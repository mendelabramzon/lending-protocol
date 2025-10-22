// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldToken, IWstETH} from "../interfaces/IYieldToken.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title WstETHAdapter
/// @notice Adapter for Lido's wstETH that implements IYieldToken interface
/// @dev wstETH is a non-rebasing wrapper for stETH with an increasing exchange rate
/// @dev CRITICAL: Integrates with EmergencyGuardian to auto-pause protocol on slashing events
contract WstETHAdapter is IYieldToken {
    using FixedPointMath for uint256;

    /// @notice The wstETH token contract
    IWstETH public immutable wstETH;
    
    /// @notice Emergency guardian for circuit breaker integration
    address public emergencyGuardian;

    /// @notice Last known exchange rate (for slashing detection)
    uint256 private lastExchangeRate;

    /// @notice Minimum exchange rate drop before considering it a slashing event (5%)
    uint256 public constant MAX_EXCHANGE_RATE_DROP = 5e16; // 0.05 in WAD

    /// @notice Error thrown when exchange rate decreases (potential slashing)
    error ExchangeRateDecreased();

    /// @notice Error thrown when exchange rate is invalid
    error InvalidExchangeRate();
    
    /// @notice Error thrown when circuit breaker trip fails
    error CircuitBreakerTripFailed();

    /// @notice Emitted when potential slashing is detected
    event PotentialSlashingDetected(uint256 oldRate, uint256 newRate, uint256 dropPercentage);
    
    /// @notice Emitted when circuit breaker is automatically tripped due to slashing
    event CircuitBreakerTrippedOnSlashing(uint256 oldRate, uint256 newRate, uint256 dropPercentage);

    /// @notice Initialize the adapter
    /// @param _wstETH Address of the wstETH contract
    /// @param _emergencyGuardian Address of the emergency guardian (can be zero initially)
    constructor(address _wstETH, address _emergencyGuardian) {
        require(_wstETH != address(0), "Invalid wstETH address");
        wstETH = IWstETH(_wstETH);
        emergencyGuardian = _emergencyGuardian; // Can be zero, will be set later
        
        // Initialize with current exchange rate
        try wstETH.tokensPerStEth() returns (uint256 rate) {
            require(rate > 0, "Invalid initial exchange rate");
            lastExchangeRate = rate;
        } catch {
            revert InvalidExchangeRate();
        }
    }
    
    /// @notice Set emergency guardian address (one-time setup or owner-controlled)
    /// @param _emergencyGuardian Address of the emergency guardian contract
    /// @dev SECURITY: In production, this should be protected by owner or made immutable
    function setEmergencyGuardian(address _emergencyGuardian) external {
        require(emergencyGuardian == address(0), "Guardian already set");
        emergencyGuardian = _emergencyGuardian;
    }

    /// @inheritdoc IYieldToken
    function getUnderlyingAmount(uint256 wrapperAmount) external view override returns (uint256 underlyingAmount) {
        // wstETH -> stETH (underlying)
        return wstETH.getStETHByWstETH(wrapperAmount);
    }

    /// @inheritdoc IYieldToken
    function getWrapperAmount(uint256 underlyingAmount) external view override returns (uint256 wrapperAmount) {
        // stETH (underlying) -> wstETH
        return wstETH.getWstETHByStETH(underlyingAmount);
    }

    /// @inheritdoc IYieldToken
    function getExchangeRate() external override returns (uint256 rate) {
        // Exchange rate: stETH per wstETH in WAD (18 decimals)
        // tokensPerStEth returns the ratio, already in proper precision
        try wstETH.tokensPerStEth() returns (uint256 currentRate) {
            if (currentRate == 0) revert InvalidExchangeRate();
            
            // CRITICAL: Check for significant drops (potential slashing)
            if (lastExchangeRate > 0 && currentRate < lastExchangeRate) {
                uint256 drop = lastExchangeRate - currentRate;
                uint256 dropPercentage = drop.wadDiv(lastExchangeRate);
                
                // If drop is significant, TRIP CIRCUIT BREAKER
                if (dropPercentage > MAX_EXCHANGE_RATE_DROP) {
                    emit PotentialSlashingDetected(lastExchangeRate, currentRate, dropPercentage);
                    
                    if (emergencyGuardian != address(0)) {
                        // Call emergency guardian to trip circuit breaker
                        // This prevents all withdrawals, borrows, and liquidations
                        (bool success,) = emergencyGuardian.call(
                            abi.encodeWithSignature("tripCircuitBreaker()")
                        );
                        
                        if (success) {
                            emit CircuitBreakerTrippedOnSlashing(lastExchangeRate, currentRate, dropPercentage);
                        } else {
                            // If trip fails, revert to prevent operations during slashing
                            revert CircuitBreakerTripFailed();
                        }
                    } else {
                        // No guardian set - revert to prevent operations during unprotected slashing
                        revert ExchangeRateDecreased();
                    }
                }
            }
            
            lastExchangeRate = currentRate;
            return currentRate;
        } catch {
            revert InvalidExchangeRate();
        }
    }

    /// @notice Get last known exchange rate (view-only, doesn't update)
    /// @return rate Last recorded exchange rate
    function getLastExchangeRate() external view returns (uint256 rate) {
        return lastExchangeRate;
    }

    /// @notice Check if exchange rate has decreased significantly
    /// @return hasSlashing True if potential slashing detected
    /// @return dropPercentage Percentage drop in WAD format
    function checkForSlashing() external view returns (bool hasSlashing, uint256 dropPercentage) {
        try wstETH.tokensPerStEth() returns (uint256 currentRate) {
            if (lastExchangeRate > 0 && currentRate < lastExchangeRate) {
                uint256 drop = lastExchangeRate - currentRate;
                dropPercentage = drop.wadDiv(lastExchangeRate);
                hasSlashing = dropPercentage > MAX_EXCHANGE_RATE_DROP;
            }
        } catch {
            return (false, 0);
        }
    }

    // ========== IERC20 Passthrough ==========

    function totalSupply() external view override returns (uint256) {
        return wstETH.totalSupply();
    }

    function balanceOf(address account) external view override returns (uint256) {
        return wstETH.balanceOf(account);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        return wstETH.transfer(to, amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return wstETH.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        return wstETH.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        return wstETH.transferFrom(from, to, amount);
    }
}

