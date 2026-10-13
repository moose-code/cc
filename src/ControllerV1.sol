// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {Sale, Credit, CreditSale, IController, ICoreViews, ICoreSale, ICreditScore, ICredits, IBalanceModule, Mainnet} from "./interfaces/Interfaces.sol";
import {CreditBounds} from "./lib/CreditBounds.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// first policy module. composes the oldest 80 pile credits with format 0.
/// it prices and sells statements and pile credits. `refScore` (an owner setting, in the per-credit score unit of one
/// ten-thousandth of a point) sets the point rate, `core.floorRate() / refScore`, and `valueOf(points)` is the larger of
/// `floorRate * points / refScore` and the balance token pool value of `points * unitPerPoint` base units, with
/// `unitPerPoint` read from the balance module at each call. the reference of a statement is the larger of its cost and
/// `valueOf(rating)`. the asking price is a fraction of the reference in bps that starts at
/// `start = min(anchorBps * markupBps / 10_000, startCapBps)` and falls at a fixed rate per second in two stages: at
/// `fastDecayBpsPerHour` from `start` to `kneeBps`, then at `slowDecayBpsPerHour` to the core setting `saleFloorBps`,
/// where it stays. a `start` at or below `kneeBps` falls at the slow rate from the first second. the price is computed
/// at every call from the age of the statement (time since its compose) and the current settings, so a setting change
/// applies to held statements at once. a `kneeBps` below `saleFloorBps` has no effect, because the price is the larger
/// of the curve and the floor.
/// `saleFloorBps` has two readings: the core takes no payment below `cost * saleFloorBps / 10_000`, and the curve here
/// floors at `reference * saleFloorBps / 10_000`. the reference is at least the cost, so the curve floor is at least the
/// core floor.
/// `anchorBps` (at least 10_000) is the running level of sale prices in bps of the reference. it moves up with sales and
/// down with time. a `buy` of a statement whose cost is at least `anchorMinCost` and whose sale price in bps of the
/// reference is above the anchor sets the anchor to the mean of the two. every other `buy` leaves the anchor unchanged.
/// the part of the anchor above 10_000 halves every `anchorHalfLife`, continuously. the controller stores the anchor at
/// its last change (`storedAnchorBps`, `anchorTime`) and evaluates the decay at the call. the price is computed from the
/// current anchor at every call, so held statements follow it.
/// `buy` sells a held statement at once at the asking price. `atFloor(sid)` is true once the statement's curve price has
/// reached the floor.
/// a pile credit sells at `max(cost, valueOf(score)) * creditFloorBps / 10_000` at the end of its window, from
/// `creditStartBps` of that at its acquisition.
/// every sale adds `royaltyBps` of the engine price on top. `buy`, `buyCredit` and `buyCredits` take the engine price
/// plus the royalty, forward the engine price to the core and add the royalty to `royaltyOwed`, which `claimRoyalty`
/// pays to `royaltyRecipient`. the controller holds `royaltyOwed` between calls and has no `receive`.
/// the owner of the core can pause sales (`core.setPaused`). while paused the core reverts `Paused` in `sellTo` and
/// `sellCreditTo`, so `buy` and `buyCredit` revert, and `priceOf` answers. the age of a statement is
/// `core.statementAge`, which excludes every paused second, so the age of a held statement stops advancing for the
/// length of a pause and continues from the same age at resume. the anchor decays with wall time in both states, so the
/// start of the curve, and with it the asking price, can still fall in a pause while the anchor is above 10_000.
/// its settings belong to the live owner of the core (`core.owner()`), there is no second owner.
/// once the owner sets the balance token pool (`setBalancePoolKey`), `valueOf` includes the pool term. with the pool key
/// unset, no balance module set, a failed, zero or above `uint128.max` unit read, or a zero pool read the pool term is 0
contract ControllerV1 is IController {
    using StateLibrary for IPoolManager;

    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;
    /// gas of the controller's read of the balance module's `unitPerPoint()`. the Core allows `atFloor` 400,000 gas in all
    uint256 private constant UNIT_GAS = 50_000;
    uint256 private constant MAX_ANCHOR_MIN_COST = 10 ether;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error ZeroAmount();
    error Reentrant();
    /// a credit sale door was called while the credit sale window is off
    error CreditSaleOff();

    event SaleSet(Sale sale);
    event CreditSaleSet(CreditSale credit);
    event AnchorBpsSet(uint32 anchorBps);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);
    event BalancePoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event RoyaltyClaimed(address indexed to, uint256 amount);

    ICoreViews public immutable CORE;

    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of the reference. the larger of `markupBps` and `kneeBps` to 200_000
    uint32 public startCapBps;
    /// fall of the asking price per hour above `kneeBps`, bps of the reference. 1 to 10_000
    uint16 public fastDecayBpsPerHour;
    /// fall of the asking price per hour at or below `kneeBps`, bps of the reference. 1 to 10_000
    uint16 public slowDecayBpsPerHour;
    /// the price where the fast fall ends and the slow fall starts, bps of the reference. 1_000 to `startCapBps`
    uint32 public kneeBps;
    /// the per-credit score that divides the floor rate into the point rate, in ten-thousandths of a point. a lower
    /// `refScore` lifts the rate term of `valueOf`. 1 to 8_000_000
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
    /// whether the balance token pool key is set. launch value false
    bool public balancePoolKeySet;
    /// the uniswap v4 pool of the balance token against native eth, used to price the redeemable value floor. native eth
    /// is `currency0` (the zero address) and the balance token is `currency1`, the only order a native eth pool sorts to.
    /// unset at launch
    PoolKey public balancePoolKey;

    /// whether pile credits are for sale from their acquisition time and compose waits for a credit's window to pass.
    /// launch value false
    bool public creditSaleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit must sit before compose
    /// may take it. 1 minute to 30 days
    uint32 public creditWindow;
    /// the credit sale floor over the larger of the credit's cost and `valueOf(score)`, bps. 10_000 to 40_000
    uint16 public creditFloorBps;
    /// the credit sale start price over the floor, bps. 10_000 to 200_000
    uint32 public creditStartBps;

    /// the share of every sale price added on top of it, bps. 0 to 1_000
    uint16 public royaltyBps;
    /// the address `claimRoyalty` pays. never zero
    address public royaltyRecipient;
    /// the royalty collected and not yet claimed, wei. the controller holds this much eth
    uint256 public royaltyOwed;

    constructor(address core, Sale memory sale, Credit memory credit) {
        CORE = ICoreViews(core);
        _setSale(sale);
        storedAnchorBps = uint32(BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
        _setCredit(
            CreditSale({
                saleOn: credit.saleOn,
                window: credit.window,
                floorBps: credit.floorBps,
                startBps: credit.startBps,
                refScore: credit.refScore,
                royaltyBps: credit.royaltyBps,
                royaltyRecipient: credit.royaltyRecipient
            })
        );
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ sale settings, owner, at once

    /// sets the seven sale settings at once. every field is checked against the bounds of the others in the call:
    /// `markupBps` 10_000 to 40_000 and at most `startCapBps`; `startCapBps` at least `markupBps` and `kneeBps`, at most
    /// 200_000; `kneeBps` 1_000 to `startCapBps`; each decay 1 to 10_000; `anchorHalfLife` 1 day to 90 days;
    /// `anchorMinCost` 0 to 10 ether. an `anchorBps()` above the new `startCapBps` is lowered to it. a change of
    /// `anchorHalfLife` stores the anchor at the call first, so the new half life applies from now on
    function setSale(Sale calldata v) external onlyOwner {
        if (v.anchorHalfLife != anchorHalfLife) _setAnchorStored(anchorBps());
        _setSale(v);
        emit SaleSet(v);
        if (anchorBps() > v.startCapBps) _setAnchor(v.startCapBps);
    }

    function _setSale(Sale memory v) private {
        if (v.markupBps < BPS || v.markupBps > 40_000) revert BadSetting("markupBps");
        if (v.startCapBps < v.markupBps || v.startCapBps > 200_000) revert BadSetting("startCapBps");
        if (v.kneeBps < 1_000 || v.kneeBps > v.startCapBps) revert BadSetting("kneeBps");
        if (v.fastDecayBpsPerHour < 1 || v.fastDecayBpsPerHour > BPS) revert BadSetting("fastDecayBpsPerHour");
        if (v.slowDecayBpsPerHour < 1 || v.slowDecayBpsPerHour > BPS) revert BadSetting("slowDecayBpsPerHour");
        if (v.anchorHalfLife < 1 days || v.anchorHalfLife > 90 days) revert BadSetting("anchorHalfLife");
        if (v.anchorMinCost > MAX_ANCHOR_MIN_COST) revert BadSetting("anchorMinCost");
        markupBps = v.markupBps;
        startCapBps = v.startCapBps;
        kneeBps = v.kneeBps;
        fastDecayBpsPerHour = v.fastDecayBpsPerHour;
        slowDecayBpsPerHour = v.slowDecayBpsPerHour;
        anchorHalfLife = v.anchorHalfLife;
        anchorMinCost = v.anchorMinCost;
    }

    /// 10_000 to `startCapBps`. replaces the running level of sale prices and restarts its decay
    function setAnchorBps(uint32 v) external onlyOwner {
        if (v < BPS || v > startCapBps) revert BadSetting("anchorBps");
        _setAnchor(v);
    }

    /// sets the native eth / balance token pool whose sqrt price prices the pool term of `valueOf`.
    /// `currency0` must be native eth (the zero address) and `currency1` the core's current balance token, the order a
    /// native eth pool sorts to. the pool must be initialized, so `valueOf` reads a live price at once. effective at once
    function setBalancePoolKey(PoolKey calldata key) external onlyOwner {
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
    }

    // ------------------------------------------------------------------ credit sale settings, owner, at once

    /// sets the credit sale, the rating reference and the royalty at once. `saleOn` turns the credit sale window on or
    /// off: while on, pile credits are for sale through `buyCredit` and compose takes only credits past their window.
    /// `window` 1 minute to 30 days, `floorBps` 10_000 to 40_000, `startBps` 10_000 to 200_000, `refScore` 1 to
    /// 8_000_000 (applies to `valueOf` at the next call), `royaltyBps` 0 to 1_000 (applies to the next sale),
    /// `royaltyRecipient` never zero (it is paid the royalty already owed)
    function setCredit(CreditSale calldata v) external onlyOwner {
        _setCredit(v);
        emit CreditSaleSet(v);
    }

    function _setCredit(CreditSale memory v) private {
        if (!CreditBounds.windowOk(v.window)) revert BadSetting("creditWindow");
        if (!CreditBounds.floorBpsOk(v.floorBps)) revert BadSetting("creditFloorBps");
        if (!CreditBounds.startBpsOk(v.startBps)) revert BadSetting("creditStartBps");
        if (!CreditBounds.refScoreOk(v.refScore)) revert BadSetting("refScore");
        if (!CreditBounds.royaltyBpsOk(v.royaltyBps)) revert BadSetting("royaltyBps");
        if (!CreditBounds.royaltyRecipientOk(v.royaltyRecipient)) revert BadSetting("royaltyRecipient");
        creditSaleOn = v.saleOn;
        creditWindow = v.window;
        creditFloorBps = v.floorBps;
        creditStartBps = v.startBps;
        refScore = v.refScore;
        royaltyBps = v.royaltyBps;
        royaltyRecipient = v.royaltyRecipient;
    }

    /// sends `royaltyOwed` to `royaltyRecipient`. anyone may call. reverts `ZeroAmount` when nothing is owed. a failed
    /// transfer reverts the call and leaves `royaltyOwed` unchanged
    function claimRoyalty() external {
        uint256 amount = royaltyOwed;
        if (amount == 0) revert ZeroAmount();
        royaltyOwed = 0;
        address to = royaltyRecipient;
        SafeTransferLib.safeTransferETH(to, amount);
        emit RoyaltyClaimed(to, amount);
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

    /// wei per score unit: `core.floorRate()` over `refScore`, rounded down. `valueOf` divides once on the product
    function pointRate() public view returns (uint256) {
        return CORE.floorRate() / refScore;
    }

    /// the value in wei of `points` score units: the larger of `floorRate * points / refScore` and the balance token pool
    /// value of `points * unitPerPoint` base units. `unitPerPoint` is read from the balance module in the call. the pool
    /// term is 0 when the pool key is unset, no balance module is set, the unit read fails, is zero or exceeds
    /// `uint128.max`, the pool reads zero, or the pool pricing exceeds 256 bits
    function valueOf(uint256 points) public view returns (uint256) {
        uint256 rate = FullMath.mulDiv(CORE.floorRate(), points, refScore);
        uint256 pool = _poolValue(points);
        return pool > rate ? pool : rate;
    }

    /// the price reference of statement `sid`, wei: the larger of its cost and `valueOf(rating)`. the curve prices in bps
    /// of this value. reverts `NotForSale` for a statement the core does not hold
    function referenceOf(uint256 sid) public view returns (uint256) {
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        return _reference(cost, CORE.ratingOf(sid));
    }

    function _reference(uint256 cost, uint256 rating) private view returns (uint256) {
        uint256 value = valueOf(rating);
        return value > cost ? value : cost;
    }

    /// the asking price of statement `sid` now, read from the core: the curve on the reference, at least
    /// `saleFloorBps` of the reference, so the quote is always a price `sellTo` takes. answers while paused
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,,) = _quote(sid);
    }

    /// `priceOf(sid)` plus the royalty, the amount `buy` takes
    function grossPriceOf(uint256 sid) external view returns (uint256) {
        return _gross(priceOf(sid));
    }

    /// true when the curve price of statement `sid` has reached the floor, `saleFloorBps` of the reference. the curve age
    /// excludes paused seconds, so eligibility holds its value while sales are paused. the core reads it to gate a
    /// balance side redemption
    function atFloor(uint256 sid) external view returns (bool) {
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        uint256 ref = _reference(cost, CORE.ratingOf(sid));
        uint256 floor = _saleFloorBps();
        return _ask(ref, CORE.statementAge(sid), floor) <= ref * floor / BPS;
    }

    /// pays the asking price plus the royalty, gets the statement at once, and moves the anchor halfway to the sale price
    /// in bps of the reference when the cost is at least `anchorMinCost`. the excess of `msg.value` is refunded to the
    /// caller last
    function buy(uint256 sid) external payable {
        if (_busy) revert Reentrant();
        _busy = true;
        (uint256 price, uint256 cost, uint256 ref) = _quote(sid);
        uint256 royalty = _royalty(price);
        uint256 gross = price + royalty;
        if (msg.value < gross) revert Underpaid();
        _moveAnchor(sid, price, cost, ref);
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        royaltyOwed += royalty;
        emit Bought(sid, msg.sender, price);
        if (msg.value > gross) SafeTransferLib.safeTransferETH(msg.sender, msg.value - gross);
        _busy = false;
    }

    function _royalty(uint256 price) private view returns (uint256) {
        return price * royaltyBps / BPS;
    }

    function _gross(uint256 price) private view returns (uint256) {
        return price + _royalty(price);
    }

    // ------------------------------------------------------------------ credit sale window

    /// the sale price of pile credit `id` now, wei. the floor is the larger of the credit's cost and `valueOf` of its
    /// score, times `creditFloorBps`. the start is the floor times `creditStartBps`. the price falls in a straight line
    /// from the start at the acquisition time to the floor at the acquisition time plus `creditWindow`, and rests at the
    /// floor after. reverts `NotForSale` for a credit not in the pile. answers whether or not the sale is on
    function creditPrice(uint256 id) public view returns (uint256 price) {
        (bool inPile, uint256 cost, uint64 acquiredAt) = CORE.creditInfo(id);
        if (!inPile) revert NotForSale();
        uint256 hi = valueOf(_scoreOf(id));
        if (cost > hi) hi = cost;
        uint256 floor = hi * creditFloorBps / BPS;
        uint256 start = floor * creditStartBps / BPS;
        uint256 age = block.timestamp - acquiredAt;
        if (age >= creditWindow) return floor;
        price = start - (start - floor) * age / creditWindow;
    }

    /// `creditPrice(id)` plus the royalty, the amount `buyCredit` takes
    function grossCreditPrice(uint256 id) external view returns (uint256) {
        return _gross(creditPrice(id));
    }

    /// the credit score of `id` from the credit score contract, the same `scoreOf(seed, paidAt)` source the balance token
    /// bid reads in `sellForBalance`. `scoreOf` is pure on a fixed verified contract, so the call is direct.
    /// `creditPrice` calls this only for a credit the core holds in the pile, so the reads cannot revert
    function _scoreOf(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(
            ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id)
        );
    }

    /// true when credit acquired at `acquiredAt` may be composed: always while the sale is off, otherwise once
    /// `creditWindow` has passed since its acquisition. the core and chosen composition test one credit with it
    function pastWindow(uint64 acquiredAt) public view returns (bool) {
        if (!creditSaleOn) return true;
        return uint256(acquiredAt) + creditWindow <= block.timestamp;
    }

    /// pays the sale price of credit `id` plus the royalty, gets the credit at once, and refunds the excess of
    /// `msg.value` last. reverts `CreditSaleOff` while the sale is off and, through the core, `Paused` while sales are paused
    function buyCredit(uint256 id) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        uint256 price = creditPrice(id);
        uint256 royalty = _royalty(price);
        uint256 gross = price + royalty;
        if (msg.value < gross) revert Underpaid();
        ICoreSale(address(CORE)).sellCreditTo{value: price}(id, msg.sender);
        royaltyOwed += royalty;
        if (msg.value > gross) SafeTransferLib.safeTransferETH(msg.sender, msg.value - gross);
        _busy = false;
    }

    /// pays the sale prices of `ids` in order plus the royalty of each, gets the credits, and refunds the excess last.
    /// each credit is priced at the state left by the previous sale. the floor rate is unchanged by a credit sale for the
    /// rest of the block, so within one batch a credit's price moves only through its own cost, score and age. reverts
    /// `CreditSaleOff` while the sale is off and, through the core, `Paused` while sales are paused
    function buyCredits(uint256[] calldata ids) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        uint256 n = ids.length;
        uint256 spent;
        uint256 royalty;
        for (uint256 i; i < n; ++i) {
            uint256 price = creditPrice(ids[i]);
            uint256 r = _royalty(price);
            spent += price + r;
            royalty += r;
            if (msg.value < spent) revert Underpaid();
            ICoreSale(address(CORE)).sellCreditTo{value: price}(ids[i], msg.sender);
        }
        royaltyOwed += royalty;
        if (msg.value > spent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - spent);
        _busy = false;
    }

    /// the curve price of statement `sid` in wei with its cost basis and its reference. the price is the age curve on the
    /// reference, at least `saleFloorBps` of the reference
    function _quote(uint256 sid) private view returns (uint256 price, uint256 cost, uint256 ref) {
        bool held;
        (held, cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        ref = _reference(cost, CORE.ratingOf(sid));
        price = _ask(ref, CORE.statementAge(sid), _saleFloorBps());
    }

    /// the core's `saleFloorBps`
    function _saleFloorBps() private view returns (uint256) {
        return ICoreSale(address(CORE)).settings().saleFloorBps;
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
    /// unset, no balance module is set, the unit read fails (see `_liveUnit`), the owed amount is zero, the pool sqrt
    /// price reads zero, or a product of the pricing exceeds 256 bits
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
    /// unset, the pool sqrt price reads zero, or either `mulDiv` of the price exceeds 256 bits. native eth is `currency0`,
    /// so wei per token base unit is `(2^96 / sqrtPrice)^2`. `mulDiv` carries the sqrt price squared at full precision
    function _priceBaseUnits(uint256 baseUnits) private view returns (uint256 priceWei, bool priced) {
        if (!balancePoolKeySet) return (0, false);
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
    /// start to the knee and by `slowDecayBpsPerHour` units a second after, never below `floor`. the slow stage
    /// starts at the second the fast stage reaches the knee, which is `(start - knee) / fastDecayBpsPerHour` hours and
    /// need not be a whole second, so its fall is rounded up. the rounding keeps the price non-increasing in `age`
    function _ask(uint256 ref, uint256 age, uint256 floor) private view returns (uint256) {
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
        uint256 low = floor * 1 hours;
        if (n < low) n = low;
        return ref * n / (1 hours * BPS);
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
