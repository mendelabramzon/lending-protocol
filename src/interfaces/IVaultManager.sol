// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVaultManager
/// @notice Interface for the core vault management contract
interface IVaultManager {
    /// @notice Struct representing a user's vault position
    struct Vault {
        uint256 collateralAmount; // Amount of yield-bearing collateral deposited (wrapper token amount, e.g., wstETH)
        uint256 debtAmount; // Amount of stablecoin debt owed
        uint256 lastAccrualTimestamp; // Last time yield was accrued (deprecated - kept for interface compatibility)
        uint256 lastExchangeRate; // Last recorded exchange rate from adapter (for tracking real yield)
    }

    /// @notice Emitted when collateral is deposited
    event CollateralDeposited(address indexed user, uint256 amount);

    /// @notice Emitted when collateral is withdrawn
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when debt is borrowed
    event DebtBorrowed(address indexed user, uint256 amount);

    /// @notice Emitted when debt is repaid
    event DebtRepaid(address indexed user, uint256 amount);

    /// @notice Emitted when a vault is liquidated
    event VaultLiquidated(address indexed user, address indexed liquidator, uint256 collateralSeized, uint256 debtRepaid);

    /// @notice Deposit yield-bearing collateral tokens
    /// @param amount Amount of collateral to deposit
    function depositCollateral(uint256 amount) external;

    /// @notice Withdraw collateral tokens
    /// @param amount Amount of collateral to withdraw
    function withdrawCollateral(uint256 amount) external;

    /// @notice Borrow stablecoins against collateral
    /// @param amount Amount of stablecoins to borrow
    function borrow(uint256 amount) external;

    /// @notice Repay borrowed stablecoins
    /// @param amount Amount of stablecoins to repay
    function repay(uint256 amount) external;

    /// @notice Get the current health ratio of a vault
    /// @param user Address of the vault owner
    /// @return healthRatio The health ratio scaled by 1e18 (>1e18 is healthy)
    function getHealthRatio(address user) external view returns (uint256 healthRatio);

    /// @notice Get vault details for a user
    /// @param user Address of the vault owner
    /// @return vault The vault struct
    function getVault(address user) external view returns (Vault memory vault);

    /// @notice Accrue yield for a user's collateral
    /// @param user Address of the vault owner
    function accrueYield(address user) external;

    /// @notice Liquidate an undercollateralized vault
    /// @param user Address of the vault owner
    /// @param debtToRepay Amount of debt to repay
    /// @return collateralSeized Amount of collateral seized
    function liquidate(address user, uint256 debtToRepay) external returns (uint256 collateralSeized);
}

