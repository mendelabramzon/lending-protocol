// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

contract VaultManagerTest is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public user1;
    address public user2;
    address public liquidator;

    uint256 constant INITIAL_COLLATERAL = 10 ether;
    uint256 constant COLLATERAL_PRICE = 2000e8; // $2000 per token

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event DebtBorrowed(address indexed user, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amount);

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");

        // Deploy contracts
        collateralToken = new MockYieldToken("Mock stETH", "mstETH");
        stableToken = new StableToken("USD Stable", "USDS");
        oracle = new PriceOracle();
        
        vaultManager = new VaultManager(
            address(collateralToken),
            address(stableToken),
            address(oracle)
        );

        // Setup price feed
        priceFeed = new MockChainlinkOracle(8);
        priceFeed.setPrice(int256(COLLATERAL_PRICE));
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Initialize TWAP with multiple observations
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        }

        // Add vault manager as minter
        stableToken.addMinter(address(vaultManager));

        // Setup users with collateral
        collateralToken.mint(user1, INITIAL_COLLATERAL);
        collateralToken.mint(user2, INITIAL_COLLATERAL);
    }

    function test_DepositCollateral() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        
        vm.expectEmit(true, false, false, true);
        emit CollateralDeposited(user1, INITIAL_COLLATERAL);
        
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,,) = vaultManager.vaults(user1);
        assertEq(collateral, INITIAL_COLLATERAL);
        assertEq(debt, 0);
    }

    function test_RevertWhen_DepositZeroCollateral() public {
        vm.prank(user1);
        vm.expectRevert(VaultManager.ZeroAmount.selector);
        vaultManager.depositCollateral(0);
    }

    function test_WithdrawCollateral() public {
        // First deposit
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);

        // Then withdraw
        uint256 withdrawAmount = 5 ether;
        vm.expectEmit(true, false, false, true);
        emit CollateralWithdrawn(user1, withdrawAmount);
        
        vaultManager.withdrawCollateral(withdrawAmount);
        vm.stopPrank();

        (uint256 collateral,,,) = vaultManager.vaults(user1);
        assertEq(collateral, INITIAL_COLLATERAL - withdrawAmount);
    }

    function test_RevertWhen_WithdrawExcessiveCollateral() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);

        vm.expectRevert(VaultManager.ExcessiveWithdrawal.selector);
        vaultManager.withdrawCollateral(INITIAL_COLLATERAL + 1);
        vm.stopPrank();
    }

    function test_Borrow() public {
        // Deposit collateral worth $20,000
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);

        // Borrow $10,000 (50% LTV, well below 80% max)
        uint256 borrowAmount = 10000e18;
        
        vm.expectEmit(true, false, false, true);
        emit DebtBorrowed(user1, borrowAmount);
        
        vaultManager.borrow(borrowAmount);
        vm.stopPrank();

        (, uint256 debt,,) = vaultManager.vaults(user1);
        assertEq(debt, borrowAmount);
        assertEq(stableToken.balanceOf(user1), borrowAmount);
    }

    function test_RevertWhen_BorrowInsufficientCollateral() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);

        // Try to borrow $18,000 (would violate 150% min collateral ratio)
        uint256 borrowAmount = 18000e18;
        
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        vaultManager.borrow(borrowAmount);
        vm.stopPrank();
    }

    function test_Repay() public {
        // Setup: deposit and borrow
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        
        uint256 borrowAmount = 10000e18;
        vaultManager.borrow(borrowAmount);

        // Repay half
        uint256 repayAmount = 5000e18;
        stableToken.approve(address(vaultManager), repayAmount);
        
        vm.expectEmit(true, false, false, true);
        emit DebtRepaid(user1, repayAmount);
        
        vaultManager.repay(repayAmount);
        vm.stopPrank();

        (, uint256 debt,,) = vaultManager.vaults(user1);
        assertEq(debt, borrowAmount - repayAmount);
        assertEq(stableToken.balanceOf(user1), borrowAmount - repayAmount);
    }

    function test_RepayFullDebt() public {
        // Setup: deposit and borrow
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        
        uint256 borrowAmount = 10000e18;
        vaultManager.borrow(borrowAmount);

        // Repay all
        stableToken.approve(address(vaultManager), borrowAmount);
        vaultManager.repay(borrowAmount);
        vm.stopPrank();

        (, uint256 debt,,) = vaultManager.vaults(user1);
        assertEq(debt, 0);
        assertEq(stableToken.balanceOf(user1), 0);
    }

    function test_GetHealthRatio() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        
        // Borrow $10,000 against $20,000 collateral = 200% ratio
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        uint256 healthRatio = vaultManager.getHealthRatio(user1);
        
        // Health ratio should be 2.0 (200%)
        assertEq(healthRatio, 2e18, "Health ratio should be 2.0");
    }

    function test_HealthRatioWithNoDebt() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.stopPrank();

        uint256 healthRatio = vaultManager.getHealthRatio(user1);
        assertEq(healthRatio, type(uint256).max, "Health ratio should be max with no debt");
    }

    function test_AccrueYield() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.stopPrank();

        (uint256 collateralAmount,,, uint256 exchangeRateBefore) = vaultManager.vaults(user1);

        // With real LST integration: wrapper amount stays constant, exchange rate increases
        uint256 exchangeRateBefore2 = collateralToken.getExchangeRate();

        // Simulate time passing (1 year)
        vm.warp(block.timestamp + 365 days);

        // Accrue yield
        vaultManager.accrueYield(user1);

        (,,, uint256 exchangeRateAfter) = vaultManager.vaults(user1);
        uint256 exchangeRateAfter2 = collateralToken.getExchangeRate();

        // Exchange rate should have increased due to 5% APY (wrapper balance stays constant)
        assertGt(exchangeRateAfter2, exchangeRateBefore2, "Exchange rate should increase with yield");
        // The vault now tracks the exchange rate
        assertEq(exchangeRateAfter, exchangeRateAfter2, "Vault should track current exchange rate");
    }

    function test_WithdrawAfterBorrowMaintainsCollateralRatio() public {
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        
        // Borrow $10,000
        vaultManager.borrow(10000e18);

        // Try to withdraw 6 ether (would leave 4 ether = $8,000, ratio = 80%)
        // This should fail because it violates 150% min ratio
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        vaultManager.withdrawCollateral(6 ether);
        vm.stopPrank();
    }

    function test_SetLiquidationEngine() public {
        address newLiquidationEngine = makeAddr("liquidationEngine");
        vaultManager.setLiquidationEngine(newLiquidationEngine);
        assertEq(vaultManager.liquidationEngine(), newLiquidationEngine);
    }

    function test_RevertWhen_SetLiquidationEngineNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vaultManager.setLiquidationEngine(makeAddr("liquidationEngine"));
    }

    // REMOVED: test_SetCollateralAPY - Function removed in favor of real LST yield tracking via exchange rates
    // The protocol now uses IYieldToken adapters which query real exchange rates from LST/LRT tokens
    // Yield accrual is automatic based on exchange rate changes, not simulated APY

    function test_MultipleUsersIndependentVaults() public {
        // User1 deposits and borrows
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vaultManager.borrow(5000e18);
        vm.stopPrank();

        // User2 deposits and borrows
        vm.startPrank(user2);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vaultManager.borrow(8000e18);
        vm.stopPrank();

        // Verify independent states
        (, uint256 debt1,,) = vaultManager.vaults(user1);
        (, uint256 debt2,,) = vaultManager.vaults(user2);
        
        assertEq(debt1, 5000e18);
        assertEq(debt2, 8000e18);
    }
}

