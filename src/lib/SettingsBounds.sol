// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI, BUYBACK_GAS} from "../interfaces/Interfaces.sol";

/// the bounds of every setting. CoreLib.setSettings and the deployment scripts use this definition. They cap caller
/// payments and keeper rewards and require the BALANCE discount to cover the royalty and accepted redemption shortfall
library SettingsBounds {
    /// @notice the name of the first field out of bounds, or zero when every field is inside its bounds
    function firstViolation(Settings memory s) internal pure returns (bytes32) {
        // The climb raises the rate from its current value, so a rate driven to zero stays at zero. dropPer100PointsBps
        // at most 9,999 and dropFloorBps at least 1 keep the post-fill rate above zero (decision 143).
        if (s.dropPer100PointsBps < 1 || s.dropPer100PointsBps > 9_999) return "dropPer100PointsBps";
        if (s.dropFloorBps < 1 || s.dropFloorBps > 10_000) return "dropFloorBps";
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
        // Value mode opens its shared ETH instance at 10,000 minus this margin; the bound keeps it positive.
        if (s.balanceBidMarginBps > 9_999) return "balanceBidMarginBps";
        if (s.redeemBurnBps > 10_000) return "redeemBurnBps";
        if (s.payeePpm > 1_000_000) return "payeePpm";
        if (s.pointsPerPage < 1) return "pointsPerPage";
        if (s.climbMultiplierCapBps < 10_000) return "climbMultiplierCapBps";
        if (s.spendCapBps < 1 || s.spendCapBps > 10_000) return "spendCapBps";
        if (s.bucketSeconds < 1) return "bucketSeconds";
        if (s.balanceBidCapBps < 10_000) return "balanceBidCapBps";
        if (s.idleStepSeconds < 1) return "idleStepSeconds";
        if (s.buyToArtistBps > 1_000) return "buyToArtistBps";
        // a 10,000 discount pays zero and every balance fill reverts ZeroAmount: the cap keeps the route live
        if (s.balanceDiscountBps > 9_999) return "balanceDiscountBps";
        // For Credits composed into a Statement, the seller payouts plus artist royalties cannot exceed the minimum
        // accepted redemption return for their total score under the same unit and settings.
        if (
            uint256(10_000 - s.balanceDiscountBps) * (10_000 + s.buyToArtistBps)
                > uint256(10_000 - s.redeemSlippageBps) * 10_000
        ) return "balanceDiscountBps";
        return bytes32(0);
    }

    /// @notice the bounds of the eth rate, wei per 100 points. `setRate` and the constructor argument `rateStart`
    function rateInBounds(uint256 r) internal pure returns (bool) {
        return r >= RATE_START_MIN_WEI && r <= RATE_START_MAX_WEI;
    }
}
