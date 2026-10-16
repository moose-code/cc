// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI, BUYBACK_GAS} from "../interfaces/Interfaces.sol";

/// the sanity bounds of every setting (docs/SPEC.md section 3). internal only: the Core reaches it through
/// `CoreLib.setSettings`, and the deploy scripts inline it, so there is one definition. the bounds stop typos and keep
/// the hard rule that settings cannot become a withdrawal path: every caller payment and keeper reward stays capped
library SettingsBounds {
    /// @notice the name of the first field out of bounds, or zero when every field is inside its bounds
    function firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.dropPerCreditBps < 1 || s.dropPerCreditBps > 10_000) return "dropPerCreditBps";
        if (s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1) return "climbPerMinBps";
        if (s.ceilBps < 10_000) return "ceilBps";
        if (s.idleLoosenBps < 1) return "idleLoosenBps";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (uint256(s.saleToArtistBps) + s.saleToOperatorBps >= 10_000) return "saleToOperatorBps";
        if (s.peakHalfLife < 1) return "peakHalfLife";
        if (s.recoveryClimbPerMinBps < s.climbPerMinBps) return "recoveryClimbPerMinBps";
        if (s.recoveryGapBps > 10_000) return "recoveryGapBps";
        if (s.buybackSlice < 1) return "buybackSlice";
        if (s.buybackDelay < 1) return "buybackDelay";
        // A funded swap keeps at least half its slice after the largest keeper payment.
        if (s.buybackSlice < 2 * (BUYBACK_GAS * uint256(s.keeperMaxBaseFee) + s.keeperFee)) return "buybackSlice";
        if (!rateInBounds(s.rateCap)) return "rateCap";
        if (s.feeToRedeemBurnBps > 10_000) return "feeToRedeemBurnBps";
        if (s.redeemSlippageBps > 10_000) return "redeemSlippageBps";
        if (s.balanceBidMarginBps > 10_000) return "balanceBidMarginBps";
        if (s.redeemBurnBps > 10_000) return "redeemBurnBps";
        if (s.payeePpm > 1_000_000) return "payeePpm";
        if (s.refScore < 1) return "refScore";
        if (s.climbMultiplierCapBps < 10_000) return "climbMultiplierCapBps";
        if (s.spendCapBps < 1 || s.spendCapBps > 10_000) return "spendCapBps";
        if (s.bucketSeconds < 1) return "bucketSeconds";
        if (s.balanceBidCapBps < 10_000) return "balanceBidCapBps";
        if (s.idleStepSeconds < 1) return "idleStepSeconds";
        return bytes32(0);
    }

    /// @notice the bounds of the eth rate, wei per credit. `setRate` and the constructor argument `rateStart`
    function rateInBounds(uint256 r) internal pure returns (bool) {
        return r >= RATE_START_MIN_WEI && r <= RATE_START_MAX_WEI;
    }
}
