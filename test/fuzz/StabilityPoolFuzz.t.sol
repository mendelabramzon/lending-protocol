// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StabilityPool} from "../../src/StabilityPool.sol";
import {StableToken} from "../../src/StableToken.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";

contract StabilityPoolFuzzTest is Test {
    StabilityPool public pool;
    StableToken public stableToken;
    MockYieldToken public collateralToken;

    address public depositor;
    address public liquidationEngine;

    function setUp() public {
        depositor = makeAddr("depositor");
        liquidationEngine = makeAddr("liquidationEngine");

        stableToken = new StableToken("USD Stable", "USDS");
        collateralToken = new MockYieldToken("Mock stETH", "mstETH");
        
        pool = new StabilityPool(address(stableToken), address(collateralToken));
        pool.setLiquidationEngine(liquidationEngine);

        stableToken.addMinter(address(this));
        stableToken.addMinter(address(pool));
    }

    /// @notice Fuzz test deposit and withdraw maintains balance
    function testFuzz_DepositWithdrawBalance(uint96 depositAmount, uint96 withdrawAmount) public {
        depositAmount = uint96(bound(depositAmount, 1e18, 1000000e18));
        withdrawAmount = uint96(bound(withdrawAmount, 0, depositAmount));

        // Setup
        stableToken.mint(depositor, depositAmount);

        vm.startPrank(depositor);
        stableToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        
        assertEq(pool.getTotalDeposits(), depositAmount, "Total deposits should match");

        if (withdrawAmount > 0) {
            pool.withdraw(withdrawAmount);
            assertEq(pool.getTotalDeposits(), depositAmount - withdrawAmount, "Remaining deposits should be correct");
        }
        vm.stopPrank();
    }

    /// @notice Fuzz test liquidation distribution is proportional
    function testFuzz_ProportionalDistribution(
        uint96 deposit1,
        uint96 deposit2,
        uint96 collateralAmount
    ) public {
        // Use bound to constrain inputs
        deposit1 = uint96(bound(deposit1, 50000e18, 500000e18));
        deposit2 = uint96(bound(deposit2, 50000e18, 500000e18));
        collateralAmount = uint96(bound(collateralAmount, 10 ether, 100 ether));

        address depositor1 = makeAddr("depositor1");
        address depositor2 = makeAddr("depositor2");

        // Setup deposits
        stableToken.mint(depositor1, deposit1);
        stableToken.mint(depositor2, deposit2);

        vm.startPrank(depositor1);
        stableToken.approve(address(pool), deposit1);
        pool.deposit(deposit1);
        vm.stopPrank();

        vm.startPrank(depositor2);
        stableToken.approve(address(pool), deposit2);
        pool.deposit(deposit2);
        vm.stopPrank();

        uint256 totalDeposits = uint256(deposit1) + uint256(deposit2);

        uint256 debtToOffset = 10000e18;
        collateralToken.mint(liquidationEngine, collateralAmount);

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateralAmount);
        pool.distributeLiquidation(debtToOffset, collateralAmount);
        vm.stopPrank();

        // Check proportional gains
        uint256 gains1 = pool.getPendingCollateralGains(depositor1);
        uint256 gains2 = pool.getPendingCollateralGains(depositor2);

        // Calculate expected proportions (with small tolerance for rounding)
        uint256 expectedGains1 = (uint256(collateralAmount) * uint256(deposit1)) / totalDeposits;
        uint256 expectedGains2 = (uint256(collateralAmount) * uint256(deposit2)) / totalDeposits;

        assertApproxEqRel(gains1, expectedGains1, 0.01e18, "Depositor1 gains should be proportional");
        assertApproxEqRel(gains2, expectedGains2, 0.01e18, "Depositor2 gains should be proportional");
    }

    /// @notice Fuzz test total deposits decrease after liquidation
    function testFuzz_LiquidationDecreasesDeposits(uint96 initialDeposit, uint96 debtOffset) public {
        initialDeposit = uint96(bound(initialDeposit, 1000e18, 1000000e18));
        debtOffset = uint96(bound(debtOffset, 1e18, initialDeposit));

        // Setup
        stableToken.mint(depositor, initialDeposit);

        vm.startPrank(depositor);
        stableToken.approve(address(pool), initialDeposit);
        pool.deposit(initialDeposit);
        vm.stopPrank();

        uint256 depositsBefore = pool.getTotalDeposits();

        // Distribute liquidation
        collateralToken.mint(liquidationEngine, 1 ether);

        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), 1 ether);
        pool.distributeLiquidation(debtOffset, 1 ether);
        vm.stopPrank();

        uint256 depositsAfter = pool.getTotalDeposits();

        assertEq(depositsAfter, depositsBefore - debtOffset, "Deposits should decrease by debt offset");
    }

    /// @notice Fuzz test gains accumulate over multiple liquidations
    function testFuzz_GainsAccumulate(
        uint96 depositAmount,
        uint96 collateral1,
        uint96 collateral2
    ) public {
        // Use bound to constrain inputs
        depositAmount = uint96(bound(depositAmount, 100000e18, 1000000e18));
        collateral1 = uint96(bound(collateral1, 1 ether, 100 ether));
        collateral2 = uint96(bound(collateral2, 1 ether, 100 ether));

        // Setup with enough deposit to handle both liquidations
        stableToken.mint(depositor, depositAmount);

        vm.startPrank(depositor);
        stableToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        collateralToken.mint(liquidationEngine, collateral1);
        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateral1);
        pool.distributeLiquidation(1000e18, collateral1);
        vm.stopPrank();

        uint256 gainsAfterFirst = pool.getPendingCollateralGains(depositor);

        collateralToken.mint(liquidationEngine, collateral2);
        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateral2);
        pool.distributeLiquidation(1000e18, collateral2);
        vm.stopPrank();

        uint256 gainsAfterSecond = pool.getPendingCollateralGains(depositor);

        // Gains should accumulate
        assertGe(gainsAfterSecond, gainsAfterFirst, "Gains should accumulate");
        assertGt(gainsAfterSecond, 0, "Should have gains");
    }

    /// @notice Fuzz test claim resets gains
    function testFuzz_ClaimResetsGains(uint96 depositAmount, uint96 collateralAmount) public {
        depositAmount = uint96(bound(depositAmount, 1000e18, 1000000e18));
        collateralAmount = uint96(bound(collateralAmount, 0.1 ether, 100 ether));

        // Setup and distribute
        stableToken.mint(depositor, depositAmount);

        vm.startPrank(depositor);
        stableToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        collateralToken.mint(liquidationEngine, collateralAmount);
        vm.startPrank(liquidationEngine);
        collateralToken.transfer(address(pool), collateralAmount);
        pool.distributeLiquidation(100e18, collateralAmount);
        vm.stopPrank();

        // Claim gains
        vm.prank(depositor);
        pool.claimCollateralGains();

        // Gains should be zero after claim
        uint256 gainsAfterClaim = pool.getPendingCollateralGains(depositor);
        assertEq(gainsAfterClaim, 0, "Gains should be zero after claim");
    }

    /// @notice Fuzz test multiple depositors don't interfere
    function testFuzz_MultipleDepositorsIndependent(
        uint96 deposit1,
        uint96 deposit2,
        uint96 withdraw1
    ) public {
        deposit1 = uint96(bound(deposit1, 1000e18, 500000e18));
        deposit2 = uint96(bound(deposit2, 1000e18, 500000e18));
        withdraw1 = uint96(bound(withdraw1, 0, deposit1));

        address depositor1 = makeAddr("depositor1");
        address depositor2 = makeAddr("depositor2");

        // Setup depositor1
        stableToken.mint(depositor1, deposit1);
        vm.startPrank(depositor1);
        stableToken.approve(address(pool), deposit1);
        pool.deposit(deposit1);
        vm.stopPrank();

        // Setup depositor2
        stableToken.mint(depositor2, deposit2);
        vm.startPrank(depositor2);
        stableToken.approve(address(pool), deposit2);
        pool.deposit(deposit2);
        vm.stopPrank();

        // Depositor1 withdraws
        if (withdraw1 > 0) {
            vm.prank(depositor1);
            pool.withdraw(withdraw1);
        }

        // Verify independent states
        StabilityPool.Deposit memory dep1 = pool.getDeposit(depositor1);
        StabilityPool.Deposit memory dep2 = pool.getDeposit(depositor2);

        assertEq(dep1.amount, deposit1 - withdraw1, "Depositor1 amount should be correct");
        assertEq(dep2.amount, deposit2, "Depositor2 amount should be unchanged");
    }

    /// @notice Fuzz test deposit-withdraw-deposit maintains correct state
    function testFuzz_DepositWithdrawDepositSequence(
        uint96 deposit1,
        uint96 withdrawAmount,
        uint96 deposit2
    ) public {
        deposit1 = uint96(bound(deposit1, 1000e18, 500000e18));
        withdrawAmount = uint96(bound(withdrawAmount, 0, deposit1));
        deposit2 = uint96(bound(deposit2, 1000e18, 500000e18));

        // Setup
        stableToken.mint(depositor, deposit1 + deposit2);

        vm.startPrank(depositor);
        stableToken.approve(address(pool), deposit1 + deposit2);
        
        // First deposit
        pool.deposit(deposit1);
        
        // Withdraw
        if (withdrawAmount > 0) {
            pool.withdraw(withdrawAmount);
        }
        
        // Second deposit
        pool.deposit(deposit2);
        vm.stopPrank();

        // Verify final state
        StabilityPool.Deposit memory finalDeposit = pool.getDeposit(depositor);
        uint256 expectedAmount = deposit1 - withdrawAmount + deposit2;
        
        assertEq(finalDeposit.amount, expectedAmount, "Final deposit should be correct");
        assertEq(pool.getTotalDeposits(), expectedAmount, "Total deposits should be correct");
    }
}

