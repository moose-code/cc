// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBalanceModule, Mainnet} from "../src/interfaces/Interfaces.sol";

interface IStatementBalanceModuleErrors {
    error InvalidConfiguration();
    error OnlyCore();
    error InsufficientAvailable();
    error CoreNotRetired();
    error InvalidSuccessor();

    event ReserveMigrated(address indexed successor, address indexed module, uint256 amount);

    function core() external view returns (address);
    function migrateReserve() external returns (uint256 amount);
}

contract BalanceGateTokenDouble {
    address public statements = Mainnet.STATEMENTS;
    uint256 public SCORE_TO_TOKEN = 1e14;
    uint8 public decimals = 18;
    uint256 public constant launchRetirement = 2_386_7072 * 1e14;
    uint256 public totalRetired;
    uint64 public transfersOpenBlock;
    bool public rejectTransfer;
    mapping(address => uint256) public balanceOf;

    function configure(address source, uint256 unit, uint8 precision) external {
        statements = source;
        SCORE_TO_TOKEN = unit;
        decimals = precision;
    }

    function setGate(uint256 retired, uint64 opensAt) external {
        totalRetired = retired;
        transfersOpenBlock = opensAt;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setRejectTransfer(bool reject) external {
        rejectTransfer = reject;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return !rejectTransfer;
    }
}

contract BalanceSuccessorDouble {
    address public balanceToken;
    address public balanceModule;

    constructor(address token) {
        balanceToken = token;
    }

    function configure(address token, address module) external {
        balanceToken = token;
        balanceModule = module;
    }
}

contract StatementBalanceModuleTest is Test {
    BalanceGateTokenDouble internal token;
    IBalanceModule internal module;
    address internal recipient = address(0xBEEF);
    uint256 public recordedPayments;
    bool public retired;
    address public successor;

    function setUp() public {
        token = new BalanceGateTokenDouble();
        module = _deploy(address(this), address(token));
    }

    function _deploy(address core, address balanceToken) internal returns (IBalanceModule) {
        return IBalanceModule(
            vm.deployCode("StatementBalanceModule.sol:StatementBalanceModule", abi.encode(core, balanceToken))
        );
    }

    function _open() internal {
        token.setGate(token.launchRetirement(), uint64(block.number));
    }

    function payFromCore(uint256 amount) external {
        recordedPayments += amount;
        module.pay(recipient, amount);
    }

    function _migrationTarget() internal returns (BalanceSuccessorDouble next, IBalanceModule target) {
        next = new BalanceSuccessorDouble(address(token));
        target = _deploy(address(next), address(token));
        next.configure(address(token), address(target));
        successor = address(next);
    }

    function _migrateReserve() internal returns (uint256) {
        return IStatementBalanceModuleErrors(address(module)).migrateReserve();
    }

    // promise: the module fixes its Core, balance token and score unit at construction.
    function test_constructorPinsConfiguration() public view {
        assertEq(IStatementBalanceModuleErrors(address(module)).core(), address(this));
        assertEq(module.balanceToken(), address(token));
        assertEq(module.unitPerPoint(), 1e14);
    }

    // promise: the module cannot bind to a Core or token without contract code.
    function test_constructorRejectsMissingCode() public {
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(0), address(token));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(recipient, address(token));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(this), address(0));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(this), recipient);
    }

    // promise: only the fixed Statements source and exact four-to-eighteen decimal conversion are accepted.
    function test_constructorRejectsWrongSourceUnitOrDecimals() public {
        token.configure(recipient, 1e14, 18);
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(this), address(token));
        token.configure(Mainnet.STATEMENTS, 1e18, 18);
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(this), address(token));
        token.configure(Mainnet.STATEMENTS, 1e14, 6);
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidConfiguration.selector);
        _deploy(address(this), address(token));
    }

    // promise: only the Core may surrender a statement or pay out the module's balance.
    function test_onlyCoreMayRedeemOrPay() public {
        vm.startPrank(recipient);
        vm.expectRevert(IStatementBalanceModuleErrors.OnlyCore.selector);
        module.redeem(1);
        vm.expectRevert(IStatementBalanceModuleErrors.OnlyCore.selector);
        module.pay(recipient, 1);
        vm.stopPrank();
    }

    // promise: both retirement finalization and the inclusive opening block gate the full spendable holding.
    function test_availableRequiresBothGates() public {
        token.mint(address(module), 100 ether);
        uint64 opensAt = uint64(block.number + 10);
        token.setGate(0, opensAt);
        assertEq(module.available(), 0);
        vm.roll(opensAt);
        assertEq(module.available(), 0);
        token.setGate(token.launchRetirement() - 1, opensAt);
        assertEq(module.available(), 0);
        token.setGate(token.launchRetirement(), opensAt);
        assertEq(module.available(), 100 ether);
        vm.roll(opensAt - 1);
        assertEq(module.available(), 0);
        vm.roll(opensAt);
        assertEq(module.available(), 100 ether);
    }

    // promise: the Core can spend the available holding, and cannot overdraw it or pay before opening.
    function test_payRespectsLiveAvailable() public {
        token.mint(address(module), 100 ether);
        token.setGate(token.launchRetirement(), uint64(block.number + 1));
        vm.expectRevert(IStatementBalanceModuleErrors.InsufficientAvailable.selector);
        this.payFromCore(1);
        assertEq(recordedPayments, 0);
        assertEq(token.balanceOf(address(module)), 100 ether);
        _open();
        this.payFromCore(40 ether);
        assertEq(module.available(), 60 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        vm.expectRevert(IStatementBalanceModuleErrors.InsufficientAvailable.selector);
        this.payFromCore(60 ether + 1);
        assertEq(recordedPayments, 40 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        this.payFromCore(60 ether);
        assertEq(module.available(), 0);
        assertEq(token.balanceOf(recipient), 100 ether);
    }

    // promise: a failed token transfer rolls back both caller bookkeeping and token-side balance changes.
    function test_failedPaymentRollsBack() public {
        _open();
        token.mint(address(module), 100 ether);
        token.setRejectTransfer(true);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        this.payFromCore(40 ether);
        assertEq(recordedPayments, 0);
        assertEq(module.available(), 100 ether);
        assertEq(token.balanceOf(recipient), 0);
    }

    // promise: a live Core's reserve cannot leave through permissionless migration.
    function test_migrationRequiresRetiredCore() public {
        (, IBalanceModule target) = _migrationTarget();
        _open();
        token.mint(address(module), 100 ether);
        vm.expectRevert(IStatementBalanceModuleErrors.CoreNotRetired.selector);
        _migrateReserve();
        assertEq(module.available(), 100 ether);
        assertEq(target.available(), 0);
    }

    // promise: migration requires a distinct successor contract with the same balance token.
    function test_migrationRejectsInvalidSuccessor() public {
        retired = true;
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        successor = recipient;
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        successor = address(this);
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        (BalanceSuccessorDouble next, IBalanceModule target) = _migrationTarget();
        next.configure(recipient, address(target));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
    }

    // promise: the successor's current module must be a distinct contract bound to that Core and token.
    function test_migrationRejectsInvalidModuleBinding() public {
        retired = true;
        (BalanceSuccessorDouble next,) = _migrationTarget();
        next.configure(address(token), address(0));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        next.configure(address(token), recipient);
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        next.configure(address(token), address(module));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        IBalanceModule wrongCore = _deploy(address(this), address(token));
        next.configure(address(token), address(wrongCore));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        BalanceGateTokenDouble otherToken = new BalanceGateTokenDouble();
        IBalanceModule wrongToken = _deploy(address(next), address(otherToken));
        next.configure(address(token), address(wrongToken));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
    }

    // promise: anyone can migrate the exact reserve to the current bound module, repeatedly for later proceeds or empty holdings.
    function test_migrationTransfersExactHoldingAndCanRepeat() public {
        retired = true;
        (BalanceSuccessorDouble next, IBalanceModule target) = _migrationTarget();
        _open();
        token.mint(address(module), 100 ether);
        vm.expectEmit(address(module));
        emit IStatementBalanceModuleErrors.ReserveMigrated(address(next), address(target), 100 ether);
        vm.prank(recipient);
        assertEq(_migrateReserve(), 100 ether);
        assertEq(module.available(), 0);
        assertEq(target.available(), 100 ether);
        IBalanceModule latest = _deploy(address(next), address(token));
        next.configure(address(token), address(latest));
        token.mint(address(module), 15 ether);
        assertEq(_migrateReserve(), 15 ether);
        assertEq(module.available(), 0);
        assertEq(target.available(), 100 ether);
        assertEq(latest.available(), 15 ether);
        assertEq(_migrateReserve(), 0);
        assertEq(latest.available(), 15 ether);
    }

    // promise: a locked nonempty reserve cannot report migration success or move any token balances.
    function test_migrationGateFailurePreservesReserve() public {
        retired = true;
        (, IBalanceModule target) = _migrationTarget();
        token.mint(address(module), 100 ether);
        token.setGate(0, uint64(block.number));
        vm.expectRevert(IStatementBalanceModuleErrors.InsufficientAvailable.selector);
        _migrateReserve();
        token.setGate(token.launchRetirement(), uint64(block.number + 1));
        vm.expectRevert(IStatementBalanceModuleErrors.InsufficientAvailable.selector);
        _migrateReserve();
        assertEq(token.balanceOf(address(module)), 100 ether);
        assertEq(token.balanceOf(address(target)), 0);
        vm.roll(block.number + 1);
        assertEq(_migrateReserve(), 100 ether);
        assertEq(target.available(), 100 ether);
    }
}
