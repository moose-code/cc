// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ICreditScore, ICredits, Mainnet} from "../src/interfaces/Interfaces.sol";
import {LowballCreditController, ReentrantCreditBuyer} from "./attackers/CreditSaleAttackers.sol";

/// credit sale window. pile credits are for sale from acquisition at a price that falls linearly from a start to a
/// floor over `creditWindow` and rests at the floor. the floor is the larger of the credit's cost and `valueOf(score)`,
/// times `creditFloorBps`; the start is the floor times `creditStartBps`. `valueOf` is the larger of the rate term
/// `floorRate * score / refScore` and the balance token pool term, which reads the live pool and the live unit: a
/// missing or failed pool read leaves the pool term at 0 and the sale never reverts for it. the core keeps a hard floor
/// at the credit's cost. a buy pays the price plus the royalty. while the sale is on compose takes only credits past
/// their window
contract CreditSaleTest is Fixture {
    uint256 internal constant BPS = 10_000;
    /// a small sqrt price makes the balance token expensive in eth, so the baseline is large
    uint160 internal constant HIGH_PRICE_SQRT = uint160(FixedPoint96.Q96 / 1000);

    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = _user("creditbuyer");
    }

    // ------------------------------------------------------------------ helpers

    /// turns the sale on and sells `n` fresh credits into the pile, then drops the eth bid far below their cost so the
    /// cost term governs the floor and the bid does not drift the price as time passes
    function _armCostGoverns(uint256 n) internal returns (uint256[] memory ids) {
        ids = _fillEthPile(n);
        vm.prank(owner);
        core.setRate(1e13); // the rate floor, far below the sale cost
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
    }

    function _on() internal {
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
    }

    /// initializes a native eth / balance token pool at `sp` and points the controller at it
    function _initBalancePoolAt(uint160 sp) internal {
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(vk, sp);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
    }

    /// `who` buys credit `id` at the price `price` plus the royalty on it
    function _buyAt(address who, uint256 id, uint256 price) internal {
        uint256 pay = price + price * ctl.royaltyBps() / BPS;
        vm.deal(who, who.balance + pay);
        vm.prank(who);
        ctl.buyCredit{value: pay}(id);
    }

    /// the credit score source the balance token bid and the credit baseline both read: `scoreOf(seed, paidAt)` on the
    /// mainnet credit score contract
    function _creditScore(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// `baseUnits` of the balance token priced in wei at a pool whose sqrt price is `sp`, the same math the controller's
    /// pool term uses. native eth is currency0, so wei per base unit is `(2^96 / sp)^2`
    function _poolValueWei(uint256 baseUnits, uint160 sp) internal pure returns (uint256) {
        uint256 q = FixedPoint96.Q96;
        return FullMath.mulDiv(FullMath.mulDiv(baseUnits, q, sp), q, sp);
    }

    /// the rate term of `valueOf(score)` for credit `id`: the floor rate times the score over `refScore`
    function _rateTerm(uint256 id) internal view returns (uint256) {
        return FullMath.mulDiv(core.floorRate(), _creditScore(id), ctl.refScore());
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ------------------------------------------------------------------ toggle and gating

    function test_toggle_offBlocksBuyCredit() public {
        uint256[] memory ids = _fillEthPile(1);
        assertFalse(ctl.creditSaleOn(), "off at launch");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.CreditSaleOff.selector);
        ctl.buyCredit{value: 10 ether}(ids[0]);
    }

    function test_setters_boundsAndEventsAndOwner() public {
        assertEq(ctl.creditWindow(), 4 hours, "launch window");
        assertEq(ctl.creditFloorBps(), 11_000, "launch floor");
        assertEq(ctl.creditStartBps(), 30_000, "launch start");

        vm.expectEmit(address(ctl));
        emit IControllerV1.CreditSaleOnSet(true);
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        assertTrue(ctl.creditSaleOn());

        vm.prank(owner);
        ctl.setCreditWindow(1 minutes);
        vm.prank(owner);
        ctl.setCreditWindow(30 days);
        assertEq(ctl.creditWindow(), 30 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("creditWindow")));
        ctl.setCreditWindow(1 minutes - 1);

        vm.prank(owner);
        ctl.setCreditFloorBps(40_000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("creditFloorBps")));
        ctl.setCreditFloorBps(9_999);

        vm.prank(owner);
        ctl.setCreditStartBps(200_000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("creditStartBps")));
        ctl.setCreditStartBps(9_999);

        // every setter is owner only
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setCreditSaleOn(false);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setCreditWindow(100);
    }

    // ------------------------------------------------------------------ the falling price

    function test_price_startMidFloorAfter() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        assertLt(core.ethRate(), cost, "the bid is below the cost");
        uint256 floor = cost * ctl.creditFloorBps() / BPS;
        uint256 start = floor * ctl.creditStartBps() / BPS;
        uint256 window = ctl.creditWindow();

        // age 0: the start
        assertEq(ctl.creditPrice(id), start, "start at acquisition");
        // the balance token baseline is off, so the floor is the cost times the floor bps
        assertEq(floor, cost * 11_000 / BPS, "floor is 110 percent of cost");
        assertEq(start, floor * 3, "start is three times the floor");

        // mid window: on the straight line
        _warp(window / 2);
        assertEq(ctl.creditPrice(id), start - (start - floor) * (window / 2) / window, "on the line at mid window");

        // end of window: the floor
        _warp(window - window / 2);
        assertEq(ctl.creditPrice(id), floor, "floor at the window end");

        // past the window: still the floor
        _warp(window);
        assertEq(ctl.creditPrice(id), floor, "floor after the window");
    }

    function test_price_monotoneNonIncreasing() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        uint256 prev = ctl.creditPrice(id);
        uint256 step = ctl.creditWindow() / 20;
        for (uint256 i; i < 25; ++i) {
            _warp(step);
            uint256 p = ctl.creditPrice(id);
            assertLe(p, prev, "price never rises");
            prev = p;
        }
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(prev, cost * ctl.creditFloorBps() / BPS, "rests at the floor");
    }

    function test_price_revertsWhenNotInPile() public {
        _on();
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.creditPrice(999_999_999);
    }

    // ------------------------------------------------------------------ the floor picks each term

    function test_floor_picksTheCost() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        _warp(ctl.creditWindow());
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(cost, core.ethRate(), "cost is the highest term");
        assertEq(ctl.creditPrice(id), cost * ctl.creditFloorBps() / BPS, "floor is cost based");
    }

    function test_floor_picksThePoolTerm() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        // an expensive balance token pool makes the credit's balance token baseline the highest term
        _initBalancePoolAt(HIGH_PRICE_SQRT);
        vm.prank(owner);
        core.setRate(1e13); // keep the floor rate small
        _on();
        _warp(ctl.creditWindow());

        // the pool term uses the same credit score source the balance token bid reads, priced at the pool sqrt price
        uint256 pool = _poolValueWei(_creditScore(id) * UNIT, HIGH_PRICE_SQRT);
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(pool, cost, "pool term above cost");
        assertGt(pool, _rateTerm(id), "pool term above the rate term");
        assertEq(ctl.valueOf(_creditScore(id)), pool, "valueOf is the pool term");
        assertEq(ctl.creditPrice(id), pool * ctl.creditFloorBps() / BPS, "floor is pool term based");
    }

    // ------------------------------------------------------------------ the pool term and the pool read

    function test_poolTerm_zeroWithoutBalanceModule() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        vm.prank(owner);
        core.setRate(1e13);
        _on();
        _warp(ctl.creditWindow());
        (, uint256 cost,) = core.creditInfo(id);
        // no balance module: the pool term is 0 and the sale works
        assertEq(ctl.creditPrice(id), _max(cost, _rateTerm(id)) * ctl.creditFloorBps() / BPS, "no balance module, pool term 0");
    }

    function test_creditPrice_worksWithModuleSetAndPoolKeyUnset() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        vm.prank(owner);
        core.setRate(1e13);
        _on();
        _warp(ctl.creditWindow());
        assertFalse(ctl.balancePoolKeySet(), "no pool key yet");
        // a balance module is set but the pool key is unset: the pool term stays 0 and the floor is the cost or rate term
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(ctl.creditPrice(id), _max(cost, _rateTerm(id)) * ctl.creditFloorBps() / BPS, "the sale prices with the pool term at 0");
    }

    /// a live unit above type(uint128).max is capped before the pool pricing, so the pool term cannot overflow and the
    /// sale does not revert. a score is at most 8_000_000, so the capped product is below 2^151
    function test_poolTerm_unitCappedAtUint128() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        _initBalancePoolAt(HIGH_PRICE_SQRT);
        vm.prank(owner);
        core.setRate(1e13);
        _on();
        _warp(ctl.creditWindow());
        assertGt(_creditScore(id), 1, "the score is above 1");
        vm.mockCall(address(mod), abi.encodeWithSignature("unitPerPoint()"), abi.encode(type(uint256).max));
        // the pool term uses the capped unit and the sale prices without reverting
        uint256 pool = _poolValueWei(_creditScore(id) * uint256(type(uint128).max), HIGH_PRICE_SQRT);
        uint256 hi = pool;
        (, uint256 cost,) = core.creditInfo(id);
        if (cost > hi) hi = cost;
        if (_rateTerm(id) > hi) hi = _rateTerm(id);
        assertEq(ctl.creditPrice(id), hi * ctl.creditFloorBps() / BPS, "the floor uses the capped pool term");
        vm.clearMockedCalls();
    }

    // ------------------------------------------------------------------ the rate term

    /// a credit scored above `refScore` has the rate term `floorRate * score / refScore`
    function test_rateTerm_scalesExactlyWithTheScore() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        _liftRateCap();
        vm.prank(owner);
        core.setRate(cost * 4);
        _fundPot(cost * 20);
        uint256 score = _creditScore(id);
        uint32 rs = uint32(score / 2);
        if (rs == 0) rs = 1;
        vm.prank(owner);
        ctl.setRefScore(rs);
        _on();
        _warp(ctl.creditWindow());
        uint256 floor = core.floorRate();
        uint256 term = floor * score / rs;
        assertGt(term, floor, "the rate term scales above the floor rate");
        assertGt(term, cost, "the rate term governs");
        assertEq(ctl.valueOf(score), term, "valueOf is the rate term");
        assertEq(ctl.creditPrice(id), term * ctl.creditFloorBps() / BPS, "floor is the scaled rate term");
    }

    /// a credit scored below `refScore` has a rate term below the floor rate: the term is proportional to the score
    function test_rateTerm_belowTheReferenceScoreIsBelowTheFloorRate() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        vm.prank(owner);
        ctl.setRefScore(8_000_000);
        assertLt(_creditScore(id), ctl.refScore(), "the score is below the reference");
        assertLt(ctl.valueOf(_creditScore(id)), core.floorRate(), "the rate term is below the floor rate");
        assertEq(ctl.valueOf(_creditScore(id)), core.floorRate() * _creditScore(id) / 8_000_000);
    }

    /// a pushed down pool price values a rich credit's balance tokens below its rate term, so the floor rests at
    /// `creditFloorBps` (1.1x) of the rate term, not the manipulated pool value
    function test_poolTerm_pushedDownPoolLeavesRichCreditAtTheRateTerm() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        // a large sqrt price makes the balance token cheap in eth, so the pool term is far below the rate term
        uint160 pushedDown = uint160((uint256(1) << 96) * 1000);
        _initBalancePoolAt(pushedDown);
        (, uint256 cost,) = core.creditInfo(id);
        _liftRateCap();
        vm.prank(owner);
        core.setRate(cost * 4);
        _fundPot(cost * 20);
        uint256 score = _creditScore(id);
        uint32 rs = uint32(score / 4);
        if (rs == 0) rs = 1;
        vm.prank(owner);
        ctl.setRefScore(rs);
        _on();
        _warp(ctl.creditWindow());
        uint256 floor = core.floorRate();
        uint256 term = floor * score / rs;
        uint256 pool = _poolValueWei(score * UNIT, pushedDown);
        assertLt(pool, term, "the pushed down pool values the credit below its rate term");
        assertGt(term, cost, "the rate term governs");
        assertEq(ctl.creditFloorBps(), 11_000, "the floor multiplier is 1.1x");
        assertEq(ctl.creditPrice(id), term * ctl.creditFloorBps() / BPS, "floor is 1.1x the rate term");
    }

    // ------------------------------------------------------------------ the floor uses the floor rate

    /// the credit sale floor reads the floor rate, so a sale that enlarges the pot cannot push the rate the credit is
    /// priced against down within the block
    function test_floor_usesThePeakNotTheClampedRate() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        // raise the stored rate far above the pot so the clamp binds: the floor rate is above the clamped read
        _liftRateCap();
        uint256 big = core.ethPot() * 4;
        vm.prank(owner);
        core.setRate(big);
        uint32 score = uint32(_creditScore(id));
        vm.prank(owner);
        ctl.setRefScore(score); // the rate term is then the floor rate itself
        _on();
        _warp(ctl.creditWindow());
        uint256 floor = core.floorRate();
        uint256 clamped = core.ethRate();
        assertGt(floor, clamped, "the clamp binds, the floor rate is above the clamped read");
        (, uint256 cost,) = core.creditInfo(id);
        uint256 hi = cost > floor ? cost : floor;
        assertEq(ctl.creditPrice(id), hi * ctl.creditFloorBps() / BPS, "the floor uses the floor rate");
        assertGt(ctl.creditPrice(id), clamped * ctl.creditFloorBps() / BPS, "the floor is above the clamped rate floor");
    }

    /// buying a credit then selling it straight back into the eth bid in the same flow is a loss: the purchase pays
    /// the floor rate backed floor and the sell back pays the clamped rate
    function test_h1_buyThenSellBackIsUnprofitable() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        _liftRateCap();
        uint256 big = core.ethPot() * 4;
        vm.prank(owner);
        core.setRate(big);
        _on();
        _warp(ctl.creditWindow());
        uint256 price = ctl.creditPrice(id);

        uint256 gross = ctl.grossCreditPrice(id);
        vm.deal(buyer, gross);
        vm.prank(buyer);
        ctl.buyCredit{value: gross}(id);
        assertEq(CREDITS.ownerOf(id), buyer, "the buyer holds the credit");

        vm.prank(buyer);
        CREDITS.setApprovalForAll(address(core), true);
        uint256[] memory back = new uint256[](1);
        back[0] = id;
        uint256 ethBefore = buyer.balance;
        vm.prank(buyer);
        core.sellForEth(back);
        assertLt(buyer.balance - ethBefore, price, "the sell back pays less than the purchase cost");
        assertEq(CREDITS.ownerOf(id), address(core), "the credit is back in the engine");
    }

    /// `buyCredits` prices each credit after the previous sale in one pass, so the batch charges the sum of the
    /// in-order quotes and empties the pile (H1)
    function test_h1_buyCreditsPricesEachAfterThePreviousSale() public {
        uint256[] memory ids = _armCostGoverns(2);
        _warp(ctl.creditWindow());
        uint256 q0 = ctl.grossCreditPrice(ids[0]);
        uint256 q1 = ctl.grossCreditPrice(ids[1]);
        uint256 pay = q0 + q1 + 1 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredits{value: pay}(ids);
        assertEq(buyer.balance, pay - (q0 + q1), "the batch charges each credit priced in order");
        assertEq(core.pileSize(), 0, "both credits left the pile");
    }

    // ------------------------------------------------------------------ buy

    function test_buy_underpayReverts() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.creditPrice(ids[0]);
        uint256 gross = ctl.grossCreditPrice(ids[0]);
        vm.deal(buyer, gross);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buyCredit{value: gross - 1}(ids[0]);
    }

    function test_buy_refundsTheExcess() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.creditPrice(ids[0]);
        uint256 gross = ctl.grossCreditPrice(ids[0]);
        uint256 pay = gross + 0.5 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredit{value: pay}(ids[0]);
        assertEq(buyer.balance, pay - gross, "only the price and the royalty were taken");
        assertEq(gross, price + price * 250 / BPS, "the gross price adds royaltyBps 250");
        assertEq(ctl.royaltyOwed(), gross - price, "the royalty is owed");
        assertEq(CREDITS.ownerOf(ids[0]), buyer, "the buyer holds the credit");
    }

    function test_buy_proceedsSplitAtDefault() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        uint256 price = ctl.creditPrice(id);
        uint256 potBefore = core.ethPot();
        uint256 buybackBefore = core.ethToBuyback();
        assertEq(core.creditCostToPotBps(), 10_000, "default");
        _buyAt(buyer, id, price);
        assertEq(core.ethPot() - potBefore, cost, "the whole cost goes to the pot at the default");
        assertEq(core.ethToBuyback() - buybackBefore, price - cost, "the markup over cost goes to the buyback");
    }

    function test_buy_proceedsSplitAtAnotherBps() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        vm.prank(owner);
        core.setCreditCostToPotBps(6_000);
        (, uint256 cost,) = core.creditInfo(id);
        uint256 price = ctl.creditPrice(id);
        uint256 toPot = cost * 6_000 / BPS;
        uint256 potBefore = core.ethPot();
        uint256 buybackBefore = core.ethToBuyback();
        _buyAt(buyer, id, price);
        assertEq(core.ethPot() - potBefore, toPot, "the pot gets the cost share");
        assertEq(core.ethToBuyback() - buybackBefore, price - toPot, "the rest goes to the buyback");
    }

    function test_buy_coreHardFloorHoldsAgainstAControllerBelowCost() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        LowballCreditController lowball = new LowballCreditController(address(core));
        _setController(address(lowball));
        vm.deal(address(lowball), 10 ether);
        // the controller quotes a wei below cost: the core refuses
        vm.expectRevert(ICore.BelowFloor.selector);
        lowball.sell{value: cost - 1}(id, buyer);
        // at the cost it passes
        lowball.sell{value: cost}(id, buyer);
        assertEq(CREDITS.ownerOf(id), buyer, "the credit moved at the hard floor");
    }

    // ------------------------------------------------------------------ the pile stays valid

    function test_pile_headMiddleTailRemovalKeepsLinksValid() public {
        uint256[] memory ids = _armCostGoverns(5);
        // buy the middle, then the head, then the tail
        _buyAt(buyer, ids[2], ctl.creditPrice(ids[2]));
        _assertPile(_arr4(ids[0], ids[1], ids[3], ids[4]));
        _buyAt(buyer, ids[0], ctl.creditPrice(ids[0]));
        _assertPile(_arr3(ids[1], ids[3], ids[4]));
        _buyAt(buyer, ids[4], ctl.creditPrice(ids[4]));
        _assertPile(_arr2(ids[1], ids[3]));
    }

    function test_buyCredits_batch() public {
        uint256[] memory ids = _armCostGoverns(3);
        uint256 total;
        uint256 royalty;
        for (uint256 i; i < 3; ++i) {
            total += ctl.grossCreditPrice(ids[i]);
            royalty += ctl.creditPrice(ids[i]) * ctl.royaltyBps() / BPS;
        }
        uint256 pay = total + 1 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredits{value: pay}(ids);
        assertEq(buyer.balance, pay - total, "paid the sum, got the excess back");
        assertEq(ctl.royaltyOwed(), royalty, "the batch owes the sum of the per credit royalty");
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), buyer, "the buyer holds each credit");
        }
        assertEq(core.pileSize(), 0, "the pile is emptied");
    }

    function test_buyCredits_underpayRevertsAndNothingMoves() public {
        uint256[] memory ids = _armCostGoverns(2);
        uint256 total = ctl.grossCreditPrice(ids[0]) + ctl.grossCreditPrice(ids[1]);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buyCredits{value: total - 1}(ids);
        assertEq(core.pileSize(), 2, "the pile is untouched");
    }

    function test_pause_blocksBuy() public {
        uint256[] memory ids = _armCostGoverns(1);
        vm.prank(owner);
        ctl.setPaused(true);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Paused.selector);
        ctl.buyCredit{value: price}(ids[0]);
    }

    /// decision 97: a pause stops `buyCredits` too, and the clock keeps running so the window still passes during it
    function test_pause_blocksBuyCredits() public {
        uint256[] memory ids = _armCostGoverns(2);
        _warp(ctl.creditWindow());
        uint256 total = ctl.grossCreditPrice(ids[0]) + ctl.grossCreditPrice(ids[1]);
        vm.prank(owner);
        ctl.setPaused(true);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Paused.selector);
        ctl.buyCredits{value: total}(ids);
        assertEq(core.pileSize(), 2, "nothing moved while paused");

        // the window clock advanced during the pause: resume and the sale works
        vm.prank(owner);
        ctl.setPaused(false);
        vm.prank(buyer);
        ctl.buyCredits{value: total}(ids);
        assertEq(core.pileSize(), 0, "the batch sells after resume");
    }

    // ------------------------------------------------------------------ compose and the window

    function test_compose_atOnceWhenSaleOff() public {
        _fillEthPile(80);
        assertFalse(ctl.creditSaleOn(), "sale off");
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        (bool held,,) = core.statementInfo(supply + 1);
        assertTrue(held, "the statement composed with the sale off");
    }

    function test_compose_waitsForTheWindowWhenSaleOn() public {
        _fillEthPile(80);
        _on();
        (bool ready,,) = ctl.nextPage();
        assertFalse(ready, "not ready while the newest credit is inside its window");
        vm.fee(composeBasefee);
        vm.prank(keeper);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();

        // past the window the page is ready and compose runs
        _warp(ctl.creditWindow() + 1);
        (ready,,) = ctl.nextPage();
        assertTrue(ready, "ready once the window has passed");
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        (bool held,,) = core.statementInfo(supply + 1);
        assertTrue(held, "the statement composed after the window");
    }

    // ------------------------------------------------------------------ a balance token credit sells at its recorded cost

    function test_buy_balanceTokenCreditSellsAtItsRecordedCost() public {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(core), 1e24);
        core.skim();
        _setBalancePool();
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        vm.prank(seller);
        core.sellForBalance(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(cost, 0, "the credit recorded an eth cost from the redemption sale");

        _on();
        _warp(ctl.creditWindow());
        uint256 price = ctl.creditPrice(id);
        assertGe(price, cost, "the sale price is at least the recorded cost");
        uint256 potBefore = core.ethPot();
        _buyAt(buyer, id, price);
        assertEq(CREDITS.ownerOf(id), buyer, "the balance token credit is sold");
        assertEq(core.ethPot() - potBefore, cost, "the pot books the recorded cost at the default split");
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_buyerCannotReenter() public {
        uint256[] memory ids = _armCostGoverns(2);
        ReentrantCreditBuyer attacker = new ReentrantCreditBuyer(address(ctl));
        uint256 price0 = ctl.creditPrice(ids[0]);
        attacker.arm(ids[1]);
        // overpay so the refund callback fires, where the attacker reenters buyCredit
        uint256 pay = price0 + 1 ether;
        vm.deal(address(attacker), pay);
        vm.expectRevert();
        attacker.buy(ids[0], pay);
        // nothing moved: both credits stay in the pile
        assertEq(core.pileSize(), 2, "the pile is untouched");
        assertEq(CREDITS.ownerOf(ids[0]), address(core), "the core still holds the first credit");
    }

    // ------------------------------------------------------------------ gas

    function test_gas_buyCreditOne() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.grossCreditPrice(ids[0]);
        vm.deal(buyer, price);
        vm.prank(buyer);
        uint256 g = gasleft();
        ctl.buyCredit{value: price}(ids[0]);
        emit log_named_uint("buyCredit(1) gas", g - gasleft());
    }

    function test_gas_buyCreditsTen() public {
        uint256[] memory ids = _armCostGoverns(10);
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            total += ctl.grossCreditPrice(ids[i]);
        }
        vm.deal(buyer, total);
        vm.prank(buyer);
        uint256 g = gasleft();
        ctl.buyCredits{value: total}(ids);
        emit log_named_uint("buyCredits(10) gas", g - gasleft());
    }

    // ------------------------------------------------------------------ pile assertions

    function _assertPile(uint256[] memory want) internal view {
        assertEq(core.pileSize(), want.length, "pile size");
        uint256[] memory page = core.pilePage(0, want.length);
        for (uint256 i; i < want.length; ++i) {
            assertEq(page[i], want[i], "pile order");
        }
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    function _arr4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory x) {
        x = new uint256[](4);
        x[0] = a;
        x[1] = b;
        x[2] = c;
        x[3] = d;
    }
}
