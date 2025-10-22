// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IYieldToken
/// @notice Interface for yield-bearing token adapters
/// @dev Abstracts different yield-bearing token mechanisms (rebasing, wrapped, exchange rate)
interface IYieldToken is IERC20 {
    /// @notice Get the underlying token amount for a given wrapper amount
    /// @param wrapperAmount Amount of wrapper tokens
    /// @return underlyingAmount Amount of underlying tokens
    function getUnderlyingAmount(uint256 wrapperAmount) external view returns (uint256 underlyingAmount);

    /// @notice Get the wrapper token amount for a given underlying amount
    /// @param underlyingAmount Amount of underlying tokens
    /// @return wrapperAmount Amount of wrapper tokens
    function getWrapperAmount(uint256 underlyingAmount) external view returns (uint256 wrapperAmount);

    /// @notice Get current exchange rate (underlying per wrapper, in WAD)
    /// @return rate Exchange rate in 18 decimals
    /// @dev Non-view to allow adapters to track and detect slashing events
    function getExchangeRate() external returns (uint256 rate);
}

/// @title IStETH
/// @notice Interface for Lido's stETH (rebasing token)
interface IStETH is IERC20 {
    /// @notice Get shares amount for a given stETH amount
    /// @param ethAmount Amount of stETH
    /// @return sharesAmount Amount of shares
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256 sharesAmount);

    /// @notice Get stETH amount for a given shares amount
    /// @param sharesAmount Amount of shares
    /// @return ethAmount Amount of stETH
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256 ethAmount);

    /// @notice Get shares of an account
    /// @param account Address to query
    /// @return shares Amount of shares
    function sharesOf(address account) external view returns (uint256 shares);

    /// @notice Submit ETH and mint stETH
    /// @param referral Referral address
    /// @return shares Amount of shares minted
    function submit(address referral) external payable returns (uint256 shares);
}

/// @title IWstETH
/// @notice Interface for Lido's wstETH (wrapped, non-rebasing)
interface IWstETH is IERC20 {
    /// @notice Get amount of stETH for a given amount of wstETH
    /// @param wstETHAmount Amount of wstETH
    /// @return stETHAmount Amount of stETH
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);

    /// @notice Get amount of wstETH for a given amount of stETH
    /// @param stETHAmount Amount of stETH
    /// @return wstETHAmount Amount of wstETH
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256 wstETHAmount);

    /// @notice Wrap stETH to wstETH
    /// @param stETHAmount Amount of stETH to wrap
    /// @return wstETHAmount Amount of wstETH received
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);

    /// @notice Unwrap wstETH to stETH
    /// @param wstETHAmount Amount of wstETH to unwrap
    /// @return stETHAmount Amount of stETH received
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);

    /// @notice Get stETH token address
    /// @return stETH Address of stETH
    function stETH() external view returns (address stETH);

    /// @notice Get current tokens per share
    /// @return tokensPerShare Tokens per share
    function tokensPerStEth() external view returns (uint256 tokensPerShare);
}

/// @title IRETH
/// @notice Interface for Rocket Pool's rETH
interface IRETH is IERC20 {
    /// @notice Get ETH value of rETH amount
    /// @param rethAmount Amount of rETH
    /// @return ethAmount Amount of ETH
    function getEthValue(uint256 rethAmount) external view returns (uint256 ethAmount);

    /// @notice Get rETH value of ETH amount
    /// @param ethAmount Amount of ETH
    /// @return rethAmount Amount of rETH
    function getRethValue(uint256 ethAmount) external view returns (uint256 rethAmount);

    /// @notice Get current exchange rate
    /// @return rate Exchange rate (ETH per rETH)
    function getExchangeRate() external view returns (uint256 rate);

    /// @notice Burn rETH for ETH
    /// @param amount Amount of rETH to burn
    function burn(uint256 amount) external;
}

