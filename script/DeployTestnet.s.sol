// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {StableToken} from "../src/StableToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {StabilityPool} from "../src/StabilityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockChainlinkOracle} from "../src/mocks/MockChainlinkOracle.sol";

/// @title DeployTestnet
/// @notice Deployment script for the lending protocol on testnet with mocks
contract DeployTestnet is Script {
    address public owner;

    function run() public {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256());
        owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));

        console.log("Deploying Enhanced Lending Protocol to Testnet...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock collateral token (stETH mock)
        MockERC20 collateralToken = new MockERC20("Mock Staked ETH", "stETH", 18);
        console.log("Mock CollateralToken deployed at:", address(collateralToken));

        // 2. Deploy mock Chainlink oracle
        MockChainlinkOracle chainlinkFeed = new MockChainlinkOracle(8);
        chainlinkFeed.setPrice(2000e8); // $2000 per ETH
        console.log("Mock Chainlink Feed deployed at:", address(chainlinkFeed));

        // 3. Deploy StableToken
        StableToken stableToken = new StableToken("Protocol Stablecoin", "PUSD");
        console.log("StableToken deployed at:", address(stableToken));

        // 4. Deploy PriceOracle
        PriceOracle oracle = new PriceOracle();
        console.log("PriceOracle deployed at:", address(oracle));

        // 5. Set price feed
        oracle.setPriceFeed(address(collateralToken), address(chainlinkFeed));
        console.log("Price feed set for collateral");

        // 6. Initialize TWAP with observations
        console.log("Initializing TWAP observations...");
        for (uint256 i = 0; i < 3; i++) {
            oracle.updatePriceObservation(address(collateralToken));
        }
        console.log("TWAP initialized with 3 observations");

        // 7. Deploy VaultManager
        VaultManager vaultManager = new VaultManager(
            address(collateralToken),
            address(stableToken),
            address(oracle)
        );
        console.log("VaultManager deployed at:", address(vaultManager));

        // 8. Deploy StabilityPool
        StabilityPool stabilityPool = new StabilityPool(
            address(stableToken),
            address(collateralToken)
        );
        console.log("StabilityPool deployed at:", address(stabilityPool));

        // 9. Deploy LiquidationEngine
        LiquidationEngine         liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(stableToken),
            address(collateralToken),
            address(oracle),
            address(stabilityPool)
        );
        console.log("LiquidationEngine deployed at:", address(liquidationEngine));

        // 10. Deploy Timelock (2 day delay)
        Timelock timelock = new Timelock(2 days);
        console.log("Timelock deployed at:", address(timelock));

        // 11. Configure contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(stabilityPool));
        stableToken.addMinter(address(liquidationEngine)); // For burning during liquidation
        console.log("Minters configured");

        vaultManager.setLiquidationEngine(address(liquidationEngine));
        console.log("LiquidationEngine set on VaultManager");

        stabilityPool.setLiquidationEngine(address(liquidationEngine));
        console.log("LiquidationEngine set on StabilityPool");

        // 12. Mint some test collateral to deployer
        collateralToken.mint(vm.addr(deployerPrivateKey), 1000 ether);
        console.log("Minted 1000 test collateral tokens to deployer");

        // 13. Transfer protocol ownership to Timelock for security
        // NOTE: For testnet, we keep direct ownership to allow easy testing
        // For production, always transfer to Timelock!
        console.log("\nNOTE: Testnet deployment - keeping direct ownership for testing");
        console.log("For production, uncomment the Timelock ownership transfer!");
        
        // Uncomment for production deployment:
        // stableToken.transferOwnership(address(timelock));
        // oracle.transferOwnership(address(timelock));
        // vaultManager.transferOwnership(address(timelock));
        // stabilityPool.transferOwnership(address(timelock));
        // if (owner != vm.addr(deployerPrivateKey)) {
        //     timelock.transferOwnership(owner);
        // }

        vm.stopBroadcast();

        // 14. Verify deployment
        console.log("\n=== Enhanced Testnet Deployment Summary ===");
        console.log("CollateralToken (Mock):", address(collateralToken));
        console.log("Chainlink Feed (Mock):", address(chainlinkFeed));
        console.log("StableToken:", address(stableToken));
        console.log("PriceOracle:", address(oracle));
        console.log("VaultManager:", address(vaultManager));
        console.log("StabilityPool:", address(stabilityPool));
        console.log("LiquidationEngine:", address(liquidationEngine));
        console.log("Timelock:", address(timelock));
        console.log("Owner:", owner);
        
        // Verification checks
        require(stableToken.isMinter(address(vaultManager)), "VaultManager not minter");
        require(stableToken.isMinter(address(stabilityPool)), "StabilityPool not minter");
        require(vaultManager.liquidationEngine() == address(liquidationEngine), "LiquidationEngine not set");
        console.log("\nAll verification checks passed!");
        
        console.log("\n=== Enhanced Features ===");
        console.log("- Batch auction liquidation with commit-reveal");
        console.log("- StabilityPool fallback for failed auctions");
        console.log("- Interest rate mechanism (5% APR with 10% protocol fee)");
        console.log("- Bad debt tracking and reserve-based backstop");
        console.log("- TWAP oracle protection against flash loans");
        console.log("- Multi-block borrow delay for flash loan protection");
        console.log("- Griefing protection via deposits (0.1 ETH)");
        console.log("- Timelock for admin functions (2 day delay)");
        console.log("- Circular buffer for gas-efficient TWAP");
        console.log("- Parameter bounds validation");
        console.log("- LST/LRT adapter support with slashing detection");
        
        console.log("\n=== System Parameters ===");
        console.log("- Borrow APR: 5%");
        console.log("- Protocol Fee: 10% of interest");
        console.log("- Min Collateral Ratio: 150%");
        console.log("- Liquidation Threshold: 120%");
        console.log("- Auction Timeout: 3 hours (then StabilityPool)");
        console.log("- Min Debt: 100 stablecoins");
    }
}
