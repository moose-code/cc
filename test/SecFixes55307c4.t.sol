// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// fixes of the security review of 55307c4 (docs/reviews/REVIEW-security-55307c4.md).
/// M1: the redemption check and the balance token bid read the unit from the module in the call, so a locked module needs
/// no refresh. M2: `releaseRedeemBurn` moves the reserve into
/// the coin buyback. L4: slippage is bounded by the bid margin. I3: the lens bid reads retired, mode and the pot
contract SecFixes55307c4 is Fixture {
    function _scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // ------------------------------------------------------------------ M1: the balance token bid

    /// the bid pays by the module's live unit
    function test_bidPaysTheLiveUnit() public {
        _enterPhase2();
        _setBalancePool();
        _fillBalanceBuyback();
        uint256 pot = core.balancePot();
        mod.setUnitPerPoint(UNIT / 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 paid = pot - core.balancePot();
        uint256 net = 10_000 - core.settings().balanceBidMarginBps;
        assertEq(paid, score * (UNIT / 2) * net / 10_000, "the bid pays at the live unit");
        assertLe(paid, score * (UNIT / 2), "the bid does not exceed what a redemption now returns");
    }

    /// a higher live unit raises the bid with it
    function test_bidFollowsAHigherLiveUnit() public {
        _enterPhase2();
        _setBalancePool();
        _fillBalanceBuyback();
        uint256 pot = core.balancePot();
        mod.setUnitPerPoint(UNIT * 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 paid = pot - core.balancePot();
        uint256 net = 10_000 - core.settings().balanceBidMarginBps;
        assertEq(paid, score * UNIT * 2 * net / 10_000, "the bid pays at the live unit");
    }

    /// a failing live unit read reverts the whole bid, so no stale overpay slips through
    function test_bidRevertsWhenLiveUnitReadFails() public {
        _enterPhase2();
        _fillBalanceBuyback();
        mod.setRevertUnit(true);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }

    /// a live unit read that burns its gas is cut at the read cap, so the bid reverts `BadModule` with the gas left
    /// to return the error
    function test_bidRevertsWhenLiveUnitReadBurnsGas() public {
        _enterPhase2();
        _fillBalanceBuyback();
        mod.setBurnUnitRead(true);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance{gas: 2_000_000}(ids);
    }

    /// a live unit of zero reverts the bid
    function test_bidRevertsWhenLiveUnitIsZero() public {
        _enterPhase2();
        _fillBalanceBuyback();
        mod.setUnitPerPoint(0);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }

    // ------------------------------------------------------------------ M1: the unit of a locked module

    /// after `lockBalanceModule` the unit still follows the module: a fall of the module's redeem rate lowers the
    /// minimum of the redemption with it. the module and the balance token stay fixed
    function test_lockedModuleRedeemsAtItsLiveUnit() public {
        _enterPhase2();
        vm.prank(owner);
        core.lockBalanceModule();
        mod.setUnitPerPoint(UNIT * 97 / 100);
        uint256 sid = _composeOnce().sid;
        uint256 rating = core.ratingOf(sid);
        _makeEligible(sid);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(mod));
        core.redeemStatement(sid);
        assertFalse(_isHeld(sid), "the statement redeemed");
        assertEq(xt.balanceOf(address(core)), rating * (UNIT * 97 / 100), "paid by the live unit");
    }

    /// a live unit above uint128 reverts the redemption and the bid with `BadModule`
    function test_unitAboveUint128RevertsRedemptionAndBid() public {
        _enterPhase2();
        _fillBalanceBuyback();
        mod.setUnitPerPoint(uint256(type(uint128).max) + 1);
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _makeEligible(sid);
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(sid);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }

    // ------------------------------------------------------------------ M2: release the redeem burn reserve

    function test_releaseRedeemBurnMovesExactlyAndHoldsSolvency() public {
        _fundPot(2 ether);
        uint256 reserve = core.ethRedeemBurn();
        assertGt(reserve, 0, "the reserve fills from fees at launch");
        uint256 tb = core.ethToBuyback();
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        uint256 amount = reserve / 3;
        vm.prank(owner);
        core.releaseRedeemBurn(amount);
        assertEq(core.ethRedeemBurn(), reserve - amount, "the reserve fell by the amount");
        assertEq(core.ethToBuyback(), tb + amount, "the coin buyback rose by the amount");
        assertEq(core.ethPot(), pot, "the pot is unchanged");
        assertEq(address(core).balance, bal, "no eth left the core");
        _solvent();
    }

    function test_releaseRedeemBurnCapsAtReserveAndRefusesEmpty() public {
        _fundPot(2 ether);
        uint256 reserve = core.ethRedeemBurn();
        uint256 tb = core.ethToBuyback();
        vm.prank(owner);
        core.releaseRedeemBurn(reserve + 1 ether);
        assertEq(core.ethRedeemBurn(), 0, "the whole reserve moved");
        assertEq(core.ethToBuyback(), tb + reserve, "the coin buyback got the whole reserve");
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.releaseRedeemBurn(1);
    }

    function test_releaseRedeemBurnIsOwnerOnly() public {
        _fundPot(1 ether);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.releaseRedeemBurn(1);
    }

    function test_releaseRedeemBurnWorksOnARetiredEngine() public {
        _fundPot(2 ether);
        uint256 reserve = core.ethRedeemBurn();
        assertGt(reserve, 0, "the reserve fills before the migration");
        address sink = address(new MigrationSink());
        vm.startPrank(owner);
        core.setSuccessor(sink);
        core.migrate(0);
        vm.stopPrank();
        assertTrue(core.retired(), "the core is retired");
        assertEq(core.ethRedeemBurn(), reserve, "migrate leaves the reserve");
        uint256 tb = core.ethToBuyback();
        vm.prank(owner);
        core.releaseRedeemBurn(reserve);
        assertEq(core.ethRedeemBurn(), 0, "the reserve released after the migration");
        assertEq(core.ethToBuyback(), tb + reserve, "the coin buyback got it");
        _solvent();
    }

    // ------------------------------------------------------------------ L4: slippage bounded by the margin

    function test_slippageBoundedByTheBidMargin() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 300;
        s.redeemSlippageBps = 301;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("redeemSlippageBps")));
        core.setSettings(s);
        // the edge: slippage equal to the margin is accepted
        s.redeemSlippageBps = 300;
        vm.prank(owner);
        core.setSettings(s);
        assertEq(core.settings().redeemSlippageBps, 300, "slippage at the margin is accepted");
        assertEq(core.settings().balanceBidMarginBps, 300, "the margin is stored");
    }

    // ------------------------------------------------------------------ I3: the lens bid

    function test_lensBidZeroWhileBalanceBidIsOff() public {
        _enterPhase2();
        _fillBalanceBuyback();
        uint256[] memory ids = _credits(seller, 1);
        assertGt(lens.balanceBidOf(ids[0]), 0, "the bid is live with balanceBidOn");
        _setSwitches(true, false);
        assertEq(lens.balanceBidOf(ids[0]), 0, "balanceBidOn false gives no bid");
        _setSwitches(false, false);
        assertEq(lens.balanceBidOf(ids[0]), 0, "both switches off give no bid");
    }

    /// after the module lowers its rate the quote equals the payout, and a failing live read quotes 0
    function test_lensBidFollowsTheLiveUnit() public {
        _enterPhase2();
        _setBalancePool();
        _fillBalanceBuyback();
        mod.setUnitPerPoint(UNIT / 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 quote = lens.balanceBidOf(ids[0]);
        assertGt(quote, 0, "the quote is live");
        uint256 pot = core.balancePot();
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(pot - core.balancePot(), quote, "the quote equals the payout");
        mod.setRevertUnit(true);
        assertEq(lens.balanceBidOf(ids[0]), 0, "a failing live read quotes 0");
        mod.setRevertUnit(false);
        mod.setUnitPerPoint(uint256(type(uint128).max) + 1);
        assertEq(lens.balanceBidOf(ids[0]), 0, "a unit above uint128 quotes 0");
    }

    function test_lensBidCapsAtThePot() public {
        _enterPhase2();
        xt.mint(address(core), 5);
        core.skim();
        uint256[] memory ids = _credits(seller, 1);
        assertEq(lens.balanceBidOf(ids[0]), 5, "the bid is capped at the balance token pot");
        assertEq(lens.balanceBidOf(ids[0]), core.balancePot(), "the cap is the pot");
    }

    function test_lensBidZeroWhenRetired() public {
        _enterPhase2();
        _fillBalanceBuyback();
        uint256[] memory ids = _credits(seller, 1);
        assertGt(lens.balanceBidOf(ids[0]), 0, "live before the migration");
        address sink = address(new MigrationSink());
        vm.startPrank(owner);
        core.setSuccessor(sink);
        core.migrate(0);
        vm.stopPrank();
        assertEq(lens.balanceBidOf(ids[0]), 0, "a retired engine gives no bid");
    }
}
