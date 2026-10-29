// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// IMDuel's token, $IMDUEL, on the IMD launch's standard terms: 1,000,000,000 fixed, 18 decimals, minted whole to
/// the launch factory (the deployer), which seeds the main duel and hands out the rest. Plain transfers and
/// allowances; no owner, mint, burn, tax, pause or blocklist. Built like every live hook launch's token (2504's).
contract IMDuelToken {
    string public constant name = "IMDuel";
    string public constant symbol = "IMDUEL";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;

    mapping(address account => uint256) public balanceOf;
    mapping(address account => mapping(address spender => uint256)) public allowance;

    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed account, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = approved - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - value;
            balanceOf[to] += value; // every balance is bounded by the fixed supply, self transfers included
        }
        emit Transfer(from, to, value);
    }
}
