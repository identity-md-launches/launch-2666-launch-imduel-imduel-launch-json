# IMDuel launch adaptation

The project already satisfied the factory's constructor and token requirements. Changes address the two reproduced imported audit findings. `launch.json`, its nine constructor values, all five hook permissions, `foundry.toml`, existing dependencies, `src/IMDuelToken.sol`, and all chess/engine sources are unchanged. The engine remains `0xc21788f704a8b9456f7391a01d8a3d95be215a27`; its code is not required during construction. The hookless route retains fee 10000 and spacing 200; the launch pool retains fee 12500 and spacing 60.

## Reproduced findings and changes

### Route-price manipulation — a878ce8b005159b1bc6c83a593cda89fe9baf9ebc3b78e9d2b07466cafbc3855

Reproduced against the original production hook in `test/RouteSample.t.sol`: a 10-ETH-deep hookless route, a 1-ETH protocol pile, and four successive transactions that push the route to approximately 0.7 times its honest square-root price, call `convert`, and restore the honest price before the block ends. The attacker supplies a narrow liquidity band at the pushed price. The original implementation earned the attacker **0.421859774673804280 ETH-equivalent**, despite an honest price at every block boundary. After the fix the same attempt loses **0.087002115995172580 ETH-equivalent**, and the ETH pile remains intact.

Changes:

- `src/IMDuelHook.sol`: route conversions no longer record live route prices. New permissionless `sampleRoute(bytes,bytes[],bytes[])` authenticates historical block-start prices. Samples must increase in block number; duplicates and older samples revert. A gap clears the price window. Conversion requires three consecutive samples, the newest from the preceding block's start. Missing or stale proofs leave the ETH owed as claims and do not stop ordinary trading. Main-duel sampling is unchanged. The existing 0.1% square-root-price band, most favourable of three prices, batch-size cap and one-batch-per-block limits remain in force.
- `src/RoutePriceVerifier.sol`: verifies a canonical RLP block header against `BLOCKHASH`, the PoolManager account proof against its state root, and the route's slot0 proof against that account's storage root. End state of block N proves the price at the start of N+1. The sample cannot come from the conversion's own block. Proofs bind to the constructor-supplied manager and the exact configured hookless route. Uninitialized/out-of-range prices are rejected.
- The hook creates the stateless verifier in its constructor and exposes `routePriceVerifier()`. The verifier needs no initialization, owner, signer, external library linking or additional manifest argument. Neither constructor reads the engine or any deployed dependency.
- `src/proof/{MerkleTrie,RLPReader,RLPErrors,Bytes}.sol`, `LICENSE`, and `PROVENANCE.md`: ordinary vendored source files from Optimism commit `1ee89a21d9304d4cfea6e39ab407e3b689f115b9`. Only imports were made relative. These provide the proof machinery without changing the existing dependency tree or compiler settings.

A one-block delay on caller-selected spot samples would still allow an attacker to poison three samples and consume them later. Authenticating past state preserves the requested block-start guarantee while retaining the configured hookless ETH route. This is why the fix needs proof verification rather than just a delay.

### Relayer-owned bids — 3a0e9840e957b5de7edc54783807bdcdd65124200d7f681d805bd7c83f5b9d25

Reproduced with a funded contract wallet swapping through the router in a transaction whose origin is a different bundler. Both empty hook data and a 32-byte ABI-encoded wallet address assigned the original bid to the bundler.

`src/IMDuelHook.sol` now accepts either a packed 20-byte recipient or a canonical 32-byte ABI-encoded address. Otherwise the PoolManager's swap `sender` owns the bid. No ownership is inferred from `tx.origin`. Dirty ABI padding falls back to the sender without breaking the swap. Existing explicit packed recipients retain their behaviour. Ownership also participates in the engine seed, so changing the fallback owner can change those trades' moves.

Integrations should forward the intended recipient explicitly. The fallback sender is usually a router, and its ability to receive or withdraw rewards depends on that router. Failed payouts still remain in `owed`; only the owed party can redirect them with `withdrawTo`. Explicit zero recipient data continues to opt out of a reward, as the original packed format did.

### Coverage statement — d904224868d620602d31eef745d1628996d7e50fa93601bee28b32a934791012

This is informational, not a defect to reproduce or fix. Neither actionable finding was dismissed. This adaptation does not claim a fresh full audit of the unchanged chess engine, move generation or repetition logic.

## Route-proof operation

Main IMD/IMDUEL trading and IMD conversion require no proof publisher. ETH conversion additionally requires permissionless publication of route proofs. There is no trusted signer or privileged publisher; anyone can provide valid proofs. If nobody provides them, ETH conversions wait safely in the pile.

`script/route_proof.py` reads the committed manifest, reads `manager()` from the deployed hook, fetches a header and `eth_getProof`, checks header reconstruction, and prints `sampleRoute` calldata. It uses Python's standard library and the existing Foundry `cast` binary. It never reads a private key, signs, or sends a transaction.

```sh
python3 script/route_proof.py --rpc-url <RPC_URL> --hook <DEPLOYED_HOOK>
```

At head B the default proof uses state block B-1, proving start block B; submit it in B+1, when it can support a conversion. Publish in increasing sample-block order. Three consecutive samples bootstrap the window. A caller capable of bundling calls may also supply the three historical proofs in one transaction. `--block` selects a particular proof-state block for this purpose. `RouteSampled` records accepted samples. Headers must remain available through the 256-block `BLOCKHASH` window. A delayed submission may be accepted but cannot enable a conversion until the newest sample is fresh again.

The committed manifest's explanatory note that each ETH batch samples the route is superseded by this audit fix; the manifest itself is preserved as requested. No contract prices the route from that unverified spot observation anymore.

## Tests and supporting files

- `test/RouteSample.t.sol`: production-hook attack reproduction, rejection with authenticated history, honest conversion and burn, price-band enforcement, claims accounting, per-block limit, stale/gapped history and duplicate samples.
- `test/RoutePriceVerifier.t.sol`, `test/RouteProof.sol`, `test/data/route-proof.json`: proof round trips with fuzzed slot0 values; tampered headers/account/storage proofs; wrong manager/pool; missing/extra nodes; expired/current-block samples; invalid prices. The committed fixture is an actual `eth_getProof` response for a PoolManager initialized on an isolated Anvil chain, including branch nodes. Tests require no RPC, FFI or downloads.
- `test/BidOwner.t.sol`: contract-wallet/bundler reproductions, both recipient encodings, malformed data fuzzing, and real capture-bounty payouts to the intended recipient or fallback sender.
- `test/Base.sol`, `test/Slice.t.sol`: ETH conversion fixtures now provide authenticated samples. Existing conversion and inherited cross-block tests retain their economic assertions.
- `test/Game.t.sol`, `test/Launch.t.sol`, `test/Money.t.sol`, `test/Invariant.t.sol`, `test/InvariantDuels.t.sol`: replace the old origin-owner expectation and include the fallback router in owed-balance accounting. The native launch fixture counts its ETH-refusing router's unpaid rewards.
- `test/FactoryLaunch.t.sol`: one-call factory-shaped CREATE2 deployment of the actual hook and fixed-supply token, both token address orders, constructor-only setup without engine code, allocation/seed, buys/sells with exact input/output and zero-liquidity LP-fee collection.
- `test/Size.t.sol`: also checks the constructor-created verifier's deployed size.
- `test/test_route_proof.py`: offline tests of RLP vectors, manifest-derived slot, proof calldata, reorganization refusal and the CLI's read-only RPC calls.

## Validation

The original suite passed 142 tests with the supplied seed before modifications. Both actionable audit regressions failed against that original code.

Final commands use the project's existing default profile:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xdd946ebf8c19a950bf866e51a9dc867cbae3b1d2dac8a071b4cd3783acbc8189 forge test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

Final results: `forge build` succeeds (compiler/lint warnings remain); **171 tests pass across 23 Foundry suites**, with zero failures or skips and the seed above; **5 offline Python tests pass**. Both factory token orders, the existing hostile-payout/withdrawal tests, fee and opening-surcharge tests, and the fuzz/invariant suites pass. Hash comparison confirmed that the manifest, compiler configuration, launch token and chess/engine sources remained unchanged.

Runtime sizes under that configuration: hook **20,620 bytes**, verifier **5,551 bytes**, token **1,088 bytes**, unchanged engine **23,339 bytes**. Hook creation code is **27,400 bytes**. All deployed contracts fit EIP-170, creation code fits EIP-3860, and the deployment bytecode has no unresolved library references.

The supplied protected tests were read; their toolchain-only helpers are not provided here, so this is not a claim that the verifier's protected suite ran locally. The project's admission tests and factory tests exercise the visible launch requirements. No mainnet deployment, broadcast, mainnet fork, Slither, Mythril or new full engine audit was performed.
