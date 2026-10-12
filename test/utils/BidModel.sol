// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";
import {Halving} from "../../src/lib/Halving.sol";

/// @notice the credit bid rule restated in the tests, from the settings. the invariant handlers and the fuzz and model
/// suites (`HandlerBase`, `RateFuzz`, `ReviewEcon`, `Econ`, `CoreUnit`, `Lifecycle`, `Seaport`) use it as their model:
/// the drop per credit with the minute floor, the dual speed climb per minute with the remembered peak, the clamp and
/// the ceiling with the idle loosening of its anchor. the clamp lowers the read, the price state is stored. the climb
/// and ceiling reproduce `CoreLib` arithmetic, so the read matches exactly. `BidRule.t.sol` asserts hand arithmetic and
/// does not use it
library BidModel {
    using FixedPointMathLib for uint256;

    /// @dev the checkpoint state the price state is read from: the stored rate, the pot, the last fill rate, the
    /// remembered peak and the three times the Core keeps (checkpoint, last fill, peak), and the evaluation time
    struct Bid {
        uint256 r;
        uint256 pot;
        uint256 lastFillRate;
        uint256 peakRate;
        uint256 peakTime;
        uint256 lastFillTime;
        uint256 checkpointTime;
        uint256 nowTs;
    }

    /// @dev the price state at the first fill of the minute after a fill at `fillState`: `minuteStart`, or `fillState` when
    /// it is below the floor of `minuteStart`
    function startAfter(Settings memory s, uint256 fillState, uint256 minuteStart) internal pure returns (uint256) {
        return fillState < minuteStart * s.dropFloorBps / 10_000 ? fillState : minuteStart;
    }

    /// @dev the rate after one credit bought with the price state `fillState`, where `minuteStart` is the price state at
    /// the first fill of the same minute bucket
    function dropOnce(Settings memory s, uint256 fillState, uint256 minuteStart) internal pure returns (uint256) {
        minuteStart = startAfter(s, fillState, minuteStart);
        return
            FixedPointMathLib.max(fillState * (10_000 - s.dropPerCreditBps) / 10_000, minuteStart * s.dropFloorBps / 10_000);
    }

    /// @dev the clamp: the price of one credit that a pot affords, at most `rateCap`
    function clamp(Settings memory s, uint256 pot) internal pure returns (uint256) {
        return FixedPointMathLib.min(pot, s.rateCap);
    }

    /// @dev the remembered peak now: `peakRate` halved over the time since `peakTime`
    function peakNow(Settings memory s, uint256 peakRate, uint256 peakTime, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        return Halving.halve(peakRate, nowTs > peakTime ? nowTs - peakTime : 0, s.peakHalfLife);
    }

    /// @dev the ceiling: `ceilBps` of the anchor grown by `idleLoosenBps` per full 10 minutes idle. the anchor is
    /// `max(last fill rate, peak now)`, which the callers pass in
    function ceiling(Settings memory s, uint256 anchor, uint256 idle) internal pure returns (uint256) {
        return anchor * (10_000 + uint256(s.idleLoosenBps) * (idle / 10 minutes)) * s.ceilBps / 1e8;
    }

    /// @dev the price state now from the checkpoint state `b`: at most `rateCap` and the ceiling, below the recovery
    /// level (`recoveryGapBps` under the peak) the climb is `recoveryClimbPerMinBps` a minute and at or above it
    /// `climbPerMinBps`, up to the clamp (a price state above the clamp holds). reproduces `CoreLib._climb` so the read
    /// matches exactly
    function priceNow(Settings memory s, Bid memory b) internal pure returns (uint256) {
        uint256 anchor = b.lastFillRate.max(peakNow(s, b.peakRate, b.peakTime, b.nowTs));
        uint256 idle = b.nowTs > b.lastFillTime ? b.nowTs - b.lastFillTime : 0;
        uint256 cap = ceiling(s, anchor, idle).min(s.rateCap);
        if (b.r >= cap) return cap;
        if (b.nowTs <= b.checkpointTime || b.r == 0) return b.r;
        uint256 target = cap.min(b.pot);
        if (b.r >= target) return b.r;
        return _recover(s, b, target);
    }

    function _recover(Settings memory s, Bid memory b, uint256 target) private pure returns (uint256) {
        // forge-lint: disable-start(unsafe-typecast)
        int256 lnFast = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.recoveryClimbPerMinBps) * 1e14));
        int256 lnSlow = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14));
        uint256 peakT = Halving.halve(
            b.peakRate, b.checkpointTime > b.peakTime ? b.checkpointTime - b.peakTime : 0, s.peakHalfLife
        );
        uint256 levelT = peakT * (10_000 - s.recoveryGapBps) / 10_000;
        uint256 fullWadSec = (b.nowTs - b.checkpointTime) * 1e18;
        if (levelT <= b.r) return _climbTo(b.r, lnSlow, fullWadSec, target);
        uint256 denom = uint256(lnFast) / 1 minutes + uint256(FixedPointMathLib.lnWad(2e18)) / s.peakHalfLife;
        uint256 crossWadSec = uint256(FixedPointMathLib.lnWad(int256(levelT * 1e18 / b.r))) * 1e18 / denom;
        if (fullWadSec <= crossWadSec) return _climbTo(b.r, lnFast, fullWadSec, target);
        uint256 priceCross = _climbTo(b.r, lnFast, crossWadSec, target);
        if (priceCross >= target) return target;
        return _climbTo(priceCross, lnSlow, fullWadSec - crossWadSec, target);
        // forge-lint: disable-end(unsafe-typecast)
    }

    function _climbTo(uint256 base, int256 lnRate, uint256 wadSec, uint256 target) private pure returns (uint256) {
        // forge-lint: disable-start(unsafe-typecast)
        int256 x = lnRate * int256(wadSec / 1 minutes) / 1e18;
        if (x >= FixedPointMathLib.lnWad(int256(target * 1e18 / base))) return target;
        return base.mulWad(uint256(FixedPointMathLib.expWad(x))).min(target);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the read for the price state `p`: lowered to the clamp
    function read(Settings memory s, uint256 pot, uint256 p) internal pure returns (uint256) {
        return FixedPointMathLib.min(p, clamp(s, pot));
    }
}
