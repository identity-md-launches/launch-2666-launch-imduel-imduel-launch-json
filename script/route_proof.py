#!/usr/bin/env python3
"""Fetch a route-price proof and print sampleRoute calldata. Read-only: never signs or sends a transaction."""

import argparse
import json
import subprocess
import urllib.request
from pathlib import Path


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def rpc(url, method, params):
    request = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(f"{method}: {result['error']}")
    return result["result"]


def word(value):
    return int(value, 0).to_bytes(32, "big") if isinstance(value, str) else value.to_bytes(32, "big")


def route_slot(manifest):
    args = manifest["hook"]["constructorArgs"]
    pool_key = word(0) + word(args[2]) + word(args[3]) + word(args[4]) + word(0)
    pool_id = bytes.fromhex(cast("keccak", "0x" + pool_key.hex())[2:])
    # v4-core StateLibrary.POOLS_SLOT = 6; slot0 is the first word of Pool.State.
    return cast("keccak", "0x" + (pool_id + word(6)).hex())


def rlp(value):
    if isinstance(value, list):
        payload = b"".join(rlp(v) for v in value)
        offset = 192
    else:
        payload = value
        offset = 128
        if len(payload) == 1 and payload[0] < 128:
            return payload
    if len(payload) < 56:
        return bytes([offset + len(payload)]) + payload
    length = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(length)]) + length + payload


def encode_header(block):
    fields = [
        "parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot", "receiptsRoot",
        "logsBloom", "difficulty", "number", "gasLimit", "gasUsed", "timestamp", "extraData",
        "mixHash", "nonce",
    ]
    optional = ["baseFeePerGas", "withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash"]
    integers = {"difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas", "blobGasUsed", "excessBlobGas"}
    values = []
    for name in fields + [name for name in optional if block.get(name) is not None]:
        value = block[name]
        if name in integers:
            integer = int(value, 16)
            values.append(integer.to_bytes((integer.bit_length() + 7) // 8, "big"))
        else:
            values.append(bytes.fromhex(value[2:]))
    encoded = "0x" + rlp(values).hex()
    if cast("keccak", encoded).lower() != block["hash"].lower():
        raise ValueError("Header hash mismatch: unsupported header format or inconsistent RPC response")
    return encoded


def fetch_proof(url, manager, slot, number):
    tag = hex(number)
    block = rpc(url, "eth_getBlockByNumber", [tag, False])
    header = encode_header(block)
    result = rpc(url, "eth_getProof", [manager, [slot], tag])
    # A reorganization between the two reads would otherwise yield an unusable proof.
    if rpc(url, "eth_getBlockByNumber", [tag, False])["hash"] != block["hash"]:
        raise ValueError("Block changed while fetching proof; retry")
    storage = result["storageProof"][0]
    if int(storage["key"], 16) != int(slot, 16):
        raise ValueError("RPC returned a different storage slot")
    return {
        "manager": manager,
        "slot": slot,
        "blockNumber": number,
        "headerHash": block["hash"],
        "header": header,
        "value": storage["value"],
        "accountProof": result["accountProof"],
        "storageProof": storage["proof"],
    }


def calldata(proof):
    return cast(
        "calldata", "sampleRoute(bytes,bytes[],bytes[])", proof["header"],
        "[" + ",".join(proof["accountProof"]) + "]",
        "[" + ",".join(proof["storageProof"]) + "]",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--hook", required=True)
    parser.add_argument("--manifest", type=Path, default=Path("launch.json"))
    parser.add_argument("--block", type=int, help="Proof state block; defaults to latest minus one")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if int(manifest["hook"]["constructorArgs"][3]) == 0:
        raise ValueError("This launch has no hookless ETH route")
    manager_word = rpc(args.rpc_url, "eth_call", [{"to": args.hook, "data": cast("calldata", "manager()")}, "latest"])
    if len(manager_word) != 66:
        raise ValueError("The hook did not return a manager address")
    manager = "0x" + manager_word[-40:]
    latest = int(rpc(args.rpc_url, "eth_blockNumber", []), 16)
    number = latest - 1 if args.block is None else args.block
    if number < 0 or number >= latest or latest - number > 255:
        raise ValueError("Choose a completed state block before latest, still within the next block's BLOCKHASH window")
    proof = fetch_proof(args.rpc_url, manager, route_slot(manifest), number)
    print(json.dumps({
        "to": args.hook, "data": calldata(proof), "proofBlock": number,
        "sampleBlock": number + 1, "conversionBlock": number + 2,
        "note": "Submit in conversionBlock; three consecutive authenticated samples are required. No transaction was sent.",
    }, indent=2))


if __name__ == "__main__":
    main()
