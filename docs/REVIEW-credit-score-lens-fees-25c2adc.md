# CreditScoreLens fee-preview independent review

Final reviewed commit: `25c2adcd4698df40f3b5041e3696bf41a39a4202`.
Initial reviewed commit: `2fc334c0c44aaefd932dadb1cf5d31b9147348bd`.
Diff base: `ddc4e041c554172b079a179a6140a06f94977364`.
Reviewer: Codex subagent `/root/review_credit_score_lens`, independent of implementation, 2026-10-13.
Checkout: `/tmp/cc-creditscorelens-review-135a216`, detached and clean at both reviewed commits. The director advanced this isolated checkout for the repair review; no parent-workspace edit or checkout move by the reviewer.

## Goal and scope

Owner's FLOW 96 request: “give me the deploy script. make sure the script gives me the gas fee before asking for my keystore. use my standard etherscan api key or ask for it in the script cli. and use tenderly and my ripe0x keystore”.

Reviewed the Python driver, its 18 focused safety tests, docs/INTEGRATION usage and associated intent records. Existing release-gate requirements remain authoritative. Implementation is authorized; agent broadcasting, wallet access and explorer submission are not.

## Original finding M1: Temporary cwd could reload a project's signer settings

Severity: Medium. Classification: intent/safety correctness.
Location: script/tools/credit-score-lens.py:47–56, especially TemporaryDirectory at line 51; corresponding unconditional claim in docs/INTEGRATION.md.

The wallet-free capture path removes signer environment variables and assumes its default temporary directory is outside any Foundry project. Python tempfile honors TMPDIR. With TMPDIR under a project, Foundry discovers the ancestor foundry.toml before parsing the explicit --root and reloads that project's .env. A keystore setting can therefore reappear before the fee preview, recreating the unlock prompt this change is meant to prevent. This can affect estimate, simulate and check paths; the default platform temporary directory worked in the supplied live estimate, but that does not establish the general guarantee.

Independent safe reproduction: created a synthetic project under /tmp containing foundry.toml and a .env with only `ETH_KEYSTORE_ACCOUNT=__review_dotenv_probe__`; set Python's tempdir to that project, equivalent to tempfile selecting it from TMPDIR. Called the driver's wallet-free capture with `forge script ... --help`. Local Foundry help printed `[env: ETH_KEYSTORE_ACCOUNT=__review_dotenv_probe__]`. The driver had removed inherited signer settings, yet dotenv reintroduced this one. No wallet was initialized, no build or fork ran, and no actual key was involved.

Relevant primary source: [Foundry v1.8.1 load_dotenv](https://raw.githubusercontent.com/foundry-rs/foundry/v1.8.1/crates/cli/src/utils/mod.rs), lines 184–213, and [find_project_root](https://raw.githubusercontent.com/foundry-rs/foundry/v1.8.1/crates/config/src/utils.rs), lines 27–67. Together they show that startup loads the cwd/inferred project's .env and that discovery walks ancestor directories until a .git boundary.

Required repair: make the read-only cwd an isolated project-discovery boundary, or otherwise prevent dotenv from restoring signer options even when the temporary root lies inside a project. An explicit --root alone is insufficient. Add a regression exercising startup from an adversarial temporary root; the current environment test mocks check_output and only asserts cwd differs from ROOT, so it misses this condition.

Disposition: fixed in `25c2adc`; no reviewer fix was made. The director added an empty `.git` directory inside the freshly created read-only cwd before starting Foundry. Its presence bounds Foundry's ancestor discovery to that clean directory; there is no `.env` there to restore a signer. The explicit --root still selects the intended build project after CLI parsing. The repair adds a real startup regression that places TMPDIR inside a synthetic Foundry project with a dummy keystore in its ancestor `.env`; `forge script --help` does not show the dummy setting. The reviewer inspected the immutable repair delta and independently passed this regression with the other 18 tests.

Final result: no open findings. No other actionable finding, and no Critical or High finding, identified in the initial or repair delta.

## Methods and assessment

Independently ran all 18 initial and all 19 final Python safety tests with bytecode writes disabled and the module's ARTIFACT pointed read-only at the existing parent artifact; all passed. The final test count includes the actual adversarial Foundry startup regression. Reviewed all driver branches, decimal fee parsing, prompt ordering, signer arguments, credential resolution and cancellation. `git diff --check ddc4e04 2fc334c` and `git diff --check 2fc334c 25c2adc` passed. The repair changes only cwd isolation, its regression and related documentation/state; fee math, confirmation ordering, wallet defaults and release-gate logic are unchanged.

The quoted max-fee and tip values are converted from gwei to integer wei using Decimal, validated for finiteness/range/integrality, and reused as explicit broadcast fee arguments. Local forge help confirms --with-gas-price accepts untagged wei and is maxFeePerGas for EIP-1559; the priority flag sets maxPriorityFeePerGas. The 130 multiplier is present in estimate and broadcast paths. ETH budget is gas budget times max-fee, not a promise of the mined fee, and this distinction is documented.

Outside M1, deploy orders the existing gate, build/artifact check, fee preview, Etherscan credential resolution, explicit confirmation and wallet invocation correctly. Default RPC is Tenderly; default account and public sender are ripe0x and the recorded owner. An alternative keystore or Ledger requires an explicit public sender. Cancellation returns before broadcast or wallet flags; EOF/interrupt handling exits without automatic deployment. The unmet release gate still fails before build or wallet work.

Etherscan keys are reused from environment or Foundry's resolved mainnet configuration; an absent key uses a hidden terminal prompt and is passed only in the verification child's environment. It is not stored in the parent environment or placed in argv. Verification retries still operate on an existing address without another deployment.

Read supplied parent evidence: the initial and repaired builds/tests passed, and the actual Tenderly estimate completed with a deliberately nonexistent inherited keystore in both runs. The repaired log `/tmp/cc-lens-fee-repair-live-estimate.log` records gas budget 484,845, max fee 0.212332611 gwei, tip 0.003202821 gwei and budget 0.000102948404780295 ETH. These are that run's live estimates, not durable prices. The reviewer did not rerun the network estimate.

## Limits

No reviewer wallet access, signing, broadcast, explorer submission, build or fork test occurred. Unit tests mock downstream commands; the independent dotenv counterexample uses only local Foundry --help. Live keystore prompting, actual transaction fee use and explorer acceptance remain untested. The source-based conclusion about a restored signer causing pre-fee wallet initialization relies on the established Foundry startup behavior and supplied parent investigation; the reviewer proved restoration without attempting to open a wallet.

This bounded tooling review does not satisfy or waive the repository deploy gate, restore stale engine release evidence, or establish engine launch readiness.
