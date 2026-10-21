// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ValueBase} from "./ValueMode.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IStandingBidPolicy} from "../src/interfaces/IStandingBidPolicy.sol";
import {CreditSale, Quote, POINT_UNIT} from "../src/interfaces/Interfaces.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// the standing bid policy on the real pools of the pinned fork: the Core's coin pool for the CC leg and a value mode
/// pool of the phase 2 standin token for the balance leg, behind a selected phase 2 treasury and ControllerV2
contract StandingBidPolicyTest is ValueBase {
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    Phase2BalanceTokenStandin internal tok;
    PoolKey internal tokKey;
    IPhase2BalanceTreasury internal t;
    IControllerV2 internal c2;
    IStandingBidPolicy internal p;
    address internal proRata;
    address internal holder;

    function setUp() public override {
        super.setUp();
        // the phase 2 token and its own eth pool at the fixture's sqrt price, full range
        tok = new Phase2BalanceTokenStandin();
        tok.open();
        tokKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tok)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(tokKey, SP);
        tok.mint(address(this), 1e24);
        tok.approve(address(lp), type(uint256).max);
        tok.approve(address(router), type(uint256).max);
        vm.deal(address(this), address(this).balance + 2_000 ether);
        lp.modify{value: 2_000 ether}(tokKey, -TICK_FULL, TICK_FULL, int256(uint256(POOL_LIQ)));
        // the treasury on the standin, selected, every switch on, 1 token of claims
        proRata = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = IPhase2BalanceTreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), address(tok), proRata, address(0))
            )
        );
        _setBalanceModule(address(t));
        tok.mint(address(t), 300 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, true);
        // a small pot, so the share per CC sits under the pool price and the bid applies, as it would on the live pot
        t.allocateToClaims(1 ether);
        vm.stopPrank();
        // ControllerV2 priced on the standin pool
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: ctl.creditSpreadBps(),
            startBps: ctl.creditStartBps()
        });
        Quote memory none;
        c2 = IControllerV2(
            vm.deployCode(
                "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(15_000), uint32(3_600))
            )
        );
        _setController(address(c2));
        (uint160 sp,,,) = PM.getSlot0(tokKey.toId());
        vm.startPrank(owner);
        c2.setBalancePoolKey(
            IControllerV2.PoolKey({
                currency0: IControllerV2.Currency.wrap(address(0)),
                currency1: IControllerV2.Currency.wrap(address(tok)),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            _spotOf(sp)
        );
        c2.setQuote(_quote());
        vm.stopPrank();
        // the policy, seeded on the live coin pool and set like the controller
        p = IStandingBidPolicy(vm.deployCode("StandingBidPolicy.sol:StandingBidPolicy", abi.encode(address(t))));
        // the fixture's coin pool has no active liquidity before its first swap: the holder's buy moves the tick
        // into the launch range, as the live pool's trades have
        holder = _user("holder");
        _buyCoin(holder, 1 ether);
        (uint256 ccSpot, bool ok) = p.ccSpot();
        assertTrue(ok && ccSpot != 0, "the fixture coin pool prices");
        vm.startPrank(owner);
        p.seedReference(ccSpot);
        p.setQuote(_quote());
        t.setRedemptionPolicy(address(p));
        t.setSwitches(true, true, true);
        vm.stopPrank();
    }

    function _quote() internal pure returns (Quote memory) {
        return Quote({
            referenceRateBpsPerHour: 1_000,
            referenceStepBps: 500,
            tolBps: 450,
            referenceMaxStale: 1 days,
            referenceMinSeconds: 0,
            minLiquidity: 1
        });
    }

    /// the bid per 1e18 CC the two live legs imply
    function _expectedPerCC() internal view returns (uint256) {
        (uint256 cc,) = p.ccSpot();
        (uint256 value, bool ok) = c2.valuePerPoint(true);
        assertTrue(ok, "balance leg usable");
        uint256 bal = FullMath.mulDiv(value, 1e18, POINT_UNIT * t.unitPerPoint());
        return FullMath.mulDiv(cc * (BPS + p.premiumBps()), 1e18, bal * BPS);
    }

    function _burn(uint256 x, uint256 minOut) internal returns (uint256 out) {
        uint64 epoch = t.configEpoch();
        vm.startPrank(holder);
        coin.approve(address(t), x);
        out = t.redeemCC(x, holder, minOut, block.timestamp, epoch);
        vm.stopPrank();
    }

    // promise: decision 258 the bid per CC is the protected coin pool price in wei over the protected balance price in wei plus the premium, read from the two live pools, and a burn under the budget pays exactly it
    function test_bidIsTheTwoLegsPlusThePremiumAndABurnPaysIt() public {
        (uint256 perCC, bool ok) = p.bidPerCC();
        assertTrue(ok);
        assertEq(perCC, _expectedPerCC());
        uint256 x = coin.balanceOf(holder) / 4;
        uint256 bid = FullMath.mulDiv(x, perCC, 1e18);
        (uint256 share,, uint256 cap) = t.redemptionTerms(x);
        assertGt(bid, share, "the bid is above the share at this pot");
        // no budget: the quote is the floor and executes at it
        (uint256 q,,,, bool exec) = t.quoteRedemption(x);
        assertEq(q, share);
        assertTrue(exec);
        assertEq(cap, share);
        // a budget: the quote is the bid
        vm.prank(owner);
        t.setBidBudget(uint128(bid * 4), uint128(bid * 4));
        vm.warp(block.timestamp + 1 days);
        assertEq(t.bidBudgetAvailable(), bid * 4);
        (q,,,, exec) = t.quoteRedemption(x);
        assertEq(q, bid);
        assertTrue(exec);
        uint256 reserve = t.claimReserve();
        uint256 out = _burn(x, bid);
        assertEq(out, bid);
        assertEq(tok.balanceOf(holder), bid);
        assertEq(t.claimReserve(), reserve - bid);
        assertEq(t.bidBudgetAvailable(), bid * 3, "the payment above the share came out of the budget");
    }

    // promise: decision 258 a burn the budget does not cover pays the floor, a burn at the floor leaves the budget alone, and the budget accrues per day up to its maximum
    function test_budgetBoundsTheBidAndTheFloorStaysOpen() public {
        uint256 x = coin.balanceOf(holder) / 4;
        (uint256 perCC,) = p.bidPerCC();
        uint256 bid = FullMath.mulDiv(x, perCC, 1e18);
        (uint256 share,,) = t.redemptionTerms(x);
        vm.prank(owner);
        t.setBidBudget(uint128(bid / 2), uint128(bid));
        vm.warp(block.timestamp + 12 hours);
        assertEq(t.bidBudgetAvailable(), bid / 4);
        (uint256 q,,,,) = t.quoteRedemption(x);
        assertEq(q, share, "the budget does not cover the bid, so the floor");
        uint256 budgetBefore = t.bidBudgetAvailable();
        assertEq(_burn(x, share), share);
        assertEq(t.bidBudgetAvailable(), budgetBefore, "a floor payment leaves the budget alone");
        vm.warp(block.timestamp + 10 days);
        assertEq(t.bidBudgetAvailable(), bid, "accrual stops at the maximum");
        _unstale();
        uint256 y = coin.balanceOf(holder) / 4;
        (q,,,,) = t.quoteRedemption(y);
        uint256 bidY = FullMath.mulDiv(y, perCC, 1e18);
        assertEq(q, bidY);
        assertEq(_burn(y, bidY), bidY);
        assertEq(p.bidCapacity(), FullMath.mulDiv(t.bidBudgetAvailable(), 1e18, perCC));
    }

    // promise: issue 113 on the CC leg: a same block pump of the coin pool does not raise the bid, because the prior block sample is the lower spot, and a persistent move is bounded by the reference plus the tolerance
    function test_sameBlockPumpDoesNotRaiseTheBidAndAMoveIsBanded() public {
        (uint256 before,) = p.bidPerCC();
        (uint256 spotBefore,) = p.ccSpot();
        address whale = _user("whale");
        _buyCoin(whale, 20 ether);
        (uint256 spotAfter,) = p.ccSpot();
        assertGt(spotAfter, spotBefore * 11 / 10, "the pump moved the live spot by over 10 percent");
        (uint256 pumped,) = p.bidPerCC();
        assertEq(pumped, before, "the bid holds the sampled spot");
        // a refresh in a later block moves the reference by at most the step and the bid by at most the tolerance band
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(p.refreshDue());
        assertTrue(p.refreshReference());
        uint256 ref = p.referencePrice();
        assertLe(ref, spotBefore * (BPS + 500) / BPS, "the reference moved by the step at most");
        (uint256 banded, bool ok) = p.bidPerCC();
        assertTrue(ok);
        (uint256 value,) = c2.valuePerPoint(true);
        uint256 bal = FullMath.mulDiv(value, 1e18, POINT_UNIT * t.unitPerPoint());
        uint256 ceiling = FullMath.mulDiv(ref * (BPS + 450) / BPS * (BPS + p.premiumBps()), 1e18, bal * BPS);
        assertLe(banded, ceiling);
        assertLt(banded, FullMath.mulDiv(spotAfter * (BPS + p.premiumBps()), 1e18, bal * BPS), "under the live spot");
    }

    // promise: the bid is unusable, and every quote the floor, with a stale reference, with liquidity under the threshold or while the Core's controller does not price the balance token
    function test_unusableLegsFallToTheFloor() public {
        uint256 x = coin.balanceOf(holder) / 4;
        (uint256 share,,) = t.redemptionTerms(x);
        vm.prank(owner);
        t.setBidBudget(type(uint128).max / 2, type(uint128).max / 2);
        vm.warp(block.timestamp + 1 days);
        (uint256 q,,,,) = t.quoteRedemption(x);
        assertGt(q, share, "the bid applies with the budget");
        vm.warp(block.timestamp + 2 days);
        (, bool ok) = p.bidPerCC();
        assertFalse(ok, "stale");
        (q,,,,) = t.quoteRedemption(x);
        assertEq(q, share);
        _unstale();
        (, ok) = p.bidPerCC();
        assertTrue(ok);
        Quote memory thin = _quote();
        thin.minLiquidity = type(uint128).max;
        vm.prank(owner);
        p.setQuote(thin);
        (, ok) = p.bidPerCC();
        assertFalse(ok, "liquidity under the threshold");
        vm.prank(owner);
        p.setQuote(_quote());
        _setController(address(ctl));
        (, ok) = p.bidPerCC();
        assertFalse(ok, "a controller without a usable balance price");
        (q,,,,) = t.quoteRedemption(x);
        assertEq(q, share);
    }

    // promise: the owner bounds: the premium at most 500 bps, the reference triple all or none with a liquidity threshold, the seed within 4.5 percent of the live spot, and only the Core owner
    function test_ownerBounds() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandingBidPolicy.BadSetting.selector, bytes32("premiumBps")));
        p.setPremiumBps(501);
        vm.prank(owner);
        p.setPremiumBps(500);
        assertEq(p.premiumBps(), 500);
        Quote memory q = _quote();
        q.referenceMaxStale = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandingBidPolicy.BadSetting.selector, bytes32("referenceTriple")));
        p.setQuote(q);
        q = _quote();
        q.minLiquidity = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandingBidPolicy.BadSetting.selector, bytes32("minLiquidity")));
        p.setQuote(q);
        uint256 live = _liveCC();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandingBidPolicy.BadSetting.selector, bytes32("spot")));
        p.seedReference(live * 2);
        vm.expectRevert(IStandingBidPolicy.OnlyOwner.selector);
        p.setPremiumBps(100);
        vm.expectRevert(IStandingBidPolicy.OnlyOwner.selector);
        p.seedReference(live);
        assertEq(p.owner(), owner);
    }

    // promise: the treasury's bounded static read holds the policy's two pool legs, the controller call and the budget read under its gas bound
    function test_quoteFitsTheTreasuryGasBound() public {
        uint256 x = coin.balanceOf(holder) / 4;
        vm.prank(owner);
        t.setBidBudget(type(uint128).max / 2, type(uint128).max / 2);
        vm.warp(block.timestamp + 1 days);
        uint256 g = gasleft();
        p.quote(x, t.claimReserve(), coin.totalSupply(), 0);
        uint256 used = g - gasleft();
        assertLt(used, 250_000, "under the treasury's 300,000 bound with margin");
        (uint256 q,,,, bool exec) = t.quoteRedemption(x);
        assertGt(q, 0);
        assertTrue(exec);
    }

    /// both references went stale over a warp: a new block, the controller's permissionless refresh and the owner's
    /// seed of the policy (a keeper refresh does the same)
    function _unstale() internal {
        vm.roll(block.number + 1);
        assertTrue(c2.refreshReference(), "the controller reference refreshed");
        uint256 live = _liveCC();
        vm.prank(owner);
        p.seedReference(live);
    }

    function _liveCC() internal view returns (uint256 s) {
        (s,) = p.ccSpot();
    }
}
