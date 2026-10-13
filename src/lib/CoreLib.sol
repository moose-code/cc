// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    IController,
    ICredits,
    ICreditScore,
    IExitModule,
    IStatements,
    Settings,
    Mainnet
} from "../interfaces/Interfaces.sol";
import {Halving} from "./Halving.sol";
import {SettingsBounds} from "./SettingsBounds.sol";
import {SettingsStore} from "./SettingsStore.sol";
import {RateStore} from "./RateStore.sol";

/// the Core's state variables in declaration order. read at slot 0 (`CoreLib.state`), it addresses the same storage as the
/// Core's own variables, because a struct in storage is laid out by the same rules as the state variables of a contract.
/// test/CoreLayout.t.sol compares both views
struct CoreState {
    address controller;
    bool controllerLocked;
    bool exitModuleLocked;
    bool targetsLocked;
    address exitModule;
    address exitToken;
    mapping(address => bool) allowedTarget;
    address owner;
    address pendingOwner;
    uint256 ethPot;
    uint256 ethToBuyback;
    uint256 ethRedeemBurn;
    uint256 xPot;
    uint256 rateAtCheckpoint;
    uint64 checkpointTime;
    uint64 lastFillTime;
    uint256 lastBuybackBlock;
    CoreLib.Pile pile;
    mapping(uint256 => CoreLib.Credit) credits;
    mapping(uint256 => CoreLib.Statement) statements;
    uint256[] heldIds;
    uint256 unitPerPoint;
    address successor;
    bool successorLocked;
    bool retired;
    uint16 creditCostToPotBps;
    bool chosenComposeOn;
    uint96 minCcToChoose;
}

/// the one linked library of the Core: the settings write (validation, storage, event), the eth rate (the climb with its
/// clamp and ceiling, and the drop on a fill), the pool manager swap of the coin buyback, the
/// pull of the fee router's balance and the sale of credits into the exit token bid.
/// it holds no state of its own and is called by delegatecall, so it works on the Core's storage and balance, and the
/// Core keeps its runtime under the size limit. deployed once before the Core (docs/DEPLOY.md)
library CoreLib {
    using FixedPointMathLib for uint256;

    struct Pile {
        uint256 head;
        uint256 tail;
        uint256 size;
    }

    struct Credit {
        uint256 cost;
        uint256 prev;
        uint256 next;
        uint64 acquiredAt;
        bool inPile;
    }

    /// a statement the Core holds for sale or exit. `composedAt` is the time of the compose, `slot` the index in
    /// `heldIds`, `rating` the sum of its credits' scores read from Statements at compose. the record is deleted when
    /// the statement leaves
    struct Statement {
        uint256 cost;
        uint64 composedAt;
        uint64 slot;
        uint32 rating;
        bool held;
    }

    uint256 internal constant BPS = 10_000;
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error Empty();
    error NoExitModule();
    error BadModule();
    error ZeroId();
    error NotOwner();
    error ZeroAmount();
    error PotTooSmall();
    error Slippage();
    /// the action is not allowed in the current `exitMode`
    error ExitModeOff();
    event CreditBought(uint256 indexed id, address indexed from, uint256 cost);
    error BadSetting(bytes32 field);
    event SettingsSet(Settings settings);
    error BadSwap();
    error ZeroAddress();
    error OnlyOwner();
    event CoinRescued(address indexed to, uint256 amount);
    /// the credit is in a pile of the Core
    error InPile();
    /// the statement is on the books of the Core
    error Held();
    /// the Core is not the holder of the token, or the token is not an ERC721
    error NotHolder();
    event NftRescued(address indexed token, uint256 indexed id, address indexed to);
    error Locked(bytes32 what);
    error NoCode(address who);
    error NoSuccessor();
    /// the Core ran `migrate`, which retired it
    error Retired();
    /// the successor is the Core or a contract the Core works with
    error BadSuccessor(address who);
    error CallFailed();
    event SuccessorSet(address successor);
    event SuccessorLocked();
    event CreditAdopted(uint256 indexed id, uint256 cost);
    event Migrated(address indexed successor, uint256 eth, uint256 exitTokens, uint256 credits);
    event EngineRetired(address indexed successor);
    event ExitTokenMigrationSkipped(address indexed successor, uint256 amount);

    /// @notice validates the settings, stores them and logs them. the Core forwards its own `setSettings` call here
    /// untouched (same selector), after it checkpointed the eth rate. the constructor calls it too. a change of
    /// `peakHalfLife` restates the remembered peak at the old half life before storing the new one, so the new half
    /// life decays the peak forward only
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        Settings storage s = SettingsStore.load();
        // a change of the peak half life applies forward only: restate the remembered peak at the old half life before
        // the new one is stored, so the elapsed decay is not rescaled. skipped at the first set (old half life zero,
        // the constructor, where the peak was just written)
        uint256 oldHalf = s.peakHalfLife;
        if (oldHalf != 0 && ns.peakHalfLife != oldHalf) {
            RateStore.Anchor storage a = RateStore.load();
            a.peakRate = Halving.halve(a.peakRate, block.timestamp.zeroFloorSub(a.peakTime), oldHalf);
            // forge-lint: disable-next-line(unsafe-typecast)
            a.peakTime = uint64(block.timestamp);
        }
        s.dropPerCreditBps = ns.dropPerCreditBps;
        s.dropFloorBps = ns.dropFloorBps;
        s.climbPerMinBps = ns.climbPerMinBps;
        s.ceilBps = ns.ceilBps;
        s.idleLoosenBps = ns.idleLoosenBps;
        s.saleFloorBps = ns.saleFloorBps;
        s.saleToBuybackBps = ns.saleToBuybackBps;
        s.recoveryClimbPerMinBps = ns.recoveryClimbPerMinBps;
        s.recoveryGapBps = ns.recoveryGapBps;
        s.peakHalfLife = ns.peakHalfLife;
        s.buybackDelay = ns.buybackDelay;
        s.exitMode = ns.exitMode;
        s.exitSlippageBps = ns.exitSlippageBps;
        s.exitBidMarginBps = ns.exitBidMarginBps;
        s.redeemBurnBps = ns.redeemBurnBps;
        s.buybackSlice = ns.buybackSlice;
        s.keeperFee = ns.keeperFee;
        s.keeperMaxBaseFee = ns.keeperMaxBaseFee;
        s.rateCap = ns.rateCap;
        s.callerFee = ns.callerFee;
        s.callerMaxBaseFee = ns.callerMaxBaseFee;
        s.feeToBuybackBps = ns.feeToBuybackBps;
        s.feeToRedeemBurnBps = ns.feeToRedeemBurnBps;
        emit SettingsSet(ns);
    }

    /// @notice the settings as a struct, from the three packed storage words they sit in. the layout is the one the
    /// compiler gives `Settings` (fields packed in order, a field never straddles a slot), which test/Flow.t.sol
    /// checks against a write and a read
    function unpack(uint256 a, uint256 b, uint256 c) external pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPerCreditBps = uint16(a);
        s.dropFloorBps = uint16(a >> 16);
        s.climbPerMinBps = uint16(a >> 32);
        s.ceilBps = uint16(a >> 48);
        s.idleLoosenBps = uint16(a >> 64);
        s.saleFloorBps = uint16(a >> 80);
        s.saleToBuybackBps = uint16(a >> 96);
        s.recoveryClimbPerMinBps = uint16(a >> 112);
        s.recoveryGapBps = uint16(a >> 128);
        s.peakHalfLife = uint32(a >> 144);
        s.buybackDelay = uint16(a >> 176);
        s.exitMode = uint8(a >> 192);
        s.exitSlippageBps = uint16(a >> 200);
        s.exitBidMarginBps = uint16(a >> 216);
        s.redeemBurnBps = uint16(a >> 232);
        s.buybackSlice = uint128(b);
        s.keeperFee = uint64(b >> 128);
        s.keeperMaxBaseFee = uint48(b >> 192);
        s.rateCap = uint64(c);
        s.callerFee = uint64(c >> 64);
        s.callerMaxBaseFee = uint48(c >> 128);
        s.feeToBuybackBps = uint16(c >> 176);
        s.feeToRedeemBurnBps = uint16(c >> 192);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice the price state and the read of the eth rate (wei per credit) at `nowTs`, from the stored rate `r` of
    /// checkpoint time `t`. The price state climbs toward min(`rateCap`, ceiling, pot) and holds a value above that
    /// bound. Below the recovery level `peak * (10_000 - recoveryGapBps) / 10_000` it compounds
    /// `recoveryClimbPerMinBps` per minute, at or above the level `climbPerMinBps`. The ceiling is `ceilBps` of
    /// `max(last fill rate, peak now)` grown by `idleLoosenBps` per full
    /// 10 minutes since `anchorTime`, where `peak now` is `peakRate` halved over the time since `peakTime`. The clamp is
    /// `pot`, the price of one credit the pot affords. The read is min(price state, pot). Never reverts: the Core calls
    /// it from `receive()`
    function climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        external
        view
        returns (uint256 price, uint256 read)
    {
        return _climb(r, pot, anchorTime, t, nowTs);
    }

    function _climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        private
        view
        returns (uint256 price, uint256 read)
    {
        Settings storage s = SettingsStore.load();
        RateStore.Anchor storage a = RateStore.load();
        uint256 peakNow = Halving.halve(a.peakRate, nowTs.zeroFloorSub(a.peakTime), s.peakHalfLife);
        uint256 anchor = a.lastFillRate.max(peakNow);
        uint256 loosened = 10_000 + uint256(s.idleLoosenBps) * (nowTs.zeroFloorSub(anchorTime) / 10 minutes);
        uint256 cap = (anchor * loosened * s.ceilBps / 1e8).min(s.rateCap);
        price = r;
        if (r >= cap) {
            price = cap;
        } else if (nowTs > t && r != 0) {
            uint256 target = cap.min(pot);
            if (r < target) price = _recover(r, target, t, nowTs, a, s);
        }
        read = price.min(pot);
    }

    /// @notice the price state climbed from `r` at time `t` to `nowTs`, clamped to `target`. Below the recovery level
    /// (`recoveryGapBps` under the decaying peak) the climb is `recoveryClimbPerMinBps` a minute, at or above it
    /// `climbPerMinBps`. The recovery level decays at the peak's rate, so the crossing where the fast climb meets it
    /// is the solution of `r * fast^(s/60) = levelT * 2^(-s/H)`, `crossWadSec = ln(levelT / r) / (lnFast/60 + ln2/H)`
    /// in wad seconds: closed form, linear in log time, so it does not move with the evaluation time. The trajectory is
    /// continuous at the crossing and monotone in `nowTs`. The ceiling clamp can fall as the peak decays, which lowers
    /// the clamped result; the unclamped climb never does
    function _recover(uint256 r, uint256 target, uint256 t, uint256 nowTs, RateStore.Anchor storage a, Settings storage s)
        private
        view
        returns (uint256)
    {
        // forge-lint: disable-start(unsafe-typecast)
        int256 lnFast = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.recoveryClimbPerMinBps) * 1e14));
        int256 lnSlow = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14));
        uint256 peakT = Halving.halve(a.peakRate, t.zeroFloorSub(a.peakTime), s.peakHalfLife);
        uint256 levelT = peakT * (10_000 - s.recoveryGapBps) / 10_000;
        uint256 fullWadSec = (nowTs - t) * 1e18;
        if (levelT <= r) return _climbTo(r, lnSlow, fullWadSec, target);
        // crossing elapsed (wad seconds): ln(levelT / r) / (lnFast per second + ln2 per second)
        uint256 denom = uint256(lnFast) / 1 minutes + uint256(FixedPointMathLib.lnWad(2e18)) / s.peakHalfLife;
        uint256 crossWadSec = uint256(FixedPointMathLib.lnWad(int256(levelT * 1e18 / r))) * 1e18 / denom;
        if (fullWadSec <= crossWadSec) return _climbTo(r, lnFast, fullWadSec, target);
        uint256 priceCross = _climbTo(r, lnFast, crossWadSec, target);
        if (priceCross >= target) return target;
        return _climbTo(priceCross, lnSlow, fullWadSec - crossWadSec, target);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice `base` compounded at `lnRate` (the wad log of one minute's growth) over `wadSec` wad seconds, at most
    /// `target`. `base` is below `target`, so the log of the ratio is positive and the exponential cannot overflow
    function _climbTo(uint256 base, int256 lnRate, uint256 wadSec, uint256 target) private pure returns (uint256) {
        // forge-lint: disable-start(unsafe-typecast)
        int256 x = lnRate * int256(wadSec / 1 minutes) / 1e18;
        if (x >= FixedPointMathLib.lnWad(int256(target * 1e18 / base))) return target;
        return base.mulWad(uint256(FixedPointMathLib.expWad(x))).min(target);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice the rate after one credit is bought with the price state `price` at the fill, and the anchor update of
    /// that fill. The rate falls `dropPerCreditBps` below `price` and stays at or above `dropFloorBps` of the price state
    /// at the first fill of the current minute bucket (`nowTs / 60`). A `price` already below that floor (restated by
    /// `setRate` or lowered by a bound) starts a new floor at `price`. `price` becomes the last fill rate, and the
    /// remembered peak becomes `max(price, peak now)` with `peakTime` set to `nowTs`
    function drop(uint256 price, uint256 nowTs) external returns (uint256) {
        Settings storage s = SettingsStore.load();
        RateStore.Anchor storage a = RateStore.load();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 bucket = uint64(nowTs / 1 minutes);
        if (bucket != a.minuteBucket || price < a.minuteStartRate * s.dropFloorBps / 10_000) {
            a.minuteBucket = bucket;
            a.minuteStartRate = price;
        }
        a.lastFillRate = price;
        uint256 peakNow = Halving.halve(a.peakRate, nowTs.zeroFloorSub(a.peakTime), s.peakHalfLife);
        a.peakRate = price.max(peakNow);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.peakTime = uint64(nowTs);
        return (price * (10_000 - s.dropPerCreditBps) / 10_000).max(a.minuteStartRate * s.dropFloorBps / 10_000);
    }

    /// @notice the swap of the coin buyback, run inside the pool manager unlock callback of the Core: exact eth in for
    /// coin on the canonical pool, the eth settled from the Core balance and the coin taken to the Core. returns the eth
    /// spent, skim included, and the coin bought. the pool took no more than it was given
    function swapIn(address manager, address coin, uint24 fee, int24 spacing, address hook, uint256 amountIn)
        external
        returns (uint256 owed, uint256 bought)
    {
        IPoolManager pm = IPoolManager(manager);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        // forge-lint: disable-start(unsafe-typecast)
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (d.amount0() > 0 || d.amount1() < 0) revert BadSwap();
        owed = uint256(uint128(-d.amount0()));
        if (owed > amountIn) revert BadSwap();
        pm.settle{value: owed}();
        bought = uint256(uint128(d.amount1()));
        pm.take(key.currency1, address(this), bought);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice sends coin the Core holds to `to`. the Core's `rescueCoin` forwards its call here untouched, so the owner
    /// check and the reentrancy guard are here: `msg.sender` is the caller of the Core and the guard is the Core's own
    /// (solady's storage guard, the same slot: the word holds the Core's address while a guarded call runs and the
    /// library's `codesize()` after it, and any nonzero value other than the Core's address counts as free)
    function rescueCoin(address to, uint256 amount) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        _enter();
        SafeTransferLib.safeTransfer(ICoinOf(address(this)).COIN(), to, amount);
        _leave();
        emit CoinRescued(to, amount);
    }

    /// @notice sends the ERC721 token `id` of `token` that the Core holds to `to` with `transferFrom`. a credit leaves only
    /// while it is not in a pile (`Credit.inPile`), a statement only while the Core has no record of it
    /// (`Statement.held`), every other ERC721 leaves. `ownerOf` must answer with the Core, which an ERC20 or an
    /// address without code cannot. the Core forwards its call here untouched, the owner check and the reentrancy
    /// guard are here
    function rescueNft(address token, uint256 id, address to) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        _enter();
        CoreState storage c = state();
        if (token == address(CREDITS)) {
            if (c.credits[id].inPile) revert InPile();
        } else if (token == Mainnet.STATEMENTS) {
            if (c.statements[id].held) revert Held();
        }
        (bool ok, bytes memory out) = token.staticcall(abi.encodeCall(ICredits.ownerOf, (id)));
        if (!ok || out.length != 32 || abi.decode(out, (address)) != address(this)) revert NotHolder();
        ICredits(token).transferFrom(address(this), to, id);
        _leave();
        emit NftRescued(token, id, to);
    }

    /// @notice puts credits the Core holds without a record into the eth pile, anyone may call. The cost basis of a
    /// credit is the price state per credit at `block.timestamp` (`climb`, before the clamp, no checkpoint is
    /// written), at least 1 wei. The price state is what the engine pays with a funded
    /// pot, so statements built from adopted credits are priced at that level; the clamp of a thin pot would book a
    /// basis of 1 wei. A donor who inflates the basis of a statement gives credits away. The basis is booked and the
    /// eth pile grows: the rate state and the pots keep their values. `acquiredAt` is the current
    /// time. Reverts `Empty` for an empty list, `ZeroId` for id zero, `InPile` for a credit that is in a pile (the same
    /// id twice included), and `NotHolder` for a credit the Core does not hold. The Core pulls the fee router, then
    /// forwards its call here untouched, under its own reentrancy guard
    function adopt(uint256[] calldata ids) external {
        if (ids.length == 0) revert Empty();
        CoreState storage c = state();
        (uint256 price,) = _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == 0) revert ZeroId();
            if (c.credits[id].inPile) revert InPile();
            if (CREDITS.ownerOf(id) != address(this)) revert NotHolder();
            uint256 cost = price.max(1);
            push(c.pile, c.credits, id, cost);
            emit CreditAdopted(id, cost);
        }
    }

    /// @notice sets the successor to which `migrate` sends the assets. the zero address means no migration. reverts
    /// after `lockSuccessor`, and for the Core itself, the exit module, the exit token, the fee source, the
    /// coin, Credits and Statements. the Core forwards its call here untouched
    function setSuccessor(address next) external {
        _onlyOwner();
        CoreState storage c = state();
        if (c.successorLocked) revert Locked("successor");
        if (next != address(0)) {
            if (next.code.length == 0) revert NoCode(next);
            ICoinOf core = ICoinOf(address(this));
            if (
                next == address(this) || next == c.exitModule || next == c.exitToken || next == core.FEE_SOURCE()
                    || next == core.COIN() || next == address(CREDITS) || next == address(STATEMENTS)
            ) revert BadSuccessor(next);
        }
        c.successor = next;
        emit SuccessorSet(next);
    }

    /// @notice closes `setSuccessor`. allowed while the successor is zero, which disables `migrate`
    function lockSuccessor() external {
        _onlyOwner();
        state().successorLocked = true;
        emit SuccessorLocked();
    }

    /// @notice moves `ethPot`, `xPot` and the credits the Core tracks to the successor, in batches. the Core
    /// forwards its call here untouched, the owner check and the reentrancy guard are here.
    /// the first call sets `retired`, which stays set: `sellForEth`, `buyListing`, `sellForExitToken`, `adopt` and
    /// `compose` then revert `Retired`. logs `EngineRetired` once.
    /// eth: `ethPot`, by one plain call, the tracker zeroed. `ethToBuyback` stays for the coin buyback. eth above the
    /// trackers stays.
    /// exit token: `xPot`, by `transfer`, the tracker zeroed. a transfer that reverts, returns false or returns less
    /// than a word leaves the pot as it is, logs `ExitTokenMigrationSkipped` and the call goes on; a later `migrate`
    /// retries. the coin stays. `ethToBuyback` and `ethRedeemBurn` stay for the coin buyback.
    /// credits: up to `maxCredits` from the head of the pile, by `transferFrom`, the pile membership cleared (the
    /// cost and arrival time of the record stay). zero moves the pots only.
    /// the held statements and their records stay with the Core, which sells or exits them itself.
    /// the eth rate is checkpointed before `ethPot` is zeroed. a call with nothing left to move logs zeros
    function migrate(uint256 maxCredits) external {
        _onlyOwner();
        CoreState storage c = state();
        address to = c.successor;
        if (to == address(0)) revert NoSuccessor();
        _enter();
        if (!c.retired) {
            c.retired = true;
            emit EngineRetired(to);
        }
        uint256 eth = _moveEth(c, to);
        uint256 credits = _moveCredits(c, to, maxCredits);
        uint256 exitTokens = _moveExitToken(c, to);
        _leave();
        emit Migrated(to, eth, exitTokens, credits);
    }

    function _moveEth(CoreState storage c, address to) private returns (uint256 eth) {
        eth = c.ethPot;
        if (eth == 0) return 0;
        (c.rateAtCheckpoint,) = _climb(c.rateAtCheckpoint, eth, c.lastFillTime, c.checkpointTime, block.timestamp);
        c.checkpointTime = uint64(block.timestamp);
        c.ethPot = 0;
        (bool ok,) = to.call{value: eth}("");
        if (!ok) revert CallFailed();
    }

    /// the transfer is a low level call that accepts no return data or `true`. on failure the pot stays as it is and
    /// `ExitTokenMigrationSkipped` is logged
    function _moveExitToken(CoreState storage c, address to) private returns (uint256 amount) {
        amount = c.xPot;
        if (amount == 0) return 0;
        address token = c.exitToken;
        bool ok;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 4), to)
            mstore(add(p, 36), amount)
            ok := call(gas(), token, 0, p, 68, 0, 32)
            switch returndatasize()
            case 0 { ok := and(ok, gt(extcodesize(token), 0)) }
            default { ok := and(ok, and(gt(returndatasize(), 31), eq(mload(0), 1))) }
        }
        if (!ok) {
            emit ExitTokenMigrationSkipped(to, amount);
            return 0;
        }
        c.xPot = 0;
    }

    /// pops up to `max` credits from the head of the pile
    function _moveCredits(CoreState storage c, address to, uint256 max) private returns (uint256 moved) {
        Pile storage p = c.pile;
        uint256 id = p.head;
        uint256 k;
        while (id != 0 && k < max) {
            Credit storage cr = c.credits[id];
            uint256 next = cr.next;
            cr.next = 0;
            cr.prev = 0;
            cr.inPile = false;
            CREDITS.transferFrom(address(this), to, id);
            id = next;
            ++k;
        }
        if (k != 0) {
            p.head = id;
            p.size -= k;
            if (id == 0) p.tail = 0;
            else c.credits[id].prev = 0;
            moved = k;
        }
    }

    /// the caller of an owner function the Core forwarded here: `msg.sender` is the caller of the Core
    function _onlyOwner() private view {
        if (msg.sender != state().owner) revert OnlyOwner();
    }

    /// takes the reentrancy guard of the Core (solady's storage guard: the word holds the Core's address while a guarded
    /// call runs and the library's `codesize()` after it; any nonzero value other than the Core's address counts as free)
    function _enter() private {
        assembly {
            if eq(sload(0x929eee149b4bd21268), address()) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            sstore(0x929eee149b4bd21268, address())
        }
    }

    function _leave() private {
        assembly {
            sstore(0x929eee149b4bd21268, codesize())
        }
    }

    /// @notice the Core's state variables, by name
    function state() internal pure returns (CoreState storage c) {
        assembly ("memory-safe") {
            c.slot := 0
        }
    }

    /// appends credit `id` with cost basis `cost` to the pile `p`
    function push(Pile storage p, mapping(uint256 => Credit) storage credits, uint256 id, uint256 cost) internal {
        uint256 tail = p.tail;
        Credit storage c = credits[id];
        c.cost = cost;
        c.prev = tail;
        c.next = 0;
        c.acquiredAt = uint64(block.timestamp);
        c.inPile = true;
        if (tail == 0) p.head = id;
        else credits[tail].next = id;
        p.tail = id;
        p.size += 1;
    }

    /// the caller must own credit `id`, which is not the zero sentinel
    function owned(uint256 id) internal view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    /// @notice sells the credits `ids` of the caller into the exit token bid. the Core's `sellForExitToken` forwards its
    /// call here untouched, under its own reentrancy guard
    function sellForExitToken(uint256[] calldata ids) external {
        _sellForExitToken(ids, 0);
    }

    /// @notice same as the one argument form with a floor on the total paid
    function sellForExitToken(uint256[] calldata ids, uint256 minOut) external {
        _sellForExitToken(ids, minOut);
    }

    /// pays each credit `score * unit * (10_000 - exitBidMarginBps) / 10_000` in exit token from `xPot`, where `unit` is
    /// the lower of the stored `unitPerPoint` and the module's live `unitPerPoint()`, so a module that lowered its rate
    /// after the owner set it cannot make the bid overpay. reads the score from the credit score contract. runs only
    /// while `exitMode` is 2. each credit's price must not exceed the remaining pot. the credit enters the single pile
    /// with an eth cost basis of the higher of the exit tokens paid valued in wei (`controller.valueWei`) and the
    /// score-scaled eth backstop `ethBid * max(1, score / refScore)`, at least 1 wei, so a pushed down pool price cannot
    /// record a cost below the score's eth value and an empty pot does not record a zero cost (docs/FLOW.md 92, 94). a
    /// failing, short or zero live unit read reverts the whole bid (`BadModule`); an unset pool key or a zero pool price
    /// reverts in `valueWei`. `refScore` is read from the controller with a bounded staticcall; a failed read leaves the
    /// backstop unscaled at `ethBid`
    function _sellForExitToken(uint256[] calldata ids, uint256 minOut) private {
        CoreState storage c = state();
        if (c.retired) revert Retired();
        Settings storage s = SettingsStore.load();
        if (s.exitMode != 2) revert ExitModeOff();
        if (ids.length == 0) revert Empty();
        if (c.exitModule == address(0)) revert NoExitModule();
        uint256 unit = c.unitPerPoint;
        uint256 live = _liveUnit(c.exitModule);
        if (live < unit) unit = live;
        uint256 net = BPS - s.exitBidMarginBps;
        uint256 pot = c.xPot;
        // the eth bid rate before the pot clamp, the base of a credit's recorded eth cost basis. the unclamped price
        // state is read so an empty pot does not drop the base to zero. read only, no checkpoint
        (uint256 ethBid,) = _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
        IController ctl = IController(c.controller);
        uint256 refScore = _refScore(c.controller);
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = owned(ids[i]);
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
            uint256 paid = score * unit * net / BPS;
            if (paid == 0) revert ZeroAmount();
            if (paid > pot) revert PotTooSmall();
            pot -= paid;
            total += paid;
            uint256 valued = ctl.valueWei(paid);
            uint256 backstop = (refScore == 0 || score <= refScore) ? ethBid : ethBid.mulDiv(score, refScore);
            uint256 cost = valued.max(backstop).max(1);
            push(c.pile, c.credits, id, cost);
            CREDITS.transferFrom(msg.sender, address(this), id);
            emit CreditBought(id, msg.sender, cost);
        }
        c.xPot = pot;
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransfer(c.exitToken, msg.sender, total);
    }

    /// gas forwarded to the live `unitPerPoint()` read of the exit token bid
    uint256 internal constant READ_GAS = 200_000;

    /// bounded read of `unitPerPoint()` of `module`: at most `READ_GAS`, exactly 32 bytes returned or more (a long
    /// answer is cut off). a revert, a short answer or a zero unit reverts `BadModule`
    function _liveUnit(address module) private view returns (uint256 unit) {
        bytes4 sel = IExitModule.unitPerPoint.selector;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok || unit == 0) revert BadModule();
    }

    /// the controller's `refScore()` through a bounded staticcall of at most `READ_GAS`. a revert or a short answer
    /// reads as 0, which leaves the exit bid's backstop unscaled at the eth bid rate
    function _refScore(address controller) private view returns (uint256) {
        (bool ok, bytes memory out) = controller.staticcall{gas: READ_GAS}(abi.encodeWithSignature("refScore()"));
        return ok && out.length >= 32 ? abi.decode(out, (uint256)) : 0;
    }

    /// gas forwarded to the router flush of `pullFees`. the most expensive flush (four payees that burn all their
    /// gas, the split on) measures 640,000 gas in test/PullFees.t.sol
    uint256 internal constant PULL_GAS = 1_000_000;

    /// @notice calls `flush()` on the fee router with at most `PULL_GAS` and ignores the outcome. the router sends
    /// the fee eth to `Core.receive`, which books it. a router that reverts, burns its gas or has no code leaves the
    /// caller's entry point unaffected and the fees in the router
    function pullFees(address router) external {
        bytes memory data = abi.encodeCall(IRouterFlush.flush, ());
        assembly ("memory-safe") {
            pop(call(PULL_GAS, router, 0, add(data, 0x20), mload(data), 0, 0))
        }
    }
}

interface IRouterFlush {
    function flush() external;
}

interface ICoinOf {
    function COIN() external view returns (address);
    function FEE_SOURCE() external view returns (address);
}
