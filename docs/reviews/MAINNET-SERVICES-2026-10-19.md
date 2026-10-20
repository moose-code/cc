# Mainnet service activation, 2026-10-19

Status at 2026-10-20 00:48 UTC: launch-critical live service checks pass in enforced no-send mode; full historical indexer acceptance is explicitly deferred by owner decision 228. Keeper funding, arming and separate coin-launch approval remain owner actions. No coin or pool launch, blockchain transaction, funding or Git push is authorized or performed by this service-activation task.

## Scope and revision

Work uses `/Users/dd/CascadeProjects/cc/cc`, branch `main`, starting at `e713bb0ffb4eb9c75fdbf427cf6aa743526f1c04`. The owner authorized reversible production service configuration and starts, specified Fly for keeper/indexer, approved up to $30/month plus $5 total setup/build retries, and approved reuse of the Midway ntfy topic plus the specific OpenSea and dedicated keeper credential transfers into Fly secrets. Secrets stayed in existing stores or memory during authenticated transfer; no secret value, credential URL, private key or password was written to source, temporary files or logs.

## Actual Ethereum deployment

Read-only observation: 2026-10-19 21:44:23 UTC (17:44:23 America/New_York), chain 1, block 26,229,388, hash `0x589329540bce19e6f626ef7a8762662f4d43adaa24552cb43957704c60a94cc1`.

- Core: `0xcdb1889ae12074d750CD9B8531B692015465e0dD`.
- Core creation: `0x2e9541a600d9c143ef537c8b10d7f254c04857e440e461c78ecd5f764edd297e`, successful at block 26,229,330; no Core code at the preceding block.
- All 11 actual chain receipts match the local Forge receipt hashes, successful statuses, block numbers and block hashes.
- All seven deployed runtimes match compiled artifacts and pinned masked runtime hashes. Core is 23,762 bytes; CoreLib is 23,811 bytes. Postflight also checks every immutable and linked-library reference site.
- Recomputed configuration hash: `0xe146658a6d35ea8c00acb845e9c7876850fa5682df5238f0832b0f7320820b36`.
- Deferred postflight passed 47/47, exit 0, including owner, stack, settings, opening rate, controller, renderer, adapters and allowlists, libraries, CREATE2 identity and factory coin prediction.
- Predicted coin `0x28ef14A55DC93CDCB9001FA038A184967146C789` has no code and its factory salt is unused. No pool/coin launch is inferred from the Core deployment.
- Core balance, buying pot, buyback pot, redeem-burn pot and live ETH bid are zero. Stored opening rate is 0.0056 ETH per 100 points. Core is unpaused, unretired and controller unlocked; pending owner is zero.

Commands: source `script/env/mainnet.env`; run `forge script script/Postflight.s.sol --rpc-url mainnet` with `MAINNET_RPC_URL=$RPC_URL`, recorded `CORE`, `DEFER_LAUNCH=1`, `POSTFLIGHT_RECORD=deployments/1.json` and recorded `CONFIG_HASH`. No `--broadcast`. A separate read-only Python helper checked actual receipts/code through JSON-RPC. Local diagnostic output is `/private/tmp/cc-mainnet-postflight-20261019.log`; helper `/private/tmp/cc-readonly-deployment-check.py`. Both exited 0. No full contract suite or fork rehearsal ran.

## Website

Actual site: https://cc.artcoins.art, Netlify site `bc71fdf3-3852-47ee-ae76-4053b530be09`.

Before repair the published deploy `6ad655284a3a28c0c20b99d5`, commit `d0c6b38bb7914c1b1cfe09f5b533b5d22f402361`, returned HTTP 200 but lacked Core/deploy-block settings and rendered "engine not deployed". Its web, engine package and npm input trees match `e713bb0`.

Public production build settings were derived directly from `deployments/1.json`: Core, deployment block 26229330, both adapters, pool hook, fee 8388608, tick spacing 200, and site URL. Readback matched. Netlify build `6ad68fb62ece5dc2317c52b2`, published deploy `6ad68fb62ece5dc2317c52b4`, commit `e713bb0`, became ready at 21:47:44 UTC. No Git push was needed.

Browser interaction on the real production site confirmed the Core/controller links and current mainnet head. The trade tab renders "$CC is not live yet" with no swap controls. `/keeper` shows zero bid/pots/buying room, the 0.1000 ETH processing reserve, and disabled buyback. The wallet was not connected and no transaction action was exercised. Indexer mode remains unaccepted until historical catch-up/parity checks pass; browser chain fallback remains available.

## Keeper

Fly app `cc-keeper-mainnet`, iad, one Machine `2869155c0291e8`, shared 1 CPU / 512 MB, encrypted 1 GB `keeper_state` volume `vol_rkgo99q6exeq8864` mounted at `/data`.

Image `registry.fly.io/cc-keeper-mainnet:d5be6e5`, digest `sha256:dab436f71ee653b9b370c070658d00f4b75b5d21228e4347c2db089d22c75305`. Public configuration including native credential mounts is committed at `01646d7`; `d5be6e5` sets umask 077 and chmod 600 before Node startup. Actual hosted stat readback confirmed both credential files are mode 600, root owned. Startup fixture checks cover permission tightening, keyless startup and refusal before npm when the mounted password is missing. The image entrypoint forcibly sets `DRY_RUN=1`, even if Fly environment values change. Hosted logs at 22:02:38 UTC confirm signer `keystore`, the expected address below, `dryRun:true`, OpenSea API and alerts enabled. Credentials decrypt in memory; no signing or sending occurs in this mode. The hosted `/app/deployments/1.json` SHA-256 is `ab8ce2301d9e5d5883196f2e0b9c9446c06363946236a81cf777078e754fbe3a`, exactly equal to the canonical local file. Live Machine configuration readback confirms one keeper with the expected record, signer, durable volume and DRY_RUN=1; the indexer readback confirms chain 1, the same Core/coin, Core block 26229330, collection/strategy start blocks, caps and v3 schema.

Dedicated signer `0x6b9411DD51DF1E41015cD8293C1BBC3E881a4aee`: three independent endpoints (MEV Blocker, Flashbots, PublicNode) reported balance 0 wei and nonce 0 at block 26,229,388. Both relay endpoints answered chain-id-1 read calls. Their transaction-submission behavior remains untested. Recommended initial funding target is exactly 0.100000 ETH; the measured shortfall to that target is exactly 0.100000 ETH. This is an operating float, not an exact gas requirement or guaranteed minimum for unknown future transactions. The configured low-balance threshold is 0.05 ETH. Fresh real balance/nonce reads at 22:32 UTC remained 0 wei / 0. Funding was not performed.

A local true no-send tick against real mainnet at block 26,229,387 decrypted the existing keystore, discovered 12,130 Strategy listings and selected no calls. Real hosted ticks make the same empty-pot decision: acquisitions wait at reserve, buyback has NothingToBuy, compose is NotReady, booking waits because the factory has not recorded launch, and reference refresh waits because no balance pool key is set. Live hosted logs show `decided:[]`, `sent:[]`, including advancing mainnet blocks 26229554, 26229555 and 26229556 at 22:17:27, 22:17:39 and 22:17:51 UTC. Existing local services in `.claude/worktrees/stack-master-ui` were preserved.

The approved OpenSea credential was transferred from the website's existing Netlify store directly into the keeper Fly secret store through subprocess memory/stdin. Hosted OpenSea reads fetched 300 listings; the current sample had no adapter-compatible orders (restricted order types and unapproved recipients). This is working discovery, not proof of an executable future order. Adapter restrictions were not loosened.

## Alerts

The owner approved reusing the existing Midway ntfy topic. Its secret URL was recovered through an isolated temporary sleep-only Machine, with no services or mounts, using authenticated SSH output captured only in subprocess memory; it was then imported to the CC Fly secret store. The helper was destroyed; the original Midway Machine remained stopped and unchanged. No secret URL was printed or saved.

Actual automatic production empty-pot alerts were found in topic readback, including message IDs `4xa99jFtgfNm`, `2IAGqkH8KyDH` and `TrCKYyepQ9ji`, with `source:cc-keeper`, `key:reserve`, pot 0, reserve 100000000000000000. The readback returned HTTP 200.

A manually triggered, explicitly SYNTHETIC readiness alert was sent from the hosted keeper image. The real ntfy endpoint returned HTTP 200, message ID `zybUb1jMpVKU`, and the event was confirmed by topic poll readback. This proves server receipt/readback, not receipt on the owner's phone.

A separate explicitly SYNTHETIC loopback test on the hosted production image returned HTTP 503 once. The shipped alert module reported the refusal and automatically retried to HTTP 200 after its retry interval. Result: `httpStatuses:[503,200]`, `refusalReported:true`, `automaticRetrySucceeded:true`, exit 0. It changed no running keeper state and sent no external failure-test message.

## Indexer: acceptance still pending

Fly app `cc-indexer-mainnet`, iad, one 1 GB Machine `815693c9070948` (initially one shared CPU, raised to four within the approved budget). Dedicated database app `cc-indexer-mainnet-db`, Machine `895902c6440568`, shared 1 CPU / 1 GB RAM, 10 GB encrypted volume `vol_vxmzoo9wygjdkqw4`. Database/user `cc_indexer_mainnet`, with CREATE permission only on its own database, and DATABASE_URL held directly in Fly secrets. Existing unrelated database/services were untouched.

Configured Core source starts at block 26229330. Global historical sources retain their actual collection starts: Credits 26037292, Statements 26100733, Strategy 26037623. These earlier sources supply real token ownership/facts; they are not synthetic Core history.

Initial production startup exposed missing database CREATE permission; repaired with the scoped GRANT and verified `has_database_privilege(...,'CREATE') = true`. The first partial schema `cc_mainnet_v1` is preserved.

Production logs then showed a provider-limit error and stalled indexing at 34 events / 1121 RPC requests. A focused mock reproduced 24 physical requests in one second despite an 8 RPS setting: Viem fallback rebuilt each child transport, creating a fresh Ponder limiter each time. Commit `24b9c8c` shares one queue per endpoint and disables internal HTTP retries which otherwise bypass the queue. Ordered failover remains intact. The regression failed before repair and passed after; 4/4 focused RPC/selection tests and indexer typecheck passed. Independent read-only review found no launch-critical defect. Limits apply per transport/Machine, using Ponder calendar-second buckets.

Ponder rejected reuse of the first schema after the app build changed. Configuration commit `ae27287` selects fresh `cc_mainnet_v2`; the original schema/data and RPC cache remain preserved. The v2 deployment passed process health but did not catch up. Observed 102,263 Credits Transfer logs and 80,065 distinct IDs within the inspected first 1,887 source blocks exposed the cost of single-token hydration. Completed handlers remained slow even while the fetch cache advanced. Commit `4e0c8f0` batches the current token with up to 64 unique actual same-block peers, validating exact collection, block hash, event topic and current ID before hydration. It retains original ordered owner/state updates, DB rollback/retry behavior, immutable facts and event-block metadata reads. The same commit rotates initial requests across the six existing public endpoints, sharing each concrete limiter across fallback rotations; optional paid reserve remains last and is not configured. Caps remain 8,8,5,10,5,5; HTTP retries are disabled. Nine focused helper/RPC/selection tests and typecheck passed, and independent frozen-file review passed. No contract behavior changed.

A fresh `cc_mainnet_v3` schema preserves v1/v2 and the existing RPC cache. The canonical `indexer/deploy.sh mainnet` deployment exited 0, image `registry.fly.io/cc-indexer-mainnet:deployment-01M5B41KFBSCTBDVHXKKACW2SC`, digest `sha256:fdbb6592470d508db81338fa646076af1f603fee2e21b2b6d0496a33e20f338a`, source `4e0c8f0`. Actual build context was 356.91 KB and dependency layers were cached. V3 started historical processing at 22:21:26 UTC, with /health 200 and /ready 503 while incomplete. At 22:22 UTC it had processed 322 Credits Transfer events and 1,188 historical seconds; the fetch head was already 26041930. This is real handler progress, not acceptance. Provider failures are visible in /health/rpc and logs, notably 1rpc.io errors and PublicNode historical-call errors; no paid reserve is silently used.

V3 subsequently stalled at 1,026 completed transfers / 1,248 historical seconds. Read-only diagnostics found no blocked SQL queries, ungranted locks, disk or CPU pressure; there were only PostgreSQL sockets and no active HTTPS sockets. The precise unresolved promise was not identified. Two bounded offline mixed-failure/timeout/burst probes did not reproduce a queue deadlock. A mistaken header-only-timeout hypothesis was withdrawn after checking the actual shipped viem 2.57.7 implementation, which includes body reads within its abort timeout.

Commit `812364f` adds an independent 20-second rejection deadline inside each rate-limited physical worker, aborts the underlying request on expiry, and exposes queued/active/last-started/last-settled counters. It preserves caps, reserve ordering and deterministic-revert behavior. Four focused RPC tests, typecheck and independent frozen-file review passed. The new synthetic test proves a fetch that ignores abort releases logical limiter slots and lets queued calls/fallback settle; it does not prove an uncooperative underlying socket closed. The canonical deployment exited 0 with fresh preserved schema `cc_mainnet_v4`, image `registry.fly.io/cc-indexer-mainnet:deployment-01M5B4N9CWVQGRMRSXETATMWTQ`, digest `sha256:3a6a6c5604f81c27c2112853ddb8096e129209b84d77ee51435e2e216d956930`. At 22:33:10 UTC it passed the previous stall at 1,218 completed transfers / 1,272 historical seconds, with fetch block 26045074. Final catch-up/parity remain pending; a restart progressing alone does not prove the original cause resolved.

Commit `7a3daa5` reduces a full uncached 64-id peer group from about 19 split wire calls to three by passing an optional 16,384-byte summed-subcall batch size only on that bounded path. Other callers, including composition, keep the default. Existing peer-bound/reorg tests (4/4), caller typecheck and independent frozen-file review passed. Actual Fly reads decoded matching 128-element score/traits results on Tenderly (3.84 seconds) and Blast (2.40 seconds), plus 128 successful historical URI/owner results on Tenderly (7.21 seconds); the URI ABI response was about 433 KB binary / 867 KB JSON, below the default 10 MB response cap. Aggregate calldata was 28,740 to 32,836 bytes despite the smaller summed-subcall setting. Historical CreditScore calls were invalid before that helper existed; production correctly retains latest-state immutable reads for that stage. Six earlier local-Mac probes and these three Fly probes are distinct evidence. No gas estimate or proportional wall-time improvement is claimed.

The canonical v5 deployment exited 0: schema `cc_mainnet_v5`, image `registry.fly.io/cc-indexer-mainnet:deployment-01M5B518F4HC06GGMYQRP2DQ5D`, digest `sha256:fd3ecf5d0c88329dc2f38e7d633354e195938dcaf986467ce19f2ffceb5f4e6d`, source `7a3daa5`. Earlier schemas and the RPC cache remain preserved. V4 had reached 2,445 completed transfers by 22:37:56 UTC before the update; none of these partial checkpoints is a ready/parity acceptance.

The owner corrected the transport policy: always use Tenderly first and throttle requests. Commit `8fec8f8` removes the initial rotation and restores fixed ordered fallback, with Tenderly capped at four physical requests per second and one active request. Shared endpoint queues, independent physical deadlines, deterministic-revert stop, zero hidden retries and reserve-last behavior remain. Four focused RPC tests, typecheck and frozen-file independent review passed, including 24 concurrent constructor requests reaching only the healthy primary at the configured cap. Production schema `cc_mainnet_v6` preserves earlier schemas and the existing cache. Its canonical deployment exited 0, image `registry.fly.io/cc-indexer-mainnet:deployment-01M5B5JY842DKRBXMGPX39TR6Q`, digest `sha256:df8063fd1f86e637ea91f606d01bc752e0ae42967dd0cdf52faf5b8c3f93ef3f`. Actual Machine readback confirms four shared CPUs / 1 GB, schema v6 and caps 4,8,5,10,5,5. At 22:48:53 UTC, the new process had 114 Tenderly requests, no errors and no fallback requests; at 22:51:02 it had 626 Tenderly requests, still zero errors/fallbacks, with 1,928 completed Credit transfers and fetched block 26053900. This is sustained actual primary traffic at the cap, not final replay/parity acceptance.

A live Fly CPU sample found 30.8% steal, 65.3% idle and 4.4% Ponder CPU use over 10.162 seconds; guest cgroup CPU quota was unlimited with zero cgroup-throttle periods. Host scheduling/credits can contribute, but were not proven the sole cause of latency. Four shared CPUs pool a 25% baseline instead of 6.25%; the same Machine keeps 1 GB RAM and no replicas. The estimated total capacity cost becomes about $20.82 per 30 days, within the approved $30 budget, before variable charges.

Keeper production RPC order was already Tenderly first. The website default was actually dRPC when no public RPC was set; the earlier claim that it already started at Tenderly was corrected. Netlify production NEXT_PUBLIC_RPC_URL is now explicitly the public Tenderly URL. Build `6ad69dfa798143d17ad3426f` / deploy `6ad69dfa798143d17ad34271`, source `e713bb0`, published ready at 22:48:35 UTC. A fresh real-browser reload showed the expected Core/controller links, head 26229721, zero pots/bid/room, reserve 0.1000 ETH and disabled buyback. The local source default and example also use Tenderly. No secret URL or Git push was involved.

Next action: finish the historical backfill, then require real `/ready`, fresh `/health/parity`, exact SQL Core/coin/deploy-block identity and state agreement, and indexed head within five blocks using `RPC_URL=<mainnet read RPC> indexer/check-live.sh mainnet`. No indexer acceptance is claimed yet.

## Focused verification and limits

- Keeper ops/executor: 26/26 synthetic tests and typecheck; isolated production workspace install/config loading passed. Independent review of packaging, context allowlist and credential mounts passed. Actual remote builds uploaded only about 443 KB keeper and 345 KB initial indexer public source, excluding `.git`, other worktrees, dependencies, credentials and `.env` files.
- Keeper decision/snapshot tests: 34/34 passed; alert-specific local tests: 3/3 passed. These are synthetic, separate from the real mainnet ticks and real topic delivery above.
- Indexer deploy guards and shell syntax passed; web indexer identity gate test passed 1/1. These do not establish production indexer readiness.
- Initial keeper build failed before upload because paths were resolved relative to the Fly config directory; fixed in `5a3e8e4`. The oversized-root warning was not treated as permission to upload. Automatic review blocked the first paid DB provisioning until the owner approved the stated budget, and blocked OpenSea/keeper credential transfers until their specific approvals. Subsequent transfers followed those approvals. These failures are preserved as failures.
- Source commits so far: `950324e`, `9729c7d`, `5a3e8e4`, `01646d7`, `24b9c8c`, `ae27287`, `d5be6e5`, `4e0c8f0`, `812364f`, `7a3daa5`, `8fec8f8`. No Git push.
- Prior Core-only waivers do not approve coin launch. Existing coin/service freeze records remain pending; no acceptance or test waiver is converted into a pass here. Post-launch fee ingestion, actual keeper paid execution/receipt accounting, buybacks, and coin/pool website transitions remain unproven until authorized launch/use.

## Cost and owner actions

Initial ongoing capacity was approximately $18.74 per 30 days before traffic, builds and snapshots, using Fly's published iad rates: two 1 GB shared Machines at $6.70 each, one 512 MB at $3.69, and 11 GB of volumes at $0.15/GB. Sources: https://docs.fly.io/about/pricing and https://fly.io/pricing-update/ . CPU pooling and steal limitations: https://docs.fly.io/machines/cpu-performance . With the indexer at four shared CPUs / 1 GB, the current estimated total is approximately $20.82 per 30 days. This is an estimate, not a hard billing cap; the owner approved $30/month and $5 total setup/build retries. No HA replicas or dedicated paid IPv4 were requested.

Current coin-launch verdict: NO-GO for fully automated operation while the keeper is unfunded/disarmed and separate coin-launch approval is absent. Decision 228 defers historical indexer acceptance; it is no longer a standalone coin-launch blocker. Minimum later owner actions include funding the dedicated keeper to the stated float, explicitly approving keeper arming/transaction sending, and approving the separate coin-launch release gates. This task authorizes none of those actions automatically.

### Website RPC API follow-up (2026-10-19)

Owner requested server-side website reads and rejected an extra persistent RPC broker as overcomplicated. Mainnet wagmi now uses only `/api/rpc`; local Anvil and wallet signing retain their transports. Metadata/listings server reads share the read-only dispatcher. Tenderly is first, with physical pacing at four requests/second and two concurrent requests per warm Netlify instance, bounded queues and a 20-second total deadline, identical-read deduplication, short live caches and bounded historical caches. The API refuses send/sign/admin methods. It bounds request bodies, batches, log ranges/topics, upstream response bytes and cached bytes. Netlify instances have independent budgets; this does not guarantee a global quota or public-provider availability.

Focused synthetic verification: new RPC proxy tests 10/10; affected history self-check and listings route test pass; web TypeScript passes. Independent review found and repaired the 23-topic compatibility bound, response/cache byte limits and queue-wide deadline. No full contract suite or fork rehearsal. Production deployment and browser verification remain pending at this checkpoint.

Indexer 8-RPS experiment `e824f5e` initially recorded 2,602 successful Tenderly requests and zero errors, then all read methods began receiving generic limit errors. Actual logs include `eth_call`, `eth_getBlockByNumber` and `eth_getLogs`; this is not solely a log-range defect. Exact provider quota/window is unproven because the existing log records only Viem's generic first line. `74102cf` restores the previously stable four-RPS primary cap on the same v6 schema; recovery is still being verified. Retained SQL rows (5,996 events, 5,825 Credits) and Ponder safe checkpoint 26,037,436 survived the previous restart. In-process counters reset; long historical batches commit together. `/ready` remains 503 and Core parity is not yet available.

### Published website API and conservative indexer readback

Website `b214fba9e44c3bf023a3ead8c2b198c9fe0c347f` is live at `https://cc.artcoins.art`, Netlify production deploy `6ad6a3e1402cbc8653b86203`. The official Next Runtime 5.16.3 build passed once in 34.7 seconds. The inspected CDN artifact contained 230 files / 6,508,787 bytes and no upstream RPC URL/server RPC environment references; the 8,723,308-byte handler zip had no secret-file matches. Live client bytes match that artifact. Two pre-upload CLI failures were retained: `--context` is incompatible with `--no-build`, and its two-minute function-manifest cache aged during inspection. Reusing the unchanged inspected zip with refreshed generated cache timestamp published successfully; no second product build, Git push or source alteration.

Actual production `/api/rpc` batch returned HTTP 200 in 1,126 ms, preserved all IDs and reported chain 1, head 26,229,832, the recorded `Core.COIN()`, zero `ethPot()` and no predicted-coin code. A labelled synthetic unsigned send-method request was rejected HTTP 400 / -32601 before upstream dispatch. Browser acceptance loaded the keeper's real zero pot, 0.1000 ETH reserve and correct Core/controller at head 26,229,830, then exercised the home trade tab showing `$CC is not live yet`. The new browser session reported no `/api/rpc` warnings/errors. Post-launch swaps and fee-driven pot changes remain unproven. Existing live snapshot interval is 15 seconds; a confirmed local transaction invalidates queries, and live API caches last at most three seconds.

Restored four-RPS indexer image: `registry.fly.io/cc-indexer-mainnet:deployment-01M5B6PN9AGZ0E4BYQXG8RWW2G`, digest `sha256:7c28b952e4e1a3c6f47596967fbe440083b23585b5b5e6b6d1de9b0d9406d262`, source `74102cf`. Same v6 schema resumed. Reducing the cap did not clear Tenderly's refusal: one explicit read from the actual Fly host returned HTTP 429 / -32005 `rate limit exceeded`, while the same harmless mainnet-head read succeeded from the Mac. The owner has no dedicated Tenderly endpoint. Public Tenderly remains first and fallbacks continue advancing; the precise quota/window is unproven. Tenderly documents IP-based public access and a 1 GB daily response-data limit: https://docs.tenderly.co/node-rpc/overview#public-endpoint-limits . No IP/quota bypass was attempted.

The keeper continued actual no-send mainnet ticks through block 26,229,816, each with zero pot, 0.1 ETH reserve and `decided=[]`, `sent=[]`. Indexer at the latest checkpoint remained backfilling, with process Credits transfers 4,577 and fetch head 26,071,175; `/ready` still 503. Website success does not close this service-readiness blocker.


### Temporary Alchemy fallback and spending constraint

Owner approved reusing the Artcoins site's existing Alchemy credential for CC,
then required restrained billing. The credential was transferred only in memory
from its existing Netlify store into Fly `RPC_FAST_FALLBACK_URL`; no credential
value or full URL was printed or saved. Source `6f46ac8` keeps Tenderly first,
adds Alchemy as the first fallback at four physical requests/second, and sanitizes
all upstream error chains before logging. Config-only changes leave the v6
indexing build inputs and database/cache intact. Focused config tests 3/3,
TypeScript and independent source review passed. Canonical deployment exited 0:
`registry.fly.io/cc-indexer-mainnet:deployment-01M5B8H225Y0PTRBMBWZ95ZEY8`,
digest `b241bf59aa584b13ba1a2d3f9765cb05cd663e786fd22e991ef81895a712fce6`.

Actual host checks before activation: historical Credit URI succeeded in 73 ms;
a 64-Credit aggregate returned 128 valid decoded URI/owner results, 867,430 bytes,
in 508 ms; a 5,000-block empty Transfer log range succeeded in 487 ms. These were
manual read-only probes, not synthetic chain events. At 23:52:14 UTC production
showed 3,006 Alchemy requests, zero errors; completed methods were 2,562 block
reads, 361 log reads, 82 calls and one chain ID. Other public fallbacks had zero
requests; Tenderly continued refusing reads. This mix is about 75,092 compute
units under the published method table, or about $0.034 at standard PAYG rates.
A conservative 60-CU bound including five manual probes is below $0.082.
Sources: https://www.alchemy.com/docs/reference/compute-unit-costs and
https://support.alchemy.com/articles/2300474614-understanding-alchemy-s-pay-as-you-go-billing-model .
Account plan, total shared usage and billing caps are unverified; this is not
an invoice or a claim of free service. Four RPS alone does not cap total spend.
The operator limit is fewer than 30,000 calls for this run (stop process counter
by 29,995 to include probes), about $0.81 at the conservative standard-rate bound.
Remove the temporary fallback on catch-up or when that limit is approached.

Actual production log at 23:51:40 committed 5,775 events for block range
26,037,627 to 26,037,714 after 11m55s. Ponder commits its public safe checkpoint
only after an entire historical event range; PostgreSQL showed no lock waits.
Increasing event counts and the actual commit prove progress, but not completion.
Core parity is still unavailable and `/ready` remains 503. Remaining early NFT
hydration and later historical fetching may exceed this run's usage limit;
completion within the limit is not promised. Do not reset counters through restarts or truncate indexing to meet this limit.

### Artcoins discovery and trading dependency

The actual live site is the local main repository `/Users/dd/CascadeProjects/artcoins`
at published source `d06d29c`, Netlify deploy `6ad1b0fce9dd865be40d02c8`.
Its generated V2 factory, hook, locker, escrow and ABI agree with the deployed
launcher snapshot, including factory `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`
at block 26,202,473. The swap flow validates the locker pool key and pool ID,
quotes/simulates before submitting, supports native ETH/CC, and uses mainnet
wallet checks. The site's create freeze does not disable trading. No site code
or deployment changed in this repair.

Its old Fly indexer was healthy but watched the old factory/event ABI and stored
PGlite outside `/data`; its empty successful coin list suppressed chain fallback.
The owner explicitly authorized preserving/verifying data and repairing this
separate indexer. Actual source `36d5238` is now deployed on existing Machine
`9080d229ae5387`, volume `vol_4qlz8we159p8l3gr`, app `artcoins-indexer`, iad,
shared one CPU/1 GB. Image `deployment-01M5B91337881KSQ85Q6448B3R`, digest
`4653ab025823b1819b2b700c280b3e87bac77e5718d80cce3922eafd1da85502`.
It uses `/data/pglite`, fresh schema `artcoins_v2_20261019`, correct C27e factory
and event ABI, 12-second polling and Tenderly first. No extra Alchemy credential,
replica or capacity was added. Focused config tests 2/2, TypeScript and independent
source/storage review passed; the canonical deployment exited 0.

Preservation was real, not a fixture: capture at 23:42:02 UTC under the running
PGlite transaction/query locks after checkpoint/sync, with source tree unchanged.
The 81,891,328-byte archive SHA-256 is
`c18320f1f4ede79185f9cfc03cee10939dc0cfaceca3e6970fec3ed55d125852`.
An identical PGlite 0.2.13/WASM Mac restore matched all 35 table counts, checkpoints
and build metadata. Active and separate rollback volume copies matched tree
`68fa8efd14ce38b628c00d61d081b0449376708b1858747207a1eb3172e523ed`
and were synced. A first snapshot attempt failed before locks/capture because
inspector evaluation could not use dynamic import; module resolution was fixed
and reviewed before the successful capture. An earlier memory-heavy Blob export
was rejected in local profiling before production; the successful capture streamed
tar under the locks. No inconsistent live-directory copy or second live database
opener was used.

Actual post-start readback through the existing instance verified all old `public`
counts/checkpoints/build metadata unchanged (145 burns, nine claims, two tokens),
`ponder_sync` retained, and the new schema independently rebuilt the same legacy
counts. The loopback inspector was closed and independently checked. Separate
rollback copy `/data/rollback-v35` and immutable archive remain; old image rollback
needs an explicit symlink because v35 ignores the new directory variable. The
Artcoins indexer README records the exact rollback image and identities.

Production acceptance: `/health` and `/ready` 200; checkpoint 26,230,021 to
26,230,022 across 12 seconds, mainnet head 26,230,023 (lag one); all 19 website
GraphQL coin fields returned a valid empty prelaunch list; website `/api/coins`
returned 200. Latest 100 production log records through 23:52:35 contained no
error/fatal/migration/OOM matches and showed continuing blocks 26,230,024 to
26,230,028 at roughly 12 seconds. This repairs the actual discovery dependency.

Actual CC launch-event insertion, listing, pool reads and executable quote remain
unproven until launch. Existing site caches can delay discovery; an already-open
list needs Refresh/reload. No predicted-coin page was queried before launch, to
avoid populating its negative caches. No synthetic event or blockchain transaction
was sent. Factory launch atomically creates the coin/pool and emits the event;
there is no extra pool-launch transaction to perform. The 69% to 6.9% initial fee
schedule is a trading cost, not a trading lock. These parameters come from the
actual deployed factory source/ABI, not the stale nested contracts checkout.

### Final live service delta and historical acceptance deferral (2026-10-20 UTC)

Owner decision 228 permits coin launch during historical NFT replay, provided the live website chain fallback through its API, keeper decisions and alerts pass against the canonical Core. Full indexer acceptance remains deferred, never passed. RUNBOOK and SPEC were updated; `check-live.sh` retains all its acceptance checks for enabling indexed data. No collection source was truncated and no schema/cache was removed.

Keeper repair `d803bea` bounds OpenSea RPC batches to 20, shares per-endpoint four-RPS pacing, falls back in configured order, validates envelopes/IDs/results, preserves deterministic owner reverts, and reports fulfillment authorization errors while retaining good cached orders. Focused OpenSea tests passed 9/9 and keeper typecheck passed; independent immutable-file review passed. Image `registry.fly.io/cc-keeper-mainnet:d803bea`, digest `9bc7bbc6b10c906a65801e3a71e9573b82315c08a81cd0f1a0ad64800c55403d`, is live on the same machine/volume. Its unchanged image entrypoint forces DRY_RUN=1. Actual startup at 00:43:15 recovered the keystore signer; 00:43:33 refresh fetched 300 listings, 289 eligible and 40 usable fulfillment orders. Actual ticks at blocks 26,230,282 through 26,230,286 had pot 0, reserve 1e17, decided=[] and sent=[]. Paid execution and receipt accounting remain unproven until separately authorized use.

Credential correction: Netlify non-development secret readbacks are masked/write-only. The earlier comparison of a Netlify API value with Fly therefore did not establish a valid original secret transfer. The old Fly fulfillment returned INVALIDKEY; this does not establish that the original Netlify credential itself was invalid. The owner supplied a new key, which was read-tested from Fly (GET 200 and one fulfillment POST 200), then explicitly approved saving it in both production stores. Fly staging and Netlify production-only PATCH succeeded, preserving other contexts, scopes and secret classification. A memory-only comparison verified the active Fly value equals the supplied key. Netlify plaintext readback is unavailable by design; actual live website acceptance returned 200 listings and one manually triggered, read-only fulfillment HTTP 200 with parameters. No website rebuild was needed. Automatic approval review had rejected the initial persistence attempt under test-only authority; no write ran before the owner's specific persistence approval. Rotate the chat-exposed OpenSea key through the provider and these stores after setup. See https://docs.netlify.com/build/environment-variables/secrets-controller/ .

Indexer boost `1019462` and narrow HTTP-429 correction `801be6f` use only config-level transport code, preserving Ponder's serialized hashed configuration fields, schema and 13 indexing source files. Focused configuration tests passed 8/8, TypeScript and diff checks passed, and independent review passed. The first boost deployment preserved v6 but failed to back off: live counters showed one Tenderly error for each Alchemy request. One real read from Fly proved HTTP 429 with JSON-RPC -32005; installed viem discards HTTP status when returning a valid JSON-RPC error. The repair observes the HTTP response before conversion and has an exact regression for this case; HTTP 200 with the same RPC error does not trigger cooldown. No broad suite or fork rehearsal ran.

Final image `registry.fly.io/cc-indexer-mainnet:deployment-01M5BCBRJZTPD996N3WGXNY1HK`, digest `ddf6fecd6bc735f14b89880bd4bc6ba69fc1e8aa112f95e52d885cb0056b0dfb`, is live on the same machine/schema/DB. A read-only SQL query of the retained v6 metadata returned build ID `33c90dbe34`, is_ready=0; Ponder accepted the existing schema and preserved its checkpoint. At 00:47 actual counters advanced 80 successful Alchemy requests over 10.08 seconds, zero Alchemy errors, while Tenderly was in its 30-second confirmed-429 cooldown. Tenderly remains first outside cooldown. The absolute paid expiry is 2026-10-20T01:04:00Z, max 10,000 physical calls per process, eight RPS; checks occur inside the physical limiter, and no Alchemy reserve can bypass them. The 00:44 baseline was 15,428 calls including probes. The fixed window plus restart margin bounds cumulative calls at 25,136, roughly $0.679 at the conservative 60-CU standard PAYG bound; actual account billing remains unverified. Expiry was not extended during the corrective restart; public fallback continues after expiry. At 00:47:39 the new process had 555 Alchemy calls and zero errors. At 00:48, fetched block 26,108,519 means 71,228 fetched blocks and 121,786 remaining against head 26,230,305; the committed checkpoint remains 26,037,796. Fetch progress and per-process events are not committed full acceptance. `/ready` and parity remain unproven.

Fresh real website API batch at 00:45:59 returned HTTP 200, chain 1, head 26,230,295, canonical Core.COIN, zero pot and no coin code. Keeper balance is exactly zero, shortfall to the recommended operating float exactly 0.100000 ETH; this is not a universal transaction gas minimum. Previous production browser acceptance of chain fallback remains valid because the web executable artifact is unchanged. Public reads stay behind `/api/rpc`; live pot polling is 15 seconds plus network/cache delay, not instant per-swap streaming. Postlaunch fee ingestion and the coin/pool UI transition are unproven.

Fresh Artcoins health/ready returned 200 at checkpoint 26,230,299; its live `/api/coins` returned HTTP 200. Actual CC discovery/quotes remain postlaunch proof. The correct V2 factory launch creates the pool atomically; discovery polls every 12 seconds, website caches add delay, and an open list needs refresh. No promise of instant discovery was made.

Preserved deployment failure: the keeper build-only image was not published, so an attempted exact-digest deploy failed before changing the machine. A subsequent cached build published the identical digest and deployed successfully. No cache clearing, extra capacity, Git push, blockchain transaction or wallet funding occurred. Historical acceptance deferral changes only that prelaunch condition; pending coin e2e/final review/owner acceptance are not silently converted to passes.

The deferred-acceptance caller repair in `indexer/check-live.sh` accepts an actual JSON coinLive boolean and requires matching on-chain code (false: exactly 0x; true: nonempty valid bytecode). Chain/Core coin identity, readiness, parity, SQL, head, pile and pot checks are unchanged. Nine labelled offline shell fixtures, bash syntax and diff checks passed; independent frozen-file review passed. These are synthetic command fixtures, not a live indexer acceptance pass. The deploy script message now instructs acceptance before using indexed data. No service redeploy is required for these operator-only changes.

At local revision `95fa7a1`, the existing record-only freeze checks were run without test execution: `script/tools/check-freeze.sh coin` and `script/tools/check-freeze.sh services` both exited 1. Existing suite/deep/rehearsal records were recognized; candidate still points to f6a5c69 and coin e2e/review/acceptance/services rows remain pending. This is an unresolved release record, not evidence of a new contract failure. No pending gate or deferred result was changed to a pass. The affected service delta review is being recorded separately; funding, arming and coin-launch authorization remain outside this task.

Final scoped service delta review at candidate `95fa7a1` passed and is recorded in `SERVICE-DELTA-95fa7a1-2026-10-20.md`. The freeze table now preserves the original Core candidate/approvals under Core scope and freezes the current executable inputs for coin/services; only the scoped service review row is passed. Coin e2e/final review, services acceptance and coin owner acceptance remain pending. At 00:52:45 actual CC checkpoint advanced to 26,037,870 with 3,000 successful Alchemy calls, zero errors and eight RPS in this process, proving a new committed batch under the boost.


## Keeper full-book and incremental discovery, 2026-10-20

Commit `9e92a13` deployed successfully to the existing keeper machine and 1-GB volume, image digest `ededc4fb05c5f6af1bc4aacca7294f294ff0aa85a50d465cf088489f800c7365`. Actual hosted logs at 01:16:24 UTC traversed 35 pages / 6,999 listings, ranked 6,937 compatible orders and prepared 40 usable fulfillments; the 62 excluded rows were 60 restricted orders and two non-native-ETH orders. A second actual scan at 01:22:50 traversed 36 pages / 7,082 listings, with 7,013 compatible orders and 40 prepared. This confirms that the book changes during operation; a completed scan is not an atomic market snapshot. The 17,332-entry score cache at 01:15:43 was stored on `/data` with mode 600 and exact chain/Credits/CreditScore identity; it grew to 17,411 entries on the next scan. Deployed Sources and SDK hashes matched the reviewed local files, and the canonical deployment record SHA-256 remained `ab8ce2301d9e5d5883196f2e0b9c9446c06363946236a81cf777078e754fbe3a`. Later real ticks continued pot zero, reserve 0.1 ETH, decided/send arrays empty. Independent frozen-code review accepted full-book discovery, with explicit top-80 validation / top-40 preparation limits.

The owner rejected repeated complete scans as the steady-state design. The incremental replacement keeps the complete compatible catalog in the same keeper process, consumes a Credits-only OpenSea WebSocket feed, applies bounded canonical order reads for positive updates, removes known cancelled/invalidated orders without REST reads, reuses fulfillment data for unchanged hashes, prunes expiry locally, and reconciles periodically or after stream gaps. Scores remain durable and immutable; the live catalog is rebuilt after restart. Stream events are hints rather than price or execution authority. Existing per-block owner/status/adapter checks and final simulation remain mandatory, and the image still forces `DRY_RUN=1`. No new service, capacity, database, paid RPC endpoint or Alchemy usage is added. Shared API pacing and provider Retry-After apply across passes. Streaming is best effort with no replay, so queue/gap state is exposed and reconciliation remains necessary.

Two labelled manual read-only production probes used the already-approved OpenSea key only in the Fly process environment. A native Node WebSocket opened, joined `collection:credits`, and acknowledged a heartbeat. The first 40-second observation saw nine listing events, one sale, one transfer, 2,492 cancellations and 2,975 invalidations, plus bids before server filtering. A second 20-second observation using the six-event filter confirmed the topic and payload collection as Credits and saw 1,358 invalidations, 4,441 cancellations, one listing, one transfer and one sale; foreign NFT identities were rejected. These actual cancellation bursts justify ignoring unknown negative events instead of issuing one REST request per notification. Two paced REST reads returned HTTP 200 and confirmed that the canonical single-order endpoint wraps its current listing in `{order: ...}`, with matching Ethereum/hash/Seaport/Credits identity. These were probes, not hosted-listener acceptance or purchases.

Focused SDK verification passed 26/26, including the entire 401-order catalog, a better price-per-point order beyond the former 300 cap, exact integer ranking, warm passes with zero API/fulfillment requests, new-order updates, canonical identity rejection, atomic failure retention, 404 indexing lag, shared pacing, and 20,000 zero-REST removals. Focused Sources/ops verification passed 26/26 in 2.32 seconds, including cached scores across restart, real HTTP-429 Retry-After shape, cancellation-flood coalescing, transfers during an asynchronous baseline, overflow fencing and existing signing/budget/alert protections. The initial Sources run cancelled one obsolete synthetic-backoff fixture; its arbitrary network error had a non-HTTP retryAt, which the safe SDK correctly did not trust. The corrected fixture exercises actual HTTP 429/Retry-After and passes. TypeScript and diff checks passed. No full contract suite or fork rehearsal ran. Independent delta review found and repaired transfer-publication and overflow-generation races before deployment. The stream lifecycle/parser checks passed 9/9, including malformed relevant events and failed callbacks requesting reconciliation while foreign events are ignored. Final independent frozen-input review passed SDK `853dffa3…`, Sources `7f331924…`, main `2972b183…` and stream `40ac68f2…`, with only live integrated acceptance remaining. Hosted incremental acceptance is pending at this candidate checkpoint.

At 01:33 UTC, a fresh read through `https://mainnet.gateway.tenderly.co` returned chain 1, keeper balance exactly `100000000000000000` wei (0.100000 ETH), and no coin code. The recommended-float funding shortfall is now zero. No funding transaction was initiated by this task. The fixed-expiry Alchemy counter remained 5,062 while Tenderly continued; `/health` was 200 and `/ready` still 503 for historical indexing. Artcoins `/ready` was 200. Historical CC indexer acceptance remains deferred by decision 228.

Decision 230 defers website marketplace listings until after coin launch. The five-file website sorting/batching/error-display patch is preserved in named stash `06036235a50a57214047724609409c69c5f2d318`, with browser acceptance pending, and is excluded from this keeper deployment; no shared website score API or public keeper HTTP service was added. Existing website Core reads, pre-coin behavior and production artifact remain unchanged. Keeper arming, actual funded execution/relay receipts, final coin review and owner coin-launch approval remain separate and unproven.


## Git auto-deploy and final discovery repairs, 2026-10-20

The owner's explicit instruction to use Netlify auto-deploy supersedes the original no-push condition for the verified service publication (decision 233). Remote docs commits were merged without losing their source/address changes. A prior automatic publish of `47688ff` had removed the unpushed RPC route, returning HTTP 404; the known-good deploy was restored before Git integration. After pushing `ee73d52`, automatic deploy `6ad6c83ec640a426b7947938` published at 01:48:43 UTC with auto-publishing enabled. Real browser acceptance showed the canonical Core/controller, zero pot/holdings/burn, 0.1 ETH reserve and pre-coin state at head 26,230,618, without console errors. Netlify is now deployed through commits/pushes; the final follow-up uses that same path.

Hosted incremental discovery was actually exercised. `97e1a8f` joined the collection stream, rejected a startup-overflow publication, recovered through a full catalog, then performed zero-page incremental passes with reused fulfillment parameters. `ee73d52` repairs repeated-removal acknowledgments. It deployed to the existing machine as image `opensea-live-book-ee73d52`, digest `85f9e97cd960d93e9a3165ffc5607e40c4d9bfbc1932f5c2132eff340f5b5702`. At 01:51:35 the actual recovered baseline traversed 53 pages / 10,605 listings, retaining 8,422 compatible catalog rows and 26 prepared orders. Subsequent 32-order incremental passes used zero collection pages and reused 26 to 34 fulfillments. Repeated negative queues drained, but positive notifications grew from 677 to 1,581 by 01:56, proving FIFO individual-order reads could lag under real traffic. Ticks remained pot zero, decided=[] and sent=[] under forced no-send. This is retained as a discovered limit, not a current-book acceptance pass.

The final narrow repair prioritizes native-ETH listing hints by exact price/cached score, with 24 preferred and eight unpriced slots per 32-order pass. At most 64 missing hint scores are read per pass; failed hint scores degrade to unpriced and cannot block discovery. Signed canonical terms and per-block validation still control purchases. Bulk queues above 128 trigger a collection reconciliation no more often than five minutes, within the existing one-REST-request/second limiter. Successful scans acknowledge only captured revisions; missing new listings and fresh-at-start revalidations remain queued for REST propagation. No extra paid RPC, capacity, service or dependency is introduced. Revalidated bids and NFT bundles are now excluded individually after strict identity checks instead of aborting the whole update; sanitized HTTP error names carry only numeric status codes.

Verification: SDK tests 27/27 passed; stream tests 10/10 passed; Sources tests 17/17 and keeper TypeScript passed. The observed-at-start acknowledgment refinement passed its focused regression afterward. An initial Sources run failed because an old synthetic market row omitted its required price; the fixture was completed and the corrected full affected file passed. Independent frozen-input review accepted SDK `4072c699...`, stream `30baa306...`, Sources `dea4db67...` and their tests. Existing transaction/signing code, financial constants and production contract inputs are unchanged.

The owner-reported website loading loop came from block-keyed listing queries with no initial successful data and no visible error state. Decision 230 keeps website marketplace listings deferred: feed and `/listings` now show a stable post-launch notice, and the header's hidden acquire-candidate query is removed too. No mounted website listing/acquire-candidate query remains; pot/current bid and manual trading are preserved. Web TypeScript passed. The local mainnet-value preview exercised feed Listings, Ledger and `/listings`; the message remained stable, other ledger behavior rendered, canonical links/pre-coin state/pot remained correct. Screenshot `/private/tmp/cc-listings-deferred-preview.png`. This is local UI acceptance; final production auto-deploy readback follows separately.

Published CI run `39355398345` failed on two confirmed fixture problems: the indexer shell fixture expected an obsolete prelaunch-only message and the contract smoke used current mutable Strategy ownership/prices for fixed IDs. The shell fixture now checks schema binding, actual SQL failure and both valid/invalid coinLive/code states. CI forks the already-verified candidate block 26,208,025 instead of latest-minus-100; no contract assertion or production setting changed. Seven affected Config/CoreUnit tests passed on public Tenderly at that block (1 Config + 6 CoreUnit, zero failures). An initial over-specific selector matched no tests and is not acceptance evidence. No full local contract suite or fork lifecycle was repeated. Final CI/publish/live results will be appended at the actual final commit.
