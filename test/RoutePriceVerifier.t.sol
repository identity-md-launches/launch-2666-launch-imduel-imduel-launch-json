// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoutePriceVerifier} from "../src/RoutePriceVerifier.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RouteProof} from "./RouteProof.sol";

contract RoutePriceVerifierTest is Test {
    RoutePriceVerifier verifier;
    address manager;
    bytes32 slot;
    uint256 constant PRICE = 1 << 96;

    function setUp() public {
        verifier = new RoutePriceVerifier();
        manager = makeAddr("proof manager");
        slot = keccak256("pool slot0");
        vm.roll(100);
    }

    function proof(uint256 number, uint256 value) internal returns (RouteProof.Proof memory p) {
        p = RouteProof.build(manager, slot, value, number);
        vm.setBlockhash(number, keccak256(p.header));
    }

    function verify(RouteProof.Proof memory p) internal view returns (uint256, uint160) {
        return verifier.verify(manager, slot, p.header, p.account, p.storageNodes);
    }

    function testFuzz_authenticatesSlot0AndItsBlock(uint160 price, uint96 otherFields) public {
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        RouteProof.Proof memory p = proof(98, uint256(price) | (uint256(otherFields) << 160));
        (uint256 start, uint160 actual) = verify(p);
        assertEq(start, 99);
        assertEq(actual, price);
    }

    function test_changedHeaderIsNotCanonical() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        p.header[p.header.length - 1] = bytes1(0x01);
        vm.expectRevert(RoutePriceVerifier.InvalidProof.selector);
        verify(p);
    }

    function test_wrongManagerIsRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        vm.expectRevert();
        verifier.verify(makeAddr("another manager"), slot, p.header, p.account, p.storageNodes);
    }

    function test_wrongPoolSlotIsRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        vm.expectRevert();
        verifier.verify(manager, bytes32(uint256(slot) + 1), p.header, p.account, p.storageNodes);
    }

    function test_changedStorageProofIsRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        p.storageNodes[0][p.storageNodes[0].length - 1] = bytes1(0x01);
        vm.expectRevert();
        verify(p);
    }

    function test_changedAccountProofIsRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        p.account[0][p.account[0].length - 1] ^= bytes1(0x01);
        vm.expectRevert();
        verify(p);
    }

    function test_emptyProofsAreRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        vm.expectRevert();
        verifier.verify(manager, slot, p.header, new bytes[](0), p.storageNodes);
        vm.expectRevert();
        verifier.verify(manager, slot, p.header, p.account, new bytes[](0));
    }

    function test_extraProofNodesAreRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        bytes[] memory extra = new bytes[](2);
        (extra[0], extra[1]) = (p.storageNodes[0], p.storageNodes[0]);
        vm.expectRevert();
        verifier.verify(manager, slot, p.header, p.account, extra);
    }

    function test_theBatchBlockCannotSupplyASample() public {
        RouteProof.Proof memory p = proof(99, PRICE); // authentic, but this block's start
        vm.expectRevert(RoutePriceVerifier.InvalidProof.selector);
        verify(p);
    }

    function test_unknownOrExpiredHeaderIsRefused() public {
        RouteProof.Proof memory p = proof(98, PRICE);
        vm.roll(355); // 257 blocks later: BLOCKHASH no longer serves it
        vm.expectRevert(RoutePriceVerifier.InvalidProof.selector);
        verify(p);
    }

    function test_uninitializedPoolPriceIsRefused() public {
        RouteProof.Proof memory p = proof(98, 0);
        vm.expectRevert(RoutePriceVerifier.InvalidProof.selector);
        verify(p);
    }

    function test_outOfRangePriceIsRefused() public {
        RouteProof.Proof memory p = proof(98, TickMath.MAX_SQRT_PRICE);
        vm.expectRevert(RoutePriceVerifier.InvalidProof.selector);
        verify(p);
    }

    /// A real eth_getProof response for an initialized PoolManager from an isolated local Anvil chain.
    /// Both tries contain branch nodes. The fixture is ordinary data, so this check needs no RPC or FFI.
    function test_clientGeneratedPoolManagerProof() public {
        string memory json = vm.readFile("./test/data/route-proof.json");
        uint256 number = vm.parseJsonUint(json, ".blockNumber");
        vm.roll(number + 2);
        vm.setBlockhash(number, vm.parseJsonBytes32(json, ".headerHash"));
        bytes[] memory accounts = vm.parseJsonBytesArray(json, ".accountProof");
        bytes[] memory storageNodes = vm.parseJsonBytesArray(json, ".storageProof");
        assertGt(accounts.length, 1);
        assertGt(storageNodes.length, 1);
        (uint256 start, uint160 price) = verifier.verify(
            vm.parseJsonAddress(json, ".manager"),
            vm.parseJsonBytes32(json, ".slot"),
            vm.parseJsonBytes(json, ".header"),
            accounts,
            storageNodes
        );
        assertEq(start, number + 1);
        assertEq(price, uint160(vm.parseUint(vm.parseJsonString(json, ".value"))));
        assertEq(price, PRICE);
    }
}
