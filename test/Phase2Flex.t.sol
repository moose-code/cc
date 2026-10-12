// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings, Mainnet, ICreditScore, ICredits} from "../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";

/// @notice phase 2 flexibility (docs/FLOW.md section 8) on the real stack: the exit module is replaceable at once, the
/// unit is read again on every set, and the per point exit token bid and the redemption read the current unit. the only
/// doubles are the two exit stand ins
contract Phase2FlexTest is Fixture {
    using FixedPointMathLib for uint256;

    function _mod(uint256 unit) internal returns (MockExitModule) {
        return new MockExitModule(address(xt), unit);
    }

    function _replace(address m) internal {
        _setExitModule(m);
    }

    function _owner(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    /// @dev books `amount` of the exit token into the exit bid pot through the real `skim` door
    function _potX(uint256 amount) internal {
        xt.mint(address(core), amount);
        core.skim();
    }

    /// @dev the exit token the per point bid pays for credit `id` at unit `unit`
    function _bid(uint256 id, uint256 unit) internal view returns (uint256) {
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        return score * unit * (10_000 - core.settings().exitBidMarginBps) / 10_000;
    }

    /// @dev an exit lane statement: the seller sells 80 credits into the exit bid, the core composes them
    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        _potX(5e21);
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        sid = STATEMENTS.supply();
    }

    // ------------------------------------------------------------------ replace

    function test_replace_newModuleSameTokenTakesEffectAtOnce() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        address fresh = address(_mod(2 * UNIT));
        vm.expectEmit(address(core));
        emit ICore.ExitModuleSet(fresh, address(xt), 2 * UNIT);
        _replace(fresh);
        assertEq(core.exitModule(), fresh);
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), 2 * UNIT);

        // the exit goes through the new module and pays by the new unit
        _makeEligible(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 pot = core.xPot();
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), fresh, "in the new module");
        assertEq(xt.balanceOf(address(core)) - before, rating * 2 * UNIT, "paid by the new unit");
        assertEq(core.xPot() - pot, rating * 2 * UNIT, "all to the bid pot");
        _solvent();
    }

    function test_replace_pilesPotsHeldAndTargetsAreUntouched() public {
        _enterPhase2();
        _composeOnce();
        _potX(3e19);
        _fillEthPile(5);
        MockExitModule m2 = _mod(3 * UNIT);
        address t = address(0xA11CE);
        _allow(t);
        uint256 xPot = core.xPot();
        uint256 ep = core.ethPot();
        uint256 eb = core.ethToBuyback();
        uint256 reserve = core.ethRedeemBurn();
        uint256 pile = core.pileSize(Lane.Eth);
        uint256 held = core.heldStatements().length;
        _replace(address(m2));
        assertEq(core.xPot(), xPot);
        assertEq(core.ethPot(), ep);
        assertEq(core.ethToBuyback(), eb);
        assertEq(core.ethRedeemBurn(), reserve);
        assertEq(core.pileSize(Lane.Eth), pile);
        assertEq(core.heldStatements().length, held);
        assertTrue(core.allowedTarget(t), "the allowed targets are untouched");
        _solvent();
    }

    function test_replace_sameAddressUpdatesTheUnit() public {
        _enterPhase2();
        mod.setUnitPerPoint(3 * UNIT);
        // the module changed its answer, the core keeps the unit it read until the set runs
        assertEq(core.unitPerPoint(), UNIT);
        vm.expectEmit(address(core));
        emit ICore.ExitModuleSet(address(mod), address(xt), 3 * UNIT);
        _replace(address(mod));
        assertEq(core.exitModule(), address(mod));
        assertEq(core.unitPerPoint(), 3 * UNIT, "a unit change takes effect at once");
        mod.setUnitPerPoint(4 * UNIT / 10);
        _replace(address(mod));
        assertEq(core.unitPerPoint(), 4 * UNIT / 10);
    }

    function test_replace_differentExitTokenReverts() public {
        _enterPhase2();
        MockExitModule alien = new MockExitModule(address(new MockExitToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.setExitModule(address(alien));
        assertEq(core.exitModule(), address(mod));
        assertEq(core.exitToken(), address(xt));
    }

    function test_replace_firstSetTakesAnyTokenAndUnit() public {
        // before any module the token is free: the first set behaves as it always did
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), 7 * UNIT / 10);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(1);
        _replace(address(mod));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), 7 * UNIT / 10);
    }

    function test_replace_everyTimeAtOnceAndOnlyTheOwner() public {
        _enterPhase2();
        _replace(address(_mod(2 * UNIT)));
        MockExitModule m3 = _mod(5 * UNIT / 10);
        _replace(address(m3));
        assertEq(core.exitModule(), address(m3));
        assertEq(core.unitPerPoint(), 5 * UNIT / 10);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setExitModule(address(mod));
    }

    function test_replace_twoSetsInARowBothApply() public {
        _enterPhase2();
        MockExitModule a = _mod(2 * UNIT);
        MockExitModule b = _mod(4 * UNIT / 10);
        _replace(address(a));
        assertEq(core.unitPerPoint(), 2 * UNIT);
        _replace(address(b));
        assertEq(core.exitModule(), address(b));
        assertEq(core.unitPerPoint(), 4 * UNIT / 10);
        assertEq(core.exitToken(), address(xt));
    }

    function test_replace_sameValidityChecks() public {
        _enterPhase2();
        address[3] memory bad = [
            address(0x1234), // no code
            address(_mod(0)), // unit zero
            address(_mod(uint256(type(uint128).max) + 1)) // unit too wide
        ];
        MockExitModule gone = _mod(1 * UNIT);
        gone.setRevertUnit(true); // the unit read fails
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(ICore.BadModule.selector);
            core.setExitModule(bad[i]);
        }
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(gone));
        vm.stopPrank();
        assertEq(core.exitModule(), address(mod), "every refusal left the state alone");
        assertEq(core.unitPerPoint(), UNIT);
    }

    function test_replace_oldModuleIsNoLongerForbiddenAndTheNewOneIs() public {
        _enterPhase2();
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(mod));
        MockExitModule m2 = _mod(2 * UNIT);
        _replace(address(m2));
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(m2));
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(xt));
    }

    function test_replace_dormantTargetFlagIsClearedByTheSet() public {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        _replace(address(mod));
        assertFalse(core.allowedTarget(address(mod)), "cleared by the first set");
        MockExitModule m2 = _mod(2 * UNIT);
        _allow(address(m2));
        _replace(address(m2));
        assertFalse(core.allowedTarget(address(m2)), "cleared by a later set");
    }

    // ------------------------------------------------------------------ the redemption reads the current unit

    /// @dev the module stored a higher unit and pays 75 percent of it, above the old unit but below the new owed amount:
    /// the check reads the new unit and refuses when the payment is under the slippage floor
    function test_unit_underpaidChecksTheNewUnitNotTheOld() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockExitModule m2 = _mod(2 * UNIT);
        _replace(address(m2));
        _makeEligible(sid);
        // pay well under the slippage floor of the new owed amount
        m2.setPayBps(10_000 - core.settings().exitSlippageBps - 1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(sid);
        // paying the new unit in full passes
        m2.setPayBps(10_000);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
    }

    /// @dev the new unit is lower than the old one, and a payment at the new unit is enough
    function test_unit_lowerNewUnitIsEnough() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockExitModule m2 = _mod(4 * UNIT / 10);
        _replace(address(m2));
        _makeEligible(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(sid);
        assertEq(xt.balanceOf(address(core)) - before, rating * 4 * UNIT / 10, "paid by the new, lower unit");
        _solvent();
    }

    /// @dev the per point bid pays by the current unit
    function test_unit_exitBidPaysByTheNewUnit() public {
        _enterPhase2();
        _potX(1e22);
        _replace(address(_mod(4 * UNIT)));
        uint256[] memory ids = _credits(seller, 1);
        uint256 expect = _bid(ids[0], 4 * UNIT);
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(seller) - before, expect, "paid score times the new unit less the margin");
        _solvent();
    }

    // ------------------------------------------------------------------ exit mode gates

    function test_mode_bidAndComposeExitNeedModeTwo() public {
        _enterPhase2();
        _setExitMode(1);
        _potX(1e22);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.sellForExitToken(ids);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.composeExit();
    }

    function test_mode_holdStillRedeems() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _setExitMode(1);
        _makeEligible(sid);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "mode 1 redeems");
    }

    // ------------------------------------------------------------------ solvency through replacements

    /// @dev exits in both lanes and three module sets: the bid pot never exceeds the exit token the core holds
    function test_solvency_potsStayBackedThroughReplacements() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _solvent();
        uint256 lane = _exitLaneStatement();
        _solvent();
        core.exitStatement(lane);
        _solvent();

        MockExitModule m2 = _mod(3 * UNIT);
        _replace(address(m2));
        _makeEligible(sid);
        core.exitStatement(sid);
        _solvent();

        m2.setUnitPerPoint(7 * UNIT / 10);
        _replace(address(m2));
        uint256 lane2 = _exitLaneStatement();
        core.exitStatement(lane2);
        _solvent();

        MockExitModule m3 = _mod(2 * UNIT);
        _replace(address(m3));
        uint256 lane3 = _exitLaneStatement();
        core.exitStatement(lane3);
        _solvent();
        assertEq(core.exitToken(), address(xt));
        assertEq(STATEMENTS.ownerOf(lane3), address(m3));
        assertEq(STATEMENTS.ownerOf(lane2), address(m2));
        assertEq(STATEMENTS.ownerOf(lane), address(mod));
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
        assertEq(core.xPot(), xt.balanceOf(address(core)), "every unit is booked into the bid pot");
    }
}
