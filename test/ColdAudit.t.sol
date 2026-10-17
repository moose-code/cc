// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Quote, Mainnet} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";

contract RevertingAvailableModule {
    address public immutable balanceToken;

    constructor(address token) {
        balanceToken = token;
    }

    function unitPerPoint() external pure returns (uint256) {
        return 1e10;
    }

    function available() external pure returns (uint256) {
        revert();
    }
}

/// Audit probes use the test-rate fixture. The balance price pool below is a real v4 pool with minted
/// liquidity, and its spot moves only through swaps.
contract ColdAuditTest is Fixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    uint160 internal constant OPEN_SP = uint160(FixedPoint96.Q96 * 10 / 7);
    PoolKey internal balanceKey;

    struct ColdRead {
        uint256 rate;
        uint256 bid;
        uint256 scoreBid;
        uint256 floor;
        uint256 multiplier;
        uint256 value;
        uint256 balanceRate;
        uint256 balanceBid;
        uint64 bucket;
        uint128 budget;
        uint128 spent;
    }

    // promise: with no engine call after deploy, the cold view matrix at 0, 10 minutes, 2 hours and 24 hours
    // equals the same-block state after its first book of real unbooked hook income
    function test_coldViewMatrixFirstBook() public {
        autoBook = false;
        uint256 id = _credits(seller, 1)[0];
        _buyCoin(funder, 2 ether);
        assertEq(core.ethPot(), 0);
        uint256 start = block.timestamp;
        uint256[4] memory ages = [uint256(0), 10 minutes, 2 hours, 24 hours];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(start + ages[i]);
            uint256 snap = vm.snapshotState();
            ColdRead memory c;
            c.rate = core.ethRate();
            c.bid = core.bidOf(id);
            c.scoreBid = core.bidForScore(_scoreOf(id));
            c.floor = core.floorRate();
            c.multiplier = core.climbMultiplier();
            c.value = ctl.valueOf(1_000_000);
            c.balanceRate = core.balanceRate();
            c.balanceBid = core.balanceBidOf(id);
            (c.bucket, c.budget, c.spent) = core.spendState();
            (bool ready,,) = ctl.nextPage();
            assertFalse(ready, "a cold pile has no page");
            assertEq(c.balanceBid, 0, "no module means no balance payout");
            assertEq(ctl.referencePrice(), 0, "no balance pool key means no reference");
            assertEq(core.ethToBuyback(), 0, "no sale means no buyback pot");
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.creditPrice(id);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.priceOf(1);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.atFloor(1);
            core.book();
            assertEq(core.ethRate(), c.rate, "ethRate fixed point");
            assertEq(core.bidOf(id), c.bid, "bidOf fixed point");
            assertEq(core.bidForScore(_scoreOf(id)), c.scoreBid, "bidForScore fixed point");
            assertEq(core.floorRate(), c.floor, "floorRate fixed point");
            assertEq(core.climbMultiplier(), c.multiplier, "climbMultiplier fixed point");
            assertEq(ctl.valueOf(1_000_000), c.value, "valueOf fixed point");
            assertEq(core.balanceRate(), c.balanceRate, "balanceRate fixed point");
            (uint64 b2, uint128 bgt2, uint128 spent2) = core.spendState();
            assertEq(b2, c.bucket);
            assertEq(bgt2, c.budget, "spendState budget fixed point");
            assertEq(spent2, c.spent);
            emit log_named_uint("cold age seconds", ages[i]);
            emit log_named_uint("ethRate wei per 100 points", c.rate);
            emit log_named_uint("pending-aware spend budget wei", c.budget);
            vm.revertToState(snap);
        }
    }

    function _valuePool() internal {
        _enterPhase2();
        balanceKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(balanceKey, OPEN_SP);
        TestLiquidityHelper lp = new TestLiquidityHelper();
        xt.mint(address(this), 1e30);
        xt.approve(address(lp), type(uint256).max);
        xt.approve(address(router), type(uint256).max);
        vm.deal(address(this), address(this).balance + 10 ether);
        lp.modify{value: 2 ether}(balanceKey, -887220, 887220, int256(1e18));
        assertGe(PM.getLiquidity(balanceKey.toId()), 1e18, "real active liquidity");
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        uint256 spot = FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, OPEN_SP), FixedPoint96.Q96, OPEN_SP);
        vm.prank(owner);
        ctl.setBalancePoolKey(k, spot);
        vm.prank(owner);
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 450,
                referenceMaxStale: 1 hours,
                referenceMinSeconds: 600,
                minLiquidity: 1e18
            })
        );
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.balanceBidCapBps = 11_000;
        s.spendCapBps = 9_999;
        s.saleFloorBps = 5_000;
        _setSettings(s);
    }

    // promise: a keeper refresh books the pending fee income first and pays the caller from the pot share the keeper's
    // gate predicted, and a later stale reference degrades the eth bid instead of reverting (decision 159, C02)
    function test_refreshReferenceBooksPendingIncomeAndPays() public {
        _valuePool();
        autoBook = false;
        _buyCoin(funder, 0.005 ether);
        assertEq(core.ethPot(), 0, "no engine call booked the hook push");
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0.0003 ether, "the real hook pushed enough to cover the keeper's caller fee");
        assertLt(pending, 0.01 ether, "the latched keeper's book gate stays idle below its threshold");
        // the once-per-block refresh guard needs a new block past the seed block
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        uint256 before = keeper.balance;
        uint256 oldTime = ctl.referenceTime();
        vm.prank(keeper);
        core.refreshReference();
        assertGt(ctl.referenceTime(), oldTime, "the keeper did refresh the reference");
        uint256 paid = keeper.balance - before;
        assertGt(paid, 0, "the refresh booked the pending income and paid the caller from the pot share");
        assertLe(paid, pending, "the payment is at most the pending income it booked");
        assertGt(core.ethPot() + paid, 0, "the pending pot share is booked");
        // a stale reference no longer reverts the eth bid: it falls back to the last good value rate
        vm.warp(block.timestamp + 3_601);
        assertGt(core.ethRate(), 0, "a stale reference degrades to the last good rate, not NoQuote");
        emit log_named_uint("pending income booked and paid from as pot", pending);
    }

    // promise: after the payee latch, a refresh books the new hook income and pays the caller from it, not only the
    // booked dust (decision 159, C02)
    function test_refreshAfterLatchBooksNewHookIncome() public {
        _valuePool();
        autoBook = false;
        vm.warp(block.timestamp + 1_800);
        vm.deal(address(core), 1);
        core.book();
        assertTrue(core.payeeOn());
        assertEq(core.ethPot(), 1);
        _buyCoin(funder, 0.005 ether);
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0.0003 ether);
        assertLt(pending, 0.01 ether, "the keeper's post-latch book threshold is not met");
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        uint256 before = keeper.balance;
        uint256 potBefore = core.ethPot();
        vm.prank(keeper);
        core.refreshReference();
        uint256 paid = keeper.balance - before;
        assertGt(paid, 1, "the refresh books the new hook income and pays more than the dust wei");
        // the pending pot share less the caller payment is now booked (the dust was already in the pot)
        assertGt(core.ethPot() + paid, potBefore, "the new hook income is booked by the refresh");
        emit log_named_uint("post-latch pending hook income", pending);
    }

    // promise: a credit sale view equals the amount its first buy charges when a reference refresh is due (C03)
    function test_creditPriceEqualsFirstBuyChargeAtDueRefresh() public {
        _valuePool();
        _setCreditSaleOn(true);
        _addToPot(1 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));
        // Selling balance tokens through the real pool lowers their ETH price.
        router.swap(balanceKey, false, -int256(1e17), address(this));
        // past the seed block and the refresh cadence, so the view projects the refresh the buy persists
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        uint256 quoted = ctl.creditPrice(id);
        uint256 refBefore = ctl.referencePrice();
        vm.deal(funder, quoted + 1 ether);
        uint256 before = funder.balance;
        vm.prank(funder);
        ctl.buyCredit{value: quoted}(id);
        uint256 charged = before - funder.balance;
        assertLt(ctl.referencePrice(), refBefore, "the buy refreshed the reference downward");
        assertEq(charged, quoted, "the view quote equals the first buy charge");
        emit log_named_uint("creditPrice view wei", quoted);
        emit log_named_uint("buyCredit charged wei", charged);
    }

    // promise: a statement priceOf view equals the first buy charge when a reference refresh is due (C03)
    function test_statementPriceEqualsFirstBuyChargeAtDueRefresh() public {
        _valuePool();
        _addToPot(20 ether);
        Composed memory c = _composeOnce();
        router.swap(balanceKey, false, -int256(1e17), address(this));
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        uint256 quoted = ctl.priceOf(c.sid);
        uint256 refBefore = ctl.referencePrice();
        vm.deal(funder, quoted + 1 ether);
        uint256 before = funder.balance;
        vm.prank(funder);
        ctl.buy{value: quoted}(c.sid);
        uint256 charged = before - funder.balance;
        assertLt(ctl.referencePrice(), refBefore, "the statement buy refreshed the reference downward");
        assertEq(charged, quoted, "the view quote equals the first statement buy charge");
        emit log_named_uint("priceOf view wei", quoted);
        emit log_named_uint("statement buy charged wei", charged);
    }

    // promise: balanceBidOf reads 0 when the module cannot pay the credit's floor, and the fill still reverts (C05)
    function test_thinModuleBalanceBidReadsZero() public {
        _enterPhase2();
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        mod.setAvailable(1e15);
        assertEq(core.balanceBidOf(id), 0, "the view reads 0 for a payout the module cannot fill");
        assertLt(mod.available(), 9e15, "the module committed less than the 90 percent floor payout");
        vm.prank(seller);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(_one(id));
        emit log_named_uint("available balance tokens", mod.available());
    }

    // promise: a balance token sent to the Core reaches the module or a recoverable balance path on the next call
    function test_balanceTokenSentToCoreRemainsOutsideModule() public {
        _enterPhase2();
        uint256 before = mod.available();
        xt.mint(address(core), 1e18);
        assertEq(xt.balanceOf(address(core)), 1e18);
        core.book();
        assertEq(mod.available(), before, "booking cannot move a direct token donation into the module");
        assertEq(xt.balanceOf(address(core)), 1e18, "the direct token donation remains in Core custody");
        emit log_named_uint("balance tokens stranded at Core", xt.balanceOf(address(core)));
    }

    // promise: rescueToken recovers a stray ERC20 the Core holds and refuses the balance token (decision 159, C06)
    function test_rescueTokenRecoversStrayErc20AndRefusesBalanceToken() public {
        _enterPhase2();
        MockBalanceToken stray = new MockBalanceToken("Stray", "STR");
        stray.mint(address(core), 5e18);
        vm.prank(owner);
        core.rescueToken(address(stray), owner, 5e18);
        assertEq(stray.balanceOf(owner), 5e18, "the stray token is recovered to the owner");
        assertEq(stray.balanceOf(address(core)), 0, "none is left at the Core");
        // the balance token may leave only through the module path, so rescueToken refuses it
        xt.mint(address(core), 1e18);
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.rescueToken(address(xt), owner, 1e18);
        assertEq(xt.balanceOf(address(core)), 1e18, "the balance token stays with the Core");
    }

    // promise: a new, zero-balance module accepts the first eligible real Statement redemption and receives the
    // correct balance-token amount before any balance-side fill
    function test_firstRedeemIntoFreshEmptyModule() public {
        Composed memory c = _composeOnce();
        MockBalanceToken token = new MockBalanceToken("Fresh Balance", "FB");
        MockBalanceModule fresh = new MockBalanceModule(address(token), UNIT);
        _setBalanceModule(address(fresh));
        assertEq(fresh.available(), 0);
        _makeEligible(c.sid);
        assertTrue(ctl.atFloor(c.sid));
        uint256 owed = core.ratingOf(c.sid) * UNIT;
        vm.prank(keeper);
        core.redeemStatement(c.sid);
        assertEq(token.balanceOf(address(fresh)), owed);
        assertEq(STATEMENTS.ownerOf(c.sid), address(fresh));
        emit log_named_uint("first fresh-module redemption base units", owed);
    }

    // promise: an owner cannot install a module whose available() reverts, even while real hook income is unbooked
    function test_coldModuleSetRejectsRevertingAvailableWithoutBookingIncome() public {
        _enterPhase2();
        autoBook = false;
        _buyCoin(funder, 0.005 ether);
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0);
        address oldModule = core.balanceModule();
        RevertingAvailableModule bad = new RevertingAvailableModule(address(xt));
        vm.prank(owner);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(bad));
        assertEq(core.balanceModule(), oldModule);
        assertEq(core.ethPot(), 0);
        assertEq(address(core).balance - core.ethToBuyback() - core.ethRedeemBurn(), pending);
    }

    // promise: cold owner levers make their documented state changes but only setSettings books pending hook income
    function test_coldOwnerRateSettingsControllerAndPauseBooking() public {
        autoBook = false;
        _buyCoin(funder, 2 ether);
        vm.warp(block.timestamp + 600);
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0);
        uint256 snap = vm.snapshotState();

        vm.prank(owner);
        core.setRate(OPEN_RATE);
        assertEq(core.ethPot(), 0, "setRate does not book the real fee income");
        assertEq(address(core).balance, pending);
        vm.revertToState(snap);

        Settings memory s = core.settings();
        s.rateCap = type(uint64).max;
        s.climbPerMinBps = type(uint16).max;
        s.recoveryClimbPerMinBps = type(uint16).max;
        s.ceilBps = type(uint16).max;
        s.balanceBidCapBps = type(uint32).max;
        _setSettings(s);
        assertEq(
            core.ethPot(),
            pending * (10_000 - s.feeToRedeemBurnBps) / 10_000,
            "setSettings books the pot share before changing widened bounds"
        );
        assertEq(core.ethRedeemBurn(), pending * s.feeToRedeemBurnBps / 10_000);
        vm.revertToState(snap);

        vm.prank(owner);
        core.setController(address(ctl));
        assertEq(core.ethPot(), 0, "controller probe does not book");
        vm.prank(owner);
        core.setPaused(true);
        assertTrue(core.paused());
        assertEq(core.ethPot(), 0, "pause does not book");
        assertEq(address(core).balance, pending);
        emit log_named_uint("pending hook income before and after cold owner calls", pending);
    }

    // promise: the launch reference cadence limits a tenfold real-pool spot spike to six 200 bps steps in an hour
    function test_realPoolSpotSpikeAndEveryBlockReferenceWalk() public {
        _valuePool();
        Settings memory s = core.settings();
        s.reserveWei = 0.1 ether;
        _setSettings(s);
        _addToPot(10 ether);
        uint256 openingRef = ctl.referencePrice();
        router.swap{value: 3 ether}(balanceKey, true, -int256(3 ether), address(this));
        (uint256 spot, bool ok) = ctl.spotPrice();
        assertTrue(ok);
        assertGe(spot, openingRef * 10, "real swap makes at least a tenfold spot spike");
        uint256 last = openingRef;
        uint256 moves;
        for (uint256 i; i < 300; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            bool moved = ctl.refreshReference();
            if (moved) {
                assertEq((i + 1) % 50, 0, "only the 600-second cadence moves the reference");
                assertLe(ctl.referencePrice(), last * 10_200 / 10_000, "each move is at most 200 bps");
                last = ctl.referencePrice();
                moves++;
            }
        }
        assertEq(moves, 6, "six reference steps in one hour");
        (uint256 value, bool usable) = ctl.valuePerPoint(false);
        assertTrue(usable, "real pool liquidity makes the quote usable");
        uint256 cappedBySharedRate = uint256(s.balanceBidCapBps) * value * 100 / 10_000;
        assertLe(core.ethRate(), cappedBySharedRate, "spot spike cannot bypass the shared bid cap");
        assertLe(core.ethRate(), s.rateCap, "spot spike cannot bypass rateCap");
        assertLe(core.ethRate(), core.ethPot() - core.reserve(), "spot spike cannot spend the reserve");
        emit log_named_uint("opening reference wei per token", openingRef);
        emit log_named_uint("spiked spot wei per token", spot);
        emit log_named_uint("one-hour reference wei per token", ctl.referencePrice());
        emit log_named_uint("one-hour ETH bid wei per 100 points", core.ethRate());
    }

    // promise: minLiquidity reads the sampled liquidity, so depth added for one block cannot open the quote (C04)
    function test_jitLiquidityCannotOpenQuoteInOneBlock() public {
        _valuePool();
        vm.prank(owner);
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 450,
                referenceMaxStale: 1 hours,
                referenceMinSeconds: 600,
                minLiquidity: 2e18
            })
        );
        (, bool before) = ctl.valuePerPoint(false);
        assertFalse(before, "the sampled liquidity is below the threshold");
        TestLiquidityHelper jit = new TestLiquidityHelper();
        xt.approve(address(jit), type(uint256).max);
        jit.modify{value: 2 ether}(balanceKey, -887220, 887220, int256(1e18));
        (, bool during) = ctl.valuePerPoint(false);
        assertFalse(during, "one-block live liquidity does not change the sampled liquidity the quote reads");
        jit.modify(balanceKey, -887220, 887220, -int256(1e18));
        (, bool after_) = ctl.valuePerPoint(false);
        assertFalse(after_, "the quote stays closed after the JIT position is removed");
    }

    // promise: the owner cannot seed or reseed the reference from a real pool moved beyond the signed expected spot
    function test_realPoolMovedSpotRejectsStaleSeed() public {
        _valuePool();
        uint256 expectedSpot = ctl.referencePrice();
        router.swap{value: 0.03 ether}(balanceKey, true, -int256(0.03 ether), address(this));
        (uint256 movedSpot, bool ok) = ctl.spotPrice();
        assertTrue(ok);
        assertGt(movedSpot, expectedSpot * 10_450 / 10_000, "the actual swap crossed the tolerance band");
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("spot")));
        ctl.setBalancePoolKey(k, expectedSpot);
        vm.stopPrank();
        assertEq(ctl.referencePrice(), expectedSpot, "the rejected owner call leaves the old reference");
    }

    // promise: while value mode is off, a zero referenceMaxStale neither observes the pool nor blocks the launch sale
    function test_modeOffZeroStaleSkipsReferenceAndStillSellsCredit() public {
        _valuePool();
        Settings memory s = core.settings();
        s.valueModeOn = false;
        s.spendCapBps = 10_000;
        _setSettings(s);
        vm.prank(owner);
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 0,
                referenceStepBps: 0,
                tolBps: 450,
                referenceMaxStale: 0,
                referenceMinSeconds: 600,
                minLiquidity: 1e18
            })
        );
        _setCreditSaleOn(true);
        _addToPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 sampledAt = ctl.referenceTime();
        vm.warp(block.timestamp + 1 days);
        router.swap{value: 0.03 ether}(balanceKey, true, -int256(0.03 ether), address(this));
        assertFalse(ctl.refreshReference(), "mode off and zero max stale make observation inert");
        uint256 ask = ctl.creditPrice(id);
        ctl.buyCredit{value: ask}(id);
        assertEq(ctl.referenceTime(), sampledAt, "the sale did not refresh the reference");
        assertEq(CREDITS.ownerOf(id), address(this));
    }

    // promise: at a low live module unit, value mode rounds a positive sale value up instead of displaying zero wei
    function test_realPoolLowUnitSaleValueRoundsUpToOneWei() public {
        _valuePool();
        mod.setUnitPerPoint(1);
        (uint256 spot, bool ok) = ctl.spotPrice();
        assertTrue(ok);
        assertEq(spot, 490_000_000_000_000_000);
        assertEq(ctl.valueOf(1), 1, "the protected sale value rounds positive dust up to one wei");
        assertEq(ctl.valueOf(2), 1, "two stored point units still round to one wei");
        assertEq(ctl.valueOf(3), 2, "three stored point units round to two wei");
    }

    // promise: when the real-pool reference expires, a balance fill remains live and records the last good ETH basis
    // rather than a one-wei fallback
    function test_realPoolQuoteOutageKeepsBalanceFillCostBasis() public {
        _valuePool();
        _addToPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        uint256 lastGood = core.ethPrice();
        vm.warp(block.timestamp + 3_601);
        // a stale reference degrades the eth bid to the last good rate instead of reverting NoQuote (decision 159, C02)
        assertGt(core.ethRate(), 1, "the eth bid falls back to the last good rate, not a dust placeholder");
        vm.prank(seller);
        core.sellForBalance(_one(id));
        (bool inPile, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        assertGt(cost, 1, "the cost basis is not a dust placeholder");
        assertGe(cost, lastGood * _scoreOf(id) / 1_000_000, "the last good price protects the basis");
        emit log_named_uint("quote-outage balance-fill cost basis wei", cost);
    }

    // promise: value mode cannot leave the ETH spend cap disabled at 10,000 bps
    function test_valueModeRejectsDisabledSpendCap() public {
        _valuePool();
        Settings memory s = core.settings();
        assertTrue(s.valueModeOn);
        assertEq(s.spendCapBps, 9_999);
        s.spendCapBps = 10_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("spendCapBps")));
        core.setSettings(s);
        assertEq(core.settings().spendCapBps, 9_999);
    }

    // promise: a same-block v4 spot round trip cannot buy a real-score Credit's bid premium for less than the pool fee
    function test_realPoolSameBlockSpotRoundTripAroundEthSell() public {
        _valuePool();
        _addToPot(10 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 snapshot = vm.snapshotState();
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        uint256 baseline = seller.balance - sellerBefore;
        vm.revertToState(snapshot);

        uint256 tokenBefore = xt.balanceOf(address(this));
        uint256 gasStart = gasleft();
        router.swap{value: 0.03 ether}(balanceKey, true, -int256(0.03 ether), address(this));
        uint256 swapInGas = gasStart - gasleft();
        uint256 tokenBought = xt.balanceOf(address(this)) - tokenBefore;
        uint256 raisedBid = core.bidOf(ids[0]);
        sellerBefore = seller.balance;
        gasStart = gasleft();
        vm.prank(seller);
        core.sellForEth(ids);
        uint256 sellGas = gasStart - gasleft();
        uint256 manipulatedPay = seller.balance - sellerBefore;
        uint256 ethBeforeReverse = address(this).balance;
        gasStart = gasleft();
        router.swap(balanceKey, false, -int256(tokenBought), address(this));
        uint256 swapOutGas = gasStart - gasleft();
        uint256 ethRecovered = address(this).balance - ethBeforeReverse;
        uint256 poolLoss = 0.03 ether - ethRecovered;
        uint256 gasCostAtBaseFee = (swapInGas + sellGas + swapOutGas) * block.basefee;
        // the bid clamps to the prior-block spot sample, so the same-block swap cannot raise the payout (C01)
        assertEq(manipulatedPay, raisedBid, "the bid view is the payout in the manipulated block");
        assertEq(manipulatedPay, baseline, "a same-block spot move does not change the eth bid");
        assertGt(poolLoss, 0, "the round trip still loses the pool fee");
        emit log_named_uint("ordinary bid wei", baseline);
        emit log_named_uint("manipulated bid wei", manipulatedPay);
        emit log_named_uint("v4 swap round-trip loss wei", poolLoss);
        emit log_named_uint("three-call gas at fork base fee wei", gasCostAtBaseFee);
        emit log_named_uint("fork base fee wei per gas", block.basefee);
    }

    // promise: a same-block balance-token spot round trip cannot lower a real Credit purchase price enough to cover
    // the v4 fee and base-fee gas while leaving the attacker with the purchased Credit
    function test_realPoolSameBlockSpotRoundTripAroundCreditBuy() public {
        _valuePool();
        _setCreditSaleOn(true);
        _addToPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 snap = vm.snapshotState();
        uint256 baselineQuote = ctl.creditPrice(id);
        uint256 before = address(this).balance;
        ctl.buyCredit{value: baselineQuote}(id);
        uint256 baselineCharge = before - address(this).balance;
        vm.revertToState(snap);

        uint256 ethBeforeSwap = address(this).balance;
        uint256 gasStart = gasleft();
        router.swap(balanceKey, false, -int256(5e16), address(this));
        uint256 swapInGas = gasStart - gasleft();
        uint256 ethFromSwap = address(this).balance - ethBeforeSwap;
        uint256 loweredQuote = ctl.creditPrice(id);
        // the ask clamps to the prior-block spot sample, so the same-block swap cannot lower it (C01)
        assertEq(loweredQuote, baselineQuote, "a same-block spot move does not lower the protected ask");
        before = address(this).balance;
        gasStart = gasleft();
        ctl.buyCredit{value: baselineQuote}(id);
        uint256 buyGas = gasStart - gasleft();
        uint256 manipulatedCharge = before - address(this).balance;
        before = address(this).balance;
        gasStart = gasleft();
        router.swap{value: 1 ether}(balanceKey, true, int256(5e16), address(this));
        uint256 swapOutGas = gasStart - gasleft();
        uint256 ethToReverse = before - address(this).balance;
        uint256 poolLoss = ethToReverse - ethFromSwap;
        uint256 gasCost = (swapInGas + buyGas + swapOutGas) * block.basefee;
        assertEq(manipulatedCharge, loweredQuote);
        assertEq(manipulatedCharge, baselineCharge, "the manipulated purchase paid the ordinary ask");
        assertGt(poolLoss + gasCost, 0, "the round trip costs pool fees and gas for no saving");
        emit log_named_uint("ordinary Credit ask wei", baselineCharge);
        emit log_named_uint("manipulated Credit ask wei", manipulatedCharge);
        emit log_named_uint("v4 swap round-trip loss wei", poolLoss);
        emit log_named_uint("three-call gas at fork base fee wei", gasCost);
    }
}

/// The cold read checks above use the standard unit fixture. This instance pins the actual launch economics.
contract ColdLaunchMatrixTest is Fixture {
    function _spendHash() internal view returns (bytes32) {
        (uint64 bucket, uint128 budget, uint128 spent) = core.spendState();
        return keccak256(abi.encode(bucket, budget, spent));
    }

    function _fixtureRateStart() internal pure override returns (uint256) {
        return 4_900_000_000_000_000;
    }

    function _fixtureCreditSaleOn() internal pure override returns (bool) {
        return true;
    }

    function _settings() internal view override returns (Settings memory) {
        return Mainnet.defaultSettings();
    }

    // promise: a zero-trade launch cannot invent a funded bid, and an empty first book changes no quote at any age
    function test_zeroTradeColdBookDoesNotStartBid() public {
        uint256 id = _credits(seller, 1)[0];
        uint256 start = block.timestamp;
        uint256[4] memory ages = [uint256(0), 10 minutes, 2 hours, 24 hours];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(start + ages[i]);
            uint256 snap = vm.snapshotState();
            uint256 floor = core.floorRate();
            uint256 multiplier = core.climbMultiplier();
            assertEq(core.ethRate(), 0);
            assertEq(core.bidOf(id), 0);
            assertEq(core.bidForScore(_scoreOf(id)), 0);
            core.book();
            assertEq(core.ethRate(), 0);
            assertEq(core.floorRate(), floor);
            assertEq(core.climbMultiplier(), multiplier);
            assertEq(core.ethPot(), 0);
            vm.revertToState(snap);
        }
    }

    // promise: hook fees arriving between idle steps grow the pages-pot multiplier without an engine call or fill,
    // and the next book is continuous with the view
    function test_midIdleRealTradesGrowMultiplierBeforeAnyFill() public {
        autoBook = false;
        _buyCoin(funder, 2 ether);
        vm.warp(block.timestamp + 300);
        _buyCoin(funder, 0.05 ether);
        vm.warp(block.timestamp + 300);
        uint256 first = core.climbMultiplier();
        uint256 rateBefore = core.ethRate();
        assertEq(core.ethPot(), 0);
        _buyCoin(funder, 2 ether);
        vm.warp(block.timestamp + 600);
        uint256 later = core.climbMultiplier();
        uint256 rateLater = core.ethRate();
        assertGt(later, first, "the unbooked pages pot increased the idle multiplier");
        assertGe(rateLater, rateBefore, "the bid did not need a fill or owner restatement to keep climbing");
        core.book();
        assertEq(core.climbMultiplier(), later);
        assertEq(core.ethRate(), rateLater);
        emit log_named_uint("mid-idle multiplier before", first);
        emit log_named_uint("mid-idle multiplier after second fee push", later);
    }

    // promise: with the real launch reserve and sale switches, real unbooked trading fees produce the same ETH views
    // before and after the first book at launch, 10 minutes, 2 hours and 24 hours
    function test_launchValuesColdViewsEqualFirstBook() public {
        autoBook = false;
        uint256 id = _credits(seller, 1)[0];
        _buyCoin(funder, 2 ether);
        assertEq(core.RATE_START(), 4_900_000_000_000_000);
        assertEq(core.settings().reserveWei, 0.1 ether);
        assertTrue(ctl.creditSaleOn());
        assertEq(core.ethPot(), 0);
        uint256 start = block.timestamp;
        uint256[4] memory ages = [uint256(0), 10 minutes, 2 hours, 24 hours];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(start + ages[i]);
            uint256 snap = vm.snapshotState();
            uint256[6] memory q;
            q[0] = core.ethRate();
            q[1] = core.bidOf(id);
            q[2] = core.bidForScore(_scoreOf(id));
            q[3] = core.floorRate();
            q[4] = core.climbMultiplier();
            q[5] = ctl.valueOf(1_000_000);
            bytes32 spendBefore = _spendHash();
            assertEq(core.balanceRate(), 9_000, "the balance bid is off at its launch floor");
            assertEq(core.balanceBidOf(id), 0);
            assertEq(core.ethToBuyback(), 0);
            assertEq(ctl.referencePrice(), 0);
            (bool ready,,) = ctl.nextPage();
            assertFalse(ready);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.creditPrice(id);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.priceOf(1);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.atFloor(1);
            core.book();
            assertEq(core.ethRate(), q[0]);
            assertEq(core.bidOf(id), q[1]);
            assertEq(core.bidForScore(_scoreOf(id)), q[2]);
            assertEq(core.floorRate(), q[3]);
            assertEq(core.climbMultiplier(), q[4]);
            assertEq(ctl.valueOf(1_000_000), q[5]);
            assertEq(_spendHash(), spendBefore);
            assertEq(core.balanceRate(), 9_000);
            assertEq(core.balanceBidOf(id), 0);
            assertEq(core.ethToBuyback(), 0);
            assertEq(ctl.referencePrice(), 0);
            (bool afterReady,,) = ctl.nextPage();
            assertFalse(afterReady);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.creditPrice(id);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.priceOf(1);
            vm.expectRevert(IControllerV1.NotForSale.selector);
            ctl.atFloor(1);
            emit log_named_uint("launch cold age seconds", ages[i]);
            emit log_named_uint("launch eth bid wei per 100 points", q[0]);
            vm.revertToState(snap);
        }
    }
}
