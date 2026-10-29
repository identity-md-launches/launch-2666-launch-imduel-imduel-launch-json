// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {IMDuelHarness, HookConfig} from "./Harness.sol";
import {Base} from "./Base.sol";

/// Regression for audit a878ce8b: every attack round restores the route before the next block.
contract RouteSampleTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    Currency imd;
    Currency duel;
    PoolKey route;
    PoolKey ethX;

    function token(string memory name) internal returns (Currency) {
        MockERC20 t = mockToken(name, name);
        t.mint(address(this), 1e30);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        return Currency.wrap(address(t));
    }

    function setUp() public {
        deployV4();
        vm.deal(address(this), 1e30);
        imd = token("IMD");
        duel = token("IMDUEL");
        Currency x = token("X");
        HookConfig memory c = config(IChessEngine(0xc21788F704a8b9456f7391A01d8a3D95Be215a27), imd);
        (c.ethFee, c.ethSpacing, c.minEth, c.minImd) = (3000, 60, 0.1 ether, 0.1 ether);
        // Test the production hook, including its constructor, rather than a conversion override.
        address at = address(IMDUEL_HOOK_FLAGS | (uint160(0xA878) << 40));
        deployCodeTo("IMDuelHook.sol:IMDuelHook", abi.encode(c), at);
        hook = IMDuelHarness(at);
        (Currency c0, Currency c1) = imd < duel ? (imd, duel) : (duel, imd);
        (pool, id) = initPool(c0, c1, IHooks(at), 12_500, 60, SQRT_PRICE_1_1);
        addLiquidity(pool);
        sampleBlocks(pool);
        route = PoolKey(CurrencyLibrary.ADDRESS_ZERO, imd, 3000, 60, IHooks(address(0)));
        manager.initialize(route, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 20 ether}(
            route, ModifyLiquidityParams(-887220, 887220, 10e18, 0), ""
        );
        (ethX,) = initPool(CurrencyLibrary.ADDRESS_ZERO, x, IHooks(at), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1e24}(ethX, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        swapNativeInput(ethX, true, -1000 ether, "", 1000 ether);
        assertEq(hook.pile(0), 1 ether);
    }

    function pushRoute(bool zeroForOne, uint160 target) internal {
        swapRouter.swap{value: zeroForOne ? 10 ether : 0}(
            route, SwapParams(zeroForOne, -10 ether, target), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    /// The attack's swaps, liquidity and conversion all happen inside one call, with no block boundary.
    function attackRound() external {
        (uint160 start,,,) = manager.getSlot0(route.toId());
        assertEq(start, SQRT_PRICE_1_1, "honest price at every block boundary");
        int24 edge = TickMath.getTickAtSqrtPrice(uint160(uint256(start) * 7 / 10)) / 60 * 60;
        pushRoute(true, TickMath.getSqrtPriceAtTick(edge));
        ModifyLiquidityParams memory band = ModifyLiquidityParams(edge - 60, edge, 1e22, 0);
        modifyLiquidityRouter.modifyLiquidity(route, band, "");
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        band.liquidityDelta = -1e22;
        modifyLiquidityRouter.modifyLiquidity(route, band, "");
        pushRoute(false, start);
        (uint160 end,,,) = manager.getSlot0(route.toId());
        assertEq(end, start, "price restored in the same transaction");
    }

    function test_callerSamplesCannotSellTheEthPileAtAPushedPrice() public {
        uint256 beforeValue = address(this).balance + imd.balanceOf(address(this));
        for (uint256 i; i < 4; i++) {
            next(12);
            this.attackRound();
        }
        int256 profit = int256(address(this).balance + imd.balanceOf(address(this))) - int256(beforeValue);
        emit log_named_int("route attacker profit at the honest price", profit);
        assertLe(profit, 0, "a batch priced against block-start prices cannot be sold a pushed price");
        assertEq(hook.pile(0), 1 ether, "unauthenticated intrablock samples cannot spend the pile");
    }

    function seedAuthenticatedHistory() internal {
        uint256 n = vm.getBlockNumber();
        proveRoute(n - 3);
        proveRoute(n - 2);
        proveRoute(n - 1);
    }

    function test_authenticatedBlockStartsRejectTheSameAttack() public {
        seedAuthenticatedHistory();
        uint256 beforeValue = address(this).balance + imd.balanceOf(address(this));
        for (uint256 i; i < 4; i++) {
            next(12);
            // Record the canonical boundary before the attacker moves the route inside its transaction.
            proveRoute(vm.getBlockNumber() - 1);
            this.attackRound();
        }
        assertLe(address(this).balance + imd.balanceOf(address(this)), beforeValue);
        assertEq(hook.pile(0), 1 ether, "the historical honest price refuses the pushed band");
    }

    function test_honestBatchRunsAndStopsAtTheHistoricalPriceBand() public {
        seedAuthenticatedHistory();
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        uint256 left = hook.pile(0);
        assertLt(left, 1 ether, "authenticated prices allow conversion");
        assertGt(left, 0.9 ether, "the thin route cannot sell the whole batch inside the band");
        (uint160 price,,,) = manager.getSlot0(route.toId());
        assertGe(price, uint256(SQRT_PRICE_1_1) * 9990 / 10_000);
        assertGt(duel.balanceOf(address(0xdEaD)), 0, "the second leg buys and burns IMDUEL");
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.pile(0), left, "at most one route batch per block");
        PoolKey[] memory pools = new PoolKey[](2);
        (pools[0], pools[1]) = (pool, ethX);
        assertSolvent(CurrencyLibrary.ADDRESS_ZERO, pools, nobody());
        assertSolvent(imd, pools, nobody());
        assertSolvent(duel, pools, nobody());
    }

    function test_staleRoutePricesWaitWithoutLosingClaims() public {
        seedAuthenticatedHistory();
        next(12);
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.pile(0), 1 ether);
        proveRoute(vm.getBlockNumber() - 1);
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        assertLt(hook.pile(0), 1 ether, "a fresh proof resumes conversion");
    }

    function test_gapRequiresThreeConsecutiveSamplesAgain() public {
        seedAuthenticatedHistory();
        next(12);
        next(12);
        proveRoute(vm.getBlockNumber() - 1);
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.pile(0), 1 ether);
        sampleRoute(1);
        assertEq(hook.pile(0), 1 ether);
        sampleRoute(1);
        assertLt(hook.pile(0), 1 ether);
    }

    function test_duplicateSampleCannotRotateOutHonestHistory() public {
        proveRoute(vm.getBlockNumber() - 1);
        vm.expectRevert(bytes4(keccak256("BadSample()")));
        this.repeatProof();
    }

    function repeatProof() external {
        proveRoute(vm.getBlockNumber() - 1);
    }
}
