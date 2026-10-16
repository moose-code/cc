// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {RepaidCaller} from "./attackers/SaleAttackers.sol";

/// the caller payment of `compose`: counted gas at the capped base fee plus `callerFee`, from `ethPot`,
/// at most the pot. real Core, real Statements, the stand in balance module and token. `redeemStatement` shares the helper
/// and the settings, its cases are in test/Redeem.t.sol
contract CallerPayTest is Fixture {
    using stdStorage for StdStorage;

    /// the private constants of the Core, restated
    uint256 internal constant COMPOSE_GAS = 13_700_000;

    uint256 internal constant FEE = 0.0005 ether;
    uint256 internal constant CEILING = 10 gwei;

    struct Run {
        uint256 paid;
        uint256 potDrop;
        uint256 balDrop;
        uint256 gasUsed;
        /// gas of the call as a transaction before the refund, intrinsic cost included
        uint256 gross;
        /// the refund the transaction earned
        uint256 refund;
    }

    function _payOn() internal {
        Settings memory s = core.settings();
        s.callerFee = uint64(FEE);
        s.callerMaxBaseFee = uint48(CEILING);
        _setSettings(s);
    }

    /// sets the pot by slot and moves the eth with it, so no eth is left above the pots for the next book to count
    function _setPot(uint256 v) internal {
        uint256 old = core.ethPot();
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
        vm.deal(address(core), address(core).balance + v - old);
        assertEq(core.ethPot(), v);
    }

    /// a full eth page and a pot that carries the payment
    function _readyEth() internal {
        _fillEthPile(80);
        _fundPot(1 ether);
    }

    function _run(uint256 basefee, uint256 gasPrice) internal returns (Run memory r) {
        vm.fee(basefee);
        vm.txGasPrice(gasPrice);
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        uint256 kb = keeper.balance;
        vm.prank(keeper);
        uint256 g0 = gasleft();
        core.compose();
        r.gasUsed = g0 - gasleft();
        (r.gross, r.refund) = _lastCallGross();
        r.paid = keeper.balance - kb;
        // unbooked income is booked into the pot during the call: the drops are meaningful only when there is none
        r.potDrop = pot > core.ethPot() ? pot - core.ethPot() : 0;
        r.balDrop = bal > address(core).balance ? bal - address(core).balance : 0;
    }

    /// counted gas read back from a payment under `_payOn` at a base fee at or under the ceiling
    function _counted(Run memory r, uint256 basefee) internal pure returns (uint256) {
        assertEq((r.paid - FEE) % basefee, 0, "a whole number of gas at the base fee");
        return (r.paid - FEE) / basefee;
    }

    // ------------------------------------------------------------------ launch values and off

    // promise: SPEC 1 compose pays its caller at launch, gas up to 3 gwei plus 0.0003 eth (decision 134)
    function test_launchSettingsPayCappedGasPlusFee() public {
        Settings memory s = core.settings();
        assertEq(s.callerFee, 0.0003 ether);
        assertEq(s.callerMaxBaseFee, 3 gwei);
        _readyEth();
        Run memory r = _run(300 gwei, 300 gwei);
        assertGt(r.paid, 0.0003 ether, "the fee and the gas");
        assertEq((r.paid - 0.0003 ether) % 3 gwei, 0, "the gas is paid at the 3 gwei ceiling");
        uint256 counted = (r.paid - 0.0003 ether) / 3 gwei;
        assertGe(counted, r.gross, "covers the gross gas of the transaction");
        assertLt(counted, COMPOSE_GAS, "under the bound");
        assertEq(r.potDrop, r.paid, "debited from the pot");
        assertEq(r.balDrop, r.paid, "and nothing else left the core");
    }

    // promise: SPEC 1 both caller settings at zero pay nothing
    function test_zeroSettingsPayNothing() public {
        Settings memory s = core.settings();
        s.callerFee = 0;
        s.callerMaxBaseFee = 0;
        _setSettings(s);
        _readyEth();
        Run memory r = _run(300 gwei, 300 gwei);
        assertEq(r.paid, 0, "compose pays nothing");
        assertEq(r.potDrop, 0, "the pot is unchanged");
        assertEq(r.balDrop, 0, "no eth moved");
    }

    // ------------------------------------------------------------------ paid

    // promise: SPEC 1 compose pays min(counted gas, bound) times min(basefee, ceiling) plus callerFee
    function test_composePaysCountedGasAtTheBaseFeePlusTheFee() public {
        _readyEth();
        _payOn();
        Run memory r = _run(5 gwei, 5 gwei);
        uint256 counted = _counted(r, 5 gwei);
        emit log_named_uint("gas of the compose call (net of refund)", r.gasUsed);
        emit log_named_uint("gas of the compose transaction before refund", r.gross);
        emit log_named_uint("refund", r.refund);
        emit log_named_uint("counted gas", counted);
        assertEq(r.paid, counted * 5 gwei + FEE);
        assertEq(r.potDrop, r.paid, "debited from the pot");
        assertEq(r.balDrop, r.paid, "and nothing else left the core");
        // counted is the metered gas from the first line of the body plus the overhead that stands for the dispatch, the
        // transaction base cost and the work after the payment. it covers the gross gas of the transaction and
        // exceeds it by a margin
        assertGe(counted, r.gross, "covers the gross gas of the transaction");
        assertLe(counted, r.gross + 20_000, "the overhead is not oversized");
        assertLt(counted, COMPOSE_GAS, "under the bound");
        _solvent();
    }

    // promise: SPEC 1 the counted gas includes the book
    /// the gas of the book is counted: the compose that books unbooked income is paid for more gas
    function test_bookIsCounted() public {
        _skipToPayeeStart();
        _buyCoin(funder, 5 ether);
        assertTrue(core.payeeOn(), "the payee share is on");
        _readyEth();
        _payOn();
        uint256 snap = vm.snapshotState();
        Run memory empty = _run(5 gwei, 5 gwei);
        vm.revertToState(snap);
        vm.deal(address(core), address(core).balance + 1 ether);
        Run memory loaded = _run(5 gwei, 5 gwei);
        uint256 bookGas = _counted(loaded, 5 gwei) - _counted(empty, 5 gwei);
        emit log_named_uint("counted gas of the book", bookGas);
        assertGt(bookGas, 10_000, "the book is in the count");
        assertGe(_counted(loaded, 5 gwei), loaded.gross);
    }

    // promise: SPEC 1 the caller payment is at most ethPot
    function test_paymentIsCappedAtThePot() public {
        _readyEth();
        _payOn();
        _setPot(1e12);
        Run memory r = _run(5 gwei, 5 gwei);
        assertEq(r.paid, 1e12, "the whole pot");
        assertEq(core.ethPot(), 0);
        assertEq(core.heldStatements().length, 1, "the compose went through");
    }

    // promise: SPEC 1 the compose gas bound is at least 1.2 times the largest counted compose
    function test_worstCaseCountedGasIsUnderTheBound() public {
        _skipToPayeeStart();
        _buyCoin(funder, 5 ether);
        _readyEth();
        _payOn();
        vm.deal(address(core), address(core).balance + 1 ether);
        Run memory r = _run(1 gwei, 1 gwei);
        emit log_named_uint("eth lane worst case: counted", _counted(r, 1 gwei));
        emit log_named_uint("eth lane worst case: gross before refund", r.gross);
        assertLe(_counted(r, 1 gwei) * 12 / 10, COMPOSE_GAS, "the bound is at least 1.2 times the worst case");
    }

    // ------------------------------------------------------------------ bounds and reentrancy

    // promise: INTEGRATION BadSetting on callerFee and callerMaxBaseFee
    function test_callerPaymentBounds() public {
        Settings memory s = core.settings();
        s.callerFee = 0.005 ether;
        s.callerMaxBaseFee = 100 gwei;
        _setSettings(s);
        s.callerFee = 0.005 ether + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("callerFee")));
        core.setSettings(s);
        s.callerFee = 0;
        s.callerMaxBaseFee = 100 gwei + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("callerMaxBaseFee")));
        core.setSettings(s);
    }

    // promise: INTEGRATION Reentrancy on the caller payment
    /// the payment is the last action: a caller that re enters from its receive finds every door shut, and it is
    /// paid once
    function test_paidCallerFindsEveryDoorShut() public {
        _readyEth();
        _payOn();
        RepaidCaller rc = new RepaidCaller(core);
        vm.fee(5 gwei);
        uint256 pot = core.ethPot();
        rc.compose(0);
        assertEq(rc.hits(), 1, "paid once");
        assertEq(rc.blocked(), 4, "all four doors refused it");
        assertEq(rc.ok(), 0);
        assertEq(core.ethPot(), pot - rc.repaid(), "the pot paid it once");
        assertEq(core.heldStatements().length, 1);
        _solvent();
    }
}
