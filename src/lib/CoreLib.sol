// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {
    IController,
    ICredits,
    ICreditScore,
    ICoin,
    IBalanceModule,
    IStatements,
    Settings,
    Mainnet,
    RATE_SCORE
} from "../interfaces/Interfaces.sol";
import {Halving} from "./Halving.sol";
import {SettingsBounds} from "./SettingsBounds.sol";

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
    /// time since which the booked pot has covered the last-fill bid for 100 points and its artist payment
    uint64 climbRestartTime;
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
    /// whether the owner pause blocks acquisitions, composition, sales, Credit swaps and buybacks
    bool paused;
    /// when the open pause began, 0 while not paused
    uint40 pausedSince;
    /// seconds of every closed pause
    uint40 pausedTotal;
    /// the caller of the `compose` or `composeChosen` that made each statement, kept after the statement is sold
    mapping(uint256 => address) composerOf;
    /// the address the payee fee share and the operator cut of nft sales are pushed to
    address payee;
    /// the address receiving artist sale cuts and purchase royalties, set by `setArtist`
    address artist;
    /// true once the payee share runs. set by the first `_book` with income at or after `launchedAt + settings.sniperSeconds`,
    /// which shares nothing. one way
    bool payeeOn;
    /// the economic settings, five packed slots
    Settings settings;
    /// the eth bid anchor state, four words
    CoreLib.Anchor anchor;
    /// value mode's shared eth instance, a `Rate`: its own stored rate, checkpoint, fill time and anchor. the rate
    /// is bps of par, bounded to [10_000 - balanceBidMarginBps, balanceBidCapBps]; module availability scales its
    /// pages multiplier, not its clamp. `sharedRate()` reads it. the posted balance bid does not read or move it
    /// (decision 164). the climb and drop are the eth bid's, shared through CoreLib
    CoreLib.Rate balance;
    /// the last `sellCreditTo` per credit id, the buyer packed in the high 160 bits and the sale time in the low 96,
    /// kept after the credit leaves the pile. every intake door (`sellForEth`, `sellForBalance`, `buyListing`,
    /// `swapCredit` as `inId`) refuses the credit for `returnLockSeconds` from the sale when the counterparty returning
    /// it is that buyer (`checkReturn`); a secondary holder is not the buyer and is not locked
    mapping(uint256 => uint256) creditSoldAt;
    /// the ETH purchase budget of the current bucket, charged by every ETH purchase door
    CoreLib.Spend spend;
    /// every module and token a `setBalanceModule` has ever selected. a replaced module or token stays here, so it
    /// remains a forbidden target after it stops being the live module or token
    mapping(address => bool) everBalanceTarget;
}

/// the Core's pricing and accounting library: settings validation and writes, the eth bid and its ceiling, and the
/// sale of Credits into the balance token bid. CoreOpsLib holds the pool swap and low-frequency operations.
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

    /// one bid instance's price state: the stored rate at its checkpoint, the checkpoint and last fill times, and
    /// its anchor. the mode-off eth bid keeps these fields inline in `State` at their fixed slots; value mode uses
    /// the appended `State.balance` instance. the shared climb and drop take the anchor and the instance cap and
    /// floor, so one body serves both
    struct Rate {
        uint256 rateAtCheckpoint;
        uint64 checkpointTime;
        uint64 lastFillTime;
        Anchor anchor;
    }

    struct Spend {
        /// `timestamp / bucketSeconds` of the bucket this record belongs to
        uint64 spendBucket;
        /// whether a purchase has opened a bucket
        bool initialized;
        /// `snapshotPot * spendCapBps / 10_000`, wei
        uint128 spendBudget;
        /// wei spent in the bucket
        uint128 spentInBucket;
        /// `ethPot` at the first purchase of the bucket
        uint256 snapshotPot;
    }

    uint256 internal constant BPS = 10_000;
    /// credits in one statement page, the unit of the queued compose payments of the reserve
    uint256 internal constant PAGE = 80;
    /// gas the controller's `valuePerPoint` may use in value mode: its reads of the settings, the module unit and the
    /// pool's slot 0 and liquidity
    uint256 internal constant QUOTE_GAS = 2_000_000;
    /// gas of one queued compose and one queued redemption the reserve prices at `callerMaxBaseFee`
    uint256 internal constant COMPOSE_QUEUE_GAS = 9_000_000;
    uint256 internal constant REDEEM_QUEUE_GAS = 600_000;
    /// the work before the count in `refreshReference` with the transaction base cost, and the most gas its caller
    /// payment counts
    uint256 internal constant REFRESH_OVERHEAD_GAS = 50_000;
    uint256 internal constant REFRESH_GAS = 200_000;
    /// gas bound for the non-blocking artist royalty `pay` on the balance route: the module bookkeeping and an
    /// ERC20 transfer to a cold wallet with a blacklist check (299,581 gas measured on the pinned token, 117,757
    /// warm). a failed token transfer within the production module accrues a liability; a reverted whole call
    /// cannot accrue one
    uint256 internal constant ARTIST_PAY_GAS = 600_000;
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
    /// `sellForBalance(ids, minOut, expectedToken)` when `balanceToken()` differs from `expectedToken`
    error BalanceTokenChanged();
    /// a credit the engine sold through `sellCreditTo` is offered back to an intake door by its buyer before `until`
    error ReturnLocked(uint256 id, uint256 until);
    /// retained for ABI compatibility; ETH quote failures now fall back to the last good value rate
    error NoQuote();
    /// one eth fill in value mode: the eth paid, the shared instance rate (bps of par) after this credit's drop, and the
    /// pot left. mirrors `EthRateFill`
    event ValueRateFill(uint256 spent, uint256 rateBps, uint256 pot);
    event CreditBought(uint256 indexed id, address indexed from, uint256 cost, uint256 toArtist);
    /// a pile credit was swapped for one of equal or higher score for a coin fee burned by the caller
    event CreditSwapped(uint256 indexed inId, uint256 indexed outId, address indexed caller, uint256 fee);
    error Paused();
    error NotInPile(uint256 id);
    error ScoreTooLow(uint256 inId, uint256 outId);
    /// one mode-off ETH fill: ETH spent including royalty, the post-drop rate in wei per 100 points, and the pot
    /// left
    event EthRateFill(uint256 spent, uint256 rate, uint256 pot);
    /// one balance fill: the balance token paid to the seller for this credit, the artist royalty, and `available()`
    /// left after both (decisions 163, 164)
    event BalanceFill(uint256 paid, uint256 toArtist, uint256 available);
    error BadSetting(bytes32 field);
    event SettingsSet(Settings settings);
    /// value mode's shared eth instance was reset to `rateBps` (bps of par), its floor, on a margin raise or the value
    /// switch turning on. the posted balance bid does not use this instance
    event BalanceRateSet(uint256 rateBps);
    error ZeroAddress();
    error ForbiddenTarget();
    error OnlyOwner();
    event CoinRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ArtistSet(address indexed artist);
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
    /// under the library selector, after checkpointing the active ETH rate. the constructor calls it too. the
    /// shared instance is checkpointed here only when the old settings have value mode on. a change of
    /// `peakHalfLife` restates both remembered peaks at the old half life before storing the new one, so the new
    /// half life decays the peaks forward only
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        // value mode bounds dump volume with the drop, but the eth route keeps the spend cap as its incident bound: the
        // cap must be active (under 10_000, not the bypass) whenever the value switch is on
        if (ns.valueModeOn && ns.spendCapBps >= BPS) revert BadSetting("spendCapBps");
        State storage c = state();
        // the artist cut is never nonzero while the artist is the zero address, so a sale never pushes it to address(0).
        // the constructor sets the artist before its own call here, so the launch config must carry a real artist
        if ((ns.saleToArtistBps != 0 || ns.buyToArtistBps != 0) && c.artist == address(0)) revert ZeroAddress();
        // the sale floor can never be above the start: with a controller set, bound `saleFloorBps` at or below its
        // `markupBps`. a controller that does not answer in range is skipped; the controller's own setter guards the
        // other direction
        address ctrl = c.controller;
        if (ctrl != address(0)) {
            uint256 markup = _markupView(ctrl);
            if (markup != 0 && ns.saleFloorBps > markup) revert BadSetting("saleFloorBps");
        }
        bool wasValue = c.settings.valueModeOn;
        // credit the elapsed climb of the shared instance under the old settings and clamp before the new ones apply,
        // so a settings change compares against the climbed value, not a stale checkpoint. the instance climbs in value
        // mode only: outside it no bid reads it (decision 164)
        if (wasValue) _balanceCheckpointNow(c);
        uint256 oldHalf = c.settings.peakHalfLife;
        if (oldHalf != 0 && ns.peakHalfLife != oldHalf) {
            _restatePeak(c.anchor, oldHalf);
            _restatePeak(c.balance.anchor, oldHalf);
        }
        _updateSpendSettings(c, ns);
        c.settings = ns;
        if (c.balance.rateAtCheckpoint > ns.balanceBidCapBps) c.balance.rateAtCheckpoint = ns.balanceBidCapBps;
        uint256 floor = BPS - ns.balanceBidMarginBps;
        // Turning value mode on resets the shared instance to its floor. Otherwise only a stored rate below the
        // floor resets; equality preserves its clock. The posted balance bid never moves this instance.
        if (ns.valueModeOn && !wasValue) _resetBalanceToFloor(c, floor);
        else _resetBalanceToFloorIfBelow(c, floor);
        // leaving value mode: seed the eth instance from the current value rate, or the stored last good value rate.
        // with neither available use 1 wei, so the mode-off bid cannot reopen at a stale high rate
        if (wasValue && !ns.valueModeOn) {
            (uint256 vr, bool okv) = _valueRate(c);
            // the quote, else the last good value rate kept in the idle eth instance; 1 wei if neither is known
            uint256 target = okv ? vr : c.rateAtCheckpoint;
            if (target == 0) target = 1;
            // mirror `setRate`: the stored rate, the last fill rate and the remembered peak all become `target` with a
            // fresh peak and checkpoint time, so the eth bid resumes from `target` and climbs the ceiling from there
            c.anchor.lastFillRate = target;
            c.anchor.peakRate = target;
            c.rateAtCheckpoint = target;
            // forge-lint: disable-next-line(unsafe-typecast)
            c.anchor.peakTime = uint64(block.timestamp);
            // forge-lint: disable-next-line(unsafe-typecast)
            c.checkpointTime = uint64(block.timestamp);
            c.climbRestartTime = uint64(block.timestamp);
        }
        emit SettingsSet(ns);
    }

    /// a settings edit keeps the wei spent in the live bucket and recomputes its budget from `snapshotPot` at the new cap.
    /// a bucket that already ended is cleared, a live one moves to its bucket id under the new `bucketSeconds`
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

    /// moves the anchor of a live bucket to its bucket id under the new `bucketSeconds`. an anchor whose bucket ended
    /// clears its opening rate, which the next fill sets
    function _rebaseBucket(Anchor storage a, uint64 oldBucket, uint256 seconds_) private {
        uint64 next = SafeCastLib.toUint64(block.timestamp / seconds_);
        if (a.minuteBucket != oldBucket) a.minuteStartRate = 0;
        a.minuteBucket = next;
    }

    /// books an ETH credit purchase of `cost` after the Core checkpoints: charges the bucket budget, drops the rate and
    /// debits the pot. `sellForEth` and `buyListing` call it per credit. a cost above `ethPot` less the reserve reverts
    /// `PotTooSmall`. the first purchase of a bucket always passes, a later purchase reverts `SpendCapReached` when the
    /// spent total would exceed the budget
    function spend(uint256 cost, uint256 score) external {
        State storage c = state();
        uint256 pot = c.ethPot;
        if (cost == 0) revert ZeroAmount();
        if (cost > pot.zeroFloorSub(_reserve(c))) revert PotTooSmall();
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
        if (cfg.spendCapBps != BPS && b.spentInBucket != 0 && total > b.spendBudget) {
            revert SpendCapReached(b.spentInBucket, cost, b.spendBudget);
        }
        b.spentInBucket = SafeCastLib.toUint128(total);
        if (cfg.valueModeOn) {
            // value mode: the fill drops the shared instance, climbed to now, never under its floor; the eth instance is
            // left as it is
            Rate storage bal = c.balance;
            uint256 bps = _sharedRead(c);
            uint256 next = _drop(bal.anchor, bps, block.timestamp, score, BPS - cfg.balanceBidMarginBps);
            bal.rateAtCheckpoint = next;
            // forge-lint: disable-start(unsafe-typecast)
            bal.checkpointTime = uint64(block.timestamp);
            bal.lastFillTime = uint64(block.timestamp);
            // forge-lint: disable-end(unsafe-typecast)
            c.ethPot = pot - cost;
            emit ValueRateFill(cost, next, pot - cost);
            return;
        }
        uint256 rate = _drop(c.anchor, c.rateAtCheckpoint, block.timestamp, score, 0);
        c.rateAtCheckpoint = rate;
        c.lastFillTime = SafeCastLib.toUint64(block.timestamp);
        c.ethPot = pot - cost;
        emit EthRateFill(cost, rate, pot - cost);
    }

    /// the bucket id, budget and spent wei of the current bucket. a bucket a purchase has opened returns its stored
    /// budget and spent. a fresh bucket quotes `spendCapBps` of the pages pot (`ethPot` plus the pot share of the
    /// unbooked fee income the next `_book` adds), the pot the first purchase of the bucket books and snapshots, so the
    /// quote equals the budget the next purchase enforces (decision 147)
    function spendState() external view returns (uint64 bucket, uint128 budget, uint128 spent) {
        State storage c = state();
        bucket = SafeCastLib.toUint64(block.timestamp / c.settings.bucketSeconds);
        Spend storage b = c.spend;
        if (b.initialized && b.spendBucket == bucket) return (bucket, b.spendBudget, b.spentInBucket);
        return (bucket, SafeCastLib.toUint128(_ethPagesPot(c).mulDiv(c.settings.spendCapBps, BPS)), 0);
    }

    /// Restates a peak under the old half life. Paused time never decays the peak, including an owner settings edit.
    function _restatePeak(Anchor storage a, uint256 oldHalf) private {
        State storage c = state();
        uint256 t = c.paused ? c.pausedSince : block.timestamp;
        a.peakRate = Halving.halve(a.peakRate, t.zeroFloorSub(a.peakTime), oldHalf);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.peakTime = uint64(t);
    }

    /// checkpoints value mode's shared instance under the old settings before `setSettings` replaces them
    function _balanceCheckpointNow(State storage c) private {
        _balanceCheckpoint(c.balance, c.settings.balanceBidCapBps, _sharedPagesPot(c));
    }

    /// the pages pot of the shared instance in value mode: the module's `available()` as bps of par, 0 without a usable
    /// module
    function _sharedPagesPot(State storage c) private view returns (uint256) {
        address module = c.balanceModule;
        if (module == address(0)) return 0;
        (uint256 unit, bool ok) = _unitView(module);
        return ok ? _toBpsRaw(_availableView(module), RATE_SCORE * unit) : 0;
    }

    /// the shared instance now in value mode, bps of par: the price state climbed with the cap as its clamp and the
    /// pages pot of `_sharedPagesPot`. read only; value mode's eth bid is this times the controller's value per point
    function _sharedRead(State storage c) private view returns (uint256 rate) {
        Rate storage bal = c.balance;
        uint256 cap = c.settings.balanceBidCapBps;
        (rate,) = _climb(
            bal.anchor,
            bal.rateAtCheckpoint,
            cap,
            cap,
            _sharedPagesPot(c),
            bal.lastFillTime,
            bal.checkpointTime,
            block.timestamp
        );
    }

    /// resets value mode's shared ETH instance to `floor` when its stored rate is below `floor`
    function _resetBalanceToFloorIfBelow(State storage c, uint256 floor) private {
        if (c.balance.rateAtCheckpoint >= floor) return;
        _resetBalanceToFloor(c, floor);
    }

    /// resets value mode's shared ETH instance to `floor`: the rate, the fill clock and the whole anchor start at
    /// `floor`. the climb heads up from there, the drop never falls under it
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

    /// @notice checkpoints the eth instance: stores the price state climbed to now and the time. the Core calls it before
    /// a pot grows or a rate is spent, so no climb is credited under a later pot
    function checkpoint() external {
        _checkpointNow(state());
    }

    function _checkpointNow(State storage c) private {
        if (c.settings.valueModeOn) {
            // value mode prices the eth bid off the shared instance, so the eth instance is idle. keep its stored rate as
            // the last good value mode eth rate: the balance sale cost basis reads it when the quote is momentarily down,
            // and the switch off reset resumes from it. a down quote leaves the previous good rate in place
            (uint256 vr, bool okv) = _valueRate(c);
            if (okv) c.rateAtCheckpoint = vr;
        } else {
            bool paused;
            (c.rateAtCheckpoint,, paused) = _ethClimb(c);
            // A book or fund checkpoints before the pot grows. The new ETH must not inherit time spent unable to pay
            // the last-fill bid for 100 points and its artist payment.
            if (paused) c.climbRestartTime = uint64(block.timestamp);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        c.checkpointTime = uint64(block.timestamp);
    }

    /// @notice the keeper's reference refresh door: forwards to the controller's refresh and, when it ran, pays the
    /// caller like compose, bounded by the pot and the caller base-fee ceiling. the Core books the pending fee income
    /// before forwarding here, so the payment comes from the pot share of that income (decision 159, C02). runs in the
    /// Core's storage context by delegatecall (the `_toLib` door forwards to it)
    function refreshReference() external {
        uint256 gasStart = gasleft();
        State storage c = state();
        address ctrl = c.controller;
        if (ctrl == address(0)) return;
        if (!IController(ctrl).refreshReference()) return;
        Settings storage cfg = c.settings;
        if (cfg.callerMaxBaseFee == 0 && cfg.callerFee == 0) return;
        // The Core checkpointed the mode-off bid before this payment can lower its funding room.
        uint256 pay = ((gasStart - gasleft() + REFRESH_OVERHEAD_GAS).min(REFRESH_GAS)
                * block.basefee.min(cfg.callerMaxBaseFee) + cfg.callerFee)
        .min(c.ethPot);
        if (pay == 0) return;
        c.ethPot -= pay;
        SafeTransferLib.safeTransferETH(msg.sender, pay);
    }

    /// @notice the eth bid rate now, wei per 100 points: the price state lowered to the royalty-adjusted room from
    /// `ethPot` plus the pending pot share less the reserve. in value mode the price state is `_valueRate`, falling back to the last good value
    /// rate while the quote is unusable. the Core forwards `ethRate`, `bidForScore`, `ethPerPoint` and `bidOf` and its
    /// doors read it
    function ethRate() external view returns (uint256 read) {
        State storage c = state();
        if (!c.settings.valueModeOn) {
            (uint256 price,,) = _ethClimb(c);
            read = price.min(_bidRoom(c));
            return read;
        }
        return _valueRateOrLast(c).min(_bidRoom(c));
    }

    /// @notice the eth price state now, wei per 100 points, before the clamp; in value mode the value rate, falling back
    /// to the last good value rate while the quote is unusable. the Core forwards its `ethPrice()`
    function ethPrice() external view returns (uint256) {
        return _ethPrice(state());
    }

    /// the eth price state now: the eth instance outside value mode, the value rate (or the last good one) in value mode
    function _ethPrice(State storage c) private view returns (uint256 price) {
        if (c.settings.valueModeOn) return _valueRateOrLast(c);
        (price,,) = _ethClimb(c);
    }

    /// the value mode eth price state now: the controller's value read when usable, else the last good value mode eth
    /// rate kept in the eth instance checkpoint. a lapsed or unusable quote degrades the eth bid instead of reverting
    /// `NoQuote`, so the engine keeps buying while the reference recovers (decision 159, C02)
    function _valueRateOrLast(State storage c) private view returns (uint256) {
        (uint256 rate, bool ok) = _valueRate(c);
        // the fallback is the last good value rate, itself stored at or under `rateCap` by `_valueRate`
        return ok ? rate : c.rateAtCheckpoint;
    }

    /// the value mode eth rate, wei per 100 points: the shared instance climbed to now (clamped to the cap, not to the
    /// funds) times 100 times the controller's value per point at the buy price, over 10_000, at most `rateCap`. `ok` is
    /// false while the controller's bounded read fails, answers short, answers a false flag or a zero value. a hostile
    /// controller quoting a huge value pays at most `rateCap`
    function _valueRate(State storage c) private view returns (uint256 rate, bool ok) {
        uint256 v;
        (v, ok) = _quoteRead(abi.encodeCall(IController.valuePerPoint, (false)));
        if (!ok || v == 0) return (0, false);
        // the cap keeps the product inside 256 bits; any value above it pays `rateCap` anyway
        if (v > type(uint128).max) v = type(uint128).max;
        uint256 bps = _sharedRead(c);
        rate = (bps * v * 100 / BPS).min(c.settings.rateCap);
    }

    /// a bounded static read of a controller view returning (uint256, bool): the value in the first word, a true flag in
    /// the second. `ok` is false on a failed call, a short answer or a false flag. at most `QUOTE_GAS` gas, so a hostile
    /// controller cannot consume the caller's gas or revert the door
    function _quoteRead(bytes memory input) private view returns (uint256 v, bool ok) {
        address ctrl = state().controller;
        assembly ("memory-safe") {
            ok := staticcall(QUOTE_GAS, ctrl, add(input, 0x20), mload(input), 0, 0x40)
            ok := and(ok, iszero(lt(returndatasize(), 0x40)))
            v := mload(0)
            ok := and(ok, eq(mload(0x20), 1))
        }
    }

    /// the posted balance payout `pay` for `score` stored units lowered to the controller's `balanceClampFor`: the eth
    /// bid for the score valued in tokens at the protected sale price, so a filled payout is worth at most the eth bid
    /// when the engine sells the tokens and a round trip cannot extract a spot that leads the reference.
    /// returns `pay` outside value mode. in value mode a failed or malformed bounded read returns zero, so the fill
    /// reverts `ZeroAmount`; a successful answer cannot raise the posted payout
    function _clampPayout(uint256 score, uint256 pay) private view returns (uint256) {
        if (!state().settings.valueModeOn) return pay;
        (uint256 out, bool ok) = _quoteRead(abi.encodeCall(IController.balanceClampFor, (score, pay)));
        return ok ? out.min(pay) : 0;
    }

    /// @notice the eth the pot keeps for processing now, wei. the Core forwards its `reserve()`
    function reserve() external view returns (uint256) {
        return _reserve(state());
    }

    /// @notice `ethPot` less the reserve, the most an eth purchase may spend now. `buyListing` checks its quote against it
    function room() external view returns (uint256) {
        State storage c = state();
        return c.ethPot.zeroFloorSub(_reserve(c));
    }

    /// the eth instance price state and peak at now. booked ETH above the reserve funds the climb; the separate read
    /// may also use pending fee income, which has no known arrival time and earns no prior climb. when the
    /// booked room cannot pay the last-fill bid for 100 points plus the artist payment, the funded climb and idle
    /// loosening pause; peak decay follows wall time outside an owner pause. the normal ceiling, recovery rate and
    /// rateCap still bind
    function _ethClimb(State storage c) private view returns (uint256 price, uint256 peakNow, bool paused) {
        uint256 bookedRoom = _bookedBidRoom(c);
        paused = bookedRoom < c.anchor.lastFillRate;
        (price, peakNow) = _climb(
            c.anchor,
            c.rateAtCheckpoint,
            bookedRoom,
            c.settings.rateCap,
            c.ethPot,
            paused ? block.timestamp : uint256(c.lastFillTime).max(c.climbRestartTime),
            paused ? block.timestamp : c.checkpointTime,
            block.timestamp
        );
    }

    function _bookedBidRoom(State storage c) private view returns (uint256) {
        return _roomAt(c, c.ethPot);
    }

    /// the clamp of the eth bid: the pages pot less the reserve, over `1 + buyToArtistBps / 10_000`, so a bid the read
    /// shows is payable with its artist royalty on top (decision 163). the funded climb uses the same adjustment on
    /// booked ETH alone
    function _bidRoom(State storage c) private view returns (uint256) {
        return _roomAt(c, _ethPagesPot(c));
    }

    function _roomAt(State storage c, uint256 pot) private view returns (uint256) {
        return pot.zeroFloorSub(_reserve(c)).mulDiv(BPS, BPS + c.settings.buyToArtistBps);
    }

    /// the eth the pot keeps for processing: the larger of `reserveWei` and 1.5 times the queued caller payments, one
    /// compose per full page of the pile at `COMPOSE_QUEUE_GAS` and one redemption per held statement at
    /// `REDEEM_QUEUE_GAS`, each gas at `callerMaxBaseFee` plus `callerFee`. the bids and the eth rate read `ethPot` less it;
    /// the caller payments, the buyback and the pushes pay from the whole pot
    function _reserve(State storage c) private view returns (uint256) {
        Settings storage s = c.settings;
        uint256 base = s.callerMaxBaseFee;
        uint256 fee = s.callerFee;
        uint256 queued =
            c.pile.size / PAGE * (COMPOSE_QUEUE_GAS * base + fee) + c.heldIds.length * (REDEEM_QUEUE_GAS * base + fee);
        return uint256(s.reserveWei).max(queued * 15 / 10);
    }

    /// reverts `ReturnLocked` while credit `id` is offered back by the buyer the engine sold it to, before
    /// `soldAt + returnLockSeconds`. `creditSoldAt[id]` packs that buyer in the high 160 bits and the sale time in the
    /// low 96. the lock binds only when `counterparty` is the stored buyer, so a secondary holder who bought the credit
    /// from the engine's buyer sells at once. a `returnLockSeconds` of 0, a word of 0 (never sold), or a counterparty
    /// other than the buyer passes at any clock. every intake door calls it per credit with the counterparty:
    /// `msg.sender` for `sellForEth`, `sellForBalance` and `swapCredit`, the listing offerer for `buyListing`
    function checkReturn(State storage c, uint256 id, address counterparty) internal view {
        uint256 lock = c.settings.returnLockSeconds;
        if (lock == 0) return;
        uint256 word = c.creditSoldAt[id];
        if (word == 0) return;
        if (counterparty != address(uint160(word >> 96))) return;
        uint256 until = uint96(word) + lock;
        if (block.timestamp < until) revert ReturnLocked(id, until);
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

    /// @notice the floor rate now in wei per 100 points: the larger of the price state climbed before the clamp and
    /// the remembered peak of the eth bid decayed to now. selling credits lowers only the rate and the peak decays
    /// between fills, so the maximum follows the climb and holds against a sale within the block. the engine's price
    /// floors read it through `Core.floorRate`
    function floorRate() external view returns (uint256) {
        (uint256 price, uint256 peakNow,) = _ethClimb(state());
        return price.max(peakNow);
    }

    /// @notice the eth instance pages multiplier now, bps (10_000 is 1x): the pages the booked pot
    /// covers at the last fill rate, clamped to [1x, `climbMultiplierCapBps`]. the Core forwards its `climbMultiplier()`
    function climbMultiplier() external view returns (uint256) {
        State storage c = state();
        return _climbMulBps(
            c.ethPot, c.anchor.lastFillRate, c.settings.pointsPerPage, c.settings.climbMultiplierCapBps
        );
    }

    /// @notice the price state and peak of a bid instance at `nowTs`, from its stored rate `r` of checkpoint
    /// time `t`. the mode-off instance uses royalty-adjusted booked ETH room as `clampTo`, `rateCap` as `capMax`, and the
    /// booked ETH pot as `pagesPot`. the shared value instance uses `balanceBidCapBps` for both
    /// bounds and module availability in bps of par for `pagesPot`. the shared climb settings are read from
    /// `state()`. the idle climb (`climbPerMinBps`, `recoveryClimbPerMinBps`) is unscaled; the ceiling's idle
    /// loosening scales by `m`, the pages the pot buys at the last fill rate, clamped to [1,
    /// `climbMultiplierCapBps` / 10_000] (decision 128, variant d)
    function _climb(
        Anchor storage a,
        uint256 r,
        uint256 clampTo,
        uint256 capMax,
        uint256 pagesPot,
        uint256 anchorTime,
        uint256 t,
        uint256 nowTs
    ) private view returns (uint256 price, uint256 peakNow) {
        State storage c = state();
        Settings storage s = c.settings;
        uint256 growthNow = c.paused ? c.pausedSince : nowTs;
        peakNow = Halving.halve(a.peakRate, growthNow.zeroFloorSub(a.peakTime), s.peakHalfLife);
        uint256 anchor = a.lastFillRate.max(peakNow);
        uint256 idle = growthNow.zeroFloorSub(anchorTime);
        // the multiplier is the pot divided by the pages the last fill rate affords, clamped to [BPS, cap]. the last
        // fill rate is the denominator and holds between fills, so a checkpoint that climbs the stored rate leaves it
        // unchanged; the pot numerator moves as `fund` and sale booking change `pagesPot`, so the multiplier tracks the
        // pot between fills (decision 128, variant d)
        uint256 m = _climbMulBps(pagesPot, a.lastFillRate, s.pointsPerPage, s.climbMultiplierCapBps);
        uint256 loosened = 10_000 + uint256(s.idleLoosenBps) * m / BPS * (idle / s.idleStepSeconds);
        uint256 cap = (anchor * loosened * s.ceilBps / 1e8).min(capMax);
        price = r;
        if (r >= cap) {
            price = cap;
        } else if (growthNow > t && r != 0) {
            uint256 target = cap.min(clampTo);
            if (r < target) price = _recover(r, target, t, growthNow, a, s);
        }
    }

    /// @notice the pot scaled multiplier, bps in [10_000, `capBps`]. `m` is the pages the pages pot buys at the rate
    /// `rate`: one page is `pointsPerPage` points and costs `rate * pointsPerPage / 100`, so pages in bps is
    /// `pagesPot.fullMulDiv(BPS * 100, rate * pointsPerPage)`, clamped to [1x, `capBps`]. a zero rate reads as 1x. only
    /// the ceiling's idle loosening scales by it
    function _climbMulBps(uint256 pagesPot, uint256 rate, uint256 pointsPerPage, uint256 capBps)
        private
        pure
        returns (uint256)
    {
        if (rate == 0) return BPS;
        uint256 mBps = pagesPot.fullMulDiv(BPS * 100, rate * pointsPerPage);
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

    /// @notice the rate after one credit of score `score` is bought with the price state `price` at the fill, and
    /// the anchor update of that fill. The fall below `price` is `dropPer100PointsBps * score / RATE_SCORE`,
    /// bounded at 10_000, so the drop tracks the eth spent on the credit. The rate stays at or above `dropFloorBps`
    /// of the price state at the first fill of the current bucket (`nowTs / bucketSeconds`). A `price` already
    /// below that floor (restated by `setRate` or lowered by a bound) starts a new floor at `price`. `price`
    /// becomes the last fill rate, and the remembered peak becomes `max(price, peak now)` with `peakTime` set to
    /// `nowTs` `absFloor` is a lower bound on the result: 0 for the eth bid, `10_000 - balanceBidMarginBps` for
    /// value mode's shared eth instance
    function _drop(Anchor storage a, uint256 price, uint256 nowTs, uint256 score, uint256 absFloor)
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
        // the fall is `dropPer100PointsBps * score / RATE_SCORE` bps of `price`, bounded at 10_000. one rounding: the
        // rate is `price * (10_000 * RATE_SCORE - dropPer100PointsBps * score) / (10_000 * RATE_SCORE)` rounded down, so
        // the fall rounds up and a nonzero `dropPer100PointsBps` always drops a nonzero amount
        uint256 fallNum = uint256(s.dropPer100PointsBps) * score;
        uint256 denom = 10_000 * RATE_SCORE;
        uint256 dropped = fallNum >= denom ? 0 : price.mulDiv(denom - fallNum, denom);
        return dropped.max(a.minuteStartRate * s.dropFloorBps / 10_000).max(absFloor);
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

    /// @notice sends `amount` of the ERC20 `token` the Core holds to `to`. every forbidden target is refused, the
    /// current and past balance tokens and modules included, and tracked eth is not an ERC20, so a stray token is
    /// recovered and nothing the engine accounts for can leave (decision 159, C06). the Core forwards its call here
    /// untouched; the owner check is here. no reentrancy guard: it transfers a token the Core does not track and does
    /// nothing after the transfer, so a token callback changes nothing here and any Core door it re-enters is guarded
    function rescueToken(address token, address to, uint256 amount) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        if (_forbidden(token)) revert ForbiddenTarget();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice sets the address the artist cut of nft sales and the artist royalty on purchases are pushed to. the zero
    /// address is refused while `saleToArtistBps` or `buyToArtistBps` is nonzero, and a forbidden target is always
    /// refused. the Core forwards its call here untouched; the owner check is here
    function setArtist(address to) external {
        _onlyOwner();
        State storage c = state();
        if (to == address(0)) {
            if (c.settings.saleToArtistBps != 0 || c.settings.buyToArtistBps != 0) revert ZeroAddress();
        } else if (_forbidden(to)) {
            revert ForbiddenTarget();
        }
        c.artist = to;
        emit ArtistSet(to);
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
    /// credit is the price state at `block.timestamp` (`climb`, before the clamp) times the
    /// credit's score over 100 points, plus the artist royalty `buyToArtistBps` the eth bid would pay, at least 1 wei,
    /// so the sale floor matches a bought credit (decision 163). The price state is what the engine pays with a funded
    /// pot, so statements built from adopted credits are priced at that level; the clamp of a thin pot would book a
    /// basis of 1 wei. A donor who inflates the basis of a statement gives credits away. The basis is booked and the
    /// eth pile grows; the Core checkpoints before the reserve may rise. `acquiredAt` is the current
    /// time. Reverts `Empty` for an empty list, `ZeroId` for id zero, `InPile` for a credit that is in a pile (the same
    /// id twice included), and `NotHolder` for a credit the Core does not hold. The Core books the fee income, then
    /// forwards its call here untouched, under its own reentrancy guard
    function adopt(uint256[] calldata ids) external {
        if (ids.length == 0) revert Empty();
        State storage c = state();
        uint256 price = _ethPrice(c);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == 0) revert ZeroId();
            if (c.credits[id].inPile) revert InPile();
            if (CREDITS.ownerOf(id) != address(this)) revert NotHolder();
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
            // record the price plus its artist royalty, as a bought credit does, so the adopted credit's sale floor
            // covers the royalty the eth bid would have paid (decision 163)
            uint256 pay = price.mulDiv(score, RATE_SCORE);
            uint256 cost = (pay + pay * c.settings.buyToArtistBps / BPS).max(1);
            push(c.pile, c.credits, id, cost);
            emit CreditAdopted(id, cost);
        }
    }

    /// @notice swaps pile credit `outId` for `inId` of equal or higher score, for a `swapFeeCc` coin fee the caller
    /// burns. `inId` takes `outId`'s pile node: the same order position, cost basis and acquisition time, so the
    /// pile size and the credit sale window of the slot do not change. `inId` is pulled in before `outId` is sent
    /// out. the Core forwards its `swapCredit` call here untouched, under its own reentrancy guard. reverts
    /// `Retired` after `migrate`, `Paused` while paused, and for a bad id, a non-pile `outId`, an `inId` not owned
    /// by the caller or already piled, a lower incoming score, or the buyer-specific return lock
    function swapCredit(uint256 inId, uint256 outId) external {
        State storage c = state();
        if (c.retired) revert Retired();
        if (c.paused) revert Paused();
        if (inId == 0) revert ZeroId();
        checkReturn(c, inId, msg.sender);
        Credit storage out = c.credits[outId];
        if (!out.inPile) revert NotInPile(outId);
        if (c.credits[inId].inPile) revert InPile();
        if (CREDITS.ownerOf(inId) != msg.sender) revert NotOwner();
        if (scoreOf(inId) < scoreOf(outId)) revert ScoreTooLow(inId, outId);

        uint256 fee = c.settings.swapFeeCc;
        if (fee != 0) ICoin(ICoinOf(address(this)).COIN()).burnFrom(msg.sender, fee);

        // `inId` inherits `outId`'s node: same neighbours, cost and acquisition time; the pile size does not change
        uint256 prev = out.prev;
        uint256 next = out.next;
        Credit storage inC = c.credits[inId];
        inC.cost = out.cost;
        inC.prev = prev;
        inC.next = next;
        inC.acquiredAt = out.acquiredAt;
        inC.inPile = true;
        if (prev == 0) c.pile.head = inId;
        else c.credits[prev].next = inId;
        if (next == 0) c.pile.tail = inId;
        else c.credits[next].prev = inId;
        delete c.credits[outId];

        CREDITS.transferFrom(msg.sender, address(this), inId);
        CREDITS.transferFrom(address(this), msg.sender, outId);
        emit CreditSwapped(inId, outId, msg.sender, fee);
    }

    /// @notice sets the successor to which `migrate` sends the assets. the zero address means no migration. reverts
    /// after `lockSuccessor`, and for the Core, coin, Credits, Statements and every current or past balance module
    /// and token. the Core forwards its call here untouched
    function setSuccessor(address next) external {
        _onlyOwner();
        State storage c = state();
        if (c.successorLocked) revert Locked("successor");
        if (next != address(0)) {
            if (next.code.length == 0) revert NoCode(next);
            ICoinOf core = ICoinOf(address(this));
            if (
                next == address(this) || c.everBalanceTarget[next] || next == core.COIN() || next == address(CREDITS)
                    || next == address(STATEMENTS)
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
        (c.rateAtCheckpoint,,) = _ethClimb(c);
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

    /// the Core's forbidden list, read through its `isForbidden` view (the base set and every module or token a
    /// `setBalanceModule` has ever selected)
    function _forbidden(address t) private view returns (bool) {
        return ICoinOf(address(this)).isForbidden(t);
    }

    /// reverts unless the caller of the owner function the Core forwarded here is the owner; `msg.sender` is the Core's
    /// caller because the Core delegatecalls the library
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
    function owned(uint256 id) internal view {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
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

    /// @notice same as the two argument form, pinning the payment token. reverts `BalanceTokenChanged` when
    /// `balanceToken()` differs from `expectedToken` before any credit moves, then applies `minOut` as a floor on the
    /// total paid in that token's base units
    function sellForBalance(uint256[] calldata ids, uint256 minOut, address expectedToken) external {
        if (state().balanceToken != expectedToken) revert BalanceTokenChanged();
        _sellForBalance(ids, minOut);
    }

    /// posts `score * unit * (10_000 - balanceDiscountBps) / 10_000` per credit, lowered by the value-mode cap. the
    /// posted bid has no climb, drop or floor-rate check. `unit` is the module's `unitPerPoint()` read in the call.
    /// runs only while `balanceBidOn`. the artist is paid `buyToArtistBps` of each payout on top (decision 163), in
    /// balance token through a second module `pay`. the module holds the balance token: the running total of the
    /// payouts and the royalties must not exceed the module's live `available()` (`PotTooSmall`), so the funds for
    /// both are present. the module pays the seller with one `pay(seller, total)`, and the seller's holding must
    /// rise by at least `total` (`BadModule`). the artist `pay` is gas bounded; a failed whole call reverts the sale
    /// because it cannot record a liability. the production module reserves token transfer shortfalls as
    /// `owed[artist]`, claimable later. the credit enters the pile at `_ethFloorNow() * score / RATE_SCORE`, at least 1
    /// wei. a failing, short or zero live unit read reverts the whole bid (`BadModule`)
    function _sellForBalance(uint256[] calldata ids, uint256 minOut) private {
        State storage c = state();
        if (c.retired) revert Retired();
        if (!c.settings.balanceBidOn) revert BalanceBidOff();
        if (ids.length == 0) revert Empty();
        address module = c.balanceModule;
        if (module == address(0)) revert NoBalanceModule();
        uint256 unit = _liveUnit(module);
        uint256 avail = _liveAvailable(module);
        (uint256 total, uint256 artistTotal) = _fillBalance(ids, unit, avail, _ethFloorNow(c));
        if (total < minOut) revert Slippage();
        address token = c.balanceToken;
        uint256 heldBefore = SafeTransferLib.balanceOf(token, msg.sender);
        IBalanceModule(module).pay(msg.sender, total);
        if (SafeTransferLib.balanceOf(token, msg.sender).zeroFloorSub(heldBefore) < total) revert BadModule();
        // The module may record a failed token transfer as debt. A failed whole module call cannot persist that debt.
        if (artistTotal != 0) {
            (bool okPay,) =
                module.call{gas: ARTIST_PAY_GAS}(abi.encodeCall(IBalanceModule.pay, (c.artist, artistTotal)));
            if (!okPay) revert BadModule();
        }
    }

    /// climbs the balance instance to now with clamp `clampTo`, cap balanceBidCapBps and pages pot `pagesPot` and stores the
    /// price state and checkpoint
    function _balanceCheckpoint(Rate storage bal, uint256 clampTo, uint256 pagesPot) private {
        (uint256 price,) = _climb(
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

    /// balance-acquisition ETH basis: mode off uses max(climbed price state, decayed peak); value mode uses the
    /// current value rate or the stored last good rate, before the ETH pot clamp
    function _ethFloorNow(State storage c) private view returns (uint256) {
        if (c.settings.valueModeOn) {
            // value mode: the eth bid the shared instance prices, a record only. a momentarily down quote falls back to
            // the last good value mode eth rate kept in the idle eth instance (checkpoint), so a balance sale never
            // books a 1 wei basis while the reference is briefly unusable; the controller separately gates the payout
            (uint256 rate, bool okv) = _valueRate(c);
            return okv ? rate : c.rateAtCheckpoint;
        }
        (uint256 ep, uint256 epk,) = _ethClimb(c);
        return ep.max(epk);
    }

    /// pays each credit its posted discount lowered by the value-mode cap and books the artist royalty
    /// `buyToArtistBps` of it, in order. reverts `ZeroAmount` on a zero payout and `PotTooSmall` once the payouts
    /// plus the royalties pass `avail`. the credit enters the pile at eth cost basis `floor * score / RATE_SCORE`,
    /// at least 1 wei. returns the balance token totals owed to the seller and to the artist
    function _fillBalance(uint256[] calldata ids, uint256 unit, uint256 avail, uint256 floor)
        private
        returns (uint256 total, uint256 artistTotal)
    {
        for (uint256 i; i < ids.length; ++i) {
            (uint256 paid, uint256 toArtist) = _fillOne(ids[i], unit, floor);
            total += paid;
            artistTotal += toArtist;
            if (total + artistTotal > avail) revert PotTooSmall();
            emit BalanceFill(paid, toArtist, avail - total - artistTotal);
        }
    }

    /// one balance fill: the clamped posted payout and its artist royalty, the pile entry at the eth basis `floor *
    /// score / RATE_SCORE` (at least 1 wei), the transfer in. reverts `ZeroAmount` on a zero payout
    function _fillOne(uint256 id, uint256 unit, uint256 floor) private returns (uint256 paid, uint256 toArtist) {
        State storage c = state();
        owned(id);
        checkReturn(c, id, msg.sender);
        uint256 score = scoreOf(id);
        // value mode: lower the posted payout to the eth bid for the score at the protected sale price; the royalty
        // and the `avail` bound follow the converted payout
        paid = _clampPayout(score, score * unit * (BPS - c.settings.balanceDiscountBps) / BPS);
        if (paid == 0) revert ZeroAmount();
        toArtist = paid * c.settings.buyToArtistBps / BPS;
        uint256 cost = floor.mulDiv(score, RATE_SCORE).max(1);
        push(c.pile, c.credits, id, cost);
        CREDITS.transferFrom(msg.sender, address(this), id);
        emit CreditBought(id, msg.sender, cost, toArtist);
    }

    /// the multiplier pages pot in bps of par. `avail` saturates at ceil(denom * multiplierCap * balanceRateCap *
    /// pointsPerPage / (BPS squared * 100)), where every allowed last-fill rate reaches the multiplier cap, so the
    /// product cannot overflow
    function _toBpsRaw(uint256 avail, uint256 denom) private view returns (uint256) {
        if (denom == 0) return 0;
        Settings storage cfg = state().settings;
        uint256 maxPages = uint256(cfg.climbMultiplierCapBps) * cfg.balanceBidCapBps * cfg.pointsPerPage;
        uint256 enough = denom.mulDivUp(maxPages, BPS * BPS * 100);
        return avail.min(enough).mulDiv(BPS, denom);
    }

    /// @notice the balance bid rate, bps of par: the posted `10_000 - balanceDiscountBps`, in every mode, bid on or off
    /// (decision 164). the Core forwards its `balanceRate()`
    function balanceRate() external view returns (uint256) {
        return BPS - state().settings.balanceDiscountBps;
    }

    /// @notice the shared instance now, bps of par: value mode's eth price state climbed to now with the cap as its
    /// clamp, the figure `ethPrice` multiplies by the value per point. read for the eth quote replay in value mode;
    /// it leaves the posted balance rate unchanged but feeds the executable payout's value-mode cap through
    /// `ethPrice()`. the Core forwards its `sharedRate()`
    function sharedRate() external view returns (uint256) {
        return _sharedRead(state());
    }

    /// @notice executable payout for `score` stored units, after the value-mode cap; 0 when the module cannot cover
    /// it and its royalty. the Core forwards `balanceBidForScore(score)`
    function balanceBidForScore(uint256 score) external view returns (uint256) {
        return _balancePayout(score);
    }

    /// @notice the executable balance token payout for credit `id` now: `balanceBidForScore(scoreOf(id))`. a module too
    /// short to pay this credit and its royalty reads 0 here, so the view never advertises a payout the fill refuses
    /// (decision 159, C05). the Core forwards its `balanceBidOf(id)`
    function balanceBidOf(uint256 id) external view returns (uint256) {
        return _balancePayout(scoreOf(id));
    }

    /// the executable balance payout: the posted discount lowered by the value-mode cap, and 0 when no module is
    /// set, the unit read fails, or the payout plus its artist royalty exceeds `available()`: the fill
    /// (`_fillBalance`) reverts `PotTooSmall` there, and the view returns 0 instead of a payout the fill refuses
    function _balancePayout(uint256 score) private view returns (uint256) {
        State storage c = state();
        address module = c.balanceModule;
        if (module == address(0)) return 0;
        (uint256 unit, bool ok) = _unitView(module);
        if (!ok) return 0;
        // report the clamped payout the fill pays in value mode, not the posted par
        uint256 pay = _clampPayout(score, score * unit * (BPS - c.settings.balanceDiscountBps) / BPS);
        if (pay + pay * c.settings.buyToArtistBps / BPS > _availableView(module)) return 0;
        return pay;
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

    /// bounded unit read: the first word of an answer at least 32 bytes, in [1, uint128 max], else (0, false)
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

    /// gas bound of module unit/availability reads and the controller markup read
    uint256 internal constant READ_GAS = 2_000_000;

    /// bounded read of `unitPerPoint()` of `module`: at most `READ_GAS`, at least 32 bytes returned (a long answer
    /// is cut off). a revert, a short answer, a zero unit or a unit above `type(uint128).max` reverts `BadModule`
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
    function isForbidden(address t) external view returns (bool);
}

interface IFund {
    function fund() external payable;
}
