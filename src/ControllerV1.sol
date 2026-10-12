// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {Lane, Sale, IController, ICoreViews, ICoreSale, Mainnet} from "./interfaces/Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// first policy module. composes the oldest 80 credits of a lane with format 0.
/// it prices and sells statements. the asking price of a statement of cost `c` is a fraction of `c` in bps that starts at
/// `start = min(anchorBps * markupBps / 10_000, startCapBps)` and falls at a fixed rate per second in two stages: at
/// `fastDecayBpsPerHour` from `start` to `kneeBps`, then at `slowDecayBpsPerHour` to `floorBps`, where it stays. a `start`
/// at or below `kneeBps` falls at the slow rate from the first second. the price is computed at every call from the age of
/// statement (time since its compose) and the current settings, so a setting change applies to held statements at once.
/// `anchorBps` (bps of cost, at least 10_000) is the running level of sale prices. it moves up with sales and down with
/// time. a `buy` of a statement whose cost is at least `anchorMinCost` and whose sale price in bps of cost is above the
/// anchor sets the anchor to the mean of the two. every other `buy` leaves the anchor unchanged. the part of the anchor above 10_000 halves every `anchorHalfLife`,
/// continuously. the controller stores the anchor at its last change (`storedAnchorBps`, `anchorTime`) and evaluates
/// the decay at the call. the price is computed from the current anchor at every call, so held statements follow it.
/// `buy` sells a held eth lane statement at once at the asking price.
/// the owner can pause sales (`setPaused`). while paused `buy` reverts `Paused`, `priceOf` answers, and the age of a
/// statement excludes every paused second, so the age of a held statement stops advancing for the length of a pause
/// and continues from the same age at resume. the anchor decays with wall time in both states, so the start of the
/// curve, and with it the asking price, can still fall in a pause while the anchor is above 10_000.
/// it holds no funds between calls. its settings belong to the live owner of the core (`core.owner()`), there is no
/// second owner. the core enforces its own hard floor whatever this contract answers.
/// once the owner sets the exit token pool (`setExitPoolKey`), the asking price is also floored at the statement's
/// redeemable value in eth, `rating * unitPerPoint` exit token base units priced at the pool sqrt price. `atCost` and
/// the anchor use the curve price, not this floor. with the pool key unset, no exit module set, or a zero pool read
/// the value floor is 0 and the asking price is the curve price
contract ControllerV1 is IController {
    using StateLibrary for IPoolManager;

    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_ANCHOR_MIN_COST = 10 ether;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error Reentrant();
    error Paused();

    event MarkupBpsSet(uint16 markupBps);
    event StartCapBpsSet(uint32 startCapBps);
    event FastDecayBpsPerHourSet(uint16 fastDecayBpsPerHour);
    event KneeBpsSet(uint32 kneeBps);
    event SlowDecayBpsPerHourSet(uint16 slowDecayBpsPerHour);
    event FloorBpsSet(uint16 floorBps);
    event AnchorBpsSet(uint32 anchorBps);
    event AnchorHalfLifeSet(uint32 anchorHalfLife);
    event AnchorMinCostSet(uint128 anchorMinCost);
    event PausedSet(bool paused);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);
    event ExitPoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);

    /// one pause of sales: a single storage slot
    struct PauseWindow {
        uint40 start;
        uint40 end;
        uint40 pausedBefore;
    }

    ICoreViews public immutable CORE;

    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of cost. the larger of `markupBps` and `kneeBps` to 200_000
    uint32 public startCapBps;
    /// fall of the asking price per hour above `kneeBps`, bps of cost. 1 to 10_000
    uint16 public fastDecayBpsPerHour;
    /// fall of the asking price per hour at or below `kneeBps`, bps of cost. 1 to 10_000
    uint16 public slowDecayBpsPerHour;
    /// the price where the fast fall ends and the slow fall starts, bps of cost. `floorBps` to `startCapBps`
    uint32 public kneeBps;
    /// lowest asking price, bps of cost. 1_000 to the smaller of 10_000 and `kneeBps`
    uint16 public floorBps;
    /// the anchor at `anchorTime`, bps of cost. 10_000 to `startCapBps`. `anchorBps()` is the value now
    uint32 public storedAnchorBps;
    /// when `storedAnchorBps` was last set
    uint40 public anchorTime;
    /// seconds for the part of the anchor above 10_000 to halve. 1 day to 90 days
    uint32 public anchorHalfLife;
    /// the least statement cost, in wei, whose `buy` moves the anchor. 0 to 10 ether
    uint128 public anchorMinCost;
    bool private _busy;
    /// whether sales are paused. launch value false
    bool public paused;
    /// whether the exit token pool key is set. launch value false
    bool public exitPoolKeySet;
    /// the uniswap v4 pool of the exit token against native eth, used to price the redeemable value floor. native eth
    /// is `currency0` (the zero address) and the exit token is `currency1`, the only order a native eth pool sorts to.
    /// unset at launch
    PoolKey public exitPoolKey;
    /// the pause windows in time order, disjoint. window `i` is paused from `start` until `end`. while `paused` is true the
    /// last window is open and its `end` is 0. `pausedBefore` is the paused seconds of windows `0` to `i - 1`
    PauseWindow[] private _pauses;

    constructor(address core, Sale memory sale) {
        CORE = ICoreViews(core);
        if (sale.markupBps < BPS || sale.markupBps > 40_000) revert BadSetting("markupBps");
        markupBps = sale.markupBps;
        if (sale.startCapBps < sale.markupBps || sale.startCapBps > 200_000) revert BadSetting("startCapBps");
        startCapBps = sale.startCapBps;
        if (sale.floorBps < 1_000 || sale.floorBps > BPS) revert BadSetting("floorBps");
        floorBps = sale.floorBps;
        if (sale.kneeBps < sale.floorBps || sale.kneeBps > sale.startCapBps) revert BadSetting("kneeBps");
        kneeBps = sale.kneeBps;
        if (sale.fastDecayBpsPerHour < 1 || sale.fastDecayBpsPerHour > BPS) revert BadSetting("fastDecayBpsPerHour");
        fastDecayBpsPerHour = sale.fastDecayBpsPerHour;
        if (sale.slowDecayBpsPerHour < 1 || sale.slowDecayBpsPerHour > BPS) revert BadSetting("slowDecayBpsPerHour");
        slowDecayBpsPerHour = sale.slowDecayBpsPerHour;
        if (sale.anchorHalfLife < 1 days || sale.anchorHalfLife > 90 days) revert BadSetting("anchorHalfLife");
        anchorHalfLife = sale.anchorHalfLife;
        if (sale.anchorMinCost > MAX_ANCHOR_MIN_COST) revert BadSetting("anchorMinCost");
        anchorMinCost = sale.anchorMinCost;
        storedAnchorBps = uint32(BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ sale settings, owner, at once

    /// 10_000 to 40_000, and not above `startCapBps`
    function setMarkupBps(uint16 v) external onlyOwner {
        if (v < BPS || v > 40_000 || v > startCapBps) revert BadSetting("markupBps");
        markupBps = v;
        emit MarkupBpsSet(v);
    }

    /// the larger of `markupBps` and `kneeBps` to 200_000. an `anchorBps()` above the new cap is lowered to it
    function setStartCapBps(uint32 v) external onlyOwner {
        if (v < markupBps || v < kneeBps || v > 200_000) revert BadSetting("startCapBps");
        startCapBps = v;
        emit StartCapBpsSet(v);
        if (anchorBps() > v) _setAnchor(v);
    }

    /// 1 to 10_000
    function setFastDecayBpsPerHour(uint16 v) external onlyOwner {
        if (v < 1 || v > BPS) revert BadSetting("fastDecayBpsPerHour");
        fastDecayBpsPerHour = v;
        emit FastDecayBpsPerHourSet(v);
    }

    /// 1 to 10_000
    function setSlowDecayBpsPerHour(uint16 v) external onlyOwner {
        if (v < 1 || v > BPS) revert BadSetting("slowDecayBpsPerHour");
        slowDecayBpsPerHour = v;
        emit SlowDecayBpsPerHourSet(v);
    }

    /// `floorBps` to `startCapBps`. raising it above the cap takes `setStartCapBps` first, lowering it below the floor
    /// takes `setFloorBps` first
    function setKneeBps(uint32 v) external onlyOwner {
        if (v < floorBps || v > startCapBps) revert BadSetting("kneeBps");
        kneeBps = v;
        emit KneeBpsSet(v);
    }

    /// 1_000 to the smaller of 10_000 and `kneeBps`
    function setFloorBps(uint16 v) external onlyOwner {
        if (v < 1_000 || v > BPS || v > kneeBps) revert BadSetting("floorBps");
        floorBps = v;
        emit FloorBpsSet(v);
    }

    /// 10_000 to `startCapBps`. replaces the running level of sale prices and restarts its decay
    function setAnchorBps(uint32 v) external onlyOwner {
        if (v < BPS || v > startCapBps) revert BadSetting("anchorBps");
        _setAnchor(v);
    }

    /// 1 day to 90 days. the anchor at the call is stored first, so the new half life applies from now on
    function setAnchorHalfLife(uint32 v) external onlyOwner {
        if (v < 1 days || v > 90 days) revert BadSetting("anchorHalfLife");
        _setAnchorStored(anchorBps());
        anchorHalfLife = v;
        emit AnchorHalfLifeSet(v);
    }

    /// 0 to 10 ether. applies to the next `buy`
    function setAnchorMinCost(uint128 v) external onlyOwner {
        if (v > MAX_ANCHOR_MIN_COST) revert BadSetting("anchorMinCost");
        anchorMinCost = v;
        emit AnchorMinCostSet(v);
    }

    /// pauses or resumes sales at once. a call that repeats the current state changes nothing. a pause opens a window at
    /// the current time and a resume closes it. each window costs one storage slot, and `priceOf` and `buy` read
    /// `log2(windows)` slots of them
    function setPaused(bool v) external onlyOwner {
        if (v == paused) return;
        paused = v;
        uint256 n = _pauses.length;
        if (v) {
            uint256 closed;
            if (n != 0) {
                PauseWindow memory last = _pauses[n - 1];
                closed = last.pausedBefore + last.end - last.start;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            _pauses.push(PauseWindow(uint40(block.timestamp), 0, uint40(closed)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            _pauses[n - 1].end = uint40(block.timestamp);
        }
        emit PausedSet(v);
    }

    /// sets the native eth / exit token pool whose sqrt price floors the asking price at a statement's redeemable value.
    /// `currency0` must be native eth (the zero address) and `currency1` the core's current exit token, the order a
    /// native eth pool sorts to. the pool must be initialized, so `_value` reads a live price at once. effective at once
    function setExitPoolKey(PoolKey calldata key) external onlyOwner {
        address token = CORE.exitToken();
        if (token == address(0)) revert BadSetting("exitToken");
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != address(0) || c1 != token) revert BadSetting("exitPoolKey");
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert BadSetting("exitPoolKey");
        exitPoolKey = key;
        exitPoolKeySet = true;
        emit ExitPoolKeySet(c0, c1, key.fee, key.tickSpacing, address(key.hooks));
    }

    // ------------------------------------------------------------------ pricing and sale

    /// the running level of sale prices now, bps of cost: 10_000 plus the part of `storedAnchorBps` above 10_000,
    /// halved every `anchorHalfLife` since `anchorTime`
    function anchorBps() public view returns (uint32) {
        uint256 excess = storedAnchorBps - BPS;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(BPS + Halving.halve(excess, block.timestamp - anchorTime, anchorHalfLife));
    }

    /// the start price of a new statement, bps of cost: the anchor times `markupBps`, at most `startCapBps`
    function startBps() public view returns (uint256) {
        uint256 start = uint256(anchorBps()) * markupBps / BPS;
        return start < startCapBps ? start : startCapBps;
    }

    /// the asking price of statement `sid` now, read from the core. never below the core hard floor
    /// `cost * saleFloorBps / 10_000`, and never below the redeemable value floor once the exit token pool key is set,
    /// so the quote is always a price `sellTo` takes. answers while paused
    function priceOf(uint256 sid) public view returns (uint256 price) {
        uint256 cost;
        (price, cost) = _quote(sid);
        uint256 value = _value(sid);
        if (value > price) price = value;
    }

    /// true when the asking price of eth lane statement `sid` is at or below its stored cost. the asking price excludes
    /// paused seconds, so eligibility holds its value while sales are paused. the core reads it to gate a phase 2
    /// redemption of an eth lane statement
    function atCost(uint256 sid) external view returns (bool) {
        (uint256 price, uint256 cost) = _quote(sid);
        return price <= cost;
    }

    /// pays the asking price, gets the statement at once, and moves the anchor halfway to the sale price in bps of
    /// cost when the cost is at least `anchorMinCost`. the excess of `msg.value` is refunded to the caller last
    function buy(uint256 sid) external payable {
        if (paused) revert Paused();
        if (_busy) revert Reentrant();
        _busy = true;
        (uint256 curve, uint256 cost) = _quote(sid);
        uint256 value = _value(sid);
        uint256 price = value > curve ? value : curve;
        if (msg.value < price) revert Underpaid();
        _moveAnchor(sid, curve, cost);
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    function _quote(uint256 sid) private view returns (uint256 price, uint256 cost) {
        bool held;
        Lane lane;
        uint64 composedAt;
        (held, lane, cost, composedAt) = CORE.statementInfo(sid);
        if (!held || lane != Lane.Eth) revert NotForSale();
        price = _ask(cost, _age(composedAt));
        uint256 floor = cost * ICoreSale(address(CORE)).settings().saleFloorBps / BPS;
        if (price < floor) price = floor;
    }

    /// the redeemable value of statement `sid` in wei from the exit token pool: `rating * unitPerPoint` exit token base
    /// units priced at the pool sqrt price. zero when the pool key is unset, no exit module is set, the owed amount is
    /// zero, or the pool sqrt price reads zero. native eth is `currency0`, so wei per token base unit is
    /// `(2^96 / sqrtPrice)^2`. `mulDiv` carries the sqrt price squared at full precision
    function _value(uint256 sid) private view returns (uint256) {
        if (!exitPoolKeySet) return 0;
        if (CORE.exitModule() == address(0)) return 0;
        uint256 owed = CORE.ratingOf(sid) * CORE.unitPerPoint();
        if (owed == 0) return 0;
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(exitPoolKey.toId());
        if (sqrtPriceX96 == 0) return 0;
        uint256 q = FixedPoint96.Q96;
        uint256 p = sqrtPriceX96;
        return FullMath.mulDiv(FullMath.mulDiv(owed, q, p), q, p);
    }

    /// the age of a statement composed at `composedAt`: the seconds from then to now outside every pause window. a
    /// statement composed inside a window ages from the end of that window
    function _age(uint256 composedAt) private view returns (uint256) {
        uint256 n = _pauses.length;
        uint256 wall = block.timestamp - composedAt;
        if (n == 0) return wall;
        return wall - (_pausedUntil(block.timestamp, n) - _pausedUntil(composedAt, n));
    }

    /// the paused seconds from time 0 to `t`, with `t` at most now and `n` the window count. a binary search finds the
    /// last window that starts at or before `t`. that window adds its clipped length to `pausedBefore`
    function _pausedUntil(uint256 t, uint256 n) private view returns (uint256) {
        uint256 lo;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_pauses[mid].start <= t) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return 0;
        PauseWindow memory w = _pauses[lo - 1];
        uint256 end = ((paused && lo == n) || w.end > t) ? t : w.end;
        return w.pausedBefore + end - w.start;
    }

    /// with `cost` at least `anchorMinCost`, a sale price in bps of cost (rounded up) above the anchor sets the anchor to
    /// the mean of the two, at most `startCapBps`. every other sale leaves the stored anchor and `anchorTime` unchanged
    function _moveAnchor(uint256 sid, uint256 price, uint256 cost) private {
        if (cost < anchorMinCost) return;
        // cost is at least 80: every eth lane credit enters the pile through `_spend` (nonzero) or `adopt` (at least 1 wei)
        uint256 saleBps = (price * BPS + cost - 1) / cost;
        uint256 current = anchorBps();
        if (saleBps <= current) return;
        uint256 next = (current + saleBps) / 2;
        uint256 cap = startCapBps;
        if (next > cap) next = cap;
        // forge-lint: disable-next-line(unsafe-typecast)
        _setAnchorStored(uint32(next));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit AnchorMoved(sid, saleBps, uint32(next));
    }

    function _setAnchor(uint32 v) private {
        _setAnchorStored(v);
        emit AnchorBpsSet(v);
    }

    function _setAnchorStored(uint32 v) private {
        storedAnchorBps = v;
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
    }

    /// the asking price in wei after `age` seconds. the price is held in units of 1/3600 bps so each stage is an integer
    /// line of the second: it falls by `fastDecayBpsPerHour` units a second from the start to the knee and by
    /// `slowDecayBpsPerHour` units a second after, never below `floorBps`. the slow stage starts at the second the fast
    /// stage reaches the knee, which is `(start - knee) / fastDecayBpsPerHour` hours and need not be a whole second, so
    /// its fall is rounded up. the rounding keeps the price non-increasing in `age`
    function _ask(uint256 cost, uint256 age) private view returns (uint256) {
        uint256 start = startBps() * 1 hours;
        uint256 knee = uint256(kneeBps) * 1 hours;
        uint256 fast = fastDecayBpsPerHour;
        uint256 fallen = fast * age;
        uint256 span = start > knee ? start - knee : 0;
        uint256 n;
        if (fallen <= span) {
            n = start - fallen;
        } else {
            uint256 drop = (slowDecayBpsPerHour * (fallen - span) + fast - 1) / fast;
            uint256 base = start < knee ? start : knee;
            n = base > drop ? base - drop : 0;
        }
        uint256 low = uint256(floorBps) * 1 hours;
        if (n < low) n = low;
        return cost * n / (1 hours * BPS);
    }

    // ------------------------------------------------------------------ credit picking, unchanged

    /// ready when the lane pile holds a full page. the page is the 80 oldest credits with format 0.
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize(lane) < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(lane, 0, PAGE);
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }
}
