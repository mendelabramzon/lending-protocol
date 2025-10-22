// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @notice Interface for Chainlink price feeds
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    
    function decimals() external view returns (uint8);
}

/// @title PriceOracle
/// @notice Aggregates price feeds from Chainlink and provides TWAP for manipulation resistance
/// @dev Uses Chainlink price feeds as primary source with TWAP backup
contract PriceOracle is IPriceOracle, Ownable {

    /// @notice Price observation for TWAP calculation
    struct PriceObservation {
        uint256 timestamp;
        uint256 price;
        uint256 cumulativePrice;
    }

    /// @notice Circular buffer state for each token
    struct CircularBuffer {
        uint256 head; // Next index to write to
        uint256 count; // Number of observations stored
        mapping(uint256 => PriceObservation) observations;
    }

    /// @notice Mapping of token => Chainlink price feed
    mapping(address => address) public priceFeeds;

    /// @notice Mapping of token => circular buffer for TWAP
    mapping(address => CircularBuffer) private priceBuffers;

    /// @notice Maximum age of price data (1 hour)
    uint256 public constant MAX_PRICE_AGE = 1 hours;

    /// @notice Maximum age of TWAP observations (2 hours)
    /// @dev If newest observation is older than this, TWAP is considered stale
    uint256 public constant MAX_TWAP_OBSERVATION_AGE = 2 hours;

    /// @notice Maximum number of observations to store per token
    uint256 public constant MAX_OBSERVATIONS = 24;

    /// @notice Minimum time between TWAP updates to prevent manipulation (5 minutes)
    uint256 public constant UPDATE_COOLDOWN = 5 minutes;

    /// @notice Mapping of token => last update timestamp
    mapping(address => uint256) public lastUpdateTime;

    /// @notice Error thrown when price feed is not set
    error PriceFeedNotSet();
    
    /// @notice Error thrown when update called too frequently
    error UpdateTooFrequent();

    /// @notice Error thrown when price data is stale
    error StalePriceData();

    /// @notice Error thrown when price is invalid
    error InvalidPrice();

    /// @notice Error thrown when insufficient observations for TWAP
    error InsufficientObservations();

    /// @notice Error thrown when TWAP observations are too old
    error StaleObservations();

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external override returns (uint256 price) {
        address feed = priceFeeds[token];
        if (feed == address(0)) revert PriceFeedNotSet();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePriceData();

        // Convert to 8 decimals (Chainlink standard)
        uint8 decimals = priceFeed.decimals();
        uint256 currentPrice;
        if (decimals < 8) {
            currentPrice = uint256(answer) * (10 ** (8 - decimals));
        } else if (decimals > 8) {
            currentPrice = uint256(answer) / (10 ** (decimals - 8));
        } else {
            currentPrice = uint256(answer);
        }
        
        if (block.timestamp >= lastUpdateTime[token] + UPDATE_COOLDOWN) {
            _updatePriceObservationInternal(token, currentPrice);
        }
        
        return currentPrice;
    }
    
    /// @notice Get price without updating TWAP (view-only version)
    /// @param token Address of the token
    /// @return price Current price without state changes
    function getPriceView(address token) external view returns (uint256 price) {
        address feed = priceFeeds[token];
        if (feed == address(0)) revert PriceFeedNotSet();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePriceData();

        // Convert to 8 decimals
        uint8 decimals = priceFeed.decimals();
        if (decimals < 8) {
            return uint256(answer) * (10 ** (8 - decimals));
        } else if (decimals > 8) {
            return uint256(answer) / (10 ** (decimals - 8));
        }
        
        return uint256(answer);
    }
    
    /// @notice Internal function to update price observation
    /// @param token Address of the token
    /// @param currentPrice Current price from feed
    function _updatePriceObservationInternal(address token, uint256 currentPrice) internal {
        lastUpdateTime[token] = block.timestamp;
        
        CircularBuffer storage buffer = priceBuffers[token];

        uint256 cumulativePrice = 0;
        
        // Calculate cumulative price from previous observation
        if (buffer.count > 0) {
            uint256 prevIndex = buffer.head > 0 ? buffer.head - 1 : MAX_OBSERVATIONS - 1;
            PriceObservation storage lastObs = buffer.observations[prevIndex];
            uint256 timeElapsed = block.timestamp - lastObs.timestamp;
            cumulativePrice = lastObs.cumulativePrice + (lastObs.price * timeElapsed);
        }

        // Write to circular buffer at head position
        buffer.observations[buffer.head] = PriceObservation({
            timestamp: block.timestamp,
            price: currentPrice,
            cumulativePrice: cumulativePrice
        });

        // Update head (circular)
        buffer.head = (buffer.head + 1) % MAX_OBSERVATIONS;
        
        // Update count (cap at MAX_OBSERVATIONS)
        if (buffer.count < MAX_OBSERVATIONS) {
            buffer.count++;
        }
    }

    /// @inheritdoc IPriceOracle
    function getTWAP(address token, uint256 period) external view override returns (uint256 price) {
        CircularBuffer storage buffer = priceBuffers[token];
        
        if (buffer.count == 0) revert InsufficientObservations();
        if (buffer.count < 2) revert InsufficientObservations();

        uint256 targetTime = block.timestamp - period;
        
        // Get newest observation with proper edge case handling
        // If count < MAX_OBSERVATIONS, newest is at (head - 1)
        // If count == MAX_OBSERVATIONS, buffer is full and newest is still at (head - 1)
        uint256 newestIndex;
        
        if (buffer.head == 0) {
            // Wraparound case: newest is at the end of the buffer
            // This can only happen if we've written at least once
            newestIndex = buffer.count >= MAX_OBSERVATIONS ? MAX_OBSERVATIONS - 1 : buffer.count - 1;
        } else {
            newestIndex = buffer.head - 1;
        }
        
        PriceObservation storage newest = buffer.observations[newestIndex];
        
        if (block.timestamp - newest.timestamp > MAX_TWAP_OBSERVATION_AGE) {
            revert StaleObservations();
        }

        // Find oldest observation within period using binary-style search
        // For simplicity, we'll do a linear search backwards from head
        PriceObservation storage oldest = newest;
        uint256 oldestIndex = newestIndex;
        
        for (uint256 i = 0; i < buffer.count; i++) {
            uint256 idx = (newestIndex + MAX_OBSERVATIONS - i) % MAX_OBSERVATIONS;
            PriceObservation storage obs = buffer.observations[idx];
            
            if (obs.timestamp <= targetTime) {
                oldest = obs;
                oldestIndex = idx;
                break;
            }
            oldest = obs;
            oldestIndex = idx;
        }

        uint256 timeElapsed = newest.timestamp - oldest.timestamp;
        if (timeElapsed == 0) revert InsufficientObservations();

        uint256 priceDelta = newest.cumulativePrice - oldest.cumulativePrice;
        
        return priceDelta / timeElapsed;
    }

    /// @inheritdoc IPriceOracle
    function setPriceFeed(address token, address feed) external override onlyOwner {
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    /// @notice Update price observation for TWAP calculation using circular buffer
    /// @param token Address of the token
    /// @dev Should be called periodically to maintain accurate TWAP
    function updatePriceObservation(address token) external {
        CircularBuffer storage buffer = priceBuffers[token];
        
        if (buffer.count >= 3 && lastUpdateTime[token] > 0 && 
            block.timestamp < lastUpdateTime[token] + UPDATE_COOLDOWN) {
            revert UpdateTooFrequent();
        }
        
        address feed = priceFeeds[token];
        if (feed == address(0)) revert PriceFeedNotSet();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePriceData();

        // Convert to 8 decimals
        uint8 decimals = priceFeed.decimals();
        uint256 currentPrice;
        if (decimals < 8) {
            currentPrice = uint256(answer) * (10 ** (8 - decimals));
        } else if (decimals > 8) {
            currentPrice = uint256(answer) / (10 ** (decimals - 8));
        } else {
            currentPrice = uint256(answer);
        }
        
        lastUpdateTime[token] = block.timestamp;
        
        uint256 cumulativePrice = 0;
        
        // Calculate cumulative price from previous observation
        if (buffer.count > 0) {
            uint256 prevIndex = buffer.head > 0 ? buffer.head - 1 : MAX_OBSERVATIONS - 1;
            PriceObservation storage lastObs = buffer.observations[prevIndex];
            uint256 timeElapsed = block.timestamp - lastObs.timestamp;
            cumulativePrice = lastObs.cumulativePrice + (lastObs.price * timeElapsed);
        }

        // Write to circular buffer at head position
        buffer.observations[buffer.head] = PriceObservation({
            timestamp: block.timestamp,
            price: currentPrice,
            cumulativePrice: cumulativePrice
        });

        // Update head (circular)
        buffer.head = (buffer.head + 1) % MAX_OBSERVATIONS;
        
        // Update count (cap at MAX_OBSERVATIONS)
        if (buffer.count < MAX_OBSERVATIONS) {
            buffer.count++;
        }
    }

    /// @notice Get the number of price observations for a token
    /// @param token Address of the token
    /// @return count Number of observations
    function getObservationCount(address token) external view returns (uint256 count) {
        return priceBuffers[token].count;
    }

    /// @notice Get a specific observation from the circular buffer
    /// @param token Address of the token
    /// @param index Index in the circular buffer
    /// @return observation The price observation
    function getObservation(address token, uint256 index) external view returns (PriceObservation memory observation) {
        CircularBuffer storage buffer = priceBuffers[token];
        require(index < MAX_OBSERVATIONS, "Index out of bounds");
        return buffer.observations[index];
    }

    /// @notice Get buffer state for a token
    /// @param token Address of the token
    /// @return head Head position
    /// @return count Number of observations
    function getBufferState(address token) external view returns (uint256 head, uint256 count) {
        CircularBuffer storage buffer = priceBuffers[token];
        return (buffer.head, buffer.count);
    }
}
