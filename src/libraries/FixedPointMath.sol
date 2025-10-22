// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FixedPointMath
/// @notice Library for precise fixed-point arithmetic operations
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant PRICE_PRECISION = 1e8; // Chainlink price precision

    /// @notice Multiply two WAD (18 decimal) numbers (rounds down)
    /// @param a First number
    /// @param b Second number
    /// @return result Product of a and b
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256 result) {
        return (a * b) / WAD;
    }

    /// @notice Multiply two WAD (18 decimal) numbers (rounds up)
    /// @dev Used when rounding should favor protocol (e.g., calculating fees)
    /// @param a First number
    /// @param b Second number
    /// @return result Product of a and b rounded up
    function wadMulUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        uint256 product = a * b;
        result = product / WAD;
        if (product % WAD != 0) {
            result += 1;
        }
        return result;
    }

    /// @notice Divide two WAD (18 decimal) numbers (rounds down)
    /// @param a Numerator
    /// @param b Denominator
    /// @return result Quotient of a and b
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256 result) {
        return (a * WAD) / b;
    }

    /// @notice Divide two WAD (18 decimal) numbers (rounds up)
    /// @dev Used when rounding should favor protocol (e.g., calculating debt)
    /// @param a Numerator
    /// @param b Denominator
    /// @return result Quotient of a and b rounded up
    function wadDivUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        uint256 product = a * WAD;
        result = product / b;
        if (product % b != 0) {
            result += 1;
        }
        return result;
    }

    /// @notice Multiply two RAY (27 decimal) numbers
    /// @param a First number
    /// @param b Second number
    /// @return result Product of a and b
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256 result) {
        return (a * b) / RAY;
    }

    /// @notice Divide two RAY (27 decimal) numbers
    /// @param a Numerator
    /// @param b Denominator
    /// @return result Quotient of a and b
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256 result) {
        return (a * RAY) / b;
    }

    /// @notice Convert price (8 decimals) to WAD (18 decimals)
    /// @param price Price with 8 decimals
    /// @return result Price with 18 decimals
    function priceToWad(uint256 price) internal pure returns (uint256 result) {
        return price * 1e10; // 1e18 / 1e8 = 1e10
    }

    /// @notice Convert WAD to price (8 decimals)
    /// @param wad Value with 18 decimals
    /// @return result Value with 8 decimals
    function wadToPrice(uint256 wad) internal pure returns (uint256 result) {
        return wad / 1e10;
    }

    /// @notice Calculate percentage of a value
    /// @param value The value
    /// @param pct The percentage (in WAD, e.g., 0.1e18 = 10%)
    /// @return result The percentage of value
    function percentage(uint256 value, uint256 pct) internal pure returns (uint256 result) {
        return wadMul(value, pct);
    }
}

