Read AGENTS.md, then docs/specs/PHASE3-TREASURY-V2.md (the spec), docs/STATUS.md section 1 and the last rows of
docs/DECISIONS.md. Live addresses are in deployments/1.json and deployments/1-phase2.json.

Goal: build, test, review and prepare the deployment of treasury v2 (permissionless $BALANCE bid, funding by rule,
CC burn bonds) and ControllerV3 (band headroom, idle loosening, the views v2 needs), exactly as the spec says, plus
the indexer, keeper and web changes it lists. The owner approves the spec's open choices before code where the spec
says "must solve" or "evaluate"; ask one question at a time, with a recommendation.

Hard constraints: the protocol never sells $BALANCE; the Core is immutable; tests and sims run against the deployed
mainnet contracts on a pinned fork of a recent block (pin past stage C, block 26250700 or later); never use the
owner's Alchemy key (Tenderly only); every owner send is prepared, never broadcast by you, from the main checkout
with `--slow`, a no-keystore dry run and a gas estimate first.

Work fast and safely:
- One focused spec decision pass, then implement v2 and V3 in their own files next to v1/V2.
- Run only the tests you add or touch, once each, on the pinned fork; do not rerun unchanged suites, do not add a
  separate build when a test run compiles. Whole-suite runs only once, on the frozen candidate, with CANDIDATE_RUN=1.
- One migration rehearsal on a fork of the head, one independent review of v2 + V3 (money, authority, migration);
  fix findings and re-run only the affected tests.
- Batch indexer changes into one reindex on a temporary machine (API-only code in indexer/src/api).
- Frontend changes stay local until the owner reviews them; then ship.

Deliver: merged code on main, the fork rehearsal evidence in docs/STATUS.md, decisions recorded, and the exact
owner command sequence (dry runs first) for deploy → migrate → setBalanceModule → setController → readbacks.
