// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Rules} from "../src/Rules.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {
    BlockToken,
    SkimToken,
    ReenterToken,
    VoidToken,
    CallbackToken,
    DebtOwner,
    SettleForOwner,
    SyncingOwner,
    NoReceive
} from "./Tokens.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// Fails to choose; its fallback plays the first legal move.
contract BrokenEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        revert("broken");
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256)
        external
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        m = Bitboard.legalMoves(Bitboard.fromBoard(board, w, b), !black)[0];
        return (m, Rules.move(board, mover, other, black, m));
    }
}

/// Fails to choose and to fall back: the turn can only wait.
contract DeadEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        revert("dead");
    }

    function playAny(uint256, uint32, uint32, bool, uint256) external pure returns (uint16, Rules.Played memory) {
        revert("dead");
    }
}

/// Anyone can create a pool with any token: hostile tokens and engine failures must never break trading or the books.
/// Runs out of gas on every choice (a pathological position); its fallback plays the first legal move.
contract GreedyEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        while (true) {}
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256)
        external
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        m = Bitboard.legalMoves(Bitboard.fromBoard(board, w, b), !black)[0];
        return (m, Rules.move(board, mover, other, black, m));
    }
}

contract HostileTest is Base {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    Currency token; // the hostile token, paired with a plain one

    function setUp() public {
        deployV4();
    }

    /// A pool of `t` against the hook's IMD (every duel needs a route for its slice), with liquidity.
    function pairWith(MockERC20 t) internal {
        MockERC20 q = deployHookAside(v5());
        for (uint256 i; i < 2; i++) {
            MockERC20 x = i == 0 ? t : q;
            x.mint(address(this), 1e30);
            x.approve(address(swapRouter), type(uint256).max);
            x.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        t.approve(address(hook), type(uint256).max);
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        token = Currency.wrap(address(t));
    }

    /// A native ETH / IMD duel on a hook aside, with liquidity: ETH's team is the "token" team.
    function pairEth() internal {
        MockERC20 q = deployHookAside(v5());
        q.mint(address(this), 1e30);
        q.approve(address(swapRouter), type(uint256).max);
        q.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 1e30);
        (pool, id) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(q)), IHooks(address(hook)), 3000, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 1e27}(pool, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        token = CurrencyLibrary.ADDRESS_ZERO;
    }

    /// The token's team (White in game 0) is in check from an unprotected queen next to its king: Kxe2 is its only
    /// move. `owner` bids for it with 1 unit of the other token; the next block's trade plays it and pays the queen's
    /// bounty (2.7% of the team's chest, well under the 2x cap) to `owner`, through the real resolve path.
    function queenForcedOn(address owner) internal {
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "h1", 4);
        b = put(b, "e2", 13);
        b = put(b, "a8", 14);
        b = put(b, "a7", 9);
        hook.setPosition(id, b, side("e1"), side("a8"), 0, 0);
        assertEq(whiteTeam(), tokenTeam(), "the token's team is White in game 0");
        white(1e18, owner);
        next(12);
        black(1e18, address(0)); // plays White's move first
    }

    function tokenTeam() internal view returns (uint256) {
        return pool.currency0 == token ? 0 : 1;
    }

    /// The token's team captures a queen with check (3% of its chest) for `owner`.
    function tokenTeamTakesQueenFor(address owner) internal {
        bool blackMoves = tokenTeam() != whiteTeam();
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "e8", 14);
        b = put(b, "a1", blackMoves ? 5 : 4);
        b = put(b, "a8", blackMoves ? 12 : 13);
        hook.setPosition(id, b, side("e1"), side("e8"), blackMoves ? 1 : 0, 0);
        hook.applyMove(pool, blackMoves ? mv("a8", "a1") : mv("a1", "a8"), owner, 1e30);
    }

    function finalizeWithATinyTrade() internal {
        next(12);
        trade(1 - tokenTeam(), 100, address(0));
    }

    // ---------------------------------------------------------------- engine failure

    /// A trade sent with too little gas for the engine must not get the fallback's seeded legal move instead (which
    /// would let anyone force an unthinking move on the queued turn by choosing the gas limit): it either plays the
    /// engine's move or reverts (NotEnoughGas), so gas estimates include the move. Swept over gas limits around the engine's cost, each from the same state.
    function test_starvingTheEngineNeverPlaysTheFallback() public {
        setUpMainDuel();
        white(1e18, address(0xA)); // a turn to play
        next(12);
        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                pool,
                SwapParams(toMove() == 1, -1e18, toMove() == 1 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                bytes("")
            )
        );
        uint256 played;
        uint256 reverted;
        for (uint256 g = 200_000; g <= 900_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(swapRouter).call{gas: g}(call);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok) {
                assertEq(count(logs, FAILED), 0, "a starved engine played the fallback move");
                if (count(logs, MOVED) == 1) played++;
            } else {
                reverted++;
            }
            vm.revertToState(snap);
        }
        assertGt(played, 0, "enough gas plays the engine's move");
        assertGt(reverted, 0, "too little reverts");
    }

    /// An engine that burns its whole cap: a trade with less gas than the cap reverts (its estimate can't skip the
    /// move), a trade with more gets the fallback move at 0%, so a pathological position costs at most ~5M gas once.
    function test_aGasBurningEngineCostsOneExpensiveTradeNotTheGame() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new GreedyEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        next(12);
        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                pool,
                SwapParams(whiteTeam() == 0, -1e17, whiteTeam() == 0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                bytes("")
            )
        );
        (bool ok, bytes memory err) = address(swapRouter).call{gas: 1_500_000}(call);
        assertFalse(ok, "a normal gas limit reverts");
        assertTrue(err.length > 0);
        vm.recordLogs();
        (ok,) = address(swapRouter).call{gas: 6_000_000}(call);
        assertTrue(ok, "with more than the cap the fallback plays");
        assertEq(count(vm.getRecordedLogs(), FAILED), 1);
        assertEq(st().ply, 1);
        assertEq(st().moveStrength, 0);
    }

    function test_brokenEngineFallsBackToALegalMove() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new BrokenEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        vm.recordLogs();
        playTurn();
        assertEq(count(vm.getRecordedLogs(), FAILED), 1);
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 1, "the game still moved");
        assertEq(g.moveStrength, 0);
        assertEq(g.moveOwner, address(0xA));
    }

    /// If the fallback fails too (an engine bug), trading goes on and the turn stays queued, unplayed and unpaid.
    function test_aDeadEngineLeavesTheTurnQueuedAndTradingGoesOn() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new DeadEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        vm.recordLogs();
        playTurn();
        assertEq(count(vm.getRecordedLogs(), FAILED), 1);
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 0, "nothing played");
        assertTrue(bid().open, "still queued");
        assertEq(bid().owner, address(0xA));
        next(12);
        trade(1 - whiteTeam(), 1e18, address(0)); // and the next trade goes through as well
    }

    // ---------------------------------------------------------------- hostile tokens

    function test_blockedRecipientStaysOwedAndTradingContinues() public {
        BlockToken t = new BlockToken();
        pairWith(t);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        t.block_(address(0xB0B));
        tokenTeamTakesQueenFor(address(0xB0B)); // played and paid: the token refuses 0xB0B
        finalizeWithATinyTrade();
        assertEq(hook.owed(address(0xB0B), token.toId()), 3e18, "kept owed");
        assertEq(hook.chest(id, tokenTeam()), 97e18);
        assertEq(claims(token), hook.chest(id, tokenTeam()) + 3e18 + hook.pile(token.toId()));
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on
    }

    function test_feeOnTransferTokenFundsOnlyWhatArrives() public {
        SkimToken t = new SkimToken(); // no liquidity: the test routers can't settle a fee-on-transfer token
        MockERC20 q = deployHookAside(v5()); // its IMD: every duel needs a route
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        token = Currency.wrap(address(t));
        t.mint(address(this), 1_000e18);
        t.approve(address(hook), type(uint256).max);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        assertEq(hook.chest(id, tokenTeam()), 99e18, "the chest records what arrived");
        assertEq(claims(token), 99e18);
    }

    /// A token whose transferFrom returns nothing (USDT) funds a chest too (swarm audit, engine launch job).
    function test_aTokenReturningNothingFundsAChest() public {
        VoidToken t = new VoidToken();
        MockERC20 q = deployHookAside(v5()); // its IMD: every duel needs a route
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        token = Currency.wrap(address(t));
        t.mint(address(this), 1_000e18);
        t.approve(address(hook), type(uint256).max);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        assertEq(hook.chest(id, tokenTeam()), 100e18);
        assertEq(claims(token), 100e18);
    }

    function test_reenteringTokenCannotBreakAPayout() public {
        ReenterToken t = new ReenterToken();
        pairWith(t);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        // first leave a legitimate reward owed to another owner, so the malicious callback attempts an unlock
        vm.mockCall(
            address(t), abi.encodeWithSignature("transfer(address,uint256)", address(0xCAFE), 3e18), abi.encode(false)
        );
        tokenTeamTakesQueenFor(address(0xCAFE));
        finalizeWithATinyTrade();
        assertEq(hook.owed(address(0xCAFE), token.toId()), 3e18);
        vm.clearMockedCalls();
        t.arm(address(0xB0B), address(hook), abi.encodeCall(IMDuelHook.withdraw, (address(0xCAFE), token)));
        tokenTeamTakesQueenFor(address(0xB0B));
        finalizeWithATinyTrade();
        assertGt(hook.owed(address(0xB0B), token.toId()), 0, "payout failed safely and is owed");
        assertEq(t.balanceOf(address(0xB0B)), 0);
        assertEq(hook.owed(address(0xCAFE), token.toId()), 3e18, "reentrant withdrawal rolled back");
    }

    // ---------------------------------------------------------------- payouts inside the unlock (job f7f2a606, medium)

    /// A move owner that is paid while the PoolManager is unlocked may act on it. One that takes 1 wei of anything and
    /// leaves the debt unsettled would make the whole trade revert after the payout "succeeded", and every later trade
    /// of the duel repeats the same resolve and the same revert, for about a day. The payout must be refused instead:
    /// the reward stays owed, the move is played, trading goes on.
    function debtOwnerIsRefusedAndTradingGoesOn(Currency debtIn) internal {
        DebtOwner r = new DebtOwner(manager, debtIn);
        if (token.isAddressZero()) hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        else hook.fundChest(pool, tokenTeam() == 1, 10e18);
        uint256 chest0 = hook.chest(id, tokenTeam());
        queenForcedOn(address(r)); // the trade that plays and pays: it must not revert
        assertEq(st().ply, 1, "the move is played");
        uint256 bounty = chest0 * 270 / 10_000;
        assertEq(hook.owed(address(r), token.toId()), bounty, "the reward is owed, not pushed");
        assertEq(hook.chest(id, tokenTeam()), chest0 - bounty);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        next(12);
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on, both ways
        next(12);
        trade(1 - tokenTeam(), 1e18, address(0));
        address[] memory who = new address[](1);
        who[0] = address(r);
        assertSolvent(who);
    }

    /// A reward owed to an address that can't receive it (job f7f2a606, low): the owed party sends it where it can.
    function test_anOwnerThatCannotReceiveWithdrawsElsewhere() public {
        pairEth();
        hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        NoReceive r = new NoReceive();
        queenForcedOn(address(r));
        uint256 bounty = 10 ether * 270 / 10_000;
        assertEq(hook.owed(address(r), 0), bounty, "owed: it takes no ETH");
        vm.expectRevert();
        hook.withdraw(address(r), CurrencyLibrary.ADDRESS_ZERO);
        hook.withdrawTo(CurrencyLibrary.ADDRESS_ZERO, address(0xB0B)); // nobody else's call moves it
        assertEq(hook.owed(address(r), 0), bounty);
        r.call(address(hook), abi.encodeCall(IMDuelHook.withdrawTo, (CurrencyLibrary.ADDRESS_ZERO, address(0xB0B))));
        assertEq(address(0xB0B).balance, bounty, "sent where the owner said");
        assertEq(hook.owed(address(r), 0), 0);
        assertSolvent(nobody());
    }

    function test_anEthOwnerLeavingADebtCannotFreezeTheDuel() public {
        pairEth();
        debtOwnerIsRefusedAndTradingGoesOn(pool.currency1);
    }

    function test_aCallbackTokenOwnerLeavingADebtCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        debtOwnerIsRefusedAndTradingGoesOn(pool.currency0 == token ? pool.currency1 : pool.currency0);
    }

    // ---------------------------------------------------------------- settleFor(hook) inside the payout (finding 68f05aa8, medium)

    /// A move owner that is paid while the PoolManager is unlocked and settles 1 wei for the hook in a currency the
    /// hook already holds a nonzero delta in (the fee claims minted in this trade): the delta moves without crossing
    /// zero, so the nonzero-delta count alone would not catch it, and the trade would end with 1 wei unsettled and
    /// revert, as would every later trade of the duel. The payout must be refused: the reward stays owed, the move is
    /// played, trading goes on both ways.
    function settleForOwnerIsRefusedAndTradingGoesOn(Currency settleIn) internal {
        SettleForOwner r = new SettleForOwner(manager, address(hook), settleIn);
        if (settleIn.isAddressZero()) vm.deal(address(r), 1 ether);
        else MockERC20(Currency.unwrap(settleIn)).mint(address(r), 1 ether);
        if (token.isAddressZero()) hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        else hook.fundChest(pool, tokenTeam() == 1, 10e18);
        // the other chest too (bigger), so the trades' chest share is minted in `token`, the smaller chest: the hook's
        // delta there is nonzero while the payout runs, like its delta in the slice currency
        Currency other = pool.currency0 == token ? pool.currency1 : pool.currency0;
        MockERC20(Currency.unwrap(other)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, pool.currency1 == other, 100e18);
        white(1e18, address(r));
        uint256 chest0 = hook.chest(id, tokenTeam());
        next(12);
        black(1e18, address(0)); // plays White's move and pays: it must not revert
        assertEq(st().ply, 1, "the move is played");
        uint256 owedNow = hook.owed(address(r), token.toId());
        assertGt(owedNow, 0, "the reward is owed, not pushed");
        // this trade's chest share (0.4% of its 1e18 input, in `token`) was added before the move was paid
        assertEq(hook.chest(id, tokenTeam()) + owedNow, chest0 + 1e18 * hook.CHEST_BPS() / 10_000, "bounty = owed");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        next(12);
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on, both ways
        next(12);
        trade(1 - tokenTeam(), 1e18, address(0));
        address[] memory who = new address[](1);
        who[0] = address(r);
        assertSolvent(who);
    }

    /// Writes the forced-capture position, as queenForcedOn, without trading.
    function queenForcedPosition() internal {
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "h1", 4);
        b = put(b, "e2", 13);
        b = put(b, "a8", 14);
        b = put(b, "a7", 9);
        hook.setPosition(id, b, side("e1"), side("a8"), 0, 0);
        assertEq(whiteTeam(), tokenTeam(), "the token's team is White in game 0");
    }

    function test_anEthOwnerSettlingForTheHookCannotFreezeTheDuel() public {
        pairEth();
        queenForcedPosition();
        settleForOwnerIsRefusedAndTradingGoesOn(pool.currency0); // ETH: the payout currency, where the hook's delta is nonzero
    }

    function test_anEthOwnerSettlingTheOtherCurrencyForTheHookCannotFreezeTheDuel() public {
        pairEth();
        queenForcedPosition();
        settleForOwnerIsRefusedAndTradingGoesOn(pool.currency1); // the slice currency: nonzero too
    }

    function test_aCallbackTokenOwnerSettlingForTheHookCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        queenForcedPosition();
        settleForOwnerIsRefusedAndTradingGoesOn(token);
    }

    function test_aCallbackTokenOwnerSettlingTheOtherCurrencyForTheHookCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        queenForcedPosition();
        settleForOwnerIsRefusedAndTradingGoesOn(pool.currency0 == token ? pool.currency1 : pool.currency0);
    }

    // ---------------------------------------------------------------- sync(token) inside the payout (finding 28dc1ba6, medium)

    /// A move owner that, paid while the PoolManager is unlocked, only syncs `syncs`: no delta moves, but the token
    /// stays synced, and a router that then settles native ETH with value (as every v4 router does, without a sync
    /// first) reverts NonzeroNativeValue, so the trade that plays the move reverts and every later ETH-paying trade of
    /// the duel with it. The payout must be refused: the reward stays owed, the move is played, trading goes on.
    function syncingOwnerIsRefusedAndTradingGoesOn(Currency syncs) internal {
        SyncingOwner r = new SyncingOwner(manager, syncs);
        if (token.isAddressZero()) hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        else hook.fundChest(pool, tokenTeam() == 1, 10e18);
        // the other chest too (bigger), so the trades' chest share is minted in `token`, the smaller chest
        Currency other = pool.currency0 == token ? pool.currency1 : pool.currency0;
        MockERC20(Currency.unwrap(other)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, pool.currency1 == other, 100e18);
        white(1e18, address(r)); // r bids for White's forced capture
        uint256 chest0 = hook.chest(id, tokenTeam());
        next(12);
        black(1e18, address(0)); // the trade that plays it pays in `token` (native ETH in the ETH duel): it must not revert
        assertEq(st().ply, 1, "the move is played");
        uint256 owedNow = hook.owed(address(r), token.toId());
        assertGt(owedNow, 0, "the reward is owed, not pushed");
        assertEq(hook.chest(id, tokenTeam()) + owedNow, chest0 + 1e18 * hook.CHEST_BPS() / 10_000, "bounty = owed");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(0), "nothing left synced");
        next(12);
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on, both ways
        next(12);
        trade(1 - tokenTeam(), 1e18, address(0));
        address[] memory who = new address[](1);
        who[0] = address(r);
        assertSolvent(who);
        // the owed reward is collected elsewhere, outside any trade
        hook.withdraw(address(r), token);
        assertEq(hook.owed(address(r), token.toId()), 0, "collected");
        if (token.isAddressZero()) assertEq(address(r).balance, owedNow, "collected in ETH");
        else assertEq(MockERC20(Currency.unwrap(token)).balanceOf(address(r)), owedNow, "collected in the token");
    }

    /// The reviewer's case: an ETH / IMD duel, the owner syncs IMD, the ETH-paying trade that plays its move.
    function test_anEthOwnerSyncingTheOtherCurrencyCannotFreezeTheDuel() public {
        pairEth();
        queenForcedPosition();
        syncingOwnerIsRefusedAndTradingGoesOn(pool.currency1);
    }

    function test_aCallbackTokenOwnerSyncingTheTokenCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        queenForcedPosition();
        syncingOwnerIsRefusedAndTradingGoesOn(token);
    }

    function test_aCallbackTokenOwnerSyncingTheOtherCurrencyCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        queenForcedPosition();
        syncingOwnerIsRefusedAndTradingGoesOn(pool.currency0 == token ? pool.currency1 : pool.currency0);
    }

    /// Syncing native ETH when nothing is synced changes nothing the router depends on: that owner is simply paid.
    function test_anEthOwnerSyncingEthWhenNothingIsSyncedIsPaid() public {
        pairEth();
        queenForcedPosition();
        SyncingOwner r = new SyncingOwner(manager, CurrencyLibrary.ADDRESS_ZERO);
        hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        white(1e18, address(r));
        next(12);
        black(1e18, address(0));
        assertEq(st().ply, 1, "the move is played");
        assertGt(address(r).balance, 0, "paid inside the trade");
        assertEq(hook.owed(address(r), 0), 0, "nothing owed");
    }
}
