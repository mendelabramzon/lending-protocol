// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockChainlinkOracle
/// @notice Mock Chainlink price feed for testing
contract MockChainlinkOracle {
    uint8 public decimals;
    int256 private _price;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 _decimals) {
        decimals = _decimals;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    /// @notice Set the price for testing
    /// @param price New price value
    function setPrice(int256 price) external {
        _price = price;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    /// @notice Set the updated timestamp for testing stale price scenarios
    /// @param timestamp New updated timestamp
    function setUpdatedAt(uint256 timestamp) external {
        _updatedAt = timestamp;
    }

    /// @notice Mock implementation of Chainlink's latestRoundData
    /// @return roundId Round ID
    /// @return answer Price value
    /// @return startedAt Round start timestamp
    /// @return updatedAt Last update timestamp
    /// @return answeredInRound Round ID where answer was computed
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice Get current round data
    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice Get latest answer (legacy Chainlink function)
    /// @return answer Latest price
    function latestAnswer() external view returns (int256 answer) {
        return _price;
    }
}

