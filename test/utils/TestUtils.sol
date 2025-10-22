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

/// @title TestUtils
/// @notice Utility functions for testing the lending protocol
contract TestUtils is Test {
    uint256 constant WAD = 1e18;
    uint256 constant PRICE_DECIMALS = 1e8;

    /// @notice Calculate expected health ratio
    function calculateHealthRatio(uint256 collateralAmount, uint256 price, uint256 debtAmount)
        internal
        pure
        returns (uint256)
    {
        if (debtAmount == 0) return type(uint256).max;
        uint256 collateralValue = (collateralAmount * price) / PRICE_DECIMALS;
        return (collateralValue * WAD) / debtAmount;
    }

    /// @notice Calculate max borrow amount for given collateral
    function calculateMaxBorrow(uint256 collateralAmount, uint256 price, uint256 minCollateralRatio)
        internal
        pure
        returns (uint256)
    {
        uint256 collateralValue = (collateralAmount * price) / PRICE_DECIMALS;
        return (collateralValue * WAD) / minCollateralRatio;
    }

    /// @notice Create a vault with specific parameters
    function createVault(
        VaultManager vaultManager,
        MockYieldToken collateralToken,
        address user,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        collateralToken.mint(user, collateralAmount);
        
        vm.startPrank(user);
        collateralToken.approve(address(vaultManager), collateralAmount);
        vaultManager.depositCollateral(collateralAmount);
        
        if (borrowAmount > 0) {
            vaultManager.borrow(borrowAmount);
        }
        vm.stopPrank();
    }

    /// @notice Make a vault liquidatable by dropping price
    function makeVaultLiquidatable(
        VaultManager vaultManager,
        MockChainlinkOracle priceFeed,
        address vault
    ) internal {
        (, uint256 debt,,) = vaultManager.vaults(vault);
        if (debt == 0) return;

        // Drop price to make health ratio < 120%
        uint256 newPrice = 1000e8; // Lower price
        priceFeed.setPrice(int256(newPrice));
    }

    /// @notice Setup complete protocol for testing
    function setupProtocol()
        internal
        returns (
            VaultManager vaultManager,
            StableToken stableToken,
            PriceOracle oracle,
            StabilityPool stabilityPool,
            LiquidationEngine liquidationEngine,
            MockYieldToken collateralToken,
            MockChainlinkOracle priceFeed
        )
    {
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
        priceFeed.setPrice(2000e8);
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(stabilityPool));
        vaultManager.setLiquidationEngine(address(liquidationEngine));
        stabilityPool.setLiquidationEngine(address(liquidationEngine));

        return (vaultManager, stableToken, oracle, stabilityPool, liquidationEngine, collateralToken, priceFeed);
    }

    /// @notice Assert health ratio is within expected range
    function assertHealthRatioInRange(
        VaultManager vaultManager,
        address user,
        uint256 minRatio,
        uint256 maxRatio
    ) internal {
        uint256 healthRatio = vaultManager.getHealthRatio(user);
        assertGe(healthRatio, minRatio, "Health ratio below minimum");
        assertLe(healthRatio, maxRatio, "Health ratio above maximum");
    }

    /// @notice Fast forward time and accrue yield
    function accrueYieldForPeriod(VaultManager vaultManager, address user, uint256 period) internal {
        vm.warp(block.timestamp + period);
        vaultManager.accrueYield(user);
    }
}

