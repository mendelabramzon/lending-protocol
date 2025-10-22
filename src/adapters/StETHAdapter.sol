// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldToken, IStETH} from "../interfaces/IYieldToken.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title StETHAdapter
/// @notice Adapter for Lido's stETH that implements IYieldToken interface
/// @dev stETH is a rebasing token where shares are constant but balance increases
contract StETHAdapter is IYieldToken {
    using FixedPointMath for uint256;

    /// @notice The stETH token contract
    IStETH public immutable stETH;

    /// @notice Mapping of account => recorded shares (to handle rebasing correctly)
    mapping(address => uint256) private _shares;

    /// @notice Initialize the adapter
    /// @param _stETH Address of the stETH contract
    constructor(address _stETH) {
        stETH = IStETH(_stETH);
    }

    /// @inheritdoc IYieldToken
    function getUnderlyingAmount(uint256 wrapperAmount) external view override returns (uint256 underlyingAmount) {
        // For stETH, the token itself IS the underlying (1:1 conceptually)
        // But we track via shares to handle rebasing
        // wrapperAmount here represents shares
        return stETH.getPooledEthByShares(wrapperAmount);
    }

    /// @inheritdoc IYieldToken
    function getWrapperAmount(uint256 underlyingAmount) external view override returns (uint256 wrapperAmount) {
        // Convert stETH balance to shares
        return stETH.getSharesByPooledEth(underlyingAmount);
    }

    /// @inheritdoc IYieldToken
    function getExchangeRate() external view override returns (uint256 rate) {
        // Exchange rate: stETH per share in WAD
        // Calculate based on total supply and total pooled ETH
        uint256 totalShares = stETH.totalSupply();
        if (totalShares == 0) return FixedPointMath.WAD;
        
        uint256 totalPooledEth = stETH.balanceOf(address(stETH));
        return totalPooledEth.wadDiv(totalShares);
    }

    // ========== IERC20 Passthrough with Share Tracking ==========

    function totalSupply() external view override returns (uint256) {
        return stETH.totalSupply();
    }

    function balanceOf(address account) external view override returns (uint256) {
        // Return current stETH balance (will increase due to rebasing)
        return stETH.balanceOf(account);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        return stETH.transfer(to, amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return stETH.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        return stETH.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        return stETH.transferFrom(from, to, amount);
    }

    /// @notice Get shares for an account (helper function)
    /// @param account Address to query
    /// @return shares Amount of shares
    function sharesOf(address account) external view returns (uint256 shares) {
        return stETH.sharesOf(account);
    }
}

