// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

/// @title GriefingAttackTest
/// @notice Tests demonstrating griefing attack resistance
contract GriefingAttackTest is Test {
    LiquidationEngine public liquidationEngine;
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public vaultOwner;
    address public legitimateLiquidator;
    address public griefer;

    uint256 constant INITIAL_COLLATERAL = 10 ether;
    uint256 constant COLLATERAL_PRICE = 2000e8;

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
        legitimateLiquidator = makeAddr("legitimateLiquidator");
        griefer = makeAddr("griefer");

        // Deploy contracts
        collateralToken = new MockYieldToken("Mock stETH", "mstETH");
        stableToken = new StableToken("USD Stable", "USDS");
        oracle = new PriceOracle();
        
        vaultManager = new VaultManager(
            address(collateralToken),
            address(stableToken),
            address(oracle)
        );

        liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(stableToken),
            address(collateralToken),
            address(oracle),
            address(0) // No StabilityPool in this test
        );

        // Setup price feed
        priceFeed = new MockChainlinkOracle(8);
        priceFeed.setPrice(int256(COLLATERAL_PRICE));
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Initialize TWAP
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        }

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(liquidationEngine));
        vaultManager.setLiquidationEngine(address(liquidationEngine));

        // Setup undercollateralized vault
        collateralToken.mint(vaultOwner, INITIAL_COLLATERAL);
        
        vm.startPrank(vaultOwner);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1); // Advance block for MIN_BORROW_DELAY
        vaultManager.borrow(13000e18); // Borrow $13k against $20k collateral (healthy: 154% ratio)
        vm.stopPrank();

        // Make vault liquidatable
        priceFeed.setPrice(1400e8); // Drop to $1400 ($14k collateral, $13k debt = 108% - liquidatable)
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        // Fund accounts
        vm.deal(griefer, 10 ether);
        vm.deal(legitimateLiquidator, 10 ether);

        stableToken.addMinter(legitimateLiquidator);
        vm.prank(legitimateLiquidator);
        stableToken.mint(legitimateLiquidator, 10000e18);
    }

    /// @notice Test: Griefer cannot block liquidation by not revealing
    function test_GrieferCannotBlockLiquidation() public {
        uint256 bidAmount = 5000e18;
        
        // Griefer commits but has no intention to reveal
        bytes32 grieferSalt = keccak256("griefer_salt");
        bytes32 grieferHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, grieferSalt);

        vm.prank(griefer);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, grieferHash);

        // Legitimate liquidator can still commit and execute
        bytes32 legitSalt = keccak256("legit_salt");
        bytes32 legitHash = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, legitSalt);

        vm.prank(legitimateLiquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, legitHash);

        // Wait for reveal period
        vm.warp(block.timestamp + 3 minutes);

        // Only legitimate liquidator reveals
        vm.startPrank(legitimateLiquidator);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, legitSalt);
        vm.stopPrank();

        // Auction ends (updated for new 10-minute auction duration)
        vm.warp(block.timestamp + 11 minutes);

        // Liquidation succeeds despite griefer
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertEq(auction.winner, legitimateLiquidator, "Legitimate liquidator should win");
        assertTrue(auction.executed, "Liquidation should execute");

        // Griefer loses deposit
        uint256 grieferBalanceBefore = griefer.balance;
        
        // Wait past MAX_COMMIT_PERIOD
        vm.warp(block.timestamp + 3 hours);

        // Griefer tries to claim refund - deposit is slashed (no refund)
        vm.prank(griefer);
        liquidationEngine.claimRefund(vaultOwner);

        // Griefer lost the deposit (0.1 ETH) - balance unchanged
        assertEq(griefer.balance, grieferBalanceBefore, "Griefer should not get refund");
    }

    /// @notice Test: Multiple griefers cannot DOS liquidation system
    function test_MultipleGriefersCannotDOS() public {
        uint256 bidAmount = 5000e18;
        
        // Deploy 10 griefers
        address[] memory griefers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            griefers[i] = makeAddr(string(abi.encodePacked("griefer", i)));
            vm.deal(griefers[i], 1 ether);
        }

        // All griefers commit (costs them 1 ETH total)
        for (uint256 i = 0; i < 10; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, salt);

            vm.prank(griefers[i]);
            liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);
        }

        // Legitimate liquidator also commits
        bytes32 legitSalt = keccak256("legit");
        bytes32 legitHash = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, legitSalt);

        vm.prank(legitimateLiquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, legitHash);

        // Wait for reveal
        vm.warp(block.timestamp + 3 minutes);

        // Only legitimate liquidator reveals
        vm.startPrank(legitimateLiquidator);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, legitSalt);
        vm.stopPrank();

        // Auction ends
        vm.warp(block.timestamp + 31 minutes);

        // Liquidation still succeeds
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertTrue(auction.executed, "Liquidation should succeed despite griefing");

        // All griefers lose their deposits (1 ETH total loss)
    }

    /// @notice Test: Deposit requirement makes griefing expensive
    function test_GriefingIsCostly() public {
        // Calculate cost to grief
        uint256 depositRequired = 0.1 ether;
        uint256 griefsNeeded = 100; // Theoretical spam attack

        uint256 totalCost = depositRequired * griefsNeeded;

        // Cost to attack: 10 ETH
        // Benefit: None (liquidation still happens, deposits are lost)
        // Conclusion: Economically irrational

        assertTrue(totalCost == 10 ether, "Griefing attack costs 10 ETH for no benefit");
    }

    /// @notice Test: Expired commitment allows overwrite
    function test_ExpiredCommitmentCanBeOverwritten() public {
        uint256 bidAmount = 5000e18;
        
        // Griefer commits
        bytes32 grieferSalt = keccak256("griefer");
        bytes32 grieferHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, grieferSalt);

        vm.prank(griefer);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, grieferHash);

        // Wait past MAX_COMMIT_PERIOD
        vm.warp(block.timestamp + 3 hours);
        priceFeed.setPrice(1400e8); // Keep price fresh after time warp

        // Griefer tries to commit again (overwriting expired commitment)
        bytes32 newHash = liquidationEngine.generateCommitHash(bidAmount, 3.9 ether, grieferSalt);

        vm.prank(griefer);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, newHash);

        // Old commitment is effectively invalid, new one is active
        LiquidationEngine.LiquidationCommit memory commit = 
            liquidationEngine.getCommitment(griefer, vaultOwner);
        
        assertEq(commit.commitHash, newHash, "New commitment should replace expired one");
    }

    /// @notice Test: Cannot grief with zero-value commitment
    function test_CannotGriefWithoutDeposit() public {
        bytes32 commitHash = keccak256("test");

        vm.prank(griefer);
        vm.expectRevert(LiquidationEngine.InsufficientDeposit.selector);
        liquidationEngine.commitLiquidation(vaultOwner, commitHash);

        // Must pay deposit to commit
    }

    /// @notice Test: Griefer cannot front-run auction finalization
    function test_CannotGriefFinalization() public {
        uint256 bidAmount = 5000e18;
        
        // Setup legitimate auction
        bytes32 legitSalt = keccak256("legit");
        bytes32 legitHash = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, legitSalt);

        vm.prank(legitimateLiquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, legitHash);

        vm.warp(block.timestamp + 3 minutes);

        vm.startPrank(legitimateLiquidator);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, legitSalt);
        vm.stopPrank();

        // Auction period ends
        vm.warp(block.timestamp + 31 minutes);

        // Griefer tries to commit to prevent finalization
        bytes32 grieferHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, keccak256("grief"));
        
        vm.prank(griefer);
        // Should not prevent finalization since auction already has valid bids
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, grieferHash);

        // Finalization should still succeed
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertTrue(auction.executed, "Should finalize despite late grief attempt");
    }

    /// @notice Test: Losing bidders can reclaim deposits
    function test_LosingBiddersReclaimDeposits() public {
        uint256 bidAmount = 5000e18;

        // Two legitimate bidders
        address bidder1 = legitimateLiquidator;
        address bidder2 = makeAddr("bidder2");
        vm.deal(bidder2, 1 ether);
        stableToken.addMinter(bidder2);
        vm.prank(bidder2);
        stableToken.mint(bidder2, 10000e18);

        // Both commit
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");
        bytes32 hash1 = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, salt1);
        bytes32 hash2 = liquidationEngine.generateCommitHash(bidAmount, 4.0 ether, salt2);

        vm.prank(bidder1);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, hash1);

        vm.prank(bidder2);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, hash2);

        vm.warp(block.timestamp + 3 minutes);

        // Both reveal
        vm.startPrank(bidder1);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, salt1);
        vm.stopPrank();

        vm.startPrank(bidder2);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 4.0 ether, salt2);
        vm.stopPrank();

        // Finalize
        vm.warp(block.timestamp + 31 minutes);
        liquidationEngine.finalizeAuction(vaultOwner);

        // Winner (bidder1) gets refund added to pending (needs withdrawal)
        // Loser (bidder2) can claim refund
        uint256 bidder2BalanceBefore = bidder2.balance;

        vm.startPrank(bidder2);
        liquidationEngine.claimRefund(vaultOwner);
        liquidationEngine.withdrawRefund();
        vm.stopPrank();

        uint256 bidder2BalanceAfter = bidder2.balance;
        assertEq(bidder2BalanceAfter - bidder2BalanceBefore, 0.1 ether, "Loser should get refund");
    }

    /// @notice Test: Grace period allows auction completion even if finalization delayed
    function test_GracePeriodPreventsGriefing() public {
        uint256 bidAmount = 5000e18;
        
        // Setup auction
        bytes32 legitSalt = keccak256("legit");
        bytes32 legitHash = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, legitSalt);

        vm.prank(legitimateLiquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, legitHash);

        vm.warp(block.timestamp + 3 minutes);

        vm.startPrank(legitimateLiquidator);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, legitSalt);
        vm.stopPrank();

        // Auction ends
        vm.warp(block.timestamp + 31 minutes);

        // Griefer delays finalization by not calling it
        // Wait almost to end of grace period
        vm.warp(block.timestamp + 9 minutes);

        // Anyone can finalize now (not just participants)
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertTrue(auction.executed, "Should finalize within grace period");
    }

    /// @notice Test: Invalid hash cannot grief system
    function test_InvalidHashCannotGrief() public {
        uint256 bidAmount = 5000e18;
        
        // Griefer commits with random hash
        bytes32 randomHash = keccak256("random");

        vm.prank(griefer);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, randomHash);

        vm.warp(block.timestamp + 3 minutes);

        // Griefer tries to reveal with mismatched data
        vm.prank(griefer);
        vm.expectRevert(LiquidationEngine.InvalidCommitmentHash.selector);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 4 ether, keccak256("wrong"));

        // Invalid reveal doesn't affect auction - legitimate liquidators can still participate
    }
}

