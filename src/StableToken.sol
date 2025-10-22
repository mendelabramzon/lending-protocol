// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StableToken
/// @notice Native ERC20 stablecoin for the lending protocol
/// @dev Only authorized contracts (VaultManager) can mint and burn tokens
contract StableToken is ERC20, Ownable {
    /// @notice Mapping of authorized minters
    mapping(address => bool) public isMinter;

    /// @notice Emitted when a minter is added
    event MinterAdded(address indexed minter);

    /// @notice Emitted when a minter is removed
    event MinterRemoved(address indexed minter);

    /// @notice Error thrown when caller is not authorized to mint
    error NotAuthorizedMinter();

    /// @notice Error thrown when trying to add zero address as minter
    error InvalidMinterAddress();

    /// @notice Initialize the stablecoin
    /// @param _name Token name
    /// @param _symbol Token symbol
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) Ownable(msg.sender) {}

    /// @notice Modifier to check if caller is authorized minter
    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotAuthorizedMinter();
        _;
    }

    /// @notice Add an authorized minter
    /// @param minter Address to authorize for minting
    function addMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert InvalidMinterAddress();
        isMinter[minter] = true;
        emit MinterAdded(minter);
    }

    /// @notice Remove an authorized minter
    /// @param minter Address to remove from minters
    function removeMinter(address minter) external onlyOwner {
        isMinter[minter] = false;
        emit MinterRemoved(minter);
    }

    /// @notice Mint new stablecoins
    /// @param to Address to receive minted tokens
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    /// @notice Burn stablecoins
    /// @param from Address to burn tokens from
    /// @param amount Amount of tokens to burn
    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}

