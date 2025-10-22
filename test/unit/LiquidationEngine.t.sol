// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

/// @notice This test file has been deprecated in favor of comprehensive attack tests
/// @dev See test/attack/ folder for MEV, flash loan, and griefing attack tests
contract LiquidationEngineTest is Test {
    LiquidationEngine public liquidationEngine;
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public vaultOwner;
    address public liquidator;

    uint256 constant INITIAL_COLLATERAL = 10 ether;
    uint256 constant COLLATERAL_PRICE = 2000e8; // $2000

    event LiquidationCommitted(address indexed liquidator, address indexed vault, bytes32 commitHash, uint256 deposit);
    event LiquidationRevealed(address indexed liquidator, address indexed vault, uint256 bidAmount, uint256 collateralRequested);
    event AuctionFinalized(address indexed vault, address indexed winner, uint256 debtRepaid, uint256 collateralSeized);

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
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

        liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(stableToken),
            address(collateralToken),
            address(oracle),
            address(0) // No StabilityPool in basic unit tests
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

        // Setup vault owner with collateral
        collateralToken.mint(vaultOwner, INITIAL_COLLATERAL);
        
        // Create an undercollateralized vault
        vm.startPrank(vaultOwner);
        collateralToken.approve(address(vaultManager), INITIAL_COLLATERAL);
        vaultManager.depositCollateral(INITIAL_COLLATERAL);
        vm.roll(block.number + 1); // Advance block for MIN_BORROW_DELAY
        vaultManager.borrow(13000e18); // Borrow $13k against $20k collateral (healthy: 154% ratio)
        vm.stopPrank();

        // Drop collateral price to make vault liquidatable
        priceFeed.setPrice(1500e8); // Drop to $1500 ($15k collateral, $13k debt = 115% - liquidatable)
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        // Setup liquidator
        vm.deal(liquidator, 1 ether);
    }

    function test_CommitLiquidation() public {
        uint256 bidAmount = 5000e18;
        uint256 collateralRequested = 4 ether;
        bytes32 salt = keccak256("random_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, collateralRequested, salt);

        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        LiquidationEngine.LiquidationCommit memory commit = liquidationEngine.getCommitment(liquidator, vaultOwner);
        
        assertEq(commit.commitHash, commitHash);
        assertEq(commit.commitTime, block.timestamp);
        assertEq(commit.deposit, 0.1 ether);
        assertFalse(commit.revealed);
    }

    function test_RevealLiquidation() public {
        uint256 bidAmount = 5000e18;
        uint256 collateralRequested = 4 ether;
        bytes32 salt = keccak256("random_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, collateralRequested, salt);

        // Commit
        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        // Wait for minimum commit period
        vm.warp(block.timestamp + 3 minutes);

        // Setup liquidator with stablecoins
        stableToken.addMinter(liquidator);
        vm.prank(liquidator);
        stableToken.mint(liquidator, bidAmount);

        // Approve and reveal
        vm.startPrank(liquidator);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, collateralRequested, salt);
        vm.stopPrank();

        LiquidationEngine.LiquidationCommit memory commit = liquidationEngine.getCommitment(liquidator, vaultOwner);
        assertTrue(commit.revealed);
    }

    function test_FinalizeAuction() public {
        uint256 bidAmount = 5000e18;
        uint256 collateralRequested = 4 ether;
        bytes32 salt = keccak256("random_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, collateralRequested, salt);

        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        vm.warp(block.timestamp + 3 minutes);

        stableToken.addMinter(liquidator);
        vm.startPrank(liquidator);
        stableToken.mint(liquidator, bidAmount);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, collateralRequested, salt);
        vm.stopPrank();

        // Wait for auction to end (updated for new 10-minute auction duration)
        vm.warp(block.timestamp + 11 minutes);

        // Finalize
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertTrue(auction.executed);
        assertEq(auction.winner, liquidator);
    }

    function test_RevertWhen_CommitWithoutDeposit() public {
        bytes32 commitHash = keccak256("test");

        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.InsufficientDeposit.selector);
        liquidationEngine.commitLiquidation(vaultOwner, commitHash);
    }

    function test_RevertWhen_RevealTooEarly() public {
        uint256 bidAmount = 5000e18;
        uint256 collateralRequested = 4 ether;
        bytes32 salt = keccak256("random_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, collateralRequested, salt);

        vm.prank(liquidator);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        // Try to reveal immediately
        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.InvalidCommitPeriod.selector);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, collateralRequested, salt);
    }

    function test_IsLiquidatable() public {
        assertTrue(liquidationEngine.isLiquidatable(vaultOwner));

        // Wait for cooldown period before next update
        vm.warp(block.timestamp + 6 minutes);
        
        // Increase price to make it healthy
        priceFeed.setPrice(2500e8);
        oracle.updatePriceObservation(address(collateralToken));
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(address(collateralToken));

        assertFalse(liquidationEngine.isLiquidatable(vaultOwner));
    }
}
