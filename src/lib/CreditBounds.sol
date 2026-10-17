// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Credit} from "../interfaces/Interfaces.sol";

/// the sanity bounds of the launch credit settings. internal only: the Core and the controller check them in their
/// constructors and their setters, and the deploy scripts check the config against them, so there is one definition.
/// the bounds stop typos and keep the credit start at or above its floor
library CreditBounds {
    uint256 internal constant BPS = 10_000;

    function costToPotBpsOk(uint16 v) internal pure returns (bool) {
        return v <= BPS;
    }

    function windowOk(uint32 v) internal pure returns (bool) {
        return v >= 1;
    }

    function startBpsOk(uint32 v) internal pure returns (bool) {
        return v >= BPS;
    }

    /// @notice the name of the first credit field out of bounds, or zero when every bounded field is inside its bounds.
    /// `chosenComposeOn`, `minCcToChoose`, `saleOn` and `spreadBps` take any value
    function firstViolation(Credit memory c) internal pure returns (bytes32) {
        if (!costToPotBpsOk(c.costToPotBps)) return "creditCostToPotBps";
        if (!windowOk(c.window)) return "creditWindow";
        if (!startBpsOk(c.startBps)) return "creditStartBps";
        return bytes32(0);
    }
}
