// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../src/interfaces/Interfaces.sol";

/// @notice the 24 fields of `Settings` by index (the order of the struct), their names and the documented bounds of
/// docs/DECISIONS.md section 2, for the settings script and the config and deploy tests. the fields bounded by another
/// field (recoveryClimbPerMinBps by climbPerMinBps, feeToRedeemBurnBps by the sum with feeToBuybackBps) have those
/// bounds in the callers' hands
library SettingsFields {
    uint256 internal constant N = 24;

    /// @dev field i of the settings struct, in declaration order
    function get(Settings memory s, uint256 i) internal pure returns (uint256) {
        uint256[24] memory f = [
            uint256(s.dropPerCreditBps),
            s.dropFloorBps,
            s.climbPerMinBps,
            s.ceilBps,
            s.idleLoosenBps,
            s.saleFloorBps,
            s.saleToBuybackBps,
            s.recoveryClimbPerMinBps,
            s.recoveryGapBps,
            s.peakHalfLife,
            s.buybackDelay,
            s.balanceMode,
            s.redeemSlippageBps,
            s.balanceBidMarginBps,
            s.redeemBurnBps,
            s.buybackSlice,
            s.keeperFee,
            s.keeperMaxBaseFee,
            s.rateCap,
            s.callerFee,
            s.callerMaxBaseFee,
            s.feeToBuybackBps,
            s.feeToRedeemBurnBps,
            s.payeePpm
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
        else if (i == 6) s.saleToBuybackBps = uint16(v);
        else if (i == 7) s.recoveryClimbPerMinBps = uint16(v);
        else if (i == 8) s.recoveryGapBps = uint16(v);
        else if (i == 9) s.peakHalfLife = uint32(v);
        else if (i == 10) s.buybackDelay = uint16(v);
        else if (i == 11) s.balanceMode = uint8(v);
        else if (i == 12) s.redeemSlippageBps = uint16(v);
        else if (i == 13) s.balanceBidMarginBps = uint16(v);
        else if (i == 14) s.redeemBurnBps = uint16(v);
        else if (i == 15) s.buybackSlice = uint128(v);
        else if (i == 16) s.keeperFee = uint64(v);
        else if (i == 17) s.keeperMaxBaseFee = uint48(v);
        else if (i == 18) s.rateCap = uint64(v);
        else if (i == 19) s.callerFee = uint64(v);
        else if (i == 20) s.callerMaxBaseFee = uint48(v);
        else if (i == 21) s.feeToBuybackBps = uint16(v);
        else if (i == 22) s.feeToRedeemBurnBps = uint16(v);
        else s.payeePpm = uint24(v);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the documented lower bound of every field. recoveryClimbPerMinBps is bounded below by climbPerMinBps and
    /// feeToRedeemBurnBps by the sum with feeToBuybackBps, handled by the callers
    function lo() internal pure returns (uint256[24] memory) {
        return [
            uint256(1),
            5_000,
            1,
            10_000,
            1,
            1_000,
            0,
            1,
            0,
            600,
            1,
            0,
            0,
            0,
            0,
            0.01 ether,
            0,
            1 gwei,
            RATE_START_MIN_WEI,
            0,
            0,
            0,
            0,
            0
        ];
    }

    function hi() internal pure returns (uint256[24] memory) {
        return [
            uint256(1_000),
            10_000,
            1_000,
            30_000,
            2_000,
            40_000,
            10_000,
            1_000,
            5_000,
            604_800,
            7_200,
            2,
            1_000,
            9_000,
            10_000,
            1 ether,
            0.005 ether,
            100 gwei,
            RATE_START_MAX_WEI,
            0.005 ether,
            100 gwei,
            10_000,
            10_000,
            200_000
        ];
    }

    function names() internal pure returns (bytes32[24] memory) {
        return [
            bytes32("dropPerCreditBps"),
            "dropFloorBps",
            "climbPerMinBps",
            "ceilBps",
            "idleLoosenBps",
            "saleFloorBps",
            "saleToBuybackBps",
            "recoveryClimbPerMinBps",
            "recoveryGapBps",
            "peakHalfLife",
            "buybackDelay",
            "balanceMode",
            "redeemSlippageBps",
            "balanceBidMarginBps",
            "redeemBurnBps",
            "buybackSlice",
            "keeperFee",
            "keeperMaxBaseFee",
            "rateCap",
            "callerFee",
            "callerMaxBaseFee",
            "feeToBuybackBps",
            "feeToRedeemBurnBps",
            "payeePpm"
        ];
    }
}
