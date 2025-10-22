// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IStabilityPool} from "./interfaces/IStabilityPool.sol";
import {StableToken} from "./StableToken.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title StabilityPool
/// @notice Pool for absorbing liquidated debt and distributing collateral to depositors
/// @dev Depositors provide stablecoins and earn collateral from liquidations
contract StabilityPool is IStabilityPool, ReentrancyGuard, Ownable, Pausable {
    using FixedPointMath for uint256;

    /// @notice Stablecoin token
    StableToken public immutable STABLE_TOKEN;

    /// @notice Collateral token
    IERC20 public immutable COLLATERAL_TOKEN;

    /// @notice Total stablecoins deposited in the pool
    uint256 public totalDeposits;

    /// @notice Collateral gains per unit of deposit (scaled by 1e18)
    uint256 public collateralGainsPerUnitStaked;

    /// @notice Product of (1 - debt_loss/total_deposits) for each liquidation
    /// @dev Used to calculate compounded deposit after losses. Starts at 1e18 (100%)
    uint256 public P = 1e18;

    /// @notice Mapping of depositor => deposit info
    mapping(address => Deposit) public deposits;

    /// @notice Mapping of depositor => snapshot of gains per unit staked
    mapping(address => uint256) public depositSnapshots;

    /// @notice Mapping of depositor => snapshot of P at time of deposit
    mapping(address => uint256) public depositPSnapshots;

    /// @notice Authorized liquidation engine
    address public liquidationEngine;

    /// @notice Error thrown when amount is zero
    error ZeroAmount();

    /// @notice Error thrown when insufficient balance
    error InsufficientBalance();

    /// @notice Error thrown when caller is not liquidation engine
    error NotLiquidationEngine();

    /// @notice Error thrown when total deposits is zero
    error NoDeposits();

    /// @notice Initialize the stability pool
    /// @param _stableToken Address of the stablecoin
    /// @param _collateralToken Address of the collateral token
    constructor(address _stableToken, address _collateralToken) Ownable(msg.sender) {
        STABLE_TOKEN = StableToken(_stableToken);
        COLLATERAL_TOKEN = IERC20(_collateralToken);
    }

    /// @notice Modifier to restrict access to liquidation engine
    modifier onlyLiquidationEngine() {
        if (msg.sender != liquidationEngine) revert NotLiquidationEngine();
        _;
    }

    /// @inheritdoc IStabilityPool
    function deposit(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Update depositor's gains and compounded deposit before modifying
        _updateDepositorGains(msg.sender);

        uint256 compoundedDeposit = _getCompoundedDeposit(msg.sender);
        
        // Reset deposit to compounded amount, then add new deposit
        deposits[msg.sender].amount = compoundedDeposit + amount;
        deposits[msg.sender].timestamp = block.timestamp;
        totalDeposits += amount;

        // Update snapshots
        depositSnapshots[msg.sender] = collateralGainsPerUnitStaked;
        depositPSnapshots[msg.sender] = P;

        STABLE_TOKEN.transferFrom(msg.sender, address(this), amount);

        emit StablecoinsDeposited(msg.sender, amount);
    }

    /// @inheritdoc IStabilityPool
    function withdraw(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Update depositor's gains and get compounded deposit
        _updateDepositorGains(msg.sender);
        
        uint256 compoundedDeposit = _getCompoundedDeposit(msg.sender);
        if (amount > compoundedDeposit) revert InsufficientBalance();

        // Update deposit amount
        deposits[msg.sender].amount = compoundedDeposit - amount;
        totalDeposits -= amount;

        // Update snapshots
        depositSnapshots[msg.sender] = collateralGainsPerUnitStaked;
        depositPSnapshots[msg.sender] = P;

        STABLE_TOKEN.transfer(msg.sender, amount);

        emit StablecoinsWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IStabilityPool
    function claimCollateralGains() external override nonReentrant whenNotPaused {
        _updateDepositorGains(msg.sender);

        uint256 compoundedDeposit = _getCompoundedDeposit(msg.sender);
        deposits[msg.sender].amount = compoundedDeposit;

        Deposit storage userDeposit = deposits[msg.sender];
        uint256 collateralGain = userDeposit.collateralGain;

        if (collateralGain == 0) revert ZeroAmount();

        userDeposit.collateralGain = 0;
        depositSnapshots[msg.sender] = collateralGainsPerUnitStaked;
        depositPSnapshots[msg.sender] = P;

        COLLATERAL_TOKEN.transfer(msg.sender, collateralGain);

        emit CollateralGainsClaimed(msg.sender, collateralGain);
    }

    /// @inheritdoc IStabilityPool
    function distributeLiquidation(uint256 debtToOffset, uint256 collateralToDistribute)
        external
        override
        onlyLiquidationEngine
    {
        if (totalDeposits == 0) revert NoDeposits();

        // Cap debt offset at total deposits
        if (debtToOffset > totalDeposits) {
            debtToOffset = totalDeposits;
        }

        // Calculate and update collateral gains BEFORE reducing deposits
        uint256 collateralGainPerUnitStaked = collateralToDistribute.wadDiv(totalDeposits);
        collateralGainsPerUnitStaked += collateralGainPerUnitStaked;

        // Update P to reflect compounding loss
        // P = P * (1 - debtToOffset/totalDeposits)
        // This tracks the cumulative effect of liquidation losses
        if (debtToOffset > 0) {
            uint256 lossRatio = debtToOffset.wadDiv(totalDeposits);
            P = P.wadMul(1e18 - lossRatio);
        }

        // Now reduce total deposits
        totalDeposits -= debtToOffset;

        // Burn the offset debt
        STABLE_TOKEN.burn(address(this), debtToOffset);

        emit LiquidationDistributed(debtToOffset, collateralToDistribute);
    }

    /// @inheritdoc IStabilityPool
    function getDeposit(address depositor) external view override returns (Deposit memory userDeposit) {
        userDeposit = deposits[depositor];
        
        uint256 compoundedAmount = _getCompoundedDepositView(depositor);
        userDeposit.amount = compoundedAmount;
        
        // Calculate pending collateral gains
        uint256 gainsSinceSnapshot = collateralGainsPerUnitStaked - depositSnapshots[depositor];
        uint256 pendingGains = compoundedAmount.wadMul(gainsSinceSnapshot);
        
        userDeposit.collateralGain += pendingGains;
        
        return userDeposit;
    }

    /// @inheritdoc IStabilityPool
    function getTotalDeposits() external view override returns (uint256 total) {
        return totalDeposits;
    }

    /// @notice Set the liquidation engine address
    /// @param _liquidationEngine Address of the liquidation engine
    function setLiquidationEngine(address _liquidationEngine) external onlyOwner {
        liquidationEngine = _liquidationEngine;
    }

    /// @notice Pause the contract (emergency use only)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Get pending collateral gains for a depositor
    /// @param depositor Address of the depositor
    /// @return pendingGains Amount of pending collateral gains
    function getPendingCollateralGains(address depositor) external view returns (uint256 pendingGains) {
        Deposit memory userDeposit = deposits[depositor];
        uint256 gainsSinceSnapshot = collateralGainsPerUnitStaked - depositSnapshots[depositor];
        return userDeposit.amount.wadMul(gainsSinceSnapshot);
    }

    /// @notice Update depositor's accumulated gains
    /// @param depositor Address of the depositor
    function _updateDepositorGains(address depositor) internal {
        Deposit storage userDeposit = deposits[depositor];
        
        if (userDeposit.amount == 0) return;

        uint256 compoundedDeposit = _getCompoundedDeposit(depositor);
        
        uint256 gainsSinceSnapshot = collateralGainsPerUnitStaked - depositSnapshots[depositor];
        uint256 newGains = compoundedDeposit.wadMul(gainsSinceSnapshot);
        
        userDeposit.collateralGain += newGains;
    }

    /// @notice Calculate compounded deposit after accounting for liquidation losses
    /// @param depositor Address of the depositor
    /// @return compoundedDeposit The depositor's compounded deposit amount
    /// @dev Non-view version for state-changing operations
    function _getCompoundedDeposit(address depositor) internal view returns (uint256 compoundedDeposit) {
        uint256 initialDeposit = deposits[depositor].amount;
        if (initialDeposit == 0) return 0;

        uint256 snapshotP = depositPSnapshots[depositor];
        if (snapshotP == 0) return initialDeposit; // First deposit, no losses yet

        // Compounded deposit = initial_deposit * (current_P / snapshot_P)
        // This accounts for all liquidation losses since the deposit
        compoundedDeposit = initialDeposit.wadMul(P.wadDiv(snapshotP));
    }

    /// @notice Calculate compounded deposit (view-only version)
    /// @param depositor Address of the depositor
    /// @return compoundedDeposit The depositor's compounded deposit amount
    function _getCompoundedDepositView(address depositor) internal view returns (uint256 compoundedDeposit) {
        uint256 initialDeposit = deposits[depositor].amount;
        if (initialDeposit == 0) return 0;

        uint256 snapshotP = depositPSnapshots[depositor];
        if (snapshotP == 0) return initialDeposit;

        compoundedDeposit = initialDeposit.wadMul(P.wadDiv(snapshotP));
    }
}

