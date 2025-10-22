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
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";

/// @title ProtocolInvariantTest
/// @notice Invariant tests for the lending protocol
contract ProtocolInvariantTest is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    PriceOracle public oracle;
    StabilityPool public stabilityPool;
    LiquidationEngine public liquidationEngine;
    MockYieldToken public collateralToken;
    MockChainlinkOracle public priceFeed;
    ProtocolHandler public handler;

    function setUp() public {
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
        priceFeed.setPrice(2000e8); // $2000
        oracle.setPriceFeed(address(collateralToken), address(priceFeed));

        // Connect contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(stabilityPool));
        vaultManager.setLiquidationEngine(address(liquidationEngine));
        stabilityPool.setLiquidationEngine(address(liquidationEngine));

        // Deploy handler
        handler = new ProtocolHandler(
            vaultManager,
            stableToken,
            stabilityPool,
            collateralToken
        );

        // Target handler for invariant testing
        targetContract(address(handler));
    }

    /// @notice Invariant: Total stablecoin supply equals total debt
    function invariant_StablecoinSupplyEqualsDebt() public {
        uint256 totalSupply = stableToken.totalSupply();
        uint256 totalDebt = handler.getTotalDebt();
        
        assertEq(
            totalSupply,
            totalDebt,
            "Total stablecoin supply should equal total debt"
        );
    }

    /// @notice Invariant: All vaults maintain minimum collateral ratio (if they have debt)
    function invariant_AllVaultsMaintainCollateralRatio() public {
        uint256 actorCount = handler.getActorCount();
        
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actors(i);
            (, uint256 debt,,) = vaultManager.vaults(actor);
            
            if (debt > 0) {
                uint256 healthRatio = vaultManager.getHealthRatio(actor);
                assertGe(
                    healthRatio,
                    vaultManager.MIN_COLLATERAL_RATIO(),
                    "Vault should maintain minimum collateral ratio"
                );
            }
        }
    }

    /// @notice Invariant: Collateral in VaultManager equals deposited minus withdrawn
    function invariant_CollateralBalance() public {
        uint256 totalCollateral = handler.getTotalCollateral();
        uint256 expectedCollateral = handler.ghost_totalCollateralDeposited() - 
                                     handler.ghost_totalCollateralWithdrawn();
        
        assertEq(
            totalCollateral,
            expectedCollateral,
            "Total collateral should match deposits minus withdrawals"
        );
    }

    /// @notice Invariant: Total debt equals borrowed minus repaid
    function invariant_DebtBalance() public {
        uint256 totalDebt = handler.getTotalDebt();
        uint256 expectedDebt = handler.ghost_totalDebtBorrowed() - 
                               handler.ghost_totalDebtRepaid();
        
        assertEq(
            totalDebt,
            expectedDebt,
            "Total debt should match borrowed minus repaid"
        );
    }

    /// @notice Invariant: Stability pool deposits equal deposited minus withdrawn
    function invariant_StabilityPoolBalance() public {
        uint256 totalDeposits = stabilityPool.getTotalDeposits();
        uint256 expectedDeposits = handler.ghost_totalStabilityDeposited() - 
                                    handler.ghost_totalStabilityWithdrawn();
        
        assertEq(
            totalDeposits,
            expectedDeposits,
            "Stability pool deposits should match deposited minus withdrawn"
        );
    }

    /// @notice Invariant: Protocol is always solvent (collateral value >= debt value)
    function invariant_ProtocolSolvency() public {
        uint256 totalCollateral = handler.getTotalCollateral();
        uint256 totalDebt = handler.getTotalDebt();
        
        // Collateral value at $2000 per token
        uint256 collateralValue = (totalCollateral * 2000e8) / 1e8;
        
        assertGe(
            collateralValue,
            totalDebt,
            "Protocol should remain solvent (collateral value >= debt)"
        );
    }

    /// @notice Invariant: No user has more stablecoins than they borrowed
    function invariant_UserStablecoinBalance() public {
        uint256 actorCount = handler.getActorCount();
        
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actors(i);
            uint256 stablecoinBalance = stableToken.balanceOf(actor);
            (, uint256 debt,,) = vaultManager.vaults(actor);
            StabilityPool.Deposit memory deposit = stabilityPool.getDeposit(actor);
            
            // User's stablecoins should not exceed borrowed amount
            // (they can have less if they deposited to stability pool or transferred)
            assertLe(
                stablecoinBalance,
                debt + 1, // +1 for potential rounding
                "User stablecoin balance should not exceed debt"
            );
        }
    }

    /// @notice Invariant: Yield accrual never decreases collateral
    function invariant_YieldNeverDecreasesCollateral() public {
        uint256 actorCount = handler.getActorCount();
        
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actors(i);
            (uint256 collateralBefore,,,) = vaultManager.vaults(actor);
            
            // Accrue yield
            vaultManager.accrueYield(actor);
            
            (uint256 collateralAfter,,,) = vaultManager.vaults(actor);
            
            assertGe(
                collateralAfter,
                collateralBefore,
                "Yield accrual should never decrease collateral"
            );
        }
    }

    /// @notice Invariant: Health ratio is deterministic based on collateral and debt
    function invariant_HealthRatioDeterministic() public {
        uint256 actorCount = handler.getActorCount();
        
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actors(i);
            (uint256 collateral, uint256 debt,,) = vaultManager.vaults(actor);
            
            if (debt == 0) {
                assertEq(
                    vaultManager.getHealthRatio(actor),
                    type(uint256).max,
                    "Health ratio should be max with no debt"
                );
            } else {
                uint256 collateralValue = (collateral * 2000e8) / 1e8;
                uint256 expectedRatio = (collateralValue * 1e18) / debt;
                uint256 actualRatio = vaultManager.getHealthRatio(actor);
                
                // Allow small rounding difference
                assertApproxEqRel(
                    actualRatio,
                    expectedRatio,
                    0.001e18, // 0.1% tolerance
                    "Health ratio should match expected calculation"
                );
            }
        }
    }

    /// @notice Invariant: VaultManager holds exactly the deposited collateral
    function invariant_VaultManagerCollateralBalance() public {
        uint256 totalCollateral = handler.getTotalCollateral();
        uint256 vaultManagerBalance = collateralToken.balanceOf(address(vaultManager));
        
        assertEq(
            vaultManagerBalance,
            totalCollateral,
            "VaultManager should hold exactly the total deposited collateral"
        );
    }
}

