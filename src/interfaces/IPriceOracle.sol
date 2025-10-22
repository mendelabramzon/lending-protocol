// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice Interface for price oracle aggregating multiple feeds
interface IPriceOracle {
    /// @notice Emitted when a price feed is updated
    event PriceFeedUpdated(address indexed token, address indexed feed);

    /// @notice Get the current USD price of a token
    /// @param token Address of the token
    /// @return price Price in USD with 8 decimals (Chainlink standard)
    function getPrice(address token) external returns (uint256 price);
    
    /// @notice Get the current USD price without updating TWAP (view-only)
    /// @param token Address of the token
    /// @return price Price in USD with 8 decimals (Chainlink standard)
    function getPriceView(address token) external view returns (uint256 price);

    /// @notice Get time-weighted average price to prevent manipulation
    /// @param token Address of the token
    /// @param period Time period for TWAP calculation
    /// @return price Time-weighted average price with 8 decimals
    function getTWAP(address token, uint256 period) external view returns (uint256 price);

    /// @notice Set or update price feed for a token
    /// @param token Address of the token
    /// @param feed Address of the Chainlink price feed
    function setPriceFeed(address token, address feed) external;
}

