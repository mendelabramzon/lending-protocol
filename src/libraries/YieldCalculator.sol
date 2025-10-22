// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FixedPointMath} from "./FixedPointMath.sol";

/// @title YieldCalculator
/// @notice Library for calculating yield accrual on collateral
library YieldCalculator {
    using FixedPointMath for uint256;

    /// @notice Calculate accrued yield based on APY and time elapsed
    /// @param principal Initial amount
    /// @param apy Annual percentage yield (in WAD, e.g., 0.05e18 = 5%)
    /// @param timeElapsed Time elapsed in seconds
    /// @return newAmount Amount after yield accrual
    function calculateYieldAccrual(uint256 principal, uint256 apy, uint256 timeElapsed)
        internal
        pure
        returns (uint256 newAmount)
    {
        if (timeElapsed == 0 || principal == 0) {
            return principal;
        }

        // Convert APY to per-second rate
        // rate = (1 + APY)^(timeElapsed/365 days) - 1
        // Simplified linear approximation for small time periods
        uint256 SECONDS_PER_YEAR = 365 days;
        uint256 yieldRate = apy.wadMul(timeElapsed * FixedPointMath.WAD / SECONDS_PER_YEAR);
        
        return principal + principal.wadMul(yieldRate);
    }

    /// @notice Calculate compound interest over time
    /// @param principal Initial amount
    /// @param rate Interest rate per period (in WAD)
    /// @param periods Number of compounding periods
    /// @return finalAmount Amount after compounding
    function compoundInterest(uint256 principal, uint256 rate, uint256 periods)
        internal
        pure
        returns (uint256 finalAmount)
    {
        if (periods == 0) {
            return principal;
        }

        uint256 accumulatedRate = FixedPointMath.WAD;
        for (uint256 i = 0; i < periods; i++) {
            accumulatedRate = accumulatedRate.wadMul(FixedPointMath.WAD + rate);
        }

        return principal.wadMul(accumulatedRate);
    }
}

