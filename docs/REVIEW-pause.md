# review of the pause (decision 81), 3653ea5..f5ab846, static read

reviewer: independent read-only agent, 2026-10-12. nothing executed by the reviewer; the director ran the touched test files.

verdict: no bugs. 0 critical, 4 low risks, 1 question.

## findings
- src/ControllerV1.sol header: said the asking price "stops falling" in a pause; the anchor keeps decaying, so only the age is held. fixed (comment), and decision 81 wording corrected.
- test/Pause.t.sol: tests ran at the launch anchor 10_000 only. fixed: test_anchorAboveParDecaysAcrossAPause.
- gas figure measured on a stub. fixed: test_gas_priceOfWithManyWindowsOnTheRealCore, 83,205 gas cold with 1,000 windows, under the CoreLens 200,000 budget.
- the pause window array has no cap; each window adds about one cold read per halving. accepted, stated in ARCHITECTURE section 7.
- question: a lost owner key during a pause leaves `buy` closed. same exposure as every owner power (decision 8); accepted.

## verified correct (by reading)
- Core, CoreLib, CoreLens, FeeRouter unchanged; only the controller pins moved.
- `_pausedUntil` binary search and the open window are correct at every boundary (start, end, equal timestamps, zero-length windows).
- `_age` is non-decreasing in time; no pause or resume timing gives a buyer a lower price than the held-age clock.
- `setPaused` is owner only through `core.owner()`; repeats are no-ops.
- `buy` checks `paused` first; Core and compose never read it; `priceOf` is not gated.
- the controller's immutable CORE sites grew from 13 to 14 (the inlined owner check).
- the handler and test models of the age are independent of the binary search.
- docs match the code (errors, events, order, storage, runbook).
