# review of 74d1cbe: the first migrate retires the old engine (FLOW 48)

reviewer: a read only subagent in a fresh context, 2026-10-10. author of 74d1cbe: an implementer subagent. method: `git show 74d1cbe`, the call graph of every door, `test/Migrate.t.sol` run in a throwaway copy (27 pass), and each `Retired` check deleted in turn in that copy (the six door test and the partial batch and adopt tests fail without them). not run: the full suite, the invariant suites, deploy and sim scripts.

result: no correctness or security defect.

| # | class | finding |
|---|---|---|
| 1 | operational | nothing on a retired Core calls `flush`. if the fee router still names the old Core, every later flush is booked there: `feeToBuybackBps` to `ethToBuyback`, the rest to `ethPot`, which only a later `migrate` moves. after `router.lock()` the retired Core is the permanent fee sink. the runbook does not say to call `router.setEngine(successor)` before `migrate` |
| 2 | intent | every `migrate` moves `xToBuyback` with `xPot` while `ethToBuyback` stays. `buybackExit` on a retired Core can run only between an exit and the next `migrate`. this follows the owner's words and no document states the limit |
| 3 | operational | `lockSuccessor()` is allowed with the successor at zero. after `setSuccessor(0)` and `lockSuccessor()`, later fee `ethPot`, the exit token pots and leftover pile credits can never move |
| 4 | operational | `exitStatement` repays its caller from `ethPot`, capped at the pot. a retired Core with an empty pot repays 0, so nobody is paid to exit its statements |
| 5 | missing evidence | the `syncStatement` relist branch is not exercised after retirement. a non owner `migrate` leaving `retired` false has no unit assertion. the six door refusals are one sequential test |
| 6 | cleanup | docs/ARCHITECTURE.md row 28 says "being built". FLOW 33's mechanism text still moves `ethPot + ethToBuyback`. docs/ARCHITECTURE.md line 140 says the old Core "keeps working". `CoreLens.snapshot()` does not return `retired`. `_openDoor` names neither of its behaviors. a comment at src/Core.sol 1174 exceeds 120 columns |

checks answered: all six doors refuse and every kept path works. storage: `retired` sits at slot 25 byte 29 after `successorLocked`, asserted by test/CoreLayout.t.sol. money: `ethPot` moves, `ethToBuyback` stays and is burned, the exit token pots move, the rate is checkpointed and the window closed before the pot is zeroed, `retired` is set before the external call and a failed send reverts the call. no double count and no unintended claimant found. size: Core 24,141 bytes, CoreLib 17,085, no check dropped.
