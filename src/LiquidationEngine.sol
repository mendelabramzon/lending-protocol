// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILiquidationEngine} from "./interfaces/ILiquidationEngine.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IStabilityPool} from "./interfaces/IStabilityPool.sol";
import {StableToken} from "./StableToken.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title LiquidationEngine
/// @notice MEV-resistant liquidation engine using batch auctions with commit-reveal
/// @dev Prevents front-running through multi-phase auctions with griefing protection
contract LiquidationEngine is ILiquidationEngine, ReentrancyGuard {
    using FixedPointMath for uint256;

    /// @notice Minimum time between commit and reveal (prevents immediate reveals)
    uint256 public constant MIN_COMMIT_PERIOD = 1 minutes;

    /// @notice Auction duration after first commit (time window for reveals)
    uint256 public constant AUCTION_DURATION = 10 minutes;

    /// @notice Grace period to finalize auction after reveal period ends
    uint256 public constant FINALIZATION_GRACE_PERIOD = 5 minutes;

    /// @notice Maximum time for commit to remain valid without reveal
    uint256 public constant MAX_COMMIT_PERIOD = 20 minutes;

    /// @notice Total auction timeout (after this, fallback to StabilityPool)
    uint256 public constant TOTAL_AUCTION_TIMEOUT = 30 minutes;

    /// @notice Minimum deposit required to commit (anti-griefing)
    uint256 public constant MIN_DEPOSIT = 0.1 ether;
    
    /// @notice Dynamic deposit multiplier based on debt size (0.1% of debt in ETH)
    /// @dev Assumes ETH price of $2000: 0.1% of debt (USD) / 2000 = ratio
    uint256 public constant DYNAMIC_DEPOSIT_RATIO = 5e11; // 0.1% of debt in USD, converted to ETH at $2000/ETH

    /// @notice Maximum number of bids per auction (DOS prevention)
    uint256 public constant MAX_BIDS_PER_AUCTION = 50;

    /// @notice Liquidation bonus percentage for liquidator (5%)
    uint256 public constant LIQUIDATION_BONUS = 5e16; // 0.05 in WAD

    /// @notice Liquidation penalty for protocol (5%)
    uint256 public constant LIQUIDATION_PENALTY = 5e16; // 0.05 in WAD

    /// @notice Vault manager contract
    IVaultManager public immutable VAULT_MANAGER;

    /// @notice Stablecoin token
    StableToken public immutable STABLE_TOKEN;

    /// @notice Collateral token
    IERC20 public immutable COLLATERAL_TOKEN;

    /// @notice Price oracle
    IPriceOracle public immutable PRICE_ORACLE;

    /// @notice Stability pool for fallback liquidations
    IStabilityPool public immutable STABILITY_POOL;

    /// @notice Mapping of liquidator => vault => commitment
    mapping(address => mapping(address => LiquidationCommit)) public commitments;

    /// @notice Mapping of vault => auction state
    mapping(address => Auction) public auctions;

    /// @notice Mapping of vault => array of revealed bids
    mapping(address => LiquidationBid[]) public vaultBids;

    /// @notice Mapping of liquidator => pending ETH refunds (pull pattern)
    mapping(address => uint256) public pendingRefunds;
    
    /// @notice Total slashed deposits accumulated (protocol revenue)
    uint256 public slashedDepositsTotal;

    /// @notice Error thrown when deposit is insufficient
    error InsufficientDeposit();

    /// @notice Error thrown when commit period requirements not met
    error InvalidCommitPeriod();

    /// @notice Error thrown when commitment hash doesn't match
    error InvalidCommitmentHash();

    /// @notice Error thrown when commitment not found
    error CommitmentNotFound();

    /// @notice Error thrown when commitment already revealed
    error CommitmentAlreadyRevealed();

    /// @notice Error thrown when auction not active
    error AuctionNotActive();

    /// @notice Error thrown when auction still ongoing
    error AuctionStillOngoing();

    /// @notice Error thrown when auction already executed
    error AuctionAlreadyExecuted();

    /// @notice Error thrown when no valid bids exist
    error NoValidBids();

    /// @notice Error thrown when caller is not winner
    error NotWinner();

    /// @notice Error thrown when refund not available
    error NoRefundAvailable();

    /// @notice Error thrown when vault is not liquidatable
    error VaultNotLiquidatable();

    /// @notice Error thrown when liquidator has insufficient stablecoin approval
    error InsufficientStablecoinApproval();

    /// @notice Error thrown when liquidator has insufficient stablecoin balance
    error InsufficientStablecoinBalance();

    /// @notice Error thrown when auction has too many bids
    error TooManyBids();

    /// @notice Error thrown when StabilityPool has insufficient funds
    error InsufficientStabilityPoolFunds();

    /// @notice Emitted when liquidation falls back to StabilityPool
    event FallbackLiquidation(address indexed vault, uint256 debtToOffset, uint256 collateralDistributed);

    /// @notice Emitted when an auction is cancelled due to timeout
    event AuctionCancelled(address indexed vault, string reason);
    
    /// @notice Emitted when refund is added to pending balance
    event RefundAdded(address indexed liquidator, uint256 amount);

    /// @notice Initialize the liquidation engine
    /// @param _vaultManager Address of the vault manager
    /// @param _stableToken Address of the stablecoin
    /// @param _collateralToken Address of the collateral token
    /// @param _priceOracle Address of the price oracle
    /// @param _stabilityPool Address of the stability pool
    constructor(
        address _vaultManager,
        address _stableToken,
        address _collateralToken,
        address _priceOracle,
        address _stabilityPool
    ) {
        VAULT_MANAGER = IVaultManager(_vaultManager);
        STABLE_TOKEN = StableToken(_stableToken);
        COLLATERAL_TOKEN = IERC20(_collateralToken);
        PRICE_ORACLE = IPriceOracle(_priceOracle);
        STABILITY_POOL = IStabilityPool(_stabilityPool);
    }

    /// @inheritdoc ILiquidationEngine
    function commitLiquidation(address vault, bytes32 commitHash) external payable override {
        IVaultManager.Vault memory vaultData = VAULT_MANAGER.getVault(vault);
        uint256 requiredDeposit = _calculateRequiredDeposit(vaultData.debtAmount);
        
        if (msg.value < requiredDeposit) revert InsufficientDeposit();

        // Check if vault is liquidatable
        uint256 healthRatio = VAULT_MANAGER.getHealthRatio(vault);
        if (healthRatio >= 120e16) revert VaultNotLiquidatable(); // LIQUIDATION_THRESHOLD

        LiquidationCommit storage commit = commitments[msg.sender][vault];
        
        // If existing commitment is expired and unrevealed, allow overwrite
        if (commit.commitHash != bytes32(0) && !commit.revealed) {
            if (block.timestamp < commit.commitTime + MAX_COMMIT_PERIOD) {
                revert CommitmentAlreadyRevealed();
            }
            uint256 oldDeposit = commit.deposit;
            slashedDepositsTotal += oldDeposit;
            emit DepositSlashed(msg.sender, vault, oldDeposit);
        }

        commit.commitHash = commitHash;
        commit.commitTime = block.timestamp;
        commit.deposit = msg.value;
        commit.revealed = false;

        // Initialize auction if this is first commit
        Auction storage auction = auctions[vault];
        if (auction.startTime == 0 || auction.executed) {
            auction.startTime = block.timestamp;
            auction.auctionEndTime = block.timestamp + AUCTION_DURATION;
            auction.executed = false;
            auction.winner = address(0);
        }

        emit LiquidationCommitted(msg.sender, vault, commitHash, msg.value);
    }

    /// @inheritdoc ILiquidationEngine
    function revealLiquidation(
        address vault,
        uint256 bidAmount,
        uint256 collateralRequested,
        bytes32 salt
    ) external override nonReentrant {
        LiquidationCommit storage commit = commitments[msg.sender][vault];

        if (commit.commitHash == bytes32(0)) revert CommitmentNotFound();
        if (commit.revealed) revert CommitmentAlreadyRevealed();

        // Check commit period
        uint256 timeSinceCommit = block.timestamp - commit.commitTime;
        if (timeSinceCommit < MIN_COMMIT_PERIOD) revert InvalidCommitPeriod();
        if (timeSinceCommit > MAX_COMMIT_PERIOD) revert InvalidCommitPeriod();

        // Verify commitment hash
        bytes32 computedHash = keccak256(abi.encodePacked(bidAmount, collateralRequested, salt));
        if (computedHash != commit.commitHash) revert InvalidCommitmentHash();

        // Check auction is still active
        Auction storage auction = auctions[vault];
        if (block.timestamp > auction.auctionEndTime) revert AuctionNotActive();
        if (auction.executed) revert AuctionAlreadyExecuted();

        if (vaultBids[vault].length >= MAX_BIDS_PER_AUCTION) revert TooManyBids();

        uint256 allowance = STABLE_TOKEN.allowance(msg.sender, address(this));
        if (allowance < bidAmount) revert InsufficientStablecoinApproval();
        
        uint256 balance = STABLE_TOKEN.balanceOf(msg.sender);
        if (balance < bidAmount) revert InsufficientStablecoinBalance();

        // Mark as revealed
        commit.revealed = true;

        // Add bid to auction
        vaultBids[vault].push(LiquidationBid({
            liquidator: msg.sender,
            bidAmount: bidAmount,
            collateralRequested: collateralRequested,
            revealTime: block.timestamp
        }));

        emit LiquidationRevealed(msg.sender, vault, bidAmount, collateralRequested);
    }

    /// @inheritdoc ILiquidationEngine
    function finalizeAuction(address vault) external override nonReentrant {
        Auction storage auction = auctions[vault];

        // Check auction has ended
        if (block.timestamp <= auction.auctionEndTime) revert AuctionStillOngoing();
        if (auction.executed) revert AuctionAlreadyExecuted();

        // Check if auction has completely timed out - fallback to StabilityPool
        if (block.timestamp > auction.startTime + TOTAL_AUCTION_TIMEOUT) {
            _fallbackToStabilityPool(vault);
            return;
        }

        // Check grace period hasn't expired
        if (block.timestamp > auction.auctionEndTime + FINALIZATION_GRACE_PERIOD) {
            // Grace period expired - allow anyone to finalize
        }

        LiquidationBid[] storage bids = vaultBids[vault];
        if (bids.length == 0) {
            // No bids received - fallback to StabilityPool
            _fallbackToStabilityPool(vault);
            return;
        }

        // Find winning bid: lowest collateralRequested (best for protocol)
        uint256 winningIndex = 0;
        uint256 lowestCollateral = bids[0].collateralRequested;

        for (uint256 i = 1; i < bids.length; i++) {
            if (bids[i].collateralRequested < lowestCollateral) {
                lowestCollateral = bids[i].collateralRequested;
                winningIndex = i;
            }
        }

        LiquidationBid memory winningBid = bids[winningIndex];
        
        // Re-verify liquidator has sufficient funds at finalization time
        uint256 allowance = STABLE_TOKEN.allowance(winningBid.liquidator, address(this));
        if (allowance < winningBid.bidAmount) revert InsufficientStablecoinApproval();
        
        uint256 balance = STABLE_TOKEN.balanceOf(winningBid.liquidator);
        if (balance < winningBid.bidAmount) revert InsufficientStablecoinBalance();
        
        auction.winner = winningBid.liquidator;
        auction.executed = true;

        // Execute liquidation
        _executeLiquidation(vault, winningBid.bidAmount, winningBid.collateralRequested, winningBid.liquidator);

        LiquidationCommit storage winnerCommit = commitments[winningBid.liquidator][vault];
        uint256 refundAmount = winnerCommit.deposit;
        winnerCommit.deposit = 0;
        
        if (refundAmount > 0) {
            pendingRefunds[winningBid.liquidator] += refundAmount;
            emit RefundAdded(winningBid.liquidator, refundAmount);
        }

        emit AuctionFinalized(vault, winningBid.liquidator, winningBid.bidAmount, winningBid.collateralRequested);
    }

    /// @inheritdoc ILiquidationEngine
    function claimRefund(address vault) external override nonReentrant {
        LiquidationCommit storage commit = commitments[msg.sender][vault];
        
        if (commit.deposit == 0) revert NoRefundAvailable();

        Auction storage auction = auctions[vault];
        
        // Can claim if:
        // 1. Revealed, auction executed, and caller is not winner
        // 2. Revealed, auction expired without finalization
        // Cannot claim if commitment expired without reveal (griefing - deposit slashed)
        
        bool canClaim = false;
        
        // Check if commitment expired without reveal first (griefing case)
        if (!commit.revealed && block.timestamp > commit.commitTime + MAX_COMMIT_PERIOD) {
            uint256 slashedAmount = commit.deposit;
            commit.deposit = 0;
            
            // Track slashed deposits as protocol revenue
            slashedDepositsTotal += slashedAmount;
            
            emit DepositSlashed(msg.sender, vault, slashedAmount);
            // Slashed deposits stay in contract as protocol revenue
            return;
        }
        
        // Only revealed commitments can claim refunds
        if (commit.revealed) {
            if (auction.executed && auction.winner != msg.sender) {
                canClaim = true;
            } else if (block.timestamp > auction.auctionEndTime + FINALIZATION_GRACE_PERIOD) {
                canClaim = true;
            }
        }

        if (!canClaim) revert NoRefundAvailable();

        uint256 refundAmount = commit.deposit;
        commit.deposit = 0;

        pendingRefunds[msg.sender] += refundAmount;
        emit RefundAdded(msg.sender, refundAmount);
        emit DepositRefunded(msg.sender, refundAmount);
    }

    /// @inheritdoc ILiquidationEngine
    function getCommitment(address liquidator, address vault)
        external
        view
        override
        returns (LiquidationCommit memory commit)
    {
        return commitments[liquidator][vault];
    }

    /// @inheritdoc ILiquidationEngine
    function getAuction(address vault) external view override returns (Auction memory auction) {
        return auctions[vault];
    }

    /// @inheritdoc ILiquidationEngine
    function calculateLiquidation(address vault, uint256 debtToRepay)
        external
        view
        override
        returns (uint256 collateralToSeize, uint256 liquidationBonus)
    {
        IVaultManager.Vault memory vaultData = VAULT_MANAGER.getVault(vault);

        if (vaultData.debtAmount == 0) return (0, 0);

        // Cap at maximum liquidation ratio (50% of debt)
        uint256 maxLiquidatableDebt = vaultData.debtAmount.wadMul(50e16); // 50%
        if (debtToRepay > maxLiquidatableDebt) {
            debtToRepay = maxLiquidatableDebt;
        }

        // Get collateral price with TWAP for manipulation resistance
        uint256 collateralPrice;
        try PRICE_ORACLE.getTWAP(address(COLLATERAL_TOKEN), 1 hours) returns (uint256 twapPrice) {
            collateralPrice = twapPrice;
        } catch {
            // If TWAP unavailable, revert - do NOT fall back to spot price
            revert("TWAP unavailable");
        }

        // Convert price from 8 decimals to WAD (18 decimals)
        uint256 collateralPriceWad = collateralPrice.priceToWad();

        // Calculate base collateral needed for debt (in USD terms)
        // collateralAmount = debtToRepay / price
        uint256 baseCollateral = debtToRepay.wadDiv(collateralPriceWad);

        liquidationBonus = baseCollateral.wadMul(LIQUIDATION_BONUS);
        uint256 liquidationPenalty = baseCollateral.wadMul(LIQUIDATION_PENALTY);
        
        // Total collateral seized from vault (includes both bonus and penalty)
        uint256 totalSeized = baseCollateral + liquidationBonus + liquidationPenalty;
        collateralToSeize = baseCollateral + liquidationBonus; // Amount to liquidator

        // Cap at available collateral
        if (totalSeized > vaultData.collateralAmount) {
            uint256 ratio = vaultData.collateralAmount.wadDiv(totalSeized);
            collateralToSeize = collateralToSeize.wadMul(ratio);
            liquidationBonus = (collateralToSeize > baseCollateral.wadMul(ratio)) 
                ? collateralToSeize - baseCollateral.wadMul(ratio) 
                : 0;
        }
    }

    /// @notice Generate commitment hash for off-chain use
    /// @param bidAmount Amount of debt to repay
    /// @param collateralRequested Collateral amount requested
    /// @param salt Random salt for commitment
    /// @return commitHash The commitment hash
    function generateCommitHash(uint256 bidAmount, uint256 collateralRequested, bytes32 salt)
        external
        pure
        returns (bytes32 commitHash)
    {
        return keccak256(abi.encodePacked(bidAmount, collateralRequested, salt));
    }

    /// @notice Check if a vault is liquidatable
    /// @param vault Address of the vault
    /// @return liquidatable True if vault can be liquidated
    function isLiquidatable(address vault) external view returns (bool liquidatable) {
        uint256 healthRatio = VAULT_MANAGER.getHealthRatio(vault);
        return healthRatio < 120e16; // LIQUIDATION_THRESHOLD from VaultManager
    }

    /// @notice Get all bids for a vault
    /// @param vault Address of the vault
    /// @return bids Array of all bids
    function getVaultBids(address vault) external view returns (LiquidationBid[] memory bids) {
        return vaultBids[vault];
    }

    /// @notice Manually cancel an auction and trigger StabilityPool fallback
    /// @param vault Address of the vault
    /// @dev Can be called by anyone if auction has timed out
    function cancelAuctionAndFallback(address vault) external nonReentrant {
        Auction storage auction = auctions[vault];
        
        // Require auction to be significantly timed out
        if (block.timestamp <= auction.startTime + TOTAL_AUCTION_TIMEOUT) {
            revert AuctionStillOngoing();
        }
        
        if (auction.executed) revert AuctionAlreadyExecuted();
        
        _fallbackToStabilityPool(vault);
    }

    /// @notice Clean up old auction data to free storage
    /// @param vault Address of the vault
    function cleanupAuction(address vault) external {
        Auction storage auction = auctions[vault];
        
        // Only cleanup executed or very old auctions
        require(
            auction.executed || block.timestamp > auction.startTime + TOTAL_AUCTION_TIMEOUT + 1 days,
            "Auction not ready for cleanup"
        );
        
        // Clear bids array to refund gas
        delete vaultBids[vault];
        
        emit AuctionCancelled(vault, "Cleanup");
    }

    /// @notice Withdraw pending refunds (pull pattern)
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "No pending refund");
        
        pendingRefunds[msg.sender] = 0;
        
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    /// @notice Calculate required deposit for auction participation
    /// @param debtAmount Debt amount of the vault being liquidated
    /// @return requiredDeposit Minimum deposit required
    function _calculateRequiredDeposit(uint256 debtAmount) internal pure returns (uint256 requiredDeposit) {
        // Base minimum deposit
        requiredDeposit = MIN_DEPOSIT;
        
        // Add dynamic component: 0.1% of debt (assuming ~$2000 ETH price)
        // debtAmount is in stablecoins (18 decimals), convert to ETH equivalent
        uint256 dynamicDeposit = (debtAmount * DYNAMIC_DEPOSIT_RATIO) / 1e18;
        
        // Use higher of minimum or dynamic
        if (dynamicDeposit > requiredDeposit) {
            requiredDeposit = dynamicDeposit;
        }
    }
    
    /// @notice Get required deposit for a specific vault
    /// @param vault Address of the vault
    /// @return requiredDeposit Minimum deposit required to participate
    function getRequiredDeposit(address vault) external view returns (uint256 requiredDeposit) {
        IVaultManager.Vault memory vaultData = VAULT_MANAGER.getVault(vault);
        return _calculateRequiredDeposit(vaultData.debtAmount);
    }

    /// @notice Execute the liquidation via auction
    /// @param vault Address of the vault to liquidate
    /// @param debtToRepay Amount of debt to repay
    /// @param collateralRequested Collateral requested by liquidator
    /// @param liquidator Address of the liquidator
    function _executeLiquidation(
        address vault,
        uint256 debtToRepay,
        uint256 collateralRequested,
        address liquidator
    ) internal {
        // Transfer stablecoins from liquidator
        STABLE_TOKEN.transferFrom(liquidator, address(this), debtToRepay);

        // Burn the stablecoins
        STABLE_TOKEN.burn(address(this), debtToRepay);

        // Execute liquidation through vault manager
        uint256 collateralSeized = VAULT_MANAGER.liquidate(vault, debtToRepay);

        // Ensure we don't give more than requested (winner's bid constraint)
        if (collateralSeized > collateralRequested) {
            collateralSeized = collateralRequested;
            
            uint256 excess = collateralSeized - collateralRequested;
            if (excess > 0) {
                COLLATERAL_TOKEN.transfer(vault, excess);
            }
        }

        // Transfer seized collateral to liquidator
        COLLATERAL_TOKEN.transfer(liquidator, collateralSeized);
    }

    /// @notice Fallback to StabilityPool liquidation when auction fails
    /// @param vault Address of the vault to liquidate
    function _fallbackToStabilityPool(address vault) internal {
        Auction storage auction = auctions[vault];
        
        // Mark auction as executed to prevent re-entry
        auction.executed = true;
        
        // SAFETY CHECK: If no StabilityPool configured, cancel auction
        if (address(STABILITY_POOL) == address(0)) {
            emit AuctionCancelled(vault, "No StabilityPool configured");
            return;
        }
        
        // Get vault data
        IVaultManager.Vault memory vaultData = VAULT_MANAGER.getVault(vault);
        
        if (vaultData.debtAmount == 0) {
            emit AuctionCancelled(vault, "No debt");
            return;
        }
        
        // Check if vault is still liquidatable
        uint256 healthRatio = VAULT_MANAGER.getHealthRatio(vault);
        if (healthRatio >= 120e16) {
            emit AuctionCancelled(vault, "Vault healthy");
            return;
        }
        
        // Check if StabilityPool has sufficient funds
        uint256 stabilityPoolBalance = STABILITY_POOL.getTotalDeposits();
        if (stabilityPoolBalance == 0) {
            // No funds in StabilityPool - auction stuck, emit event for manual intervention
            emit AuctionCancelled(vault, "No StabilityPool funds");
            return;
        }
        
        // Calculate maximum liquidatable debt (50% of total debt)
        uint256 maxDebt = vaultData.debtAmount * 50 / 100;
        uint256 debtToOffset = maxDebt < stabilityPoolBalance ? maxDebt : stabilityPoolBalance;
        
        // Execute liquidation through vault manager
        uint256 collateralSeized = VAULT_MANAGER.liquidate(vault, debtToOffset);
        
        // Transfer collateral to this contract first
        // (VaultManager already transferred it in liquidate() call, so we receive it)
        
        // Approve StabilityPool to take collateral
        COLLATERAL_TOKEN.approve(address(STABILITY_POOL), collateralSeized);
        
        // Distribute to StabilityPool depositors
        STABILITY_POOL.distributeLiquidation(debtToOffset, collateralSeized);
        
        emit FallbackLiquidation(vault, debtToOffset, collateralSeized);
    }
}
