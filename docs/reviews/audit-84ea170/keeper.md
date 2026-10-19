# keeper audit: security and correctness

repository /home/user/cc, commit 84ea170, branch claude/hopeful-hamilton-nt5h8x. scope: keeper/src/*.ts, keeper/test/**, packages/engine/src/*, docs/RUNBOOK.md section 8. ground truth read: src/Core.sol (book, refreshReference, collectEscrow, buyListing, _quote, _payment, _payCaller, redeemStatement, buyback, _openDoor, _book, _sniperOver, _atFloor), src/lib/CoreLib.sol (spend, spendState, refreshReference, ethRate, room, _reserve, checkReturn, REFRESH_GAS), src/lib/CoreOpsLib.sol (setPaused), src/ControllerV1.sol (refreshReference, _protected, atFloor, _spot), src/adapters/*.sol. intent read: docs/SPEC.md sections 1, 3, 5, 6, 10, 12; docs/DECISIONS.md 136 to 139, 159, 176, 178; docs/RUNBOOK.md section 8. docs/reviews/* and docs/STATUS.md section 1 were not read. no file under /home/user/cc was modified (one throwaway probe script was copied into keeper/ for a node run and removed in the same command). forge and anvil were not run; read only calls went to the fork at 127.0.0.1:8545 (head 26222700).

## findings

### K-01  High  security  (a listing that simulates clean and reverts on chain starves `buyListing` and burns gas)

files: keeper/src/main.ts:114-124, keeper/src/exec.ts:69-77, 120-141; src/adapters/SeaportBasicAdapter.sol:63-75

claim: an on chain revert of a `buyListing` transaction does not cool the listing down, does not drop it from the candidate set, and ends the tick. the simulation is `eth_estimateGas` with no fee fields at `latest`, whose environment differs from the inclusion block in ways a hostile offerer contract can read. one hostile listing therefore makes the keeper send a reverting transaction every tick until the breaker trips, and blocks every other sweep in between.

evidence:

```ts
// main.ts:116-124
const outcome = await this.exec.run(c, state, listing);
...
if (outcome.kind === "failed" && listing) this.sources.coolDown(`${listing.venue}:${listing.id}`, LISTING_COOLDOWN_SEC);
// one transaction per tick: the next decision reads the state after it
if (outcome.kind === "sent") {
```
a reverted receipt is `kind: "sent", status: "reverted"` (exec.ts:141), so the cooldown branch is never taken and the loop breaks before any other listing or door.

```ts
// exec.ts:72
gasUsed = await this.client.estimateGas({ account: this.signer.address, to, data });
```
probe on the fork (state override, read only): `eth_call`/`eth_estimateGas` without fee fields run with `tx.gasprice == 0` (code `0x3a60005260206000f3` returned 0; code that reverts when gasprice != 0 did not revert without fee fields and reverted with `maxFeePerGas` set) and `block.number == head` (returned 0x190206c = 26222700), while the real transaction lands at head + 1 with gasprice = basefee + tip.

the Seaport basic order pays native eth to the offerer by `call`; Seaport reverts the fill when that call fails. the adapter (SeaportBasicAdapter.sol:63-75) accepts any `offerer`, so a contract offerer with `receive() { require(tx.gasprice == 0); }` (or a `block.number` parity test) passes the adapter quote, the owner check, the order status read and the simulation, and reverts on chain every time. the Core protects the pot (`NoCredit`, `BadCost`), not the keeper's gas.

failure scenario: attacker lists a Credit from such a contract at a tempting gap (so it sorts first, decide.ts:304-305). after 120 s the keeper sends; the fill reverts; `breaker.fail("buyListing")` (exec.ts:138); the tick ends. next tick the same listing is still valid and first; after `BREAKER_THRESHOLD` (3) reverts the whole `buyListing` door pauses 1 hour, then repeats. cost to the keeper per revert: the gas to the revert point (book, checkpoint, quote, Seaport entry), about 250,000 to 400,000 gas, at 1 gwei plus a 0.05 gwei tip about 0.0003 to 0.0004 eth; 3 per hour, under 0.03 eth a day, inside `DAILY_BUDGET_ETH`, but every legitimate sweep is blocked while it lasts. a cheaper variant with the same effect on other listings: an offerer who drops the bid ahead of the keeper (one `sellForEth` in the inclusion block) makes the sweep revert `AboveBid`; the keeper's timing (120 s after the listing turns sweepable) is public.

structural fix: (1) treat `status: "reverted"` of a `buyListing` as a fault of that listing: cool it down for much longer than 300 s (or until the order hash changes) and, for Seaport, remember the offerer; (2) simulate with the transaction's fee fields and at `blockTag: "pending"` so `tx.gasprice`, `block.number` and `block.timestamp` match inclusion; (3) consider the relay's revert protection endpoint (K-15); (4) keep the one transaction per tick rule but do not let a reverted sweep end the candidate list for the next tick.

### K-02  High  launch readiness  (`refreshReference` is sent every tick, unpaid, when the controller refresh returns false for a reason the keeper does not gate)

files: keeper/src/decide.ts:233-239, 383-398; src/lib/CoreLib.sol:500-517; src/ControllerV1.sol:277-293

claim: the Core door pays only when `IController.refreshReference()` returns true. the controller returns false in six cases; the keeper gates three of them. the other three leave `referenceTime` unchanged, so the keeper's "due" test stays true and it sends an unpaid transaction every tick. the breaker never trips (the transaction succeeds), so the only stop is the daily budget, which then idles every paid door for the rest of the UTC day.

evidence:
```solidity
// ControllerV1.sol:277-293
if (uint48(block.number) == lastRefreshBlock) return false;
uint256 ref = referencePrice; if (ref == 0) return false;            // keeper gates
if (q.referenceMaxStale == 0) return false;                           // keeper gates
if (elapsed < q.referenceMinSeconds) return false;                    // keeper gates
(uint256 spot, bool ok) = _spot(); if (!ok || spot == 0) return false; // NOT gated
uint256 move = uint256(q.referenceRateBpsPerHour) * elapsed / 1 hours;
if (move > q.referenceStepBps) move = q.referenceStepBps;
if (move == 0) return false;                                           // NOT gated
```
```solidity
// CoreLib.sol:504-506
if (ctrl == address(0)) return;
if (!IController(ctrl).refreshReference()) return;   // no payment, the door still cost book + checkpoint + the read
```
```ts
// decide.ts:233-239
if (s.referencePrice === 0n) ...; if (s.referenceMaxStale === 0n) ...;
const due = s.referenceTime + s.referenceMinSeconds; if (s.timestamp < due) ...;
return { ok: true, ... }
```
`_spot()` (ControllerV1.sol:650-658) is false when `balancePoolKeySet` is false, when `balancePoolKey.currency1 != CORE.balanceToken()` (the state after a balance token replacement, RUNBOOK section 8 "Replacing the balance token") or when `sqrtPriceX96 == 0`. `move == 0` holds whenever `referenceRateBpsPerHour * referenceMinSeconds < 3600` (for example rate 5 bps/h with the 600 s launch `referenceMinSeconds`: move = 5 * 600 / 3600 = 0 until 720 s). the snapshot already exposes both inputs (`value.spot` is undefined when `_spot` is not ok, `value.quote.referenceRateBpsPerHour`, snapshot.ts:196-206) and the keeper ignores them. the executor cannot see the payment: `estimateGas` succeeds either way (exec.ts:72-81), and the ledger records `received` only after the fact (exec.ts:127-131).

failure scenario: value mode on, the owner replaces the balance token and sets the module before the pool key (the documented order). every tick: decide says due, simulation passes, the keeper pays about 60,000 to 80,000 gas (book, checkpoint, controller read) with no refund. at 1 gwei plus 0.05 gwei tip that is about 0.00008 eth per block, 0.6 eth per day; the 0.2 eth budget is gone after roughly 2,400 blocks (8 hours), after which `buyListing`, `buyback`, `compose` and `redeemStatement` all answer "daily budget exhausted" until midnight UTC, and the same thing happens the next day.

structural fix: gate the door on `snap.value.spot !== undefined` and on `floor(referenceRateBpsPerHour * (timestamp - referenceTime) / 3600) >= 1` (both already in the snapshot), and add one generic guard in the executor: a paid door whose receipt shows `received == 0` counts as a breaker failure and is alerted. the second guard also bounds every future "paid on chain but not to us" case.

### K-03  Medium  best practice  (the OpenSea refresh runs inside the tick with no request timeout)

files: keeper/src/listings.ts:175-221, 225; packages/engine/src/opensea.mjs:112, 134, 188

claim: `candidates()` awaits `refreshSeaport()`; the fetch helpers in opensea.mjs call `fetch` without an `AbortSignal` and sleep on 429 (up to 1.5 + 3 + 4.5 s per page, 1 + 2 + 3 s per fulfillment). node's undici defaults are a 300 s headers timeout and a 300 s body timeout, so one stalled OpenSea or primary rpc connection holds the whole tick, and with it every door, for minutes.

evidence:
```ts
// listings.ts:225
await Promise.all([this.refreshStrategy(), this.refreshSeaport()]);
```
```js
// opensea.mjs:112, 134, 188
const r = await fetch(rpc, { method: "POST", ... });      // no signal
const res = await fetch(url, { headers });                  // no signal
res = await fetch("https://api.opensea.io/api/v2/listings/fulfillment_data", { ... }); // no signal
```
`indexerSeed` and `alert` do set `AbortSignal.timeout` (inventory.ts:488, alert.ts:557), so the gap is specific to the OpenSea path.

failure scenario: OpenSea holds a connection open without answering (a load balancer stall); the tick blocks up to 300 s per request; the buyback delay opens and closes, a ready page is not composed, the head poller keeps running and does nothing because `keeper.tick()` has not returned. unverified: the exact undici defaults on node 22.22 were taken from the undici documentation, not measured.

structural fix: `AbortSignal.timeout` on every fetch in opensea.mjs (a parameter with a default), and move the two refreshes off the tick path (a timer that swaps `this.seaport` and `this.strategy` when it finishes) so a slow source never delays a decision.

### K-04  Medium  best practice  (a malformed order aborts the tick instead of being dropped)

files: keeper/src/listings.ts:199-220

claim: after the `try` that guards the fetch, the keeper maps every order through `BigInt(x.price)`, `getAddress(x.params.offerer)` and `encodeBasicOrder` (which calls `getAddress` and `encodeAbiParameters` on every field). a single order with an unexpected shape (an OpenSea `fulfillment_data` field renamed, a `zoneHash` not 32 bytes, a mixed case address with a bad checksum, a non numeric price in a `SEAPORT_ORDERS` file) throws out of `candidates()`, the tick fails, and because `seaportAt` was already set the throw repeats once per `OPENSEA_REFRESH_SEC` while the cached list stays stale.

evidence:
```ts
// listings.ts:195-219: the try ends at 198; the following runs unguarded
orders = orders.filter((x) => { ... if (BigInt(x.price) <= 0n) ... });
this.seaport = orders.map((x) => ({ ..., params: encodeBasicOrder(x.params), offerer: getAddress(x.params.offerer) }));
```
a hashless or zero price order is handled (and tested, listings.test.ts), a structurally bad one is not.

failure scenario: OpenSea ships `zone_hash` instead of `zoneHash` in `input_data.parameters`; `basicParams` copies `undefined`; `encodeAbiParameters` throws on the bytes32; every 300 s one tick is lost for every door and the Seaport list never updates again (the old orders stay until they are filled or cancelled, which the per block status read does catch).

structural fix: encode and validate each order inside its own try and drop the bad ones with a `warn`, the way the hashless case is handled.

### K-05  Medium  best practice  (the base fee ceiling is checked at the snapshot block only; the recheck clamps instead of refusing)

files: keeper/src/decide.ts:259-265; keeper/src/exec.ts:79-81, 101-108, 120-126

claim: `ceiling()` runs in `decide` on the snapshot's base fee. the executor reads the live base fee for the recheck but `worstBaseFee` clamps it to the ceiling, so a base fee that has risen above the ceiling between the snapshot and the send still passes, and the transaction goes out with `maxFeePerGas = maxBaseFee + tip` below the current base fee.

evidence:
```ts
// exec.ts:79-81
const gasNow = { baseFee: (await this.client.getBlock()).baseFeePerGas ?? s.baseFee };
const r = recheck(c, s, listing, gasUsed, gasNow, this.policy);   // worstBaseFee = min(9/8 b, maxBaseFee)
// exec.ts:105-107
maxFeePerGas: pol.maxBaseFee + pol.tip,
```
such a transaction cannot be included until the base fee falls under the ceiling; after `RECEIPT_TIMEOUT_SEC` (300 s) `waitReceipt` returns undefined and the door takes a breaker failure (exec.ts:121-126). three in a row during a gas spike pause the door for an hour after the spike is over.

structural fix: in `run()`, after reading `gasNow`, skip with a reason when `gasNow.baseFee > pol.maxBaseFee`; count a dropped (never included) transaction separately from an on chain revert in the breaker, or only after the base fee has been under the ceiling for the whole wait.

### K-06  Low  best practice  (a transaction that lands after the receipt timeout is invisible to the ledger; `received` counts unrelated inflows)

files: keeper/src/exec.ts:109, 120-131, 155

claim: after the 300 s timeout the keeper records nothing and returns `failed`; if the relay includes the transaction later, its gas is never charged to the budget and the Core payment never credited. the next send takes `getTransactionCount(pending)` from public nodes that have not seen the private transaction, so it reuses the nonce (one of the two fails, no gas charged for the loser, so this part is safe). `received = after + spent - before` attributes any eth that reached the wallet between `before` (latest, before the send) and the receipt block, for example a top up, to the door, inflating the net loss budget.

structural fix: keep the pending hash and reconcile it in the ledger on the next tick (receipt lookup by hash); compute `received` from the `ListingBought`/`Buyback` event or from the balance at `receipt.blockNumber - 1`.

### K-07  Low  security  (hot paths log and alert with the engine's `txError`, which passes `shortMessage` through verbatim; the test covers `safeError`)

files: keeper/src/main.ts:173-174; keeper/src/exec.ts:76, 115-116, 168; packages/engine/src/errors.ts:304-323; keeper/test/ops.test.ts:166-192

claim: `safeError` (log.ts:581-586) strips URLs to their host; `txError` does not. node run (probe): on the exact error object ops.test.ts builds, `txError` returns `HTTP request failed at https://eth-mainnet.g.alchemy.com/v2/SECRETKEY123` while `safeError` returns `HTTP request failed at eth-mainnet.g.alchemy.com`. viem's own `HttpRequestError`, `TimeoutError` and `RpcRequestError` keep the URL and the request body in `metaMessages`, and their `shortMessage` carries no URL (verified: `HTTP request failed.`, `The request took too long to respond.`, `RPC Request failed.`), so with viem errors the practical exposure is nil; a plain `Error` whose first message line contains a URL (any wrapper that embeds the rpc or relay URL) would reach the `tick` alert webhook and the log.

evidence:
```ts
// main.ts:173-174
log("error", "tick failed", { error: txError(e), failures });
if (failures === 5) await alert(cfg.alertWebhook, "tick", "five ticks in a row failed", { error: txError(e) });
```
```ts
// ops.test.ts:172, 185: the test exercises safeError only
assert.ok(!safeError(e).includes(secret));
await alert("https://hooks.example.org/x", "secret-test", "tick failed", { error: safeError(e) });
```
the test's promise ("reaches neither the log line nor the webhook payload") is therefore about a function the two call sites above do not use.

structural fix: use `safeError` for every keeper log and alert field (keep `txError` for the decoded revert name through `revertName`), or make `txError` apply the same URL to host reduction before returning.

### K-08  Low  best practice  (an indexer seed with block 0 makes the first delta scan the chain from genesis inside the tick)

files: keeper/src/inventory.ts:357-368, 391-393, 498; keeper/src/listings.ts:126-139

claim: `indexerSeed` takes `max(0, ...status blocks)`; an indexer whose `_meta.status` is `{}` reports block 0, the book sets `confirmed = 0` and `delta(head)` issues `getLogs` in 10,000 block windows from block 1 to the head (about 2,600 windows, two calls each), all awaited inside `candidates()`. an rpc that errors on the range falls back to `full()` (the catch at 369-372), one that serves it slowly blocks the tick for the duration.

evidence:
```ts
// inventory.ts:498
if (page === 0) block = BigInt(Math.max(0, ...Object.values(body.data._meta.status).map((c) => c.block.number)));
// inventory.ts:363
this.confirmed = s.block > this.o.reorg ? s.block - this.o.reorg : 0n;
```

structural fix: refuse a seed whose block is 0 or below `record.deployBlock`; cap the delta range (for example 50,000 blocks) and take the full read above it.

### K-09  Low  best practice  (the entrypoint guard can make the process exit 0 without running)

file: keeper/src/main.ts:180

claim: `import.meta.url === \`file://${process.argv[1]}\`` is a string comparison with a hand built URL. `import.meta.url` percent encodes spaces and non ASCII characters and normalises the path; a checkout under such a path (or a symlinked `argv[1]`) makes the guard false, `main()` never runs, and the keeper exits with status 0 and no log line, which a supervisor reads as a clean stop. verified equal on this container's plain path.

structural fix: `import.meta.url === pathToFileURL(process.argv[1]).href` (node:url), or an explicit `--run` entry.

### K-10  Low  best practice  (configuration accepts values that make a door fail on its first attempt)

file: keeper/src/config.ts:262-268, 407-409

claim: `num()` allows 0. `BREAKER_THRESHOLD=0` makes `fail()` trip on the first failure (`n >= 0`, ledger.ts:299); `RECEIPT_TIMEOUT_SEC=0` makes `waitReceipt` return undefined at once so every send counts as a failure; `OPENSEA_PAGES=0` disables the source silently. no bounds, no log.

structural fix: a `min` argument for `num()` (1 for the three above) and a start log of the effective values (already done by `describe`, which omits these three).

### K-11  Low  legibility  (alert and skip logging)

files: keeper/src/main.ts:105-112, 171-175; keeper/src/alert.ts:549-553

claim: the `reserve` and `quote` alerts are called every tick; `alert()` logs at error level before the 30 minute dedupe, so a pot under the reserve produces about 7,200 error lines a day with the same text. the `tick` alert fires only when `failures === 5`, never again during the same outage (the dedupe would have allowed one per 30 minutes). `decide` drops a listing with `l.price > l.bid` silently (decide.ts:282) while every other gate logs a reason.

structural fix: apply the dedupe to the log line as well, or log the repeated alert at info; `failures % 5 === 0`; a skip reason for the bid check.

### K-12  Low  legibility  (tests whose assertion or comment checks something other than what the name says)

file: keeper/test/decide.test.ts

- lines 265-287, "pending-only cold pot is projected as paid from the booked pot share": the assertion `assert.equal(s.ethPot, 0n, "booked pot is empty; the Core books the pending pot share first, then pays from it")` tests the fixture it built, not a decision. the meaningful checks are the two `recheck(...).ok` lines; the fixture assertion should go.
- lines 185-194, "the payment is min(gas refund + keeperFee, bid - price, ethPot - price)": the rule is `room - price - royalty` (decide.ts:164), and the second branch (`potRoom: 0.0101`) asserts only `doorsOf(pot) == []`, which holds because 0.01 + 0.00025 royalty > 0.0101 is `PotTooSmall` (decide.ts:285), not because "the pot cap" bounds the payment as the comment says. the test passes for a different gate than it names.
- lines 404-414: the comment block ("KEEPER FINDING: bookLatches returns 'already latched' once payeeOn, so the latched/pot-0/pending state never books ... it does not today") describes a defect that no longer exists: the test passes because `bookFollowsIncome` books (pendingIncome 0.2 > 0.01, lastBookAt 0, decide.ts:213-217 and 356). the name uses an em dash, which the repository rule forbids.
- ops.test.ts:166-192: see K-07, the promise names the log line and the webhook while the function under test is not the one those paths call.

### K-13  Info  best practice  (the return lock is not modeled; it is handled by simulation only)

files: src/lib/CoreLib.sol:656-667; keeper/src/listings.ts:249-271

claim: `buyListing` reverts `ReturnLocked` while the offerer is the buyer the engine sold the credit to, for `returnLockSeconds` (21,600 at launch). the keeper has no read of `creditSoldAt` (the Core exposes no view for it, Core.sol:1020 is the only reference) and so simulates such a listing, gets `failed: simulation reverted: ReturnLocked`, cools it 300 s and retries, up to 72 free simulations per lock. no gas is spent. the promise at decide.test.ts:1-2 ("never sends a call that reverts on a gate it can read") holds only because the gate is not readable.

structural fix: none required for launch; a `creditSoldAt(id)` view in a later Core would let the keeper skip with a dated reason.

### K-14  Info  legibility  (dead `target: "controller"` branch)

files: keeper/src/decide.ts:109-111; keeper/src/exec.ts:57-60, 66

`Intended.target` is never set; `data()` and `to` carry a branch for the controller abi that no door uses, and the field comment says so ("the Core (every door...)"). remove the field and the two branches.

### K-15  Info  launch readiness  (relay endpoint semantics, unverified)

file: keeper/src/config.ts:202

`DEFAULT_RELAYS` hardcodes `https://rpc.mevblocker.io` and `https://rpc.flashbots.net/fast`. decision 139 says "no keeper transaction goes to the public mempool". MEV Blocker documents several endpoints with different privacy and revert policies (`/fast`, `/noreverts`, `/fullprivacy`); which policy the bare host applies, and whether Flashbots Protect `/fast` can forward to the public mempool after a delay, was not verified in this review. the operator should confirm the policy of each endpoint before launch; a revert protected endpoint would also blunt K-01.

### K-16  Info  best practice  (unbounded in memory maps)

files: keeper/src/main.ts:66, 98-100; keeper/src/listings.ts:79, 94-96

`skipLogged` keys include the listing key (`venue:id:price`) and `cooldown` the listing id; neither is pruned. a process that runs for months over a churning order book grows them without bound (about 100 bytes per key; harmless for a long time, but a leak).

## verified OK

decision logic against the Core:

- `buyListing` payment: `min(min(counted, 1,500,000) * min(basefee, keeperMaxBaseFee) + keeperFee, bid - value, room - value - royalty)` (Core.sol:756-760) is `listingPayment` (decide.ts:160-165); `room = CoreLib.room() = ethPot(after book) - reserve` equals the keeper's `potRoom = potWithPending - reserve` (snapshot.ts:126-129) because `_openDoor` books first and the book conserves the total; the `PotTooSmall` test `value + toArtist > room` (Core.sol:745) is restated at decide.ts:285; the `AboveBid` test at decide.ts:282. the keeper measures its cost with the whole transaction gas while the Core counts from `gasStart` plus a 350,000 overhead (Core.sol:259, 756), so the projection errs toward refusing.
- `buyback`: `TooSoon` at `block.number < lastBuybackBlock + buybackDelay` with the next block as the inclusion block (decide.ts:172-173 vs Core.sol:1094), `SliceTooSmall` at `slice < 2 * maxPay` with `maxPay = 600,000 * min(basefee, keeperMaxBaseFee) + keeperFee` (decide.ts:174-177 vs Core.sol:1097-1100), the fee scaled by `spent / (buybackSlice - maxPay)` with `spent` taken as the whole budget, the worst case of `fee.min(fee * spent / (setSlice - maxPay))` (decide.ts:178-179 vs Core.sol:1106-1113). no division by zero: `slice >= 2 * maxPay` and `slice <= buybackSlice` imply `buybackSlice > maxPay`.
- `callerPayment` vs `_payCaller` (Core.sol:950-959): returns 0 when both settings are 0, else `min(counted, cap) * min(basefee, callerMaxBaseFee) + callerFee`, at most the pot after the book (`potWithPending`); caps `COMPOSE_GAS` 13,700,000, `REDEEM_GAS` 1,500,000, and for the refresh door `REFRESH_GAS` 200,000 of CoreLib.sol:184, 509-511 (the formula there is the same with its own 50,000 overhead).
- spend budget: `spendBlocked` (decide.ts:194-198) restates CoreLib.spend (CoreLib.sol:361-372): bypass at `spendCapBps == 10,000`, first purchase of a bucket passes, revert when `spent + cost > budget`; the cost is `value + royalty + paid` (Core.sol:761) and the bucket, budget and spent come from `spendState()` at the pinned block, whose fresh bucket quote equals the budget the first purchase snapshots (CoreLib.sol:401-408). a `SpendCapReached` simulation is a skip, not a listing fault (exec.ts:75).
- reserve: `potRoom == 0` skips every listing with `ReserveHeld` (decide.ts:271-272), while compose, redeem, buyback and refresh pay from the whole pot (decide.ts:189 uses `potWithPending`), matching `_reserve` and `room()` (CoreLib.sol:597-654).
- payee latch and `book()`: `bookLatches` requires income pending (a zero income `_book` returns before the latch, Core.sol:447-448), `launchedAt != 0`, `timestamp >= launchedAt + sniperSeconds` (Core.sol:462-474, `_sniperOver`), `payeeOn` false; `launchedAt` is read from `deploymentInfo` whose tuple has `launchedAt` in position 9, the word the Core reads (abis.ts:261, Core.sol:244-245). after the latch `bookFollowsIncome` books above `BOOK_MIN_ETH` once per `BOOK_MIN_SEC`; the snapshot's `potWithPending` uses the pre latch `payeeOn`, consistent with "that book shares nothing".
- pause (decision 178): `buyListing`, `buyback`, `compose` blocked; `book`, `collectEscrow`, `redeemStatement`, `refreshReference` live (decide.ts:252-257), matching `_openDoor` (Core.sol:661-666), `buyback`'s `if (s.paused) revert Paused()` (Core.sol:1088) and the absence of a pause check in `redeemStatement`, `collectEscrow`, `book`, `refreshReference`. main.ts:93 fetches no listings while paused or retired.
- retired: `buyListing` and `compose` gated (`_openDoor`), `buyback` and `redeemStatement` not gated in the Core and not in the keeper.
- redeem gating: module nonzero (skipped without simulation, logged once per tick), `redeemOn`, `atFloor` through `controller.atFloor(sid)` at the pinned block for the held statements only (chain.ts:396-405), the same read `_atFloor` bounds (Core.sol:609-613).
- refresh cadence: the three gates the keeper applies are the controller's first three (K-02 covers the rest).
- gas and base fee: `worstBaseFee = min(ceil(9/8 * baseFee), maxBaseFee)` (decide.ts:142-144); `ownCost = gas * (worst + tip)`; `maxFeePerGas = maxBaseFee + tip` so a transaction never lands above the ceiling; the worst case direction is right because the keeper uses the same `gasUsed` on both sides, so profit is non increasing in the base fee. recheck at the measured gas for every paid door, `escrowBalance >= cost` for `collectEscrow`, always for `book`.
- priority and one transaction in flight: best gap first, then buyback, compose, collectEscrow, book, redeem, refresh (decide.ts:304-305, 324-398); the receipt is awaited before the next send; `cacheTime: 0` on the client so the next tick reads the head after the receipt (chain.ts:332-334).

liveness:

- rpc: `fallback` over the listed rpcs plus three public ones on mainnet, 20 s timeout and one retry each; a fallback answer is logged once a minute; the snapshot refuses an unpinned read and the tick fails cleanly; `main()` catches every tick error, counts failures and keeps polling.
- receipts: `waitReceipt` swallows rpc errors and is bounded by `RECEIPT_TIMEOUT_SEC`.
- breaker: time based pause, resets by the clock; count reset on success.
- ledger: per UTC day file, `remaining = budget - (spent - received)`, `allows` on the gross worst case cost; reloads after a restart (ops.test.ts:27-46).
- strategy inventory delta (inventory.ts): moves applied at or below `head - 12` to the confirmed set, newer ones to a working copy and re-read next time; `confirmed` never moves backwards when a lagging node reports a lower head; the rolling 300 id price slice; a delta error falls back to the full read; a daily full read; the state file keyed by chain and strategy; the Transfer event has an indexed `id` (abis.ts:171). the strategy holds 12,125 credits at the fork head (`balanceOf`), one `tokensOf` call and 9 price multicalls for a full read.
- OpenSea: a hashless or zero price order is dropped with a warning (listings.ts:200-210, tested); the order status read needs the hash; every candidate is re-read at the pinned block (`bidOf`, the adapter quote whose `value` is what the Core pays, `ownerOf` against the offerer or the strategy, `getOrderStatus` cancelled and filled) before `decide` sees it, and the simulation is the last check.
- scores: `seedOf` on a nonexistent id returns zero bytes on the fork (probe), so a bad id in a listing does not break the score multicall.

security:

- key handling: the v3 keystore is decrypted in memory (scrypt or pbkdf2, MAC checked before decryption), the key goes only into `privateKeyToAccount`; a keystore or password file inside the repository tree is refused (`insideRepo`); the owner address and the Core's `owner()` are refused as signer; the chain id of the rpc must match the record; an EIP 7702 delegated signer is warned; `describe()` logs secrets and secret paths as booleans or counts; a dry run needs no key; impersonation is refused off a local node.
- alert payload: `{ source, key, text, ...f }` with fixed field names at every call site, so no field from chain or api data can override `text`, `key` or `source`; the free text in `error` fields comes from viem `shortMessage`s or ABI error names (`revertName`), not from counterparties (K-07 is the one gap, and it is operator secrets, not injection).
- untrusted data: indexer ids and OpenSea orders only nominate candidates; the Core bounds the pot (`AboveBid`, `PotTooSmall`, `NoCredit`, `BadCost`, `AdapterNotAllowed`, the allowlisted recipients in the adapter); the keeper's only exposure is its own gas (K-01).
- replay: a filled or cancelled order is invalid before simulation (listings.ts:264-268); a credit the Core already owns is `AlreadyOwned` (listings.ts:260); the simulation reverts `AlreadyOwned` or the Seaport status check for a race in the same block.
- loops: `indexerSeed` is capped at 100 pages; the OpenSea fetch at `OPENSEA_PAGES` pages and `OPENSEA_SIGN` signatures; candidate reads at 40 per venue.

## stale comments and names

| file:line | text | why | replacement |
|---|---|---|---|
| keeper/src/decide.ts:10 | `the private gas constants of the Core (src/Core.sol 224 to 236), restated` | the constants are at src/Core.sol:233-268 now, and `REFRESH_GAS` is in src/lib/CoreLib.sol:184 | `the gas constants of the Core (src/Core.sol, PARAMETERS) and CoreLib.REFRESH_GAS, restated` |
| keeper/src/decide.ts:12 | `(Core.REFRESH_GAS)` | the constant belongs to CoreLib | `(CoreLib.REFRESH_GAS)` |
| keeper/src/decide.ts:109-111 | `target?: "controller"` and `the contract the call goes to: the Core (every door, including the refreshReference door that forwards to the controller)` | the field is never set, the comment admits it | remove the field and the branches at exec.ts:58, 66 |
| keeper/src/decide.ts:184 | `Core._payCaller for compose and redeemStatement` | the same projection pays the refreshReference door (CoreLib.refreshReference) | `Core._payCaller for compose and redeemStatement, and CoreLib.refreshReference for the refresh door` |
| keeper/src/decide.ts:192 | `Core.spend: the first purchase of a bucket always passes` | the function is `CoreLib.spend` (Core._spend forwards) | `CoreLib.spend: ...` |
| keeper/src/decide.ts:229-232 | `referenceMinSeconds is the cadence that produces a full step (step / rate)` | it is an owner setting (600 s at launch, rate and step 0 at launch, SPEC section 3), not a derived cadence | `referenceMinSeconds is the controller's least spacing between refreshes` |
| keeper/src/decide.ts:241-242 | `priority order: buyListing (best gap first), buyback, compose, collectEscrow, book, redeemStatement, observe. returns the updated staleness map` | there is no `observe` door; the seventh is `refreshReference` | `... book, redeemStatement, refreshReference. returns the updated listing staleness map` |
| keeper/src/config.ts:203 | `docs/RUNBOOK.md section 0 and .env.example list archive capable ones` | .env.example names `mainnet.gateway.tenderly.co`, `PUBLIC_RPCS` uses `gateway.tenderly.co/public/mainnet`; the two lists do not match | name the same hosts in both, or drop the .env.example reference |
| keeper/test/decide.test.ts:185 | `the payment is min(gas refund + keeperFee, bid - price, ethPot - price)` | the third term is `room - price - royalty` | `... bid - price, room - price - royalty)` |
| keeper/test/decide.test.ts:404-411 | `KEEPER FINDING: bookLatches returns "already latched" once payeeOn, so the latched/pot-0/pending state never books` and the em dash in the test name | the defect is fixed by `bookFollowsIncome`; the comment says the opposite of what the passing test shows; em dashes are forbidden by AGENTS.md | `// promise: once latched, a pending income above BOOK_MIN_ETH is booked by the income rule`; name without the dash |
| docs/RUNBOOK.md section 8, priority 7 | `refreshReference() on the controller ... unpaid, about 60,000 gas` | the keeper calls the Core door (decide.ts:395, `target` unset); the door pays the caller (CoreLib.sol:500-517) and the keeper profit gates it (decide.ts:390-393) | `refreshReference() on the Core: the door forwards to the controller and pays the caller like compose (REFRESH_GAS 200,000 cap); paid and profit gated` |
| docs/RUNBOOK.md section 8, priority 7 | `the pool-time cadence is referenceStepBps / referenceRateBpsPerHour (200 / 1,200 = 600 s)` | launch values are 0 / 0 (SPEC section 3); presented as fact | mark as an example for a later `setQuote`, with the launch values |
| docs/RUNBOOK.md section 8, priority 5 | `book() ... the book that latches the payee share` | the keeper also books after the latch when pending income exceeds `BOOK_MIN_ETH` and the last book is older than `BOOK_MIN_SEC` (decide.ts:356) | add the second rule to the row |
| docs/RUNBOOK.md:368 | `` `intended (logged only)` is a redemption while no module is set `` | no such log line exists; the case is a `skip` with reason `no balance module bound` (decide.ts:367) | `` a redemption while no module is set is a `skip` with reason `no balance module bound` `` |
| docs/RUNBOOK.md:372 | `` `book`, `collectEscrow` and `observe` are unpaid `` | there is no `observe` door | `` `book` and `collectEscrow` are unpaid `` |
| docs/SPEC.md:190 (outside scope, noted) | `its price(id, params) is read by staticcall (300,000 gas, 8,192 bytes)` | Core.sol:261 `QUOTE_GAS = 2,000,000` | `(2,000,000 gas, 8,192 bytes)` |
| docs/DECISIONS.md 159 C02 (outside scope, noted) | `pays the caller on the exact compose basis (_payCaller)` | the code pays with its own `REFRESH_GAS` 200,000 cap and 50,000 overhead (CoreLib.sol:183-184, 509), not `_payCaller`'s `COMPOSE_GAS`; the keeper mirrors the code | record the refresh cap in the decision or SPEC |

## test run

`cd /home/user/cc && npm test --workspace keeper` (node v22.22.0, node_modules present, no install needed):

```
# tests 49
# suites 0
# pass 49
# fail 0
# cancelled 0
# skipped 0
# todo 0
# duration_ms 2180.496398
```

files: test/decide.test.ts, test/inventory.test.ts, test/listings.test.ts, test/ops.test.ts, test/snapshot-quote.test.ts. no failing output.

not run: `npm run typecheck --workspace keeper` (the session's permission classifier refused the command); the e2e suites (test/e2e/doors.e2e.ts, launch.e2e.ts, seaport.e2e.ts) need the local anvil stack, which this review was told not to start. read only probes against the fork at 127.0.0.1:8545 (head 26222700): `Credits.seedOf(2^200)` returns zero bytes, `Credits.balanceOf(CreditStrategy)` = 12125, `eth_call`/`eth_estimateGas` without fee fields see `tx.gasprice == 0` and `block.number == head`.
