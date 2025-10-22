// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockChainlinkOracle} from "../../src/mocks/MockChainlinkOracle.sol";

contract PriceOracleTest is Test {
    PriceOracle public oracle;
    MockChainlinkOracle public mockFeed;
    address public token;
    address public owner;

    event PriceFeedUpdated(address indexed token, address indexed feed);

    function setUp() public {
        owner = address(this);
        token = makeAddr("token");
        
        oracle = new PriceOracle();
        mockFeed = new MockChainlinkOracle(8); // 8 decimals like Chainlink
        mockFeed.setPrice(2000e8); // $2000
    }

    function test_SetPriceFeed() public {
        vm.expectEmit(true, true, false, false);
        emit PriceFeedUpdated(token, address(mockFeed));
        
        oracle.setPriceFeed(token, address(mockFeed));
        assertEq(oracle.priceFeeds(token), address(mockFeed));
    }

    function test_RevertWhen_SetPriceFeedNotOwner() public {
        vm.prank(makeAddr("user"));
        vm.expectRevert();
        oracle.setPriceFeed(token, address(mockFeed));
    }

    function test_GetPrice() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        uint256 price = oracle.getPrice(token);
        assertEq(price, 2000e8, "Price should be $2000 with 8 decimals");
    }

    function test_RevertWhen_PriceFeedNotSet() public {
        vm.expectRevert(PriceOracle.PriceFeedNotSet.selector);
        oracle.getPrice(token);
    }

    function test_RevertWhen_PriceIsNegative() public {
        oracle.setPriceFeed(token, address(mockFeed));
        mockFeed.setPrice(-1);

        vm.expectRevert(PriceOracle.InvalidPrice.selector);
        oracle.getPrice(token);
    }

    function test_RevertWhen_PriceIsStale() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        // Warp to a reasonable timestamp first
        vm.warp(block.timestamp + 10 hours);
        
        // Set price update time to 2 hours ago
        mockFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert(PriceOracle.StalePriceData.selector);
        oracle.getPrice(token);
    }

    function test_UpdatePriceObservation() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        oracle.updatePriceObservation(token);
        assertEq(oracle.getObservationCount(token), 1);

        // Wait and update again
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePriceObservation(token);
        assertEq(oracle.getObservationCount(token), 2);
    }

    function test_GetTWAP() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        // First observation at $2000
        mockFeed.setPrice(2000e8);
        oracle.updatePriceObservation(token);

        // Wait 1 hour and update at $2100
        vm.warp(block.timestamp + 1 hours);
        mockFeed.setPrice(2100e8);
        oracle.updatePriceObservation(token);

        // Wait another hour and update at $2200
        vm.warp(block.timestamp + 1 hours);
        mockFeed.setPrice(2200e8);
        oracle.updatePriceObservation(token);

        // Get TWAP for last 2 hours
        uint256 twap = oracle.getTWAP(token, 2 hours);
        
        // TWAP should be between $2000 and $2200
        assertGt(twap, 2000e8);
        assertLt(twap, 2200e8);
    }

    function test_RevertWhen_InsufficientObservationsForTWAP() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        // Only one observation
        oracle.updatePriceObservation(token);

        vm.expectRevert(PriceOracle.InsufficientObservations.selector);
        oracle.getTWAP(token, 1 hours);
    }

    function test_MaxObservations() public {
        oracle.setPriceFeed(token, address(mockFeed));

        // Add more than MAX_OBSERVATIONS (24)
        for (uint256 i = 0; i < 30; i++) {
            oracle.updatePriceObservation(token);
            vm.warp(block.timestamp + 1 hours);
            mockFeed.setPrice(2000e8); // Keep price fresh
        }

        // Should cap at MAX_OBSERVATIONS
        assertLe(oracle.getObservationCount(token), 30);
    }

    function test_PriceDecimalConversion() public {
        // Test with 6 decimal feed
        MockChainlinkOracle feed6Decimals = new MockChainlinkOracle(6);
        feed6Decimals.setPrice(2000e6); // $2000 with 6 decimals
        
        oracle.setPriceFeed(token, address(feed6Decimals));
        uint256 price = oracle.getPrice(token);
        
        // Should convert to 8 decimals
        assertEq(price, 2000e8);
    }

    function test_ValidPriceUpdate() public {
        oracle.setPriceFeed(token, address(mockFeed));
        
        // Initial price
        uint256 price1 = oracle.getPrice(token);
        assertEq(price1, 2000e8);

        // Update price
        mockFeed.setPrice(2500e8);
        uint256 price2 = oracle.getPrice(token);
        assertEq(price2, 2500e8);
    }
}

