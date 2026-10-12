// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExitModule, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./MockExitToken.sol";

/// test double for the exit module. owes `rating * unitPerPoint` for a statement (rating is the statement's stored
/// rating, read from Statements) and pays `payBps` of the owed amount in the exit token to the caller, keeping the
/// statement. `payBps` 10_000 pays the owed amount exactly; below it underpays, above it overpays
contract MockExitModule is IExitModule {
    address public immutable exitToken;
    uint256 internal _unit;
    bool public revertUnit;
    /// makes unitPerPoint loop until its gas runs out
    bool public burnUnitRead;
    /// payout as bps of the owed amount. 10_000 pays exactly the owed amount
    uint256 public payBps = 10_000;
    /// gas to burn inside `exit`, and a call to make to some address while the core is inside the exit. a test or a
    /// handler sets them to see that a gas burning or calling module cannot move more than the rules allow
    uint256 public burnGas;
    address public callTarget;
    bytes public callData;
    bool public called;
    /// true if a call made from inside an exit went through, which no door of the core may allow
    bool public calledOk;

    constructor(address exitToken_, uint256 unitPerPoint_) {
        exitToken = exitToken_;
        _unit = unitPerPoint_;
    }

    /// the unit, exit token base units per stored score unit (one ten-thousandth of a point). reverts when asked to.
    function unitPerPoint() public view returns (uint256) {
        if (revertUnit) revert();
        if (burnUnitRead) while (true) {}
        return _unit;
    }

    /// the unit the module pays by, whether or not unitPerPoint is set to revert.
    function currentUnit() external view returns (uint256) {
        return _unit;
    }

    /// makes unitPerPoint revert.
    function setRevertUnit(bool on) external {
        revertUnit = on;
    }

    /// makes unitPerPoint burn all the gas it is given.
    function setBurnUnitRead(bool on) external {
        burnUnitRead = on;
    }

    /// sets the payout as bps of the owed amount. below 10_000 underpays, above overpays.
    function setPayBps(uint256 bps) external {
        payBps = bps;
    }

    function setBurn(uint256 gas_) external {
        burnGas = gas_;
    }

    function setCall(address target, bytes calldata data) external {
        callTarget = target;
        callData = data;
    }

    /// sets the unit per point the module reports.
    function setUnitPerPoint(uint256 unit) external {
        _unit = unit;
    }

    /// reads the statement rating, mints `payBps` of the owed amount (rating times the unit) to the caller and keeps
    /// the statement.
    function exit(uint256 statementId) external returns (uint256 out) {
        uint256 rating = IStatements(Mainnet.STATEMENTS).creditScoreOf(statementId);
        out = rating * _unit * payBps / 10_000;
        MockExitToken(exitToken).mint(msg.sender, out);
        if (callTarget != address(0)) {
            called = true;
            (bool ok,) = callTarget.call(callData);
            if (ok) calledOk = true;
        }
        if (burnGas != 0) {
            uint256 end = gasleft() > burnGas ? gasleft() - burnGas : 0;
            while (gasleft() > end) {}
        }
    }
}
