// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {MockCreditScoreModule} from "./standins/MockCreditScoreModule.sol";
import {LowballCreditController, ReentrantCreditBuyer} from "./attackers/CreditSaleAttackers.sol";

/// decision 88, credit sale window. pile credits are for sale from acquisition at a price that falls linearly from a
/// start to a floor over `creditWindow` and rests at the floor. the floor is the highest of the credit's cost, its exit
/// token baseline and the current eth bid, times `creditFloorBps`; the start is the floor times `creditStartBps`. the
/// core keeps a hard floor at the credit's cost. while the sale is on compose takes only credits past their window
contract CreditSaleTest is Fixture {
    uint256 internal constant BPS = 10_000;
    /// a small sqrt price makes the exit token expensive in eth, so the baseline is large
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

    /// initializes a native eth / exit token pool at `sp` and points the controller at it
    function _initExitPoolAt(uint160 sp) internal {
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
        ctl.setExitPoolKey(k);
    }

    function _buyAt(address who, uint256 id, uint256 pay) internal {
        vm.deal(who, who.balance + pay);
        vm.prank(who);
        ctl.buyCredit{value: pay}(id);
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
        assertEq(ctl.creditScoreModule(), address(0), "launch score module");

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

        vm.expectEmit(address(ctl));
        emit IControllerV1.CreditScoreModuleSet(address(0xBEEF));
        vm.prank(owner);
        ctl.setCreditScoreModule(address(0xBEEF));
        assertEq(ctl.creditScoreModule(), address(0xBEEF));

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
        // the exit token baseline is off, so the floor is the cost times the floor bps
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

    function test_floor_picksTheEthBid() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        (, uint256 cost,) = core.creditInfo(id);
        // lift the bid far above the credit's cost
        _liftRateCap();
        vm.prank(owner);
        core.setRate(cost * 4);
        _fundPot(cost * 20);
        _on();
        _warp(ctl.creditWindow());
        uint256 bid = core.ethRate();
        assertGt(bid, cost, "the bid is the highest term");
        assertEq(ctl.creditPrice(id), bid * ctl.creditFloorBps() / BPS, "floor is bid based");
    }

    function test_floor_picksTheBaseline() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        // a score module and an expensive exit token pool make the baseline the highest term
        MockCreditScoreModule sm = new MockCreditScoreModule();
        sm.set(id, 1_000_000);
        vm.prank(owner);
        ctl.setCreditScoreModule(address(sm));
        _initExitPoolAt(HIGH_PRICE_SQRT);
        vm.prank(owner);
        core.setRate(1e13); // keep the bid small
        _on();
        _warp(ctl.creditWindow());

        uint256 baseline = ctl.valueWei(1_000_000 * core.unitPerPoint());
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(baseline, cost, "baseline above cost");
        assertGt(baseline, core.ethRate(), "baseline above the bid");
        assertEq(ctl.creditPrice(id), baseline * ctl.creditFloorBps() / BPS, "floor is baseline based");
    }

    // ------------------------------------------------------------------ baseline is 0 and never reverts

    function test_baseline_zeroWithoutScoreModule() public {
        uint256[] memory ids = _armCostGoverns(1);
        _warp(ctl.creditWindow());
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(ctl.creditScoreModule(), address(0), "no score module");
        assertEq(ctl.creditPrice(ids[0]), cost * ctl.creditFloorBps() / BPS, "baseline contributes nothing");
    }

    function test_baseline_zeroWithoutExitModuleOrPoolKey() public {
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        MockCreditScoreModule sm = new MockCreditScoreModule();
        sm.set(id, 5_000_000);
        vm.prank(owner);
        ctl.setCreditScoreModule(address(sm));
        vm.prank(owner);
        core.setRate(1e13);
        _on();
        _warp(ctl.creditWindow());
        (, uint256 cost,) = core.creditInfo(id);
        // no exit module and no pool key: the baseline is 0 and the price does not revert
        assertEq(ctl.creditPrice(id), cost * ctl.creditFloorBps() / BPS, "no exit module, baseline 0");

        // add the exit module but still no pool key: still 0
        _enterPhase2();
        assertFalse(ctl.exitPoolKeySet(), "no pool key yet");
        assertEq(ctl.creditPrice(id), cost * ctl.creditFloorBps() / BPS, "no pool key, baseline 0");
    }

    function test_baseline_zeroWhenScoreModuleReverts() public {
        _enterPhase2();
        uint256[] memory ids = _fillEthPile(1);
        uint256 id = ids[0];
        MockCreditScoreModule sm = new MockCreditScoreModule();
        sm.set(id, 5_000_000);
        sm.setRevert(true);
        vm.prank(owner);
        ctl.setCreditScoreModule(address(sm));
        _initExitPoolAt(HIGH_PRICE_SQRT);
        vm.prank(owner);
        core.setRate(1e13);
        _on();
        _warp(ctl.creditWindow());
        (, uint256 cost,) = core.creditInfo(id);
        // the module reverts, so the score reads 0 and the sale does not revert
        assertEq(ctl.creditPrice(id), cost * ctl.creditFloorBps() / BPS, "reverting module, baseline 0");
    }

    // ------------------------------------------------------------------ buy

    function test_buy_underpayReverts() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buyCredit{value: price - 1}(ids[0]);
    }

    function test_buy_refundsTheExcess() public {
        uint256[] memory ids = _armCostGoverns(1);
        uint256 price = ctl.creditPrice(ids[0]);
        uint256 pay = price + 0.5 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredit{value: pay}(ids[0]);
        assertEq(buyer.balance, pay - price, "only the price was taken");
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
        for (uint256 i; i < 3; ++i) {
            total += ctl.creditPrice(ids[i]);
        }
        uint256 pay = total + 1 ether;
        vm.deal(buyer, pay);
        vm.prank(buyer);
        ctl.buyCredits{value: pay}(ids);
        assertEq(buyer.balance, pay - total, "paid the sum, got the excess back");
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), buyer, "the buyer holds each credit");
        }
        assertEq(core.pileSize(), 0, "the pile is emptied");
    }

    function test_buyCredits_underpayRevertsAndNothingMoves() public {
        uint256[] memory ids = _armCostGoverns(2);
        uint256 total = ctl.creditPrice(ids[0]) + ctl.creditPrice(ids[1]);
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

    // ------------------------------------------------------------------ an exit token credit sells at its recorded cost

    function test_buy_exitTokenCreditSellsAtItsRecordedCost() public {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(core), 1e24);
        core.skim();
        _setExitPool();
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        vm.prank(seller);
        core.sellForExitToken(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(cost, 0, "the credit recorded an eth cost from the exit sale");

        _on();
        _warp(ctl.creditWindow());
        uint256 price = ctl.creditPrice(id);
        assertGe(price, cost, "the sale price is at least the recorded cost");
        uint256 potBefore = core.ethPot();
        _buyAt(buyer, id, price);
        assertEq(CREDITS.ownerOf(id), buyer, "the exit token credit is sold");
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
        uint256 price = ctl.creditPrice(ids[0]);
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
            total += ctl.creditPrice(ids[i]);
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
