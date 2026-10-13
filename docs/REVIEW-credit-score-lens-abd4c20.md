# CreditScoreLens independent review

Final reviewed candidate: `abd4c20f57dce51f88c04443d19deb638a6354b8`.
Initial implementation reviewed: `135a2166acaf9bae5a6ce1ea888b80c4e3ccd96f`.
Reviewer: Codex subagent `/root/review_credit_score_lens`, independent of implementation, 2026-10-13.
Checkout: `/tmp/cc-creditscorelens-review-135a216`, detached and clean at both reviewed revisions. The director advanced this separate checkout to the follow-up commit; the reviewer did not move or modify the director's workspace.

## Goal and scope

Checked FLOW decisions 88–91 and the CreditScoreLens packet in docs/NEXT.md against the owner's goal: a simple, minimal developer helper for individual and batch credit scores, rarity, traits, and statement totals, with clear function names and proper NatSpec describing on-chain behavior only.

Scope: src/CreditScoreLens.sol, src/interfaces/ICreditScoreLens.sol, test/CreditScoreLens.t.sol, script/DeployCreditScoreLens.s.sol, script/tools/gen-interfaces.sh, script/tools/fix-interface.py, and helper sections of docs/INTEGRATION.md, NEXT.md and ARCHITECTURE.md. Read repository entrypoints, director handoff/status, current intent and evidence context, and project-director review guidance. This is helper review, not engine launch acceptance.

## Methods and evidence

Read the immutable implementation and test cases against the supplied exact-match Sourcify source snapshots for Credits, CreditScore and Statements. Independently recomputed the three runtime hashes and source-content SHA-256 hashes; all matched the pins and source-evidence table in NEXT.md. Checked mint timestamp validation, immutable credit records through burn, scorer input/output types and precision, trait tuple semantics, and statement compose/overprint accounting.

Inspected the supplied build, focused-test, interface and deployment-simulation logs. The focused log shows 17 passes, including 256 differential fuzz cases at block 26158000, transfer/burn invariance, batch ordering and failures, and nested overprints preserving absorbed-page scores. The simulation log shows one CREATE, no broadcast, and runtime hash `0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058`.

Independently regenerated the helper interface from the existing compiled artifact with `cast interface` and fix-interface.py, without compiling; output matched the committed interface byte for byte. Inspected its five-view/one-error ABI and 1,478-byte runtime. Ran `bash -n script/tools/gen-interfaces.sh` and `git diff --check 135a216^ 135a216`; both passed.

For `abd4c20`, independently regenerated the interface again and matched its committed contents. Recomputed the final artifact runtime hash: unchanged at `0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058`; ABI remains the same five views and one error with identical inputs and outputs. Independently compared final creation bytecode with the input of the sole CREATE in the earlier dry-run transaction file; the bytes are identical. `git diff --check 135a216 abd4c20` passed. All 17 focused test results and the deployment simulation are carried to this documentation-only repair because both creation and runtime executable bytes, the ABI, the tests, and the source dependencies are unchanged. No full-suite evidence is claimed or carried here.

## Findings

### L1: NatSpec overstates the absence of assets

Severity: Low. Classification: documentation correctness.

Locations: src/CreditScoreLens.sol:24 and src/interfaces/ICreditScoreLens.sol:8.

The contract-level NatSpec says it “Holds no state or assets.” No payable functions or asset-management functions does not guarantee a zero balance: ETH can be forced to the address, and an ERC20 can be transferred directly to it. Such assets have no recovery path. The claim should describe the actual interface and storage properties, for example: “Stores no mutable state and has no admin or asset-handling functions.” Do not add recovery functions to this minimal helper.

Disposition: fixed in `abd4c20`. The director independently noticed the wording and proposed the repair; the reviewer validated the counterexample. The reviewer inspected the follow-up immutable delta: only the contract NatSpec and generated interface NatSpec changed, to the suggested accurate wording. Removing NatSpec produces identical source and interface text at both revisions. No asset-management functions were added.

Final result: no open implementation findings. No Critical, High or Medium finding, and no runtime or ABI correctness defect found.

## Acceptance assessment

The five public names identify their NFT domain and result. The credit batch is the sole batching operation; it uses the same internal path, preserves ordering and duplicates, accepts empty input, and reverts atomically on unknown ids. There is no owner, mutable storage, local score math, cache, pricing or engine dependency.

The nonzero timestamp check correctly distinguishes historical mint records from unknown credits without excluding burns. Credit scores preserve ten-thousandths precision; rarity is returned as raw source points; the five traits retain their source order and values. Statement scores directly read the stored aggregate, so nested overprints are included without rescanning composedFrom. Unknown statements return zero and absorbed pages retain their own historical aggregate. Source failures propagate. These are useful developer semantics and the tests exercise the owner's acceptance cases, rather than merely matching an unrelated engine rule.

The interface-tool changes retain ABI-derived signatures, add only the intended helper, support scoped generation and cleanup, and preserve NatSpec from its source. Public helper docs reference the fixed on-chain contracts and do not compare other versions.

## Operational prerequisite and limits

Future deployment remains a separate owner-authorized action. The isolated script checks chain 1 and all three source runtime hashes before its one CREATE; it contains no private-key handling or engine launch action. It does not itself run `director.py check --gate deploy`. Project-director's phase-gate guidance requires a deployment control before external action; the existing engine deploy gate and OBJ-LAUNCH-1 remain unmet and must not be represented as satisfied by helper evidence. Before any authorized helper broadcast, the director must establish the applicable helper release control and record the exact approved command, artifact identity, verification and readbacks. This is an operational prerequisite, not a waiver or a helper-runtime defect. No deployment is authorized by this review.

No builds, test reruns, full suites, forks, deployment or external writes were performed by the reviewer. Execution results rely on the supplied logs; ABI regeneration used an existing director-workspace artifact read-only, not an independent compiler run. Source snapshots were checked locally, not refetched. This review does not restore stale engine evidence, validate the engine economics, establish launch readiness, or constitute a human audit.
