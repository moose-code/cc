// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBalanceModule, Mainnet} from "../interfaces/Interfaces.sol";

/// the fixed AuctionLineageWithdrawals surface used by this module.
interface IStatementBalanceToken {
    function statements() external view returns (address);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function decimals() external view returns (uint8);
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function transfersOpenBlock() external view returns (uint64);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
}

interface IStatementApproval {
    function approve(address to, uint256 id) external;
}

interface IStatementBalanceCore {
    function retired() external view returns (bool);
    function successor() external view returns (address);
    function balanceToken() external view returns (address);
    function balanceModule() external view returns (address);
}

interface IStatementBalanceBinding {
    function core() external view returns (address);
    function balanceToken() external view returns (address);
}

/// surrenders the Core's statements and holds their balance tokens for the Core's balance bid.
contract StatementBalanceModule is IBalanceModule {
    address public immutable core;
    address public immutable override balanceToken;
    uint256 public constant override unitPerPoint = 1e14;

    error InvalidConfiguration();
    error OnlyCore();
    error InsufficientAvailable();
    error CoreNotRetired();
    error InvalidSuccessor();

    event ReserveMigrated(address indexed successor, address indexed module, uint256 amount);

    constructor(address core_, address balanceToken_) {
        if (core_.code.length == 0 || balanceToken_.code.length == 0) revert InvalidConfiguration();
        IStatementBalanceToken token = IStatementBalanceToken(balanceToken_);
        if (
            token.statements() != Mainnet.STATEMENTS || token.SCORE_TO_TOKEN() != unitPerPoint || token.decimals() != 18
        ) revert InvalidConfiguration();
        core = core_;
        balanceToken = balanceToken_;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    /// the Core transfers custody first. approval is limited to this statement and consumed by withdrawal.
    function redeem(uint256 statementId) external override onlyCore returns (uint256 out) {
        IStatementBalanceToken token = IStatementBalanceToken(balanceToken);
        uint256 expected = token.quote(statementId);
        IStatementApproval(Mainnet.STATEMENTS).approve(balanceToken, statementId);
        return token.withdraw(statementId, expected);
    }

    /// do not advertise a bid before ordinary token holders can transfer their balance.
    function available() public view override returns (uint256) {
        IStatementBalanceToken token = IStatementBalanceToken(balanceToken);
        if (token.totalRetired() != token.launchRetirement() || block.number < token.transfersOpenBlock()) return 0;
        return SafeTransferLib.balanceOf(balanceToken, address(this));
    }

    function pay(address to, uint256 amount) external override onlyCore {
        if (amount > available()) revert InsufficientAvailable();
        SafeTransferLib.safeTransfer(balanceToken, to, amount);
    }

    /// anyone may move the retired Core's reserve to its successor's currently bound module, including later proceeds.
    function migrateReserve() external returns (uint256 amount) {
        IStatementBalanceCore source = IStatementBalanceCore(core);
        if (!source.retired()) revert CoreNotRetired();
        address successor = source.successor();
        if (successor.code.length == 0 || successor == core) revert InvalidSuccessor();
        IStatementBalanceCore next = IStatementBalanceCore(successor);
        if (next.balanceToken() != balanceToken) revert InvalidSuccessor();
        address destination = next.balanceModule();
        if (destination.code.length == 0 || destination == address(this)) revert InvalidSuccessor();
        IStatementBalanceBinding target = IStatementBalanceBinding(destination);
        if (target.core() != successor || target.balanceToken() != balanceToken) revert InvalidSuccessor();
        amount = SafeTransferLib.balanceOf(balanceToken, address(this));
        if (amount > available()) revert InsufficientAvailable();
        if (amount != 0) SafeTransferLib.safeTransfer(balanceToken, destination, amount);
        emit ReserveMigrated(successor, destination, amount);
    }
}
