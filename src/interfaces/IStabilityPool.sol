// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStabilityPool
/// @notice Interface for the stability pool holding liquidation funds
interface IStabilityPool {
    /// @notice Struct representing a depositor's position
    struct Deposit {
        uint256 amount; // Amount of stablecoins deposited
        uint256 collateralGain; // Accumulated collateral from liquidations
        uint256 timestamp; // Last deposit/claim timestamp
    }

    /// @notice Emitted when stablecoins are deposited
    event StablecoinsDeposited(address indexed depositor, uint256 amount);

    /// @notice Emitted when stablecoins are withdrawn
    event StablecoinsWithdrawn(address indexed depositor, uint256 amount);

    /// @notice Emitted when collateral gains are claimed
    event CollateralGainsClaimed(address indexed depositor, uint256 collateralAmount);

    /// @notice Emitted when liquidation proceeds are distributed
    event LiquidationDistributed(uint256 debtOffset, uint256 collateralToDistribute);

    /// @notice Deposit stablecoins into the stability pool
    /// @param amount Amount of stablecoins to deposit
    function deposit(uint256 amount) external;

    /// @notice Withdraw stablecoins from the stability pool
    /// @param amount Amount of stablecoins to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Claim accumulated collateral gains
    function claimCollateralGains() external;

    /// @notice Distribute liquidation proceeds to depositors
    /// @param debtToOffset Amount of debt being offset
    /// @param collateralToDistribute Amount of collateral to distribute
    function distributeLiquidation(uint256 debtToOffset, uint256 collateralToDistribute) external;

    /// @notice Get deposit details for a user
    /// @param depositor Address of the depositor
    /// @return deposit The deposit struct
    function getDeposit(address depositor) external view returns (Deposit memory deposit);

    /// @notice Get total stablecoins in the pool
    /// @return total Total stablecoin balance
    function getTotalDeposits() external view returns (uint256 total);
}

