// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {IRedemptionPolicy, Quote, POINT_UNIT} from "../interfaces/Interfaces.sol";

interface IBidCore {
    function owner() external view returns (address);
    function controller() external view returns (address);
    function MANAGER() external view returns (address);
    function COIN() external view returns (address);
    function HOOK() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
}

interface IBidTreasury {
    function core() external view returns (address);
    function bidBudgetAvailable() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint16);
    function unitPerPoint() external view returns (uint256);
}

interface IBidController {
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
}

/// the standing bid redemption policy of the phase 2 treasury (decision 258): a burn of `ccIn` is paid the CC pool's
/// protected price in balance tokens plus `premiumBps`, while the treasury's bid budget covers it; otherwise the
/// proportional share of the claim reserve, the floor the first policy pays. the CC leg is the Core's coin pool read
/// under the issue 113 rule of ControllerV2: the lower of a prior block sample and the live spot, never above the
/// reference plus `tolBps`, unusable when the reference is stale or the liquidity is under `minLiquidity`. the balance
/// leg is ControllerV2's protected sale price per point, the higher side, so a manipulated pool can only lower the
/// bid. holds no token, has no allowance; the owner is the Core's owner. the treasury caps every answer at the larger
/// of the share and its budget, whatever this contract says
contract StandingBidPolicy is IRedemptionPolicy {
    using StateLibrary for IPoolManager;

    string public constant VERSION = "standing-bid-v1";
    uint256 private constant BPS = 10_000;
    /// the most the premium may be set to, well under the coin pool's fee so a pool round trip cannot farm it
    uint16 public constant MAX_PREMIUM_BPS = 500;
    uint256 private constant POOL_SEED_MAX_DEVIATION_BPS = 450;
    uint256 private constant CONTROLLER_GAS = 150_000;
    uint256 private constant BUDGET_GAS = 50_000;

    error OnlyOwner();
    error InvalidConfiguration();
    error BadSetting(bytes32 field);
    error ZeroInput();
    error InputAboveSupply();
    error BadFee();

    event PremiumSet(uint16 premiumBps);
    event QuoteSet(Quote quote);
    event ReferenceSeeded(uint256 referencePrice, uint256 spot);
    event ReferenceRefreshed(uint256 referencePrice, uint256 spot);

    IBidCore public immutable CORE;
    IBidTreasury public immutable TREASURY;
    IPoolManager public immutable MANAGER;
    address public immutable COIN;
    address public immutable HOOK;
    uint24 public immutable POOL_FEE;
    int24 public immutable TICK_SPACING;

    /// bps over the protected CC price the bid pays, at most `MAX_PREMIUM_BPS`. 100 at deployment
    uint16 public premiumBps;
    /// the CC pool reference settings, the shape of ControllerV2's. all zero at deployment: the bid is unusable and
    /// every quote is the floor until the owner seeds the reference and sets the quote
    Quote public bidQuote;
    /// the CC reference, wei per 1e18 CC, and when it was last sampled
    uint256 public referencePrice;
    uint40 public referenceTime;
    uint256 private spotSampleA;
    uint256 private spotSampleB;
    uint128 private liqSampleA;
    uint128 private liqSampleB;
    uint48 private lastRefreshBlock;

    constructor(address treasury_) {
        if (treasury_.code.length == 0) revert InvalidConfiguration();
        address core_ = IBidTreasury(treasury_).core();
        if (core_.code.length == 0) revert InvalidConfiguration();
        IBidCore c = IBidCore(core_);
        address manager = c.MANAGER();
        address coin = c.COIN();
        if (manager.code.length == 0 || coin.code.length == 0) revert InvalidConfiguration();
        CORE = c;
        TREASURY = IBidTreasury(treasury_);
        MANAGER = IPoolManager(manager);
        COIN = coin;
        HOOK = c.HOOK();
        POOL_FEE = c.POOL_FEE();
        TICK_SPACING = c.TICK_SPACING();
        premiumBps = 100;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OnlyOwner();
        _;
    }

    /// the Core's current owner, read at each use
    function owner() public view returns (address) {
        return CORE.owner();
    }

    // ------------------------------------------------------------------ the policy

    /// the bid while usable and within the budget, else the floor. both less `feeBps`. reverts on a zero input or
    /// supply, an input above the supply and a fee above 10,000, as the first policy does
    function quote(uint256 ccIn, uint256 claimReserve, uint256 ccSupply, uint256 feeBps)
        external
        view
        override
        returns (uint256 out)
    {
        if (ccIn == 0 || ccSupply == 0) revert ZeroInput();
        if (ccIn > ccSupply) revert InputAboveSupply();
        if (feeBps > BPS) revert BadFee();
        uint256 floor =
            FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(ccIn, claimReserve, ccSupply), BPS - feeBps, BPS);
        (uint256 bid, bool ok) = bidFor(ccIn);
        if (!ok) return floor;
        bid = FixedPointMathLib.fullMulDiv(bid, BPS - feeBps, BPS);
        if (bid <= floor) return floor;
        (uint256 budget, bool read) = _budget();
        if (!read || bid > budget) return floor;
        return bid;
    }

    function isRedemptionPolicy() external pure override returns (bool) {
        return true;
    }

    /// the bid for `ccIn` before the fee, balance base units, and whether the bid is usable now
    function bidFor(uint256 ccIn) public view returns (uint256 out, bool ok) {
        (uint256 perCC, bool usable) = bidPerCC();
        if (!usable) return (0, false);
        return (FixedPointMathLib.fullMulDiv(ccIn, perCC, 1e18), true);
    }

    /// the bid per 1e18 CC before the fee, balance base units: the protected CC price in wei over the protected
    /// balance price in wei, plus the premium. unusable while either leg is
    function bidPerCC() public view returns (uint256 perCC, bool ok) {
        (uint256 cc, bool ccOk) = protectedCCPrice();
        if (!ccOk) return (0, false);
        (uint256 bal, bool balOk) = protectedBalancePrice();
        if (!balOk || bal == 0) return (0, false);
        perCC = FixedPointMathLib.fullMulDiv(cc * (BPS + premiumBps), 1e18, bal * BPS);
        ok = perCC != 0;
    }

    /// the most CC the bid covers now at the current budget, after the treasury's fee as `quote` applies it. zero
    /// while the bid is unusable or the fee takes everything
    function bidCapacity() external view returns (uint256 cc) {
        (uint256 perCC, bool ok) = bidPerCC();
        if (!ok) return 0;
        (uint256 budget, bool read) = _budget();
        if (!read) return 0;
        uint256 fee = TREASURY.redemptionFeeBps();
        if (fee >= BPS) return 0;
        return FixedPointMathLib.fullMulDiv(budget * BPS, 1e18, perCC * (BPS - fee));
    }

    /// the terms of a burn of `ccIn` now, for a panel, after the treasury's fee as `quote` applies it: the floor, the
    /// bid, the budget and whether `quote` returns the bid
    function terms(uint256 ccIn, uint256 claimReserve, uint256 ccSupply)
        external
        view
        returns (uint256 floor, uint256 bid, uint256 budget, bool bidUsable, bool atBid)
    {
        if (ccIn == 0 || ccSupply == 0 || ccIn > ccSupply) return (0, 0, 0, false, false);
        uint256 fee = TREASURY.redemptionFeeBps();
        if (fee > BPS) fee = BPS;
        floor = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(ccIn, claimReserve, ccSupply), BPS - fee, BPS);
        (bid, bidUsable) = bidFor(ccIn);
        bid = FixedPointMathLib.fullMulDiv(bid, BPS - fee, BPS);
        (budget,) = _budget();
        atBid = bidUsable && bid > floor && bid <= budget;
    }

    // ------------------------------------------------------------------ the two legs

    /// the CC pool's protected price, wei per 1e18 CC: the lower of the prior block sample and the live spot, never
    /// above the reference plus `tolBps`. unusable with no reference, a stale reference, a zero live price or
    /// liquidity under `minLiquidity` live or in either sample
    function protectedCCPrice() public view returns (uint256 price, bool ok) {
        Quote memory q = bidQuote;
        uint256 ref = referencePrice;
        if (ref == 0 || q.referenceMaxStale == 0) return (0, false);
        (uint256 live, bool priced) = ccSpot();
        if (!priced || live == 0) return (0, false);
        if (block.timestamp - referenceTime > q.referenceMaxStale) return (0, false);
        uint128 liveLiq = MANAGER.getLiquidity(ccPoolKey().toId());
        if (liveLiq == 0 || liveLiq < q.minLiquidity || liqSampleA < q.minLiquidity || liqSampleB < q.minLiquidity) {
            return (0, false);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 sampled = uint48(block.number) == lastRefreshBlock ? spotSampleB : spotSampleA;
        uint256 up = ref * (BPS + q.tolBps) / BPS;
        uint256 low = sampled < live ? sampled : live;
        price = low < up ? low : up;
        ok = price != 0;
    }

    /// ControllerV2's protected sale price of the balance token, wei per 1e18 base units, through its value per point.
    /// unusable while the Core's controller does not answer or its reference is unusable
    function protectedBalancePrice() public view returns (uint256 price, bool ok) {
        address controller = CORE.controller();
        if (controller.code.length == 0) return (0, false);
        (bool called, bytes memory ret) =
            controller.staticcall{gas: CONTROLLER_GAS}(abi.encodeCall(IBidController.valuePerPoint, (true)));
        if (!called || ret.length < 64) return (0, false);
        (uint256 value, bool usable) = abi.decode(ret, (uint256, bool));
        if (!usable || value == 0) return (0, false);
        uint256 unit = TREASURY.unitPerPoint();
        if (unit == 0) return (0, false);
        // value is wei per point and a point is POINT_UNIT * unit base units
        price = FixedPointMathLib.fullMulDiv(value, 1e18, POINT_UNIT * unit);
        ok = price != 0;
    }

    /// the live coin pool spot, wei per 1e18 CC. unusable without an initialized pool
    function ccSpot() public view returns (uint256 spot, bool ok) {
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(ccPoolKey().toId());
        if (sqrtPriceX96 == 0) return (0, false);
        uint256 q = FixedPoint96.Q96;
        uint256 p = sqrtPriceX96;
        return ((1e18 * q / p) * q / p, true);
    }

    /// the Core's coin pool: native eth against the coin at the Core's fee, spacing and hook
    function ccPoolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(COIN),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _budget() private view returns (uint256 budget, bool ok) {
        (bool called, bytes memory ret) =
            address(TREASURY).staticcall{gas: BUDGET_GAS}(abi.encodeCall(IBidTreasury.bidBudgetAvailable, ()));
        if (!called || ret.length < 32) return (0, false);
        return (abi.decode(ret, (uint256)), true);
    }

    // ------------------------------------------------------------------ the reference

    /// seeds the CC reference from the live spot. `expectedSpot` (wei per 1e18 CC) is the owner's read: a live spot
    /// more than 4.5 percent from it reverts, as does a pool with no active liquidity. both samples and their
    /// liquidity are taken now
    function seedReference(uint256 expectedSpot) external onlyOwner {
        (uint256 spot, bool ok) = ccSpot();
        if (!ok || spot == 0) revert BadSetting("spot");
        uint256 band = expectedSpot * POOL_SEED_MAX_DEVIATION_BPS / BPS;
        if (spot < expectedSpot - band || spot > expectedSpot + band) revert BadSetting("spot");
        uint128 liq = MANAGER.getLiquidity(ccPoolKey().toId());
        if (liq == 0) revert BadSetting("liquidity");
        spotSampleA = spot;
        spotSampleB = spot;
        liqSampleA = liq;
        liqSampleB = liq;
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        referencePrice = spot;
        // forge-lint: disable-next-line(unsafe-typecast)
        referenceTime = uint40(block.timestamp);
        emit ReferenceSeeded(spot, spot);
    }

    /// the reference settings, ControllerV2's rules: the rate, the step and the staleness all set or all zero, a
    /// positive liquidity threshold with them, `referenceStepBps` 0 to 10,000, `tolBps` 0 to 9,999
    function setQuote(Quote calldata v) external onlyOwner {
        if (v.referenceStepBps > BPS) revert BadSetting("referenceStepBps");
        if (v.tolBps >= BPS) revert BadSetting("tolBps");
        bool anyRef = v.referenceRateBpsPerHour != 0 || v.referenceStepBps != 0 || v.referenceMaxStale != 0;
        bool allRef = v.referenceRateBpsPerHour != 0 && v.referenceStepBps != 0 && v.referenceMaxStale != 0;
        if (anyRef && !allRef) revert BadSetting("referenceTriple");
        if (allRef && v.minLiquidity == 0) revert BadSetting("minLiquidity");
        bidQuote = v;
        emit QuoteSet(v);
    }

    /// 0 to `MAX_PREMIUM_BPS`
    function setPremiumBps(uint16 v) external onlyOwner {
        if (v > MAX_PREMIUM_BPS) revert BadSetting("premiumBps");
        premiumBps = v;
        emit PremiumSet(v);
    }

    /// moves the CC reference toward the pool spot by at most `min(referenceRateBpsPerHour * elapsed / 3600,
    /// referenceStepBps)` bps of the reference, ControllerV2's rule. anyone may call. no move with no reference, with
    /// the mode off, before `referenceMinSeconds` since the last sample, twice in a block, or on a zero spot. returns
    /// true when it updated the reference
    function refreshReference() external returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint48(block.number) == lastRefreshBlock) return false;
        uint256 ref = referencePrice;
        if (ref == 0) return false;
        Quote memory q = bidQuote;
        if (q.referenceMaxStale == 0) return false;
        uint256 elapsed = block.timestamp - referenceTime;
        if (elapsed < q.referenceMinSeconds) return false;
        (uint256 spot, bool ok) = ccSpot();
        if (!ok || spot == 0) return false;
        uint256 move = uint256(q.referenceRateBpsPerHour) * elapsed / 1 hours;
        if (move > q.referenceStepBps) move = q.referenceStepBps;
        if (move == 0) return false;
        uint256 hi = ref * (BPS + move) / BPS;
        uint256 lo = ref * (BPS - move) / BPS;
        spotSampleB = spotSampleA;
        liqSampleB = liqSampleA;
        spotSampleA = spot;
        liqSampleA = MANAGER.getLiquidity(ccPoolKey().toId());
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        referencePrice = spot > hi ? hi : spot < lo ? lo : spot;
        // forge-lint: disable-next-line(unsafe-typecast)
        referenceTime = uint40(block.timestamp);
        emit ReferenceRefreshed(referencePrice, spot);
        return true;
    }

    /// whether `refreshReference` would move the reference now, for a keeper
    function refreshDue() external view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint48(block.number) == lastRefreshBlock) return false;
        if (referencePrice == 0) return false;
        Quote memory q = bidQuote;
        if (q.referenceMaxStale == 0) return false;
        uint256 elapsed = block.timestamp - referenceTime;
        if (elapsed < q.referenceMinSeconds) return false;
        (uint256 spot, bool ok) = ccSpot();
        if (!ok || spot == 0) return false;
        uint256 move = uint256(q.referenceRateBpsPerHour) * elapsed / 1 hours;
        if (move > q.referenceStepBps) move = q.referenceStepBps;
        return move != 0;
    }
}
