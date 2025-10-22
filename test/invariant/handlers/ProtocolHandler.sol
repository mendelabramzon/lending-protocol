// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../../../src/VaultManager.sol";
import {StableToken} from "../../../src/StableToken.sol";
import {StabilityPool} from "../../../src/StabilityPool.sol";
import {MockYieldToken} from "../../../src/mocks/MockYieldToken.sol";

/// @title ProtocolHandler
/// @notice Handler contract for invariant testing of the lending protocol
contract ProtocolHandler is Test {
    VaultManager public vaultManager;
    StableToken public stableToken;
    StabilityPool public stabilityPool;
    MockYieldToken public collateralToken;

    // Ghost variables for tracking protocol state
    uint256 public ghost_totalCollateralDeposited;
    uint256 public ghost_totalCollateralWithdrawn;
    uint256 public ghost_totalDebtBorrowed;
    uint256 public ghost_totalDebtRepaid;
    uint256 public ghost_totalStabilityDeposited;
    uint256 public ghost_totalStabilityWithdrawn;

    // Actor management
    address[] public actors;
    address internal currentActor;

    // Bounded ranges
    uint256 constant MAX_COLLATERAL_AMOUNT = 1000 ether;
    uint256 constant MAX_BORROW_AMOUNT = 100000e18;
    uint256 constant MIN_COLLATERAL_RATIO = 150e16;

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        VaultManager _vaultManager,
        StableToken _stableToken,
        StabilityPool _stabilityPool,
        MockYieldToken _collateralToken
    ) {
        vaultManager = _vaultManager;
        stableToken = _stableToken;
        stabilityPool = _stabilityPool;
        collateralToken = _collateralToken;

        // Initialize actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            
            // Give each actor initial collateral
            collateralToken.mint(actor, MAX_COLLATERAL_AMOUNT * 2);
        }
    }

    /// @notice Handler for depositing collateral
    function depositCollateral(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 1 ether, MAX_COLLATERAL_AMOUNT);

        // Approve and deposit
        collateralToken.approve(address(vaultManager), amount);
        
        try vaultManager.depositCollateral(amount) {
            ghost_totalCollateralDeposited += amount;
        } catch {
            // If deposit fails, don't update ghost variables
        }
    }

    /// @notice Handler for withdrawing collateral
    function withdrawCollateral(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        (uint256 collateral,,,) = vaultManager.vaults(currentActor);
        amount = bound(amount, 0, collateral);

        if (amount == 0) return;

        try vaultManager.withdrawCollateral(amount) {
            ghost_totalCollateralWithdrawn += amount;
        } catch {
            // If withdrawal fails (due to collateral ratio), that's expected
        }
    }

    /// @notice Handler for borrowing stablecoins
    function borrow(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        (uint256 collateral, uint256 debt,,) = vaultManager.vaults(currentActor);
        
        if (collateral == 0) return;

        // Calculate max safe borrow
        uint256 collateralValue = (collateral * 2000e8) / 1e8; // Assuming $2000 price
        uint256 maxBorrow = (collateralValue * 1e18) / MIN_COLLATERAL_RATIO;
        
        if (maxBorrow <= debt) return;
        
        amount = bound(amount, 1e18, maxBorrow - debt - 1e18);

        try vaultManager.borrow(amount) {
            ghost_totalDebtBorrowed += amount;
        } catch {
            // Borrow might fail due to health ratio
        }
    }

    /// @notice Handler for repaying debt
    function repay(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        (, uint256 debt,,) = vaultManager.vaults(currentActor);
        amount = bound(amount, 0, debt);

        if (amount == 0) return;

        stableToken.approve(address(vaultManager), amount);
        
        try vaultManager.repay(amount) {
            ghost_totalDebtRepaid += amount;
        } catch {
            // Repay shouldn't fail but handle gracefully
        }
    }

    /// @notice Handler for depositing to stability pool
    function depositToStabilityPool(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 balance = stableToken.balanceOf(currentActor);
        amount = bound(amount, 0, balance);

        if (amount == 0) return;

        stableToken.approve(address(stabilityPool), amount);
        
        try stabilityPool.deposit(amount) {
            ghost_totalStabilityDeposited += amount;
        } catch {
            // Deposit might fail
        }
    }

    /// @notice Handler for withdrawing from stability pool
    function withdrawFromStabilityPool(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        StabilityPool.Deposit memory deposit = stabilityPool.getDeposit(currentActor);
        amount = bound(amount, 0, deposit.amount);

        if (amount == 0) return;

        try stabilityPool.withdraw(amount) {
            ghost_totalStabilityWithdrawn += amount;
        } catch {
            // Withdrawal might fail
        }
    }

    /// @notice Handler for accruing yield
    function accrueYield(uint256 actorSeed) external useActor(actorSeed) {
        vaultManager.accrueYield(currentActor);
    }

    /// @notice Get total collateral in system
    function getTotalCollateral() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 collateral,,,) = vaultManager.vaults(actors[i]);
            total += collateral;
        }
    }

    /// @notice Get total debt in system
    function getTotalDebt() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            (, uint256 debt,,) = vaultManager.vaults(actors[i]);
            total += debt;
        }
    }

    /// @notice Get number of actors
    function getActorCount() external view returns (uint256) {
        return actors.length;
    }
}

