// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

/// A move owner paid in ETH while the PoolManager is unlocked. What its receive() does is set per test:
/// 0 nothing, 1 only reads the PoolManager's transient state, 2 syncs a token (no delta), 3 settles `amount` wei of
/// ETH for `target`. It can call anything, so it can withdraw its owed rewards elsewhere.
contract ProbeOwner {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable manager;
    uint8 public mode;
    address public target;
    uint256 public amount;
    Currency public syncIn;
    uint256 public seen; // what mode 1 read, so the read is not optimised away

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function set(uint8 mode_, address target_, uint256 amount_, Currency syncIn_) external {
        (mode, target, amount, syncIn) = (mode_, target_, amount_, syncIn_);
    }

    receive() external payable {
        if (mode == 1) {
            seen = manager.getNonzeroDeltaCount() ^ uint256(manager.currencyDelta(target, CurrencyLibrary.ADDRESS_ZERO));
        } else if (mode == 2) {
            manager.sync(syncIn);
        } else if (mode == 3) {
            manager.sync(CurrencyLibrary.ADDRESS_ZERO);
            manager.settleFor{value: amount}(target);
        }
    }

    function call(address to, bytes calldata data) external {
        (bool ok, bytes memory err) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 32), mload(err))
            }
        }
    }
}

/// The payout guard (payOut): a reward paid inside the trade that plays its move is refused, and left owed, exactly
/// when the recipient touches the PoolManager's deltas; a recipient that does not is paid at once. Native ETH / IMD
/// duel, the forced queen capture of the Hostile suite: ETH's team (White in game 0) must play Kxe2.
contract PayoutGuardTest is Base {
    using CurrencyLibrary for Currency;

    Currency constant ETH = CurrencyLibrary.ADDRESS_ZERO;
    ProbeOwner r;
    MockERC20 q; // the hook's IMD, the duel's other side

    function setUp() public {
        deployV4();
        q = deployHookAside(v5());
        q.mint(address(this), 1e30);
        q.approve(address(swapRouter), type(uint256).max);
        q.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 1e30);
        (pool, id) = initPool(ETH, Currency.wrap(address(q)), IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1e27}(pool, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        r = new ProbeOwner(manager);
        vm.deal(address(r), 1 ether);

        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "h1", 4);
        b = put(b, "e2", 13);
        b = put(b, "a8", 14);
        b = put(b, "a7", 9);
        hook.setPosition(id, b, side("e1"), side("a8"), 0, 0);
        assertEq(whiteTeam(), 0, "ETH's team is White in game 0");
    }

    /// `r` bids for the forced capture; the next block's trade plays it and pays (or owes) its bounty. Returns the
    /// amount and whether it was paid, from the trade's one Reward event.
    function playForR() internal returns (uint256 amount, bool paid) {
        white(1e18, address(r));
        next(12);
        vm.recordLogs();
        black(1e18, address(0)); // plays White's move: it must not revert, whatever r does
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == REWARD) {
                address to;
                Currency c;
                (,, to, c, amount, paid) = abi.decode(logs[i].data, (uint32, uint16, address, Currency, uint256, bool));
                assertEq(to, address(r), "the bounty is r's");
                assertTrue(c == ETH, "paid in ETH");
                n++;
            }
        }
        assertEq(n, 1, "one reward");
        assertEq(st().ply, 1, "the move is played");
        assertGt(amount, 0);
    }

    function who() internal view returns (address[] memory w) {
        w = new address[](1);
        w[0] = address(r);
    }

    /// Trading goes on both ways after the payout, and the books balance.
    function tradingGoesOn() internal {
        next(12);
        trade(0, 1e18, address(0));
        next(12);
        trade(1, 1e18, address(0));
        assertSolvent(who());
    }

    // ---------------------------------------------------------------- recipients the guard must not refuse

    function test_aPlainRecipientIsPaidInTheTrade() public {
        uint256 before = address(r).balance;
        (uint256 amount, bool paid) = playForR();
        assertTrue(paid, "paid");
        assertEq(address(r).balance, before + amount);
        assertEq(hook.owed(address(r), ETH.toId()), 0);
        tradingGoesOn();
    }

    /// Reading the PoolManager's deltas is not touching them.
    function test_aRecipientThatOnlyReadsDeltasIsPaid() public {
        r.set(1, address(hook), 0, ETH);
        uint256 before = address(r).balance;
        (uint256 amount, bool paid) = playForR();
        assertTrue(paid, "a read is not refused");
        assertEq(address(r).balance, before + amount);
        assertEq(hook.owed(address(r), ETH.toId()), 0);
        tradingGoesOn();
    }

    /// A recipient that syncs a token, paid inside a trade that pays in that token (the router syncs again before it
    /// settles): the move is played, the reward is paid or owed, never lost, and trading goes on. The same recipient
    /// paid inside a trade that pays in native ETH makes that trade revert (NonzeroNativeValue): reported in
    /// .imd-findings.json, not asserted here.
    function test_aRecipientThatSyncsIsSettledAroundWhenTheTradePaysInTheToken() public {
        r.set(2, address(0), 0, Currency.wrap(address(q)));
        uint256 before = address(r).balance;
        white(1e18, address(r));
        next(12);
        trade(0, 1e18, address(0)); // q in, ETH out: plays White's move
        assertEq(st().ply, 1, "the move is played");
        uint256 got = address(r).balance - before + hook.owed(address(r), ETH.toId());
        assertGt(got, 0, "the bounty is r's, paid or owed");
        tradingGoesOn();
    }

    // ---------------------------------------------------------------- recipients the guard must refuse

    /// Settling for the trade's router opens a delta (the router's is zero while afterSwap runs): refused, owed,
    /// nothing reaches the router, and the trade settles.
    function test_aRecipientSettlingForTheRouterIsRefused() public {
        r.set(3, address(swapRouter), 1, ETH);
        uint256 before = address(r).balance;
        (uint256 amount, bool paid) = playForR();
        assertFalse(paid, "refused");
        assertEq(hook.owed(address(r), ETH.toId()), amount, "left owed");
        assertEq(address(r).balance, before, "neither paid nor charged: the refused call is rolled back");
        tradingGoesOn();
    }

    /// Any amount settled for the hook in the payout currency moves the hook's own nonzero delta without crossing
    /// zero (the nonzero-delta count stays the same): still refused, and the trade still settles.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_settlingAnyAmountForTheHookIsRefused(uint256 amount) public {
        amount = bound(amount, 1, 0.5 ether);
        r.set(3, address(hook), amount, ETH);
        uint256 before = address(r).balance;
        (uint256 bounty, bool paid) = playForR();
        assertFalse(paid, "refused");
        assertEq(hook.owed(address(r), ETH.toId()), bounty, "left owed");
        assertEq(address(r).balance, before, "rolled back");
        tradingGoesOn();
    }

    // ---------------------------------------------------------------- what is owed only ever reaches its owner

    /// The owed reward of a recipient that keeps touching deltas: withdraw (anyone's call, to the owner) fails in
    /// its own unlock and keeps it owed; another caller's withdrawTo moves nothing; the owner's withdrawTo collects
    /// it elsewhere, exactly once.
    function test_aRefusedRewardLeavesOnlyThroughItsOwnersWithdrawTo() public {
        r.set(3, address(hook), 1, ETH);
        (uint256 bounty, bool paid) = playForR();
        assertFalse(paid);

        vm.expectRevert(); // the hook's own unlock ends 1 wei in credit: CurrencyNotSettled
        hook.withdraw(address(r), ETH);
        assertEq(hook.owed(address(r), ETH.toId()), bounty, "still owed");

        address elsewhere = makeAddr("elsewhere");
        vm.prank(makeAddr("stranger"));
        hook.withdrawTo(ETH, elsewhere); // the stranger is owed nothing: nothing moves
        assertEq(elsewhere.balance, 0);
        assertEq(hook.owed(address(r), ETH.toId()), bounty);

        r.call(address(hook), abi.encodeCall(IMDuelHook.withdrawTo, (ETH, elsewhere)));
        assertEq(elsewhere.balance, bounty, "collected elsewhere");
        assertEq(hook.owed(address(r), ETH.toId()), 0);
        r.call(address(hook), abi.encodeCall(IMDuelHook.withdrawTo, (ETH, elsewhere)));
        assertEq(elsewhere.balance, bounty, "only once");
        assertSolvent(who());
    }

    /// Once the owner stops touching deltas, anyone's withdraw delivers its reward to it, and to nobody else.
    function test_anOwedRewardIsDeliveredByAnyonesWithdrawOnceTheOwnerAccepts() public {
        r.set(3, address(swapRouter), 1, ETH);
        (uint256 bounty, bool paid) = playForR();
        assertFalse(paid);
        r.set(0, address(0), 0, ETH);
        uint256 before = address(r).balance;
        vm.prank(makeAddr("stranger"));
        hook.withdraw(address(r), ETH);
        assertEq(address(r).balance, before + bounty);
        assertEq(hook.owed(address(r), ETH.toId()), 0);
        hook.withdraw(address(r), ETH); // nothing left: a no-op
        assertEq(address(r).balance, before + bounty);
        assertSolvent(who());
    }
}
