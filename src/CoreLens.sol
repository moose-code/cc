// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IControllerV1} from "./interfaces/IControllerV1.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";
import {Lane, ICredits, ICreditScore, Settings, Mainnet} from "./interfaces/Interfaces.sol";

/// read only view of the Core, the controller and the fee router in one call. it has no storage and no state changing
/// function. the Core and the router are immutable pointers fixed at creation (the router is the Core fee source). the
/// controller is read from the Core on every call, so a controller replaced by the owner is followed. Credits and
/// Statements are the mainnet constants.
/// `snapshot` returns everything a seller, a buyer or a keeper decides on. a held list of several hundred statements
/// costs more gas than a public node allows for `eth_call`: `statementsPage` reads it in pages
contract CoreLens {
    using FixedPointMathLib for uint256;

    /// the held statement `id` of the Core, with its lane, cost basis, compose time and rating. `askingPrice` is the
    /// controller price now in wei for an eth lane statement. it is 0 for an exit lane statement and when the
    /// controller does not answer. `exitEligible` is true when a redemption of this statement would pass the Core gates
    /// now: a module set, `exitMode` at least 1, and for an eth lane statement an asking price at or below cost
    struct StatementView {
        uint256 id;
        Lane lane;
        uint256 cost;
        uint64 composedAt;
        uint256 rating;
        uint256 askingPrice;
        bool exitEligible;
    }

    /// `ethRate` is the wei the Core pays for one credit now. `ethPrice` is the price state before the
    /// clamp, the figure an adopted credit is priced with. `unbookedEth` is the Core balance
    /// above the booked pots (`skim` books it). the flush fields are what `FeeRouter.flush()` would send
    /// now: to the Core and to the payees
    struct Snapshot {
        uint256 ethRate;
        uint256 ethPrice;
        uint256 ethPileSize;
        uint256 ethPileHead;
        uint256 exitPileSize;
        uint256 exitPileHead;
        bool ethPageReady;
        bool exitPageReady;
        uint256 ethPot;
        uint256 ethToBuyback;
        uint256 ethRedeemBurn;
        uint256 xPot;
        uint256 unbookedEth;
        uint256 routerBalance;
        uint256 routerOwed;
        uint256 flushToCore;
        uint256 flushToPayees;
        address controller;
        address successor;
        address exitModule;
        address exitToken;
        uint256 exitMode;
        uint256 unitPerPoint;
        bool controllerLocked;
        bool exitModuleLocked;
        bool targetsLocked;
        bool successorLocked;
        StatementView[] statements;
    }

    uint256 private constant PPM = 1_000_000;
    uint256 private constant NEXT_PAGE_GAS = 500_000;
    /// the answer size of `nextPage` that the Core requires: ready flag, 80 ids and the format
    uint256 private constant NEXT_PAGE_BYTES = (80 + 2) * 32;
    uint256 private constant ASK_GAS = 200_000;

    ICore public immutable CORE;
    IFeeRouter public immutable ROUTER;
    address public constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address public constant STATEMENTS = 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b;

    constructor(address core) {
        CORE = ICore(payable(core));
        ROUTER = IFeeRouter(payable(ICore(payable(core)).FEE_SOURCE()));
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
        s.ethPileSize = core.pileSize(Lane.Eth);
        s.ethPileHead = _head(Lane.Eth);
        s.exitPileSize = core.pileSize(Lane.Exit);
        s.exitPileHead = _head(Lane.Exit);
        s.controller = controller();
        s.ethPageReady = _pageReady(s.controller, Lane.Eth);
        s.exitPageReady = _pageReady(s.controller, Lane.Exit);
        s.ethPot = core.ethPot();
        s.ethToBuyback = core.ethToBuyback();
        s.ethRedeemBurn = core.ethRedeemBurn();
        s.xPot = core.xPot();
        s.unbookedEth = address(core).balance.zeroFloorSub(s.ethPot + s.ethToBuyback + s.ethRedeemBurn);
        s.routerBalance = address(ROUTER).balance;
        s.routerOwed = ROUTER.totalOwed();
        (s.flushToCore, s.flushToPayees) = _flush();
        s.successor = core.successor();
        s.exitModule = core.exitModule();
        s.exitToken = core.exitToken();
        s.exitMode = core.settings().exitMode;
        s.unitPerPoint = core.unitPerPoint();
        s.controllerLocked = core.controllerLocked();
        s.exitModuleLocked = core.exitModuleLocked();
        s.targetsLocked = core.targetsLocked();
        s.successorLocked = core.successorLocked();
    }

    /// the oldest credit of the pile of `lane`, zero when the pile is empty
    function _head(Lane lane) private view returns (uint256) {
        uint256[] memory ids = CORE.pilePage(lane, 0, 1);
        return ids.length == 0 ? 0 : ids[0];
    }

    /// the split of `FeeRouter.flush`, from the router balance, the debts to payees and the split state now. zero while
    /// the router has no engine or nothing above its debts
    function _flush() private view returns (uint256 toCore, uint256 toPayees) {
        IFeeRouter r = ROUTER;
        uint256 balance = address(r).balance;
        uint256 owed = r.totalOwed();
        if (r.engine() == address(0) || balance <= owed) return (0, 0);
        uint256 amount = balance - owed;
        if (r.splitOn()) {
            (, uint32[] memory ppm) = r.payees();
            for (uint256 i; i < ppm.length; ++i) {
                toPayees += amount * ppm[i] / PPM;
            }
        }
        toCore = amount - toPayees;
    }

    /// whether the controller answers `nextPage` for `lane` with ready set, read with the gas and the answer size the
    /// Core requires of it in `compose`. a controller without code, a revert and an answer shorter than
    /// `NEXT_PAGE_BYTES` read as not ready
    function _pageReady(address ctl, Lane lane) private view returns (bool ready) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: NEXT_PAGE_GAS}(abi.encodeCall(IControllerV1.nextPage, (lane)));
        ready = ok && out.length >= NEXT_PAGE_BYTES && abi.decode(out, (uint256)) == 1;
    }

    /// the asking price of statement `sid` from the controller, zero when it does not answer with one word
    function _askingPrice(address ctl, uint256 sid) private view returns (uint256 price) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeCall(IControllerV1.priceOf, (sid)));
        if (ok && out.length == 32) price = abi.decode(out, (uint256));
    }

    /// the controller's eligibility answer for an eth lane statement, read with the gas the Core uses. a revert, a
    /// short answer or a `false` reads as not eligible
    function _atCost(address ctl, uint256 sid) private view returns (bool) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: ASK_GAS}(abi.encodeCall(IControllerV1.atCost, (sid)));
        return ok && out.length == 32 && abi.decode(out, (bool));
    }

    /// the exit token the bid pays for a live credit now, zero when the bid is off (`exitMode` other than 2) or no
    /// module is set. the Core reads the same score from the credit score contract in `sellForExitToken`
    function exitBidOf(uint256 id) external view returns (uint256) {
        ICore core = CORE;
        if (core.exitModule() == address(0)) return 0;
        Settings memory st = core.settings();
        if (st.exitMode != 2) return 0;
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(CREDITS).seedOf(id), ICredits(CREDITS).timestampOf(id));
        return score * core.unitPerPoint() * (10_000 - st.exitBidMarginBps) / 10_000;
    }

    function _statements(uint256 start, uint256 n) private view returns (StatementView[] memory out) {
        ICore core = CORE;
        address ctl = controller();
        bool modeOn = core.exitModule() != address(0) && core.settings().exitMode >= 1;
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
        (, v.lane, v.cost, v.composedAt) = CORE.statementInfo(sid);
        v.rating = CORE.ratingOf(sid);
        if (v.lane == Lane.Eth) {
            v.askingPrice = _askingPrice(ctl, sid);
            v.exitEligible = modeOn && _atCost(ctl, sid);
        } else {
            v.exitEligible = modeOn;
        }
    }
}
