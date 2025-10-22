// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IYieldToken} from "./interfaces/IYieldToken.sol";
import {StableToken} from "./StableToken.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {EmergencyGuardian} from "./governance/EmergencyGuardian.sol";

/// @title VaultManager
/// @notice Core vault management contract for collateralized debt positions
/// @dev Manages yield-bearing collateral and debt positions with automatic yield accrual
contract VaultManager is IVaultManager, ReentrancyGuard, Ownable, Pausable {
    using FixedPointMath for uint256;

    /// @notice Minimum collateralization ratio (150%)
    uint256 public constant MIN_COLLATERAL_RATIO = 150e16; // 1.5 in WAD

    /// @notice Liquidation threshold (120%)
    uint256 public constant LIQUIDATION_THRESHOLD = 120e16; // 1.2 in WAD

    /// @notice Maximum loan-to-value ratio (80%)
    uint256 public constant MAX_LTV = 80e16; // 0.8 in WAD

    /// @notice Maximum liquidation ratio (50% of debt can be liquidated at once)
    uint256 public constant MAX_LIQUIDATION_RATIO = 50e16; // 0.5 in WAD

    /// @notice Liquidation penalty paid by borrower to protocol (5%)
    uint256 public constant LIQUIDATION_PENALTY = 5e16; // 0.05 in WAD

    /// @notice Liquidation bonus paid to liquidator (5%)
    uint256 public constant LIQUIDATION_BONUS = 5e16; // 0.05 in WAD

    /// @notice TWAP period for liquidation price checks (1 hour)
    uint256 public constant TWAP_PERIOD = 1 hours;

    /// @notice Maximum yield accrual period to prevent DOS (1 year) - deprecated but kept for safety checks
    uint256 public constant MAX_ACCRUAL_PERIOD = 365 days;

    /// @notice Minimum time between borrow operations (flash loan protection)
    uint256 public constant MIN_BORROW_DELAY = 1;

    /// @notice Minimum debt amount to prevent dust attacks (100 stablecoins)
    uint256 public constant MIN_DEBT = 100e18;
    
    /// @notice Grace period after interest accrual before liquidation allowed (1 hour)
    uint256 public constant LIQUIDATION_GRACE_PERIOD = 1 hours;

    /// @notice Base borrow APR (5% annual)
    uint256 public borrowAPR = 5e16; // 0.05 in WAD (5%)

    /// @notice Protocol fee on interest (10% of interest goes to protocol)
    uint256 public constant PROTOCOL_FEE = 10e16; // 0.1 in WAD (10%)

    /// @notice Seconds per year for interest calculations
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Protocol reserve in stablecoins (from interest fees)
    uint256 public protocolReserveStable;
    
    /// @notice Protocol reserve in collateral (from liquidation penalties)
    uint256 public protocolReserveCollateral;

    /// @notice Bad debt accumulated from failed liquidations
    uint256 public badDebt;

    /// @notice Total debt across all vaults (tracking for economic health)
    uint256 public totalSystemDebt;

    /// @notice Yield-bearing collateral token adapter (e.g., wstETH, rETH adapter)
    /// @dev Adapter handles exchange rate queries for real yield tracking
    IYieldToken public immutable COLLATERAL_TOKEN;
    
    /// @notice Underlying collateral token for compatibility
    IERC20 private immutable UNDERLYING_TOKEN;

    /// @notice Stablecoin token
    StableToken public immutable STABLE_TOKEN;

    /// @notice Price oracle
    IPriceOracle public immutable PRICE_ORACLE;

    /// @notice Liquidation engine address
    address public liquidationEngine;

    /// @notice Emergency guardian contract
    EmergencyGuardian public emergencyGuardian;

    /// @notice Mapping of user => vault
    mapping(address => Vault) public vaults;

    /// @notice Mapping of user => last borrow block (flash loan protection)
    mapping(address => uint256) public lastBorrowBlock;
    
    /// @notice Mapping of user => last interest accrual timestamp
    mapping(address => uint256) public lastInterestAccrual;
    
    /// @notice Mapping of user => last liquidation timestamp
    mapping(address => uint256) public lastLiquidationTime;
    
    /// @notice Minimum time between liquidations of the same vault (10 minutes)
    uint256 public constant LIQUIDATION_COOLDOWN = 10 minutes;

    /// @notice Error thrown when collateral ratio is too low
    error InsufficientCollateralRatio();
    
    /// @notice Error thrown when attempting to liquidate during cooldown period
    error LiquidationInCooldown();

    /// @notice Error thrown when trying to withdraw too much collateral
    error ExcessiveWithdrawal();

    /// @notice Error thrown when vault is not liquidatable
    error VaultNotLiquidatable();

    /// @notice Error thrown when amount is zero
    error ZeroAmount();

    /// @notice Error thrown when caller is not liquidation engine
    error NotLiquidationEngine();

    /// @notice Error thrown when parameter is out of bounds
    error ParameterOutOfBounds();

    /// @notice Error thrown when borrow too soon (flash loan protection)
    error BorrowTooSoon();

    /// @notice Error thrown when TWAP is unavailable
    error TWAPUnavailable();

    /// @notice Error thrown when debt is below minimum
    error DebtBelowMinimum();

    /// @notice Error thrown when APR is out of valid range
    error InvalidAPR();
    
    /// @notice Error thrown when liquidation attempted during grace period
    error LiquidationInGracePeriod();

    /// @notice Emitted when liquidation engine is set
    event LiquidationEngineSet(address indexed liquidationEngine);

    /// @notice Emitted when borrow APR is updated
    event BorrowAPRUpdated(uint256 oldAPR, uint256 newAPR);

    /// @notice Emitted when protocol reserves are withdrawn
    event ProtocolReservesWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when bad debt is recorded
    event BadDebtRecorded(address indexed vault, uint256 amount);

    /// @notice Emitted when bad debt is covered by reserves
    event BadDebtCovered(uint256 amount);

    /// @notice Emitted when liquidation penalty is collected
    event LiquidationPenaltyCollected(address indexed vault, uint256 penaltyAmount);

    /// @notice Initialize the vault manager
    /// @param _collateralToken Address of the yield-bearing collateral token adapter (IYieldToken)
    /// @param _stableToken Address of the stablecoin
    /// @param _priceOracle Address of the price oracle
    /// @dev CRITICAL ORACLE REQUIREMENTS:
    ///      The price oracle MUST price the WRAPPER token (e.g., wstETH, rETH) directly, NOT the underlying.
    ///      
    ///      ✅ CORRECT: Use wstETH/USD price feed (includes exchange rate appreciation)
    ///      ❌ WRONG:   Use stETH/USD price feed for wstETH collateral (misses yield)
    ///      
    ///      Why: Wrapper tokens like wstETH have increasing exchange rates. The wrapper price
    ///      naturally reflects both the underlying asset value AND the accrued yield.
    ///      
    ///      Example: If wstETH = 1.1 stETH, and stETH = $2000, then wstETH price should be $2200.
    ///      Chainlink provides wstETH/USD feeds that do this correctly.
    ///      
    ///      This ensures yield automatically improves vault health ratios without needing to
    ///      manually update collateral amounts in storage.
    constructor(address _collateralToken, address _stableToken, address _priceOracle) Ownable(msg.sender) {
        COLLATERAL_TOKEN = IYieldToken(_collateralToken);
        UNDERLYING_TOKEN = IERC20(_collateralToken); // Adapter also implements IERC20
        STABLE_TOKEN = StableToken(_stableToken);
        PRICE_ORACLE = IPriceOracle(_priceOracle);
    }

    /// @notice Modifier to restrict access to liquidation engine
    modifier onlyLiquidationEngine() {
        if (msg.sender != liquidationEngine) revert NotLiquidationEngine();
        _;
    }

    /// @notice Modifier to check circuit breaker status
    modifier whenCircuitBreakerNotTripped() {
        if (address(emergencyGuardian) != address(0)) {
            require(!emergencyGuardian.isCircuitBreakerActive(), "Circuit breaker tripped");
        }
        _;
    }

    /// @inheritdoc IVaultManager
    function depositCollateral(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Cache storage pointer
        Vault storage vault = vaults[msg.sender];

        // Accrue yield before modifying vault
        _accrueYieldInternal(vault);

        vault.collateralAmount += amount;
        vault.lastAccrualTimestamp = block.timestamp;

        COLLATERAL_TOKEN.transferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(msg.sender, amount);
    }

    /// @inheritdoc IVaultManager
    function withdrawCollateral(uint256 amount) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        whenCircuitBreakerNotTripped 
    {
        if (amount == 0) revert ZeroAmount();

        // Cache storage pointer for optimized access
        Vault storage vault = vaults[msg.sender];
        
        // Accrue yield and interest before modifying vault
        _accrueYieldInternal(vault);
        _accrueInterest(vault);

        if (amount > vault.collateralAmount) revert ExcessiveWithdrawal();
        
        // Cache values for single SLOAD
        uint256 cachedCollateral = vault.collateralAmount - amount;
        uint256 cachedDebt = vault.debtAmount;
        
        vault.collateralAmount = cachedCollateral;
        vault.lastAccrualTimestamp = block.timestamp;

        // Check collateral ratio after withdrawal
        if (cachedDebt > 0) {
            uint256 healthRatio = _calculateHealthRatio(cachedCollateral, cachedDebt, true);
            if (healthRatio < MIN_COLLATERAL_RATIO) revert InsufficientCollateralRatio();
        }

        COLLATERAL_TOKEN.transfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IVaultManager
    function borrow(uint256 amount) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        whenCircuitBreakerNotTripped 
    {
        if (amount == 0) revert ZeroAmount();

        // Flash loan protection: Prevent borrowing in same block as previous borrow
        // Allow first borrow (lastBorrowBlock[msg.sender] == 0)
        if (lastBorrowBlock[msg.sender] != 0 && block.number - lastBorrowBlock[msg.sender] < MIN_BORROW_DELAY) {
            revert BorrowTooSoon();
        }
        lastBorrowBlock[msg.sender] = block.number;

        // Cache storage pointer for optimized access
        Vault storage vault = vaults[msg.sender];

        // Accrue yield and interest before modifying vault
        _accrueYieldInternal(vault);
        _accrueInterest(vault);

        uint256 newDebt = vault.debtAmount + amount;
        
        if (newDebt < MIN_DEBT) revert DebtBelowMinimum();
        
        vault.debtAmount = newDebt;
        vault.lastAccrualTimestamp = block.timestamp;
        
        // Update total system debt
        totalSystemDebt += amount;

        // Check collateral ratio using TWAP (flash loan protection)
        uint256 healthRatio = _calculateHealthRatio(vault.collateralAmount, newDebt, true);
        if (healthRatio < MIN_COLLATERAL_RATIO) revert InsufficientCollateralRatio();

        STABLE_TOKEN.mint(msg.sender, amount);

        emit DebtBorrowed(msg.sender, amount);
    }

    /// @inheritdoc IVaultManager
    function repay(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Cache storage pointer for optimized access
        Vault storage vault = vaults[msg.sender];

        // Accrue yield and interest before modifying vault
        _accrueYieldInternal(vault);
        _accrueInterest(vault);
        
        uint256 cachedDebt = vault.debtAmount;
        
        if (amount > cachedDebt) {
            amount = cachedDebt;
        }

        uint256 remainingDebt = cachedDebt - amount;
        
        if (remainingDebt > 0 && remainingDebt < MIN_DEBT) revert DebtBelowMinimum();
        
        vault.debtAmount = remainingDebt;
        vault.lastAccrualTimestamp = block.timestamp;
        
        // Update total system debt
        if (amount <= totalSystemDebt) {
            totalSystemDebt -= amount;
        } else {
            totalSystemDebt = 0;
        }

        STABLE_TOKEN.burn(msg.sender, amount);

        emit DebtRepaid(msg.sender, amount);
    }

    /// @inheritdoc IVaultManager
    function accrueYield(address user) public override {
        Vault storage vault = vaults[user];
        // Accrue interest BEFORE yield accrual updates timestamp
        _accrueInterest(vault);
        _accrueYieldInternal(vault);
    }

    /// @inheritdoc IVaultManager
    function getHealthRatio(address user) external view override returns (uint256 healthRatio) {
        Vault memory vault = vaults[user];
        
        if (vault.debtAmount == 0) {
            return type(uint256).max;
        }

        // For yield-bearing tokens, we price the wrapper token directly
        // The wrapper token's price (e.g., wstETH) naturally increases as yield accrues
        // Exchange rate is tracked for transparency but pricing uses wrapper amount
        uint256 currentCollateral = vault.collateralAmount;

        // View function: Try TWAP first, fallback to spot for backward compatibility
        // Note: View functions don't affect state, so graceful degradation is acceptable
        // State-changing functions (borrow, withdraw) enforce strict TWAP
        try PRICE_ORACLE.getTWAP(address(COLLATERAL_TOKEN), TWAP_PERIOD) returns (uint256) {
            return _calculateHealthRatio(currentCollateral, vault.debtAmount, true);
        } catch {
            // TWAP unavailable in view - use spot price for display purposes only
            return _calculateHealthRatio(currentCollateral, vault.debtAmount, false);
        }
    }

    /// @inheritdoc IVaultManager
    function getVault(address user) external view override returns (Vault memory vault) {
        return vaults[user];
    }

    /// @notice Liquidate an undercollateralized vault
    /// @param user Address of the vault owner
    /// @param debtToRepay Amount of debt to repay
    /// @return collateralSeized Amount of collateral seized (sent to liquidator)
    function liquidate(address user, uint256 debtToRepay)
        external
        onlyLiquidationEngine
        nonReentrant
        returns (uint256 collateralSeized)
    {
        Vault storage vault = vaults[user];

        if (lastLiquidationTime[user] > 0 && 
            block.timestamp < lastLiquidationTime[user] + LIQUIDATION_COOLDOWN) {
            revert LiquidationInCooldown();
        }

        if (lastInterestAccrual[user] > 0 && 
            block.timestamp < lastInterestAccrual[user] + LIQUIDATION_GRACE_PERIOD) {
            revert LiquidationInGracePeriod();
        }

        // Accrue yield and interest first
        _accrueYieldInternal(vault);
        uint256 debtBefore = vault.debtAmount;
        _accrueInterest(vault);
        uint256 interestAccrued = vault.debtAmount - debtBefore;
        
        // Track interest accrual for grace period
        if (interestAccrued > 0) {
            _updateInterestAccrualTracking(user, interestAccrued);
        }

        // Cache debt for checks
        uint256 cachedDebt = vault.debtAmount;
        if (cachedDebt == 0) revert VaultNotLiquidatable();

        // Verify liquidation threshold
        uint256 healthRatio = _calculateHealthRatio(vault.collateralAmount, cachedDebt, true);
        if (healthRatio >= LIQUIDATION_THRESHOLD) revert VaultNotLiquidatable();

        // Cap liquidation at 50% of total debt
        if (debtToRepay > cachedDebt.wadMul(MAX_LIQUIDATION_RATIO)) {
            debtToRepay = cachedDebt.wadMul(MAX_LIQUIDATION_RATIO);
        }

        (uint256 liquidatorCollateral, uint256 penaltyCollateral) = 
            _calculateCollateralToSeize(debtToRepay, vault.collateralAmount);
        
        uint256 totalCollateralSeized = liquidatorCollateral + penaltyCollateral;
        collateralSeized = liquidatorCollateral; // Return amount for liquidator

        // Update vault state and handle bad debt
        _updateVaultAfterLiquidation(vault, user, totalCollateralSeized, debtToRepay, penaltyCollateral);
        
        lastLiquidationTime[user] = block.timestamp;

        // External call last (CEI pattern)
        COLLATERAL_TOKEN.transfer(msg.sender, collateralSeized);

        return collateralSeized;
    }

    /// @notice Set the liquidation engine address
    /// @param _liquidationEngine Address of the liquidation engine
    function setLiquidationEngine(address _liquidationEngine) external onlyOwner {
        if (_liquidationEngine == address(0)) revert ParameterOutOfBounds();
        liquidationEngine = _liquidationEngine;
        emit LiquidationEngineSet(_liquidationEngine);
    }

    /// @notice Set the emergency guardian contract
    /// @param _emergencyGuardian Address of the emergency guardian
    function setEmergencyGuardian(address _emergencyGuardian) external onlyOwner {
        if (_emergencyGuardian == address(0)) revert ParameterOutOfBounds();
        emergencyGuardian = EmergencyGuardian(_emergencyGuardian);
    }

    /// @notice Pause the contract (emergency use only)
    /// @dev Can be called by owner or guardian for rapid response
    function pause() external {
        require(
            msg.sender == owner() || 
            (address(emergencyGuardian) != address(0) && msg.sender == emergencyGuardian.guardian()),
            "Not authorized"
        );
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Only owner can unpause to prevent guardian abuse
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the borrow APR
    /// @param newAPR New annual percentage rate (in WAD, e.g., 5e16 = 5%)
    function setBorrowAPR(uint256 newAPR) external onlyOwner {
        if (newAPR > 20e16) revert InvalidAPR(); // Max 20% APR
        
        uint256 maxChange = 5e16; // 5% maximum change
        if (borrowAPR > 0) {
            uint256 change = newAPR > borrowAPR ? newAPR - borrowAPR : borrowAPR - newAPR;
            require(change <= maxChange, "APR change too large");
        }
        
        uint256 oldAPR = borrowAPR;
        borrowAPR = newAPR;
        emit BorrowAPRUpdated(oldAPR, newAPR);
    }

    /// @notice Withdraw protocol reserves (stablecoin)
    /// @param to Address to receive reserves
    /// @param amount Amount to withdraw
    function withdrawProtocolReserves(address to, uint256 amount) external onlyOwner {
        if (amount > protocolReserveStable) revert ExcessiveWithdrawal();
        protocolReserveStable -= amount;
        STABLE_TOKEN.mint(to, amount);
        emit ProtocolReservesWithdrawn(to, amount);
    }
    
    /// @notice Withdraw protocol collateral reserves
    /// @param to Address to receive collateral
    /// @param amount Amount of collateral to withdraw
    function withdrawProtocolCollateral(address to, uint256 amount) external onlyOwner {
        if (amount > protocolReserveCollateral) revert ExcessiveWithdrawal();
        protocolReserveCollateral -= amount;
        COLLATERAL_TOKEN.transfer(to, amount);
    }

    /// @notice Cover bad debt with protocol reserves (stablecoin)
    /// @param amount Amount of bad debt to cover
    function coverBadDebt(uint256 amount) external onlyOwner {
        if (amount > badDebt) revert ParameterOutOfBounds();
        if (amount > protocolReserveStable) revert ExcessiveWithdrawal();
        
        badDebt -= amount;
        protocolReserveStable -= amount;
        
        emit BadDebtCovered(amount);
    }

    /// @notice Get system health metrics
    /// @return totalDebt Total debt in the system
    /// @return reservesStable Protocol reserves in stablecoins
    /// @return reservesCollateral Protocol reserves in collateral
    /// @return debt Bad debt amount
    /// @return solvencyRatio Ratio of (total debt - bad debt) to total debt in WAD
    function getSystemHealth()
        external
        view
        returns (
            uint256 totalDebt, 
            uint256 reservesStable, 
            uint256 reservesCollateral,
            uint256 debt, 
            uint256 solvencyRatio
        )
    {
        totalDebt = totalSystemDebt;
        reservesStable = protocolReserveStable;
        reservesCollateral = protocolReserveCollateral;
        debt = badDebt;
        
        if (totalDebt == 0) {
            solvencyRatio = 1e18; // 100% solvent if no debt
        } else if (totalDebt <= badDebt) {
            solvencyRatio = 0; // Insolvent
        } else {
            solvencyRatio = ((totalDebt - badDebt) * 1e18) / totalDebt;
        }
    }

    /// @notice Internal function to accrue yield using real exchange rate from adapter
    /// @param vault Storage pointer to the vault
    function _accrueYieldInternal(Vault storage vault) internal {
        if (vault.collateralAmount == 0) {
            vault.lastAccrualTimestamp = block.timestamp;
            vault.lastExchangeRate = COLLATERAL_TOKEN.getExchangeRate();
            return;
        }

        // Get current exchange rate from adapter (e.g., stETH per wstETH)
        uint256 currentExchangeRate = COLLATERAL_TOKEN.getExchangeRate();
        
        // Initialize if first accrual
        if (vault.lastExchangeRate == 0) {
            vault.lastExchangeRate = currentExchangeRate;
            vault.lastAccrualTimestamp = block.timestamp;
            return;
        }

        // Calculate yield based on exchange rate increase
        // collateralAmount is in wrapper tokens (e.g., wstETH)
        // Exchange rate tells us how much underlying (stETH) we have
        // As exchange rate increases, our position value increases
        
        // New underlying value = collateralAmount * currentRate
        // Old underlying value = collateralAmount * lastRate  
        // Yield multiplier = currentRate / lastRate
        
        if (currentExchangeRate > vault.lastExchangeRate) {
            // Collateral value has increased due to yield
            // Update the wrapper amount to reflect increased underlying value
            // Note: For wrapped tokens (wstETH, rETH), the balance stays constant
            // but the exchange rate increases, so we track that instead
            vault.lastExchangeRate = currentExchangeRate;
        }
        
        vault.lastAccrualTimestamp = block.timestamp;
    }

    /// @notice Internal function to accrue interest on debt
    /// @param vault Storage pointer to the vault
    function _accrueInterest(Vault storage vault) internal {
        if (vault.debtAmount == 0) return;
        
        // Initialize timestamp if first time
        if (vault.lastAccrualTimestamp == 0) {
            vault.lastAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - vault.lastAccrualTimestamp;
        if (timeElapsed == 0) return;

        if (timeElapsed > MAX_ACCRUAL_PERIOD) {
            timeElapsed = MAX_ACCRUAL_PERIOD;
        }

        // Calculate interest: debt * APR * timeElapsed / SECONDS_PER_YEAR
        uint256 interest = vault.debtAmount.wadMul(borrowAPR).wadMul(timeElapsed.wadDiv(SECONDS_PER_YEAR));
        
        // Split interest: 90% to user debt, 10% to protocol reserves
        uint256 protocolFee = interest.wadMul(PROTOCOL_FEE);
        uint256 userInterest = interest - protocolFee;

        vault.debtAmount += userInterest;
        protocolReserveStable += protocolFee;
        totalSystemDebt += userInterest;
        
        // Update timestamp after accrual
        vault.lastAccrualTimestamp = block.timestamp;
    }
    
    /// @notice Internal function to update interest accrual tracking for grace period
    /// @param user Address of the vault owner
    /// @param interestAmount Amount of interest accrued
    function _updateInterestAccrualTracking(address user, uint256 interestAmount) internal {
        Vault storage vault = vaults[user];
        // Only track if significant interest was accrued (> 0.01% of debt)
        if (interestAmount > vault.debtAmount / 10000) {
            lastInterestAccrual[user] = block.timestamp;
        }
    }

    /// @notice Calculate health ratio for a vault
    /// @param collateralAmount Amount of collateral
    /// @param debtAmount Amount of debt
    /// @param useTWAP Whether to use TWAP for price (true for all operations now)
    /// @return healthRatio Health ratio in WAD format
    function _calculateHealthRatio(uint256 collateralAmount, uint256 debtAmount, bool useTWAP)
        internal
        view
        returns (uint256 healthRatio)
    {
        if (debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = _getCollateralValue(collateralAmount, useTWAP);
        
        return collateralValue.wadDiv(debtAmount);
    }

    /// @notice Get USD value of collateral using real exchange rate
    /// @dev collateralAmount is in wrapper tokens (e.g., wstETH), price is of wrapper token
    /// @dev The wrapper token price naturally reflects the underlying value + exchange rate
    /// @param collateralAmount Amount of collateral (wrapper tokens)
    /// @param useTWAP Whether to use TWAP for price
    /// @return value USD value with 18 decimals
    function _getCollateralValue(uint256 collateralAmount, bool useTWAP) internal view returns (uint256 value) {
        uint256 price;
        
        if (useTWAP) {
            // Use TWAP for all critical operations (borrows, liquidations, withdrawals)
            try PRICE_ORACLE.getTWAP(address(COLLATERAL_TOKEN), TWAP_PERIOD) returns (uint256 twapPrice) {
                price = twapPrice;
            } catch {
                revert TWAPUnavailable();
            }
        } else {
            // Spot price only for non-critical view operations
            // Use view version to avoid state changes in view context
            price = PRICE_ORACLE.getPriceView(address(COLLATERAL_TOKEN));
        }
        
        // NOTE: For yield-bearing tokens (wstETH, rETH), the price feed should price the wrapper token directly
        // The wrapper token's price naturally increases as the underlying accrues yield
        // Example: wstETH price = stETH price * (stETH per wstETH)
        // This is how Chainlink price feeds work for these tokens in practice
        return collateralAmount.wadMul(price.priceToWad());
    }

    /// @notice Calculate collateral to seize in liquidation
    /// @param debtToRepay Amount of debt to repay
    /// @param availableCollateral Available collateral in vault
    /// @return collateralToSeize Amount of collateral to seize (to liquidator)
    /// @return penaltyCollateral Amount of collateral penalty (to protocol)
    function _calculateCollateralToSeize(uint256 debtToRepay, uint256 availableCollateral)
        internal
        view
        returns (uint256 collateralToSeize, uint256 penaltyCollateral)
    {
        // Get TWAP price
        uint256 collateralPrice;
        try PRICE_ORACLE.getTWAP(address(COLLATERAL_TOKEN), TWAP_PERIOD) returns (uint256 twapPrice) {
            collateralPrice = twapPrice;
        } catch {
            revert TWAPUnavailable();
        }

        // Convert to WAD and calculate base collateral equivalent to debt
        uint256 priceWad = collateralPrice.priceToWad();
        uint256 baseCollateral = debtToRepay.wadDiv(priceWad);

        uint256 liquidatorBonus = baseCollateral.wadMul(LIQUIDATION_BONUS);
        penaltyCollateral = baseCollateral.wadMul(LIQUIDATION_PENALTY);
        
        collateralToSeize = baseCollateral + liquidatorBonus;
        uint256 totalCollateralNeeded = collateralToSeize + penaltyCollateral;

        // Cap at available collateral
        if (totalCollateralNeeded > availableCollateral) {
            // Proportionally reduce both bonus and penalty
            uint256 ratio = availableCollateral.wadDiv(totalCollateralNeeded);
            collateralToSeize = collateralToSeize.wadMul(ratio);
            penaltyCollateral = penaltyCollateral.wadMul(ratio);
        }
    }

    /// @notice Update vault state after liquidation and handle bad debt
    /// @param vault Storage pointer to vault
    /// @param user Address of vault owner
    /// @param collateralSeized Amount of collateral seized (total including penalty)
    /// @param debtRepaid Amount of debt repaid
    /// @param penaltyCollateral Amount of collateral penalty for protocol
    function _updateVaultAfterLiquidation(
        Vault storage vault,
        address user,
        uint256 collateralSeized,
        uint256 debtRepaid,
        uint256 penaltyCollateral
    ) internal {
        vault.collateralAmount -= collateralSeized;
        vault.debtAmount -= debtRepaid;
        
        // Update total system debt
        totalSystemDebt = debtRepaid <= totalSystemDebt ? totalSystemDebt - debtRepaid : 0;
        
        if (penaltyCollateral > 0) {
            protocolReserveCollateral += penaltyCollateral;
            emit LiquidationPenaltyCollected(user, penaltyCollateral);
        }
        
        // Check for bad debt - treat dust amounts (< 10 wei) as zero for practical purposes
        // This handles rounding edge cases where liquidation math leaves tiny collateral amounts
        if (vault.debtAmount > 0 && vault.collateralAmount < 10) {
            uint256 remaining = vault.debtAmount;
            badDebt += remaining;
            vault.debtAmount = 0;
            totalSystemDebt -= remaining;
            emit BadDebtRecorded(user, remaining);
        }

        emit VaultLiquidated(user, msg.sender, collateralSeized, debtRepaid);
    }
}
