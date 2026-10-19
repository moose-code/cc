# Documentation findings outside the decisions review (README, INTEGRATION, STATUS, RUNBOOK)

| id | file:line | text | why stale | replacement |
|---|---|---|---|---|
| DOC-01 | README.md:3 | "burns CC with half of every sale" | `saleToBuybackBps` 2,500 since decision 119: a quarter of the rest after the cuts | "a quarter of every statement sale buys and burns CC" |
| DOC-02 | README.md:15 to 18 (mermaid) | `sold -->|half| burn`, `sold -->|half| core` | same | quarter / three quarters |
| DOC-03 | README.md:36 | callers: `claimPayee`, `claimRoyalty` | both removed by decision 123 (pushes) | drop both; add `swapCredit`, `refreshReference`, `buyCredits` |
| DOC-04 | README.md:30 | "ControllerV1 ... `valueOf`, the royalty" | the controller royalty was removed (123) | "`valueOf`, the reference price" |
| DOC-05 | README.md:39 | "eth, credits and the balance token leave the Core at the owner's call only through `migrate`" | the Core holds no balance token (117) | "eth and credits" |
| DOC-06 | README.md:49 and .env.example | `FORK_BLOCK=26158000` | the live factory has no code before 26202473; the default fixture cannot run at that block | a block after 26205064 |
| DOC-07 | docs/INTEGRATION.md:38 (section 3) | `sellForEth` reverts "in value mode `NoQuote`" | decision 159 C02: the eth doors fall back; `NoQuote` is the controller's sale doors only | remove; add `ReturnLocked` is listed, fine |
| DOC-08 | docs/INTEGRATION.md:9 section 9 last line | "`balanceBidCapBps` and `balanceBidMarginBps` apply to value mode only" | `balanceBidCapBps` feeds `floorMultBps()` in both modes (section 2 of the same file says so) | "`balanceBidMarginBps` applies to value mode only; `balanceBidCapBps` also sets the credit sale floor multiplier in every mode" |
| DOC-09 | docs/INTEGRATION.md section 13 | "a stored pool key contributes pool value while its currency1 is the current balance token" | decision 170: no pool value in mode off | "a stored pool key prices nothing until value mode is on" |
| DOC-10 | docs/INTEGRATION.md section 12 | "last recorded before the issue 23 changes" gas figures | stale measurements; the audit's GasCap run supplies new ones | re-measure or cite the candidate run |
| DOC-11 | docs/INTEGRATION.md section 1 | "Core: the launch record in docs/STATUS.md" | the record is deployments/<chain>.json; STATUS has no addresses | name the record file |
| DOC-12 | docs/STATUS.md:5 "Core size 538 bytes of headroom after issue 23" | 902 at this build after the CoreOpsLib split | update or remove the number |
| DOC-13 | script/dev/e2e-real.sh:118 to 121 | "the live protocol occupies them (the predicted CREATE2 addresses) at recent head blocks, so a head fork collides" | preflight at block 26222700 shows the predicted Core, coin and renderer empty for both mainnet.json and anvil.json | state the real reason for the pin (determinism and cache reuse) or remove |
| DOC-14 | test/utils/V2Stack.sol:31 | "the default reads the superseded live record" | the live record is current; the master fixture is the superseded one | swap the words |
