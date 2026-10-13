// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Credit} from "../interfaces/Interfaces.sol";

/// the sanity bounds of the launch credit settings. internal only: the Core and the controller check them in their
/// constructors and their setters, and the deploy scripts check the config against them, so there is one definition.
/// the bounds stop typos and keep the sale prices above the credit cost
library CreditBounds {
    uint256 internal constant BPS = 10_000;
    /// the largest per-credit score, in ten-thousandths of a point (800 points), the ceiling of the `refScore` the
    /// statement reference divides the rating by
    uint32 internal constant MAX_REF_SCORE = 8_000_000;

    function costToPotBpsOk(uint16 v) internal pure returns (bool) {
        return v <= BPS;
    }

    function windowOk(uint32 v) internal pure returns (bool) {
        return v >= 1 minutes && v <= 30 days;
    }

    function floorBpsOk(uint16 v) internal pure returns (bool) {
        return v >= BPS && v <= 40_000;
    }

    function startBpsOk(uint32 v) internal pure returns (bool) {
        return v >= BPS && v <= 200_000;
    }

    function refScoreOk(uint32 v) internal pure returns (bool) {
        return v != 0 && v <= MAX_REF_SCORE;
    }

    /// @notice the name of the first credit field out of bounds, or zero when every bounded field is inside its bounds.
    /// `chosenComposeOn`, `minCcToChoose` and `saleOn` take any value
    function firstViolation(Credit memory c) internal pure returns (bytes32) {
        if (!costToPotBpsOk(c.costToPotBps)) return "creditCostToPotBps";
        if (!windowOk(c.window)) return "creditWindow";
        if (!floorBpsOk(c.floorBps)) return "creditFloorBps";
        if (!startBpsOk(c.startBps)) return "creditStartBps";
        if (!refScoreOk(c.refScore)) return "refScore";
        return bytes32(0);
    }
}
