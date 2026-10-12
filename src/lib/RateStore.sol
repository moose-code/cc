// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// where the bid anchor state lives: four words from a fixed storage slot of the Core, shared by the Core and
/// the linked library, so the library can update it on a fill
library RateStore {
    // the top 64 bits of keccak256("credits.core.rate.v1"). a slot far above the sequential slots of the Core and far
    // below the hashed slots of its mappings and arrays, four words from here
    bytes32 internal constant SLOT = bytes32(uint256(0x4e200413f073f368));

    struct Anchor {
        /// the price state at the last fill. the rate at deployment before the first fill
        uint256 lastFillRate;
        /// the price state at the first fill of the minute bucket `minuteBucket`
        uint256 minuteStartRate;
        /// `timestamp / 60` of the first fill of the current minute
        uint64 minuteBucket;
        /// time `peakRate` was last written: the last fill or `setRate`, deploy time before the first fill
        uint64 peakTime;
        /// the remembered peak: `max(fill price, peak decayed to the fill time)` at the last fill, `setRate`'s rate, or
        /// `rateStart` at deploy. it halves every `peakHalfLife` since `peakTime`. the ceiling anchors on
        /// `max(lastFillRate, peak now)`, and the price state climbs at `recoveryClimbPerMinBps` while below it
        uint256 peakRate;
    }

    function load() internal pure returns (Anchor storage a) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            a.slot := slot
        }
    }
}
