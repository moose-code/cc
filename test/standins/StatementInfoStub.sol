// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings} from "../../src/interfaces/Interfaces.sol";

/// answers the reads `ControllerV1` makes of the Core (`statementInfo`, `statementAge`, `ratingOf`, `floorRate`, `settings`, `owner`)
/// for any statement id, with a settable cost, compose time and `saleFloorBps` (1_000 until set). the rating is zero, so the
/// rate term of the reference is zero and the reference equals the cost and the curve prices in bps of cost. lets the
/// price fuzz set the cost and the age of a statement directly
contract StatementInfoStub {
    address public owner;
    uint256 internal cost;
    uint64 internal composedAt;
    uint16 internal saleFloorBps = 1_000;

    constructor(address owner_) {
        owner = owner_;
    }

    function set(uint256 cost_, uint64 composedAt_) external {
        cost = cost_;
        composedAt = composedAt_;
    }

    function setSaleFloorBps(uint16 bps) external {
        saleFloorBps = bps;
    }

    function statementInfo(uint256) external view returns (bool, uint256, uint64) {
        return (true, cost, composedAt);
    }

    /// the wall time since the compose: the stand-in has no pause
    function statementAge(uint256) external view returns (uint256) {
        return block.timestamp - composedAt;
    }

    function ratingOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function floorRate() external pure returns (uint256) {
        return 0;
    }

    function settings() external view returns (Settings memory s) {
        s.saleFloorBps = saleFloorBps;
    }
}
