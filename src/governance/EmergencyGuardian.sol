// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title EmergencyGuardian
/// @notice Governance contract with guardian role for emergency actions
/// @dev Implements circuit breakers and emergency procedures without timelock for rapid response
contract EmergencyGuardian is Ownable {
    /// @notice Guardian address with emergency powers
    address public guardian;

    /// @notice Mapping of function selector => paused status
    mapping(bytes4 => bool) public functionPaused;

    /// @notice Global circuit breaker status
    bool public circuitBreakerTripped;

    /// @notice Last known price for circuit breaker detection
    mapping(address => uint256) public lastKnownPrice;

    /// @notice Maximum acceptable price change percentage (20%)
    uint256 public constant MAX_PRICE_CHANGE = 20e16; // 0.2 in WAD

    /// @notice Circuit breaker cooldown period (1 hour)
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours;

    /// @notice Timestamp when circuit breaker was last tripped
    uint256 public lastCircuitBreakerTrip;

    /// @notice Error thrown when caller is not guardian
    error NotGuardian();

    /// @notice Error thrown when function is paused
    error FunctionPaused();

    /// @notice Error thrown when circuit breaker is tripped
    error CircuitBreakerTripped();

    /// @notice Error thrown when zero address provided
    error ZeroAddress();

    /// @notice Emitted when guardian is updated
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Emitted when function pause status changes
    event FunctionPauseStatusChanged(bytes4 indexed selector, bool paused);

    /// @notice Emitted when circuit breaker is tripped
    event CircuitBreakerActivated(address indexed token, uint256 oldPrice, uint256 newPrice, uint256 changePercent);

    /// @notice Emitted when circuit breaker is reset
    event CircuitBreakerReset(address indexed by);

    /// @notice Initialize the guardian contract
    /// @param _guardian Initial guardian address
    constructor(address _guardian) Ownable(msg.sender) {
        if (_guardian == address(0)) revert ZeroAddress();
        guardian = _guardian;
        emit GuardianUpdated(address(0), _guardian);
    }

    /// @notice Modifier to check if caller is guardian
    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _;
    }

    /// @notice Modifier to check if function is not paused
    /// @param selector Function selector to check
    modifier whenFunctionNotPaused(bytes4 selector) {
        if (functionPaused[selector]) revert FunctionPaused();
        _;
    }

    /// @notice Modifier to check if circuit breaker is not tripped
    modifier whenCircuitBreakerNotTripped() {
        if (circuitBreakerTripped) revert CircuitBreakerTripped();
        _;
    }

    /// @notice Set a new guardian address
    /// @param newGuardian Address of new guardian
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /// @notice Pause a specific function (guardian can do this instantly)
    /// @param selector Function selector to pause
    function pauseFunction(bytes4 selector) external onlyGuardian {
        functionPaused[selector] = true;
        emit FunctionPauseStatusChanged(selector, true);
    }

    /// @notice Unpause a specific function (owner only, requires deliberation)
    /// @param selector Function selector to unpause
    function unpauseFunction(bytes4 selector) external onlyOwner {
        functionPaused[selector] = false;
        emit FunctionPauseStatusChanged(selector, false);
    }

    /// @notice Trip the circuit breaker (automatic or guardian)
    function tripCircuitBreaker() external onlyGuardian {
        circuitBreakerTripped = true;
        lastCircuitBreakerTrip = block.timestamp;
        emit CircuitBreakerReset(msg.sender);
    }

    /// @notice Reset the circuit breaker (owner only)
    function resetCircuitBreaker() external onlyOwner {
        require(
            block.timestamp >= lastCircuitBreakerTrip + CIRCUIT_BREAKER_COOLDOWN,
            "Cooldown period not elapsed"
        );
        circuitBreakerTripped = false;
        emit CircuitBreakerReset(msg.sender);
    }

    /// @notice Check if price change exceeds threshold and trip circuit breaker
    /// @param token Token address
    /// @param newPrice New price
    /// @return shouldTrip True if circuit breaker should trip
    function checkPriceCircuitBreaker(address token, uint256 newPrice) 
        external 
        returns (bool shouldTrip) 
    {
        uint256 oldPrice = lastKnownPrice[token];
        
        // Initialize if first check
        if (oldPrice == 0) {
            lastKnownPrice[token] = newPrice;
            return false;
        }

        // Calculate price change percentage
        uint256 priceChange;
        if (newPrice > oldPrice) {
            priceChange = ((newPrice - oldPrice) * 1e18) / oldPrice;
        } else {
            priceChange = ((oldPrice - newPrice) * 1e18) / oldPrice;
        }

        // Trip if change exceeds threshold
        if (priceChange > MAX_PRICE_CHANGE) {
            circuitBreakerTripped = true;
            lastCircuitBreakerTrip = block.timestamp;
            emit CircuitBreakerActivated(token, oldPrice, newPrice, priceChange);
            shouldTrip = true;
        }

        // Update last known price
        lastKnownPrice[token] = newPrice;
    }

    /// @notice Check if function is paused
    /// @param selector Function selector
    /// @return True if function is paused
    function isFunctionPaused(bytes4 selector) external view returns (bool) {
        return functionPaused[selector];
    }

    /// @notice Check if circuit breaker is active
    /// @return True if circuit breaker is tripped
    function isCircuitBreakerActive() external view returns (bool) {
        return circuitBreakerTripped;
    }
}

