// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {Sale, Credit, IController, ICoreViews, ICoreSale, ICreditScore, ICredits, IExitModule, Mainnet} from "./interfaces/Interfaces.sol";
import {CreditBounds} from "./lib/CreditBounds.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// first policy module. composes the oldest 80 pile credits with format 0.
/// it prices and sells statements. a statement's price reference is the larger of its cost and the eth bid rate before
/// the pot clamp times its rating over `refScore`, computed at each call. the rate term prices the rating at the
/// engine's average credit price, so two statements of the same rating reference the same amount once the rate term
/// binds, whatever each credit cost. `refScore` is an owner setting in the
/// per-credit score unit (one ten-thousandth of a point). the asking price is a fraction of the reference in bps that
/// starts at `start = min(anchorBps * markupBps / 10_000, startCapBps)` and falls at a fixed rate per second in two
/// stages: at `fastDecayBpsPerHour` from `start` to `kneeBps`, then at `slowDecayBpsPerHour` to `floorBps`, where it
/// stays. a `start` at or below `kneeBps` falls at the slow rate from the first second. the price is computed at every
/// call from the age of the statement (time since its compose) and the current settings, so a setting change applies to
/// held statements at once.
/// `anchorBps` (at least 10_000) is the running level of sale prices in bps of the reference. it moves up with sales and
/// down with time. a `buy` of a statement whose cost is at least `anchorMinCost` and whose sale price in bps of the
/// reference is above the anchor sets the anchor to the mean of the two. every other `buy` leaves the anchor unchanged.
/// the part of the anchor above 10_000 halves every `anchorHalfLife`, continuously. the controller stores the anchor at
/// its last change (`storedAnchorBps`, `anchorTime`) and evaluates the decay at the call. the price is computed from the
/// current anchor at every call, so held statements follow it.
/// `buy` sells a held statement at once at the asking price. `atFloor(sid)` is true once the statement's curve price has
/// reached its floor, `floorBps` of the reference.
/// the owner can pause sales (`setPaused`). while paused `buy` reverts `Paused`, `priceOf` answers, and the age of a
/// statement excludes every paused second, so the age of a held statement stops advancing for the length of a pause
/// and continues from the same age at resume. the anchor decays with wall time in both states, so the start of the
/// curve, and with it the asking price, can still fall in a pause while the anchor is above 10_000.
/// it holds no funds between calls. its settings belong to the live owner of the core (`core.owner()`), there is no
/// second owner. the core enforces its own hard floor, `saleFloorBps` of cost, whatever this contract answers.
/// once the owner sets the exit token pool (`setExitPoolKey`), the asking price is also floored at the statement's
/// redeemable value in eth, `rating * unit` exit token base units priced at the pool sqrt price, with `unit` the lower of the stored and the live `unitPerPoint()`. `atFloor` and
/// the anchor use the curve price, not this floor. with the pool key unset, no exit module set, or a zero pool read
/// the value floor is 0 and the asking price is the curve price
contract ControllerV1 is IController {
    using StateLibrary for IPoolManager;

    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;
    uint256 private constant READ_GAS = 200_000;
    uint256 private constant MAX_ANCHOR_MIN_COST = 10 ether;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error Reentrant();
    error Paused();
    /// the exit token baseline cannot be priced. `valueWei` reverts it for an unset pool key or a zero pool price. the
    /// credit sale reverts it for the same two and, while an exit module is set, for a failed or zero live
    /// `unitPerPoint` read
    error NoExitPrice();
    /// a credit sale door was called while the credit sale window is off
    error CreditSaleOff();
    /// a credit's score times the live unit overflows a 256 bit word
    error BaselineOverflow();

    event MarkupBpsSet(uint16 markupBps);
    event StartCapBpsSet(uint32 startCapBps);
    event FastDecayBpsPerHourSet(uint16 fastDecayBpsPerHour);
    event KneeBpsSet(uint32 kneeBps);
    event SlowDecayBpsPerHourSet(uint16 slowDecayBpsPerHour);
    event FloorBpsSet(uint16 floorBps);
    event RefScoreSet(uint32 refScore);
    event AnchorBpsSet(uint32 anchorBps);
    event AnchorHalfLifeSet(uint32 anchorHalfLife);
    event AnchorMinCostSet(uint128 anchorMinCost);
    event PausedSet(bool paused);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);
    event ExitPoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event CreditSaleOnSet(bool on);
    event CreditWindowSet(uint32 creditWindow);
    event CreditFloorBpsSet(uint16 creditFloorBps);
    event CreditStartBpsSet(uint32 creditStartBps);

    /// one pause of sales: a single storage slot
    struct PauseWindow {
        uint40 start;
        uint40 end;
        uint40 pausedBefore;
    }

    ICoreViews public immutable CORE;

    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of the reference. the larger of `markupBps` and `kneeBps` to 200_000
    uint32 public startCapBps;
    /// fall of the asking price per hour above `kneeBps`, bps of the reference. 1 to 10_000
    uint16 public fastDecayBpsPerHour;
    /// fall of the asking price per hour at or below `kneeBps`, bps of the reference. 1 to 10_000
    uint16 public slowDecayBpsPerHour;
    /// the price where the fast fall ends and the slow fall starts, bps of the reference. `floorBps` to `startCapBps`
    uint32 public kneeBps;
    /// lowest asking price, bps of the reference. 1_000 to the smaller of 10_000 and `kneeBps`
    uint16 public floorBps;
    /// the per-credit score the statement reference divides the rating by, in ten-thousandths of a point. the reference
    /// is the larger of cost and the eth bid rate times rating over `refScore`, so a lower `refScore` lifts the rate
    /// term. 1 to 8_000_000
    uint32 public refScore;
    /// the anchor at `anchorTime`, bps of the reference. 10_000 to `startCapBps`. `anchorBps()` is the value now
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

    /// whether pile credits are for sale from their acquisition time and compose waits for a credit's window to pass.
    /// launch value false
    bool public creditSaleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit must sit before compose
    /// may take it. 1 minute to 30 days
    uint32 public creditWindow;
    /// the credit sale floor over the highest of the credit's cost, exit token baseline and score-scaled eth backstop,
    /// bps. 10_000 to 40_000
    uint16 public creditFloorBps;
    /// the credit sale start price over the floor, bps. 10_000 to 200_000
    uint32 public creditStartBps;

    constructor(address core, Sale memory sale, Credit memory credit) {
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
        if (!CreditBounds.refScoreOk(credit.refScore)) revert BadSetting("refScore");
        if (!CreditBounds.windowOk(credit.window)) revert BadSetting("creditWindow");
        if (!CreditBounds.floorBpsOk(credit.floorBps)) revert BadSetting("creditFloorBps");
        if (!CreditBounds.startBpsOk(credit.startBps)) revert BadSetting("creditStartBps");
        refScore = credit.refScore;
        creditSaleOn = credit.saleOn;
        creditWindow = credit.window;
        creditFloorBps = credit.floorBps;
        creditStartBps = credit.startBps;
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

    /// 1 to 8_000_000. applies to the reference of every open listing at the next call
    function setRefScore(uint32 v) external onlyOwner {
        if (!CreditBounds.refScoreOk(v)) revert BadSetting("refScore");
        refScore = v;
        emit RefScoreSet(v);
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

    // ------------------------------------------------------------------ credit sale settings, owner, at once

    /// turns the credit sale window on or off. while on, pile credits are for sale through `buyCredit` and compose
    /// takes only credits past their window
    function setCreditSaleOn(bool v) external onlyOwner {
        creditSaleOn = v;
        emit CreditSaleOnSet(v);
    }

    /// 1 minute to 30 days
    function setCreditWindow(uint32 v) external onlyOwner {
        if (!CreditBounds.windowOk(v)) revert BadSetting("creditWindow");
        creditWindow = v;
        emit CreditWindowSet(v);
    }

    /// 10_000 to 40_000
    function setCreditFloorBps(uint16 v) external onlyOwner {
        if (!CreditBounds.floorBpsOk(v)) revert BadSetting("creditFloorBps");
        creditFloorBps = v;
        emit CreditFloorBpsSet(v);
    }

    /// 10_000 to 200_000
    function setCreditStartBps(uint32 v) external onlyOwner {
        if (!CreditBounds.startBpsOk(v)) revert BadSetting("creditStartBps");
        creditStartBps = v;
        emit CreditStartBpsSet(v);
    }

    // ------------------------------------------------------------------ pricing and sale

    /// the running level of sale prices now, bps of the reference: 10_000 plus the part of `storedAnchorBps` above
    /// 10_000, halved every `anchorHalfLife` since `anchorTime`
    function anchorBps() public view returns (uint32) {
        uint256 excess = storedAnchorBps - BPS;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(BPS + Halving.halve(excess, block.timestamp - anchorTime, anchorHalfLife));
    }

    /// the start price of a new statement, bps of the reference: the anchor times `markupBps`, at most `startCapBps`
    function startBps() public view returns (uint256) {
        uint256 start = uint256(anchorBps()) * markupBps / BPS;
        return start < startCapBps ? start : startCapBps;
    }

    /// the price reference of statement `sid`, wei: the larger of its cost and the eth bid rate before the pot clamp
    /// times its rating over `refScore`. the curve prices in bps of this value. reverts `NotForSale` for a statement
    /// the core does not hold
    function referenceOf(uint256 sid) public view returns (uint256) {
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        return _reference(cost, CORE.ratingOf(sid));
    }

    /// the larger of `cost` and `CORE.ethPrice()` times `rating` over `refScore`. `ethPrice` is the eth bid rate before
    /// the pot clamp, so a `sellTo` that enlarges the pot leaves the rate this reads unchanged within the block: the
    /// core checkpoints the climbed rate before the pot grows, and the climb heads toward the larger pot only in later
    /// blocks. one `mulDiv`, so the rate term divides at full precision
    function _reference(uint256 cost, uint256 rating) private view returns (uint256) {
        uint256 rate = FullMath.mulDiv(CORE.ethPrice(), rating, refScore);
        return rate > cost ? rate : cost;
    }

    /// the asking price of statement `sid` now, read from the core. never below the core hard floor
    /// `cost * saleFloorBps / 10_000`, and never below the redeemable value floor once the exit token pool key is set,
    /// so the quote is always a price `sellTo` takes. answers while paused
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,,) = _quote(sid);
        uint256 value = _value(sid);
        if (value > price) price = value;
    }

    /// true when the curve price of statement `sid` has reached its floor, `floorBps` of the reference. the curve age
    /// excludes paused seconds, so eligibility holds its value while sales are paused. the core hard floor does not
    /// enter this, so a `saleFloorBps` above the curve floor does not block eligibility. the core reads it to gate a
    /// phase 2 redemption
    function atFloor(uint256 sid) external view returns (bool) {
        (bool held, uint256 cost, uint64 composedAt) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        uint256 ref = _reference(cost, CORE.ratingOf(sid));
        return _ask(ref, _age(composedAt)) <= ref * floorBps / BPS;
    }

    /// pays the asking price, gets the statement at once, and moves the anchor halfway to the sale price in bps of
    /// cost when the cost is at least `anchorMinCost`. the excess of `msg.value` is refunded to the caller last
    function buy(uint256 sid) external payable {
        if (paused) revert Paused();
        if (_busy) revert Reentrant();
        _busy = true;
        (uint256 curve, uint256 cost, uint256 ref) = _quote(sid);
        uint256 value = _value(sid);
        uint256 price = value > curve ? value : curve;
        if (msg.value < price) revert Underpaid();
        _moveAnchor(sid, curve, cost, ref);
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    // ------------------------------------------------------------------ credit sale window

    /// the sale price of pile credit `id` now, wei. the floor is the highest of the credit's cost, its exit token
    /// baseline and the score-scaled eth backstop, times `creditFloorBps`. the start is the floor times
    /// `creditStartBps`. the price falls in a straight line from the start at the acquisition time to the floor at the
    /// acquisition time plus `creditWindow`, and rests at the floor after. reverts `NotForSale` for a credit not in the
    /// pile and `NoExitPrice` while an exit module is set and the baseline cannot be priced. answers whether or not the
    /// sale is on
    function creditPrice(uint256 id) public view returns (uint256 price) {
        (bool inPile, uint256 cost, uint64 acquiredAt) = CORE.creditInfo(id);
        if (!inPile) revert NotForSale();
        uint256 score = _scoreOf(id);
        uint256 hi = cost;
        uint256 base = _baseline(score);
        if (base > hi) hi = base;
        uint256 back = _backstop(score);
        if (back > hi) hi = back;
        uint256 floor = hi * creditFloorBps / BPS;
        uint256 start = floor * creditStartBps / BPS;
        uint256 age = block.timestamp - acquiredAt;
        if (age >= creditWindow) return floor;
        price = start - (start - floor) * age / creditWindow;
    }

    /// the exit token baseline in wei: `score` times the lower of the stored and live `unitPerPoint`, priced at the
    /// exit token pool, the same read the statement value floor uses. zero when no exit module is set. with a module
    /// set it reverts `NoExitPrice` for a failed or zero live unit read, an unset pool key or a zero pool price, and
    /// `BaselineOverflow` when `score` times unit overflows a word. a zero `score` or unit gives zero once the pool
    /// prices, so a failed score read leaves the floor to the cost and backstop terms
    function _baseline(uint256 score) private view returns (uint256) {
        address module = CORE.exitModule();
        if (module == address(0)) return 0;
        uint256 unit = CORE.unitPerPoint();
        (uint256 live, bool ok) = _liveUnit(module);
        if (!ok || live == 0) revert NoExitPrice();
        if (live < unit) unit = live;
        uint256 owed;
        if (score != 0 && unit != 0) {
            if (unit > type(uint256).max / score) revert BaselineOverflow();
            owed = score * unit;
        }
        (uint256 priceWei, bool priced) = _priceBaseUnits(owed);
        if (!priced) revert NoExitPrice();
        return priceWei;
    }

    /// the score-scaled eth backstop of a credit in wei: `ethPrice` when `score` is at or below `refScore`, else
    /// `ethPrice * score / refScore`, the scaling the statement reference applies. `ethPrice` is the eth bid rate
    /// before the pot clamp, so a sale through `sellCreditTo` that enlarges the pot cannot raise the rate the credit is
    /// priced against within the block. a `score` of zero (a failed score read) gives the unscaled rate
    function _backstop(uint256 score) private view returns (uint256) {
        uint256 eth = CORE.ethPrice();
        uint256 rs = refScore;
        if (score <= rs) return eth;
        return FullMath.mulDiv(eth, score, rs);
    }

    /// the credit score of `id` from the credit score contract, the same `scoreOf(seed, paidAt)` source the exit token
    /// bid reads in `sellForExitToken`, through a bounded staticcall of at most `READ_GAS`. a revert or a short answer
    /// reads as 0. `seedOf` and `timestampOf` are read directly: `creditPrice` calls this only for a credit the core
    /// holds in the pile, so those reads cannot revert
    function _scoreOf(uint256 id) private view returns (uint256) {
        bytes21 seed = ICredits(Mainnet.CREDITS).seedOf(id);
        uint64 paidAt = ICredits(Mainnet.CREDITS).timestampOf(id);
        (bool ok, bytes memory out) = Mainnet.CREDIT_SCORE.staticcall{gas: READ_GAS}(
            abi.encodeWithSelector(ICreditScore.scoreOf.selector, seed, paidAt)
        );
        return ok && out.length >= 32 ? abi.decode(out, (uint256)) : 0;
    }

    /// true when credit acquired at `acquiredAt` may be composed: always while the sale is off, otherwise once
    /// `creditWindow` has passed since its acquisition. the core and chosen composition test one credit with it
    function pastWindow(uint64 acquiredAt) public view returns (bool) {
        if (!creditSaleOn) return true;
        return uint256(acquiredAt) + creditWindow <= block.timestamp;
    }

    /// pays the sale price of credit `id`, gets the credit at once, and refunds the excess of `msg.value` last. reverts
    /// `CreditSaleOff` while the sale is off and `Paused` while sales are paused
    function buyCredit(uint256 id) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (paused) revert Paused();
        if (_busy) revert Reentrant();
        _busy = true;
        uint256 price = creditPrice(id);
        if (msg.value < price) revert Underpaid();
        ICoreSale(address(CORE)).sellCreditTo{value: price}(id, msg.sender);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    /// pays the sale prices of `ids` in order, gets the credits, and refunds the excess last. each credit is priced at
    /// the state left by the previous sale. the eth backstop reads `ethPrice`, which a credit sale leaves unchanged for
    /// the rest of the block, so within one batch a credit's price moves only through its own cost, baseline and age.
    /// reverts `CreditSaleOff` while the sale is off and `Paused` while sales are paused
    function buyCredits(uint256[] calldata ids) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (paused) revert Paused();
        if (_busy) revert Reentrant();
        _busy = true;
        uint256 n = ids.length;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 price = creditPrice(ids[i]);
            spent += price;
            if (msg.value < spent) revert Underpaid();
            ICoreSale(address(CORE)).sellCreditTo{value: price}(ids[i], msg.sender);
        }
        if (msg.value > spent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - spent);
        _busy = false;
    }

    /// the curve price of statement `sid` in wei with its cost basis and its reference. the price is `floorBps` to the
    /// start of the reference by the age curve, floored at the core hard floor `saleFloorBps` of cost
    function _quote(uint256 sid) private view returns (uint256 price, uint256 cost, uint256 ref) {
        bool held;
        uint64 composedAt;
        (held, cost, composedAt) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        ref = _reference(cost, CORE.ratingOf(sid));
        price = _ask(ref, _age(composedAt));
        uint256 floor = cost * ICoreSale(address(CORE)).settings().saleFloorBps / BPS;
        if (price < floor) price = floor;
    }

    /// the module's `unitPerPoint()` read with at most `READ_GAS`, the same gas the exit token bid forwards. copies at
    /// most 32 bytes of returndata, so a long answer cannot grief the gas. `ok` is false on a revert or an answer
    /// shorter than 32 bytes, where the unit reads 0
    function _liveUnit(address module) private view returns (uint256 unit, bool ok) {
        bytes4 sel = IExitModule.unitPerPoint.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(READ_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok) unit = 0;
    }

    /// the redeemable value of statement `sid` in wei from the exit token pool: `rating * unit` exit token base units
    /// priced at the pool sqrt price, where `unit` is the lower of the stored and the module's live `unitPerPoint()`
    /// (a failed live read gives 0). zero when the pool key is unset, no exit module is set, the owed amount is
    /// zero, or the pool sqrt price reads zero
    function _value(uint256 sid) private view returns (uint256) {
        if (!exitPoolKeySet) return 0;
        if (CORE.exitModule() == address(0)) return 0;
        uint256 unit = CORE.unitPerPoint();
        (uint256 live,) = _liveUnit(CORE.exitModule());
        if (live < unit) unit = live;
        uint256 owed = CORE.ratingOf(sid) * unit;
        if (owed == 0) return 0;
        (uint256 priceWei, bool priced) = _priceBaseUnits(owed);
        return priced ? priceWei : 0;
    }

    /// `exitTokenBaseUnits` priced in wei at the exit token pool. reverts `NoExitPrice` when the pool key is unset or
    /// the pool sqrt price reads zero. the core reads it in `sellForExitToken` to value the exit tokens a credit was
    /// bought for
    function valueWei(uint256 exitTokenBaseUnits) external view returns (uint256 priceWei) {
        bool priced;
        (priceWei, priced) = _priceBaseUnits(exitTokenBaseUnits);
        if (!priced) revert NoExitPrice();
    }

    /// `baseUnits` of the exit token priced in wei at the exit token pool. `priced` is false when the pool key is
    /// unset or the pool sqrt price reads zero. native eth is `currency0`, so wei per token base unit is
    /// `(2^96 / sqrtPrice)^2`. `mulDiv` carries the sqrt price squared at full precision
    function _priceBaseUnits(uint256 baseUnits) private view returns (uint256 priceWei, bool priced) {
        if (!exitPoolKeySet) return (0, false);
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(exitPoolKey.toId());
        if (sqrtPriceX96 == 0) return (0, false);
        uint256 q = FixedPoint96.Q96;
        uint256 p = sqrtPriceX96;
        priceWei = FullMath.mulDiv(FullMath.mulDiv(baseUnits, q, p), q, p);
        priced = true;
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

    /// with `cost` at least `anchorMinCost`, a sale price in bps of the reference (rounded up) above the anchor sets the
    /// anchor to the mean of the two, at most `startCapBps`. every other sale leaves the stored anchor and `anchorTime`
    /// unchanged. measuring in bps of the reference keeps a rating-rich statement sold at the normal markup from moving
    /// the anchor
    function _moveAnchor(uint256 sid, uint256 price, uint256 cost, uint256 ref) private {
        if (cost < anchorMinCost) return;
        // a zero reference would divide by zero below
        if (ref == 0) return;
        uint256 saleBps = (price * BPS + ref - 1) / ref;
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

    /// the asking price in wei after `age` seconds, a fraction of `ref` by the bps curve. the bps is held in units of
    /// 1/3600 so each stage is an integer line of the second: it falls by `fastDecayBpsPerHour` units a second from the
    /// start to the knee and by `slowDecayBpsPerHour` units a second after, never below `floorBps`. the slow stage
    /// starts at the second the fast stage reaches the knee, which is `(start - knee) / fastDecayBpsPerHour` hours and
    /// need not be a whole second, so its fall is rounded up. the rounding keeps the price non-increasing in `age`
    function _ask(uint256 ref, uint256 age) private view returns (uint256) {
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
        return ref * n / (1 hours * BPS);
    }

    // ------------------------------------------------------------------ credit picking

    /// ready when the pile holds a full page. the page is the 80 oldest credits with format 0. while the credit sale is
    /// on the page is ready only once the newest of its 80 credits is past its window; the pile is oldest first, so that
    /// credit is the last of the page
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize() < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(0, PAGE);
        if (creditSaleOn) {
            (,, uint64 acquiredAt) = CORE.creditInfo(page[PAGE - 1]);
            if (!pastWindow(acquiredAt)) return (false, ids, 0);
        }
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }
}
