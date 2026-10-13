// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {RepaidCaller} from "./attackers/SaleAttackers.sol";
import {GasBurningPayee} from "./attackers/GasBurners.sol";

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

    function _setPot(uint256 v) internal {
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
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
        // a loaded router flushes into the pot during the call: the drops are meaningful only when it is empty
        r.potDrop = pot > core.ethPot() ? pot - core.ethPot() : 0;
        r.balDrop = bal > address(core).balance ? bal - address(core).balance : 0;
    }

    /// counted gas read back from a payment under `_payOn` at a base fee at or under the ceiling
    function _counted(Run memory r, uint256 basefee) internal pure returns (uint256) {
        assertEq((r.paid - FEE) % basefee, 0, "a whole number of gas at the base fee");
        return (r.paid - FEE) / basefee;
    }

    // ------------------------------------------------------------------ off at launch

    function test_launchSettingsPayZero() public {
        Settings memory s = core.settings();
        assertEq(s.callerFee, 0);
        assertEq(s.callerMaxBaseFee, 0);
        _readyEth();
        Run memory r = _run(300 gwei, 300 gwei);
        assertEq(r.paid, 0, "compose pays nothing");
        assertEq(r.potDrop, 0, "the pot is unchanged");
        assertEq(r.balDrop, 0, "no eth moved");
    }

    /// the fee alone pays the fee, the ceiling alone pays the gas
    function test_feeAndCeilingAreIndependent() public {
        _readyEth();
        uint256 snap = vm.snapshotState();
        Settings memory s = core.settings();
        s.callerFee = uint64(FEE);
        _setSettings(s);
        Run memory r = _run(5 gwei, 5 gwei);
        assertEq(r.paid, FEE, "the fee alone, no gas refund with a zero ceiling");
        vm.revertToState(snap);
        s.callerFee = 0;
        s.callerMaxBaseFee = uint48(CEILING);
        _setSettings(s);
        r = _run(5 gwei, 5 gwei);
        assertGt(r.paid, 0);
        assertEq(r.paid % 5 gwei, 0, "the gas alone");
    }

    // ------------------------------------------------------------------ paid

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

    /// above the ceiling the gas is paid at the ceiling, with the same counted gas
    function test_baseFeeAboveTheCeilingPaysAtTheCeiling() public {
        _readyEth();
        _payOn();
        uint256 snap = vm.snapshotState();
        Run memory low = _run(5 gwei, 5 gwei);
        uint256 counted = _counted(low, 5 gwei);
        vm.revertToState(snap);
        Run memory high = _run(50 gwei, 50 gwei);
        assertEq(high.paid, counted * CEILING + FEE, "the same counted gas at the ceiling");
        assertEq(high.potDrop, high.paid);
    }

    /// the priority fee is not refunded: the gas price of the transaction does not enter the payment
    function test_priorityFeeIsNotRefunded() public {
        _readyEth();
        _payOn();
        uint256 snap = vm.snapshotState();
        Run memory plain = _run(5 gwei, 5 gwei);
        vm.revertToState(snap);
        Run memory tipped = _run(5 gwei, 5 gwei + 40 gwei);
        assertEq(tipped.paid, plain.paid);
    }

    /// the gas of the fee router flush is counted: the compose that pulls a loaded router is paid for more gas
    function test_routerFlushIsCounted() public {
        _skipToSplitStart();
        vm.deal(address(feeRouter), 1 gwei);
        _flush();
        assertTrue(feeRouter.splitOn(), "the split is on");
        _readyEth();
        _payOn();
        uint256 snap = vm.snapshotState();
        Run memory empty = _run(5 gwei, 5 gwei);
        vm.revertToState(snap);
        vm.deal(address(feeRouter), 1 ether);
        Run memory loaded = _run(5 gwei, 5 gwei);
        assertGt(address(core).balance, 0);
        uint256 flushGas = _counted(loaded, 5 gwei) - _counted(empty, 5 gwei);
        emit log_named_uint("counted gas of the flush", flushGas);
        assertGt(flushGas, 20_000, "the flush is in the count");
        assertGe(_counted(loaded, 5 gwei), loaded.gross);
    }

    function test_paymentIsCappedAtThePot() public {
        _readyEth();
        _payOn();
        _setPot(1e12);
        Run memory r = _run(5 gwei, 5 gwei);
        assertEq(r.paid, 1e12, "the whole pot");
        assertEq(core.ethPot(), 0);
        assertEq(core.heldStatements().length, 1, "the compose went through");
    }

    function test_emptyPotPaysZeroAndComposes() public {
        _readyEth();
        _payOn();
        _setPot(0);
        Run memory r = _run(5 gwei, 5 gwei);
        assertEq(r.paid, 0);
        assertEq(core.heldStatements().length, 1);
    }

    /// @dev the router split on and four payees that burn all the gas they are given: the most expensive flush
    function _burningRouter() internal {
        _skipToSplitStart();
        vm.deal(address(feeRouter), 1 gwei);
        _flush();
        address[] memory who = new address[](4);
        uint32[] memory ppm = new uint32[](4);
        for (uint256 i; i < 4; ++i) {
            who[i] = address(new GasBurningPayee());
            ppm[i] = 50_000;
        }
        vm.prank(owner);
        feeRouter.setPayees(who, ppm);
    }

    function test_worstCaseCountedGasIsUnderTheBound() public {
        _burningRouter();
        _readyEth();
        _payOn();
        vm.deal(address(feeRouter), 1 ether);
        Run memory r = _run(1 gwei, 1 gwei);
        emit log_named_uint("eth lane worst case: counted", _counted(r, 1 gwei));
        emit log_named_uint("eth lane worst case: gross before refund", r.gross);
        assertLe(_counted(r, 1 gwei) * 12 / 10, COMPOSE_GAS, "the bound is at least 1.2 times the worst case");
    }

    // ------------------------------------------------------------------ bounds and reentrancy

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
