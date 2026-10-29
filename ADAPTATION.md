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

`src/IMDuelHook.sol` now accepts either a packed 20-byte recipient or a canonical 32-byte ABI-encoded address. No ownership is inferred from `tx.origin`. The first revision made the PoolManager's swap `sender` own a bid that named no recipient; the review of that revision showed the sender is the router on every common path (finding 5edd7f4d below), so a bid that names no recipient is now nobody's: it bids and plays like any other, and its move pays no bounty (see the revision section). Dirty ABI padding is treated the same without breaking the swap. Existing explicit packed recipients retain their behaviour. Ownership also participates in the engine seed, so changing the fallback owner changes those trades' moves.

Integrations must forward the intended recipient in hookData to earn bounties. Failed payouts still remain in `owed`; only the owed party can redirect them with `withdrawTo`. Explicit zero recipient data continues to opt out of a reward, as the original packed format did.

## Revision: reviewer findings on the accepted work

Each was reproduced on the accepted tree before anything was changed; `.imd-responses.json` carries the verdicts.

### Payout guard bypassed by settleFor(hook) — 68f05aa8ca529a35221baa8a61c563eda2d3bb4a985e1f65170b6261fcfa7397 (medium, fixed)

Reproduced: an ETH/IMD duel on the hook, a recipient whose `receive()` calls `manager.sync(ETH)` then `manager.settleFor{value: 1}(hook)`. The hook's ETH delta during the trade is already nonzero (the chest share it minted as a claim in `beforeSwap` is offset by the PoolManager only after `afterSwap` returns), so the 1 wei moved it without crossing zero, the nonzero-delta count stayed the same, `payOut` accepted the payout, and the trade ended with `CurrencyNotSettled()`; every later swap of that duel replayed the same payout and reverted the same way.

Change, `src/IMDuelHook.sol`: `payOut` now takes the pool key and snapshots the hook's own deltas in the pool's two currencies (`manager.currencyDelta(address(this), key.currency0 / currency1)`) beside the nonzero-delta count; if any of the three differs after the send, it reverts `Unsettled` and the reward stays owed. The payout currency is always one of the two, and during a trade the hook holds no delta outside them (fee claims are minted in the pool's currencies only; the batch and burn paths net to zero and run after the payout). `_pay` passes the key through. Nothing else changes: an ordinary recipient is still paid inside the swap.

Tests, `test/Tokens.sol` (`SettleForOwner`) and `test/Hostile.t.sol`: four tests, a native-ETH duel and a callback-token duel, each with the recipient settling 1 wei for the hook in the payout currency and in the pool's other currency (the slice currency). Each asserts the move is played, the reward is owed and equals what left the chest, the nonzero-delta count is zero after the trade, later trades go through both ways and the books balance. All four fail with `CurrencyNotSettled()` when the own-delta check is removed.

### A bid without hookData owned by the router — 5edd7f4d325d60bd01cc114e287291987d7ad3cc64464dcedd854a8849352465 (medium, fixed)

Reproduced with the reviewer's proof: a buy through `PoolSwapTest` with empty hookData owned the bid, the move paid the router, the router has no `receive()`, so 0.27 ETH was left owed to a contract that can never call `withdrawTo`.

Change, `src/IMDuelHook.sol`, `_bidOwner`: a trade that names no recipient (hookData other than a 20-byte or clean 32-byte address) now bids for nobody. It still bids and plays its team's move at its strength, as the brief requires of every swap; only the bounty is not paid, exactly as a timeout move or an explicit zero recipient already behaved (`_payBounty` returns for owner 0). The swap `sender` is no longer used for anything. Refusing the bid instead would let a trade without hookData skip the game; recording `owed[sender]` would still accumulate a shared router balance.

Tests: `test/BidOwner.t.sol` (empty, dirty-padded and fuzzed hookData are nobody's; a forced capture played by a nobody bid pays nothing to the router, the wallet, the bundler or anyone and the chest keeps it), `test/Game.t.sol`, `test/Launch.t.sol` (both factory-shaped token orders and the ETH-paired launch assert the router is never paid or owed), `test/InvariantDuels.t.sol` (GL-05 allows a sized nobody bid; new SP-07 checks every `Reward` event names a recipient a trade gave, never nobody and never the router). The reviewer's proof `Proof_5edd7f4d325d.t.sol` passes on the result.

### Strength from in-range liquidity read at swap start — b3605770c7e04242982992758c4183411e66378b20101a796e8095aec4a94a11 (low, disputed, no change)

The trace holds: an LP holding nearly all in-range liquidity can, in one unlock, remove most of it, trade a dust amount at the 90% strength cap and add it back. It is not fixed here because neither suggested fix closes it within this launch's permissions. Sampling liquidity at the start of the block does not help: the first trade of a block takes that sample inside the same unlock, after the removal, so the manipulator who trades first in a block (or in each of three blocks, for gas) sets the sample. The only robust measure is a liquidity callback (`beforeRemoveLiquidity`/`afterAddLiquidity`) that notices the position moving inside a swap's block, which changes `getHookPermissions()` and the manifest's permission list; the assignment fixes both. Setting strength from the bid's size rather than its share replaces the game rule the brief states. The impact is bounded: a bounty is at most `PAYOUT_CAP` (2x) of the trade's own output, so the manipulator cannot drain a chest; it buys strong moves cheaply in duels where it already owns the pool's depth. Recorded here as an accepted limitation of this design.

### End-of-block spike delays the IMD conversion — 573a433044d1ef15959c9f3990e353a3f5ce3c1df79f5a5c93e07b8177124f1f (low, disputed, no change)

The trace holds: a trade that pushes the main duel's price up by more than 0.1% as the last of block B-1 and reverses it as the first of block B leaves that start price in the three-sample window, and each batch in the next three sampled blocks returns `(0, 0)`. This is the designed behaviour of the "most hook-favourable of three block-start prices" rule, kept on purpose: the batch only ever buys within 0.1% of a price the pool held across a public block boundary, so a seller cannot sell the pile into a price it pushed. A median of the three would let a pusher poison two samples by holding the price through one public block instead of two. The grief delays the conversion only (the pile stays as ERC-6909 claims, nothing is lost), costs the griefer the 0.5% hook fee and 1.25% LP fee on two trades of about 0.1% of depth every third sampled block with no gain, and the `CONVERT_GAS` attempt is bounded. Left as is.

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
- `test/BidOwner.t.sol`: contract-wallet/bundler reproductions, both recipient encodings, malformed data fuzzing, a real capture-bounty payout to the intended recipient, and a nobody bid that plays and pays nobody.
- `test/Hostile.t.sol`, `test/Tokens.sol`: the settleFor(hook) recipient, native and callback-token, both currencies.
- `test/Base.sol`, `test/Slice.t.sol`: ETH conversion fixtures now provide authenticated samples. Existing conversion and inherited cross-block tests retain their economic assertions.
- `test/Game.t.sol`, `test/Launch.t.sol`, `test/Money.t.sol`, `test/Invariant.t.sol`, `test/InvariantDuels.t.sol`: replace the old origin-owner expectation; a trade without a recipient is nobody's. The launch fixtures assert the router is never paid or owed; the invariant handler keeps the router in its owed-balance list (always zero now) and SP-07 checks every reward's recipient.
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

Final results after the revision: `forge build` succeeds (compiler/lint warnings remain); **176 tests pass across 23 Foundry suites**, with zero failures or skips and the seed above, plus the reviewer's proof; **5 offline Python tests pass**. Both factory token orders, the existing hostile-payout/withdrawal tests, fee and opening-surcharge tests, and the fuzz/invariant suites pass. The manifest, compiler configuration, launch token and chess/engine sources are unchanged.

Runtime sizes under that configuration: hook **20,963 bytes**, verifier **5,551 bytes**, token **1,088 bytes**, unchanged engine **23,339 bytes**. Hook creation code is **27,743 bytes**. All deployed contracts fit EIP-170, creation code fits EIP-3860, and the deployment bytecode has no unresolved library references.

The supplied protected tests were read; their toolchain-only helpers are not provided here, so this is not a claim that the verifier's protected suite ran locally. The project's admission tests and factory tests exercise the visible launch requirements. No mainnet deployment, broadcast, mainnet fork, Slither, Mythril or new full engine audit was performed.
