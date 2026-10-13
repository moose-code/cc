// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// exit module whose `exitToken()` can be changed after it is set
contract TokenSwitchModule {
    address public exitToken;
    uint256 public unitPerPoint = 1e10;

    constructor(address token) {
        exitToken = token;
    }

    function setExitToken(address token) external {
        exitToken = token;
    }
}

/// fixes of the security review of 55307c4 (docs/reviews/REVIEW-security-55307c4.md).
/// M1: the stored unit is the exit check basis, the exit token bid pays by the lower of the stored and the live unit,
/// and `refreshUnitPerPoint` re-reads the unit after `lockExitModule`. M2: `releaseRedeemBurn` moves the reserve into
/// the coin buyback. L4: slippage is bounded by the bid margin. I3: the lens bid reads retired, mode and the pot
contract SecFixes55307c4 is Fixture {
    function _scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // ------------------------------------------------------------------ M1: the exit token bid

    /// the bid pays by the module's live unit when it is below the stored unit, so a module that lowered its rate
    /// after the owner set it cannot make the bid overpay
    function test_bidPaysTheLowerOfStoredAndLiveUnit() public {
        _enterPhase2();
        _setExitPool();
        _fillExitBuyback();
        uint256 pot = core.xPot();
        mod.setUnitPerPoint(UNIT / 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 paid = pot - core.xPot();
        uint256 net = 10_000 - core.settings().exitBidMarginBps;
        assertEq(paid, score * (UNIT / 2) * net / 10_000, "the bid pays at the live unit, not the stored one");
        assertLe(paid, score * (UNIT / 2), "the bid does not exceed what a redemption now returns");
    }

    /// a higher live unit does not raise the bid above the stored unit
    function test_bidKeepsTheStoredUnitWhenLiveIsHigher() public {
        _enterPhase2();
        _setExitPool();
        _fillExitBuyback();
        uint256 pot = core.xPot();
        mod.setUnitPerPoint(UNIT * 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 paid = pot - core.xPot();
        uint256 net = 10_000 - core.settings().exitBidMarginBps;
        assertEq(paid, score * UNIT * net / 10_000, "the bid pays at the stored unit");
    }

    /// a failing live unit read reverts the whole bid, so no stale overpay slips through
    function test_bidRevertsWhenLiveUnitReadFails() public {
        _enterPhase2();
        _fillExitBuyback();
        mod.setRevertUnit(true);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForExitToken(ids);
    }

    /// a live unit read that burns its gas is cut at the read cap, so the bid reverts `BadModule` with the gas left
    /// to return the error
    function test_bidRevertsWhenLiveUnitReadBurnsGas() public {
        _enterPhase2();
        _fillExitBuyback();
        mod.setBurnUnitRead(true);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForExitToken{gas: 2_000_000}(ids);
    }

    /// a live unit of zero reverts the bid
    function test_bidRevertsWhenLiveUnitIsZero() public {
        _enterPhase2();
        _fillExitBuyback();
        mod.setUnitPerPoint(0);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForExitToken(ids);
    }

    // ------------------------------------------------------------------ M1: refresh after the lock

    /// after `lockExitModule` the owner still refreshes the stored unit from the current module, which unbricks every
    /// held statement when the module's redeem rate changed. the module and the exit token stay fixed
    function test_refreshUnbricksTheLockedModule() public {
        _enterPhase2();
        vm.prank(owner);
        core.lockExitModule();
        // the module's rate falls more than the slippage tolerance: at the stale stored unit every exit underpays
        mod.setUnitPerPoint(UNIT * 97 / 100);
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(sid);

        vm.prank(owner);
        core.refreshUnitPerPoint();
        assertEq(core.unitPerPoint(), UNIT * 97 / 100, "the stored unit is the refreshed one");
        // the module cannot be changed after the lock
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("exitModule")));
        core.setExitModule(address(mod));
        // the exit now goes through at the refreshed rate
        core.exitStatement(sid);
        assertFalse(_isHeld(sid), "the statement redeemed");
    }

    function test_refreshIsOwnerOnly() public {
        _enterPhase2();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.refreshUnitPerPoint();
    }

    function test_refreshRevertsWithoutAModule() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.refreshUnitPerPoint();
    }

    function test_refreshRejectsAZeroUnit() public {
        _enterPhase2();
        mod.setUnitPerPoint(0);
        vm.prank(owner);
        vm.expectRevert(ICore.BadModule.selector);
        core.refreshUnitPerPoint();
    }

    function test_refreshRejectsAFailingRead() public {
        _enterPhase2();
        mod.setRevertUnit(true);
        vm.prank(owner);
        vm.expectRevert(ICore.BadModule.selector);
        core.refreshUnitPerPoint();
    }

    function test_refreshRejectsAUnitAboveUint128() public {
        _enterPhase2();
        mod.setUnitPerPoint(uint256(type(uint128).max) + 1);
        vm.prank(owner);
        vm.expectRevert(ICore.BadModule.selector);
        core.refreshUnitPerPoint();
        // the edge is accepted
        mod.setUnitPerPoint(type(uint128).max);
        vm.prank(owner);
        core.refreshUnitPerPoint();
        assertEq(core.unitPerPoint(), type(uint128).max, "the largest unit is accepted");
    }

    function test_refreshLeavesModuleAndTokenUnchanged() public {
        _enterPhase2();
        address m = core.exitModule();
        address t = core.exitToken();
        mod.setUnitPerPoint(UNIT * 3);
        vm.prank(owner);
        core.refreshUnitPerPoint();
        assertEq(core.unitPerPoint(), UNIT * 3, "the unit is the refreshed one");
        assertEq(core.exitModule(), m, "the module is unchanged");
        assertEq(core.exitToken(), t, "the exit token is unchanged");
    }

    function test_refreshRevertsWhenTheModuleChangedItsExitToken() public {
        _enterPhase2();
        TokenSwitchModule sw = new TokenSwitchModule(address(xt));
        vm.prank(owner);
        core.setExitModule(address(sw));
        sw.setExitToken(address(new MockExitToken("Other", "OTH")));
        vm.prank(owner);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.refreshUnitPerPoint();
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
        s.exitBidMarginBps = 300;
        s.exitSlippageBps = 301;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("exitSlippageBps")));
        core.setSettings(s);
        // the edge: slippage equal to the margin is accepted
        s.exitSlippageBps = 300;
        vm.prank(owner);
        core.setSettings(s);
        assertEq(core.settings().exitSlippageBps, 300, "slippage at the margin is accepted");
        assertEq(core.settings().exitBidMarginBps, 300, "the margin is stored");
    }

    // ------------------------------------------------------------------ I3: the lens bid

    function test_lensBidZeroOffMode2() public {
        _enterPhase2();
        _fillExitBuyback();
        uint256[] memory ids = _credits(seller, 1);
        assertGt(lens.exitBidOf(ids[0]), 0, "the bid is live in mode 2");
        _setExitMode(1);
        assertEq(lens.exitBidOf(ids[0]), 0, "mode 1 gives no bid");
        _setExitMode(0);
        assertEq(lens.exitBidOf(ids[0]), 0, "mode 0 gives no bid");
    }

    /// after the module lowers its rate the quote equals the payout, and a failing live read quotes 0
    function test_lensBidFollowsTheLiveUnit() public {
        _enterPhase2();
        _setExitPool();
        _fillExitBuyback();
        mod.setUnitPerPoint(UNIT / 2);
        uint256[] memory ids = _credits(seller, 1);
        uint256 quote = lens.exitBidOf(ids[0]);
        assertGt(quote, 0, "the quote is live");
        uint256 pot = core.xPot();
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(pot - core.xPot(), quote, "the quote equals the payout");
        mod.setRevertUnit(true);
        assertEq(lens.exitBidOf(ids[0]), 0, "a failing live read quotes 0");
    }

    function test_lensBidCapsAtThePot() public {
        _enterPhase2();
        xt.mint(address(core), 5);
        core.skim();
        uint256[] memory ids = _credits(seller, 1);
        assertEq(lens.exitBidOf(ids[0]), 5, "the bid is capped at the exit token pot");
        assertEq(lens.exitBidOf(ids[0]), core.xPot(), "the cap is the pot");
    }

    function test_lensBidZeroWhenRetired() public {
        _enterPhase2();
        _fillExitBuyback();
        uint256[] memory ids = _credits(seller, 1);
        assertGt(lens.exitBidOf(ids[0]), 0, "live before the migration");
        address sink = address(new MigrationSink());
        vm.startPrank(owner);
        core.setSuccessor(sink);
        core.migrate(0);
        vm.stopPrank();
        assertEq(lens.exitBidOf(ids[0]), 0, "a retired engine gives no bid");
    }
}
