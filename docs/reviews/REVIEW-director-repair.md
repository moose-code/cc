# independent review of the director repair, 2026-10-10

three read only reviewer subagents, each in a fresh context, reviewed the director repair of 2026-10-10. none authored the records it reviewed and none repaired its findings. this file records their findings as reported. the director's dispositions are in docs/reviews/REVIEW-decisions.md section 6.

## 1. review of 01452dd (cc records) and 15653ff (the project-director skill)

method: `git diff 2407087 01452dd`, the owner transcript 75f67902 for every quote, the checker functions run on in memory copies, the skill's two test commands. claims C1 to C6 challenged.

| claim | verdict |
|---|---|
| C1 the skill's v1 defects are real and fixed | holds, with regressions: v1's "one active change", "separate launch blockers from cleanup" and "no new subsystem without a rule" were dropped |
| C2 the checker is proportionate and sound | partly: findings 1 to 3 |
| C3 intent records are faithful and authority is unambiguous | partly: findings 6, 7, 13 |
| C4 the decision audit classifications hold | partly: findings 4, 8 |
| C5 the evidence ledger is honest | partly: findings 10 to 12 |
| C6 what the director missed | findings 5, 6, 9, 14 |

findings:

1. high. any passing record satisfied any gate: gates had no kinds, empty required gate lists passed, deploy ignored decisions that block freeze. repro: one analysis record listed in every gate passed freeze and deploy.
2. high. a carry record could launder stale evidence: the carrier's scope was never checked against the carried scope. repro: a carrier scoped `docs/**` carrying a review scoped `src/**` stayed valid.
3. medium. scopes could silently match nothing (bare directories, `./src/**`), stateOnlyPaths could hide evidence scope, `test/**/*.sol` missed direct children, non ascii diff paths were quoted.
4. medium. OD-1 option B listed five doors. `sellForExitToken` (src/Core.sol 631) does not call `_pullFees`. it also ignored guarantee 42 and invariants 11 and 16, and left the flag timing undefined.
5. medium. the deploy gate was not part of the runbook.
6. medium. guarantee 42 was recorded wider than the code proves: above `rateCap` buying stops, and a rising market is followed slowly.
7. medium. FLOW 43 and 46 attributed director text to the owner ("nobody is overpaid", "the engine never sells credits").
8. medium low. path B was classed contradicted. the owner's words and FLOW 33 support unproved.
9. medium low. the test records referenced no intent assumption, so an owner decision change could not invalidate them. the deep run's "reviewed with the owner" was overstated.
10. low. E-REVIEW-SALE was called the most recent review. docs/reviews/REVIEW-v2port.md is later.
11. low. "a comment change cannot change bytecode" is false for NatSpec, which enters metadata.
12. low. the audit record's scope omitted files its findings rest on.
13. low. precedence text duplicated across four files, README called FLOW the brief, OD-1 recorded in four places.
14. low. FLOW 37 classed supported on invalid simulator evidence, the system audit sequenced after the freeze, NEXT 21 pins exactly 10x.
15. low. the decision id pattern matched only DEC-n.

not examined: no forge run, Solidity read only for the migrate doors and invariants 11 and 16.

## 2. re-review of 5c02f64 (cc) and 73d6495 (skill)

| finding | verdict |
|---|---|
| 1, 3, 4, 5, 8, 9, 11, 15 | resolved |
| 2 | partly: the carrier must cover the carried scope, but in scope changes between the two revisions were not checked |
| 6 | partly: FLOW 42 still read "never locks up" |
| 7 | partly: an unlabelled director sentence remained in FLOW 46 |
| 10 | partly: commit counts wrong (34 for the latest review) |
| 12 | partly: rows cite files outside the audit scope |
| 13 | partly: HANDOFF section 1 repeated the precedence |
| 14 | disposition accepted |

new findings:

* N1 high. an analysis record could carry an older review across a change to the reviewed code and satisfy a review gate.
* N2 medium. the new 10x preflight row caught the review matrix's rate mutations, masking the bounds checks.
* N3 low. the recovery time wording did not match the compounded climb.
* N4 low. the baton called the 06009bd suite records valid after fb6c26c changed their scope.
* N5 low. the schema 1 message pointed at a file without migration steps, the decision id pattern was undocumented and silent on zero matches, `analysis` could be listed as a gate kind.

the NEXT 21 test wrapper `_pre` was checked and masks no real failure. the matrix reclassification counts match.

## 3. adversarial check of 16249c1 (skill) and 2645c00 (cc)

* N1 still open: chains of analysis records (analysis carries analysis carries review), three levels deep, a review kind top record, and the same chain over an acceptance record all passed a review gate. the reviewer name comparison accepted lookalike strings. a deleted reviewed file listed as state only passed.
* N2 closed except one gap: removing only the `rateStart <= rateCap` clause made nothing fail.
* the uint64 overflow fix in the ratio row's detail string is correct and complete.

the director's follow up: the checker applies the independent kind rule over the whole carried closure and normalizes reviewer names (skill 23bd276), and the matrix gained a rateStart above rateCap mutation that fails when that clause is removed (f1fd139). a reviewer name written as a Cyrillic lookalike still passes: a checker cannot prove who reviewed.
