// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldToken, IRETH} from "../interfaces/IYieldToken.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title RETHAdapter
/// @notice Adapter for Rocket Pool's rETH that implements IYieldToken interface
/// @dev rETH has an increasing exchange rate vs ETH (non-rebasing)
contract RETHAdapter is IYieldToken {
    using FixedPointMath for uint256;

    /// @notice The rETH token contract
    IRETH public immutable rETH;

    /// @notice Initialize the adapter
    /// @param _rETH Address of the rETH contract
    constructor(address _rETH) {
        rETH = IRETH(_rETH);
    }

    /// @inheritdoc IYieldToken
    function getUnderlyingAmount(uint256 wrapperAmount) external view override returns (uint256 underlyingAmount) {
        // rETH -> ETH (underlying)
        return rETH.getEthValue(wrapperAmount);
    }

    /// @inheritdoc IYieldToken
    function getWrapperAmount(uint256 underlyingAmount) external view override returns (uint256 wrapperAmount) {
        // ETH (underlying) -> rETH
        return rETH.getRethValue(underlyingAmount);
    }

    /// @inheritdoc IYieldToken
    function getExchangeRate() external view override returns (uint256 rate) {
        // Exchange rate: ETH per rETH in WAD (18 decimals)
        return rETH.getExchangeRate();
    }

    // ========== IERC20 Passthrough ==========

    function totalSupply() external view override returns (uint256) {
        return rETH.totalSupply();
    }

    function balanceOf(address account) external view override returns (uint256) {
        return rETH.balanceOf(account);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        return rETH.transfer(to, amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return rETH.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        return rETH.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        return rETH.transferFrom(from, to, amount);
    }
}

