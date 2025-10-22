// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {StableToken} from "../src/StableToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {StabilityPool} from "../src/StabilityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {Timelock} from "../src/governance/Timelock.sol";

/// @title Deploy
/// @notice Deployment script for the lending protocol
contract Deploy is Script {
    // Deployment parameters (set via environment variables or hardcode)
    address public collateralToken; // e.g., stETH address on mainnet
    address public chainlinkFeed; // Chainlink ETH/USD feed
    address public owner;

    function run() public {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));
        
        // For testnet/mainnet, set these addresses
        // Mainnet stETH: 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
        // Mainnet ETH/USD Chainlink: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        collateralToken = vm.envOr("COLLATERAL_TOKEN", address(0));
        chainlinkFeed = vm.envOr("CHAINLINK_FEED", address(0));

        console.log("Deploying Lending Protocol...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy StableToken
        StableToken stableToken = new StableToken("Protocol Stablecoin", "PUSD");
        console.log("StableToken deployed at:", address(stableToken));

        // 2. Deploy PriceOracle
        PriceOracle oracle = new PriceOracle();
        console.log("PriceOracle deployed at:", address(oracle));

        // 3. Set price feed if addresses are provided
        if (collateralToken != address(0) && chainlinkFeed != address(0)) {
            oracle.setPriceFeed(collateralToken, chainlinkFeed);
            console.log("Price feed set for collateral:", collateralToken);
        }

        // 4. Deploy VaultManager
        VaultManager vaultManager = new VaultManager(
            collateralToken,
            address(stableToken),
            address(oracle)
        );
        console.log("VaultManager deployed at:", address(vaultManager));

        // 5. Deploy StabilityPool
        StabilityPool stabilityPool = new StabilityPool(
            address(stableToken),
            collateralToken
        );
        console.log("StabilityPool deployed at:", address(stabilityPool));

        // 6. Deploy LiquidationEngine
        LiquidationEngine liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(stableToken),
            collateralToken,
            address(oracle),
            address(stabilityPool)
        );
        console.log("LiquidationEngine deployed at:", address(liquidationEngine));

        // 7. Configure contracts
        stableToken.addMinter(address(vaultManager));
        stableToken.addMinter(address(stabilityPool));
        console.log("VaultManager and StabilityPool added as minters");

        vaultManager.setLiquidationEngine(address(liquidationEngine));
        console.log("LiquidationEngine set on VaultManager");

        stabilityPool.setLiquidationEngine(address(liquidationEngine));
        console.log("LiquidationEngine set on StabilityPool");

        // 8. Deploy Timelock for governance (2 day delay)
        Timelock timelock = new Timelock(2 days);
        console.log("Timelock deployed at:", address(timelock));

        // 9. Transfer ownership to Timelock for security
        // CRITICAL: All admin functions now require 2-day timelock delay
        // This gives users time to exit if they disagree with governance decisions
        stableToken.transferOwnership(address(timelock));
        oracle.transferOwnership(address(timelock));
        vaultManager.transferOwnership(address(timelock));
        stabilityPool.transferOwnership(address(timelock));
        console.log("Protocol ownership transferred to Timelock");
        
        // 10. Transfer Timelock ownership to intended owner (or multisig)
        if (owner != vm.addr(deployerPrivateKey)) {
            timelock.transferOwnership(owner);
            console.log("Timelock ownership transferred to:", owner);
        } else {
            console.log("WARNING: Timelock owned by deployer. Transfer to multisig for production!");
        }

        vm.stopBroadcast();

        // 11. Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("StableToken:", address(stableToken));
        console.log("PriceOracle:", address(oracle));
        console.log("VaultManager:", address(vaultManager));
        console.log("StabilityPool:", address(stabilityPool));
        console.log("LiquidationEngine:", address(liquidationEngine));
        console.log("Timelock:", address(timelock));
        console.log("Timelock Delay: 2 days");
        console.log("Timelock Owner:", owner);
        
        // Verification checks
        require(stableToken.isMinter(address(vaultManager)), "VaultManager not minter");
        require(stableToken.isMinter(address(stabilityPool)), "StabilityPool not minter");
        require(vaultManager.liquidationEngine() == address(liquidationEngine), "LiquidationEngine not set");
        require(stableToken.owner() == address(timelock), "StableToken owner not Timelock");
        require(vaultManager.owner() == address(timelock), "VaultManager owner not Timelock");
        console.log("\nAll verification checks passed!");
        
        console.log("\n=== IMPORTANT: Admin Function Usage ===");
        console.log("To call admin functions (setLiquidationEngine, pause, etc.):");
        console.log("1. Queue transaction via Timelock.queueTransaction()");
        console.log("2. Wait 2 days (minimum delay)");
        console.log("3. Execute via Timelock.executeTransaction()");
        console.log("Example: See Timelock contract documentation");
    }
}

