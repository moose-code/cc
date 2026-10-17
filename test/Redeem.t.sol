// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Sale} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, HostileModule, RepaidCaller} from "./attackers/SaleAttackers.sol";
import {ComposeCall} from "./utils/ComposeCall.sol";

/// the balance side redemption: when a statement may be redeemed, what stops it, and the payment to the caller from
/// the eth pot. real Core, Statements. the stand in module and token, and the attacker modules
abstract contract RedeemBase is Fixture {
    using stdStorage for StdStorage;

    /// the most gas of a redemption the caller payment counts (a private constant of the core, restated here)
    uint256 internal constant REDEEM_GAS = 1_500_000;
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

    /// sets the pot by slot and moves the eth with it, so no eth is left above the pots for the next book to count
    function _setPot(uint256 v) internal {
        uint256 old = core.ethPot();
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
        vm.deal(address(core), address(core).balance + v - old);
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

    /// turns the age only eligibility rule on or off (decision 155). launch is off, the reference curve rule
    function _setAgeEligibility(bool on) internal {
        vm.prank(owner);
        ctl.setAgeEligibilityOn(on);
    }

    /// the payment of `gasCounted` at `basefee` under the settings of `_payOn`
    function _want(uint256 gasCounted, uint256 basefee) internal pure returns (uint256) {
        return gasCounted * (basefee < PAY_CEILING ? basefee : PAY_CEILING) + PAY_FEE;
    }
}

contract RedeemTimingTest is RedeemBase {
    // promise: INTEGRATION NotEligible: a redemption waits for the curve floor
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
        uint256 held0 = _moduleHolding();
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(_moduleHolding() - held0, owed, "the owed amount is minted into the module");
        _solvent();
    }

    // promise: SPEC 1 a pause holds the age, so eligibility holds
    /// eligibility is the statement's age: a pause freezes the age, so a statement not yet eligible stays ineligible
    /// across the pause and becomes eligible only after the age advances again
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

    // promise: INTEGRATION NoBalanceModule, NotHeld on redeemStatement
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

    // promise: SPEC 9 the launch curve rule reaches its floor at decayHours of age: false one second before it, true at
    // it (at launch saleFloorBps is 10,000, so the curve boundary equals the age rule's)
    function test_eligibility_byAgeAtTheBoundary() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 span = uint256(ctl.decayHours()) * 1 hours;
        vm.warp(_composedAt(sid) + span - 1);
        assertFalse(ctl.atFloor(sid), "one second short of decayHours");
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
        vm.warp(_composedAt(sid) + span);
        assertTrue(ctl.atFloor(sid), "eligible at decayHours of age");
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    // promise: SPEC 9 eligibility reads no price: a failing unit read, a pool key and a rate move leave it unchanged
    /// the old rule compared the curve price with its floor and read the reference (the floor rate and the pool); the
    /// age rule reads only the start and the age, so a broken quote neither blocks nor restarts eligibility
    function test_eligibility_readsNoPrice() public {
        _enterPhase2();
        _setAgeEligibility(true);
        _setBalancePool();
        uint256 sid = _composeOnce().sid;
        vm.warp(_composedAt(sid) + uint256(ctl.decayHours()) * 1 hours);
        assertTrue(ctl.atFloor(sid));
        mod.setRevertUnit(true);
        _liftRateCap();
        uint256 doubled = core.floorRate() * 2;
        vm.prank(owner);
        core.setRate(doubled);
        assertTrue(ctl.atFloor(sid), "a failing unit read and a doubled rate leave it eligible");
        mod.setRevertUnit(false);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    // promise: SPEC 9 a start at or below 10,000 is eligible from the first second
    function test_eligibility_startAtParIsEligibleAtOnce() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        assertFalse(ctl.atFloor(sid), "the launch start of 15,000 waits for the age");
        Sale memory s = _sale();
        s.markupBps = 10_000;
        vm.prank(owner);
        ctl.setSale(s);
        assertEq(ctl.startBps(), 10_000);
        assertTrue(ctl.atFloor(sid), "a start at par is eligible at age 0");
    }

    // promise: SPEC 9 the switch selects the rule: off is the reference curve (the ask at its floor), on is age only.
    /// they differ once `saleFloorBps` is below 10,000 (the value at the switch): a start at par waits under the curve
    /// (the ask sits above a 5,000 floor) but is eligible at once under the age rule (the start is at or below 10,000)
    function test_eligibility_switchOffIsCurveOnIsAge() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        Settings memory s = core.settings();
        s.saleFloorBps = 5_000;
        _setSettings(s);
        Sale memory sale = _sale();
        sale.markupBps = 10_000;
        vm.prank(owner);
        ctl.setSale(sale);
        assertEq(ctl.startBps(), 10_000, "start at par");
        assertFalse(ctl.ageEligibilityOn(), "the launch default is the curve rule");
        assertFalse(ctl.atFloor(sid), "curve rule: a start above the 5,000 floor is not at floor at age 0");
        _setAgeEligibility(true);
        assertTrue(ctl.atFloor(sid), "age rule: a start at par is eligible at age 0");
    }

    // promise: INTEGRATION the Core reads eligibility within its gas budget
    /// `atFloor` reads the start and the statement age in cold state. the Core allows it 400,000 gas (`AT_FLOOR_GAS`).
    /// with a pool key set and the module stand in, the cold read stays under half the cap and the redemption through
    /// the Core completes
    function test_timing_atFloorColdFitsTheCoreReadBudget() public {
        _enterPhase2();
        _setAgeEligibility(true);
        _setBalancePool();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _cool();
        uint256 before = gasleft();
        bool floor = ctl.atFloor(sid);
        uint256 used = before - gasleft();
        assertTrue(floor, "eligible");
        emit log_named_uint("atFloor gas, cold, pool key set", used);
        assertLt(used, 200_000, "the cold read uses under half the Core read budget");
        _cool();
        core.redeemStatement(sid);
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held, "the redemption through the Core completed");
    }

    function _cool() internal {
        vm.cool(address(core));
        vm.cool(address(ctl));
        vm.cool(address(mod));
        vm.cool(address(PM));
    }

    // promise: INTEGRATION RedeemOff
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

    // promise: INTEGRATION NotEligible when the controller reports not at floor
    /// every redemption needs the controller's eligibility answer: a controller that answers not at floor makes
    /// statements ineligible
    function test_timing_redemptionNeedsTheController() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        ScriptedController sc = new ScriptedController(); // atFloorFlag defaults false, so atFloor returns false
        _setController(address(sc));
        vm.prank(owner);
        core.lockController();
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
    }

    // promise: INTEGRATION Underpaid
    /// a module that pays less than rating times unit less slippage is refused: nothing moves and nothing is repaid
    function test_timing_anUnderpayingModuleRevertsEverything() public {
        _phase2Hostile();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        hm.setPayBps(10_000 - core.settings().redeemSlippageBps - 1);
        uint256 pot = core.ethPot();
        uint256 heldPre = xt.balanceOf(address(hm));
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(sid);
        assertEq(core.ethPot(), pot);
        assertEq(xt.balanceOf(address(hm)), heldPre, "the module holding did not change");
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

    // promise: SPEC 1 redeem pays its caller at launch, gas up to 3 gwei plus 0.0003 eth (decision 138)
    /// at the launch settings and a base fee above 3 gwei, a module that burns past the count is paid exactly
    /// REDEEM_GAS * 3 gwei + 0.0003 eth, from the pot
    function test_pay_launchSettingsPayCappedGasPlusFee() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        (uint256 repaid, uint256 potLost) = _redeem(sid, HIGH);
        assertEq(repaid, REDEEM_GAS * 3 gwei + 0.0003 ether, "the count at its cap, the base fee at the 3 gwei ceiling");
        assertEq(potLost, repaid, "from the pot");
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the redemption went through");
    }

    // promise: SPEC 1 both caller settings at zero pay nothing
    /// with both caller settings at zero a redemption pays nothing and moves no eth, at any base fee
    function test_pay_zeroSettingsPayZero() public {
        uint256 sid = _ethStatementReady();
        Settings memory s = core.settings();
        s.callerFee = 0;
        s.callerMaxBaseFee = 0;
        _setSettings(s);
        hm.setBurn(4_000_000);
        uint256 bal = address(core).balance;
        (uint256 repaid, uint256 potLost) = _redeem(sid, HIGH);
        assertEq(repaid, 0);
        assertEq(potLost, 0);
        assertEq(address(core).balance, bal, "no eth moved");
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the redemption went through");
    }

    // promise: SPEC 1 redeemStatement counted gas is bounded by REDEEM_GAS
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

    // promise: SPEC 1 the caller payment is at most ethPot
    function test_pay_zeroPotPaysZeroAndDoesNotRevert() public {
        uint256 sid = _ethStatementReady();
        _payOn();
        _setPot(0);
        (uint256 repaid,) = _redeem(sid, HIGH);
        assertEq(repaid, 0);
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the redemption went through");
        assertEq(core.ethPot(), 0);
    }

    // promise: SPEC 1 the caller payment is bounded by the gas bound at the base fee ceiling
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

    // ------------------------------------------------------------------ reentrancy

    // promise: INTEGRATION Reentrancy on the caller payment
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

    // promise: inv 14 no call from inside a redemption works
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
            if (k == 0) data = ComposeCall.noArgs();
            else if (k == 1) data = abi.encodeCall(ICore.book, ());
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

    // promise: SPEC 1 releaseRedeemBurn moves the reserve into ethToBuyback (inv 5)
    function test_releaseRedeemBurnMovesExactlyAndHoldsSolvency() public {
        Settings memory cfg = core.settings();
        cfg.feeToRedeemBurnBps = 1_000;
        _setSettings(cfg);
        _fundPot(2 ether);
        uint256 reserve = core.ethRedeemBurn();
        assertGt(reserve, 0, "the configured fee share fills the redeem-burn pot");
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

    // promise: INTEGRATION ZeroAmount on releaseRedeemBurn
    function test_releaseRedeemBurnCapsAtReserveAndRefusesEmpty() public {
        Settings memory cfg = core.settings();
        cfg.feeToRedeemBurnBps = 1_000;
        _setSettings(cfg);
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
}
