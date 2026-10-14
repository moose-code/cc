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
    ICredits,
    ICreditScore,
    IBalanceModule,
    IStatements,
    Settings,
    Mainnet
} from "../interfaces/Interfaces.sol";
import {Halving} from "./Halving.sol";
import {SettingsBounds} from "./SettingsBounds.sol";

/// every state variable of the Core, in one struct. the Core declares it once (`State internal s`, slot 0) and the library
/// reads it at slot 0 (`CoreLib.state`), so both address the same storage. test/CoreLayout.t.sol compares the fields with
/// raw storage words
struct State {
    address controller;
    /// one way locks of the owner (docs/SPEC.md section 11): once set, the door never opens again
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
    /// eth reserve filled by `feeToRedeemBurnBps` of the fee stream. each redemption moves `redeemBurnBps` of it into
    /// `ethToBuyback`
    uint256 ethRedeemBurn;
    /// balance token held for the balance token bid. redemptions add to it, `sellForBalance` pays from it
    uint256 balancePot;
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
    /// `compose` and `composeChosen` with `Retired`
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
    /// the address `claimPayee` pays
    address payee;
    /// eth credited to the payee by `_book` and not yet claimed
    uint256 payeeOwed;
    /// true once the payee share runs. set by the first `_book` with income at or after `launchedAt + SNIPER_SECONDS`,
    /// which shares nothing. one way
    bool payeeOn;
    /// the economic settings, three packed slots
    Settings settings;
    /// the bid anchor state, four words
    CoreLib.Anchor anchor;
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
        /// `timestamp / 60` of the first fill of the current minute
        uint64 minuteBucket;
        /// time `peakRate` was last written: the last fill or `setRate`, deploy time before the first fill
        uint64 peakTime;
        /// the remembered peak: `max(fill price, peak decayed to the fill time)` at the last fill, `setRate`'s rate, or
        /// `rateStart` at deploy. it halves every `peakHalfLife` since `peakTime`. the ceiling anchors on
        /// `max(lastFillRate, peak now)`, and the price state climbs at `recoveryClimbPerMinBps` while below the
        /// recovery level `peak now * (10_000 - recoveryGapBps) / 10_000`
        uint256 peakRate;
    }

    uint256 internal constant BPS = 10_000;
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error Empty();
    error NoBalanceModule();
    error BadModule();
    /// the controller's `refScore()` read failed or returned zero
    error BadQuote();
    error ZeroId();
    error NotOwner();
    error ZeroAmount();
    error PotTooSmall();
    error Slippage();
    /// `sellForBalance` while `balanceBidOn` is false
    error BalanceBidOff();
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
    event Migrated(address indexed successor, uint256 eth, uint256 balanceTokens, uint256 credits);
    event EngineRetired(address indexed successor);
    event BalanceTokenMigrationSkipped(address indexed successor, uint256 amount);

    /// @notice validates the settings, stores them and logs them. the Core forwards its own `setSettings` call here
    /// untouched (same selector), after it checkpointed the eth rate. the constructor calls it too. a change of
    /// `peakHalfLife` restates the remembered peak at the old half life before storing the new one, so the new half
    /// life decays the peak forward only
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        State storage c = state();
        // a change of the peak half life applies forward only: restate the remembered peak at the old half life before
        // the new one is stored, so the elapsed decay is not rescaled. skipped at the first set (old half life zero,
        // the constructor, where the peak was just written)
        uint256 oldHalf = c.settings.peakHalfLife;
        if (oldHalf != 0 && ns.peakHalfLife != oldHalf) {
            Anchor storage a = c.anchor;
            a.peakRate = Halving.halve(a.peakRate, block.timestamp.zeroFloorSub(a.peakTime), oldHalf);
            // forge-lint: disable-next-line(unsafe-typecast)
            a.peakTime = uint64(block.timestamp);
        }
        c.settings = ns;
        emit SettingsSet(ns);
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
        (price, read,) = _climb(r, pot, anchorTime, t, nowTs);
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
        (uint256 price,, uint256 peakNow) = _climb(r, pot, anchorTime, t, nowTs);
        return price.max(peakNow);
    }

    function _climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        private
        view
        returns (uint256 price, uint256 read, uint256 peakNow)
    {
        State storage c = state();
        Settings storage s = c.settings;
        Anchor storage a = c.anchor;
        peakNow = Halving.halve(a.peakRate, nowTs.zeroFloorSub(a.peakTime), s.peakHalfLife);
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
    function _recover(uint256 r, uint256 target, uint256 t, uint256 nowTs, Anchor storage a, Settings storage s)
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
        State storage c = state();
        Settings storage s = c.settings;
        Anchor storage a = c.anchor;
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
        State storage c = state();
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
    /// id twice included), and `NotHolder` for a credit the Core does not hold. The Core books the fee income, then
    /// forwards its call here untouched, under its own reentrancy guard
    function adopt(uint256[] calldata ids) external {
        if (ids.length == 0) revert Empty();
        State storage c = state();
        (uint256 price,,) = _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
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

    /// @notice moves `ethPot`, `balancePot` and the credits the Core tracks to the successor, in batches. the Core
    /// forwards its call here untouched, the owner check and the reentrancy guard are here.
    /// the first call sets `retired`, which stays set: `sellForEth`, `buyListing`, `sellForBalance`, `adopt` and
    /// `compose` then revert `Retired`. logs `EngineRetired` once.
    /// eth: `ethPot`, by `fund()` of the successor, or by a plain send when `fund()` fails, the tracker zeroed. `ethToBuyback` stays for the coin buyback. eth above the
    /// trackers stays.
    /// balance token: `balancePot`, by `transfer`, the tracker zeroed. a transfer that reverts, returns false or returns less
    /// than a word leaves the pot as it is, logs `BalanceTokenMigrationSkipped` and the call goes on; a later `migrate`
    /// retries. the coin stays. `ethToBuyback` and `ethRedeemBurn` stay for the coin buyback.
    /// credits: up to `maxCredits` from the head of the pile, by `transferFrom`, the pile membership cleared (the
    /// cost and arrival time of the record stay). zero moves the pots only.
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
        uint256 balanceTokens = _moveBalanceToken(c, to);
        _leave();
        emit Migrated(to, eth, balanceTokens, credits);
    }

    function _moveEth(State storage c, address to) private returns (uint256 eth) {
        eth = c.ethPot;
        if (eth == 0) return 0;
        (c.rateAtCheckpoint,,) = _climb(c.rateAtCheckpoint, eth, c.lastFillTime, c.checkpointTime, block.timestamp);
        c.checkpointTime = uint64(block.timestamp);
        c.ethPot = 0;
        (bool ok,) = to.call{value: eth}(abi.encodeCall(IFund.fund, ()));
        if (!ok) (ok,) = to.call{value: eth}("");
        if (!ok) revert CallFailed();
    }

    /// the transfer is a low level call that accepts no return data or `true`. on failure the pot stays as it is and
    /// `BalanceTokenMigrationSkipped` is logged
    function _moveBalanceToken(State storage c, address to) private returns (uint256 amount) {
        amount = c.balancePot;
        if (amount == 0) return 0;
        address token = c.balanceToken;
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
            emit BalanceTokenMigrationSkipped(to, amount);
            return 0;
        }
        c.balancePot = 0;
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

    /// @notice sells the credits `ids` of the caller into the balance token bid. the Core's `sellForBalance` forwards its
    /// call here untouched, under its own reentrancy guard
    function sellForBalance(uint256[] calldata ids) external {
        _sellForBalance(ids, 0);
    }

    /// @notice same as the one argument form with a floor on the total paid
    function sellForBalance(uint256[] calldata ids, uint256 minOut) external {
        _sellForBalance(ids, minOut);
    }

    /// pays each credit `score * unit * (10_000 - balanceBidMarginBps) / 10_000` in balance token from `balancePot`, where
    /// `unit` is the module's `unitPerPoint()` read in the call. reads the score from the credit score contract. runs
    /// only while `balanceBidOn` is true. each credit's price must not exceed the remaining pot. the credit enters the single pile
    /// with an eth cost basis of `floorRate * score / refScore`, at least 1 wei, where `floorRate` is the larger of the
    /// climbed price state and the remembered eth bid peak decayed to now (the Core's `floorRate()`). the peak rises with
    /// fills and falls only with time, so neither a pot move nor a pool move can push a recorded cost down, and no pool
    /// key is needed. a failing, short or zero live unit read reverts the whole bid (`BadModule`). `refScore` is read
    /// from the controller with a bounded staticcall; a failed or zero read reverts `BadQuote`
    function _sellForBalance(uint256[] calldata ids, uint256 minOut) private {
        State storage c = state();
        if (c.retired) revert Retired();
        Settings storage s = c.settings;
        if (!s.balanceBidOn) revert BalanceBidOff();
        if (ids.length == 0) revert Empty();
        if (c.balanceModule == address(0)) revert NoBalanceModule();
        uint256 unit = _liveUnit(c.balanceModule);
        uint256 net = BPS - s.balanceBidMarginBps;
        uint256 pot = c.balancePot;
        // the floor rate now, the base of a credit's recorded eth cost basis: the larger of the price state climbed
        // before the pot clamp and the decayed peak. selling credits lowers only the rate and the peak decays between
        // fills, so the maximum follows the climb and holds against the walk down. read only
        (uint256 price,, uint256 peakNow) =
            _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
        uint256 floor = price.max(peakNow);
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
            uint256 cost = floor.mulDiv(score, refScore).max(1);
            push(c.pile, c.credits, id, cost);
            CREDITS.transferFrom(msg.sender, address(this), id);
            emit CreditBought(id, msg.sender, cost);
        }
        c.balancePot = pot;
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransfer(c.balanceToken, msg.sender, total);
    }

    /// gas forwarded to the bounded module and controller reads of the balance token bid
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

    /// the controller's `refScore()` through a bounded staticcall of at most `READ_GAS`, copying at most 32 bytes of
    /// returndata. a revert, an answer shorter than 32 bytes or a zero answer reverts `BadQuote`
    function _refScore(address controller) private view returns (uint256 refScore) {
        bytes4 sel = 0x0dd34cf6; // refScore()
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, controller, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            refScore := mload(0)
        }
        if (!ok || refScore == 0) revert BadQuote();
    }
}

interface ICoinOf {
    function COIN() external view returns (address);
}

interface IFund {
    function fund() external payable;
}
