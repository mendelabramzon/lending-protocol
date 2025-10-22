// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StableToken} from "../../src/StableToken.sol";

contract StableTokenTest is Test {
    StableToken public stableToken;
    address public owner;
    address public minter;
    address public user;

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    function setUp() public {
        owner = address(this);
        minter = makeAddr("minter");
        user = makeAddr("user");

        stableToken = new StableToken("Test Stable", "TST");
    }

    function test_Constructor() public {
        assertEq(stableToken.name(), "Test Stable");
        assertEq(stableToken.symbol(), "TST");
        assertEq(stableToken.decimals(), 18);
        assertEq(stableToken.owner(), owner);
    }

    function test_AddMinter() public {
        vm.expectEmit(true, false, false, false);
        emit MinterAdded(minter);
        
        stableToken.addMinter(minter);
        assertTrue(stableToken.isMinter(minter));
    }

    function test_RevertWhen_AddMinterZeroAddress() public {
        vm.expectRevert(StableToken.InvalidMinterAddress.selector);
        stableToken.addMinter(address(0));
    }

    function test_RevertWhen_AddMinterNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        stableToken.addMinter(minter);
    }

    function test_RemoveMinter() public {
        stableToken.addMinter(minter);
        assertTrue(stableToken.isMinter(minter));

        vm.expectEmit(true, false, false, false);
        emit MinterRemoved(minter);
        
        stableToken.removeMinter(minter);
        assertFalse(stableToken.isMinter(minter));
    }

    function test_Mint() public {
        stableToken.addMinter(minter);

        vm.prank(minter);
        stableToken.mint(user, 1000e18);

        assertEq(stableToken.balanceOf(user), 1000e18);
        assertEq(stableToken.totalSupply(), 1000e18);
    }

    function test_RevertWhen_MintNotMinter() public {
        vm.prank(user);
        vm.expectRevert(StableToken.NotAuthorizedMinter.selector);
        stableToken.mint(user, 1000e18);
    }

    function test_Burn() public {
        stableToken.addMinter(minter);

        vm.startPrank(minter);
        stableToken.mint(user, 1000e18);
        stableToken.burn(user, 500e18);
        vm.stopPrank();

        assertEq(stableToken.balanceOf(user), 500e18);
        assertEq(stableToken.totalSupply(), 500e18);
    }

    function test_RevertWhen_BurnNotMinter() public {
        stableToken.addMinter(minter);
        
        vm.prank(minter);
        stableToken.mint(user, 1000e18);

        vm.prank(user);
        vm.expectRevert(StableToken.NotAuthorizedMinter.selector);
        stableToken.burn(user, 500e18);
    }

    function test_MultipleMinters() public {
        address minter2 = makeAddr("minter2");
        
        stableToken.addMinter(minter);
        stableToken.addMinter(minter2);

        assertTrue(stableToken.isMinter(minter));
        assertTrue(stableToken.isMinter(minter2));

        vm.prank(minter);
        stableToken.mint(user, 500e18);

        vm.prank(minter2);
        stableToken.mint(user, 500e18);

        assertEq(stableToken.balanceOf(user), 1000e18);
    }
}

