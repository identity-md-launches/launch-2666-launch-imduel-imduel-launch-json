// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";

/// $IMDUEL on the launch's standard terms: the whole fixed supply to the deployer, plain transfers and allowances,
/// nothing privileged.
contract TokenTest is Test {
    IMDuelToken token;
    address factory = makeAddr("factory");
    address a = makeAddr("a");
    address b = makeAddr("b");

    function setUp() public {
        vm.prank(factory);
        token = new IMDuelToken();
    }

    function test_fixedSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(factory), 1_000_000_000e18);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "IMDuel");
        assertEq(token.symbol(), "IMDUEL");
    }

    function test_transfers() public {
        vm.prank(factory);
        assertTrue(token.transfer(a, 10e18));
        assertEq(token.balanceOf(a), 10e18);
        vm.prank(a);
        token.transfer(a, 10e18); // to itself: unchanged
        assertEq(token.balanceOf(a), 10e18);
        vm.prank(a);
        vm.expectRevert(IMDuelToken.InsufficientBalance.selector);
        token.transfer(b, 11e18);
        vm.prank(a);
        vm.expectRevert(IMDuelToken.InvalidAddress.selector);
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), token.balanceOf(factory) + token.balanceOf(a), "the supply is fixed");
    }

    function test_allowances() public {
        vm.prank(factory);
        token.transfer(a, 10e18);
        vm.prank(b);
        vm.expectRevert(IMDuelToken.InsufficientAllowance.selector);
        token.transferFrom(a, b, 1);
        vm.prank(a);
        token.approve(b, 4e18);
        vm.prank(b);
        assertTrue(token.transferFrom(a, b, 3e18));
        assertEq(token.allowance(a, b), 1e18, "spent");
        vm.prank(b);
        vm.expectRevert(IMDuelToken.InsufficientAllowance.selector);
        token.transferFrom(a, b, 2e18);
        vm.prank(a);
        token.approve(b, type(uint256).max);
        vm.prank(b);
        token.transferFrom(a, b, 7e18);
        assertEq(token.allowance(a, b), type(uint256).max, "an unlimited allowance stays");
        assertEq(token.balanceOf(b), 10e18);
        vm.prank(a);
        vm.expectRevert(IMDuelToken.InvalidAddress.selector);
        token.approve(address(0), 1);
    }

    /// Nothing but the ERC-20 surface: every other selector reverts (no owner, mint, burn, pause or blocklist).
    function test_nothingPrivileged() public {
        bytes4[7] memory selectors = [bytes4(keccak256("mint(address,uint256)")), bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("owner()")), bytes4(keccak256("pause()")), bytes4(keccak256("blacklist(address)")),
            bytes4(keccak256("setFee(uint256)")), bytes4(keccak256("transferOwnership(address)"))];
        for (uint256 i; i < selectors.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), 1));
            assertFalse(ok, "no such function");
        }
        assertEq(address(token).balance, 0);
        (bool sent,) = address(token).call{value: 0}("");
        assertFalse(sent, "no fallback");
    }
}
