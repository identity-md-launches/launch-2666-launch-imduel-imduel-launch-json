// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";

/// A contract wallet pays for a swap, while the outer transaction can be sent by a bundler.
contract BidWallet {
    function buy(PoolSwapTest router, PoolKey memory key, bytes memory data, uint160 limit) external {
        MockERC20(Currency.unwrap(key.currency0)).approve(address(router), 1 ether);
        router.swap(key, SwapParams(true, -1 ether, limit), PoolSwapTest.TestSettings(false, false), data);
    }
}

contract BidOwnerTest is Base {
    BidWallet wallet;
    address bundler;

    function setUp() public {
        setUpMainDuel();
        wallet = new BidWallet();
        bundler = makeAddr("bundler");
        MockERC20(Currency.unwrap(currency0)).mint(address(wallet), 10 ether);
    }

    function walletBuy(bytes memory data) internal {
        vm.prank(bundler, bundler);
        wallet.buy(swapRouter, pool, data, MIN_PRICE_LIMIT);
    }

    /// No recipient in hookData: the bid is nobody's. Never the swap sender (through a router, the router, where a
    /// bounty is sweepable or stuck) and never the outer signer (a bundler or relayer).
    function test_missingOwnerIsNobodyNotTheRouterNorTheBundler() public {
        walletBuy("");
        assertTrue(bid().open, "it still bids");
        assertEq(bid().owner, address(0));
    }

    function test_packedOwnerCreditsTheWallet() public {
        walletBuy(abi.encodePacked(address(wallet)));
        assertEq(bid().owner, address(wallet));
    }

    function test_abiEncodedOwnerCreditsTheWallet() public {
        walletBuy(abi.encode(address(wallet)));
        assertEq(bid().owner, address(wallet));
    }

    function test_dirtyAbiPaddingIsNobody() public {
        walletBuy(abi.encode(uint256(1) << 160 | uint160(address(wallet))));
        assertEq(bid().owner, address(0));
    }

    function testFuzz_otherDataLengthsNeverCreditTheBundlerOrTheRouter(bytes memory data) public {
        vm.assume(data.length != 20 && data.length != 32);
        walletBuy(data);
        assertEq(bid().owner, address(0));
    }

    function forcedCapture() internal {
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), 10 ether);
        hook.fundChest(pool, true, 10 ether);
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "h1", 4);
        b = put(b, "e2", 13);
        b = put(b, "a8", 14);
        b = put(b, "a7", 9);
        hook.setPosition(id, b, side("e1"), side("a8"), 0, 0);
    }

    function checkCaptureReward(bytes memory data, address recipient) internal {
        forcedCapture();
        walletBuy(data);
        MockERC20 reward = MockERC20(Currency.unwrap(currency1));
        uint256 beforeBalance = reward.balanceOf(recipient);
        next(12);
        black(1 ether, address(this));
        assertEq(st().moveOwner, recipient);
        assertEq(st().moveCaptured, 5);
        assertEq(reward.balanceOf(recipient) - beforeBalance, 0.27 ether);
        assertEq(reward.balanceOf(bundler), 0, "the outer signer never receives the bounty");
        assertEq(hook.owed(bundler, uint160(Currency.unwrap(currency1))), 0);
    }

    function test_abiEncodedOwnerReceivesTheCaptureBounty() public {
        checkCaptureReward(abi.encode(address(wallet)), address(wallet));
    }

    /// A move nobody owns is played and pays no bounty: the chest keeps it, nothing goes to or is owed to the router.
    function test_missingOwnerPlaysButPaysNobody() public {
        forcedCapture();
        walletBuy("");
        MockERC20 reward = MockERC20(Currency.unwrap(currency1));
        uint256 routerBefore = reward.balanceOf(address(swapRouter));
        uint256 chestBefore = hook.chest(id, 1);
        next(12);
        black(1 ether, address(this));
        assertEq(st().ply, 1, "the move is played");
        assertEq(st().moveCaptured, 5);
        assertEq(st().moveOwner, address(0));
        assertEq(reward.balanceOf(address(swapRouter)), routerBefore, "nothing pushed to the router");
        assertEq(hook.owed(address(swapRouter), uint160(Currency.unwrap(currency1))), 0, "nothing owed to the router");
        assertEq(hook.owed(bundler, uint160(Currency.unwrap(currency1))), 0);
        assertEq(hook.owed(address(wallet), uint160(Currency.unwrap(currency1))), 0);
        assertGe(hook.chest(id, 1), chestBefore, "the chest keeps the bounty");
    }

    function test_aHookWithoutAnEthRouteRejectsRouteProofs() public {
        vm.expectRevert(IMDuelHook.NoRoute.selector);
        hook.sampleRoute("", new bytes[](0), new bytes[](0));
    }
}
