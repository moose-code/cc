# Issue 23 early independent source review

Reviewer: independent `/root/review` agent. This is early source review, not final candidate or release acceptance.

## Identity and method

Reviewed parent commit `2e8330cbaf0a9e190696f6f87a263677878df21e` plus `/private/tmp/issue23-source-review.patch`, SHA256 `8295dd535fb42af4f69f511e79265667ec48fea51371accdf15ef71e59901dd8`. A separate clone at `/private/tmp/cc-issue23-review-early` was checked out at that commit and the exact patch applied. The reviewer did not edit implementation files or use the coordinator's working tree.

Authority: owner's approval to implement issue 23, including 10,000 bps bypass, retained used budget across settings edits, and the recommended dependent fixes, as recorded in decisions 129 and 130. Inspected Solidity contracts, settings bounds and tooling, generated interfaces, storage consumers, focused test changes, simulator and web commits. Executed two cheap Node counterexamples below. No compilation, fork, full suite, deep invariant campaign, lifecycle, deployment or transaction was run by this reviewer. Coordinator verification remains separate evidence.

## Findings

### R1: P2, correctness, combined owner settings can fail despite a valid final state

`script/SetSettings.s.sol:79-94` previews controller edits against the old Core state and always sends Core settings before controller settings. Two examples with valid markup values:

- Old floor 20,000, markup 22,000; new floor 10,000, markup 12,000. Controller preview rejects the new markup against the old floor, although applying Core first would succeed.
- Old floor 10,000, markup 12,000; new floor 20,000, markup 22,000. Preview succeeds, but the Core-first transaction rejects its new floor against the old markup. Applying controller first would succeed.

Plan and simulate the entire patch in the same dependency order used for broadcast. Restore preview state and retain cached changes for broadcast. This path predates the patch, but is in scope of the authorized owner-tooling flexibility pass. Coordinator notified; repair pending final review.

### R2: P2, intent mismatch, simulator duration edits lose the active bid-drop floor

`sim/engine.js:485-486` rebases the spending bucket but never translates ETH `burstTime` or balance `balBurstBucket`. Contract `CoreLib._updateSpendSettings` and `_rebaseBucket` preserve active drop floors and invalidate expired ones before translating ids.

Executed Node counterexample: instantiate a Core at timestamp 120 with rateStart 1,000 wei, dropPerCreditPct 100, dropToPct 50, cap bypassed and a funded pot. First same-time purchase stores rate 500 and drop-bucket id 2 with base 1,000. Edit bucketSeconds from 60 to 100 at the same timestamp, then purchase again. Simulator resets its base to 500 because bucket id changes to 1 and stores rate 250. The contract carries the active base of 1,000 and remains at 500. The same error affects balance fills. Expired buckets whose new numeric id equals the old id need the converse regression.

Rebase both bid-drop buckets under the old duration, alongside the spend ledger. Coordinator notified; repair pending final review.

### R3: P2, correctness, simulator rejects an affordable listing when the keeper receives zero

`sim/engine.js:579-584` limits keeper payment by the fee and bid room, omitting the Core's third limit, `ethPot - ask` (`src/Core.sol:690-694`). A credit above refScore can have a score-scaled bid above the buying pot.

Executed Node counterexample: pot 0.01 ETH, reference bid 0.01 ETH, credit score twice refScore, ask 0.01 ETH, positive keeper payment. Contract buys the credit and pays the keeper zero. Simulator computes a positive keeper payment, makes total cost exceed the pot and returns null. Clamp keeper pay by remaining pot before charging the shared budget. This path predates the patch but affects the requested simulator parity. Coordinator notified; repair pending final review.

## Challenged claims without an additional finding

- Both direct sell overloads and adapter fills converge on one shared budget after fee booking. Adapter outflow includes price and keeper payment. Solidity transaction rollback covers budget, rate, pile and NFT state on a later failed credit or minOut failure.
- The ledger counts bypassed purchases, retains original snapshot and successful outflow on cap edits, and checks expiration using the old duration before rebasing an active bucket.
- Balance purchases remain independent of the ETH budget. Both balance conversions honor a configurable cap above par, and pages saturation is derived from both configured caps. The arithmetic remains within 256 bits for valid unit/refScore/cap field widths, including huge reported available funds.
- Per-minute climb remains based on 60 seconds; only the shared drop budget duration and idle loosening step use their new settings. The sniper payee activation is a one-way latch. Anchor movement zero returns without changing its clock; full and partial fractions use the configured gap share.
- The new five-word Settings layout moves the ETH anchor to slot 28, balance instance to slot 32 and spend ledger to slot 39. Web ABI and events contain all 34 settings. Generated Solidity interfaces reflect the changed external surface.
- The preview snapshot repair in the reviewed patch restores controller state, addressing the earlier consumed-preview defect, but does not by itself resolve R1's multi-call dependencies.

## Limits

Budget and cumulative outflow are checked uint128 values; bypass does not promise successful accounting above uint128 max. Snapshot pot is uint256. The market simulator retains Number rate/price trajectories and converts their already approximate results to an exact BigInt budget ledger; this is documented and is not an exact Solidity differential simulation. Full-width arithmetic claims exclude arbitrary impossible chain timestamps or artificially unbounded ETH supply.

Existing broad release evidence predates this packet and cannot accept it. Final review must cover the repaired immutable candidate, its focused verification, and the coordinator's once-per-candidate broad gates. This report carries three actionable findings and does not claim final acceptance.
