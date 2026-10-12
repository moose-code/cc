// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../src/interfaces/Interfaces.sol";

/// @notice the 26 fields of `Settings` by index (the order of the struct), their names and the documented bounds of
/// docs/FLOW.md section 2, for the settings script and the config and deploy tests. the fields bounded by another
/// field (xRateCap, xRateFloor, recoveryClimbPerMinBps) have the bounds of the other field in the callers' hands
library SettingsFields {
    uint256 internal constant N = 26;

    /// @dev field i of the settings struct, in declaration order
    function get(Settings memory s, uint256 i) internal pure returns (uint256) {
        uint256[26] memory f = [
            uint256(s.dropPerCreditBps),
            s.dropFloorBps,
            s.climbPerMinBps,
            s.ceilBps,
            s.idleLoosenBps,
            s.saleFloorBps,
            s.exitAfter,
            s.saleToBuybackBps,
            s.exitToBuybackBps,
            s.peakHalfLife,
            s.recoveryClimbPerMinBps,
            s.buybackSlice,
            s.buybackDelay,
            s.keeperFee,
            s.keeperMaxBaseFee,
            s.xRateCap,
            s.xRateFloor,
            s.xRateClimbPerHour,
            s.xRateDropPerCredit,
            s.xAuctionHalfLife,
            s.exitSliceCredits,
            s.rateCap,
            s.exitLaneToBuybackBps,
            s.feeToBuybackBps,
            s.callerFee,
            s.callerMaxBaseFee
        ];
        return f[i];
    }

    /// @dev sets field i, narrowing the value (callers stay inside the width of the field)
    function set(Settings memory s, uint256 i, uint256 v) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        if (i == 0) s.dropPerCreditBps = uint16(v);
        else if (i == 1) s.dropFloorBps = uint16(v);
        else if (i == 2) s.climbPerMinBps = uint16(v);
        else if (i == 3) s.ceilBps = uint16(v);
        else if (i == 4) s.idleLoosenBps = uint16(v);
        else if (i == 5) s.saleFloorBps = uint16(v);
        else if (i == 6) s.exitAfter = uint32(v);
        else if (i == 7) s.saleToBuybackBps = uint16(v);
        else if (i == 8) s.exitToBuybackBps = uint16(v);
        else if (i == 9) s.peakHalfLife = uint32(v);
        else if (i == 10) s.recoveryClimbPerMinBps = uint16(v);
        else if (i == 11) s.buybackSlice = uint128(v);
        else if (i == 12) s.buybackDelay = uint16(v);
        else if (i == 13) s.keeperFee = uint64(v);
        else if (i == 14) s.keeperMaxBaseFee = uint48(v);
        else if (i == 15) s.xRateCap = uint16(v);
        else if (i == 16) s.xRateFloor = uint16(v);
        else if (i == 17) s.xRateClimbPerHour = uint16(v);
        else if (i == 18) s.xRateDropPerCredit = uint16(v);
        else if (i == 19) s.xAuctionHalfLife = uint32(v);
        else if (i == 20) s.exitSliceCredits = uint16(v);
        else if (i == 21) s.rateCap = uint64(v);
        else if (i == 22) s.exitLaneToBuybackBps = uint16(v);
        else if (i == 23) s.feeToBuybackBps = uint16(v);
        else if (i == 24) s.callerFee = uint64(v);
        else s.callerMaxBaseFee = uint48(v);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the documented lower bound of every field. xRateFloor and xRateCap bound each other, and
    /// recoveryClimbPerMinBps is bounded below by climbPerMinBps, handled by the callers
    function lo() internal pure returns (uint256[26] memory) {
        return [
            uint256(1),
            5_000,
            1,
            10_000,
            1,
            1_000,
            1 hours,
            0,
            0,
            600,
            1,
            0.01 ether,
            1,
            0,
            1 gwei,
            0,
            0,
            0,
            0,
            10 minutes,
            1,
            RATE_START_MIN_WEI,
            0,
            0,
            0,
            0
        ];
    }

    function hi() internal pure returns (uint256[26] memory) {
        return [
            uint256(1_000),
            10_000,
            1_000,
            30_000,
            2_000,
            40_000,
            365 days,
            10_000,
            10_000,
            604_800,
            1_000,
            1 ether,
            7_200,
            0.005 ether,
            100 gwei,
            10_000,
            10_000,
            1_000,
            1_000,
            30 days,
            1_000,
            RATE_START_MAX_WEI,
            10_000,
            10_000,
            0.005 ether,
            100 gwei
        ];
    }

    function names() internal pure returns (bytes32[26] memory) {
        return [
            bytes32("dropPerCreditBps"),
            "dropFloorBps",
            "climbPerMinBps",
            "ceilBps",
            "idleLoosenBps",
            "saleFloorBps",
            "exitAfter",
            "saleToBuybackBps",
            "exitToBuybackBps",
            "peakHalfLife",
            "recoveryClimbPerMinBps",
            "buybackSlice",
            "buybackDelay",
            "keeperFee",
            "keeperMaxBaseFee",
            "xRateCap",
            "xRateFloor",
            "xRateClimbPerHour",
            "xRateDropPerCredit",
            "xAuctionHalfLife",
            "exitSliceCredits",
            "rateCap",
            "exitLaneToBuybackBps",
            "feeToBuybackBps",
            "callerFee",
            "callerMaxBaseFee"
        ];
    }
}
