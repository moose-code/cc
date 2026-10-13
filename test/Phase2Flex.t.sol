// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, ICreditScore, ICredits} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";

/// @notice the balance side flexibility (docs/DECISIONS.md section 8) on the real stack: the balance module is replaceable at once, the
/// unit is read again on every set, and the per point balance token bid and the redemption read the current unit. the only
/// doubles are the two balance stand ins
contract Phase2FlexTest is Fixture {
    using FixedPointMathLib for uint256;

    function _mod(uint256 unit) internal returns (MockBalanceModule) {
        return new MockBalanceModule(address(xt), unit);
    }

    function _replace(address m) internal {
        _setBalanceModule(m);
    }

    function _owner(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    /// @dev books `amount` of the balance token into the balance bid pot through the real `skim` door
    function _potX(uint256 amount) internal {
        xt.mint(address(core), amount);
        core.skim();
    }

    /// @dev the balance token the per point bid pays for credit `id` at unit `unit`
    function _bid(uint256 id, uint256 unit) internal view returns (uint256) {
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        return score * unit * (10_000 - core.settings().balanceBidMarginBps) / 10_000;
    }

    /// @dev a statement composed from credits bought through the balance bid (one pile, balance pool key must be set)
    function _balanceBidStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        _potX(5e21);
        vm.prank(seller);
        core.sellForBalance(ids);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    // ------------------------------------------------------------------ replace

    function test_replace_newModuleSameTokenTakesEffectAtOnce() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        address fresh = address(_mod(2 * UNIT));
        vm.expectEmit(address(core));
        emit ICore.BalanceModuleSet(fresh, address(xt), 2 * UNIT);
        _replace(fresh);
        assertEq(core.balanceModule(), fresh);
        assertEq(core.balanceToken(), address(xt));
        assertEq(core.unitPerPoint(), 2 * UNIT);

        // the redemption goes through the new module and pays by the new unit
        _makeEligible(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 pot = core.balancePot();
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), fresh, "in the new module");
        assertEq(xt.balanceOf(address(core)) - before, rating * 2 * UNIT, "paid by the new unit");
        assertEq(core.balancePot() - pot, rating * 2 * UNIT, "all to the bid pot");
        _solvent();
    }

    function test_replace_pilesPotsHeldAndAdaptersAreUntouched() public {
        _enterPhase2();
        _composeOnce();
        _potX(3e19);
        _fillEthPile(5);
        MockBalanceModule m2 = _mod(3 * UNIT);
        address t = address(0xA11CE);
        _approveAdapter(t);
        uint256 balancePot = core.balancePot();
        uint256 ep = core.ethPot();
        uint256 eb = core.ethToBuyback();
        uint256 reserve = core.ethRedeemBurn();
        uint256 pile = core.pileSize();
        uint256 held = core.heldStatements().length;
        _replace(address(m2));
        assertEq(core.balancePot(), balancePot);
        assertEq(core.ethPot(), ep);
        assertEq(core.ethToBuyback(), eb);
        assertEq(core.ethRedeemBurn(), reserve);
        assertEq(core.pileSize(), pile);
        assertEq(core.heldStatements().length, held);
        assertTrue(core.allowedAdapter(t), "the approved adapters are untouched");
        _solvent();
    }

    function test_replace_sameAddressUpdatesTheUnit() public {
        _enterPhase2();
        mod.setUnitPerPoint(3 * UNIT);
        // the module changed its answer, the core keeps the unit it read until the set runs
        assertEq(core.unitPerPoint(), UNIT);
        vm.expectEmit(address(core));
        emit ICore.BalanceModuleSet(address(mod), address(xt), 3 * UNIT);
        _replace(address(mod));
        assertEq(core.balanceModule(), address(mod));
        assertEq(core.unitPerPoint(), 3 * UNIT, "a unit change takes effect at once");
        mod.setUnitPerPoint(4 * UNIT / 10);
        _replace(address(mod));
        assertEq(core.unitPerPoint(), 4 * UNIT / 10);
    }

    function test_replace_differentBalanceTokenReverts() public {
        _enterPhase2();
        MockBalanceModule alien = new MockBalanceModule(address(new MockBalanceToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(alien));
        assertEq(core.balanceModule(), address(mod));
        assertEq(core.balanceToken(), address(xt));
    }

    function test_replace_firstSetTakesAnyTokenAndUnit() public {
        // before any module the token is free: the first set behaves as it always did
        xt = new MockBalanceToken("Balance Token", "XT");
        mod = new MockBalanceModule(address(xt), 7 * UNIT / 10);
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(1);
        _replace(address(mod));
        assertEq(core.balanceToken(), address(xt));
        assertEq(core.unitPerPoint(), 7 * UNIT / 10);
    }

    function test_replace_everyTimeAtOnceAndOnlyTheOwner() public {
        _enterPhase2();
        _replace(address(_mod(2 * UNIT)));
        MockBalanceModule m3 = _mod(5 * UNIT / 10);
        _replace(address(m3));
        assertEq(core.balanceModule(), address(m3));
        assertEq(core.unitPerPoint(), 5 * UNIT / 10);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(mod));
    }

    function test_replace_twoSetsInARowBothApply() public {
        _enterPhase2();
        MockBalanceModule a = _mod(2 * UNIT);
        MockBalanceModule b = _mod(4 * UNIT / 10);
        _replace(address(a));
        assertEq(core.unitPerPoint(), 2 * UNIT);
        _replace(address(b));
        assertEq(core.balanceModule(), address(b));
        assertEq(core.unitPerPoint(), 4 * UNIT / 10);
        assertEq(core.balanceToken(), address(xt));
    }

    function test_replace_sameValidityChecks() public {
        _enterPhase2();
        address[3] memory bad = [
            address(0x1234), // no code
            address(_mod(0)), // unit zero
            address(_mod(uint256(type(uint128).max) + 1)) // unit too wide
        ];
        MockBalanceModule gone = _mod(1 * UNIT);
        gone.setRevertUnit(true); // the unit read fails
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(ICore.BadModule.selector);
            core.setBalanceModule(bad[i]);
        }
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(gone));
        vm.stopPrank();
        assertEq(core.balanceModule(), address(mod), "every refusal left the state alone");
        assertEq(core.unitPerPoint(), UNIT);
    }

    function test_replace_oldModuleIsNoLongerForbiddenAndTheNewOneIs() public {
        _enterPhase2();
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(mod));
        MockBalanceModule m2 = _mod(2 * UNIT);
        _replace(address(m2));
        _approveAdapter(address(mod));
        assertTrue(core.allowedAdapter(address(mod)));
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(m2));
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(xt));
    }

    function test_replace_dormantAdapterFlagIsClearedByTheSet() public {
        xt = new MockBalanceToken("Balance Token", "XT");
        mod = new MockBalanceModule(address(xt), UNIT);
        _approveAdapter(address(mod));
        assertTrue(core.allowedAdapter(address(mod)));
        _replace(address(mod));
        assertFalse(core.allowedAdapter(address(mod)), "cleared by the first set");
        MockBalanceModule m2 = _mod(2 * UNIT);
        _approveAdapter(address(m2));
        _replace(address(m2));
        assertFalse(core.allowedAdapter(address(m2)), "cleared by a later set");
    }

    // ------------------------------------------------------------------ the redemption reads the current unit

    /// @dev the module stored a higher unit and pays 75 percent of it, above the old unit but below the new owed amount:
    /// the check reads the new unit and refuses when the payment is under the slippage floor
    function test_unit_underpaidChecksTheNewUnitNotTheOld() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockBalanceModule m2 = _mod(2 * UNIT);
        _replace(address(m2));
        _makeEligible(sid);
        // pay well under the slippage floor of the new owed amount
        m2.setPayBps(10_000 - core.settings().redeemSlippageBps - 1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(sid);
        // paying the new unit in full passes
        m2.setPayBps(10_000);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
    }

    /// @dev the new unit is lower than the old one, and a payment at the new unit is enough
    function test_unit_lowerNewUnitIsEnough() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockBalanceModule m2 = _mod(4 * UNIT / 10);
        _replace(address(m2));
        _makeEligible(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 before = xt.balanceOf(address(core));
        core.redeemStatement(sid);
        assertEq(xt.balanceOf(address(core)) - before, rating * 4 * UNIT / 10, "paid by the new, lower unit");
        _solvent();
    }

    /// @dev the per point bid pays by the current unit
    function test_unit_balanceBidPaysByTheNewUnit() public {
        _enterPhase2();
        _setBalancePool();
        _potX(1e22);
        _replace(address(_mod(4 * UNIT)));
        uint256[] memory ids = _credits(seller, 1);
        uint256 expect = _bid(ids[0], 4 * UNIT);
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(seller) - before, expect, "paid score times the new unit less the margin");
        _solvent();
    }

    // ------------------------------------------------------------------ balance mode gates

    function test_mode_bidAndComposeBalanceNeedModeTwo() public {
        _enterPhase2();
        _setBalanceMode(1);
        _potX(1e22);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.BalanceModeOff.selector);
        core.sellForBalance(ids);
    }

    function test_mode_holdStillRedeems() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _setBalanceMode(1);
        _makeEligible(sid);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "mode 1 redeems");
    }

    // ------------------------------------------------------------------ solvency through replacements

    /// @dev redeems balance bid and eth bid statements through three module sets: the bid pot never exceeds the redemption
    /// token the core holds
    function test_solvency_potsStayBackedThroughReplacements() public {
        _enterPhase2();
        _setBalancePool();
        uint256 sid = _composeOnce().sid;
        _solvent();
        uint256 lane = _balanceBidStatement();
        _makeEligible(lane);
        _solvent();
        core.redeemStatement(lane);
        _solvent();

        MockBalanceModule m2 = _mod(3 * UNIT);
        _replace(address(m2));
        _makeEligible(sid);
        core.redeemStatement(sid);
        _solvent();

        m2.setUnitPerPoint(7 * UNIT / 10);
        _replace(address(m2));
        uint256 lane2 = _balanceBidStatement();
        _makeEligible(lane2);
        core.redeemStatement(lane2);
        _solvent();

        MockBalanceModule m3 = _mod(2 * UNIT);
        _replace(address(m3));
        uint256 lane3 = _balanceBidStatement();
        _makeEligible(lane3);
        core.redeemStatement(lane3);
        _solvent();
        assertEq(core.balanceToken(), address(xt));
        assertEq(STATEMENTS.ownerOf(lane3), address(m3));
        assertEq(STATEMENTS.ownerOf(lane2), address(m2));
        assertEq(STATEMENTS.ownerOf(lane), address(mod));
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
        assertEq(core.balancePot(), xt.balanceOf(address(core)), "every unit is booked into the bid pot");
    }
}
