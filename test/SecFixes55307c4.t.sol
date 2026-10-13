// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// balance module whose `balanceToken()` can be changed after it is set
contract TokenSwitchModule {
    address public balanceToken;
    uint256 public unitPerPoint = 1e10;

    constructor(address token) {
        balanceToken = token;
    }

    function setBalanceToken(address token) external {
        balanceToken = token;
    }
}

/// fixes of the security review of 55307c4 (docs/reviews/REVIEW-security-55307c4.md).
/// M1: the stored unit is the redemption check basis, the balance token bid pays by the lower of the stored and the live unit,
/// and `refreshUnitPerPoint` re-reads the unit after `lockBalanceModule`. M2: `releaseRedeemBurn` moves the reserve into
/// the coin buyback. L4: slippage is bounded by the bid margin. I3: the lens bid reads retired, mode and the pot
contract SecFixes55307c4 is Fixture {
    function _scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // ------------------------------------------------------------------ M1: the balance token bid

    /// the bid pays by the module's live unit when it is below the stored unit, so a module that lowered its rate
    /// after the owner set it cannot make the bid overpay
    function test_bidPaysTheLowerOfStoredAndLiveUnit() public {
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
        assertEq(paid, score * (UNIT / 2) * net / 10_000, "the bid pays at the live unit, not the stored one");
        assertLe(paid, score * (UNIT / 2), "the bid does not exceed what a redemption now returns");
    }

    /// a higher live unit does not raise the bid above the stored unit
    function test_bidKeepsTheStoredUnitWhenLiveIsHigher() public {
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
        assertEq(paid, score * UNIT * net / 10_000, "the bid pays at the stored unit");
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

    // ------------------------------------------------------------------ M1: refresh after the lock

    /// after `lockBalanceModule` the owner still refreshes the stored unit from the current module, which unbricks every
    /// held statement when the module's redeem rate changed. the module and the balance token stay fixed
    function test_refreshUnbricksTheLockedModule() public {
        _enterPhase2();
        vm.prank(owner);
        core.lockBalanceModule();
        // the module's rate falls more than the slippage tolerance: at the stale stored unit every redemption underpays
        mod.setUnitPerPoint(UNIT * 97 / 100);
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(sid);

        vm.prank(owner);
        core.refreshUnitPerPoint();
        assertEq(core.unitPerPoint(), UNIT * 97 / 100, "the stored unit is the refreshed one");
        // the module cannot be changed after the lock
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(mod));
        // the redemption now goes through at the refreshed rate
        core.redeemStatement(sid);
        assertFalse(_isHeld(sid), "the statement redeemed");
    }

    function test_refreshIsOwnerOnly() public {
        _enterPhase2();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.refreshUnitPerPoint();
    }

    function test_refreshRevertsWithoutAModule() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoBalanceModule.selector);
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
        address m = core.balanceModule();
        address t = core.balanceToken();
        mod.setUnitPerPoint(UNIT * 3);
        vm.prank(owner);
        core.refreshUnitPerPoint();
        assertEq(core.unitPerPoint(), UNIT * 3, "the unit is the refreshed one");
        assertEq(core.balanceModule(), m, "the module is unchanged");
        assertEq(core.balanceToken(), t, "the balance token is unchanged");
    }

    function test_refreshRevertsWhenTheModuleChangedItsBalanceToken() public {
        _enterPhase2();
        TokenSwitchModule sw = new TokenSwitchModule(address(xt));
        vm.prank(owner);
        core.setBalanceModule(address(sw));
        sw.setBalanceToken(address(new MockBalanceToken("Other", "OTH")));
        vm.prank(owner);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
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

    function test_lensBidZeroOffMode2() public {
        _enterPhase2();
        _fillBalanceBuyback();
        uint256[] memory ids = _credits(seller, 1);
        assertGt(lens.balanceBidOf(ids[0]), 0, "the bid is live in mode 2");
        _setBalanceMode(1);
        assertEq(lens.balanceBidOf(ids[0]), 0, "mode 1 gives no bid");
        _setBalanceMode(0);
        assertEq(lens.balanceBidOf(ids[0]), 0, "mode 0 gives no bid");
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
