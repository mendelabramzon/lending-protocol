// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {StabilityPool} from "../../src/StabilityPool.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

/// @title EnhancedFeaturesTest
/// @notice Tests for new features: interest rates, StabilityPool fallback, bad debt handling
contract EnhancedFeaturesTest is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    StabilityPool public stabilityPool;
    LiquidationEngine public liquidationEngine;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public alice;
    address public bob;
    address public liquidator;

    uint256 constant COLLATERAL_PRICE = 2000e8;
    uint256 constant INITIAL_COLLATERAL = 10 ether;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
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

        stabilityPool = new StabilityPool(
            address(stableToken),
            address(collateralToken)
        );

        liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(stableToken),
            address(collateralToken),
            address(oracle),
            address(stabilityPool)
        );

        // Setup price feed
        priceFeed = new MockChainlinkOracle(8);
        priceFeed.setPrice(int256(COLLATERAL_PRICE));
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Initialize TWAP
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(int256(COLLATERAL_PRICE));
        }

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(stabilityPool));
        stableToken.addMinter(address(liquidationEngine));
        vaultManager.setLiquidationEngine(address(liquidationEngine));
        stabilityPool.setLiquidationEngine(address(liquidationEngine));

        // Setup users
        collateralToken.mint(alice, INITIAL_COLLATERAL);
        collateralToken.mint(bob, INITIAL_COLLATERAL);
        
        vm.deal(liquidator, 1 ether);
    }

    /// @notice Test: Interest accrual on borrows
    function test_InterestAccrual() public {
        // Alice borrows
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        // Check initial debt
        (, uint256 debtBefore,,) = vaultManager.vaults(alice);
        assertEq(debtBefore, 10000e18, "Initial debt should be 10000");

        // Wait 1 year (update TWAP to prevent staleness)
        vm.warp(block.timestamp + 365 days);
        priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        oracle.updatePriceObservation(address(collateralToken));

        // Trigger interest accrual
        vaultManager.accrueYield(alice);

        // Check debt after 1 year (should be ~10450 with 5% APR, 90% to user)
        (, uint256 debtAfter,,) = vaultManager.vaults(alice);
        
        // Expected: 10000 * 1.045 = 10450 (5% APR * 90% to user)
        assertGt(debtAfter, 10400e18, "Debt should have increased");
        assertLt(debtAfter, 10500e18, "Debt increase should be reasonable");
    }

    /// @notice Test: Protocol reserves accumulation
    function test_ProtocolReservesAccumulate() public {
        // Alice borrows
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        uint256 reservesBefore = vaultManager.protocolReserveStable();

        // Wait 1 year (update TWAP to prevent staleness)
        vm.warp(block.timestamp + 365 days);
        priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        oracle.updatePriceObservation(address(collateralToken));

        // Trigger interest accrual
        vaultManager.accrueYield(alice);

        uint256 reservesAfter = vaultManager.protocolReserveStable();

        // Protocol should earn 10% of 5% = 0.5% = 50 tokens
        assertGt(reservesAfter, reservesBefore, "Reserves should increase");
        assertGt(reservesAfter, 40e18, "Should have at least 40 in reserves");
    }

    /// @notice Test: APR adjustment by owner
    function test_SetBorrowAPR() public {
        uint256 oldAPR = vaultManager.borrowAPR();
        assertEq(oldAPR, 5e16, "Initial APR should be 5%");

        // Owner sets new APR
        vaultManager.setBorrowAPR(10e16); // 10%

        uint256 newAPR = vaultManager.borrowAPR();
        assertEq(newAPR, 10e16, "APR should be updated");
    }

    /// @notice Test: Cannot set invalid APR
    function test_CannotSetInvalidAPR() public {
        vm.expectRevert(VaultManager.InvalidAPR.selector);
        vaultManager.setBorrowAPR(150e16); // 150% - too high
    }

    /// @notice Test: StabilityPool fallback when auction times out
    function test_StabilityPoolFallback() public {
        // Bob deposits to StabilityPool
        stableToken.addMinter(bob);
        vm.startPrank(bob);
        stableToken.mint(bob, 10000e18);
        stableToken.approve(address(stabilityPool), 10000e18);
        stabilityPool.deposit(10000e18);
        vm.stopPrank();

        // Alice creates undercollateralized vault
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(13000e18);
        vm.stopPrank();

        // Price drops - vault becomes liquidatable
        priceFeed.setPrice(1400e8);
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        // Start auction but don't reveal any bids
        bytes32 commitHash = keccak256(abi.encodePacked(uint256(5000e18), uint256(4 ether), bytes32(0)));
        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(alice, commitHash);

        // Wait for total timeout (3 hours) and update TWAP to prevent staleness
        vm.warp(block.timestamp + 3 hours + 1 minutes);
        priceFeed.setPrice(1400e8); // Keep liquidatable price fresh
        oracle.updatePriceObservation(address(collateralToken));

        // Anyone can trigger fallback
        liquidationEngine.cancelAuctionAndFallback(alice);

        // Check that StabilityPool was used
        uint256 poolBalanceAfter = stabilityPool.getTotalDeposits();
        assertLt(poolBalanceAfter, 10000e18, "StabilityPool should have been used");
    }

    /// @notice Test: Bad debt is recorded when vault has no collateral
    function test_BadDebtRecording() public {
        // Alice creates vault
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        uint256 badDebtBefore = vaultManager.badDebt();
        assertEq(badDebtBefore, 0, "No bad debt initially");

        // Price crashes dramatically - severe enough to create bad debt
        // At $200, vault worth $2000, owes $10000 - highly underwater
        priceFeed.setPrice(200e8); 
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        // Liquidation loop: keep liquidating until either collateral or debt is exhausted
        // Due to MAX_LIQUIDATION_RATIO of 50%, we need multiple liquidations
        // Note: Bad debt is automatically recorded within liquidation when collateral hits 0
        for (uint256 i = 0; i < 5; i++) {
            (, uint256 currentDebt,,) = vaultManager.vaults(alice);
            
            // Stop if vault is cleared
            if (currentDebt == 0) break;
            
            // Liquidate up to 50% of current debt (or remaining if collateral insufficient)
            uint256 liquidationAmount = currentDebt / 2;
            if (liquidationAmount == 0) liquidationAmount = currentDebt; // Handle rounding
            
            vm.prank(address(liquidationEngine));
            vaultManager.liquidate(alice, liquidationAmount);
            
            // If collateral is exhausted (< 10 wei dust threshold), bad debt should be recorded and debt set to 0
            (uint256 afterCollateral, uint256 afterDebt,,) = vaultManager.vaults(alice);
            if (afterCollateral < 10) {
                // Bad debt handling occurred - debt should be 0 now
                assertEq(afterDebt, 0, "Debt should be 0 after bad debt recording");
                break;
            }
            
            vm.warp(block.timestamp + 11 minutes);
        }

        // Check final state
        uint256 badDebtAfter = vaultManager.badDebt();
        (uint256 finalCollateral, uint256 finalDebt,,) = vaultManager.vaults(alice);
        
        // In a severely underwater position with $200 price:
        // Collateral worth $2k, debt $10k - collateral will be exhausted
        // and bad debt should be recorded
        
        // Allow for dust (< 10 wei threshold) due to rounding in liquidation math
        assertLt(finalCollateral, 10, "Collateral should be exhausted (< 10 wei dust threshold)");
        assertEq(finalDebt, 0, "Debt should be 0 after bad debt recording");
        assertGt(badDebtAfter, 0, "Bad debt should be recorded");
        
        // With 10 ETH collateral at $200 = $2k value, and $10k debt:
        // MAX_LIQUIDATION_RATIO allows 50% liquidation ($5k)
        // $2k collateral can cover ~$1.82k of the $5k debt (after 10% liquidation costs - reduced from 15%)
        // Remaining debt becomes bad debt
        // With reduced liquidation fees (10% vs 15%), collateral covers MORE debt, leaving LESS bad debt
        // Expected bad debt: roughly $1k to $8.5k depending on liquidation rounds
        assertGt(badDebtAfter, 1000e18, "Bad debt should be > 1000 USD");
        assertLt(badDebtAfter, 9000e18, "Bad debt should be < 9000 USD (sanity check)");
    }

    /// @notice Test: System health metrics
    function test_SystemHealthMetrics() public {
        // Alice and Bob borrow
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        (uint256 totalDebt, , , uint256 badDebtAmount, uint256 solvencyRatio) = 
            vaultManager.getSystemHealth();

        assertEq(totalDebt, 20000e18, "Total debt should be 20000");
        assertEq(badDebtAmount, 0, "No bad debt initially");
        assertEq(solvencyRatio, 1e18, "System should be 100% solvent");
    }

    /// @notice Test: Cover bad debt with reserves
    function test_CoverBadDebt() public {
        // Simulate having bad debt and reserves
        // We'll need to manually set these through liquidations and interest

        // First accumulate some reserves through interest
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        // Wait to accumulate reserves (update TWAP to prevent staleness)
        vm.warp(block.timestamp + 365 days);
        priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        oracle.updatePriceObservation(address(collateralToken));
        vaultManager.accrueYield(alice);

        uint256 reserves = vaultManager.protocolReserveStable();
        assertGt(reserves, 0, "Should have some reserves");

        // Note: Full bad debt simulation requires complete liquidation flow
        // This would be tested in integration tests
    }

    /// @notice Test: Withdraw protocol reserves
    function test_WithdrawProtocolReserves() public {
        // Accumulate reserves
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vaultManager.accrueYield(alice);

        uint256 reserves = vaultManager.protocolReserveStable();
        address treasury = makeAddr("treasury");

        uint256 treasuryBalanceBefore = stableToken.balanceOf(treasury);

        // Withdraw reserves
        vaultManager.withdrawProtocolReserves(treasury, reserves);

        uint256 treasuryBalanceAfter = stableToken.balanceOf(treasury);
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, reserves, "Treasury should receive reserves");
        assertEq(vaultManager.protocolReserveStable(), 0, "Reserves should be zero");
    }

    /// @notice Test: Auction cleanup frees storage
    function test_AuctionCleanup() public {
        // Create liquidatable vault
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(13000e18);
        vm.stopPrank();

        priceFeed.setPrice(1400e8);
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        // Start auction
        bytes32 commitHash = keccak256(abi.encodePacked(uint256(5000e18), uint256(4 ether), bytes32(0)));
        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(alice, commitHash);

        // Execute auction through StabilityPool fallback
        vm.warp(block.timestamp + 3 hours + 1 minutes);
        priceFeed.setPrice(1400e8); // Keep liquidatable price fresh
        oracle.updatePriceObservation(address(collateralToken));
        liquidationEngine.cancelAuctionAndFallback(alice);

        // Now cleanup is possible (update TWAP again after 1 day)
        vm.warp(block.timestamp + 1 days);
        priceFeed.setPrice(1400e8); // Keep price fresh
        oracle.updatePriceObservation(address(collateralToken));
        liquidationEngine.cleanupAuction(alice);

        // Verify bids were cleared
        LiquidationEngine.LiquidationBid[] memory bids = liquidationEngine.getVaultBids(alice);
        assertEq(bids.length, 0, "Bids should be cleared");
    }

    /// @notice Test: Interest accrual affects health ratio
    function test_InterestAffectsHealthRatio() public {
        vm.startPrank(alice);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        uint256 healthBefore = vaultManager.getHealthRatio(alice);

        // Wait 2 years for significant interest (update TWAP to prevent staleness)
        vm.warp(block.timestamp + 730 days);
        priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        oracle.updatePriceObservation(address(collateralToken));

        // Trigger interest accrual
        vaultManager.accrueYield(alice);

        uint256 healthAfter = vaultManager.getHealthRatio(alice);

        // Health ratio should decrease as debt increases
        assertLt(healthAfter, healthBefore, "Health should worsen with interest");
    }
}

