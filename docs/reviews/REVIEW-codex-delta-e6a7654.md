# Delta audit of main e6a7654

Recorded 2026-10-18. An independent auditor reviewed the delta on main `e6a7654`. The auditor's own fixes live in its sandbox, so decision 173 re-implements four of the findings on branch `fix/delta-audit-e6a7654`.

## Verification the auditor reported

| run | result |
| --- | --- |
| full suite | 751 passed, 0 failed, 7 skipped |
| e2e-real | 35 passed, 0 failed |
| deep invariants 21 and 21b | 7 suites, 64 runs of depth 200, all passing |

## Findings

| id | area | finding | state |
| --- | --- | --- | --- |
| L-01 | script/dev/Scenario.s.sol, script/dev/check-post.sh | the balance bid stage opened `balanceBidOn` and left it on, so the dev chain ended in the state `check-post.sh` rejects (bid on, value mode off, pool key set) | fixed: the stage closes the bid after its two fills; the check skips the fill probe while the bid is off |
| B-01 | web/lib/live.ts, web/lib/sell.ts, web/app/sell/page.tsx | the replay treated a missing protected sale price as value mode off and showed the posted payout, while the contract returns no quote and reverts `ZeroAmount` | fixed: value mode stays on, the replay pays 0, the sell action reads "balance quote unavailable" |
| B-02 | web/lib/live.ts | `useCoinLive` cached `false` with no expiry and refetched only on window focus | fixed: polls `getCode` every 15 seconds until the coin has code, then stops |
| SEC-02 | web/app/api/listings/route.ts | upstream fulfillment POSTs had a per client bucket and an in-flight cap, with no budget across clients | fixed: global token bucket, burst 8, refill 4 per second, 503 with `Retry-After` when spent |
| SEC-01, LEG-01 to LEG-05 | | listed in the auditor's report | the text of these findings was not available to the session that wrote this record; read them in the auditor's report before closing the audit |

## Open for the owner

The SEC-02 numbers (`UPSTREAM_BURST`, `UPSTREAM_REFILL_PER_SEC`) depend on the OpenSea plan rate limit and need confirming. The release freeze stays pending.
