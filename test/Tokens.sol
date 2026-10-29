// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// Refuses transfers to blocked addresses (like a token with a blocklist).
contract BlockToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Block", "BLK", 18) {}

    function block_(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transferFrom(from, to, amount);
    }
}

/// Burns 1% of every transfer (a fee-on-transfer token).
contract SkimToken is MockERC20 {
    constructor() MockERC20("Skim", "SKM", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 cut = amount / 100;
        super.transferFrom(from, to, amount - cut);
        _burn(from, cut);
        return true;
    }
}

/// On a transfer to `target`, calls back into `callee` with `data` and fails if that fails (a re-entering token).
contract ReenterToken is MockERC20 {
    address public target;
    address public callee;
    bytes public data;

    constructor() MockERC20("Reenter", "RNT", 18) {}

    function arm(address target_, address callee_, bytes calldata data_) external {
        (target, callee, data) = (target_, callee_, data_);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == target && callee != address(0)) {
            (bool ok,) = callee.call(data);
            require(ok, "callback failed");
        }
        return super.transfer(to, amount);
    }
}

/// transfer and transferFrom return nothing (like USDT).
contract VoidToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface ITransferSink {
    function onTransfer() external;
}

/// Tells a contract recipient about every transfer to it (like an ERC-777 or ERC-1363 token): the recipient acts
/// inside the transfer.
contract CallbackToken is MockERC20 {
    constructor() MockERC20("Callback", "CBK", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to.code.length != 0) {
            try ITransferSink(to).onTransfer() {} catch {}
        }
        return ok;
    }
}

/// A move owner that, paid while the PoolManager is unlocked (inside the trade that plays its move), takes 1 wei of
/// `c` from the PoolManager and leaves that debt unsettled. Unless the hook refuses the payout, the trade ends with a
/// nonzero delta count and reverts (CurrencyNotSettled), and so does every later trade that plays the same move.
contract DebtOwner is ITransferSink {
    IPoolManager immutable manager;
    Currency immutable c;

    constructor(IPoolManager manager_, Currency c_) {
        (manager, c) = (manager_, c_);
    }

    receive() external payable {
        _debt();
    }

    function onTransfer() external {
        _debt();
    }

    function _debt() internal {
        manager.take(c, address(this), 1);
    }
}

/// A move owner that, paid while the PoolManager is unlocked, settles 1 wei of `c` for the hook (sync, pay, settleFor).
/// The hook already holds a nonzero delta in `c` during the trade (the fee claims it minted), so the delta moves
/// without crossing zero and the nonzero-delta count is unchanged. Unless the hook sees its own delta move, the
/// payout "succeeds", the PoolManager then credits the hook 1 wei too many, and the trade reverts at the end of its
/// unlock (CurrencyNotSettled), and so does every later trade that plays the same move.
contract SettleForOwner is ITransferSink {
    IPoolManager immutable manager;
    address immutable hook;
    Currency immutable c;

    constructor(IPoolManager manager_, address hook_, Currency c_) {
        (manager, hook, c) = (manager_, hook_, c_);
    }

    receive() external payable {
        _settle();
    }

    function onTransfer() external {
        _settle();
    }

    function _settle() internal {
        manager.sync(c);
        if (Currency.unwrap(c) == address(0)) {
            manager.settleFor{value: 1}(hook);
        } else {
            MockERC20(Currency.unwrap(c)).transfer(address(manager), 1);
            manager.settleFor(hook);
        }
    }
}

/// A move owner that, paid while the PoolManager is unlocked, only calls manager.sync(c): no delta moves, so the delta
/// checks alone accept the payout, but `c` stays synced for the rest of the unlock. The trader's router then settles
/// its input without syncing first when it pays native ETH (settle{value}: NonzeroNativeValue), so the trade that
/// plays the move reverts, and so does every later ETH-paying trade of the duel. The payout must be refused instead.
contract SyncingOwner is ITransferSink {
    IPoolManager immutable manager;
    Currency immutable c;

    constructor(IPoolManager manager_, Currency c_) {
        (manager, c) = (manager_, c_);
    }

    receive() external payable {
        manager.sync(c);
    }

    function onTransfer() external {
        manager.sync(c);
    }
}

/// Takes no ETH, ever; can call anything (to withdraw its reward elsewhere).
contract NoReceive {
    function call(address target, bytes calldata data) external {
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 32), mload(err))
            }
        }
    }
}
