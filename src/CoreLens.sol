// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IControllerV1} from "./interfaces/IControllerV1.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";
import {Lane} from "./interfaces/Interfaces.sol";

/// read only view of the Core, the controller and the fee router in one call. it has no storage and no state changing
/// function. the Core and the router are immutable pointers fixed at creation (the router is the Core fee source). the
/// controller is read from the Core on every call, so a controller replaced by the owner is followed. Credits and
/// Statements are the mainnet constants.
/// `snapshot` returns everything a seller, a buyer or a keeper decides on. a held list of several hundred statements
/// costs more gas than a public node allows for `eth_call`: `statementsPage` reads it in pages
contract CoreLens {
    using FixedPointMathLib for uint256;

    /// the held statement `id` of the Core, with its lane, cost basis and compose time. `askingPrice` is the
    /// controller price now in wei for an eth lane statement. it is 0 for an exit lane statement and when the
    /// controller does not answer
    struct StatementView {
        uint256 id;
        Lane lane;
        uint256 cost;
        uint64 composedAt;
        uint256 askingPrice;
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
        uint256 xPot;
        uint256 xToBuyback;
        uint256 unbookedEth;
        uint256 routerBalance;
        uint256 routerOwed;
        uint256 flushToCore;
        uint256 flushToPayees;
        address controller;
        address successor;
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
        s.xPot = core.xPot();
        s.xToBuyback = core.xToBuyback();
        s.unbookedEth = address(core).balance.zeroFloorSub(s.ethPot + s.ethToBuyback);
        s.routerBalance = address(ROUTER).balance;
        s.routerOwed = ROUTER.totalOwed();
        (s.flushToCore, s.flushToPayees) = _flush();
        s.successor = core.successor();
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

    function _statements(uint256 start, uint256 n) private view returns (StatementView[] memory out) {
        address ctl = controller();
        uint256[] memory ids = CORE.heldStatements();
        uint256 from = start.min(ids.length);
        uint256 to = ids.length.min(from.saturatingAdd(n));
        out = new StatementView[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = _statement(ids[i], ctl);
        }
    }

    function _statement(uint256 sid, address ctl) private view returns (StatementView memory v) {
        v.id = sid;
        (, v.lane, v.cost, v.composedAt) = CORE.statementInfo(sid);
        if (v.lane == Lane.Eth) v.askingPrice = _askingPrice(ctl, sid);
    }
}
