// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IControllerV1} from "./interfaces/IControllerV1.sol";
import {ICredits, ICreditScore, IBalanceModule, Settings, Mainnet} from "./interfaces/Interfaces.sol";

/// read only view of the Core and the controller in one call. it has no storage and no state changing
/// function. the Core is an immutable pointer fixed at creation. the controller is read from the Core on every call, so a controller replaced by the owner is followed. Credits and
/// Statements are the mainnet constants.
/// `snapshot` returns everything a seller, a buyer or a keeper decides on. a held list of several hundred statements
/// costs more gas than a public node allows for `eth_call`: `statementsPage` reads it in pages
contract CoreLens {
    using FixedPointMathLib for uint256;

    /// the held statement `id` of the Core, with its cost basis, compose time and rating. `priceReference` is the
    /// controller price reference in wei, the larger of cost and the eth bid rate times rating over `refScore`, 0 when
    /// the controller does not answer.
    /// `askingPrice` is the controller price now in wei, 0 when the controller does not answer. `redeemEligible` is true
    /// when a redemption of this statement would pass the Core gates now: a module set, `balanceMode` at least 1, and a
    /// curve price at its floor
    struct StatementView {
        uint256 id;
        uint256 cost;
        uint64 composedAt;
        uint256 rating;
        uint256 priceReference;
        uint256 askingPrice;
        bool redeemEligible;
    }

    /// `ethRate` is the wei the Core pays for one credit now. `ethPrice` is the price state before the
    /// clamp, the figure an adopted credit is priced with. `pendingIncome` is the Core balance above the booked pots and
    /// the payee claim (`book` books it). `payee`, `payeeOwed` and `payeeOn` are the payee state of the Core
    struct Snapshot {
        uint256 ethRate;
        uint256 ethPrice;
        uint256 pileSize;
        uint256 pileHead;
        bool pageReady;
        uint256 ethPot;
        uint256 ethToBuyback;
        uint256 ethRedeemBurn;
        uint256 balancePot;
        uint256 pendingIncome;
        address payee;
        uint256 payeeOwed;
        bool payeeOn;
        address controller;
        address successor;
        address balanceModule;
        address balanceToken;
        uint256 balanceMode;
        uint256 unitPerPoint;
        bool controllerLocked;
        bool balanceModuleLocked;
        bool adaptersLocked;
        bool successorLocked;
        /// whether the controller's credit sale window is on, and the seconds a credit's price falls over
        bool creditSaleOn;
        uint256 creditWindow;
        /// the controller's `refScore`, the per-credit score the statement reference divides the rating by
        uint32 refScore;
        /// whether a caller may pick the 80 credits and the format of a compose, and the least coin balance a caller
        /// of a chosen compose must hold
        bool chosenComposeOn;
        uint256 minCcToChoose;
        StatementView[] statements;
    }

    uint256 private constant NEXT_PAGE_GAS = 500_000;
    /// the answer size of `nextPage` that the Core requires: ready flag, 80 ids and the format
    uint256 private constant NEXT_PAGE_BYTES = (80 + 2) * 32;
    uint256 private constant ASK_GAS = 200_000;
    /// gas forwarded to `creditPrice` and `priceOf`. each makes up to two bounded module reads inside the controller at
    /// the controller READ_GAS (200_000) each, plus a pool read, so the lens forwards both reads plus overhead for the
    /// controller frame. a smaller budget would run a module out of gas and return a lens price below the controller's
    uint256 private constant PRICE_GAS = 600_000;

    ICore public immutable CORE;
    address public constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address public constant STATEMENTS = 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b;

    constructor(address core) {
        CORE = ICore(payable(core));
    }

    /// the controller of the Core now
    function controller() public view returns (address) {
        return CORE.controller();
    }

    /// the state of the engine in one call, with every held statement
    function snapshot() external view returns (Snapshot memory s) {
        s = _snapshot();
        s.statements = _statements(0, type(uint256).max);
    }

    /// the held statements `start` to `start + n`, in the order of `heldStatements`
    function statementsPage(uint256 start, uint256 n) external view returns (StatementView[] memory) {
        return _statements(start, n);
    }

    function _snapshot() private view returns (Snapshot memory s) {
        ICore core = CORE;
        s.ethRate = core.ethRate();
        s.ethPrice = core.ethPrice();
        s.pileSize = core.pileSize();
        s.pileHead = _head();
        s.controller = controller();
        s.pageReady = _pageReady(s.controller);
        s.ethPot = core.ethPot();
        s.ethToBuyback = core.ethToBuyback();
        s.ethRedeemBurn = core.ethRedeemBurn();
        s.balancePot = core.balancePot();
        s.payee = core.payee();
        s.payeeOwed = core.payeeOwed();
        s.payeeOn = core.payeeOn();
        s.pendingIncome = address(core).balance.zeroFloorSub(s.ethPot + s.ethToBuyback + s.ethRedeemBurn + s.payeeOwed);
        s.successor = core.successor();
        s.balanceModule = core.balanceModule();
        s.balanceToken = core.balanceToken();
        s.balanceMode = core.settings().balanceMode;
        s.unitPerPoint = core.unitPerPoint();
        s.controllerLocked = core.controllerLocked();
        s.balanceModuleLocked = core.balanceModuleLocked();
        s.adaptersLocked = core.adaptersLocked();
        s.successorLocked = core.successorLocked();
        (s.creditSaleOn, s.creditWindow) = _creditWindow(s.controller);
        s.refScore = _refScore(s.controller);
        s.chosenComposeOn = core.chosenComposeOn();
        s.minCcToChoose = core.minCcToChoose();
    }

    /// whether credit `id` may be named in a chosen compose now: in the pile and past its window. a controller that
    /// does not answer with one word reads as not past the window
    function choosable(uint256 id) external view returns (bool) {
        (bool inPile,, uint64 acquiredAt) = CORE.creditInfo(id);
        if (!inPile) return false;
        (bool ok, bytes memory out) =
            controller().staticcall{gas: ASK_GAS}(abi.encodeWithSignature("pastWindow(uint64)", acquiredAt));
        return ok && out.length == 32 && abi.decode(out, (bool));
    }

    /// the controller's credit sale state: whether the sale is on and the window length. a controller that does not
    /// answer with one word reads as off with a zero window
    function _creditWindow(address ctl) private view returns (bool on, uint256 window) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeWithSignature("creditSaleOn()"));
        on = ok && out.length == 32 && abi.decode(out, (bool));
        (ok, out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeWithSignature("creditWindow()"));
        if (ok && out.length == 32) window = abi.decode(out, (uint256));
    }

    /// the controller's sale price of pile credit `id` now, wei. zero when the controller does not answer with one word
    /// (a credit not in the pile, or a controller without the credit sale window)
    function creditPriceOf(uint256 id) external view returns (uint256 price) {
        (bool ok, bytes memory out) =
            controller().staticcall{gas: PRICE_GAS}(abi.encodeWithSignature("creditPrice(uint256)", id));
        if (ok && out.length == 32) price = abi.decode(out, (uint256));
    }

    /// the oldest credit of the pile, zero when the pile is empty
    function _head() private view returns (uint256) {
        uint256[] memory ids = CORE.pilePage(0, 1);
        return ids.length == 0 ? 0 : ids[0];
    }

    /// whether the controller answers `nextPage` with ready set, read with the gas and the answer size the
    /// Core requires of it in `compose`. a controller without code, a revert and an answer shorter than
    /// `NEXT_PAGE_BYTES` read as not ready
    function _pageReady(address ctl) private view returns (bool ready) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: NEXT_PAGE_GAS}(abi.encodeCall(IControllerV1.nextPage, ()));
        ready = ok && out.length >= NEXT_PAGE_BYTES && abi.decode(out, (uint256)) == 1;
    }

    /// the asking price of statement `sid` from the controller, zero when it does not answer with one word
    function _askingPrice(address ctl, uint256 sid) private view returns (uint256 price) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: PRICE_GAS}(abi.encodeCall(IControllerV1.priceOf, (sid)));
        if (ok && out.length == 32) price = abi.decode(out, (uint256));
    }

    /// the controller's eligibility answer for a statement, read with the gas the Core uses. a revert, a
    /// short answer or a `false` reads as not eligible
    function _atFloor(address ctl, uint256 sid) private view returns (bool) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeCall(IControllerV1.atFloor, (sid)));
        return ok && out.length == 32 && abi.decode(out, (bool));
    }

    /// the controller's price reference of a statement, read with the gas the Core uses. a revert or a short answer
    /// reads as 0
    function _reference(address ctl, uint256 sid) private view returns (uint256) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeCall(IControllerV1.referenceOf, (sid)));
        return ok && out.length == 32 ? abi.decode(out, (uint256)) : 0;
    }

    /// the controller's `refScore`, read with the gas the Core uses. a revert or a short answer reads as 0
    function _refScore(address ctl) private view returns (uint32) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeWithSignature("refScore()"));
        return ok && out.length == 32 ? uint32(abi.decode(out, (uint256))) : 0;
    }

    /// the module's `unitPerPoint()` read with the gas the Core uses. a revert or a short answer reads as 0
    function _liveUnit(address module) private view returns (uint256) {
        (bool ok, bytes memory out) = module.staticcall{gas: ASK_GAS}(abi.encodeCall(IBalanceModule.unitPerPoint, ()));
        return ok && out.length >= 32 ? abi.decode(out, (uint256)) : 0;
    }

    /// the balance token the bid pays for a live credit now, zero when the bid is off: no module set, `balanceMode` other
    /// than 2, or the engine retired. the unit is the lower of the stored and the live `unitPerPoint()`, as in
    /// `sellForBalance`, and a failed live read gives 0. the bid is capped at `balancePot`, the most `sellForBalance` can pay for one credit.
    /// the Core reads the same score from the credit score contract in `sellForBalance`
    function balanceBidOf(uint256 id) external view returns (uint256) {
        ICore core = CORE;
        if (core.balanceModule() == address(0) || core.retired()) return 0;
        Settings memory st = core.settings();
        if (st.balanceMode != 2) return 0;
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(CREDITS).seedOf(id), ICredits(CREDITS).timestampOf(id));
        uint256 unit = core.unitPerPoint();
        uint256 live = _liveUnit(core.balanceModule());
        if (live < unit) unit = live;
        uint256 bid = score * unit * (10_000 - st.balanceBidMarginBps) / 10_000;
        uint256 pot = core.balancePot();
        return bid > pot ? pot : bid;
    }

    function _statements(uint256 start, uint256 n) private view returns (StatementView[] memory out) {
        ICore core = CORE;
        address ctl = controller();
        bool modeOn = core.balanceModule() != address(0) && core.settings().balanceMode >= 1;
        uint256[] memory ids = core.heldStatements();
        uint256 from = start.min(ids.length);
        uint256 to = ids.length.min(from.saturatingAdd(n));
        out = new StatementView[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = _statement(ids[i], ctl, modeOn);
        }
    }

    function _statement(uint256 sid, address ctl, bool modeOn) private view returns (StatementView memory v) {
        v.id = sid;
        (, v.cost, v.composedAt) = CORE.statementInfo(sid);
        v.rating = CORE.ratingOf(sid);
        v.priceReference = _reference(ctl, sid);
        v.askingPrice = _askingPrice(ctl, sid);
        v.redeemEligible = modeOn && _atFloor(ctl, sid);
    }
}
