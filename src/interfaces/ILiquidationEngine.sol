// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILiquidationEngine
/// @notice Interface for MEV-resistant batch auction liquidation mechanism with commit-reveal
interface ILiquidationEngine {
    /// @notice Struct representing a liquidation commitment
    struct LiquidationCommit {
        bytes32 commitHash; // Hash of the bid details
        uint256 commitTime; // Timestamp of commitment
        uint256 deposit; // Deposit amount (anti-griefing)
        bool revealed; // Whether the bid has been revealed
    }

    /// @notice Struct representing a revealed bid
    struct LiquidationBid {
        address liquidator; // Address of the liquidator
        uint256 bidAmount; // Amount of debt to repay
        uint256 collateralRequested; // Collateral requested (lower is better)
        uint256 revealTime; // Time bid was revealed
    }

    /// @notice Struct representing an auction state
    struct Auction {
        uint256 startTime; // When auction started (first commit)
        uint256 auctionEndTime; // When reveal period ends
        bool executed; // Whether auction has been executed
        address winner; // Winning bidder
    }

    /// @notice Emitted when a liquidation is committed
    event LiquidationCommitted(address indexed liquidator, address indexed vault, bytes32 commitHash, uint256 deposit);

    /// @notice Emitted when a liquidation is revealed
    event LiquidationRevealed(address indexed liquidator, address indexed vault, uint256 bidAmount, uint256 collateralRequested);

    /// @notice Emitted when an auction is finalized
    event AuctionFinalized(address indexed vault, address indexed winner, uint256 debtRepaid, uint256 collateralSeized);

    /// @notice Emitted when a deposit is slashed
    event DepositSlashed(address indexed liquidator, address indexed vault, uint256 amount);

    /// @notice Emitted when a deposit is refunded
    event DepositRefunded(address indexed liquidator, uint256 amount);

    /// @notice Commit to a liquidation bid with deposit (step 1)
    /// @param vault Address of the vault to liquidate
    /// @param commitHash Hash of (bidAmount, collateralRequested, salt)
    function commitLiquidation(address vault, bytes32 commitHash) external payable;

    /// @notice Reveal liquidation bid during auction period (step 2)
    /// @dev IMPORTANT: Liquidator must have approved LiquidationEngine to spend bidAmount of STABLE_TOKEN before revealing
    /// @dev Liquidator must have sufficient STABLE_TOKEN balance to cover bidAmount
    /// @param vault Address of the vault to liquidate
    /// @param bidAmount Amount of debt to repay
    /// @param collateralRequested Collateral amount requested (competition parameter)
    /// @param salt Random salt used in commitment
    function revealLiquidation(address vault, uint256 bidAmount, uint256 collateralRequested, bytes32 salt) external;

    /// @notice Finalize auction and execute winning bid (step 3)
    /// @param vault Address of the vault to liquidate
    function finalizeAuction(address vault) external;

    /// @notice Claim refund for losing bid or expired commitment
    /// @param vault Address of the vault
    function claimRefund(address vault) external;

    /// @notice Get commitment details for a liquidator and vault
    /// @param liquidator Address of the liquidator
    /// @param vault Address of the vault
    /// @return commit The liquidation commitment struct
    function getCommitment(address liquidator, address vault) external view returns (LiquidationCommit memory commit);

    /// @notice Get auction state for a vault
    /// @param vault Address of the vault
    /// @return auction The auction state
    function getAuction(address vault) external view returns (Auction memory auction);

    /// @notice Calculate liquidation parameters with proper USD valuation
    /// @param vault Address of the vault
    /// @param debtToRepay Amount of debt to repay
    /// @return collateralToSeize Amount of collateral to seize
    /// @return liquidationBonus Bonus amount for liquidator
    function calculateLiquidation(address vault, uint256 debtToRepay)
        external
        view
        returns (uint256 collateralToSeize, uint256 liquidationBonus);
}

