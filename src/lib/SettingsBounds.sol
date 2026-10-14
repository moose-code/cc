// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI, BUYBACK_GAS} from "../interfaces/Interfaces.sol";

/// the sanity bounds of every setting (docs/SPEC.md section 3). internal only: the Core reaches it through the linked
/// `CoreLib.validate`, and the deploy scripts inline it, so there is one definition. the bounds stop typos and keep
/// the hard rule that settings cannot become a withdrawal path: every caller payment and keeper reward stays capped
library SettingsBounds {
    /// @notice the name of the first field out of bounds, or zero when every field is inside its bounds
    function firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.dropPerCreditBps < 1 || s.dropPerCreditBps > 1_000) return "dropPerCreditBps";
        if (s.dropFloorBps < 5_000 || s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1 || s.climbPerMinBps > 1_000) return "climbPerMinBps";
        if (s.ceilBps < 10_000 || s.ceilBps > 30_000) return "ceilBps";
        if (s.idleLoosenBps < 1 || s.idleLoosenBps > 2_000) return "idleLoosenBps";
        if (s.saleFloorBps < 1_000 || s.saleFloorBps > 40_000) return "saleFloorBps";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (s.peakHalfLife < 600 || s.peakHalfLife > 604_800) return "peakHalfLife";
        if (s.recoveryClimbPerMinBps < s.climbPerMinBps || s.recoveryClimbPerMinBps > 1_000) {
            return "recoveryClimbPerMinBps";
        }
        if (s.recoveryGapBps > 5_000) return "recoveryGapBps";
        if (s.buybackSlice < 0.01 ether || s.buybackSlice > 1 ether) return "buybackSlice";
        if (s.buybackDelay < 1 || s.buybackDelay > 7_200) return "buybackDelay";
        if (s.keeperFee > 0.005 ether) return "keeperFee";
        if (s.keeperMaxBaseFee < 1 gwei || s.keeperMaxBaseFee > 100 gwei) return "keeperMaxBaseFee";
        // the largest buyback payment is at most half the slice, so the swap budget is never empty
        if (s.buybackSlice < 2 * (BUYBACK_GAS * s.keeperMaxBaseFee + s.keeperFee)) return "buybackSlice";
        if (!rateInBounds(s.rateCap)) return "rateCap";
        if (s.feeToRedeemBurnBps > 10_000) return "feeToRedeemBurnBps";
        if (s.callerFee > 0.005 ether) return "callerFee";
        if (s.callerMaxBaseFee > 100 gwei) return "callerMaxBaseFee";
        if (s.redeemSlippageBps > 1_000) return "redeemSlippageBps";
        if (s.balanceBidMarginBps > 9_000) return "balanceBidMarginBps";
        // the balance cycle (bid then redeem) cannot lose more than its margin: slippage at most the bid margin
        if (s.redeemSlippageBps > s.balanceBidMarginBps) return "redeemSlippageBps";
        if (s.redeemBurnBps > 10_000) return "redeemBurnBps";
        if (s.payeePpm > 200_000) return "payeePpm";
        if (s.refScore == 0 || s.refScore > 8_000_000) return "refScore";
        return bytes32(0);
    }

    /// @notice the bounds of the eth rate, wei per credit. `setRate` and the constructor argument `rateStart`
    function rateInBounds(uint256 r) internal pure returns (bool) {
        return r >= RATE_START_MIN_WEI && r <= RATE_START_MAX_WEI;
    }
}
