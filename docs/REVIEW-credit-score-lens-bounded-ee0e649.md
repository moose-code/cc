# CreditScoreLens independent bounded audit

Audited commit: `ee0e649754136c29b5feb94fe94402b03d4eb08c` on local branch `codex/issue-3-spec`, against base `79c79d1c7b412b430b20927615a6d86277e519c2`. Review occurred in an isolated detached checkout. The original worktree and its unrelated `.DS_Store` were not changed. This is a helper audit, not acceptance of the credits engine or authority to deploy.

## Result

**No actionable security vulnerability or correctness/documentation defect remains in the scoped helper.** The five public methods are justified by the requested single-credit score, batch score, raw rarity, source traits and stored statement total. They have no owner, mutable storage, cache, local scoring formula, asset-handling function or engine dependency. Public NatSpec and the consumer documentation state inputs, outputs, units, failures and historical behavior without claiming that a historical score proves current NFT ownership.

The prior independent review in `docs/REVIEW-credit-score-lens-abd4c20.md` was treated as a claim. I inspected the source and changed tooling, checked source snapshots and ABI shapes, and independently ran the focused mainnet-fork tests at block `26158000`.

## Security vulnerabilities

None found. Caller-controlled IDs and batch lengths only drive reads of fixed mainnet contracts. `creditScores` allocates and loops linearly; an oversized call can exhaust the caller's call gas, with no partial result or state effect. Source reverts and ABI decoding failures revert the helper call. There is no privileged entry point, balance transfer, callback, external write or mutable cache in `src/CreditScoreLens.sol:28-114`.

## Correctness and developer-facing clarity

No actionable defect found.

- `src/CreditScoreLens.sol:33-41` uses the three intended addresses. The fork tests asserted runtime hashes `0x8ab17e09de9f492357738695c934fb72062a0f1aa0c66eaf388b3fcf659d57d4` (Credits), `0xeea220f30cd748713b758d3cecf2a3c9e814381ace6d276390663d7e334ddf9d` (CreditScore), and `0x6ea1df2fdef523d462711ac890c1be3df13badae863912f8453018251488f6ae` (Statements) at block `26158000`. The local source snapshots' SHA-256 values match the three pins in `docs/NEXT.md`: `b2c916aa276ed04bc300b4aeb04e5482804739ec6d1f72b026a57f9e8f664176`, `713e3c873e8c419ee1c3c715cdb669c111b35786c26b9938318ee6329a591d89`, and `1ae0e4903edf3f9a9b8ebc683bfbef7d31fd5898b829a4cb0bef1570395b3b35`. The executed calls additionally establish ABI compatibility at that block; this audit did not independently recompile the external source snapshots.
- `src/CreditScoreLens.sol:103-113` rejects a zero mint timestamp with `UnknownCredit(id)` and reads the retained seed. Credits' verified source rejects zero timestamps at mint and does not clear either mapping on burn. This admits burned credits while rejecting never-minted IDs. The direct scorer calls at lines 71, 89 and 105 return their `uint256` or five-element tuple unchanged. Credit #1 returns `1324012`, in ten-thousandths of a point; rarity remains a separate raw trait-point metric.
- `src/CreditScoreLens.sol:57-62` preserves batch order and duplicates, returns an empty array for empty input, and reverts the whole call on an invalid ID. No arithmetic converts or sums scores. `statementScore` at lines 92-100 directly returns `Statements.creditScoreOf`; the source stores a page total at compose, adds the absorbed page's stored total on overprint and retains the absorbed page's record after burn. Never-composed IDs read zero. The focused test exercised these cases, including nested overprints.
- The compiled ABI has exactly five `view` functions and `UnknownCredit(uint256)`. `script/tools/gen-interfaces.sh --check CreditScoreLens` regenerated the committed helper interface successfully, including source NatSpec. The helper-only branch in `script/tools/fix-interface.py:29-39` leaves other interface processing unchanged. Regeneration from the available compiled ABIs matched each of `ICore`, `IControllerV1`, `ICoreLib`, `IFeeRouter` and `ICoreLens` byte for byte; the diff adds only `ICreditScoreLens` under `src/interfaces`.
- `script/DeployCreditScoreLens.s.sol:15-35` requires chain ID 1 and checks all three source runtime hashes before fetching `CreditScoreLens.sol:CreditScoreLens` creation code and calling `CREATE`. The focused test compared the resulting runtime code with that compiled helper artifact and tested rejection on chain ID 2. `vm.startBroadcast` marks the creation transaction for Foundry; execution without `--broadcast` remains a simulation. There is no implicit broadcast or engine deployment action.

## Operational prerequisites before any future release

These are release conditions, **not current runtime findings or deployment authority**.

1. **Pin the reviewed helper artifact.** `script/DeployCreditScoreLens.s.sol:29-38` selects a local compiled artifact and prints the resulting runtime hash, but does not compare it with an expected helper creation or runtime hash. A later source or build change could therefore produce a different helper while all three source checks still pass. Before an authorized broadcast, freeze the exact helper source, compiler settings, creation code and expected runtime hash, and compare the selected artifact with that record. The reviewed runtime is 1,478 bytes and its recorded hash is `0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058`; recalculate it for the final candidate.
2. **Run a scoped release check on current mainnet state.** The successful fork test and earlier no-broadcast deployment simulation use historical block `26158000`. The deployment script checks chain ID and source hashes at execution, but the operator must use the intended current mainnet RPC, exact approved sender and command, and the project-approved helper release control. After a separately authorized transaction, verify the receipt, deployed address and runtime hash, then compare direct source reads with helper reads. No broadcast, deploy, push or engine gate was run in this audit.

## Verification and limits

Commands executed in the detached checkout:

- `forge test --match-path test/CreditScoreLens.t.sol -j 1`: **17 passed, 0 failed, 0 skipped**; differential fuzz ran **256** cases. Tests created a fork at block `26158000` and checked the three source codehashes, transfer/burn, unknown IDs, batch order and atomic failure, overprints, and deployment-script artifact selection. The test compiled two files successfully.
- `script/tools/gen-interfaces.sh --check CreditScoreLens`: passed. A separate `cast interface` plus `fix-interface.py` comparison matched all five existing engine interfaces from the available compiled artifacts.
- `bash -n script/tools/gen-interfaces.sh`, `python3 -m py_compile script/tools/fix-interface.py`, and `git diff --check 79c79d1 ee0e649`: passed. The temporary Python bytecode was removed.

The Codex Security diff-scan workbench was started for the immutable range, but its changed-file inventory repeatedly failed at `ee0e649:project/director-state.json` even though `git show` and a direct invocation of its blob reader could read that committed blob. Its scan remains incomplete; this report is the independently performed bounded review, not a claim that the workbench finalized a scan. No full suite, deep invariant run, engine lifecycle, launch rehearsal, source fix, broadcast or deployment was performed. External source snapshots were checked by content hash and behavior against the pinned fork, not independently rebuilt to prove their exact-match provenance. Future mainnet state and a future release candidate require fresh checks.
