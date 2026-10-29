// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {SyncingOwner} from "./Tokens.sol";

/// The real hook plus one test-only setter, to start from a position where the side to move must capture a queen.
/// The reviewer's proof for finding 28dc1ba6 deploys this harness by artifact name ("Proof_SyncRecipient.t.sol:PositionHook"),
/// so this file keeps that name and the harness its constructor and setter signatures.
contract PositionHook is IMDuelHook {
    constructor(IPoolManager m, IChessEngine e, Currency imd_)
        IMDuelHook(m, e, imd_, 0, 0, type(uint256).max, type(uint256).max, type(uint256).max, 1)
    {}

    function setPosition(PoolId id, uint256 board, uint32 white, uint32 black) external {
        Game storage g = games[id];
        (g.board, g.whiteState, g.blackState, g.ply, g.quiet) = (board, white, black, 0, 0);
    }
}

/// Finding 28dc1ba6 (medium): a move owner whose receive() only calls manager.sync(IMD) moves no delta, so a payout
/// guard that only looks at deltas pays it and leaves IMD synced; the router's native settle{value}() that follows in
/// the same unlock then reverts NonzeroNativeValue, so the ETH-paying trade that plays the move reverts, and so does
/// every later ETH-paying trade of the duel. payOut also snapshots the synced currency and reserves now: the payout
/// is refused, the reward stays owed, the trade goes through. Same shape as the reviewer's proof, on the real hook
/// through PoolSwapTest.
contract SyncRecipientTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest router;
    PositionHook hook;
    PoolKey key;
    PoolId id;
    MockERC20 imd;

    function sq(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        return uint256(uint8(b[0]) - 97) + 8 * uint256(uint8(b[1]) - 49);
    }

    function put(uint256 board, string memory s, uint256 piece) internal pure returns (uint256) {
        return board | (piece << (sq(s) << 2));
    }

    function side(string memory k) internal pure returns (uint32) {
        return 0x80800000 | (uint32(sq(k)) << 8) | 0xff;
    }

    function swap(bool zeroForOne, uint256 amountIn, bytes memory data) internal {
        router.swap{value: zeroForOne ? amountIn : 0}(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    function setUp() public {
        manager = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        router = PoolSwapTest(vm.deployCode("PoolSwapTest.sol:PoolSwapTest", abi.encode(manager)));
        PoolModifyLiquidityTest lp = PoolModifyLiquidityTest(
            vm.deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", abi.encode(manager))
        );
        IChessEngine engine = IChessEngine(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));
        imd = new MockERC20("IMD", "IMD", 18);
        MockERC20 imduel = new MockERC20("IMDUEL", "IMDUEL", 18);
        address at = address(IMDUEL_HOOK_FLAGS | (uint160(0x1D0E1) << 40));
        deployCodeTo(
            "Proof_SyncRecipient.t.sol:PositionHook", abi.encode(manager, engine, Currency.wrap(address(imd))), at
        );
        hook = PositionHook(payable(at));
        // the main duel (IMD / IMDUEL) first, then a native ETH / IMD duel
        (address a, address b) =
            address(imd) < address(imduel) ? (address(imd), address(imduel)) : (address(imduel), address(imd));
        manager.initialize(PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(at)), 2 ** 96);
        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(imd)), 3000, 60, IHooks(at));
        id = key.toId();
        manager.initialize(key, 2 ** 96);

        imd.mint(address(this), 1e30);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1e30);
        lp.modifyLiquidity{value: 1e27}(key, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        hook.fundChest{value: 10 ether}(key, false, 10 ether);
        // the IMD chest too (bigger), so the trades' chest share is minted in ETH, the smaller chest
        imd.approve(address(hook), type(uint256).max);
        hook.fundChest(key, true, 100e18);

        // ETH's team is White in game 0 and is in check from an unprotected queen: Kxe2 is its only move
        uint256 board;
        board = put(board, "e1", 6);
        board = put(board, "h1", 4);
        board = put(board, "e2", 13);
        board = put(board, "a8", 14);
        board = put(board, "a7", 9);
        hook.setPosition(id, board, side("e1"), side("a8"));
    }

    function test_anEthPayingTradeThatPaysASyncingOwnerGoesThrough() public {
        SyncingOwner r = new SyncingOwner(manager, Currency.wrap(address(imd)));
        swap(false, 1e18, abi.encodePacked(address(r))); // IMD in: buys ETH, bids for White's move for r
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        uint256 chest = hook.chest(id, 0);
        // ETH in: the first trade after the window plays White's move. r's sync(IMD) is refused: the reward stays owed
        swap(true, 1e18, "");
        assertEq(hook.game(id).ply, 1, "the move is played");
        assertEq(address(r).balance, 0, "not pushed");
        uint256 owed = hook.owed(address(r), 0);
        assertGt(owed, 0, "the bounty is owed");
        assertEq(hook.chest(id, 0) + owed, chest + 1e18 * hook.CHEST_BPS() / 10_000, "the bounty left the chest");
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(0), "nothing left synced");
        // every later ETH-paying trade goes through too, and r collects its reward outside any trade
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        swap(true, 1e18, "");
        hook.withdraw(address(r), CurrencyLibrary.ADDRESS_ZERO);
        assertEq(address(r).balance, owed, "collected");
    }

    receive() external payable {}
}
