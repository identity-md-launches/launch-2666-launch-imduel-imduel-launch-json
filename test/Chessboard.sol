// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Chess} from "../src/Chess.sol";
import {Rules} from "../src/Rules.sol";

/// The rules as a contract, for tests that replay games.
contract RulesHarness {
    function move(uint256 board, uint32 mover, uint32 other, bool black, uint16 m)
        external
        pure
        returns (Rules.Played memory)
    {
        return Rules.move(board, mover, other, black, m);
    }
}

/// Board helpers shared by every test: squares by name, positions, replays of the recorded games, mirrored colours.
/// Encoding in src/Chess.sol (a1 = square 0; 1 pawn 2 bishop 3 knight 4 rook 5 queen 6 king, +8 black).
abstract contract Chessboard is Test {
    // Loaded separately built when a replay first needs it: embedding its creation code in each suite makes clean IR
    // builds costly, and the cheatcode is Foundry's (Echidna and Medusa never replay).
    RulesHarness rules;

    function _rules() internal returns (RulesHarness) {
        if (address(rules) == address(0)) rules = RulesHarness(vm.deployCode("Chessboard.sol:RulesHarness"));
        return rules;
    }

    function sq(string memory s) internal pure returns (uint16) {
        bytes memory b = bytes(s);
        return uint16(uint8(b[0]) - 97) + 8 * uint16(uint8(b[1]) - 49);
    }

    function put(uint256 board, string memory s, uint256 piece) internal pure returns (uint256) {
        return board | (piece << (uint256(sq(s)) << 2));
    }

    function mv(string memory from, string memory to) internal pure returns (uint16) {
        return (sq(from) << 6) | sq(to);
    }

    /// Side state with the king on `k`, castling gone, no en passant.
    function side(string memory k) internal pure returns (uint32) {
        return 0x80800000 | (uint32(sq(k)) << 8) | 0xff;
    }

    /// The same position with colours swapped (ranks mirrored); the states are for kings without castling rights.
    function mirror(uint256 b, uint32 w, uint32 k) internal pure returns (uint256 m, uint32 nw, uint32 nk) {
        for (uint256 s; s < 64; s++) {
            uint256 piece = (b >> (s * 4)) & 15;
            if (piece != 0) m |= (piece ^ 8) << ((s ^ 56) * 4);
        }
        nw = 0x808000ff | (uint32((k >> 8) & 63) ^ 56) << 8;
        nk = 0x808000ff | (uint32((w >> 8) & 63) ^ 56) << 8;
    }

    /// Plays `move` for the side to move and returns the new position.
    function step(uint256 b, uint32 w, uint32 k, bool black, uint16 move)
        internal
        returns (uint256, uint32, uint32, Rules.Played memory p)
    {
        p = _rules().move(b, black ? k : w, black ? w : k, black, move);
        (uint32 nw, uint32 nk) = black ? (p.other, p.mover) : (p.mover, p.other);
        return (p.board, nw, nk, p);
    }

    /// The position after the first `n` moves of recorded game `game` (test/data/chess.json).
    function replay(uint256 game, uint256 n) internal returns (uint256 b, uint32 w, uint32 k) {
        uint256[] memory moves = gameMoves(game);
        (b, w, k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        for (uint256 i; i < n; i++) (b, w, k,) = step(b, w, k, i % 2 == 1, uint16(moves[i]));
    }

    function gameMoves(uint256 game) internal view returns (uint256[] memory) {
        return vm.parseJsonUintArray(vm.readFile("./test/data/chess.json"), string.concat(".games[", vm.toString(game), "]"));
    }
}
