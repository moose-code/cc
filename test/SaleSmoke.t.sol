// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";

/// the sale controller and the fee share on the live fork: the asking price and its decay, `buy` through
/// `sellTo`, the hard floor, the pool fee split and the redeem caller payment
contract SaleSmokeTest is Fixture {
    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (, cost,) = core.statementInfo(sid);
    }

    function test_statement_opens_at_the_start_price_of_the_controller() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(ctl.priceOf(sid), cost * 15_000 / 10_000, "ask is 150 percent");
    }

    function test_price_falls_to_the_knee_then_to_the_floor() public {
        uint256 sid = _composeOnce().sid;
        // the curve prices in bps of the reference, which follows the floor rate as time passes
        _warp(25 hours);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 12_500 / 10_000, "half way to the knee: 125 percent");
        _warp(25 hours);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid), "at the knee at hour 50: 100 percent");
        _warp(100 hours);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 10_000 / 10_000, "at the floor at hour 150");
        _warp(100 hours);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 10_000 / 10_000, "never below the floor");
    }

    function test_buy_sells_at_once_and_refunds_the_excess() public {
        uint256 sid = _composeOnce().sid;
        _warp(6 hours);
        uint256 price = ctl.priceOf(sid);
        uint256 potBefore = core.ethPot();
        uint256 bbBefore = core.ethToBuyback();
        address buyer = address(0xB0B);
        uint256 gross = ctl.grossPriceOf(sid);
        vm.deal(buyer, gross + 1 ether);
        vm.prank(buyer);
        ctl.buy{value: gross + 1 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "statement delivered");
        assertEq(buyer.balance, 1 ether, "excess refunded");
        uint256 toBuyback = price * core.settings().saleToBuybackBps / 10_000;
        assertEq(core.ethToBuyback() - bbBefore, toBuyback, "buyback share booked");
        assertEq(core.ethPot() - potBefore, price - toBuyback, "rest to the pot");
        assertFalse(_isHeld(sid), "record cleared");
        _solvent();
    }

    function test_buy_below_the_price_reverts() public {
        uint256 sid = _composeOnce().sid;
        uint256 gross = ctl.grossPriceOf(sid);
        vm.deal(address(0xB0B), gross);
        vm.prank(address(0xB0B));
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: gross - 1}(sid);
    }

    function test_sellTo_is_for_the_controller_only() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(address(0xB0B), 10 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, address(0xB0B));
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, owner);
    }

    function test_the_floor_setting_lifts_the_controller_price() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        Settings memory s = core.settings();
        s.saleFloorBps = 20_000;
        _setSettings(s);
        // the curve starts at 150 percent, the quote is lifted to the new floor of 200 percent of the reference
        address buyer = address(0xB0B);
        uint256 ask = ctl.priceOf(sid);
        assertEq(ask, ctl.referenceOf(sid) * 20_000 / 10_000, "the quote is the floor");
        assertGe(ask, cost * 20_000 / 10_000, "and at least the cost based floor of the core");
        uint256 gross = ctl.grossPriceOf(sid);
        vm.deal(buyer, gross);
        vm.prank(buyer);
        ctl.buy{value: gross}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "sold at the floor");
    }

    function test_pool_fees_split_by_feeToRedeemBurnBps() public {
        Settings memory s0 = core.settings();
        s0.feeToRedeemBurnBps = 0;
        _setSettings(s0);
        address hook = lc.stack.feeSource;
        vm.deal(hook, 10 ether);
        uint256 pot = core.ethPot();
        vm.prank(hook);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot() - pot, 1 ether, "share 0: all to the pot");
        assertEq(core.ethRedeemBurn(), 0);
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = 4_000;
        _setSettings(s);
        pot = core.ethPot();
        vm.prank(hook);
        (ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethRedeemBurn(), 0.4 ether, "forty percent to the redeem burn reserve");
        assertEq(core.ethPot() - pot, 0.6 ether, "the rest to the pot");
        assertEq(core.ethToBuyback(), 0, "nothing to the buyback pot");
        _solvent();
    }

    function test_redeem_pays_the_caller_from_the_pot() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        Settings memory st = core.settings();
        st.callerFee = 0.0005 ether;
        st.callerMaxBaseFee = 10 gwei;
        _setSettings(st);
        _makeEligible(sid);
        vm.fee(composeBasefee);
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        vm.prank(keeper);
        core.redeemStatement(sid);
        uint256 got = keeper.balance - before_;
        assertGt(got, 0.0005 ether, "caller paid the fee and the gas");
        assertLe(got, 1_500_000 * 10 gwei + 0.0005 ether, "capped");
        assertEq(pot - core.ethPot(), got, "paid from the pot");
        _solvent();
    }
}
