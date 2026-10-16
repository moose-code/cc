// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ICredits, ICreditScore, IBalanceModule, IStatements, Settings, Mainnet} from "../interfaces/Interfaces.sol";
import {Halving} from "./Halving.sol";
import {SettingsBounds} from "./SettingsBounds.sol";

/// the v2 hook swap `hookData` layout. `mevModuleSwapData` is `abi.encode(refundTo)`; the hook credits skim charged on
/// an unfilled part of the swap to that address in the fee escrow
struct SwapData {
    bytes mevModuleSwapData;
    bytes poolExtensionSwapData;
}

/// every state variable of the Core, in one struct. the Core declares it once (`State internal s`, slot 0) and the library
/// reads it at slot 0 (`CoreLib.state`), so both address the same storage
struct State {
    address controller;
    /// one way locks of the owner (docs/SPEC.md section 11): once set, never cleared
    bool controllerLocked;
    bool balanceModuleLocked;
    bool adaptersLocked;
    address balanceModule;
    address balanceToken;
    mapping(address => bool) allowedAdapter;
    address owner;
    address pendingOwner;
    uint256 ethPot;
    uint256 ethToBuyback;
    /// the redeem burn pot, filled by `feeToRedeemBurnBps` of the fee stream. each redemption moves `redeemBurnBps` of it into
    /// `ethToBuyback`
    uint256 ethRedeemBurn;
    uint256 rateAtCheckpoint;
    uint64 checkpointTime;
    uint64 lastFillTime;
    uint256 lastBuybackBlock;
    CoreLib.Pile pile;
    mapping(uint256 => CoreLib.Credit) credits;
    mapping(uint256 => CoreLib.Statement) statements;
    uint256[] heldIds;
    /// the contract `migrate` sends the assets to, and whether `setSuccessor` is closed
    address successor;
    bool successorLocked;
    /// set by the first `migrate`, one way. a retired Core refuses `sellForEth`, `buyListing`, `sellForBalance`, `adopt`,
    /// `compose`, `composeChosen` and `swapCredit` with `Retired`
    bool retired;
    /// share of a sold credit's cost booked to `ethPot` in `sellCreditTo`, the rest of the payment to `ethToBuyback`.
    /// 0 to 10_000
    uint16 creditCostToPotBps;
    /// whether a caller may pick the 80 credits and the format of a compose through `composeChosen`
    bool chosenComposeOn;
    /// least coin balance the caller of `composeChosen` and `setHeldFormat` must hold, read at the call
    uint96 minCcToChoose;
    /// whether `sellTo` and `sellCreditTo` are paused
    bool paused;
    /// when the open pause began, 0 while not paused
    uint40 pausedSince;
    /// seconds of every closed pause
    uint40 pausedTotal;
    /// the caller of the `compose` or `composeChosen` that made each statement, kept after the statement is sold
    mapping(uint256 => address) composerOf;
    /// the address the payee fee share and the operator cut of nft sales are pushed to
    address payee;
    /// the address the artist cut of nft sales is pushed to, set by `setArtist`
    address artist;
    /// true once the payee share runs. set by the first `_book` with income at or after `launchedAt + settings.sniperSeconds`,
    /// which shares nothing. one way
    bool payeeOn;
    /// the economic settings, five packed slots
    Settings settings;
    /// the eth bid anchor state, four words
    CoreLib.Anchor anchor;
    /// the balance token bid price state, a `Rate`: its own stored rate, checkpoint, fill time and anchor. the rate is
    /// bps of par, bounded to [10_000 - balanceBidMarginBps, balanceBidCapBps] and clamped to the module's available(); the climb
    /// and drop are the eth bid's, shared through CoreLib
    CoreLib.Rate balance;
    /// the block of the last `sellCreditTo` per credit id, kept after the credit leaves the pile. an intake door
    /// (`sellForEth`, `sellForBalance`, `buyListing`, `swapCredit` as `inId`) refuses a credit the engine sold in the
    /// same block
    mapping(uint256 => uint256) creditSaleBlock;
    /// ETH purchase outflow, independent of the balance bid and of non-purchase payments
    CoreLib.Spend spend;
}

/// the one linked library of the Core: the settings write (validation, storage, event), the eth rate (the climb with its
/// clamp and ceiling, and the drop on a fill), the pool manager swap of the coin buyback, the
/// sale of credits into the balance token bid.
/// it holds no state of its own and is called by delegatecall, so it works on the Core's storage and balance, and the
/// Core keeps its runtime under the size limit. deployed once before the Core (docs/RUNBOOK.md)
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

    /// a statement the Core holds for sale or redemption. `composedAt` is the time of the compose, `slot` the index in
    /// `heldIds`, `rating` the sum of its credits' scores read from Statements at compose, `pauseMark` the paused
    /// seconds accumulated at compose (`pausedNow()` of the Core). the record is deleted when the statement leaves
    struct Statement {
        uint256 cost;
        uint64 composedAt;
        uint64 slot;
        uint32 rating;
        bool held;
        uint40 pauseMark;
    }

    /// the bid anchor state, written by a fill and by `setRate`
    struct Anchor {
        /// the price state at the last fill. the rate at deployment before the first fill
        uint256 lastFillRate;
        /// the price state at the first fill of the minute bucket `minuteBucket`
        uint256 minuteStartRate;
        /// `timestamp / bucketSeconds` of the first fill of the current bucket
        uint64 minuteBucket;
        /// time `peakRate` was last written: the last fill or `setRate`, deploy time before the first fill
        uint64 peakTime;
        /// the remembered peak: `max(fill price, peak decayed to the fill time)` at the last fill, `setRate`'s rate, or
        /// `rateStart` at deploy. it halves every `peakHalfLife` since `peakTime`. the ceiling anchors on
        /// `max(lastFillRate, peak now)`, and the price state climbs at `recoveryClimbPerMinBps` while below the
        /// recovery level `peak now * (10_000 - recoveryGapBps) / 10_000`
        uint256 peakRate;
    }

    /// one bid instance's price state: the stored rate at its checkpoint, the checkpoint and last fill times, and its
    /// anchor. the eth bid keeps these fields inline in `State` at their fixed slots; the balance bid is this struct,
    /// appended. the shared climb and drop take the anchor and the instance cap and floor, so one body serves both
    struct Rate {
        uint256 rateAtCheckpoint;
        uint64 checkpointTime;
        uint64 lastFillTime;
        Anchor anchor;
    }

    struct Spend {
        uint64 spendBucket;
        bool initialized;
        uint128 spendBudget;
        uint128 spentInBucket;
        uint256 snapshotPot;
    }

    uint256 internal constant BPS = 10_000;
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error SpendCapReached(uint256 spent, uint256 cost, uint256 budget);
    error Empty();
    error NoBalanceModule();
    error BadModule();
    /// a listing adapter answered with a bad quote. declared here for abi parity with the Core
    error BadQuote();
    error ZeroId();
    error NotOwner();
    error ZeroAmount();
    error PotTooSmall();
    error Slippage();
    /// `sellForBalance` while `balanceBidOn` is false
    error BalanceBidOff();
    /// a credit the engine sold through `sellCreditTo` in this block is offered back to an intake door
    error SameBlockReturn(uint256 id);
    event CreditBought(uint256 indexed id, address indexed from, uint256 cost);
    /// one credit filled into the balance token bid: the balance token paid, the balance rate (bps of par) after this
    /// credit's drop, and the module available left for the rest of the batch. mirrors `Core.EthRateFill`
    event EthRateFill(uint256 spent, uint256 rate, uint256 pot);
    event BalanceRateFill(uint256 spent, uint256 rateBps, uint256 available);
    error BadSetting(bytes32 field);
    event SettingsSet(Settings settings);
    /// the balance bid rate was reset to `rateBps` (bps of par): the floor, on a margin raise or the bid turning on
    event BalanceRateSet(uint256 rateBps);
    error BadSwap();
    error ZeroAddress();
    error OnlyOwner();
    event CoinRescued(address indexed to, uint256 amount);
    /// the credit is in a pile of the Core
    error InPile();
    /// `rescueNft` on the Credits contract
    error NoCreditRescue();
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
    event Migrated(address indexed successor, uint256 eth, uint256 credits);
    event EngineRetired(address indexed successor);

    /// @notice validates the settings, stores them and logs them. the Core forwards its own `setSettings` call here
    /// untouched (same selector), after it checkpointed the eth rate. the constructor calls it too. both bid instances
    /// are checkpointed before the new settings apply: the eth instance by the Core, the balance instance here when the
    /// bid is on. a change of `peakHalfLife` restates both remembered peaks at the old half life before storing the new
    /// one, so the new half life decays the peaks forward only
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        State storage c = state();
        // the artist cut is never nonzero while the artist is the zero address, so a sale never pushes it to address(0).
        // the constructor sets the artist before its own call here, so the launch config must carry a real artist
        if (ns.saleToArtistBps != 0 && c.artist == address(0)) revert ZeroAddress();
        // the sale floor can never be above the start: with a controller set, bound `saleFloorBps` at or below its
        // `markupBps`. a controller that does not answer in range is skipped; the controller's own setter guards the
        // other direction
        address ctrl = c.controller;
        if (ctrl != address(0)) {
            uint256 markup = _markupView(ctrl);
            if (markup != 0 && ns.saleFloorBps > markup) revert BadSetting("saleFloorBps");
        }
        bool wasOn = c.settings.balanceBidOn;
        // credit the elapsed climb of the balance instance under the old settings and clamp before the new ones apply,
        // so a settings change compares against the climbed value, not a stale checkpoint. with the bid off or no usable
        // module the instance does not climb, so the checkpoint is skipped and `usable` stays false
        bool usable;
        if (wasOn) usable = _balanceCheckpointNow(c);
        uint256 oldHalf = c.settings.peakHalfLife;
        if (oldHalf != 0 && ns.peakHalfLife != oldHalf) {
            _restatePeak(c.anchor, oldHalf);
            _restatePeak(c.balance.anchor, oldHalf);
        }
        _updateSpendSettings(c, ns);
        c.settings = ns;
        if (c.balance.rateAtCheckpoint > ns.balanceBidCapBps) c.balance.rateAtCheckpoint = ns.balanceBidCapBps;
        uint256 floor = BPS - ns.balanceBidMarginBps;
        // the bid turning on, and the bid on with no usable module, open the instance at the floor with a fresh clock.
        // otherwise a floor at or above the stored rate resets to the floor, and a lower floor leaves the climbed rate
        if (ns.balanceBidOn && (!wasOn || !usable)) _resetBalanceToFloor(c, floor);
        else _resetBalanceToFloorIfBelow(c, floor);
        emit SettingsSet(ns);
    }

    /// Settings edits retain successful outflow and reprice the original snapshot, never the remaining pot.
    function _updateSpendSettings(State storage c, Settings calldata ns) private {
        uint256 oldSeconds = c.settings.bucketSeconds;
        Spend storage b = c.spend;
        if (oldSeconds == 0) return;
        uint64 oldBucket = SafeCastLib.toUint64(block.timestamp / oldSeconds);
        if (b.initialized && b.spendBucket != oldBucket) {
            delete c.spend;
        } else if (b.initialized) {
            b.spendBucket = SafeCastLib.toUint64(block.timestamp / ns.bucketSeconds);
            b.spendBudget = SafeCastLib.toUint128(b.snapshotPot.mulDiv(ns.spendCapBps, BPS));
        }
        if (ns.bucketSeconds != oldSeconds) {
            _rebaseBucket(c.anchor, oldBucket, ns.bucketSeconds);
            _rebaseBucket(c.balance.anchor, oldBucket, ns.bucketSeconds);
        }
    }

    /// Preserve an active drop floor when translating its bucket; expired floors start again on the next fill.
    function _rebaseBucket(Anchor storage a, uint64 oldBucket, uint256 seconds_) private {
        uint64 next = SafeCastLib.toUint64(block.timestamp / seconds_);
        if (a.minuteBucket != oldBucket) a.minuteStartRate = 0;
        a.minuteBucket = next;
    }

    /// Books one ETH credit purchase after the Core checkpoints. Both direct and adapter doors use this path.
    function spend(uint256 cost, uint256 score, uint256 refScore) external {
        State storage c = state();
        uint256 pot = c.ethPot;
        if (cost == 0) revert ZeroAmount();
        if (cost > pot) revert PotTooSmall();
        Spend storage b = c.spend;
        Settings storage cfg = c.settings;
        uint64 bucket = SafeCastLib.toUint64(block.timestamp / cfg.bucketSeconds);
        if (!b.initialized || b.spendBucket != bucket) {
            b.spendBucket = bucket;
            b.initialized = true;
            b.snapshotPot = pot;
            b.spendBudget = SafeCastLib.toUint128(pot.mulDiv(cfg.spendCapBps, BPS));
            b.spentInBucket = 0;
        }
        uint256 total = uint256(b.spentInBucket) + cost;
        if (cfg.spendCapBps != BPS && total > b.spendBudget) {
            revert SpendCapReached(b.spentInBucket, cost, b.spendBudget);
        }
        b.spentInBucket = SafeCastLib.toUint128(total);
        uint256 rate = _drop(c.anchor, c.rateAtCheckpoint, block.timestamp, score, refScore, 0);
        c.rateAtCheckpoint = rate;
        c.lastFillTime = SafeCastLib.toUint64(block.timestamp);
        c.ethPot = pot - cost;
        emit EthRateFill(cost, rate, pot - cost);
    }

    /// restates the remembered peak of `a` at `oldHalf`: decays it to now under the old half life and marks now, so a
    /// half life change decays the peak forward only
    function _restatePeak(Anchor storage a, uint256 oldHalf) private {
        a.peakRate = Halving.halve(a.peakRate, block.timestamp.zeroFloorSub(a.peakTime), oldHalf);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.peakTime = uint64(block.timestamp);
    }

    /// climbs the balance instance to now with the live clamp (available as bps of par) and stores the price state.
    /// returns true when a usable module climbed it. with no usable module the clamp is zero, the instance does not
    /// climb, and this returns false so the caller pins the instance to the floor
    function _balanceCheckpointNow(State storage c) private returns (bool) {
        address module = c.balanceModule;
        if (module != address(0)) {
            (uint256 unit, bool ok) = _unitView(module);
            if (ok) {
                uint256 denom = uint256(c.settings.refScore) * unit;
                uint256 avail = _availableView(module);
                _balanceCheckpoint(c.balance, _toBps(avail, denom), _toBpsRaw(avail, denom));
                return true;
            }
        }
        return false;
    }

    /// resets the balance bid instance to `floor` when its stored rate is below `floor`
    function _resetBalanceToFloorIfBelow(State storage c, uint256 floor) private {
        if (c.balance.rateAtCheckpoint >= floor) return;
        _resetBalanceToFloor(c, floor);
    }

    /// @notice resets the balance instance to its live margin floor when a module is installed.
    function resetBalanceToFloor() external {
        State storage c = state();
        _resetBalanceToFloor(c, BPS - c.settings.balanceBidMarginBps);
    }

    /// resets the balance bid instance to `floor`: the rate, the fill clock and the whole anchor start at `floor`. the
    /// climb heads up from there, the drop never falls under it
    function _resetBalanceToFloor(State storage c, uint256 floor) private {
        Rate storage bal = c.balance;
        bal.rateAtCheckpoint = floor;
        // forge-lint: disable-start(unsafe-typecast)
        bal.checkpointTime = uint64(block.timestamp);
        bal.lastFillTime = uint64(block.timestamp);
        bal.anchor.lastFillRate = floor;
        bal.anchor.minuteStartRate = floor;
        bal.anchor.minuteBucket = uint64(block.timestamp / c.settings.bucketSeconds);
        bal.anchor.peakRate = floor;
        bal.anchor.peakTime = uint64(block.timestamp);
        // forge-lint: disable-end(unsafe-typecast)
        emit BalanceRateSet(floor);
    }

    /// @notice the price state and the read of the eth rate (wei per credit) at `nowTs`, from the stored rate `r` of
    /// checkpoint time `t`. The price state climbs toward min(`rateCap`, ceiling, pot). A stored rate at or above the
    /// ceiling is read at the ceiling; a rate above the availability clamp does not climb. Below the recovery level
    /// `peak * (10_000 - recoveryGapBps) / 10_000` it compounds
    /// `recoveryClimbPerMinBps` per minute, at or above the level `climbPerMinBps`. The ceiling is `ceilBps` of
    /// `max(last fill rate, peak now)` grown by `idleLoosenBps` per full
    /// 10 minutes since `anchorTime`, where `peak now` is `peakRate` halved over the time since `peakTime`. The clamp is
    /// `pot`, the price of one credit the pot affords. The read is min(price state, pot)
    function climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        external
        view
        returns (uint256 price, uint256 read)
    {
        State storage c = state();
        (price, read,) = _climb(c.anchor, r, pot, c.settings.rateCap, _ethPagesPot(c), anchorTime, t, nowTs);
    }

    /// the eth instance pages pot: `ethPot` plus the pot share of the unbooked fee income the next `_book` adds (the
    /// payee share while `payeeOn`, then `feeToRedeemBurnBps` of the rest to the redeem burn pot, the remainder to the
    /// pot). `msg.value` of the current call is excluded, the same as `Core._income`. the total is conserved across a
    /// `_book`, so a door that books before it checkpoints reads the same pages pot the handler and the views read
    function _ethPagesPot(State storage c) private view returns (uint256) {
        uint256 income = (address(this).balance - msg.value).zeroFloorSub(c.ethPot + c.ethToBuyback + c.ethRedeemBurn);
        if (income == 0) return c.ethPot;
        Settings storage s = c.settings;
        if (c.payeeOn) income -= income * s.payeePpm / 1_000_000;
        return c.ethPot + income - income * s.feeToRedeemBurnBps / BPS;
    }

    /// @notice the floor rate at `nowTs` in wei per credit: the larger of the price state climbed before the pot clamp
    /// and the remembered peak of the eth bid decayed to now. selling credits lowers only the rate and the peak decays
    /// between fills, so the maximum follows the climb and holds against a sale within the block. the engine's price
    /// floors read it through `Core.floorRate`
    function floorRate(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        external
        view
        returns (uint256)
    {
        State storage c = state();
        (uint256 price,, uint256 peakNow) =
            _climb(c.anchor, r, pot, c.settings.rateCap, _ethPagesPot(c), anchorTime, t, nowTs);
        return price.max(peakNow);
    }

    /// @notice the eth instance pages multiplier now, bps (10_000 is 1x): the pages the pot (with the pending fee share)
    /// covers at the last fill rate, clamped to [1x, `climbMultiplierCapBps`]. the Core forwards its `climbMultiplier()`
    function climbMultiplier() external view returns (uint256) {
        State storage c = state();
        return _climbMulBps(_ethPagesPot(c), c.anchor.lastFillRate, c.settings.climbMultiplierCapBps);
    }

    /// @notice the price state, read and peak of a bid instance at `nowTs`, from its stored rate `r` of checkpoint
    /// time `t`. `a` is the instance anchor, `clampTo` its clamp (eth: the pot; balance: available as bps of par),
    /// `capMax` its hard cap (eth: `rateCap`; balance: balanceBidCapBps), `pagesPot` the pot the pages multiplier reads (eth: the
    /// pot with the pending fee share; balance: available as bps of par). the shared climb settings are read from
    /// `state()`. the idle climb (`climbPerMinBps`, `recoveryClimbPerMinBps`) is unscaled; the ceiling's idle loosening
    /// scales by `m`, the pages the pot buys at the last fill rate, clamped to [1, `climbMultiplierCapBps` / 10_000] (decision 128, variant d)
    function _climb(
        Anchor storage a,
        uint256 r,
        uint256 clampTo,
        uint256 capMax,
        uint256 pagesPot,
        uint256 anchorTime,
        uint256 t,
        uint256 nowTs
    ) private view returns (uint256 price, uint256 read, uint256 peakNow) {
        Settings storage s = state().settings;
        peakNow = Halving.halve(a.peakRate, nowTs.zeroFloorSub(a.peakTime), s.peakHalfLife);
        uint256 anchor = a.lastFillRate.max(peakNow);
        uint256 idle = nowTs.zeroFloorSub(anchorTime);
        // the multiplier counts pages at the last fill rate (the rate credits last cleared at), not the climbing stored
        // rate, so it is fixed between fills: a checkpoint never moves the read and the displayed bid matches the paid
        // bid (decision 128, variant d)
        uint256 m = _climbMulBps(pagesPot, a.lastFillRate, s.climbMultiplierCapBps);
        uint256 loosened = 10_000 + uint256(s.idleLoosenBps) * m / BPS * (idle / s.idleStepSeconds);
        uint256 cap = (anchor * loosened * s.ceilBps / 1e8).min(capMax);
        price = r;
        if (r >= cap) {
            price = cap;
        } else if (nowTs > t && r != 0) {
            uint256 target = cap.min(clampTo);
            if (r < target) price = _recover(r, target, t, nowTs, a, s);
        }
        read = price.min(clampTo);
    }

    /// @notice the pot scaled multiplier, bps in [10_000, `capBps`]. `m` is the pages of 80 credits of score refScore
    /// the pages pot buys at the rate `rate`: one page costs `rate * 80`, so pages in bps is `pagesPot.fullMulDiv(BPS / 80, rate)`,
    /// clamped to [1x, `capBps`]. a zero rate reads as 1x. only the ceiling's idle loosening scales by it
    function _climbMulBps(uint256 pagesPot, uint256 rate, uint256 capBps) private pure returns (uint256) {
        if (rate == 0) return BPS;
        uint256 mBps = pagesPot.fullMulDiv(BPS / 80, rate);
        if (mBps < BPS) return BPS;
        if (mBps > capBps) return capBps;
        return mBps;
    }

    /// @notice the price state climbed from `r` at time `t` to `nowTs`, clamped to `target`. Below the recovery level
    /// (`recoveryGapBps` under the decaying peak) the climb is `recoveryClimbPerMinBps` a minute, at or above it
    /// `climbPerMinBps`. The recovery level decays at the peak's rate, so the crossing where the fast climb meets it
    /// is the solution of `r * fast^(s/60) = levelT * 2^(-s/H)`, `crossWadSec = ln(levelT / r) / (lnFast/60 + ln2/H)`
    /// in wad seconds: closed form, linear in log time, so it does not move with the evaluation time. The trajectory is
    /// continuous at the crossing and monotone in `nowTs`. The ceiling clamp can fall as the peak decays, which lowers
    /// the clamped result; the unclamped climb never does
    function _recover(uint256 r, uint256 target, uint256 t, uint256 nowTs, Anchor storage a, Settings storage s)
        private
        view
        returns (uint256)
    {
        // forge-lint: disable-start(unsafe-typecast)
        // the per minute climb is unscaled (decision 128, variant d: the multiplier scales the ceiling loosening only)
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

    /// @notice the rate after one credit of score `score` is bought with the price state `price` at the fill, and the
    /// anchor update of that fill. The fall below `price` is `dropPerCreditBps * score / refScore`, bounded at 10_000,
    /// so the drop tracks the eth spent on the credit. The rate stays at or above `dropFloorBps` of the price state at
    /// the first fill of the current bucket (`nowTs / bucketSeconds`). A `price` already below that floor (restated by
    /// `setRate` or lowered by a bound) starts a new floor at `price`. `price` becomes the last fill rate, and the
    /// remembered peak becomes `max(price, peak now)` with `peakTime` set to `nowTs`
    function drop(uint256 price, uint256 nowTs, uint256 score, uint256 refScore) external returns (uint256) {
        return _drop(state().anchor, price, nowTs, score, refScore, 0);
    }

    /// @notice the rate after one credit of score `score` is bought with the price state `price` of anchor `a`.
    /// `absFloor` is a lower bound on the result: 0 for the eth bid, `10_000 - balanceBidMarginBps` for the balance bid
    function _drop(Anchor storage a, uint256 price, uint256 nowTs, uint256 score, uint256 refScore, uint256 absFloor)
        private
        returns (uint256)
    {
        Settings storage s = state().settings;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 bucket = uint64(nowTs / s.bucketSeconds);
        if (bucket != a.minuteBucket || a.minuteStartRate == 0 || price < a.minuteStartRate * s.dropFloorBps / 10_000) {
            a.minuteBucket = bucket;
            a.minuteStartRate = price;
        }
        a.lastFillRate = price;
        uint256 peakNow = Halving.halve(a.peakRate, nowTs.zeroFloorSub(a.peakTime), s.peakHalfLife);
        a.peakRate = price.max(peakNow);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.peakTime = uint64(nowTs);
        // the fall is `dropPerCreditBps * score / refScore` bps of `price`, bounded at 10_000. one rounding: the rate
        // is `price * (10_000 * refScore - dropPerCreditBps * score) / (10_000 * refScore)` rounded down, so the fall
        // rounds up and a nonzero `dropPerCreditBps` always drops a nonzero amount
        uint256 fallNum = uint256(s.dropPerCreditBps) * score;
        uint256 denom = 10_000 * refScore;
        uint256 dropped = fallNum >= denom ? 0 : price.mulDiv(denom - fallNum, denom);
        return dropped.max(a.minuteStartRate * s.dropFloorBps / 10_000).max(absFloor);
    }

    /// @notice the swap of the coin buyback, run inside the pool manager unlock callback of the Core: exact eth in for
    /// coin on the canonical pool, the eth settled from the Core balance and the coin taken to the Core. returns the eth
    /// spent, skim included, and the coin bought. the pool took no more than it was given. hookData carries the refund
    /// address so the hook credits skim on an unfilled part of the input to the Core in the fee escrow, which
    /// `collectEscrow` books to the pot; an empty refund address reverts the hook on a partial fill
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
        bytes memory hookData =
            abi.encode(SwapData({mevModuleSwapData: abi.encode(address(this)), poolExtensionSwapData: ""}));
        // forge-lint: disable-start(unsafe-typecast)
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookData
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

    /// @notice sends the ERC721 token `id` of `token` that the Core holds to `to` with `transferFrom`. Credits are
    /// refused in every state: a credit enters the pile through `adopt` and leaves the Core at the owner's call only
    /// through `migrate`. A statement leaves only while the Core has no record of it (`Statement.held`), every other
    /// ERC721 leaves. `ownerOf` must answer with the Core, which an ERC20 or an address without code cannot. the Core
    /// forwards its call here untouched, the owner check and the reentrancy guard are here
    function rescueNft(address token, uint256 id, address to) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        if (token == address(CREDITS)) revert NoCreditRescue();
        _enter();
        State storage c = state();
        if (token == Mainnet.STATEMENTS) {
            if (c.statements[id].held) revert Held();
        }
        (bool ok, bytes memory out) = token.staticcall(abi.encodeCall(ICredits.ownerOf, (id)));
        if (!ok || out.length != 32 || abi.decode(out, (address)) != address(this)) revert NotHolder();
        ICredits(token).transferFrom(address(this), to, id);
        _leave();
        emit NftRescued(token, id, to);
    }

    /// @notice puts credits the Core holds without a record into the eth pile, anyone may call. The cost basis of a
    /// credit is the price state at `block.timestamp` (`climb`, before the clamp, no checkpoint is written) times the
    /// credit's score over `refScore`, at least 1 wei. The price state is what the engine pays with a funded
    /// pot, so statements built from adopted credits are priced at that level; the clamp of a thin pot would book a
    /// basis of 1 wei. A donor who inflates the basis of a statement gives credits away. The basis is booked and the
    /// eth pile grows: the rate state and the pots keep their values. `acquiredAt` is the current
    /// time. Reverts `Empty` for an empty list, `ZeroId` for id zero, `InPile` for a credit that is in a pile (the same
    /// id twice included), and `NotHolder` for a credit the Core does not hold. The Core books the fee income, then
    /// forwards its call here untouched, under its own reentrancy guard
    function adopt(uint256[] calldata ids) external {
        if (ids.length == 0) revert Empty();
        State storage c = state();
        (uint256 price,,) = _climb(
            c.anchor,
            c.rateAtCheckpoint,
            c.ethPot,
            c.settings.rateCap,
            _ethPagesPot(c),
            c.lastFillTime,
            c.checkpointTime,
            block.timestamp
        );
        uint256 refScore = c.settings.refScore;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == 0) revert ZeroId();
            if (c.credits[id].inPile) revert InPile();
            if (CREDITS.ownerOf(id) != address(this)) revert NotHolder();
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
            uint256 cost = price.mulDiv(score, refScore).max(1);
            push(c.pile, c.credits, id, cost);
            emit CreditAdopted(id, cost);
        }
    }

    /// @notice sets the successor to which `migrate` sends the assets. the zero address means no migration. reverts
    /// after `lockSuccessor`, and for the Core itself, the balance module, the balance token, the
    /// coin, Credits and Statements. the Core forwards its call here untouched
    function setSuccessor(address next) external {
        _onlyOwner();
        State storage c = state();
        if (c.successorLocked) revert Locked("successor");
        if (next != address(0)) {
            if (next.code.length == 0) revert NoCode(next);
            ICoinOf core = ICoinOf(address(this));
            if (
                next == address(this) || next == c.balanceModule || next == c.balanceToken || next == core.COIN()
                    || next == address(CREDITS) || next == address(STATEMENTS)
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

    /// @notice moves `ethPot` and the credits the Core tracks to the successor, in batches. the Core
    /// forwards its call here untouched, the owner check and the reentrancy guard are here.
    /// the first call sets `retired`, which stays set: `sellForEth`, `buyListing`, `sellForBalance`, `adopt`, `compose`,
    /// `composeChosen` and `swapCredit` then revert `Retired`. logs `EngineRetired` once.
    /// eth: `ethPot`, by `fund()` of the successor, or by a plain send when `fund()` fails, the tracker zeroed.
    /// `ethToBuyback` and `ethRedeemBurn` stay for the coin buyback. eth above the trackers stays.
    /// credits: up to `maxCredits` from the head of the pile, by `transferFrom`, the pile membership cleared (the
    /// cost and arrival time of the record stay). zero moves the pot only.
    /// the held statements and their records stay with the Core, which sells or redeems them itself.
    /// the eth rate is checkpointed before `ethPot` is zeroed. a call with nothing left to move logs zeros
    function migrate(uint256 maxCredits) external {
        _onlyOwner();
        State storage c = state();
        address to = c.successor;
        if (to == address(0)) revert NoSuccessor();
        _enter();
        if (!c.retired) {
            c.retired = true;
            emit EngineRetired(to);
        }
        uint256 eth = _moveEth(c, to);
        uint256 credits = _moveCredits(c, to, maxCredits);
        _leave();
        emit Migrated(to, eth, credits);
    }

    function _moveEth(State storage c, address to) private returns (uint256 eth) {
        eth = c.ethPot;
        if (eth == 0) return 0;
        (c.rateAtCheckpoint,,) = _climb(
            c.anchor,
            c.rateAtCheckpoint,
            eth,
            c.settings.rateCap,
            _ethPagesPot(c),
            c.lastFillTime,
            c.checkpointTime,
            block.timestamp
        );
        c.checkpointTime = uint64(block.timestamp);
        c.ethPot = 0;
        (bool ok,) = to.call{value: eth}(abi.encodeCall(IFund.fund, ()));
        if (!ok) (ok,) = to.call{value: eth}("");
        if (!ok) revert CallFailed();
    }

    /// pops up to `max` credits from the head of the pile
    function _moveCredits(State storage c, address to, uint256 max) private returns (uint256 moved) {
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
    function state() internal pure returns (State storage c) {
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

    /// the credit score of `id` from the CreditScore contract, `scoreOf(seedOf, timestampOf)`, the source every door reads
    function scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// @notice sells the credits `ids` of the caller into the balance token bid. the Core's `sellForBalance` forwards its
    /// call here untouched, under its own reentrancy guard
    function sellForBalance(uint256[] calldata ids) external {
        _sellForBalance(ids, 0);
    }

    /// @notice same as the one argument form with a floor on the total paid
    function sellForBalance(uint256[] calldata ids, uint256 minOut) external {
        _sellForBalance(ids, minOut);
    }

    /// pays each credit `score * unit * rate / 10_000` in balance token, where `unit` is the module's `unitPerPoint()`
    /// read in the call and `rate` is the balance bid, bps of par (par is `score * unit`). the rate is the balance
    /// instance price state, climbed by the eth bid's climb with cap balanceBidCapBps and floored
    /// at `10_000 - balanceBidMarginBps`, dropped per credit by the eth bid's drop. runs only while `balanceBidOn`. the
    /// balance token is held by the module: the running total must not exceed the module's live `available()`
    /// (`PotTooSmall`). the rate clamp `availBps` is the full `available()` as bps of par for a refScore credit, read
    /// once for the batch; a paid rate below the floor `10_000 - balanceBidMarginBps` reverts `PotTooSmall`, so a module
    /// too short to pay the floor closes the bid. the module pays with one `pay(seller, total)`, and the seller's holding
    /// must rise by at least `total` (`BadModule`). the credit enters the single pile with an eth cost basis of
    /// `floorRate * score / refScore`, at least 1 wei (the Core's eth `floorRate()`). a failing, short or zero live unit
    /// read reverts the whole bid (`BadModule`). `refScore` is the Core setting, read from storage
    function _sellForBalance(uint256[] calldata ids, uint256 minOut) private {
        State storage c = state();
        if (c.retired) revert Retired();
        Settings storage s = c.settings;
        if (!s.balanceBidOn) revert BalanceBidOff();
        if (ids.length == 0) revert Empty();
        address module = c.balanceModule;
        if (module == address(0)) revert NoBalanceModule();
        uint256 unit = _liveUnit(module);
        uint256 avail = _liveAvailable(module);
        // the rate clamp: available expressed as bps of par for a refScore credit, read once from full available
        uint256 denom = s.refScore * unit;
        uint256 availBps = _toBps(avail, denom);
        // checkpoint the balance instance: climb to now with the clamp, store the price state so the per credit drops
        // walk down from it. the cap is 10_000, the par ceiling; the pages pot is available as bps of par, uncapped
        _balanceCheckpoint(c.balance, availBps, _toBpsRaw(avail, denom));
        uint256 total = _fillBalance(ids, unit, avail, availBps, _ethFloorNow(c), BPS - s.balanceBidMarginBps);
        if (total < minOut) revert Slippage();
        address token = c.balanceToken;
        uint256 heldBefore = SafeTransferLib.balanceOf(token, msg.sender);
        IBalanceModule(module).pay(msg.sender, total);
        if (SafeTransferLib.balanceOf(token, msg.sender).zeroFloorSub(heldBefore) < total) revert BadModule();
    }

    /// climbs the balance instance to now with clamp `clampTo`, cap balanceBidCapBps and pages pot `pagesPot` and stores the
    /// price state and checkpoint
    function _balanceCheckpoint(Rate storage bal, uint256 clampTo, uint256 pagesPot) private {
        (uint256 price,,) = _climb(
            bal.anchor,
            bal.rateAtCheckpoint,
            clampTo,
            state().settings.balanceBidCapBps,
            pagesPot,
            bal.lastFillTime,
            bal.checkpointTime,
            block.timestamp
        );
        bal.rateAtCheckpoint = price;
        // forge-lint: disable-next-line(unsafe-typecast)
        bal.checkpointTime = uint64(block.timestamp);
    }

    /// the eth bid floor now, the base of a balance sale's recorded eth cost basis: the larger of the eth price state
    /// climbed before the pot clamp and the decayed eth peak. read only
    function _ethFloorNow(State storage c) private view returns (uint256) {
        (uint256 ep,, uint256 epk) = _climb(
            c.anchor,
            c.rateAtCheckpoint,
            c.ethPot,
            c.settings.rateCap,
            _ethPagesPot(c),
            c.lastFillTime,
            c.checkpointTime,
            block.timestamp
        );
        return ep.max(epk);
    }

    /// pays each named credit `score * unit * rate / 10_000` and drops the balance rate per credit, in order. `rate` is
    /// the stored balance rate clamped to `availBps` (available as bps of par). reverts `ZeroAmount` on a zero payout and
    /// `PotTooSmall` once the running total passes `avail`. the credit enters the pile at eth cost basis
    /// `floor * score / refScore`, at least 1 wei. returns the balance token total owed to the seller
    function _fillBalance(
        uint256[] calldata ids,
        uint256 unit,
        uint256 avail,
        uint256 availBps,
        uint256 floor,
        uint256 floorBps
    ) private returns (uint256 total) {
        State storage c = state();
        Rate storage bal = c.balance;
        uint256 refScore = c.settings.refScore;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = owned(ids[i]);
            if (c.creditSaleBlock[id] == block.number) revert SameBlockReturn(id);
            uint256 score = scoreOf(id);
            // the paid rate never falls below the floor: a module too short to pay the floor closes the bid
            uint256 rate = bal.rateAtCheckpoint.min(availBps);
            if (rate < floorBps) revert PotTooSmall();
            uint256 paid = score * unit * rate / BPS;
            if (paid == 0) revert ZeroAmount();
            total += paid;
            if (total > avail) revert PotTooSmall();
            bal.rateAtCheckpoint = _drop(bal.anchor, bal.rateAtCheckpoint, block.timestamp, score, refScore, floorBps);
            // forge-lint: disable-next-line(unsafe-typecast)
            bal.lastFillTime = uint64(block.timestamp);
            uint256 cost = floor.mulDiv(score, refScore).max(1);
            push(c.pile, c.credits, id, cost);
            CREDITS.transferFrom(msg.sender, address(this), id);
            emit CreditBought(id, msg.sender, cost);
            emit BalanceRateFill(paid, bal.rateAtCheckpoint, avail - total);
        }
    }

    /// the balance token amount `avail` as bps of par for a refScore credit, where `denom` is `refScore * unit`. at or
    /// above `denom` the bps reaches the 10_000 cap, so it reads as no clamp; a zero denom reads as no clamp
    function _toBps(uint256 avail, uint256 denom) private view returns (uint256) {
        uint256 cap = state().settings.balanceBidCapBps;
        if (denom == 0) return cap;
        uint256 enough = denom.mulDivUp(cap, BPS);
        return avail >= enough ? cap : avail.mulDiv(BPS, denom);
    }

    /// The multiplier pages pot in bps of par. Saturate only once any allowed last-fill rate reaches the multiplier
    /// cap: ceil(denom * multiplierCap * PAGE * balanceRateCap / BPS squared). The bounded product cannot overflow.
    function _toBpsRaw(uint256 avail, uint256 denom) private view returns (uint256) {
        if (denom == 0) return 0;
        Settings storage cfg = state().settings;
        uint256 maxPages = uint256(cfg.climbMultiplierCapBps) * 80 * cfg.balanceBidCapBps;
        uint256 enough = denom.mulDivUp(maxPages, BPS * BPS);
        return avail.min(enough).mulDiv(BPS, denom);
    }

    /// @notice the balance token bid rate now, bps of par. the Core forwards its `balanceRate()`
    function balanceRate() external view returns (uint256 rate) {
        (rate,) = _balanceRead();
    }

    /// @notice the balance token payout for credit `id` now: `score * unitPerPoint * rate / 10_000`, the rate held at
    /// or above the floor `10_000 - balanceBidMarginBps`. a module too short to pay the floor still reports the floor
    /// payout, which `sellForBalance` refuses with `PotTooSmall`. zero at a zero-rate floor, when no module is set or when the live unit read fails. the Core forwards its `balanceBidOf(id)`
    function balanceBidOf(uint256 id) external view returns (uint256) {
        (uint256 rate, uint256 unit) = _balanceRead();
        if (unit == 0) return 0;
        uint256 floorBps = BPS - state().settings.balanceBidMarginBps;
        if (rate < floorBps) rate = floorBps;
        return scoreOf(id) * unit * rate / BPS;
    }

    /// the balance bid rate (bps of par) and the live unit. with the bid off or no usable module the instance does not
    /// climb and the rate is the floor `10_000 - balanceBidMarginBps`. with the bid on and a usable module it is the
    /// balance instance price state climbed with balanceBidCapBps, clamped to available as bps of par. with no module or a
    /// failed unit read the unit is zero
    function _balanceRead() private view returns (uint256 rate, uint256 unit) {
        State storage c = state();
        uint256 clampTo;
        uint256 pagesPot;
        bool usable;
        address module = c.balanceModule;
        if (module != address(0)) {
            bool ok;
            (unit, ok) = _unitView(module);
            if (ok) {
                uint256 denom = uint256(c.settings.refScore) * unit;
                uint256 avail = _availableView(module);
                clampTo = _toBps(avail, denom);
                pagesPot = _toBpsRaw(avail, denom);
                usable = true;
            }
        }
        if (!c.settings.balanceBidOn || !usable) return (BPS - c.settings.balanceBidMarginBps, unit);
        Rate storage bal = c.balance;
        (, rate,) = _climb(
            bal.anchor,
            bal.rateAtCheckpoint,
            clampTo,
            state().settings.balanceBidCapBps,
            pagesPot,
            bal.lastFillTime,
            bal.checkpointTime,
            block.timestamp
        );
    }

    /// a non reverting bounded read of the controller's `markupBps()`: the start multiplier in bps, or 0 when the
    /// answer is short or outside the 10_000 to uint16.max range. used to bound `saleFloorBps` at or below the start
    function _markupView(address ctrl) private view returns (uint256 markup) {
        bytes4 sel = bytes4(keccak256("markupBps()"));
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, ctrl, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            markup := mload(0)
        }
        if (!ok || markup < 10_000 || markup > type(uint16).max) markup = 0;
    }

    /// a non reverting read of `unitPerPoint()`: (unit, true) on a 32 byte answer in [1, uint128 max], else (0, false)
    function _unitView(address module) private view returns (uint256 unit, bool ok) {
        bytes4 sel = IBalanceModule.unitPerPoint.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok || unit == 0 || unit > type(uint128).max) return (0, false);
    }

    /// a non reverting bounded read of the module `available()`: at most `READ_GAS`, 32 bytes, the amount on a good
    /// answer, else 0
    function _availableView(address module) private view returns (uint256 avail) {
        bytes4 sel = IBalanceModule.available.selector;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            avail := mload(0)
        }
        if (!ok) avail = 0;
    }

    /// a bounded read of the module `available()`: at most `READ_GAS`, 32 bytes returned. a revert or a short answer
    /// reverts `BadModule`
    function _liveAvailable(address module) private view returns (uint256 avail) {
        bytes4 sel = IBalanceModule.available.selector;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            avail := mload(0)
        }
        if (!ok) revert BadModule();
    }

    /// gas of the bounded `unitPerPoint` and `available` reads of the balance module
    uint256 internal constant READ_GAS = 200_000;

    /// bounded read of `unitPerPoint()` of `module`: at most `READ_GAS`, exactly 32 bytes returned or more (a long
    /// answer is cut off). a revert, a short answer, a zero unit or a unit above `type(uint128).max` reverts `BadModule`
    function _liveUnit(address module) private view returns (uint256 unit) {
        bytes4 sel = IBalanceModule.unitPerPoint.selector;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok || unit == 0 || unit > type(uint128).max) revert BadModule();
    }
}

interface ICoinOf {
    function COIN() external view returns (address);
}

interface IFund {
    function fund() external payable;
}
