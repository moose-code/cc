// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

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
    /// floors at the eth bid and cannot go lower
    function test_sellForExit_costFloorsAtTheEthBidWhenThePoolPriceIsPushedDown() public {
        _ready();
        // the fixture pool is at a high sqrt price: the exit token is cheap, so its wei value is near zero
        _setExitPool();
        uint256[] memory ids = _credits(seller, 1);
        uint256 ethBid = core.ethRate();
        assertGt(ethBid, 0, "the eth bid is nonzero");
        uint256 xBefore = core.xPot();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 exitPaid = xBefore - core.xPot();
        uint256 valued = ctl.valueWei(exitPaid);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertLt(valued, ethBid, "the pushed down pool price values the exit tokens below the eth bid");
        assertEq(cost, ethBid, "the recorded eth cost floors at the eth bid");
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
