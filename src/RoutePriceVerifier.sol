// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RLPReader} from "./proof/RLPReader.sol";
import {MerkleTrie} from "./proof/MerkleTrie.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// Authenticates a hookless pool's slot0 at a past block boundary using eth_getProof and a block header.
/// Deployed by the hook's constructor; no owner, mutable configuration, signer or initialization call.
contract RoutePriceVerifier {
    error InvalidProof();

    /// The end state of block N is the start state of N+1. Only completed start blocks are accepted:
    /// the batch's own block can never contribute a sample. Headers must still be served by BLOCKHASH.
    function verify(
        address manager,
        bytes32 slot,
        bytes calldata header,
        bytes[] calldata accountProof,
        bytes[] calldata storageProof
    ) external view returns (uint256 sampleBlock, uint160 sqrtPriceX96) {
        RLPReader.RLPItem[] memory fields = RLPReader.readList(header);
        if (fields.length < 15) revert InvalidProof();
        uint256 number = _uint(RLPReader.readBytes(fields[8]));
        if (block.number < 2 || number >= block.number - 1) revert InvalidProof();
        bytes32 canonical = blockhash(number);
        if (canonical == bytes32(0) || canonical != keccak256(header)) revert InvalidProof();
        bytes memory stateRoot = RLPReader.readBytes(fields[3]);
        if (stateRoot.length != 32) revert InvalidProof();
        bytes memory account =
            MerkleTrie.get(abi.encodePacked(keccak256(abi.encodePacked(manager))), accountProof, bytes32(stateRoot));
        RLPReader.RLPItem[] memory accountFields = RLPReader.readList(account);
        if (accountFields.length != 4) revert InvalidProof();
        bytes memory storageRoot = RLPReader.readBytes(accountFields[2]);
        if (storageRoot.length != 32) revert InvalidProof();
        bytes memory encoded =
            MerkleTrie.get(abi.encodePacked(keccak256(abi.encode(slot))), storageProof, bytes32(storageRoot));
        uint256 slot0 = _uint(RLPReader.readBytes(encoded));
        sqrtPriceX96 = uint160(slot0);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert InvalidProof();
        sampleBlock = number + 1;
    }

    function _uint(bytes memory value) private pure returns (uint256 result) {
        if (value.length > 32 || (value.length != 0 && value[0] == 0)) revert InvalidProof();
        for (uint256 i; i < value.length; i++) {
            result = (result << 8) | uint8(value[i]);
        }
    }
}
