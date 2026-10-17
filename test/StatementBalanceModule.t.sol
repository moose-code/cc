// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBalanceModule, Mainnet} from "../src/interfaces/Interfaces.sol";

interface IOwedClaim {
    function owed(address) external view returns (uint256);
    function claim(address) external returns (uint256);
}

interface IStatementBalanceModuleErrors {
    error InvalidConfiguration();
    error OnlyCore();
    error InsufficientAvailable();
    error CoreNotRetired();
    error InvalidSuccessor();
    error RedeemedBelowRating();

    event ReserveMigrated(address indexed successor, address indexed module, uint256 amount);

    function core() external view returns (address);
    function migrateReserve() external returns (uint256 amount);
}

/// public stand in for the Statements calls the module makes: rating read and per-statement approval.
contract StatementsDouble {
    mapping(uint256 => uint256) public creditScoreOf;
    mapping(uint256 => address) public approved;

    function setScore(uint256 id, uint256 score) external {
        creditScoreOf[id] = score;
    }

    function approve(address to, uint256 id) external {
        approved[id] = to;
    }

    function clearApproval(uint256 id) external {
        delete approved[id];
    }
}

/// calls back into the module from inside the token transfer.
contract ReentrantHook {
    address public module;
    bool public called;
    uint256 public innerMigrated;
    bool public innerPayReverted;

    constructor(address module_) {
        module = module_;
    }

    function onTransfer() external {
        called = true;
        innerMigrated = IStatementBalanceModuleErrors(module).migrateReserve();
        try IBalanceModule(module).pay(address(this), 1) {} catch {
            innerPayReverted = true;
        }
    }
}

contract BalanceGateTokenDouble {
    address public statements = Mainnet.STATEMENTS;
    uint256 public SCORE_TO_TOKEN = 1e14;
    uint8 public decimals = 18;
    uint256 public constant launchRetirement = 2_386_7072 * 1e14;
    uint256 public totalRetired;
    uint64 public transfersOpenBlock;
    bool public rejectTransfer;
    uint256 public shortfall;
    address public hook;
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

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function setHook(address target) external {
        hook = target;
    }

    function quote(uint256 id) public view returns (uint256) {
        return StatementsDouble(Mainnet.STATEMENTS).creditScoreOf(id) * SCORE_TO_TOKEN;
    }

    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256 amount) {
        StatementsDouble source = StatementsDouble(Mainnet.STATEMENTS);
        require(source.approved(id) == address(this), "statement not approved");
        require(expectedAmount == quote(id), "quote changed");
        source.clearApproval(id);
        amount = expectedAmount - shortfall;
        balanceOf[msg.sender] += amount;
    }

    /// 0 normal, 1 moves half then returns false, 2 reverts, 3 moves nothing and returns no data, 4 moves all then returns false
    uint8 public mode;
    address public reenter;

    function setMode(uint8 m) external {
        mode = m;
    }

    function setReenter(address module_) external {
        reenter = module_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (rejectTransfer) return false;
        if (mode == 2) revert("transfer reverts");
        if (mode == 3) {
            assembly {
                return(0, 0)
            }
        }
        uint256 moved = mode == 1 ? amount / 2 : amount;
        balanceOf[msg.sender] -= moved;
        balanceOf[to] += moved;
        if (hook != address(0)) ReentrantHook(hook).onTransfer();
        if (reenter != address(0)) IOwedClaim(reenter).claim(to);
        return mode == 0;
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
        vm.etch(Mainnet.STATEMENTS, address(new StatementsDouble()).code);
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

    // promise: a redemption pays the statement's rating times the unit into the module, consumes the approval and
    // leaves the balance unspendable until the gates open.
    function test_redeemCreditsRatingAndConsumesApproval() public {
        StatementsDouble source = StatementsDouble(Mainnet.STATEMENTS);
        source.setScore(7, 1_324_012);
        assertEq(module.redeem(7), 1_324_012 * 1e14);
        assertEq(token.balanceOf(address(module)), 1_324_012 * 1e14);
        assertEq(source.approved(7), address(0));
        assertEq(module.available(), 0);
        _open();
        assertEq(module.available(), 1_324_012 * 1e14);
    }

    // promise: a redemption that raises the module's balance by less than rating times the unit reverts and changes nothing.
    function test_redeemRevertsBelowRating() public {
        StatementsDouble source = StatementsDouble(Mainnet.STATEMENTS);
        source.setScore(7, 1_324_012);
        token.setShortfall(1);
        vm.expectRevert(IStatementBalanceModuleErrors.RedeemedBelowRating.selector);
        module.redeem(7);
        assertEq(token.balanceOf(address(module)), 0);
        assertEq(source.approved(7), address(0));
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

    // promise: a retired total different from launchRetirement, below or above, keeps the bid closed; equal opens it.
    function test_availableClosedUnlessRetiredTotalEqualsLaunchRetirement() public {
        token.mint(address(module), 100 ether);
        uint256 launch = token.launchRetirement();
        token.setGate(launch - 1, uint64(block.number));
        assertEq(module.available(), 0);
        token.setGate(launch + 1, uint64(block.number));
        assertEq(module.available(), 0);
        token.setGate(launch, uint64(block.number));
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

    // promise: a failed token transfer is recorded as owed to the recipient and excluded from available()
    function test_failedPaymentAccruesOwed() public {
        _open();
        token.mint(address(module), 100 ether);
        token.setRejectTransfer(true);
        this.payFromCore(40 ether);
        assertEq(IOwedClaim(address(module)).owed(recipient), 40 ether);
        assertEq(module.available(), 60 ether);
        assertEq(token.balanceOf(recipient), 0);
        token.setRejectTransfer(false);
        assertEq(IOwedClaim(address(module)).claim(recipient), 40 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        assertEq(module.available(), 60 ether);
    }

    // promise: accrual equals the undelivered part for every token failure shape
    function test_accrualEqualsShortfallForEachFailureShape() public {
        _open();
        token.mint(address(module), 400 ether);
        IOwedClaim m = IOwedClaim(address(module));
        token.setMode(1); // moves half, returns false
        this.payFromCore(40 ether);
        assertEq(m.owed(recipient), 20 ether);
        assertEq(token.balanceOf(recipient), 20 ether);
        token.setMode(4); // moves all, returns false: not paid twice
        this.payFromCore(40 ether);
        assertEq(m.owed(recipient), 20 ether);
        assertEq(token.balanceOf(recipient), 60 ether);
        token.setMode(2); // reverts
        this.payFromCore(40 ether);
        assertEq(m.owed(recipient), 60 ether);
        token.setMode(3); // no return data, nothing moved
        this.payFromCore(40 ether);
        assertEq(m.owed(recipient), 100 ether);
        assertEq(token.balanceOf(recipient), 60 ether);
    }

    // promise: a token callback that calls claim during the claim transfer receives nothing more
    function test_claimReentrancyPaysOnce() public {
        _open();
        token.mint(address(module), 100 ether);
        token.setMode(2);
        this.payFromCore(40 ether);
        token.setMode(0);
        token.setReenter(address(module));
        assertEq(IOwedClaim(address(module)).claim(recipient), 40 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        assertEq(token.balanceOf(address(module)), 60 ether);
        assertEq(IOwedClaim(address(module)).owed(recipient), 0);
    }

    // promise: migration moves the unowed balance and leaves owed amounts in the retired module for claim
    function test_migrationLeavesOwedInTheModule() public {
        retired = true;
        (BalanceSuccessorDouble next, IBalanceModule target) = _migrationTarget();
        _open();
        token.mint(address(module), 100 ether);
        token.setMode(2);
        this.payFromCore(40 ether);
        token.setMode(0);
        assertEq(_migrateReserve(), 60 ether);
        assertEq(token.balanceOf(address(module)), 40 ether);
        assertEq(token.balanceOf(address(target)), 60 ether);
        assertEq(IOwedClaim(address(module)).claim(recipient), 40 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        next;
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

    // promise: a successor module bound to another token receives nothing and the reserve stays.
    function test_hostileSuccessorModuleOnOtherTokenKeepsReserve() public {
        retired = true;
        _open();
        token.mint(address(module), 100 ether);
        (BalanceSuccessorDouble next,) = _migrationTarget();
        BalanceGateTokenDouble otherToken = new BalanceGateTokenDouble();
        IBalanceModule foreign = _deploy(address(next), address(otherToken));
        next.configure(address(token), address(foreign));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        next.configure(address(otherToken), address(foreign));
        vm.expectRevert(IStatementBalanceModuleErrors.InvalidSuccessor.selector);
        _migrateReserve();
        assertEq(token.balanceOf(address(module)), 100 ether);
        assertEq(otherToken.balanceOf(address(foreign)), 0);
    }

    // promise: a bound successor cannot receive the reserve while the source Core has not retired.
    function test_boundSuccessorReceivesNothingBeforeCoreRetires() public {
        (, IBalanceModule target) = _migrationTarget();
        _open();
        token.mint(address(module), 100 ether);
        vm.prank(recipient);
        vm.expectRevert(IStatementBalanceModuleErrors.CoreNotRetired.selector);
        _migrateReserve();
        assertEq(token.balanceOf(address(module)), 100 ether);
        assertEq(token.balanceOf(address(target)), 0);
    }

    // promise: a token callback during migration cannot move more than the holding or reach Core-only payment.
    function test_reentrantTokenCallbackCannotMoveMoreThanTheHolding() public {
        retired = true;
        (, IBalanceModule target) = _migrationTarget();
        _open();
        token.mint(address(module), 100 ether);
        ReentrantHook hook = new ReentrantHook(address(module));
        token.setHook(address(hook));
        assertEq(_migrateReserve(), 100 ether);
        assertTrue(hook.called());
        assertEq(hook.innerMigrated(), 0);
        assertTrue(hook.innerPayReverted());
        assertEq(token.balanceOf(address(module)), 0);
        assertEq(token.balanceOf(address(target)), 100 ether);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
