// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, HostileModule, RepaidCaller} from "./attackers/SaleAttackers.sol";

/// the balance side redemption: when a statement may be redeemed, what stops it, and the payment to the caller from
/// the eth pot. real Core, Statements. the stand in module and token, and the attacker modules
abstract contract RedeemBase is Fixture {
    using stdStorage for StdStorage;

    /// the most gas of a redemption the caller payment counts (a private constant of the core, restated here)
    uint256 internal constant REDEEM_GAS = 1_500_000;
    uint256 internal constant NOTIONAL_COUNT = 80;
    HostileModule internal hm;

    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (, cost,) = core.statementInfo(sid);
    }

    function _composedAt(uint256 sid) internal view returns (uint64 at) {
        (,, at) = core.statementInfo(sid);
    }

    /// the balance side with a module that can burn gas and call out, same balance token as the stand in
    function _phase2Hostile() internal {
        _enterPhase2();
        hm = new HostileModule(address(xt), UNIT);
        _setBalanceModule(address(hm));
    }

    function _another() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    function _setPot(uint256 v) internal {
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
        assertEq(core.ethPot(), v);
    }

    /// redeems `sid` as the keeper at `basefee` and returns what the keeper was repaid and what the pot lost. an eth lane
    /// redemption may move part of the redeem burn reserve into the coin buyback, so the buyback pot is not asserted here
    function _redeem(uint256 sid, uint256 basefee) internal returns (uint256 repaid, uint256 potLost) {
        vm.fee(basefee);
        uint256 pot = core.ethPot();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        core.redeemStatement(sid);
        repaid = keeper.balance - bal;
        potLost = pot - core.ethPot();
    }

    /// the caller payment on: 0.0005 ether and a 10 gwei base fee ceiling
    uint256 internal constant PAY_FEE = 0.0005 ether;
    uint256 internal constant PAY_CEILING = 10 gwei;

    function _payOn() internal {
        Settings memory s = core.settings();
        s.callerFee = uint64(PAY_FEE);
        s.callerMaxBaseFee = uint48(PAY_CEILING);
        _setSettings(s);
    }

    /// the payment of `gasCounted` at `basefee` under the settings of `_payOn`
    function _want(uint256 gasCounted, uint256 basefee) internal pure returns (uint256) {
        return gasCounted * (basefee < PAY_CEILING ? basefee : PAY_CEILING) + PAY_FEE;
    }
}

contract RedeemTimingTest is RedeemBase {
    function test_timing_revertsUntilAtCostThenWorks() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        // not eligible while the asking price is above cost
        assertFalse(ctl.atFloor(sid), "fresh statement starts above cost");
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "still held after the refused try");
        _makeEligible(sid);
        assertTrue(ctl.atFloor(sid), "the price has fallen to cost");
        uint256 owed = core.ratingOf(sid) * UNIT;
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.balancePot(), owed);
        _solvent();
    }

    /// eligibility is read live from the controller price: a pause freezes the age, so a statement that was not yet at
    /// cost stays ineligible across the pause and becomes eligible only after the age advances again
    function test_timing_eligibilityFrozenDuringPause() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        // pause before the price reaches cost
        vm.prank(owner);
        core.setPaused(true);
        _warp(300 hours);
        assertFalse(ctl.atFloor(sid), "a pause holds the age, so the price stays above cost");
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
        vm.prank(owner);
        core.setPaused(false);
        _makeEligible(sid);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_timing_noModuleNotHeldAndUnknown() public {
        uint256 sid = _composeOnce().sid;
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(sid);
        _enterPhase2();
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(sid + 99);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(0);
    }

    function test_timing_offWhenRedeemOnIsFalse() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _setSwitches(false, false);
        vm.expectRevert(ICore.RedeemOff.selector);
        core.redeemStatement(sid);
        // redeemOn alone redeems
        _setSwitches(true, false);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_timing_aBuyFirstMakesTheRedemptionRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _buy(address(0xB0B), sid);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB0B));
    }

    function test_timing_aSellToSaleFirstMakesTheRedemptionRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        SellingController sc = new SellingController(core);
        _setController(address(sc));
        uint256 floor = _cost(sid) * core.settings().saleFloorBps / 10_000;
        sc.sell{value: floor}(sid, address(0xB0B));
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(sid);
    }

    /// every redemption needs the controller's eligibility answer: a controller that cannot answer makes statements
    /// ineligible
    function test_timing_redemptionNeedsTheController() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        ScriptedController sc = new ScriptedController();
        sc.setRevertPage(true); // atFloorFlag defaults false, so atFloor returns false
        _setController(address(sc));
        vm.prank(owner);
        core.lockController();
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
    }

    /// a module that pays less than rating times unit less slippage is refused: nothing moves and nothing is repaid
    function test_timing_anUnderpayingModuleRevertsEverything() public {
        _phase2Hostile();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        hm.setPayBps(10_000 - core.settings().redeemSlippageBps - 1);
        uint256 pot = core.ethPot();
        uint256 balancePotPre = core.balancePot();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(sid);
        assertEq(core.ethPot(), pot);
        assertEq(core.balancePot(), balancePotPre);
        assertEq(keeper.balance, bal);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "the statement never left");
        assertTrue(_isHeld(sid));
        hm.setPayBps(10_000);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(hm));
    }
}

contract RedeemRepayTest is RedeemBase {
    uint256 internal constant LOW = 0.2 gwei;
    uint256 internal constant HIGH = 100 gwei;

    function _ethStatementReady() internal returns (uint256 sid) {
        _phase2Hostile();
        sid = _composeOnce().sid;
        _makeEligible(sid);
    }

    /// at the launch settings a redemption pays nothing and moves no eth, at any base fee
    function test_pay_launchSettingsPayZero() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        uint256 bal = address(core).balance;
        (uint256 repaid, uint256 potLost) = _redeem(sid, HIGH);
        assertEq(repaid, 0);
        assertEq(potLost, 0);
        assertEq(address(core).balance, bal - 0, "no eth moved");
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the redemption went through");
    }

    /// the fee and the ceiling are separate: the fee alone pays the fee, the ceiling alone pays the gas
    function test_pay_feeAndCeilingAreIndependent() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        uint256 snap = vm.snapshotState();
        Settings memory s = core.settings();
        s.callerFee = uint64(PAY_FEE);
        _setSettings(s);
        (uint256 repaid, uint256 potLost) = _redeem(sid, LOW);
        assertEq(repaid, PAY_FEE, "the fee alone");
        assertEq(potLost, PAY_FEE);
        vm.revertToState(snap);
        s.callerFee = 0;
        s.callerMaxBaseFee = uint48(PAY_CEILING);
        _setSettings(s);
        (repaid, potLost) = _redeem(sid, LOW);
        assertEq(repaid, REDEEM_GAS * LOW, "the gas alone");
        assertEq(potLost, repaid);
    }

    /// eth lane, a module that burns more than the count allows: the count is capped at REDEEM_GAS, so the payment
    /// is exactly REDEEM_GAS * basefee + callerFee
    function test_pay_ethLaneGasCountIsCappedExactly() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        _payOn();
        uint256 want = _want(REDEEM_GAS, LOW);
        assertEq(want, 300_000_000_000_000 + PAY_FEE, "1.5M gas at 0.2 gwei plus the fee");
        (uint256 repaid, uint256 potLost) = _redeem(sid, LOW);
        assertEq(repaid, want);
        assertEq(potLost, want, "paid from the pot, to the wei");
        _solvent();
    }

    /// above the ceiling the gas is paid at the ceiling
    function test_pay_baseFeeAboveTheCeilingPaysAtTheCeiling() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        _payOn();
        (uint256 repaid, uint256 potLost) = _redeem(sid, HIGH);
        assertEq(repaid, REDEEM_GAS * PAY_CEILING + PAY_FEE);
        assertEq(potLost, repaid);
    }

    function test_pay_ethLanePotBindsExactly() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        _payOn();
        _setPot(1e12);
        (uint256 repaid, uint256 potLost) = _redeem(sid, HIGH);
        assertEq(repaid, 1e12, "the whole pot");
        assertEq(potLost, 1e12);
        assertEq(core.ethPot(), 0);
    }

    function test_pay_zeroPotPaysZeroAndDoesNotRevert() public {
        uint256 sid = _ethStatementReady();
        _payOn();
        _setPot(0);
        (uint256 repaid,) = _redeem(sid, HIGH);
        assertEq(repaid, 0);
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the redemption went through");
        assertEq(core.ethPot(), 0);
    }

    /// the natural regime: the counted gas is what the redemption used plus the fixed overhead, at most REDEEM_GAS. with the
    /// fee at zero the payment is counted gas times basefee, so the count can be read back
    function _natural(uint256 sid) internal {
        Settings memory s = core.settings();
        s.callerMaxBaseFee = uint48(PAY_CEILING);
        _setSettings(s);
        uint256 basefee = 1 gwei;
        vm.fee(basefee);
        uint256 bal = keeper.balance;
        uint256 g0 = gasleft();
        vm.prank(keeper);
        core.redeemStatement(sid);
        g0 -= gasleft();
        (uint256 gross,) = _lastCallGross();
        uint256 repaid = keeper.balance - bal;
        assertEq(repaid % basefee, 0);
        uint256 counted = repaid / basefee;
        assertGt(counted, 50_000, "the overhead and the work");
        assertLe(counted, REDEEM_GAS);
        assertGe(counted + 15_000, gross, "covers the gross gas of the transaction but for the part of the overhead the constant leaves out");
        assertLe(counted, gross + 20_000, "and the overhead is not oversized");
    }

    function test_pay_naturalCount() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _natural(sid);
    }

    /// never above the gas bound at the ceiling plus the fee, and never above the pot, for any basefee, with a module
    /// that burns as much as it likes
    function test_pay_neverAboveTheBoundWithAGasBurningModule() public {
        uint256[8] memory fees = [uint256(0), 1, 1e6, 1e9, 1e10, 1e11, 1e12, 1e15];
        for (uint256 i; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();
            _phase2Hostile();
            uint256 sid = _composeOnce().sid;
            _makeEligible(sid);
            _payOn();
            hm.setBurn(20_000_000);
            uint256 pot = core.ethPot();
            uint256 want = _want(REDEEM_GAS, fees[i]);
            if (want > pot) want = pot;
            (uint256 repaid, uint256 potLost) = _redeem(sid, fees[i]);
            assertEq(repaid, want, "min of the payment and the pot");
            assertLe(repaid, REDEEM_GAS * PAY_CEILING + PAY_FEE);
            assertLe(repaid, pot);
            assertEq(potLost, repaid);
            _solvent();
            vm.revertToState(snap);
        }
    }

    function test_pay_nothingIsAddedToTheBooksOnlyThePotPays() public {
        uint256 sid = _ethStatementReady();
        _payOn();
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 reserve = core.ethRedeemBurn();
        uint256 bal = address(core).balance;
        uint256 xp = core.balancePot();
        uint256 owed = core.ratingOf(sid) * UNIT;
        (uint256 repaid,) = _redeem(sid, LOW);
        assertGt(repaid, 0);
        assertEq(core.ethPot(), pot - repaid, "only the caller payment leaves the pot");
        // the reserve release moves between trackers, it does not add or remove eth
        uint256 released = reserve * core.settings().redeemBurnBps / 10_000;
        assertEq(core.ethToBuyback(), bb + released, "the buyback pot rose by the released reserve only");
        assertEq(core.ethRedeemBurn(), reserve - released, "the reserve fell by the release only");
        assertEq(address(core).balance, bal - repaid, "the balance fell by the payment only");
        assertEq(core.balancePot() - xp, owed, "the whole received amount went to the bid pot");
    }

    // ------------------------------------------------------------------ reentrancy

    /// the payment is paid after all state is final: a caller that re enters from its receive finds every door shut
    function test_reenter_theRepaidCallerFindsEveryDoorShut() public {
        _enterPhase2();
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        RepaidCaller rc = new RepaidCaller(core);
        _payOn();
        _makeEligible(a);
        vm.fee(LOW);
        uint256 pot = core.ethPot();
        uint256 bal = address(rc).balance;
        rc.redeem(a, b);
        assertEq(rc.hits(), 1, "it was repaid once");
        assertEq(rc.blocked(), 4, "all four doors refused it");
        assertEq(rc.ok(), 0);
        assertGt(address(rc).balance - bal, 0);
        assertEq(core.ethPot(), pot - rc.repaid(), "the pot paid it once");
        assertEq(STATEMENTS.ownerOf(a), address(mod));
        assertEq(STATEMENTS.ownerOf(b), address(core), "the other statement is untouched");
        _solvent();
    }

    /// a module that calls the core while the core is inside the redemption
    function test_reenter_aHostileModuleCannotUseAnyDoorMidRedeem() public {
        bytes4 guard = bytes4(0xab143c06);
        for (uint256 k; k < 5; ++k) {
            uint256 snap = vm.snapshotState();
            _phase2Hostile();
            uint256 a = _composeOnce().sid;
            uint256 b = _another();
            SellingController sc = new SellingController(core);
            sc.setAtFloor(true); // the eth lane statement is eligible under this controller
            _setController(address(sc));
            bytes memory data;
            address target = address(core);
            if (k == 0) data = abi.encodeCall(ICore.compose, ());
            else if (k == 1) data = abi.encodeCall(ICore.skim, ());
            else if (k == 2) data = abi.encodeCall(ICore.redeemStatement, (b));
            else if (k == 3) data = abi.encodeCall(ICore.buyback, ());
            else {
                target = address(sc);
                data = abi.encodeCall(SellingController.sell, (b, address(hm)));
            }
            hm.setCall(target, data);
            vm.prank(keeper);
            core.redeemStatement(a);
            assertTrue(hm.called());
            assertFalse(hm.calledOk(), "the call mid redemption failed");
            assertEq(bytes4(hm.calledOut()), guard, "with the reentrancy guard");
            assertEq(STATEMENTS.ownerOf(a), address(hm));
            assertEq(STATEMENTS.ownerOf(b), address(core));
            _solvent();
            vm.revertToState(snap);
        }
    }
}
