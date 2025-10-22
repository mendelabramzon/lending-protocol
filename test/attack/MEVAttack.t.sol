// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

/// @title MEVAttackTest
/// @notice Tests demonstrating MEV resistance of the liquidation mechanism
contract MEVAttackTest is Test {
    LiquidationEngine public liquidationEngine;
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public vaultOwner;
    address public liquidatorA;
    address public liquidatorB;
    address public mevBot;

    uint256 constant INITIAL_COLLATERAL = 10 ether;
    uint256 constant COLLATERAL_PRICE = 2000e8;

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
        liquidatorA = makeAddr("liquidatorA");
        liquidatorB = makeAddr("liquidatorB");
        mevBot = makeAddr("mevBot");

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

        // Update price observations for TWAP
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        }

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(liquidationEngine));
        vaultManager.setLiquidationEngine(address(liquidationEngine));

        // Setup vault owner
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

        // Setup liquidators with funds
        vm.deal(liquidatorA, 1 ether);
        vm.deal(liquidatorB, 1 ether);
        vm.deal(mevBot, 1 ether);

        stableToken.addMinter(liquidatorA);
        stableToken.addMinter(liquidatorB);
        stableToken.addMinter(mevBot);

        vm.prank(liquidatorA);
        stableToken.mint(liquidatorA, 10000e18);
        vm.prank(liquidatorB);
        stableToken.mint(liquidatorB, 10000e18);
        vm.prank(mevBot);
        stableToken.mint(mevBot, 10000e18);
    }

    /// @notice Test: MEV bot cannot front-run during commit phase
    function test_CannotFrontRunCommit() public {
        uint256 bidAmount = 5000e18;
        uint256 collateralRequested = 4 ether;
        bytes32 saltA = keccak256("liquidatorA_salt");

        // LiquidatorA prepares commitment
        bytes32 commitHashA = liquidationEngine.generateCommitHash(
            bidAmount,
            collateralRequested,
            saltA
        );

        // LiquidatorA commits
        vm.prank(liquidatorA);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHashA);

        // MEV bot sees the commit in mempool and tries to commit with better terms
        bytes32 saltMEV = keccak256("mev_salt");
        uint256 betterCollateral = 3.5 ether; // Better bid
        bytes32 commitHashMEV = liquidationEngine.generateCommitHash(
            bidAmount,
            betterCollateral,
            saltMEV
        );

        // MEV bot can commit, but this doesn't prevent liquidatorA from revealing
        vm.prank(mevBot);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHashMEV);

        // Both can reveal after MIN_COMMIT_PERIOD
        vm.warp(block.timestamp + 3 minutes);

        // LiquidatorA reveals first
        vm.startPrank(liquidatorA);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, collateralRequested, saltA);
        vm.stopPrank();

        // MEV bot also reveals
        vm.startPrank(mevBot);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, betterCollateral, saltMEV);
        vm.stopPrank();

        // Wait for auction to end (updated for new 10-minute auction duration)
        vm.warp(block.timestamp + 11 minutes);

        // Finalize auction - MEV bot wins because it offered lower collateral
        liquidationEngine.finalizeAuction(vaultOwner);

        // Check winner
        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        
        // MEV bot wins, but this is FAIR because:
        // 1. They paid deposit
        // 2. They offered better terms for protocol
        // 3. No timing manipulation advantage
        assertEq(auction.winner, mevBot, "Best bid should win");
    }

    /// @notice Test: Cannot front-run reveal phase (first reveal doesn't win automatically)
    function test_CannotFrontRunReveal() public {
        uint256 bidAmount = 5000e18;
        bytes32 saltA = keccak256("liquidatorA_salt");
        bytes32 saltB = keccak256("liquidatorB_salt");

        // Both liquidators commit
        bytes32 commitHashA = liquidationEngine.generateCommitHash(bidAmount, 4 ether, saltA);
        bytes32 commitHashB = liquidationEngine.generateCommitHash(bidAmount, 3.8 ether, saltB);

        vm.prank(liquidatorA);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHashA);

        vm.prank(liquidatorB);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHashB);

        // Wait for commit period
        vm.warp(block.timestamp + 3 minutes);

        // LiquidatorA reveals first (tries to win by being first)
        vm.startPrank(liquidatorA);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 4 ether, saltA);
        vm.stopPrank();

        // LiquidatorB reveals later with better bid
        vm.startPrank(liquidatorB);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 3.8 ether, saltB);
        vm.stopPrank();

        // Wait for auction to end (updated for new 10-minute auction duration)
        vm.warp(block.timestamp + 11 minutes);

        // Finalize - best bid wins, not first reveal
        liquidationEngine.finalizeAuction(vaultOwner);

        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        
        assertEq(auction.winner, liquidatorB, "Best bid wins, not first reveal");
    }

    /// @notice Test: Griefing attack is prevented by deposits
    function test_GriefingAttackPrevented() public {
        bytes32 saltAttacker = keccak256("attacker_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(5000e18, 4 ether, saltAttacker);

        // Attacker commits but doesn't reveal (griefing attempt)
        vm.prank(mevBot);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        // Legitimate liquidator can still commit
        bytes32 saltLegit = keccak256("legit_salt");
        bytes32 commitHashLegit = liquidationEngine.generateCommitHash(5000e18, 3.9 ether, saltLegit);

        vm.prank(liquidatorA);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHashLegit);

        // Wait and reveal
        vm.warp(block.timestamp + 3 minutes);

        vm.startPrank(liquidatorA);
        stableToken.approve(address(liquidationEngine), 5000e18);
        liquidationEngine.revealLiquidation(vaultOwner, 5000e18, 3.9 ether, saltLegit);
        vm.stopPrank();

        // Wait for auction end (updated for new 10-minute auction duration)
        vm.warp(block.timestamp + 11 minutes);

        // Finalize
        liquidationEngine.finalizeAuction(vaultOwner);

        // LiquidatorA wins
        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertEq(auction.winner, liquidatorA);

        // Attacker loses deposit (cannot claim refund)
        vm.warp(block.timestamp + 3 hours); // Past MAX_COMMIT_PERIOD

        // Check deposit before
        uint256 balanceBefore = mevBot.balance;
        
        vm.prank(mevBot);
        // Calling claimRefund slashes the deposit (no refund given)
        liquidationEngine.claimRefund(vaultOwner);
        
        // Balance unchanged (deposit was slashed, not refunded)
        assertEq(mevBot.balance, balanceBefore, "Griefer should not get refund");
    }

    /// @notice Test: Sandwich attack during liquidation is prevented
    function test_SandwichAttackPrevented() public {
        // This test demonstrates that price manipulation during liquidation doesn't work
        // because we use TWAP instead of spot price

        uint256 bidAmount = 5000e18;
        bytes32 salt = keccak256("liquidator_salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, salt);

        vm.prank(liquidatorA);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        vm.warp(block.timestamp + 3 minutes);

        // MEV bot tries to manipulate price upward right before reveal
        priceFeed.setPrice(2000e8); // Pump price

        // Reveal happens - but uses TWAP not spot price
        vm.startPrank(liquidatorA);
        stableToken.approve(address(liquidationEngine), bidAmount);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 4 ether, salt);
        vm.stopPrank();

        // MEV bot dumps price back
        priceFeed.setPrice(1400e8);

        vm.warp(block.timestamp + 31 minutes);

        // Finalize - liquidation used TWAP so manipulation didn't work
        liquidationEngine.finalizeAuction(vaultOwner);

        // Verify vault was liquidated (if manipulation worked, it wouldn't be)
        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertTrue(auction.executed, "Liquidation should execute despite price manipulation");
    }

    /// @notice Test: Deposit requirement prevents spam attacks
    function test_DepositPreventsSpa() public {
        // Attacker tries to commit without sufficient deposit
        bytes32 commitHash = keccak256("test");

        vm.prank(mevBot);
        vm.expectRevert(LiquidationEngine.InsufficientDeposit.selector);
        liquidationEngine.commitLiquidation{value: 0.01 ether}(vaultOwner, commitHash);
    }

    /// @notice Test: Time windows prevent atomic MEV
    function test_TimeWindowsPreventAtomicMEV() public {
        uint256 bidAmount = 5000e18;
        bytes32 salt = keccak256("salt");
        bytes32 commitHash = liquidationEngine.generateCommitHash(bidAmount, 4 ether, salt);

        vm.prank(liquidatorA);
        liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);

        // Try to reveal immediately (atomic attack)
        vm.startPrank(liquidatorA);
        stableToken.approve(address(liquidationEngine), bidAmount);
        
        vm.expectRevert(LiquidationEngine.InvalidCommitPeriod.selector);
        liquidationEngine.revealLiquidation(vaultOwner, bidAmount, 4 ether, salt);
        vm.stopPrank();

        // This prevents MEV bots from commit+reveal in same block
    }

    /// @notice Test: Multiple liquidators create competitive market
    function test_CompetitiveBiddingWorks() public {
        uint256 bidAmount = 5000e18;
        
        // Three liquidators with different bids
        address[] memory liquidators = new address[](3);
        liquidators[0] = liquidatorA;
        liquidators[1] = liquidatorB;
        liquidators[2] = mevBot;

        uint256[] memory collateralBids = new uint256[](3);
        collateralBids[0] = 4.0 ether;  // Highest collateral requested
        collateralBids[1] = 3.8 ether;  // Medium
        collateralBids[2] = 3.6 ether;  // Lowest (best for protocol)

        // All commit
        for (uint256 i = 0; i < 3; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitHash = liquidationEngine.generateCommitHash(
                bidAmount,
                collateralBids[i],
                salt
            );

            vm.prank(liquidators[i]);
            liquidationEngine.commitLiquidation{value: 0.1 ether}(vaultOwner, commitHash);
        }

        vm.warp(block.timestamp + 3 minutes);

        // All reveal
        for (uint256 i = 0; i < 3; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            
            vm.startPrank(liquidators[i]);
            stableToken.approve(address(liquidationEngine), bidAmount);
            liquidationEngine.revealLiquidation(
                vaultOwner,
                bidAmount,
                collateralBids[i],
                salt
            );
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 11 minutes);

        // Finalize
        liquidationEngine.finalizeAuction(vaultOwner);

        // Verify lowest collateral bid won
        LiquidationEngine.Auction memory auction = liquidationEngine.getAuction(vaultOwner);
        assertEq(auction.winner, mevBot, "Most efficient bid should win");
    }
}

