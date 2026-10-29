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

    function test_missingOwnerUsesSwapSenderNotBundler() public {
        walletBuy("");
        assertEq(bid().owner, address(swapRouter));
        assertTrue(bid().owner != bundler);
    }

    function test_packedOwnerCreditsTheWallet() public {
        walletBuy(abi.encodePacked(address(wallet)));
        assertEq(bid().owner, address(wallet));
    }

    function test_abiEncodedOwnerCreditsTheWallet() public {
        walletBuy(abi.encode(address(wallet)));
        assertEq(bid().owner, address(wallet));
    }

    function test_dirtyAbiPaddingFallsBackToSender() public {
        walletBuy(abi.encode(uint256(1) << 160 | uint160(address(wallet))));
        assertEq(bid().owner, address(swapRouter));
    }

    function testFuzz_otherDataLengthsNeverCreditTheBundler(bytes memory data) public {
        vm.assume(data.length != 20 && data.length != 32);
        walletBuy(data);
        assertEq(bid().owner, address(swapRouter));
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

    function test_missingOwnerPaysTheSwapSender() public {
        checkCaptureReward("", address(swapRouter));
    }

    function test_aHookWithoutAnEthRouteRejectsRouteProofs() public {
        vm.expectRevert(IMDuelHook.NoRoute.selector);
        hook.sampleRoute("", new bytes[](0), new bytes[](0));
    }
}
