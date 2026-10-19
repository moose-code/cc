# Launch description delta, 2026-10-19

Executable revision `9fadc14d1e35010e3d090b7bea3fc578ab047f48` changes the launch description, the preview's demo coin, the signer rehearsal's config source, and the focused config test. It does not change production contracts or dependencies. The broad suite and deep invariant results at `a0fa1dc` remain the preceding frozen-candidate evidence; they were not repeated for this literal metadata update, per owner decision 205. The signed same-record drill and production-service acceptance remain unproven.

The approved 124-byte description exactly matches `web/lib/site.ts`. `image` remains empty in the launch config; `LogoCoinRenderer` supplies a 2,013-byte SVG with six animations. The preview's decoded JSON has name `CC`, symbol `CC`, the approved description and the SVG image. The renderer runtime build hash remains `0x789770d6ad6b21255e6aa816a264650ed079691ad3ee36359a2972b75b7d9be9`.

| check | revision and scope | result | limit |
|---|---|---|---|
| `forge build` | `9fadc14` source staged before commit | exit 0 | production bytecode unchanged; stale generated artifact warning only |
| `forge test --match-path test/Config.t.sol --chain-id 1` | chain-id-1 fork, block 26,208,025 | 34 passed, 0 failed, 0 skipped | focused config file |
| `CANDIDATE_RUN=1 REHEARSAL=1 LAUNCH_CONFIG=script/config/mainnet.json forge test --match-path test/Rehearsal.t.sol --chain-id 1 -vv` | local Anvil fork of mainnet block 26,208,025 | 1 passed, 0 failed, 0 skipped; preflight 116 ok, 2 warnings, 0 failed; postflight 77 ok, 0 failed | in-process Foundry simulation, no signed receipts or interrupted recovery |
| `FORK_URL=http://127.0.0.1:18547 FORK_BLOCK=26208025 script/tools/coin-metadata.sh` | launch preview on the same local fork | exit 0; 3,881-byte metadata URI, 2,013-byte SVG, six animations | preview contract, not the eventual live coin |
| `bash -n script/dev/rehearse-signer.sh`; JSON transform and website-copy comparison; `git diff --check` | changed script and config | exit 0 | signed wrapper not run |

The first rehearsal attempt failed when the public upstream returned HTTP 408 for a factory storage slot. A retry against the same pinned local Anvil fork passed. No failing contract assertion was hidden by this retry.

For this exact config, the simulated `CONFIG_HASH` is `0x75e231b433893f1a9876ea1715e0fca24cce95fe63380ed82264443b131b0b83`; predicted Core `0x76413d49Dd870b721165135c40E8a71ae4723357`, coin `0xb59d732320b005955188acec812dEef9450B9397`, controller `0x4f8cd3b048C1D62e2B99e6B535877A08B404921E`, renderer `0x0D2022F8D780884A1B46de156CBfc4f36423504c`. The renderer address stays the same because its salt and owner did not change. The launch simulation through the deployed factory accepted the config and used 3,190,882 call gas. The 12 measured deployment transactions total 21,676,127 gas, below the 22,000,000 estimate; the largest is Core creation at 5,971,300 gas, below the 16,777,216 per-transaction cap. These are fork simulation figures, not signed receipt gas.

Before deployment, recalculate the hash and addresses from the final local config, market rate and current factory state. A further config edit invalidates the numbers above. The live website, keeper and indexer still need to be bound to a final deployment record; local tests do not establish production service acceptance.
