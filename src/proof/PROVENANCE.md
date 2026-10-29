# Proof libraries

Vendored as ordinary files from ethereum-optimism/optimism at commit `1ee89a21d9304d4cfea6e39ab407e3b689f115b9`.

- `MerkleTrie.sol`: `packages/contracts-bedrock/src/libraries/trie/MerkleTrie.sol`
- `RLPReader.sol`, `RLPErrors.sol`: `packages/contracts-bedrock/src/libraries/rlp/`
- `Bytes.sol`: `packages/contracts-bedrock/src/libraries/Bytes.sol`
- `LICENSE`: repository root MIT licence.

Source: https://github.com/ethereum-optimism/optimism/tree/1ee89a21d9304d4cfea6e39ab407e3b689f115b9/packages/contracts-bedrock/src/libraries

Only import paths were changed to relative local paths. No external linking, package installation, submodule, network access, or compiler configuration change is needed to build. All library functions used by the verifier are internal.
