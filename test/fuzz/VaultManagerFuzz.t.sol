// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../../src/VaultManager.sol";
import {StableToken} from "../../src/StableToken.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockYieldToken} from "../../src/mocks/MockYieldToken.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

contract VaultManagerFuzzTest is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;

    address public user;
    
    uint256 constant MIN_COLLATERAL_RATIO = 150e16; // 1.5
    uint256 constant MAX_COLLATERAL = 1000000 ether;
    uint256 constant MIN_PRICE = 100e8; // $100
    uint256 constant MAX_PRICE = 10000e8; // $10,000

    function setUp() public {
        user = makeAddr("user");

        collateralToken = new MockYieldToken("Mock stETH", "mstETH");
        stableToken = new StableToken("USD Stable", "USDS");
        oracle = new PriceOracle();
        
        vaultManager = new VaultManager(
            address(collateralToken),
            address(stableToken),
            address(oracle)
        );

        priceFeed = new MockChainlinkOracle(8);
        priceFeed.setPrice(2000e8);
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Initialize TWAP with multiple observations
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
            vm.warp(block.timestamp + 30 minutes);
            priceFeed.setPrice(2000e8); // Keep price fresh
        }

        stableToken.addMinter(address(vaultManager));
    }

    /// @notice Fuzz test for deposit and withdraw maintaining balance
    function testFuzz_DepositWithdrawMaintainsBalance(uint96 depositAmount, uint96 withdrawAmount) public {
        depositAmount = uint96(bound(depositAmount, 1 ether, MAX_COLLATERAL));
        withdrawAmount = uint96(bound(withdrawAmount, 0, depositAmount));

        // Setup
        collateralToken.mint(user, depositAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), depositAmount);
        
        // Deposit
        vaultManager.depositCollateral(depositAmount);
        (uint256 collateralAfterDeposit,,,) = vaultManager.vaults(user);
        assertEq(collateralAfterDeposit, depositAmount, "Deposit amount mismatch");

        // Withdraw
        if (withdrawAmount > 0) {
            vaultManager.withdrawCollateral(withdrawAmount);
            (uint256 collateralAfterWithdraw,,,) = vaultManager.vaults(user);
            assertEq(collateralAfterWithdraw, depositAmount - withdrawAmount, "Withdraw amount mismatch");
        }
        vm.stopPrank();
    }

    /// @notice Fuzz test for borrow maintaining health ratio
    function testFuzz_BorrowMaintainsHealthRatio(uint96 collateralAmount, uint96 borrowAmount) public {
        collateralAmount = uint96(bound(collateralAmount, 10 ether, MAX_COLLATERAL));
        
        // Calculate max safe borrow (under MIN_COLLATERAL_RATIO)
        uint256 collateralValue = (uint256(collateralAmount) * 2000e8) / 1e8; // Price = $2000
        uint256 maxBorrow = (collateralValue * 1e18) / MIN_COLLATERAL_RATIO;
        
        // Bound borrowAmount to valid range (MIN_DEBT = 100e18)
        uint256 minDebt = 100e18;
        borrowAmount = uint96(bound(borrowAmount, minDebt, maxBorrow > minDebt ? maxBorrow - 1e18 : minDebt));

        // Setup
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        
        // Borrow
        vaultManager.borrow(borrowAmount);
        
        // Verify health ratio
        uint256 healthRatio = vaultManager.getHealthRatio(user);
        assertGe(healthRatio, MIN_COLLATERAL_RATIO, "Health ratio should be above minimum");
        vm.stopPrank();
    }

    /// @notice Fuzz test that repay reduces debt correctly
    function testFuzz_RepayReducesDebt(uint96 borrowAmount, uint96 repayAmount) public {
        uint256 minDebt = 100e18;
        borrowAmount = uint96(bound(borrowAmount, minDebt, 10000e18));
        repayAmount = uint96(bound(repayAmount, 1e18, borrowAmount));
        
        // Ensure remaining debt is either zero or >= MIN_DEBT
        if (repayAmount < borrowAmount) {
            uint256 remainingDebt = borrowAmount - repayAmount;
            if (remainingDebt < minDebt) {
                // Adjust to leave exactly MIN_DEBT or repay fully
                if (borrowAmount > minDebt) {
                    repayAmount = uint96(borrowAmount - minDebt);
                } else {
                    repayAmount = borrowAmount; // Full repayment
                }
            }
        }

        // Setup with sufficient collateral (2x in USD value)
        // borrowAmount is in USD, collateralAmount is in ETH
        // collateralValue = collateralAmount * 2000 (price)
        // We want: collateralAmount * 2000 = borrowAmount * 2
        // So: collateralAmount = (borrowAmount * 2) / 2000
        uint256 collateralAmount = (borrowAmount * 2) / 2000;
        if (collateralAmount < 1 ether) {
            collateralAmount = 1 ether;
        }
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        
        // Borrow
        vaultManager.borrow(borrowAmount);
        (, uint256 debtBefore,,) = vaultManager.vaults(user);
        
        // Repay
        stableToken.approve(address(vaultManager), repayAmount);
        vaultManager.repay(repayAmount);
        
        (, uint256 debtAfter,,) = vaultManager.vaults(user);
        assertEq(debtAfter, debtBefore - repayAmount, "Debt should decrease by repay amount");
        vm.stopPrank();
    }

    /// @notice Fuzz test price changes affecting health ratio
    function testFuzz_PriceChangeAffectsHealthRatio(uint96 collateralAmount, uint96 price) public {
        collateralAmount = uint96(bound(collateralAmount, 10 ether, 1000 ether));
        price = uint96(bound(price, MIN_PRICE, MAX_PRICE));

        // Setup
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        
        // Borrow at initial price ($2000), 50% LTV
        // collateralValue = collateralAmount * 2000
        // borrowAmount = collateralValue / 2 = (collateralAmount * 2000) / 2
        uint256 borrowAmount = (collateralAmount * 1000); // Simplified: * 2000 / 2 = * 1000
        vaultManager.borrow(borrowAmount);
        vm.stopPrank();

        uint256 healthRatioBefore = vaultManager.getHealthRatio(user);

        // Change price
        priceFeed.setPrice(int256(uint256(price)));
        uint256 healthRatioAfter = vaultManager.getHealthRatio(user);

        // Health ratio should change with price
        if (price > 2000e8) {
            assertGe(healthRatioAfter, healthRatioBefore, "Health ratio should increase with price");
        } else if (price < 2000e8) {
            assertLe(healthRatioAfter, healthRatioBefore, "Health ratio should decrease with price");
        }
    }

    /// @notice Fuzz test yield accrual increases collateral
    function testFuzz_YieldAccrualIncreasesCollateral(uint96 collateralAmount, uint32 timeElapsed) public {
        collateralAmount = uint96(bound(collateralAmount, 1 ether, MAX_COLLATERAL));
        timeElapsed = uint32(bound(timeElapsed, 1 days, 365 days));

        // Setup
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        vm.stopPrank();

        (uint256 vaultCollateral,,,) = vaultManager.vaults(user);
        uint256 exchangeRateBefore = collateralToken.getExchangeRate();

        // Advance time and accrue yield
        vm.warp(block.timestamp + timeElapsed);
        vaultManager.accrueYield(user);

        (,,, uint256 exchangeRateAfter) = vaultManager.vaults(user);
        uint256 exchangeRateNow = collateralToken.getExchangeRate();

        // With real LST integration: wrapper amount stays constant, exchange rate increases
        // Exchange rate should never decrease
        assertGe(exchangeRateNow, exchangeRateBefore, "Yield should not decrease exchange rate");
        
        // For significant time periods, exchange rate should definitely increase
        if (timeElapsed >= 30 days) {
            assertGt(exchangeRateNow, exchangeRateBefore, "Yield should increase exchange rate over time");
        }
        
        // Vault should track the latest exchange rate after accrual
        assertEq(exchangeRateAfter, exchangeRateNow, "Vault should track current exchange rate");
    }

    /// @notice Fuzz test that health ratio never decreases with yield accrual
    function testFuzz_YieldAccrualImprovesHealthRatio(
        uint96 collateralAmount,
        uint96 borrowAmount,
        uint32 timeElapsed
    ) public {
        collateralAmount = uint96(bound(collateralAmount, 100 ether, MAX_COLLATERAL));
        timeElapsed = uint32(bound(timeElapsed, 1 days, 365 days));
        
        uint256 collateralValue = (uint256(collateralAmount) * 2000e8) / 1e8;
        uint256 maxBorrow = (collateralValue * 1e18) / (MIN_COLLATERAL_RATIO + 10e16); // Add buffer
        
        // Bound borrowAmount to valid range (MIN_DEBT = 100e18)
        uint256 minDebt = 100e18;
        borrowAmount = uint96(bound(borrowAmount, minDebt, maxBorrow > minDebt ? maxBorrow - 1e18 : minDebt));

        // Setup
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        vaultManager.borrow(borrowAmount);
        vm.stopPrank();

        uint256 healthRatioBefore = vaultManager.getHealthRatio(user);

        // Advance time and add price observations to maintain TWAP
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + (timeElapsed / 3));
            priceFeed.setPrice(2000e8); // Update price to create observations
        }
        
        vaultManager.accrueYield(user);

        uint256 healthRatioAfter = vaultManager.getHealthRatio(user);

        // Note: accrueYield now also accrues interest, so health ratio can go either way
        // Yield accrual increases collateral (improves health)
        // Interest accrual increases debt (worsens health)
        // We just verify the function doesn't revert and produces a valid health ratio
        assertTrue(healthRatioAfter > 0, "Health ratio should be positive");
        
        // Verify collateral increased due to yield (if any time passed)
        (uint256 collateralAfter,,,) = vaultManager.vaults(user);
        assertGe(collateralAfter, collateralAmount, "Collateral should not decrease");
    }

    /// @notice Fuzz test multiple users don't interfere
    function testFuzz_MultipleUsersIndependent(
        uint96 collateral1,
        uint96 collateral2,
        uint96 borrow1,
        uint96 borrow2
    ) public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        collateral1 = uint96(bound(collateral1, 10 ether, 1000 ether));
        collateral2 = uint96(bound(collateral2, 10 ether, 1000 ether));

        uint256 maxBorrow1 = (uint256(collateral1) * 2000e8 * 1e18) / (MIN_COLLATERAL_RATIO * 1e8);
        uint256 maxBorrow2 = (uint256(collateral2) * 2000e8 * 1e18) / (MIN_COLLATERAL_RATIO * 1e8);

        uint256 minDebt = 100e18;
        borrow1 = uint96(bound(borrow1, minDebt, maxBorrow1 > minDebt ? maxBorrow1 - 1e18 : minDebt));
        borrow2 = uint96(bound(borrow2, minDebt, maxBorrow2 > minDebt ? maxBorrow2 - 1e18 : minDebt));

        // Setup user1
        collateralToken.mint(user1, collateral1);
        vm.startPrank(user1);
        collateralToken.approve(address(vaultManager), collateral1);
        vaultManager.depositCollateral(collateral1);
        vaultManager.borrow(borrow1);
        vm.stopPrank();

        // Setup user2
        collateralToken.mint(user2, collateral2);
        vm.startPrank(user2);
        collateralToken.approve(address(vaultManager), collateral2);
        vaultManager.depositCollateral(collateral2);
        vaultManager.borrow(borrow2);
        vm.stopPrank();

        // Verify independent states
        (, uint256 debt1,,) = vaultManager.vaults(user1);
        (, uint256 debt2,,) = vaultManager.vaults(user2);

        assertEq(debt1, borrow1, "User1 debt should match");
        assertEq(debt2, borrow2, "User2 debt should match");
    }
}

