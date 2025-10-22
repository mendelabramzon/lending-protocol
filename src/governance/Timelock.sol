// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Timelock
/// @notice Time-delayed execution of administrative functions for security
/// @dev Allows users to exit the protocol before critical parameter changes take effect
contract Timelock is Ownable {
    /// @notice Minimum delay before execution (2 days)
    uint256 public constant MINIMUM_DELAY = 2 days;

    /// @notice Maximum delay before execution expires (30 days)
    uint256 public constant MAXIMUM_DELAY = 30 days;

    /// @notice Grace period after delay expires (7 days)
    uint256 public constant GRACE_PERIOD = 7 days;

    /// @notice Current delay setting
    uint256 public delay;

    /// @notice Struct representing a queued transaction
    struct QueuedTransaction {
        address target;
        uint256 value;
        string signature;
        bytes data;
        uint256 eta; // Estimated time of execution
        bool executed;
        bool cancelled;
    }

    /// @notice Mapping of transaction hash => queued transaction
    mapping(bytes32 => QueuedTransaction) public queuedTransactions;

    /// @notice Array of all queued transaction hashes
    bytes32[] public queuedTxHashes;

    /// @notice Emitted when a transaction is queued
    event TransactionQueued(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    /// @notice Emitted when a transaction is executed
    event TransactionExecuted(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    /// @notice Emitted when a transaction is cancelled
    event TransactionCancelled(bytes32 indexed txHash);

    /// @notice Emitted when delay is updated
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);

    /// @notice Error thrown when delay is out of bounds
    error InvalidDelay();

    /// @notice Error thrown when transaction is not queued
    error TransactionNotQueued();

    /// @notice Error thrown when transaction is already queued
    error TransactionAlreadyQueued();

    /// @notice Error thrown when transaction is too early to execute
    error TransactionTooEarly();

    /// @notice Error thrown when transaction is expired
    error TransactionExpired();

    /// @notice Error thrown when transaction already executed
    error TransactionAlreadyExecuted();

    /// @notice Error thrown when transaction is cancelled
    error TransactionIsCancelled();

    /// @notice Error thrown when execution fails
    error ExecutionFailed();

    /// @notice Initialize the timelock with a delay
    /// @param _delay Initial delay period
    constructor(uint256 _delay) Ownable(msg.sender) {
        if (_delay < MINIMUM_DELAY || _delay > MAXIMUM_DELAY) revert InvalidDelay();
        delay = _delay;
    }

    /// @notice Queue a transaction for execution
    /// @param target Target contract address
    /// @param value ETH value to send
    /// @param signature Function signature
    /// @param data Calldata
    /// @param eta Estimated time of execution
    /// @return txHash Transaction hash
    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyOwner returns (bytes32 txHash) {
        if (eta < block.timestamp + delay) revert InvalidDelay();

        txHash = keccak256(abi.encode(target, value, signature, data, eta));

        if (queuedTransactions[txHash].eta != 0) revert TransactionAlreadyQueued();

        queuedTransactions[txHash] = QueuedTransaction({
            target: target,
            value: value,
            signature: signature,
            data: data,
            eta: eta,
            executed: false,
            cancelled: false
        });

        queuedTxHashes.push(txHash);

        emit TransactionQueued(txHash, target, value, signature, data, eta);

        return txHash;
    }

    /// @notice Execute a queued transaction
    /// @param target Target contract address
    /// @param value ETH value to send
    /// @param signature Function signature
    /// @param data Calldata
    /// @param eta Estimated time of execution
    /// @return result Return data from execution
    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external payable onlyOwner returns (bytes memory result) {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));

        QueuedTransaction storage queuedTx = queuedTransactions[txHash];

        if (queuedTx.eta == 0) revert TransactionNotQueued();
        if (queuedTx.executed) revert TransactionAlreadyExecuted();
        if (queuedTx.cancelled) revert TransactionIsCancelled();
        if (block.timestamp < queuedTx.eta) revert TransactionTooEarly();
        if (block.timestamp > queuedTx.eta + GRACE_PERIOD) revert TransactionExpired();

        queuedTx.executed = true;

        bytes memory callData;
        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        if (!success) revert ExecutionFailed();

        emit TransactionExecuted(txHash, target, value, signature, data, eta);

        return returnData;
    }

    /// @notice Cancel a queued transaction
    /// @param target Target contract address
    /// @param value ETH value to send
    /// @param signature Function signature
    /// @param data Calldata
    /// @param eta Estimated time of execution
    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyOwner {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));

        QueuedTransaction storage queuedTx = queuedTransactions[txHash];

        if (queuedTx.eta == 0) revert TransactionNotQueued();
        if (queuedTx.executed) revert TransactionAlreadyExecuted();
        if (queuedTx.cancelled) revert TransactionIsCancelled();

        queuedTx.cancelled = true;

        emit TransactionCancelled(txHash);
    }

    /// @notice Update the delay period
    /// @param newDelay New delay period
    function setDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MINIMUM_DELAY || newDelay > MAXIMUM_DELAY) revert InvalidDelay();
        uint256 oldDelay = delay;
        delay = newDelay;
        emit DelayUpdated(oldDelay, newDelay);
    }

    /// @notice Get all queued transaction hashes
    /// @return hashes Array of transaction hashes
    function getAllQueuedTransactions() external view returns (bytes32[] memory hashes) {
        return queuedTxHashes;
    }

    /// @notice Get details of a queued transaction
    /// @param txHash Transaction hash
    /// @return queuedTx The queued transaction details
    function getQueuedTransaction(bytes32 txHash) external view returns (QueuedTransaction memory queuedTx) {
        return queuedTransactions[txHash];
    }

    /// @notice Receive ETH
    receive() external payable {}
}

