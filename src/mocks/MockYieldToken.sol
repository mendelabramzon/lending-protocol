// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldToken} from "../interfaces/IYieldToken.sol";

/// @title MockYieldToken
/// @notice Mock yield-bearing token for testing (simulates stETH, sfrxETH, etc.)
/// @dev Implements IYieldToken for adapter compatibility
contract MockYieldToken is ERC20, IYieldToken {
    /// @notice Simulated annual percentage yield (5% default)
    uint256 public apy = 5e16; // 0.05 in WAD (5%)

    /// @notice Last yield accrual timestamp
    uint256 public lastAccrualTime;

    /// @notice Total shares (internal accounting)
    uint256 private _totalShares;

    /// @notice Mapping of account => shares
    mapping(address => uint256) private _shares;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        lastAccrualTime = block.timestamp;
    }

    /// @notice Mint tokens (as shares)
    /// @param to Recipient address
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external {
        uint256 shares = _getSharesByTokens(amount);
        _shares[to] += shares;
        _totalShares += shares;
        
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn tokens (as shares)
    /// @param from Address to burn from
    /// @param amount Amount of tokens to burn
    function burn(address from, uint256 amount) external {
        uint256 shares = _getSharesByTokens(amount);
        _shares[from] -= shares;
        _totalShares -= shares;
        
        emit Transfer(from, address(0), amount);
    }

    /// @notice Set APY for testing
    /// @param newApy New APY in WAD format
    function setAPY(uint256 newApy) external {
        apy = newApy;
    }

    /// @notice Simulate yield accrual
    function accrueYield() external {
        lastAccrualTime = block.timestamp;
        // Yield is automatically reflected in balanceOf due to share mechanism
    }

    /// @notice Get balance of an account (includes accrued yield)
    /// @param account Address to query
    /// @return Token balance
    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        return _getTokensByShares(_shares[account]);
    }

    /// @notice Get total supply (includes accrued yield)
    /// @return Total token supply
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return _getTokensByShares(_totalShares);
    }

    /// @notice Transfer tokens
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        address owner = _msgSender();
        uint256 shares = _getSharesByTokens(amount);
        
        _shares[owner] -= shares;
        _shares[to] += shares;
        
        emit Transfer(owner, to, amount);
        return true;
    }

    /// @notice Transfer tokens from
    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        
        uint256 shares = _getSharesByTokens(amount);
        _shares[from] -= shares;
        _shares[to] += shares;
        
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Convert shares to tokens (with yield)
    function _getTokensByShares(uint256 sharesAmount) internal view returns (uint256) {
        if (_totalShares == 0) return sharesAmount;
        
        // Calculate time-based yield multiplier
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        uint256 yieldMultiplier = 1e18 + (apy * timeElapsed / 365 days);
        
        return (sharesAmount * yieldMultiplier) / 1e18;
    }

    /// @notice Convert tokens to shares
    function _getSharesByTokens(uint256 tokenAmount) internal view returns (uint256) {
        if (_totalShares == 0) return tokenAmount;
        
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        uint256 yieldMultiplier = 1e18 + (apy * timeElapsed / 365 days);
        
        return (tokenAmount * 1e18) / yieldMultiplier;
    }

    /// @notice Get shares of an account
    function sharesOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    /// @notice Get total shares
    function getTotalShares() external view returns (uint256) {
        return _totalShares;
    }

    // ========== IYieldToken Implementation ==========

    /// @inheritdoc IYieldToken
    /// @notice For mock, wrapper and underlying are the same (simulates wrapped LST behavior)
    function getUnderlyingAmount(uint256 wrapperAmount) external view override returns (uint256 underlyingAmount) {
        // Simulate exchange rate increase over time (like wstETH -> stETH)
        // As time passes, same wrapper amount represents more underlying
        return _getTokensByShares(wrapperAmount);
    }

    /// @inheritdoc IYieldToken
    function getWrapperAmount(uint256 underlyingAmount) external view override returns (uint256 wrapperAmount) {
        // Convert underlying back to wrapper
        return _getSharesByTokens(underlyingAmount);
    }

    /// @inheritdoc IYieldToken
    /// @notice Returns the exchange rate (underlying per wrapper) in WAD format
    function getExchangeRate() external override returns (uint256 rate) {
        // Calculate yield multiplier based on time elapsed
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        // Exchange rate = 1 + (APY * time_elapsed / year)
        // This simulates how wstETH exchange rate increases over time
        return 1e18 + (apy * timeElapsed / 365 days);
    }
}

