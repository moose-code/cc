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

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IStatementSource {
    function approve(address to, uint256 id) external;
    function creditScoreOf(uint256 id) external view returns (uint256);
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
    error RedeemedBelowRating();

    /// gas kept back from a payment transfer so an unpaid amount can still be recorded: two storage writes and an event.
    uint256 internal constant ACCRUE_RESERVE = 60_000;

    /// balance token owed to an address whose transfer from `pay` did not complete. excluded from `available()`.
    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    event ReserveMigrated(address indexed successor, address indexed module, uint256 amount);
    event PaymentAccrued(address indexed to, uint256 amount);
    event OwedClaimed(address indexed to, uint256 amount);

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

    /// the Core transfers custody first. approval is limited to this statement and consumed by withdrawal. the module's
    /// balance must rise by at least the statement's rating times `unitPerPoint`.
    function redeem(uint256 statementId) external override onlyCore returns (uint256 out) {
        IStatementBalanceToken token = IStatementBalanceToken(balanceToken);
        IStatementSource statements = IStatementSource(Mainnet.STATEMENTS);
        uint256 required = statements.creditScoreOf(statementId) * unitPerPoint;
        uint256 expected = token.quote(statementId);
        statements.approve(balanceToken, statementId);
        uint256 before = SafeTransferLib.balanceOf(balanceToken, address(this));
        token.withdraw(statementId, expected);
        out = SafeTransferLib.balanceOf(balanceToken, address(this)) - before;
        if (out < required) revert RedeemedBelowRating();
    }

    /// returns 0 until upstream retirement is complete and the opening block is reached, then the module's token
    /// balance less `totalOwed`. `totalRetired` is 0 or `launchRetirement`: `retireLaunchSupply` assigns it once, behind a
    /// `totalRetired != 0` revert.
    function available() public view override returns (uint256) {
        IStatementBalanceToken token = IStatementBalanceToken(balanceToken);
        if (token.totalRetired() != token.launchRetirement() || block.number < token.transfersOpenBlock()) return 0;
        return _unowedBalance();
    }

    function _unowedBalance() private view returns (uint256) {
        uint256 bal = SafeTransferLib.balanceOf(balanceToken, address(this));
        uint256 debt = totalOwed;
        return bal > debt ? bal - debt : 0;
    }

    /// transfers `amount` with all gas except `ACCRUE_RESERVE`, then records the shortfall in the module's balance
    /// (`amount` less the balance decrease) in `owed[to]` for `claim`. the token's return value is not read: a transfer
    /// that reverts, runs out of gas, returns false, returns no data or moves less than `amount` accrues exactly the
    /// undelivered part. the token's transfer callbacks can exceed the gas the Core forwards for the artist royalty. the
    /// Core checks the seller's balance after paying the seller and reverts if it did not rise.
    function pay(address to, uint256 amount) external override onlyCore {
        if (amount > available()) revert InsufficientAvailable();
        uint256 before = SafeTransferLib.balanceOf(balanceToken, address(this));
        uint256 g = gasleft();
        if (g > ACCRUE_RESERVE) {
            (bool sent,) =
                balanceToken.call{gas: g - ACCRUE_RESERVE}(abi.encodeCall(IERC20Transfer.transfer, (to, amount)));
            sent;
        }
        uint256 afterBal = SafeTransferLib.balanceOf(balanceToken, address(this));
        uint256 delivered = before > afterBal ? before - afterBal : 0;
        if (delivered < amount) {
            uint256 short = amount - delivered;
            owed[to] += short;
            totalOwed += short;
            emit PaymentAccrued(to, short);
        }
    }

    /// pays `owed[to]` to `to` with all gas. anyone may call.
    function claim(address to) external returns (uint256 amount) {
        amount = owed[to];
        owed[to] = 0;
        totalOwed -= amount;
        if (amount != 0) {
            SafeTransferLib.safeTransfer(balanceToken, to, amount);
            emit OwedClaimed(to, amount);
        }
    }

    /// anyone may move the retired Core's reserve to its successor's currently bound module, including later proceeds.
    /// the moved amount excludes `totalOwed`, which stays in this module for `claim`.
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
        amount = _unowedBalance();
        if (amount > available()) revert InsufficientAvailable();
        if (amount != 0) SafeTransferLib.safeTransfer(balanceToken, destination, amount);
        emit ReserveMigrated(successor, destination, amount);
    }
}
