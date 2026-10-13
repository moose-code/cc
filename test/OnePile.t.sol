// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LowballCreditController} from "./attackers/CreditSaleAttackers.sol";

/// decision 92: one pile for every credit. the exit token bid records an eth cost basis of the higher of the exit
/// tokens paid valued in wei (the controller's `valueWei`, decision 87 pool math) and the current eth bid, so a
/// pushed down pool price cannot record a cost below the eth market. every credit composes into the same statement.
/// the three standalone settings have owner setters, bounds and events
contract OnePileTest is Fixture {
    /// a small sqrt price makes the exit token expensive in eth, so `valueWei` is large and binds above the eth bid
    uint160 internal constant LOW_SQRT = uint160(FixedPoint96.Q96 / 1000);

    /// initializes the exit pool at `sp` and points the controller at it
    function _initPoolAt(uint160 sp) internal {
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

    /// funds the exit pot and the eth pot so the exit bid has a pot to pay from and the eth bid reads nonzero
    function _ready() internal {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(core), 1e24);
        core.skim();
    }

    // ------------------------------------------------------------------ the exit bid's eth cost basis

    /// the exit tokens paid valued in wei exceed the eth bid, so the recorded cost is that value
    function test_sellForExit_costIsTheExitTokenValueWhenItBinds() public {
        _ready();
        _initPoolAt(LOW_SQRT);
        uint256[] memory ids = _credits(seller, 1);
        uint256 ethBid = core.ethRate();
        uint256 xBefore = core.xPot();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 exitPaid = xBefore - core.xPot();
        uint256 valued = ctl.valueWei(exitPaid);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertGt(valued, ethBid, "the exit token value binds above the eth bid");
        assertEq(cost, valued, "the recorded eth cost is the exit tokens valued in wei");
    }

    /// a cheap exit token (a pushed down pool price) values the exit tokens below the eth bid, so the recorded cost
    /// floors at the eth bid rate before the pot clamp and cannot go lower
    function test_sellForExit_costFloorsAtTheEthBidWhenThePoolPriceIsPushedDown() public {
        _ready();
        // the fixture pool is at a high sqrt price: the exit token is cheap, so its wei value is near zero
        _setExitPool();
        uint256[] memory ids = _credits(seller, 1);
        uint256 ethBid = core.ethPrice();
        assertGt(ethBid, 0, "the eth bid is nonzero");
        uint256 xBefore = core.xPot();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 exitPaid = xBefore - core.xPot();
        uint256 valued = ctl.valueWei(exitPaid);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertLt(valued, ethBid, "the pushed down pool price values the exit tokens below the eth bid");
        assertEq(cost, ethBid, "the recorded eth cost floors at the eth bid rate before the clamp");
    }

    /// with an empty eth pot the clamped bid is zero, but the recorded cost floors at the unclamped price state, not
    /// zero, so a credit bought with the exit token is never resellable into the eth bid at a profit (H2). buying it
    /// back costs at least `creditFloorBps` (1.1x) of that unclamped rate
    function test_sellForExit_costFloorsAtTheUnclampedRateWithAnEmptyPot() public {
        _enterPhase2();
        xt.mint(address(core), 1e24);
        core.skim();
        _setExitPool();
        assertEq(core.ethPot(), 0, "the eth pot is empty");
        assertEq(core.ethRate(), 0, "the clamped bid is zero with an empty pot");
        uint256 priceState = core.ethPrice();
        assertGt(priceState, 0, "the unclamped price state is nonzero");

        uint256[] memory ids = _credits(seller, 1);
        uint256 xBefore = core.xPot();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 exitPaid = xBefore - core.xPot();
        uint256 valued = ctl.valueWei(exitPaid);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertLt(valued, priceState, "the cheap pool values the exit tokens below the price state");
        assertEq(cost, priceState, "the recorded cost floors at the unclamped rate, not the clamped zero");
        assertGe(cost, 1, "the recorded cost is at least 1 wei");

        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        vm.warp(block.timestamp + ctl.creditWindow());
        uint256 floor = cost * ctl.creditFloorBps() / 10_000;
        assertEq(ctl.creditPrice(ids[0]), floor, "the sale floor is 1.1x the recorded cost");
        assertGe(ctl.creditPrice(ids[0]), priceState * 11_000 / 10_000, "buy back costs at least 1.1x the unclamped rate");
    }

    /// an inflated pool price records an inflated eth cost (an accepted residual, M1): the credit's sale is floored at
    /// that cost by the core hard floor, so a sale below it reverts BelowFloor, and the statement built from the credit
    /// still leaves the engine through redemption once its curve reaches the floor
    function test_sellForExit_inflatedCostStillRedeems() public {
        address buyer = _user("onepileBuyer");
        _ready();
        _initPoolAt(LOW_SQRT); // expensive exit token: the recorded cost is far above the eth market
        uint256[] memory xIds = _credits(seller, 1);
        vm.prank(seller);
        core.sellForExitToken(xIds);
        (, uint256 inflated,) = core.creditInfo(xIds[0]);
        assertGt(inflated, core.ethPrice() * 100, "the recorded cost is far above the eth bid");

        // a controller that quotes below the inflated cost is refused by the core hard floor
        IControllerV1 saved = ctl;
        LowballCreditController lowball = new LowballCreditController(address(core));
        _setController(address(lowball));
        vm.deal(address(lowball), inflated);
        vm.expectRevert(ICore.BelowFloor.selector);
        lowball.sell{value: inflated - 1}(xIds[0], buyer);
        _setController(address(saved));

        // compose the inflated credit with 79 eth credits into a statement, then redeem it once it is at its floor
        _fillEthPile(79);
        assertEq(core.pileSize(), 80, "a full page including the inflated credit");
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        _makeEligible(sid);
        assertTrue(ctl.atFloor(sid), "the statement reached its floor");
        uint256 xBefore = core.xPot();
        core.exitStatement(sid);
        assertGt(core.xPot(), xBefore, "the statement left the engine through redemption");
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held, "the statement is no longer held");
    }

    /// without the exit pool key the bid cannot value its cost basis, so it reverts
    function test_sellForExit_revertsWithoutThePoolKey() public {
        _ready();
        assertFalse(ctl.exitPoolKeySet(), "no pool key");
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(IControllerV1.NoExitPrice.selector);
        core.sellForExitToken(ids);
    }

    // ------------------------------------------------------------------ one pile, one compose

    /// credits bought through the eth bid and the exit bid share one pile and compose into one statement
    function test_compose_oneKindFromMixedCredits() public {
        _ready();
        _setExitPool();
        // 40 credits through the eth bid, then 40 through the exit bid, into the single pile
        _fillEthPile(40);
        uint256[] memory xIds = _credits(seller, 40);
        vm.prank(seller);
        core.sellForExitToken(xIds);
        assertEq(core.pileSize(), 80, "one pile holds both kinds of credits");

        uint256[] memory page = core.pilePage(0, 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (, uint256 c,) = core.creditInfo(page[i]);
            sum += c;
        }
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        (bool held, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held, "the statement is held");
        assertEq(cost, sum, "the cost basis is the sum of the mixed credits' eth cost bases");
        assertEq(core.pileSize(), 0, "the pile is emptied by the compose");
        assertEq(STATEMENTS.ownerOf(sid), address(core));
    }

    // ------------------------------------------------------------------ the standalone settings

    function test_setter_creditCostToPotBps() public {
        assertEq(core.creditCostToPotBps(), 10_000, "launch value");
        vm.expectEmit(address(core));
        emit ICore.CreditCostToPotBpsSet(6_000);
        vm.prank(owner);
        core.setCreditCostToPotBps(6_000);
        assertEq(core.creditCostToPotBps(), 6_000);
        vm.prank(owner);
        core.setCreditCostToPotBps(10_000);
        assertEq(core.creditCostToPotBps(), 10_000, "the top of the bound");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("creditCostToPotBps")));
        core.setCreditCostToPotBps(10_001);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setCreditCostToPotBps(0);
    }

    function test_setter_chosenComposeOn() public {
        assertFalse(core.chosenComposeOn(), "off at launch");
        vm.expectEmit(address(core));
        emit ICore.ChosenComposeOnSet(true);
        vm.prank(owner);
        core.setChosenComposeOn(true);
        assertTrue(core.chosenComposeOn());
        vm.prank(owner);
        core.setChosenComposeOn(false);
        assertFalse(core.chosenComposeOn());
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setChosenComposeOn(true);
    }

    function test_setter_minCcToChoose() public {
        assertEq(core.minCcToChoose(), 0, "zero at launch");
        vm.expectEmit(address(core));
        emit ICore.MinCcToChooseSet(123e18);
        vm.prank(owner);
        core.setMinCcToChoose(123e18);
        assertEq(core.minCcToChoose(), 123e18);
        vm.prank(owner);
        core.setMinCcToChoose(type(uint96).max);
        assertEq(core.minCcToChoose(), type(uint96).max, "the top of the type");
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setMinCcToChoose(1);
    }
}
