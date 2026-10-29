// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {LaunchPolicy} from "../script/LaunchPolicy.sol";
import {V4Fixture} from "./V4Fixture.sol";

contract FactoryLaunchReceiver {}

/// The factory's actions in one call: CREATE2 both real contracts, initialize, allocate and seed. Creation code
/// is supplied as data, so the test factory itself stays within EIP-170 like the production generic factory.
contract FactoryLaunchProbe is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager immutable manager;
    address immutable paired;
    IMDuelToken public token;
    IMDuelHook public hook;
    PoolKey public key;
    int24 lower;
    int24 upper;
    address public distributor;

    constructor(IPoolManager manager_, address paired_) {
        (manager, paired) = (manager_, paired_);
    }

    function deploy(bytes memory code, bytes32 salt) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "factory deployment");
    }

    function launch(bytes memory tokenCode, bytes memory hookCode, bytes32 tokenSalt, bytes32 hookSalt) external {
        require(address(token) == address(0));
        token = IMDuelToken(deploy(tokenCode, tokenSalt));
        require(token.totalSupply() == LaunchPolicy.SUPPLY && token.balanceOf(address(this)) == LaunchPolicy.SUPPLY);
        hook = IMDuelHook(deploy(hookCode, hookSalt));
        bool tokenFirst = address(token) < paired;
        (Currency a, Currency b) = tokenFirst
            ? (Currency.wrap(address(token)), Currency.wrap(paired))
            : (Currency.wrap(paired), Currency.wrap(address(token)));
        uint160 price;
        uint256 liquidity;
        (price, lower, upper, liquidity) = LaunchPolicy.opening(tokenFirst);
        key = PoolKey(a, b, LaunchPolicy.FEE, LaunchPolicy.SPACING, IHooks(address(hook)));
        manager.initialize(key, price);
        distributor = address(new FactoryLaunchReceiver());
        token.transfer(distributor, LaunchPolicy.SUPPLY / 10);
        token.transfer(0x6AA302EFf055259c9Cf177f33Ae3cBA5d4135B23, LaunchPolicy.SUPPLY / 20);
        manager.unlock(abi.encode(int256(liquidity)));
    }

    function collect() external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(int256(0))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, abi.decode(data, (int256)), 0), "");
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency c, int128 amount) internal {
        if (amount < 0) {
            manager.sync(c);
            c.transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, address(this), uint256(uint128(amount)));
        }
    }
}

contract FactoryLaunchTest is V4Fixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant ENGINE = 0xc21788F704a8b9456f7391A01d8a3D95Be215a27;

    function predicted(address factory, bytes32 hash, uint256 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, bytes32(salt), hash)))));
    }

    function run(bool tokenFirst) internal {
        deployV4();
        vm.etch(IMD, address(mockToken("IMD", "IMD")).code);
        FactoryLaunchProbe factory = new FactoryLaunchProbe(manager, IMD);
        bytes memory tokenCode = vm.getCode("IMDuelToken.sol:IMDuelToken");
        bytes memory hookCode = abi.encodePacked(
            vm.getCode("IMDuelHook.sol:IMDuelHook"),
            abi.encode(
                manager,
                IChessEngine(ENGINE),
                Currency.wrap(IMD),
                uint24(10_000),
                uint24(200),
                uint256(10 ether),
                uint256(0.02 ether),
                uint256(1_000_000 ether),
                uint256(3)
            )
        );
        uint256 tokenSalt;
        bytes32 hash = keccak256(tokenCode);
        while ((predicted(address(factory), hash, tokenSalt) < IMD) != tokenFirst) tokenSalt++;
        uint256 hookSalt;
        hash = keccak256(hookCode);
        while (uint160(predicted(address(factory), hash, hookSalt)) & Hooks.ALL_HOOK_MASK != IMDUEL_HOOK_FLAGS) {
            hookSalt++;
        }
        assertEq(ENGINE.code.length, 0, "the constructor must work without the engine");
        factory.launch(tokenCode, hookCode, bytes32(tokenSalt), bytes32(hookSalt));
        IMDuelToken t = factory.token();
        IMDuelHook h = factory.hook();
        assertEq(address(t) < IMD, tokenFirst);
        assertEq(t.totalSupply(), LaunchPolicy.SUPPLY);
        assertEq(t.balanceOf(factory.distributor()), LaunchPolicy.SUPPLY / 10);
        assertEq(t.balanceOf(0x6AA302EFf055259c9Cf177f33Ae3cBA5d4135B23), LaunchPolicy.SUPPLY / 20);
        assertEq(Currency.unwrap(h.imduel()), address(t));
        assertEq(address(h.manager()), address(manager));
        assertEq(address(h.engine()), ENGINE);
        assertEq(h.turnBlocks(), 3);
        assertGt(address(h.routePriceVerifier()).code.length, 0);
        (Currency c0, Currency c1) = tokenFirst
            ? (Currency.wrap(address(t)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(t)));
        PoolKey memory k = PoolKey(c0, c1, 12_500, 60, IHooks(address(h)));
        assertTrue(h.game(k.toId()).main);
        MockERC20(IMD).mint(address(this), 1000 ether);
        MockERC20(IMD).approve(address(swapRouter), type(uint256).max);
        t.approve(address(swapRouter), type(uint256).max);
        swap(k, !tokenFirst, -50 ether, abi.encodePacked(address(this)));
        swap(k, tokenFirst, -1_000_000 ether, abi.encodePacked(address(this)));
        swap(k, !tokenFirst, 10_000 ether, abi.encodePacked(address(this)));
        swap(k, tokenFirst, 0.01 ether, abi.encodePacked(address(this)));
        BalanceDelta collected = factory.collect();
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(
            int256(collected.amount0()) + collected.amount1(), 0, "factory collects LP fees with zero liquidity change"
        );
        for (uint256 i; i < 2; i++) {
            Currency c = i == 0 ? c0 : c1;
            assertEq(manager.balanceOf(address(h), c.toId()), h.chest(k.toId(), i) + h.pile(c.toId()));
        }
    }

    function test_factoryLaunchWithRealTokenBelowImd() public {
        run(true);
    }

    function test_factoryLaunchWithRealTokenAboveImd() public {
        run(false);
    }
}
