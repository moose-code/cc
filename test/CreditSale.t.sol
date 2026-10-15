// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {CreditSale} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LowballCreditController, ReentrantCreditBuyer} from "./attackers/CreditSaleAttackers.sol";

/// credit sale window. pile credits are for sale from acquisition at a price that falls linearly from a start to a
/// floor over `creditWindow` and rests at the floor. the floor is the larger of the credit's cost and
/// `valueOf(score)`, times `creditFloorBps`; the start is the floor times `creditStartBps`. `valueOf` is the larger of the rate term
/// `floorRate * score / refScore` and the balance token pool term, which reads the live pool and the live unit: a
/// missing or failed pool read leaves the pool term at 0 and the sale never reverts for it. the core keeps a hard floor
/// at the credit's cost. a buy pays the price, with the artist and operator cuts taken off it (decision 123). while
/// the sale is on compose takes only credits past their window
contract CreditSaleTest is Fixture {
    uint256 internal constant BPS = 10_000;

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
        _setCreditSaleOn(true);
    }

    function _on() internal {
        _setCreditSaleOn(true);
    }

    /// `who` buys credit `id` at its price (the artist and operator cuts come off it inside the core)
    function _buyAt(address who, uint256 id, uint256 price) internal {
        vm.deal(who, who.balance + price);
        vm.prank(who);
        ctl.buyCredit{value: price}(id);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ------------------------------------------------------------------ toggle and gating

    // promise: INTEGRATION CreditSaleOff
    function test_toggle_offBlocksBuyCredit() public {
        uint256[] memory ids = _fillEthPile(1);
        assertFalse(ctl.creditSaleOn(), "the fixture starts with the sale off");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.CreditSaleOff.selector);
        ctl.buyCredit{value: 10 ether}(ids[0]);
    }

    // promise: INTEGRATION BadSetting and OnlyOwner on the credit sale setters
    function test_setters_boundsAndEventsAndOwner() public {
        assertEq(ctl.creditWindow(), 4 hours, "launch window");
        assertEq(ctl.creditFloorBps(), 11_000, "launch floor");
        assertEq(ctl.creditStartBps(), 30_000, "launch start");

        CreditSale memory c = _creditSale();
        c.saleOn = true;
        vm.expectEmit(address(ctl));
        emit IControllerV1.CreditSaleSet(c);
        vm.prank(owner);
        ctl.setCredit(c);
        assertTrue(ctl.creditSaleOn());

        vm.startPrank(owner);
        c.window = 1 minutes;
        ctl.setCredit(c);
        c.window = 30 days;
        ctl.setCredit(c);
        assertEq(ctl.creditWindow(), 30 days);
        c.window = 1 minutes - 1;
        _creditBad(c, "creditWindow");
        c.window = 30 days;

        c.floorBps = 40_000;
        ctl.setCredit(c);
        c.floorBps = 9_999;
        _creditBad(c, "creditFloorBps");
        c.floorBps = 40_000;

        c.startBps = 200_000;
        ctl.setCredit(c);
        c.startBps = 9_999;
        _creditBad(c, "creditStartBps");
        c.startBps = 200_000;
        vm.stopPrank();

        // refScore is a Core setting now, its bound is covered by test/SetSettings.t.sol

        // owner only
        c.saleOn = false;
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setCredit(c);
    }

    function _creditBad(CreditSale memory c, bytes32 field) internal {
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, field));
        ctl.setCredit(c);
    }

    // ------------------------------------------------------------------ the falling price

    // promise: SPEC 1 credit sale: the price falls linearly from start to floor over creditWindow and rests
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

    // promise: INTEGRATION NotForSale on creditPrice
    function test_price_revertsWhenNotInPile() public {
        _on();
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.creditPrice(999_999_999);
    }

    // ------------------------------------------------------------------ the floor picks each term

    // ------------------------------------------------------------------ the pool term and the pool read

    // ------------------------------------------------------------------ the rate term

    // ------------------------------------------------------------------ the floor uses the floor rate

    // promise: SPEC 1 credit sale floor: a buy then a sell back into the bid is a loss
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

        uint256 gross = ctl.creditPrice(id);
        vm.deal(buyer, gross);
        vm.prank(buyer);
        ctl.buyCredit{value: gross}(id);
        assertEq(CREDITS.ownerOf(id), buyer, "the buyer holds the credit");

        vm.prank(buyer);
        CREDITS.setApprovalForAll(address(core), true);
        uint256[] memory back = new uint256[](1);
        back[0] = id;
        uint256 ethBefore = buyer.balance;
        vm.roll(block.number + 1); // a credit sold through the credit sale returns through a door in a later block
        vm.prank(buyer);
        core.sellForEth(back);
        assertLt(buyer.balance - ethBefore, price, "the sell back pays less than the purchase cost");
        assertEq(CREDITS.ownerOf(id), address(core), "the credit is back in the engine");
    }

    // promise: an outsider gains nothing at the engine's cost: a credit bought at its sale price and sold straight
    // back into the eth bid returns less than it cost, for the credit with the lowest sale price. the floor is
    // `valueOf(score) * creditFloorBps >= floorRate * score / refScore * creditFloorBps >= bidOf`, so the round trip loses
    function test_noProfit_buyThenSellBackNeverBeatsTheBid() public {
        uint256[] memory ids = _fillEthPile(40);
        _on();
        _warp(ctl.creditWindow());
        uint256 id = ids[0];
        uint256 pay = ctl.creditPrice(id);
        for (uint256 i = 1; i < ids.length; ++i) {
            uint256 g = ctl.creditPrice(ids[i]);
            if (g < pay) {
                pay = g;
                id = ids[i];
            }
        }
        address arb = _user("arb");
        vm.deal(arb, pay);
        vm.startPrank(arb);
        ctl.buyCredit{value: pay}(id);
        CREDITS.setApprovalForAll(address(core), true);
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        vm.roll(block.number + 1); // the same block return is refused; the profit test is about price, not timing
        core.sellForEth(one);
        vm.stopPrank();
        assertLe(arb.balance, pay, "the round trip returned more eth than the credit cost");
    }

    // promise: SPEC 8 the credit sale floor is max(cost, valueOf(score)) * creditFloorBps, the flat floorRate term dropped
    /// a credit scoring well below refScore floors at its per-point value, not the average-credit floor rate. the
    /// dropped term (decision 115a, redundant under the per-point bid of decision 116) would have priced it at floorRate * creditFloorBps, far above
    function test_floor_usesValueOfNotTheFlatFloorRate() public {
        uint256 id = _fillEthPile(1)[0];
        _on();
        // raise the rate well above the credit's recorded cost, so the flat floorRate sits above both the cost and the
        // per-point value term; a high refScore puts the credit's score well below it, so valueOf(score) is a fraction of floorRate
        _liftRateCap();
        vm.prank(owner);
        core.setRate(1e17);
        _setRefScore(8_000_000);
        uint256 s = _scoreOf(id);
        assertLt(s, 8_000_000, "the credit scores below refScore");
        (, uint256 cost,) = core.creditInfo(id);
        uint256 fr = core.floorRate();
        uint256 value = ctl.valueOf(s);
        assertEq(value, FullMath.mulDiv(fr, s, 8_000_000), "valueOf is the rate term, no pool");
        uint256 hi = _max(cost, value);
        assertLt(hi, fr, "the governing term is below the flat floor rate that was dropped");
        uint256 fb = ctl.creditFloorBps();
        _warp(ctl.creditWindow());
        assertEq(ctl.creditPrice(id), hi * fb / BPS, "the floor is max(cost, valueOf(score)) * creditFloorBps");
        assertLt(ctl.creditPrice(id), fr * fb / BPS, "and below floorRate * creditFloorBps, the dropped flat term");
    }

    // promise: SPEC 1 buyCredits prices each credit after the previous sale
    /// `buyCredits` prices each credit after the previous sale in one pass, so the batch charges the sum of the
    /// in-order quotes and empties the pile (H1)
    function test_h1_buyCreditsPricesEachAfterThePreviousSale() public {
        uint256[] memory ids = _armCostGoverns(2);
        _warp(ctl.creditWindow());
        uint256 q0 = ctl.creditPrice(ids[0]);
        uint256 q1 = ctl.creditPrice(ids[1]);
        uint256 pay = q0 + q1 + 1 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredits{value: pay}(ids);
        assertEq(buyer.balance, pay - (q0 + q1), "the batch charges each credit priced in order");
        assertEq(core.pileSize(), 0, "both credits left the pile");
    }

    // ------------------------------------------------------------------ buy

    // promise: INTEGRATION Underpaid on buyCredit
    function test_buy_underpayReverts() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buyCredit{value: price - 1}(ids[0]);
    }

    // promise: SPEC 1 creditCostToPotBps of the cost to ethPot, the rest to the buyback pot
    function test_buy_proceedsSplitAtDefault() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        uint256 price = ctl.creditPrice(id);
        uint256 potBefore = core.ethPot();
        uint256 buybackBefore = core.ethToBuyback();
        assertEq(core.creditCostToPotBps(), 8_000, "default");
        // the artist and operator cuts come off the top, then the credit cost basis share of the rest goes to the pot
        uint256 toArtist = price * core.settings().saleToArtistBps / 10_000;
        uint256 toOperator = price * core.settings().saleToOperatorBps / 10_000;
        uint256 rest = price - toArtist - toOperator;
        uint256 toPot = cost * 8_000 / 10_000;
        if (toPot > rest) toPot = rest;
        _buyAt(buyer, id, price);
        assertEq(core.ethPot() - potBefore, toPot, "the credit cost basis share of the rest goes to the pot");
        assertEq(core.ethToBuyback() - buybackBefore, rest - toPot, "the remainder of the rest goes to the buyback");
    }

    // promise: INTEGRATION BelowFloor on sellCreditTo
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

    // promise: INTEGRATION Paused
    function test_pause_blocksBuy() public {
        uint256[] memory ids = _armCostGoverns(1);
        vm.prank(owner);
        core.setPaused(true);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(ICore.Paused.selector);
        ctl.buyCredit{value: price}(ids[0]);
    }

    // ------------------------------------------------------------------ compose and the window

    // promise: SPEC 1 credit sale window: composeChosen waits for the window (InWindow)
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

    // promise: SPEC 1 one pile: a balance bought credit sells at its recorded cost (decision 96)
    function test_buy_balanceTokenCreditSellsAtItsRecordedCost() public {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(mod), 1e24);
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
        assertEq(core.ethPot() - potBefore, cost * 8_000 / 10_000, "the pot books 80 percent of the recorded cost at the default split");
    }

    // ------------------------------------------------------------------ reentrancy

    // promise: INTEGRATION Reentrancy on buyCredit
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

    // ------------------------------------------------------------------ pile assertions

}
