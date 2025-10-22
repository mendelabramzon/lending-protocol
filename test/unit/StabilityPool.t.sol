// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StabilityPool} from "../../src/StabilityPool.sol";
import {StableToken} from "../../src/StableToken.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";

contract StabilityPoolTest is Test {
    StabilityPool public pool;
    StableToken public stableToken;
    MockYieldToken public collateralToken;

    address public depositor1;
    address public depositor2;
    address public liquidationEngine;

    event StablecoinsDeposited(address indexed depositor, uint256 amount);
    event StablecoinsWithdrawn(address indexed depositor, uint256 amount);
    event CollateralGainsClaimed(address indexed depositor, uint256 collateralAmount);
    event LiquidationDistributed(uint256 debtOffset, uint256 collateralToDistribute);

    function setUp() public {
        depositor1 = makeAddr("depositor1");
        depositor2 = makeAddr("depositor2");
        liquidationEngine = makeAddr("liquidationEngine");

        stableToken = new StableToken("USD Stable", "USDS");
        collateralToken = new MockYieldToken("Mock stETH", "mstETH");
        
        pool = new StabilityPool(address(stableToken), address(collateralToken));
        pool.setLiquidationEngine(liquidationEngine);

        // Mint stablecoins to depositors
        stableToken.addMinter(address(this));
        stableToken.mint(depositor1, 10000e18);
        stableToken.mint(depositor2, 10000e18);
    }

    function test_Deposit() public {
        uint256 depositAmount = 5000e18;

        vm.startPrank(depositor1);
        stableToken.approve(address(pool), depositAmount);
        
        vm.expectEmit(true, false, false, true);
        emit StablecoinsDeposited(depositor1, depositAmount);
        
        pool.deposit(depositAmount);
        vm.stopPrank();

        assertEq(pool.getTotalDeposits(), depositAmount);
        
        StabilityPool.Deposit memory deposit = pool.getDeposit(depositor1);
        assertEq(deposit.amount, depositAmount);
    }

    function test_RevertWhen_DepositZeroAmount() public {
        vm.prank(depositor1);
        vm.expectRevert(StabilityPool.ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_Withdraw() public {
        uint256 depositAmount = 5000e18;
        uint256 withdrawAmount = 2000e18;

        vm.startPrank(depositor1);
        stableToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        vm.expectEmit(true, false, false, true);
        emit StablecoinsWithdrawn(depositor1, withdrawAmount);
        
        pool.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(pool.getTotalDeposits(), depositAmount - withdrawAmount);
        
        StabilityPool.Deposit memory deposit = pool.getDeposit(depositor1);
        assertEq(deposit.amount, depositAmount - withdrawAmount);
    }

    function test_RevertWhen_WithdrawInsufficientBalance() public {
        uint256 depositAmount = 5000e18;

        vm.startPrank(depositor1);
        stableToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        vm.expectRevert(StabilityPool.InsufficientBalance.selector);
        pool.withdraw(depositAmount + 1);
        vm.stopPrank();
    }

    function test_DistributeLiquidation() public {
        // Setup: Two depositors with equal deposits
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);
        vm.stopPrank();

        vm.startPrank(depositor2);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);
        vm.stopPrank();

        // Prepare liquidation distribution
        uint256 debtToOffset = 2000e18;
        uint256 collateralToDistribute = 2 ether;

        // Mint collateral to liquidation engine
        collateralToken.mint(liquidationEngine, collateralToDistribute);
        
        // Add pool as minter to burn debt
        stableToken.addMinter(address(pool));

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateralToDistribute);
        
        vm.expectEmit(false, false, false, true);
        emit LiquidationDistributed(debtToOffset, collateralToDistribute);
        
        pool.distributeLiquidation(debtToOffset, collateralToDistribute);
        vm.stopPrank();

        // Total deposits should decrease by debt offset
        assertEq(pool.getTotalDeposits(), 10000e18 - debtToOffset);
    }

    function test_ClaimCollateralGains() public {
        // Setup: deposit
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);
        vm.stopPrank();

        // Distribute liquidation
        uint256 collateralToDistribute = 1 ether;
        collateralToken.mint(liquidationEngine, collateralToDistribute);
        stableToken.addMinter(address(pool));

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateralToDistribute);
        pool.distributeLiquidation(1000e18, collateralToDistribute);
        vm.stopPrank();

        // Claim gains
        uint256 balanceBefore = collateralToken.balanceOf(depositor1);
        
        vm.prank(depositor1);
        pool.claimCollateralGains();

        uint256 balanceAfter = collateralToken.balanceOf(depositor1);
        assertGt(balanceAfter, balanceBefore, "Should receive collateral gains");
    }

    function test_RevertWhen_ClaimZeroGains() public {
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);

        // Try to claim without any liquidations
        vm.expectRevert(StabilityPool.ZeroAmount.selector);
        pool.claimCollateralGains();
        vm.stopPrank();
    }

    function test_ProportionalDistribution() public {
        // Depositor1: 7500, Depositor2: 2500 (75% vs 25%)
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 7500e18);
        pool.deposit(7500e18);
        vm.stopPrank();

        vm.startPrank(depositor2);
        stableToken.approve(address(pool), 2500e18);
        pool.deposit(2500e18);
        vm.stopPrank();

        // Distribute 4 ether of collateral
        uint256 collateralToDistribute = 4 ether;
        collateralToken.mint(liquidationEngine, collateralToDistribute);
        stableToken.addMinter(address(pool));

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateralToDistribute);
        pool.distributeLiquidation(1000e18, collateralToDistribute);
        vm.stopPrank();

        // Check pending gains
        uint256 gains1 = pool.getPendingCollateralGains(depositor1);
        uint256 gains2 = pool.getPendingCollateralGains(depositor2);

        // Depositor1 should get ~75% and Depositor2 ~25%
        assertApproxEqRel(gains1, 3 ether, 0.01e18, "Depositor1 should get ~75%");
        assertApproxEqRel(gains2, 1 ether, 0.01e18, "Depositor2 should get ~25%");
    }

    function test_GetPendingCollateralGains() public {
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);
        vm.stopPrank();

        // Initially no gains
        assertEq(pool.getPendingCollateralGains(depositor1), 0);

        // Distribute liquidation
        collateralToken.mint(liquidationEngine, 1 ether);
        stableToken.addMinter(address(pool));

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), 1 ether);
        pool.distributeLiquidation(500e18, 1 ether);
        vm.stopPrank();

        // Should have pending gains
        assertGt(pool.getPendingCollateralGains(depositor1), 0);
    }

    function test_RevertWhen_DistributeLiquidationNotAuthorized() public {
        vm.prank(depositor1);
        vm.expectRevert(StabilityPool.NotLiquidationEngine.selector);
        pool.distributeLiquidation(1000e18, 1 ether);
    }

    function test_RevertWhen_DistributeLiquidationNoDeposits() public {
        vm.prank(liquidationEngine);
        vm.expectRevert(StabilityPool.NoDeposits.selector);
        pool.distributeLiquidation(1000e18, 1 ether);
    }

    function test_SetLiquidationEngine() public {
        address newEngine = makeAddr("newEngine");
        pool.setLiquidationEngine(newEngine);
        assertEq(pool.liquidationEngine(), newEngine);
    }

    function test_RevertWhen_SetLiquidationEngineNotOwner() public {
        vm.prank(depositor1);
        vm.expectRevert();
        pool.setLiquidationEngine(makeAddr("newEngine"));
    }

    function test_MultipleDepositsAndWithdrawals() public {
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 10000e18);
        
        // Multiple deposits
        pool.deposit(2000e18);
        pool.deposit(3000e18);
        
        StabilityPool.Deposit memory deposit = pool.getDeposit(depositor1);
        assertEq(deposit.amount, 5000e18);

        // Partial withdrawal
        pool.withdraw(1000e18);
        
        deposit = pool.getDeposit(depositor1);
        assertEq(deposit.amount, 4000e18);
        vm.stopPrank();
    }

    function test_CollateralGainsAccumulation() public {
        // Deposit
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), 5000e18);
        pool.deposit(5000e18);
        vm.stopPrank();

        stableToken.addMinter(address(pool));

        // First liquidation
        collateralToken.mint(liquidationEngine, 1 ether);
        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), 1 ether);
        pool.distributeLiquidation(500e18, 1 ether);
        vm.stopPrank();

        uint256 gains1 = pool.getPendingCollateralGains(depositor1);

        // Second liquidation
        collateralToken.mint(liquidationEngine, 1 ether);
        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), 1 ether);
        pool.distributeLiquidation(500e18, 1 ether);
        vm.stopPrank();

        uint256 gains2 = pool.getPendingCollateralGains(depositor1);

        // Gains should accumulate
        assertGt(gains2, gains1, "Gains should accumulate over multiple liquidations");
    }
}

