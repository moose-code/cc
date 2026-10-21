// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IRedemptionPolicy} from "../interfaces/Interfaces.sol";

/// the first redemption policy of the phase 2 treasury: a burn of `ccIn` out of `ccSupply` is paid its proportional share
/// of `claimReserve`, less `feeBps`. pure, stateless, holds no token and has no allowance. the treasury keeps any fee
/// in its claim reserve because it subtracts only `out`. at a zero fee the backing per remaining token never falls
/// through a redemption, apart from the rounding dust that stays in the reserve
contract ProRataRedemptionPolicy is IRedemptionPolicy {
    string public constant VERSION = "pro-rata-v1";
    uint256 private constant BPS = 10_000;

    error ZeroInput();
    error InputAboveSupply();
    error BadFee();

    /// `floor(ccIn * claimReserve / ccSupply) * (10_000 - feeBps) / 10_000`, full precision. reverts on a zero input or
    /// supply, an input above the supply and a fee above 10,000
    function quote(uint256 ccIn, uint256 claimReserve, uint256 ccSupply, uint256 feeBps)
        external
        pure
        override
        returns (uint256 out)
    {
        if (ccIn == 0 || ccSupply == 0) revert ZeroInput();
        if (ccIn > ccSupply) revert InputAboveSupply();
        if (feeBps > BPS) revert BadFee();
        uint256 gross = FixedPointMathLib.fullMulDiv(ccIn, claimReserve, ccSupply);
        out = FixedPointMathLib.fullMulDiv(gross, BPS - feeBps, BPS);
    }

    function isRedemptionPolicy() external pure override returns (bool) {
        return true;
    }
}
