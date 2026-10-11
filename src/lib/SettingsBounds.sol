// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI, BUYBACK_GAS} from "../interfaces/Interfaces.sol";

/// the sanity bounds of every setting (docs/FLOW.md section 2). internal only: the Core reaches it through the linked
/// `CoreLib.validate`, and the deploy scripts inline it, so there is one definition. the bounds stop typos and keep
/// the hard rule that settings cannot become a withdrawal path: every tip, caller payment and keeper reward stays capped
library SettingsBounds {
    /// @notice the name of the first field out of bounds, or zero when every field is inside its bounds
    function firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.dropPerCreditBps < 1 || s.dropPerCreditBps > 1_000) return "dropPerCreditBps";
        if (s.dropFloorBps < 5_000 || s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1 || s.climbPerMinBps > 1_000) return "climbPerMinBps";
        if (s.ceilBps < 10_000 || s.ceilBps > 30_000) return "ceilBps";
        if (s.idleLoosenBps < 1 || s.idleLoosenBps > 2_000) return "idleLoosenBps";
        if (s.tipSavingsBps > 2_500) return "tipSavingsBps";
        if (s.tipCapBps > 500) return "tipCapBps";
        if (s.saleFloorBps < 1_000 || s.saleFloorBps > 40_000) return "saleFloorBps";
        if (s.auctionDuration < 6 hours || s.auctionDuration > 30 days) return "auctionDuration";
        if (s.exitAfter < 1 hours || s.exitAfter > 365 days) return "exitAfter";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (s.exitToBuybackBps > 10_000) return "exitToBuybackBps";
        if (s.buybackSlice < 0.01 ether || s.buybackSlice > 1 ether) return "buybackSlice";
        if (s.buybackDelay < 1 || s.buybackDelay > 7_200) return "buybackDelay";
        if (s.keeperFee > 0.005 ether) return "keeperFee";
        if (s.buybackMaxBaseFee < 1 gwei || s.buybackMaxBaseFee > 100 gwei) return "buybackMaxBaseFee";
        // the largest buyback payment is at most half the slice, so the swap budget is never empty
        if (s.buybackSlice < 2 * (BUYBACK_GAS * s.buybackMaxBaseFee + s.keeperFee)) return "buybackSlice";
        if (s.xRateCap > 10_000) return "xRateCap";
        if (s.xRateFloor > s.xRateCap) return "xRateFloor";
        if (s.xRateClimbPerHour > 1_000) return "xRateClimbPerHour";
        if (s.xRateDropPerCredit > 1_000) return "xRateDropPerCredit";
        if (s.xAuctionHalfLife < 10 minutes || s.xAuctionHalfLife > 30 days) return "xAuctionHalfLife";
        if (s.exitSliceCredits < 1 || s.exitSliceCredits > 1_000) return "exitSliceCredits";
        if (!rateInBounds(s.rateCap)) return "rateCap";
        if (s.exitLaneToBuybackBps > 10_000) return "exitLaneToBuybackBps";
        if (s.feeToBuybackBps > 10_000) return "feeToBuybackBps";
        if (s.callerFee > 0.005 ether) return "callerFee";
        if (s.callerMaxBaseFee > 100 gwei) return "callerMaxBaseFee";
        return bytes32(0);
    }

    /// @notice the bounds of the eth rate, wei per credit. `setRate` and the constructor argument `rateStart`
    function rateInBounds(uint256 r) internal pure returns (bool) {
        return r >= RATE_START_MIN_WEI && r <= RATE_START_MAX_WEI;
    }
}
