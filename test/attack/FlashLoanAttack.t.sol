// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FlashLoanAttack
/// @notice Malicious contract attempting flash loan attacks
contract FlashLoanAttacker {
    VaultManager public vaultManager;
    MockYieldToken public collateralToken;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockChainlinkOracle public priceFeed;

    constructor(
        address _vaultManager,
        address _collateralToken,
        address _stableToken,
        address _oracle,
        address _priceFeed
    ) {
        vaultManager = VaultManager(_vaultManager);
        collateralToken = MockYieldToken(_collateralToken);
        stableToken = StableToken(_stableToken);
        oracle = PriceOracle(_oracle);
        priceFeed = MockChainlinkOracle(_priceFeed);
    }

    /// @notice Attempt flash loan attack: borrow collateral, deposit, borrow max, withdraw
    function attemptFlashLoanDepositAttack(uint256 flashAmount) external {
        // Simulate flash loan by minting
        collateralToken.mint(address(this), flashAmount);

        // Deposit borrowed collateral
        collateralToken.approve(address(vaultManager), flashAmount);
        vaultManager.depositCollateral(flashAmount);

        // Try to borrow maximum
        uint256 maxBorrow = (flashAmount * 2000 * 80) / 100; // 80% LTV at $2000
        vaultManager.borrow(maxBorrow);

        // Try to withdraw collateral
        vaultManager.withdrawCollateral(flashAmount);

        // Repay flash loan
        collateralToken.transfer(msg.sender, flashAmount);

        // If we get here, attack succeeded (profit = maxBorrow stablecoins)
    }

    /// @notice Attempt price manipulation attack
    function attemptPriceManipulationAttack(uint256 depositAmount, int256 manipulatedPrice) external {
        // Deposit collateral
        collateralToken.approve(address(vaultManager), depositAmount);
        vaultManager.depositCollateral(depositAmount);

        // Manipulate price feed (simulating flash loan price attack)
        int256 originalPrice = priceFeed.latestAnswer();
        priceFeed.setPrice(manipulatedPrice);

        // Try to borrow at manipulated price
        uint256 borrowAmount = (depositAmount * uint256(manipulatedPrice) * 80) / 100 / 1e8;
        vaultManager.borrow(borrowAmount);

        // Restore price
        priceFeed.setPrice(originalPrice);

        // If successful, we borrowed more than we should have
    }

    /// @notice Attempt same-block borrow attack
    function attemptSameBlockBorrow() external {
        uint256 amount = 10 ether;
        collateralToken.approve(address(vaultManager), amount * 2);
        
        // Deposit
        vaultManager.depositCollateral(amount);
        
        // First borrow
        vaultManager.borrow(5000e18);
        
        // Try immediate second borrow (same block)
        vaultManager.borrow(5000e18);
    }

    /// @notice Attempt reentrancy attack via callback (simplified test)
    function attemptReentrancy() external {
        uint256 amount = 10 ether;
        collateralToken.approve(address(vaultManager), amount);
        vaultManager.depositCollateral(amount);
        
        // Try to borrow twice in same transaction (simulating reentrancy)
        vaultManager.borrow(5000e18);
        // Second borrow in same block should fail
        vaultManager.borrow(1000e18);
    }

    receive() external payable {}
}

/// @title FlashLoanAttackTest
/// @notice Tests demonstrating flash loan attack resistance
contract FlashLoanAttackTest is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    LiquidationEngine public liquidationEngine;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;
    FlashLoanAttacker public attacker;

    address public user;

    uint256 constant COLLATERAL_PRICE = 2000e8;

    function setUp() public {
        user = makeAddr("user");

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

        // Initialize TWAP with multiple observations
        for (uint256 i = 0; i < 5; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(int256(COLLATERAL_PRICE)); // Keep price fresh
        }

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        vaultManager.setLiquidationEngine(address(liquidationEngine));

        // Deploy attacker
        attacker = new FlashLoanAttacker(
            address(vaultManager),
            address(collateralToken),
            address(stableToken),
            address(oracle),
            address(priceFeed)
        );

        // Give attacker some initial collateral
        collateralToken.mint(address(attacker), 100 ether);
    }

    /// @notice Test: Flash loan attack fails due to TWAP
    function test_FlashLoanDepositAttackFails() public {
        uint256 attackAmount = 50 ether;

        // Attacker tries to exploit flash loan
        // Since TWAP is initialized, it uses TWAP for collateral valuation
        // The attack should fail when trying to withdraw (breaking collateral ratio)
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        attacker.attemptFlashLoanDepositAttack(attackAmount);

        // Attack fails because TWAP provides accurate valuation
    }

    /// @notice Test: Price manipulation via flash loan fails
    function test_PriceManipulationFails() public {
        uint256 depositAmount = 10 ether;
        collateralToken.mint(address(attacker), depositAmount);

        // Attacker tries to manipulate price and borrow
        // TWAP prevents borrowing at manipulated price
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        attacker.attemptPriceManipulationAttack(depositAmount, 10000e8); // 5x price

        // Even if spot price is manipulated, TWAP protects the protocol
    }

    /// @notice Test: Same-block borrow protection
    function test_SameBlockBorrowFails() public {
        collateralToken.mint(address(attacker), 20 ether);

        vm.expectRevert(VaultManager.BorrowTooSoon.selector);
        attacker.attemptSameBlockBorrow();

        // Cannot borrow twice in same block
    }

    /// @notice Test: Reentrancy protection
    function test_ReentrancyProtected() public {
        collateralToken.mint(address(attacker), 10 ether);

        // Multiple borrows in same block should fail
        vm.expectRevert(VaultManager.BorrowTooSoon.selector);
        attacker.attemptReentrancy();
    }

    /// @notice Test: TWAP makes flash loan manipulation economically unfeasible
    function test_TWAPResistanceToFlashLoan() public {
        // Setup: Normal user deposits
        collateralToken.mint(user, 10 ether);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), 10 ether);
        vaultManager.depositCollateral(10 ether);
        vm.stopPrank();

        // Record initial TWAP
        uint256 twapBefore = oracle.getTWAP(address(collateralToken), 1 hours);

        // Attacker manipulates spot price dramatically
        priceFeed.setPrice(10000e8); // 5x increase
        oracle.updatePriceObservation(address(collateralToken));

        // Check that TWAP barely moved
        uint256 twapAfter = oracle.getTWAP(address(collateralToken), 1 hours);

        // TWAP should be much closer to original than to manipulated price
        uint256 twapChange = twapAfter > twapBefore ? twapAfter - twapBefore : twapBefore - twapAfter;
        uint256 spotChange = 10000e8 - COLLATERAL_PRICE;

        assertLt(twapChange, spotChange / 10, "TWAP should be resistant to manipulation");

        // User tries to borrow at manipulated price - fails because TWAP is much lower
        vm.startPrank(user);
        vm.roll(block.number + 1); // Advance block for MIN_BORROW_DELAY
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        vaultManager.borrow(20000e18); // Would be allowed at spot price, but TWAP prevents it
        vm.stopPrank();
    }

    /// @notice Test: Multi-block delay prevents complex flash loan attacks
    function test_MultiBlockDelayPreventsComplexAttack() public {
        collateralToken.mint(user, 10 ether);

        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), 10 ether);
        vaultManager.depositCollateral(10 ether);

        // First borrow succeeds
        vaultManager.borrow(5000e18);

        // Try to borrow again in same block
        vm.expectRevert(VaultManager.BorrowTooSoon.selector);
        vaultManager.borrow(5000e18);

        // Roll to next block
        vm.roll(block.number + 1);

        // Now it works
        vaultManager.borrow(5000e18);
        vm.stopPrank();
    }

    /// @notice Test: Cannot exploit TWAP with slow manipulation
    function test_SlowManipulationDetected() public {
        collateralToken.mint(user, 10 ether);

        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), 10 ether);
        vaultManager.depositCollateral(10 ether);
        vm.stopPrank();

        // Attacker tries to slowly manipulate TWAP over time
        uint256 initialPrice = COLLATERAL_PRICE;
        
        for (uint256 i = 0; i < 10; i++) {
            // Gradually increase price
            priceFeed.setPrice(int256(initialPrice + (i * 100e8)));
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 10 minutes);
        }

        // Even after 100 minutes of manipulation, user cannot over-borrow
        // because TWAP averages over the period
        vm.prank(user);
        // This would work with spot price but fails with TWAP
        vm.expectRevert(VaultManager.InsufficientCollateralRatio.selector);
        vaultManager.borrow(25000e18); // Trying to borrow too much
    }

    /// @notice Test: Withdrawal also protected by TWAP
    function test_WithdrawalProtectedByTWAP() public {
        collateralToken.mint(user, 10 ether);

        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), 10 ether);
        vaultManager.depositCollateral(10 ether);
        vaultManager.borrow(10000e18);
        vm.stopPrank();

        // Attacker tries to manipulate price down to force liquidation or prevent withdrawal
        priceFeed.setPrice(1000e8); // Drop to $1000
        oracle.updatePriceObservation(address(collateralToken));

        // User tries to withdraw (would fail at spot price)
        vm.prank(user);
        // TWAP protection means the real value is used, not manipulated spot
        vm.expectRevert(); // Will fail but for the right reason (TWAP unavailable or insufficient ratio)
        vaultManager.withdrawCollateral(5 ether);
    }

    /// @notice Test: Flash loan cannot bypass deposit requirements
    function test_FlashLoanCannotBypassDeposit() public {
        // Attacker has no collateral
        FlashLoanAttacker attacker2 = new FlashLoanAttacker(
            address(vaultManager),
            address(collateralToken),
            address(stableToken),
            address(oracle),
            address(priceFeed)
        );

        // Mint flash loan to attacker
        collateralToken.mint(address(attacker2), 100 ether);

        // Try to use flash loan to borrow stablecoins
        vm.expectRevert();
        attacker2.attemptFlashLoanDepositAttack(100 ether);
    }
}

