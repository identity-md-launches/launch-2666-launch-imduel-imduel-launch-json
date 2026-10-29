// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Test-only RLP and single-leaf state tries. Tests install the resulting header hash with vm.setBlockhash;
/// production callers must provide a canonical header and real eth_getProof nodes instead.
library RouteProof {
    struct Proof {
        bytes header;
        bytes[] account;
        bytes[] storageNodes;
    }

    function scalar(uint256 value) internal pure returns (bytes memory) {
        uint256 n;
        for (uint256 v = value; v != 0; v >>= 8) {
            n++;
        }
        bytes memory result = new bytes(n);
        for (uint256 i; i < n; i++) {
            result[n - i - 1] = bytes1(uint8(value >> (i * 8)));
        }
        return result;
    }

    function prefix(uint256 n, uint8 offset) internal pure returns (bytes memory) {
        if (n < 56) return abi.encodePacked(bytes1(offset + uint8(n)));
        bytes memory length = scalar(n);
        return bytes.concat(bytes1(offset + 55 + uint8(length.length)), length);
    }

    function data(bytes memory value) internal pure returns (bytes memory) {
        if (value.length == 1 && uint8(value[0]) < 128) return value;
        return bytes.concat(prefix(value.length, 128), value);
    }

    function list(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(prefix(payload.length, 192), payload);
    }

    function leaf(bytes32 key, bytes memory value) internal pure returns (bytes memory) {
        return list(bytes.concat(data(abi.encodePacked(bytes1(0x20), key)), data(value)));
    }

    function build(address manager, bytes32 slot, uint256 slotValue, uint256 number)
        internal
        view
        returns (Proof memory p)
    {
        p.storageNodes = new bytes[](1);
        p.storageNodes[0] = leaf(keccak256(abi.encode(slot)), data(scalar(slotValue)));
        bytes memory account = list(
            bytes.concat(
                hex"8080",
                data(abi.encodePacked(keccak256(p.storageNodes[0]))),
                data(abi.encodePacked(manager.codehash))
            )
        );
        p.account = new bytes[](1);
        p.account[0] = leaf(keccak256(abi.encodePacked(manager)), account);
        bytes memory fields;
        for (uint256 i; i < 15; i++) {
            bytes memory value;
            if (i == 3) value = abi.encodePacked(keccak256(p.account[0]));
            else if (i == 8) value = scalar(number);
            fields = bytes.concat(fields, data(value));
        }
        p.header = list(fields);
    }
}
