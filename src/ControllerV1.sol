// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {
    Sale,
    Credit,
    CreditSale,
    Quote,
    Settings,
    IController,
    ICoreViews,
    ICoreSale,
    ICreditScore,
    ICredits,
    IBalanceModule,
    Mainnet,
    RATE_SCORE,
    POINT_UNIT
} from "./interfaces/Interfaces.sol";
import {CreditBounds} from "./lib/CreditBounds.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// first policy module. pages the oldest 80 pile credits for the Core, which picks the format.
/// it prices and sells statements and pile credits. the point rate is `core.floorRate() / RATE_SCORE`, where
/// `RATE_SCORE` is 100 points in score units (one ten-thousandth of a point each), and `valueOf(points)` is the larger of
/// `floorRate * points / RATE_SCORE` and the balance token pool value of `points * unitPerPoint` base units, with
/// `unitPerPoint` read from the balance module at each call. the reference of a statement is the larger of its cost and
/// `valueOf(rating)`. the asking price is a fraction of the reference in bps that starts at
/// `start = min(anchorBps * markupBps / 10_000, startCapBps)` and falls in a straight line to the core setting
/// `saleFloorBps` over `decayHours` hours, where it rests. a `start` at or below `saleFloorBps` is the floor from the
/// first second. the price is computed at every call from the age of the statement (time since its compose) and the
/// current settings, so a setting change applies to held statements at once.
/// `saleFloorBps` has two readings: the core takes no payment below `cost * saleFloorBps / 10_000`, and the curve here
/// floors at `reference * saleFloorBps / 10_000`. the reference is at least the cost, so the curve floor is at least the
/// core floor.
/// `anchorBps` (at least 10_000) is the running level of sale prices in bps of the reference. it moves up with sales and
/// down with time. a `buy` of a statement whose cost is at least `anchorMinCost` and whose sale price in bps of the
/// reference is above the anchor moves it by anchorMoveBps of the upward gap. other sales leave it unchanged.
/// the part of the anchor above 10_000 halves every `anchorHalfLife`, continuously. the controller stores the anchor at
/// its last change (`storedAnchorBps`, `anchorTime`) and evaluates the decay at the call. the price is computed from the
/// current anchor at every call, so held statements follow it.
/// `buy` sells a held statement at once at the asking price.
/// a pile credit sells at `max(cost, valueOf(score)) * floorMultBps() / 10_000` at the end of its window, from
/// `creditStartBps` of that at its acquisition. `floorMultBps()` is `(10_000 + creditSpreadBps)` of the Core's live
/// `balanceBidCapBps`, at least 10_000, so the floor follows every change of the bid's hard cap.
/// `atFloor(sid)` gates redemption. with `ageEligibilityOn` it is by age only: true once the start is at or below 10_000
/// or the statement has aged `decayHours`. with `ageEligibilityOn` false (launch) it compares the curve price with its
/// floor, reading the reference.
/// the owner of the core can pause sales (`core.setPaused`). while paused the core reverts `Paused` in `sellTo` and
/// `sellCreditTo`, so `buy` and `buyCredit` revert, and `priceOf` answers. the age of a statement is
/// `core.statementAge`, which excludes every paused second, so the age of a held statement stops advancing for the
/// length of a pause and continues from the same age at resume. the anchor decays with wall time in both states, so the
/// start of the curve, and with it the asking price, can still fall in a pause while the anchor is above 10_000.
/// its settings belong to the live owner of the core (`core.owner()`), there is no second owner.
/// once the owner sets the balance token pool (`setBalancePoolKey`), `valueOf` includes the pool term. the pool term is
/// 0 with the pool key unset, with the stored pool key's `currency1` other than the Core's current `balanceToken()`
/// (a stale key after an owner module replacement), with no balance module set, on a failed, zero or above
/// `uint128.max` unit read, or on a zero pool read.
/// the protected price (decision 148): the controller keeps a reference price of the balance token, set to the pool spot
/// by `setBalancePoolKey` and moved toward the spot by `refreshReference()` and the sale doors by at most
/// `min(referenceRateBpsPerHour * elapsed / 3600, referenceStepBps)` bps of the reference per update. a refresh runs at
/// most once per block and stores the spot and liquidity it sampled. buys price off `min(spotSample, reference *
/// (10_000 + tolBps) / 10_000)`, sales off `max(spotSample, reference * (10_000 - tolBps) / 10_000)`, where `spotSample`
/// is the spot taken at a prior block's refresh, never the live spot, so a same-block pool move cannot change the quote.
/// the reference price is usable while the sample is at most `referenceMaxStale` old, the two most recent liquidity
/// samples both hold `minLiquidity` and the unit read succeeds. in value mode (the Core's `valueModeOn`) `valueOf` is the
/// sale price value with the floor rate and cost terms dropped, a statement's reference is that value times
/// `floorMultBps()` and its curve rests at 10_000 of it, and the price views and the sale doors revert `NoQuote` while
/// the quote is unusable. the views and the sale doors run a read-only projected refresh so a view equals the price the
/// same-block sale door charges (decision 159)
contract ControllerV1 is IController {
    using StateLibrary for IPoolManager;

    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;
    /// gas of the controller's read of the balance module's `unitPerPoint()`. the Core allows `atFloor` 400,000 gas in all
    uint256 private constant UNIT_GAS = 50_000;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error Reentrant();
    /// a credit sale door was called while the credit sale window is off
    error CreditSaleOff();
    /// a value mode price was read while the quote is unusable
    error NoQuote();

    event SaleSet(Sale sale);
    event CreditSaleSet(CreditSale credit);
    event AgeEligibilitySet(bool on);
    event AnchorBpsSet(uint32 anchorBps);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);
    event BalancePoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event QuoteSet(Quote quote);
    /// a refresh of the reference price: the reference after it and the spot it moved toward, wei per 1e18 base units
    event ReferenceRefreshed(uint256 referencePrice, uint256 spot);

    ICoreViews public immutable CORE;

    /// start price over the anchor, bps. 10_000 to uint16.max, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of the reference. `markupBps` to uint32.max
    uint32 public startCapBps;
    /// hours for the asking price to fall in a straight line from the start to the floor, then rest. 1 to uint16.max
    uint16 public decayHours;
    /// the anchor at `anchorTime`, bps of the reference. 10_000 to `startCapBps`. `anchorBps()` is the value now
    uint32 public storedAnchorBps;
    /// when `storedAnchorBps` was last set
    uint40 public anchorTime;
    /// seconds for the part of the anchor above 10_000 to halve. 1 to uint32.max seconds
    uint32 public anchorHalfLife;
    /// the least statement cost, in wei, whose `buy` moves the anchor. 0 to uint128.max
    uint128 public anchorMinCost;
    /// Share of the upward anchor gap moved by a qualifying sale, 0 to 10,000.
    uint16 public anchorMoveBps;
    bool private _busy;
    /// whether the balance token pool key is set. launch value false
    bool public balancePoolKeySet;
    /// the uniswap v4 pool of the balance token against native eth, used to price the redeemable value floor. native eth
    /// is `currency0` (the zero address) and the balance token is `currency1`, the only order a native eth pool sorts to.
    /// unset at launch
    PoolKey public balancePoolKey;

    /// whether pile credits are for sale from their acquisition time and compose waits for a credit's window to pass.
    /// launch value true
    bool public creditSaleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit must sit before compose
    /// may take it. 1 to uint32.max seconds
    uint32 public creditWindow;
    /// the sale spread over the bid's hard cap, bps: the credit floor multiplier is `(10_000 + creditSpreadBps)` of the
    /// Core's `balanceBidCapBps`. 0 to uint16.max
    uint16 public creditSpreadBps;
    /// the credit sale start price over the floor, bps. 10_000 to uint32.max
    uint32 public creditStartBps;
    /// when true, `atFloor` is by age only: the start at or below 10_000, or the statement aged `decayHours`, with no
    /// reference read. when false, `atFloor` compares the curve price with its floor and reads the reference. launch
    /// value false; the owner turns it on with the value switch (decision 155)
    bool public ageEligibilityOn;

    /// the reference price settings (decision 148)
    Quote public quote;
    /// the reference price of the balance token, wei per 1e18 base units, 0 until the pool key is set
    uint256 public referencePrice;
    /// the sample time of `referencePrice`: the moment the stored reference was sampled from the spot
    uint40 public referenceTime;
    /// the pool spot sampled at the two most recent refreshes, newest in `spotSampleA`, wei per 1e18 base units. the
    /// executable quote clamps the band to the sample taken in a prior block, so a same-block pool move cannot change
    /// the bid or the ask
    uint256 private spotSampleA;
    uint256 private spotSampleB;
    /// the pool liquidity sampled at the two most recent refreshes, newest in `liqSampleA`. the quote is usable only
    /// while both hold `minLiquidity`, so liquidity added for one block cannot open the quote
    uint128 private liqSampleA;
    uint128 private liqSampleB;
    /// the block of the last reference refresh. a refresh runs at most once per block
    uint48 private lastRefreshBlock;

    constructor(address core, Sale memory sale, Credit memory credit, Quote memory quote_) {
        CORE = ICoreViews(core);
        _setSale(sale);
        storedAnchorBps = uint32(BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
        _setCredit(
            CreditSale({
                saleOn: credit.saleOn, window: credit.window, spreadBps: credit.spreadBps, startBps: credit.startBps
            })
        );
        _setQuote(quote_);
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ sale settings, owner, at once

    /// sets the six sale settings at once. every field is checked against the bounds of the others in the call:
    /// `markupBps` 10_000 to uint16.max, at least the core's `saleFloorBps` and at most `startCapBps`; `startCapBps` at
    /// least `markupBps`, at most uint32.max; `decayHours` 1 to uint16.max; `anchorHalfLife` 1 to uint32.max seconds;
    /// `anchorMinCost` 0 to uint128.max. an `anchorBps()` above the new `startCapBps` is lowered to it. a change of
    /// `anchorHalfLife` stores the anchor at the call first, so the new half life applies from now on
    function setSale(Sale calldata v) external onlyOwner {
        if (v.anchorHalfLife != anchorHalfLife) _setAnchorStored(anchorBps());
        _setSale(v);
        emit SaleSet(v);
        if (anchorBps() > v.startCapBps) _setAnchor(v.startCapBps);
    }

    function _setSale(Sale memory v) private {
        if (v.markupBps < BPS) revert BadSetting("markupBps");
        // the sale floor can never be above the start: refuse a start below the core's current `saleFloorBps`. the read
        // is skipped while the core has no code yet, the constructor deployed before its core (the address is predicted)
        if (address(CORE).code.length != 0 && v.markupBps < ICoreSale(address(CORE)).settings().saleFloorBps) {
            revert BadSetting("markupBps");
        }
        if (v.startCapBps < v.markupBps) revert BadSetting("startCapBps");
        if (v.decayHours < 1) revert BadSetting("decayHours");
        if (v.anchorHalfLife < 1) revert BadSetting("anchorHalfLife");
        if (v.anchorMoveBps > BPS) revert BadSetting("anchorMoveBps");
        markupBps = v.markupBps;
        startCapBps = v.startCapBps;
        decayHours = v.decayHours;
        anchorHalfLife = v.anchorHalfLife;
        anchorMinCost = v.anchorMinCost;
        anchorMoveBps = v.anchorMoveBps;
    }

    /// 10_000 to `startCapBps`. replaces the running level of sale prices and restarts its decay
    function setAnchorBps(uint32 v) external onlyOwner {
        if (v < BPS || v > startCapBps) revert BadSetting("anchorBps");
        _setAnchor(v);
    }

    /// sets the native eth / balance token pool whose sqrt price prices the pool term of `valueOf`.
    /// `currency0` must be native eth (the zero address) and `currency1` the core's current balance token, the order a
    /// native eth pool sorts to. the pool must be initialized, so `valueOf` reads a live price at once. the reference is
    /// seeded from the live spot, and the owner passes `expectedSpot` (wei per 1e18 base units): a live spot more than
    /// `tolBps` from it reverts, so the reference is not seeded from a pool moved or manipulated between signing and
    /// landing. effective at once
    function setBalancePoolKey(PoolKey calldata key, uint256 expectedSpot) external onlyOwner {
        address token = CORE.balanceToken();
        if (token == address(0)) revert BadSetting("balanceToken");
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != address(0) || c1 != token) revert BadSetting("balancePoolKey");
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert BadSetting("balancePoolKey");
        balancePoolKey = key;
        balancePoolKeySet = true;
        emit BalancePoolKeySet(c0, c1, key.fee, key.tickSpacing, address(key.hooks));
        // the reference starts at the spot of the key the owner sets, in the owner's transaction
        (uint256 spot,) = _spot();
        uint256 band = expectedSpot * quote.tolBps / BPS;
        if (spot < expectedSpot - band || spot > expectedSpot + band) revert BadSetting("spot");
        // seed both sample slots from the live spot and liquidity, so the first quote reads a sample from this block
        uint128 liq = _sampleLiq();
        spotSampleA = spot;
        spotSampleB = spot;
        liqSampleA = liq;
        liqSampleB = liq;
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        _setRef(spot, spot);
    }

    /// the pool liquidity of the balance token pool now, the sample the quote's `minLiquidity` gate reads
    function _sampleLiq() private view returns (uint128) {
        return IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(balancePoolKey.toId());
    }

    /// sets the reference price settings at once. `referenceStepBps` 0 to 10_000, `tolBps` 0 to 9_999
    function setQuote(Quote calldata v) external onlyOwner {
        _setQuote(v);
    }

    function _setQuote(Quote memory v) private {
        if (v.referenceStepBps > BPS) revert BadSetting("referenceStepBps");
        if (v.tolBps >= BPS) revert BadSetting("tolBps");
        // the rate, the step and the staleness are all set or all zero: a partial triple would move or expire the
        // reference without the matching bound, a misconfiguration
        bool anyRef = v.referenceRateBpsPerHour != 0 || v.referenceStepBps != 0 || v.referenceMaxStale != 0;
        bool allRef = v.referenceRateBpsPerHour != 0 && v.referenceStepBps != 0 && v.referenceMaxStale != 0;
        if (anyRef && !allRef) revert BadSetting("referenceTriple");
        // the sale spread covers the worst round trip through the reference band at the current credit spread
        _checkLoopClosure(v.tolBps, creditSpreadBps);
        // the reference band widened by the sale spread stays inside the bid margin, so a buy from the bid and a sale
        // back loses in either currency. the Core read is skipped while the Core has no code yet (constructor order)
        if (address(CORE).code.length != 0) {
            uint256 margin = ICoreSale(address(CORE)).settings().balanceBidMarginBps;
            if ((BPS + v.referenceStepBps) * (BPS + v.tolBps) * (BPS - margin) >= BPS * BPS * BPS) {
                revert BadSetting("referenceBand");
            }
        }
        quote = v;
        emit QuoteSet(v);
    }

    /// the sale spread (bps over the bid cap) must cover the worst round trip through the reference band: with a buy at
    /// the band top `(10_000 + tol)` and a sale floor at the band bottom `(10_000 - tol)`, the ask clears the bid only
    /// when `(10_000 + spread) >= (10_000 + tol) * 10_000 / (10_000 - tol)` (the bid cap cancels on both sides). about
    /// 1,053 at `tol` 500, 943 at 450
    function _checkLoopClosure(uint256 tol, uint256 spread) private pure {
        uint256 num = (BPS + tol) * BPS;
        uint256 den = BPS - tol;
        uint256 req = (num + den - 1) / den - BPS;
        if (spread < req) revert BadSetting("creditSpreadBps");
    }

    // ------------------------------------------------------------------ the protected price

    /// moves the reference toward the pool spot by at most
    /// `min(referenceRateBpsPerHour * elapsed / 3600, referenceStepBps)` bps of the reference. anyone may call; the sale
    /// doors call it first. no move with no reference, with `referenceMaxStale` zero (mode off), before
    /// `referenceMinSeconds` has passed since the last sample, or on a zero spot. when the integer move floors to zero
    /// the sample time is left unchanged, so a rate too small for a one bps move over the elapsed time still tracks
    /// under frequent calls; a nonzero move resets the sample to now. repeated calls gain nothing beyond the rate.
    /// returns true when it updated the reference, so the Core's `refreshReference` door pays the caller only for work
    function refreshReference() public returns (bool) {
        // at most one refresh per block, so a sample the quote clamps to is always from a prior block
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint48(block.number) == lastRefreshBlock) return false;
        uint256 ref = referencePrice;
        if (ref == 0) return false;
        Quote memory q = quote;
        if (q.referenceMaxStale == 0) return false;
        uint256 elapsed = block.timestamp - referenceTime;
        if (elapsed < q.referenceMinSeconds) return false;
        (uint256 spot, bool ok) = _spot();
        if (!ok || spot == 0) return false;
        uint256 move = uint256(q.referenceRateBpsPerHour) * elapsed / 1 hours;
        if (move > q.referenceStepBps) move = q.referenceStepBps;
        // a move that floors to zero leaves the sample untouched, so the sub bps time keeps accumulating until the next
        // call clears one bps; the reference is not pinned when the per call interval is short against the rate
        if (move == 0) return false;
        uint256 hi = ref * (BPS + move) / BPS;
        uint256 lo = ref * (BPS - move) / BPS;
        // shift the sample history: the most recent spot and liquidity become the previous, this block's become the most
        // recent. the quote clamps to the previous sample and checks `minLiquidity` at both
        spotSampleB = spotSampleA;
        liqSampleB = liqSampleA;
        spotSampleA = spot;
        liqSampleA = _sampleLiq();
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        _setRef(spot > hi ? hi : spot < lo ? lo : spot, spot);
        return true;
    }

    function _setRef(uint256 ref, uint256 spot) private {
        referencePrice = ref;
        // forge-lint: disable-next-line(unsafe-typecast)
        referenceTime = uint40(block.timestamp);
        emit ReferenceRefreshed(ref, spot);
    }

    /// @notice the pool spot of the balance token, wei per 1e18 base units, the price `refreshReference()` moves the
    /// reference toward. the web shows it against `referencePrice`. false as in `_spot`
    function spotPrice() external view returns (uint256 spot, bool ok) {
        return _spot();
    }

    /// the pool spot of the balance token, wei per 1e18 base units. false with no pool key, a key for another token than
    /// the Core's, a zero sqrt price or a product above 256 bits
    function _spot() private view returns (uint256 spot, bool ok) {
        return _priceBaseUnits(1e18);
    }

    /// the buy price, the sale price and the unit, wei per 1e18 base units and base units per score unit, and whether the
    /// reference price is usable. the band is centred on the reference and clamped to the pool spot sampled at the last
    /// refresh (a prior block), never the live spot, so a same-block pool move cannot change the quote. the quote is
    /// usable with a reference set, the sample at most `referenceMaxStale` old, both of the two most recent liquidity
    /// samples at least `minLiquidity`, a balance module set and a unit read.
    /// with `project` true the views and the sale doors run the read-only equivalent of `refreshReference` first, so a
    /// view read in the same block as a sale door's refresh equals the price the door charges (decision 159, C03). the
    /// Core's eth bid reads it with `project` false, so a lapsed refresh reads stale and the bid falls back
    function _protected(bool project) private view returns (uint256 pBuy, uint256 pSell, uint256 unit, bool ok) {
        Quote memory q = quote;
        uint256 ref = referencePrice;
        if (ref == 0 || q.referenceMaxStale == 0) return (0, 0, 0, false);
        uint256 t = referenceTime;
        uint256 sA = spotSampleA;
        uint256 sB = spotSampleB;
        uint256 lA = liqSampleA;
        uint256 lB = liqSampleB;
        // forge-lint: disable-next-line(unsafe-typecast)
        bool aThisBlock = uint48(block.number) == lastRefreshBlock;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (project && !aThisBlock && block.timestamp - t >= q.referenceMinSeconds) {
            (uint256 spot, bool priced) = _spot();
            if (priced && spot != 0) {
                uint256 move = uint256(q.referenceRateBpsPerHour) * (block.timestamp - t) / 1 hours;
                if (move > q.referenceStepBps) move = q.referenceStepBps;
                if (move != 0) {
                    uint256 hi = ref * (BPS + move) / BPS;
                    uint256 lo = ref * (BPS - move) / BPS;
                    ref = spot > hi ? hi : spot < lo ? lo : spot;
                    sB = sA;
                    lB = lA;
                    sA = spot;
                    lA = _sampleLiq();
                    t = block.timestamp;
                    aThisBlock = true;
                }
            }
        }
        if (block.timestamp - t > q.referenceMaxStale) return (0, 0, 0, false);
        if (lA < q.minLiquidity || lB < q.minLiquidity) return (0, 0, 0, false);
        // the clamp spot is a prior block's sample: the previous one when the latest was taken this block
        uint256 spotNow = aThisBlock ? sB : sA;
        address module = CORE.balanceModule();
        if (module == address(0)) return (0, 0, 0, false);
        (unit, ok) = _liveUnit(module);
        if (!ok) return (0, 0, 0, false);
        uint256 up = ref * (BPS + q.tolBps) / BPS;
        uint256 down = ref * (BPS - q.tolBps) / BPS;
        pBuy = spotNow < up ? spotNow : up;
        pSell = spotNow > down ? spotNow : down;
    }

    /// the wei value of one point at the protected price, see `IController.valuePerPoint`
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok) {
        uint256 pBuy;
        uint256 pSell;
        uint256 unit;
        // the Core's eth bid reads the stored reference without a projected refresh, so a lapsed refresh reads stale and
        // the Core falls back to the eth instance rather than halting (decision 159, C02)
        (pBuy, pSell, unit, ok) = _protected(false);
        if (!ok) return (0, false);
        value = forSale
            ? FullMath.mulDivRoundingUp(POINT_UNIT * unit, pSell, 1e18)
            : FullMath.mulDiv(POINT_UNIT * unit, pBuy, 1e18);
    }

    /// the Core's settings, read once per door and threaded through the pricing path so a single call reads them once,
    /// not the four to five times a per field read would (gas, mostly for the mode off doors)
    function _cfg() private view returns (Settings memory) {
        return ICoreSale(address(CORE)).settings();
    }

    // ------------------------------------------------------------------ credit sale settings, owner, at once

    /// sets the credit sale settings at once. `saleOn` turns the credit sale window on or off: while on, pile credits
    /// are for sale through `buyCredit` and compose takes only credits past their window. `window` 1 to uint32.max seconds,
    /// `spreadBps` 0 to uint16.max, `startBps` 10_000 to uint32.max
    function setCredit(CreditSale calldata v) external onlyOwner {
        _setCredit(v);
        emit CreditSaleSet(v);
    }

    /// switches redemption eligibility between the age only rule (true) and the reference curve rule (false). launch
    /// value false; the owner turns it on with the value switch (decision 155)
    function setAgeEligibilityOn(bool v) external onlyOwner {
        ageEligibilityOn = v;
        emit AgeEligibilitySet(v);
    }

    function _setCredit(CreditSale memory v) private {
        if (!CreditBounds.windowOk(v.window)) revert BadSetting("creditWindow");
        if (!CreditBounds.startBpsOk(v.startBps)) revert BadSetting("creditStartBps");
        // the sale spread covers the worst round trip through the reference band at the current reference tolerance
        _checkLoopClosure(quote.tolBps, v.spreadBps);
        creditSaleOn = v.saleOn;
        creditWindow = v.window;
        creditSpreadBps = v.spreadBps;
        creditStartBps = v.startBps;
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

    /// wei per score unit: `core.floorRate()` over `RATE_SCORE` (100 points in score units), rounded down. `valueOf`
    /// divides once on the product
    function pointRate() public view returns (uint256) {
        return CORE.floorRate() / RATE_SCORE;
    }

    /// the value in wei of `points` score units: the larger of `floorRate * points / RATE_SCORE` and the balance token
    /// pool value of `points * unitPerPoint` base units. `unitPerPoint` is read from the balance module in the call. the
    /// pool term is 0 when the pool key is unset, no balance module is set, the unit read fails, is zero or exceeds
    /// `uint128.max`, the pool reads zero, or the pool pricing exceeds 256 bits. in value mode it is `points * unitPerPoint`
    /// base units at the protected sale price, rounded up, with the floor rate term dropped, and reverts `NoQuote` while
    /// the quote is unusable
    function valueOf(uint256 points) public view returns (uint256) {
        return _valueOf(points, _cfg());
    }

    function _valueOf(uint256 points, Settings memory cfg) private view returns (uint256) {
        if (cfg.valueModeOn) {
            (, uint256 pSell, uint256 unit, bool ok) = _protected(true);
            if (!ok) revert NoQuote();
            return FullMath.mulDivRoundingUp(points * unit, pSell, 1e18);
        }
        uint256 rate = FullMath.mulDiv(CORE.floorRate(), points, RATE_SCORE);
        uint256 pool = _poolValue(points);
        return pool > rate ? pool : rate;
    }

    /// the price reference of statement `sid`, wei: the larger of its cost and `valueOf(rating)`. the curve prices in bps
    /// of this value. reverts `NotForSale` for a statement the core does not hold
    function referenceOf(uint256 sid) public view returns (uint256) {
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        return _reference(cost, CORE.ratingOf(sid), _cfg());
    }

    /// the reference of a statement of `cost` and `rating`: the larger of its cost and `valueOf(rating)`; in value mode
    /// the protected floor `valueOf(rating) * floorMultBps() / 10_000`, the cost term dropped (decision 150)
    function _reference(uint256 cost, uint256 rating, Settings memory cfg) private view returns (uint256) {
        uint256 value = _valueOf(rating, cfg);
        if (cfg.valueModeOn) return value * _floorMult(cfg) / BPS;
        return value > cost ? value : cost;
    }

    /// the asking price of statement `sid` now, read from the core: the curve on the reference, at least
    /// `saleFloorBps` of the reference, so the quote is always a price `sellTo` takes. answers while paused
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,,) = _quote(sid, _cfg());
    }

    /// true when statement `sid` is eligible for redemption. with `ageEligibilityOn` the rule is age only: the start at
    /// or below 10_000, or the statement aged `decayHours`, with no price or pool read, so eligibility never restarts on
    /// a price move and never waits on a quote. with `ageEligibilityOn` false (the launch rule) the curve price is
    /// compared with its floor, which reads the reference. the age excludes paused seconds, so eligibility holds its
    /// value while sales are paused. reverts `NotForSale` for a statement the core does not hold. the core reads it to
    /// gate a balance side redemption
    function atFloor(uint256 sid) external view returns (bool) {
        if (ageEligibilityOn) {
            return startBps() <= BPS || CORE.statementAge(sid) >= uint256(decayHours) * 1 hours;
        }
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        Settings memory cfg = _cfg();
        uint256 ref = _reference(cost, CORE.ratingOf(sid), cfg);
        uint256 floor = cfg.saleFloorBps;
        return _ask(ref, CORE.statementAge(sid), floor) <= ref * floor / BPS;
    }

    /// pays the asking price, gets the statement at once, and moves the anchor halfway to the sale price in bps of the
    /// reference when the cost is at least `anchorMinCost`. the excess of `msg.value` is refunded to the caller last
    function buy(uint256 sid) external payable {
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        (uint256 price, uint256 cost, uint256 ref) = _quote(sid, _cfg());
        if (msg.value < price) revert Underpaid();
        _moveAnchor(sid, price, cost, ref);
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    // ------------------------------------------------------------------ credit sale window

    /// the sale price of pile credit `id` now, wei. the floor is the larger of the credit's cost and `valueOf` of its
    /// score, times `floorMultBps()`; in value mode `valueOf` alone, the cost term dropped. the floor is at least
    /// `saleFloorBps` of the cost, the Core's floor of `sellCreditTo`. the start is the floor times `creditStartBps`. the price falls in
    /// a straight line from the start at the acquisition time to the floor at the acquisition time plus `creditWindow`,
    /// and rests at the floor after. reverts `NotForSale` for a credit not in the pile. answers whether or not the sale is on
    function creditPrice(uint256 id) public view returns (uint256 price) {
        return _creditPrice(id, _cfg());
    }

    function _creditPrice(uint256 id, Settings memory cfg) private view returns (uint256 price) {
        (bool inPile, uint256 cost, uint64 acquiredAt) = CORE.creditInfo(id);
        if (!inPile) revert NotForSale();
        uint256 hi = _valueOf(_scoreOf(id), cfg);
        if (cost > hi && !cfg.valueModeOn) hi = cost;
        uint256 floor = hi * _floorMult(cfg) / BPS;
        // never under the Core's floor of `sellCreditTo`, so the quote is always a price the Core takes
        uint256 coreFloor = cost * cfg.saleFloorBps / BPS;
        if (floor < coreFloor) floor = coreFloor;
        uint256 start = floor * creditStartBps / BPS;
        uint256 age = block.timestamp - acquiredAt;
        if (age >= creditWindow) return floor;
        price = start - (start - floor) * age / creditWindow;
    }

    /// the credit floor multiplier now, bps: `(10_000 + creditSpreadBps) * balanceBidCapBps / 10_000` with the Core's cap
    /// read live, at least 10_000. the most the engine pays for a credit is the cap times its value, so a buy at the floor
    /// and a sale back into the bid at its ceiling loses at least the spread
    function floorMultBps() public view returns (uint256) {
        return _floorMult(_cfg());
    }

    function _floorMult(Settings memory cfg) private view returns (uint256) {
        uint256 m = (BPS + creditSpreadBps) * cfg.balanceBidCapBps / BPS;
        return m < BPS ? BPS : m;
    }

    /// the credit score of `id` from the credit score contract, `scoreOf(seed, paidAt)`, the score source of every Core
    /// door. `scoreOf` is pure on a fixed verified contract, so the call is direct.
    /// `creditPrice` calls this only for a credit the core holds in the pile, so the reads cannot revert
    function _scoreOf(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
    }

    /// true when credit acquired at `acquiredAt` may be composed: always while the sale is off, otherwise once
    /// `creditWindow` has passed since its acquisition. the core and chosen composition test one credit with it
    function pastWindow(uint64 acquiredAt) public view returns (bool) {
        if (!creditSaleOn) return true;
        return uint256(acquiredAt) + creditWindow <= block.timestamp;
    }

    /// pays the sale price of credit `id`, gets the credit at once, and refunds the excess of `msg.value` last. reverts
    /// `CreditSaleOff` while the sale is off and, through the core, `Paused` while sales are paused
    function buyCredit(uint256 id) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        uint256 price = _creditPrice(id, _cfg());
        if (msg.value < price) revert Underpaid();
        ICoreSale(address(CORE)).sellCreditTo{value: price}(id, msg.sender);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    /// pays the sale prices of `ids` in order, gets the credits, and refunds the excess last. each credit is priced at
    /// the state left by the previous sale. the floor rate is unchanged by a credit sale for the rest of the block, so
    /// within one batch a credit's price moves only through its own cost, score and age. reverts `CreditSaleOff` while
    /// the sale is off and, through the core, `Paused` while sales are paused
    function buyCredits(uint256[] calldata ids) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        Settings memory cfg = _cfg();
        uint256 n = ids.length;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 price = _creditPrice(ids[i], cfg);
            spent += price;
            if (msg.value < spent) revert Underpaid();
            ICoreSale(address(CORE)).sellCreditTo{value: price}(ids[i], msg.sender);
        }
        if (msg.value > spent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - spent);
        _busy = false;
    }

    /// the curve price of statement `sid` in wei with its cost basis and its reference. the price is the age curve on the
    /// reference, at least `saleFloorBps` of the reference; in value mode at least the reference, the protected floor
    function _quote(uint256 sid, Settings memory cfg) private view returns (uint256 price, uint256 cost, uint256 ref) {
        bool held;
        (held, cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        ref = _reference(cost, CORE.ratingOf(sid), cfg);
        price = _ask(ref, CORE.statementAge(sid), cfg.valueModeOn ? BPS : cfg.saleFloorBps);
    }

    /// the module's `unitPerPoint()` read with at most `UNIT_GAS`. copies at most 32 bytes of returndata, so a long answer
    /// cannot grief the gas. `ok` is false, and the unit reads 0, on a revert, an answer shorter than 32 bytes, a zero
    /// unit or a unit above `type(uint128).max`, the same reads the Core's balance doors revert `BadModule` on
    function _liveUnit(address module) private view returns (uint256 unit, bool ok) {
        bytes4 sel = IBalanceModule.unitPerPoint.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(UNIT_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok || unit == 0 || unit > type(uint128).max) return (0, false);
    }

    /// the balance token pool value of `points` score units in wei: `points * unitPerPoint` base units priced at the pool
    /// sqrt price. `unitPerPoint` is read from the balance module in the call. never reverts: 0 when the pool key is
    /// unset, the stored pool key's `currency1` is not the Core's current `balanceToken()`, no balance module is set,
    /// the unit read fails (see `_liveUnit`), the owed amount is zero, the pool sqrt price reads zero, or a product of
    /// the pricing exceeds 256 bits
    function _poolValue(uint256 points) private view returns (uint256) {
        if (!balancePoolKeySet) return 0;
        address module = CORE.balanceModule();
        if (module == address(0)) return 0;
        (uint256 unit, bool ok) = _liveUnit(module);
        if (!ok) return 0;
        uint256 baseUnits;
        unchecked {
            baseUnits = points * unit;
        }
        if (points != 0 && baseUnits / points != unit) return 0;
        (uint256 priceWei, bool priced) = _priceBaseUnits(baseUnits);
        return priced ? priceWei : 0;
    }

    /// `baseUnits` of the balance token priced in wei at the balance token pool. `priced` is false when the pool key is
    /// unset, the stored pool key's `currency1` is not the Core's current `balanceToken()`, the pool sqrt price reads
    /// zero, or either `mulDiv` of the price exceeds 256 bits. native eth is `currency0`, so wei per token base unit is
    /// `(2^96 / sqrtPrice)^2`. `mulDiv` carries the sqrt price squared at full precision
    function _priceBaseUnits(uint256 baseUnits) private view returns (uint256 priceWei, bool priced) {
        if (!balancePoolKeySet) return (0, false);
        if (Currency.unwrap(balancePoolKey.currency1) != CORE.balanceToken()) return (0, false);
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(balancePoolKey.toId());
        if (sqrtPriceX96 == 0) return (0, false);
        uint256 q = FixedPoint96.Q96;
        uint256 p = sqrtPriceX96;
        bool fits;
        (fits, priceWei) = _mulDivFits(baseUnits, q, p);
        if (!fits) return (0, false);
        (fits, priceWei) = _mulDivFits(priceWei, q, p);
        if (!fits) return (0, false);
        priced = true;
    }

    /// `a * b / d` rounded down with `fits` false when the quotient exceeds 256 bits. `d` is nonzero
    function _mulDivFits(uint256 a, uint256 b, uint256 d) private pure returns (bool fits, uint256 r) {
        uint256 hi;
        unchecked {
            uint256 lo = a * b;
            uint256 mm;
            assembly ("memory-safe") {
                mm := mulmod(a, b, not(0))
            }
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
        if (hi >= d) return (false, 0);
        return (true, FullMath.mulDiv(a, b, d));
    }

    /// with `cost` at least `anchorMinCost`, a sale price in bps of the reference (rounded up) above the anchor sets the
    /// anchor by anchorMoveBps of their gap, at most `startCapBps`; zero leaves its clock unchanged. every other sale leaves the stored anchor and `anchorTime`
    /// unchanged. measuring in bps of the reference keeps a rating-rich statement sold at the normal markup from moving
    /// the anchor
    function _moveAnchor(uint256 sid, uint256 price, uint256 cost, uint256 ref) private {
        if (anchorMoveBps == 0 || cost < anchorMinCost) return;
        // a zero reference would divide by zero below
        if (ref == 0) return;
        uint256 saleBps = FullMath.mulDiv(price, BPS, ref);
        if (mulmod(price, BPS, ref) != 0) ++saleBps;
        uint256 current = anchorBps();
        if (saleBps <= current) return;
        uint256 next = current + FullMath.mulDiv(saleBps - current, anchorMoveBps, BPS);
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

    /// the asking price in wei after `age` seconds, a fraction of `ref` by the bps curve. the asking bps falls in a
    /// straight line from `startBps()` at `age` 0 to `floor` at `age` `decayHours`, and rests at `floor` after. a start
    /// at or below the floor is the floor from the first second. the bps is non-increasing in `age`
    function _ask(uint256 ref, uint256 age, uint256 floor) private view returns (uint256) {
        uint256 start = startBps();
        uint256 span = uint256(decayHours) * 1 hours;
        uint256 n;
        if (start <= floor || age >= span) {
            n = floor;
        } else {
            n = start - (start - floor) * age / span;
        }
        return ref * n / BPS;
    }

    // ------------------------------------------------------------------ credit picking

    /// ready when the pile holds a full page. the page is the 80 oldest credits. the returned format is 0 and the core
    /// does not use it. while the credit sale is on the page is ready only once the newest of its 80 credits is past
    /// its window; the pile is oldest first, so that credit is the last of the page
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
