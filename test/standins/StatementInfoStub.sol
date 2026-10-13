// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings} from "../../src/interfaces/Interfaces.sol";

/// answers the reads `ControllerV1` makes of the Core (`statementInfo`, `ratingOf`, `settings`, `owner`) for any
/// statement id, with a settable cost and compose time and the lowest hard floor. the rating is zero, so the reference
/// equals the cost and the curve prices in bps of cost. lets the price fuzz set the cost and the age of a statement
/// directly
contract StatementInfoStub {
    address public owner;
    uint256 internal cost;
    uint64 internal composedAt;

    constructor(address owner_) {
        owner = owner_;
    }

    function set(uint256 cost_, uint64 composedAt_) external {
        cost = cost_;
        composedAt = composedAt_;
    }

    function statementInfo(uint256) external view returns (bool, uint256, uint64) {
        return (true, cost, composedAt);
    }

    function ratingOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function settings() external pure returns (Settings memory s) {
        s.saleFloorBps = 1_000;
    }
}
