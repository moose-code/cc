# CreditScoreLens focused shell deployment repair review

Reviewed commit: `a0a0f53108e816c1cfc65c62cbef7e1f6e2ddd7a`.
Diff base: `60f26741f606cd7e1b5ff69c34161b7a9ff158de`.
Reviewer: Codex subagent `/root/review_credit_score_lens`, independent of implementation, 2026-10-13.
Checkout: `/tmp/cc-creditscorelens-review-135a216`, detached and clean at the reviewed commit. No parent-workspace edit or checkout move by the reviewer.

## Authority and scope

Owner reports the pasted failures were engine deployment-gate errors and asks: “i think you really overengineered this. please keep it simple and focused”. The intended artifact is the standalone, minimal developer reader. The owner also requires a main/clean-Forge command, Tenderly, ripe0x, gas before wallet access, and the standard Etherscan key or a private CLI prompt.

The earlier Python CLI incorrectly made this separate helper depend on OBJ-LAUNCH-1 engine acceptance. Removing that dependency corrects the helper's scope; it is not a waiver of engine requirements. Independently compared director-state fields: objective, candidate, required freeze/deploy gates, gate evidence lists, candidate policy and state-only paths are identical to the base. script/director.py is unchanged. No engine Solidity, helper Solidity, generated interface or Foundry configuration changes in this delta. The latest owner correction supersedes the older helper implementation choice to call the engine gate. No agent signing, broadcasting or explorer submission is authorized.

Reviewed script/deploy-credit-score-lens.sh, script/test_deploy_credit_score_lens.py, helper usage/intent records and the removal of the Python driver/tests. Final implementation evidence depends on the shell script, its focused tests, the unchanged helper/interface/deploy/readback Solidity and reviewed build settings. The director's subsequent usage-only cleanup removes the redundant standalone `forge build`; it does not change those implementation inputs. Kept the review bounded to this repair.

## Findings

No actionable findings. No Critical, High, Medium or Low correctness/security defect identified in scope. No repairs or broader release work requested.

## Independent methods

Read the complete 84-line shell script and focused tests. Independently ran all four CLI tests using ephemeral copies of the immutable script and an existing parent-main artifact read-only. They invoke mocked Forge/git commands and real local Bash/Python/Cast artifact checks; all passed. Additional local probes covered EOF, N/no/yes responses, invalid mode and a zero retry address: none reached credentials or broadcast; EOF exits nonzero, explicit negative/non-y responses cancel successfully. `bash -n script/deploy-credit-score-lens.sh` and `git diff --check 60f2674 a0a0f53` passed. Review checkout remained clean.

Read the supplied actual Tenderly preview/cancellation log: native Foundry estimated 484,845 gas and 0.000073616108456175 ETH, then the script cancelled without wallet access. These are that run's measurements, not fixed future prices. Parent targeted build and prior main 21 focused fork tests are supporting author evidence; the reviewer did not rerun builds or forks.

## Assessment

The focused command is `git switch main && forge clean && bash script/deploy-credit-score-lens.sh` from the primary checkout. The script itself runs the helper/deploy/readback-only Forge build, so the command needs no separate full-project compile. The original a0a0f53 usage includes a redundant standalone `forge build`; the director is removing that in a documentation-only cleanup. The script independently refuses other branches and checks exact reviewed compiler settings and helper runtime hash before proceeding. It uses Tenderly and ripe0x with the recorded public sender.

The deploy path prints Foundry's native fee estimate before confirmation. Declining stops before Etherscan configuration/key resolution or wallet invocation. The preview/readback function removes inherited signer settings, starts in a fresh cwd with the previously validated .git discovery boundary, and uses an explicit build root. This retains the repair for ancestor .env signer restoration under project-local TMPDIR.

After confirmation, the script reuses the standard environment/Foundry mainnet explorer key or requests it through a hidden terminal read. The key is exported for the verification subprocess, not placed in argv, printed or saved by the wrapper. Broadcast is explicit, uses the ripe0x keystore and --slow, and has a fresh broadcast-record directory. The deployment Solidity still checks mainnet and its three source hashes.

The receipt parser requires exactly one confirmed mainnet CREATE, no pending entries, successful status, zero value, exact artifact creation input, expected helper identity, matching transaction hash and matching nonzero address. It fails before trusting a mismatched receipt. The script prints the confirmed address and retry command before source verification. Verify-address mode never redeploys or supplies wallet arguments.

Readback checks the exact helper/source runtimes and all five source results before publishing source with the explicit reviewed viair compilation profile and --watch. A later explorer failure exits without automatically redeploying. The fee preview is intentionally a native estimate rather than a fixed-price promise; docs explain that final fees can differ as gas prices change. This satisfies the owner's simpler fee-before-wallet requirement.

## Limits

No reviewer builds, forks, wallets, signing, broadcasts or explorer submissions occurred. Real mined receipt serialization, live keystore interaction and Etherscan acceptance remain untested; these cannot be claimed from mocked CLI tests. The parent's real preview/cancellation proves the wallet-free quote path on its host, not a successful deployment. Existing engine release evidence and OBJ-LAUNCH-1 are outside this helper repair and remain unchanged. This review grants no external-action authority and does not constitute a human audit.
