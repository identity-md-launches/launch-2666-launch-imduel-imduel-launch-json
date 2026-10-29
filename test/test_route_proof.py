"""Offline checks for the read-only proof/calldata helper (python3 -m unittest discover -s test -p 'test_*.py')."""

import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("route_proof", ROOT / "script/route_proof.py")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class RouteProofScriptTest(unittest.TestCase):
    def test_standard_rlp_vectors(self):
        for value, encoded in [
            (b"", "80"), (b"dog", "83646f67"),
            ([b"cat", b"dog"], "c88363617483646f67"),
            ([], "c0"), (b"\x00", "00"), (b"\x80", "8180"),
        ]:
            self.assertEqual(HELPER.rlp(value).hex(), encoded)
        self.assertEqual(HELPER.rlp(b"a" * 56)[:2], bytes.fromhex("b838"))

    def test_route_slot_matches_client_fixture(self):
        manifest = json.loads((ROOT / "launch.json").read_text())
        fixture = json.loads((ROOT / "test/data/route-proof.json").read_text())
        self.assertEqual(HELPER.route_slot(manifest).lower(), fixture["slot"].lower())

    def test_calldata_encodes_the_fixture(self):
        fixture = json.loads((ROOT / "test/data/route-proof.json").read_text())
        data = HELPER.calldata(fixture)
        decoded = HELPER.cast("calldata-decode", "sampleRoute(bytes,bytes[],bytes[])", data)
        self.assertIn(fixture["header"].lower(), decoded.lower())
        for node in fixture["accountProof"] + fixture["storageProof"]:
            self.assertIn(node.lower(), decoded.lower())

    def test_fetch_rejects_a_reorganization(self):
        fixture = json.loads((ROOT / "test/data/route-proof.json").read_text())
        proof = {"storageProof": [{"key": fixture["slot"]}]}
        with patch.object(HELPER, "rpc", side_effect=[{"hash": "first"}, proof, {"hash": "second"}]), \
                patch.object(HELPER, "encode_header", return_value=fixture["header"]):
            with self.assertRaisesRegex(ValueError, "Block changed"):
                HELPER.fetch_proof("unused", fixture["manager"], fixture["slot"], fixture["blockNumber"])

    def test_cli_only_reads_rpc_and_prints_call_data(self):
        fixture = json.loads((ROOT / "test/data/route-proof.json").read_text())
        block = {"hash": fixture["headerHash"]}
        response = {
            "accountProof": fixture["accountProof"],
            "storageProof": [{"key": fixture["slot"], "value": fixture["value"], "proof": fixture["storageProof"]}],
        }
        answers = ["0x" + HELPER.word(fixture["manager"]).hex(), hex(fixture["blockNumber"] + 1), block, response, block]
        arguments = ["route_proof.py", "--rpc-url", "unused", "--hook", fixture["manager"],
                     "--manifest", str(ROOT / "launch.json")]
        output = io.StringIO()
        with patch("sys.argv", arguments), patch("sys.stdout", output), \
                patch.object(HELPER, "rpc", side_effect=answers) as requests, \
                patch.object(HELPER, "encode_header", return_value=fixture["header"]):
            HELPER.main()
        result = json.loads(output.getvalue())
        self.assertEqual(result["data"], HELPER.calldata(fixture))
        self.assertEqual(result["sampleBlock"], fixture["blockNumber"] + 1)
        self.assertEqual(result["conversionBlock"], fixture["blockNumber"] + 2)
        self.assertEqual([call.args[1] for call in requests.call_args_list], [
            "eth_call", "eth_blockNumber", "eth_getBlockByNumber", "eth_getProof", "eth_getBlockByNumber",
        ])


if __name__ == "__main__":
    unittest.main()
