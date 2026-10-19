# Mainnet service activation, 2026-10-19

Status: in progress; indexer historical acceptance is still pending. No coin or pool launch, blockchain transaction, funding or Git push is authorized or performed by this service-activation task.

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

Dedicated signer `0x6b9411DD51DF1E41015cD8293C1BBC3E881a4aee`: three independent endpoints (MEV Blocker, Flashbots, PublicNode) reported balance 0 wei and nonce 0 at block 26,229,388. Both relay endpoints answered chain-id-1 read calls. Their transaction-submission behavior remains untested. Recommended initial funding target is exactly 0.100000 ETH; the measured shortfall to that target is exactly 0.100000 ETH. This is an operating float, not an exact gas requirement or guaranteed minimum for unknown future transactions. The configured low-balance threshold is 0.05 ETH. Funding was not performed.

A local true no-send tick against real mainnet at block 26,229,387 decrypted the existing keystore, discovered 12,130 Strategy listings and selected no calls. Real hosted ticks make the same empty-pot decision: acquisitions wait at reserve, buyback has NothingToBuy, compose is NotReady, booking waits because the factory has not recorded launch, and reference refresh waits because no balance pool key is set. Live hosted logs show `decided:[]`, `sent:[]`, including advancing mainnet blocks 26229554, 26229555 and 26229556 at 22:17:27, 22:17:39 and 22:17:51 UTC. Existing local services in `.claude/worktrees/stack-master-ui` were preserved.

The approved OpenSea credential was transferred from the website's existing Netlify store directly into the keeper Fly secret store through subprocess memory/stdin. Hosted OpenSea reads fetched 300 listings; the current sample had no adapter-compatible orders (restricted order types and unapproved recipients). This is working discovery, not proof of an executable future order. Adapter restrictions were not loosened.

## Alerts

The owner approved reusing the existing Midway ntfy topic. Its secret URL was recovered through an isolated temporary sleep-only Machine, with no services or mounts, using authenticated SSH output captured only in subprocess memory; it was then imported to the CC Fly secret store. The helper was destroyed; the original Midway Machine remained stopped and unchanged. No secret URL was printed or saved.

Actual automatic production empty-pot alerts were found in topic readback, including message IDs `4xa99jFtgfNm`, `2IAGqkH8KyDH` and `TrCKYyepQ9ji`, with `source:cc-keeper`, `key:reserve`, pot 0, reserve 100000000000000000. The readback returned HTTP 200.

A manually triggered, explicitly SYNTHETIC readiness alert was sent from the hosted keeper image. The real ntfy endpoint returned HTTP 200, message ID `zybUb1jMpVKU`, and the event was confirmed by topic poll readback. This proves server receipt/readback, not receipt on the owner's phone.

A separate explicitly SYNTHETIC loopback test on the hosted production image returned HTTP 503 once. The shipped alert module reported the refusal and automatically retried to HTTP 200 after its retry interval. Result: `httpStatuses:[503,200]`, `refusalReported:true`, `automaticRetrySucceeded:true`, exit 0. It changed no running keeper state and sent no external failure-test message.

## Indexer: acceptance still pending

Fly app `cc-indexer-mainnet`, iad, one 1 GB Machine `815693c9070948`. Dedicated database app `cc-indexer-mainnet-db`, Machine `895902c6440568`, shared 1 CPU / 1 GB RAM, 10 GB encrypted volume `vol_vxmzoo9wygjdkqw4`. Database/user `cc_indexer_mainnet`, with CREATE permission only on its own database, and DATABASE_URL held directly in Fly secrets. Existing unrelated database/services were untouched.

Configured Core source starts at block 26229330. Global historical sources retain their actual collection starts: Credits 26037292, Statements 26100733, Strategy 26037623. These earlier sources supply real token ownership/facts; they are not synthetic Core history.

Initial production startup exposed missing database CREATE permission; repaired with the scoped GRANT and verified `has_database_privilege(...,'CREATE') = true`. The first partial schema `cc_mainnet_v1` is preserved.

Production logs then showed a provider-limit error and stalled indexing at 34 events / 1121 RPC requests. A focused mock reproduced 24 physical requests in one second despite an 8 RPS setting: Viem fallback rebuilt each child transport, creating a fresh Ponder limiter each time. Commit `24b9c8c` shares one queue per endpoint and disables internal HTTP retries which otherwise bypass the queue. Ordered failover remains intact. The regression failed before repair and passed after; 4/4 focused RPC/selection tests and indexer typecheck passed. Independent read-only review found no launch-critical defect. Limits apply per transport/Machine, using Ponder calendar-second buckets.

Ponder rejected reuse of the first schema after the app build changed. Configuration commit `ae27287` selects fresh `cc_mainnet_v2`; the original schema/data and RPC cache remain preserved. The v2 deployment passed process health but did not catch up. Observed 102,263 Credits Transfer logs and 80,065 distinct IDs within the inspected first 1,887 source blocks exposed the cost of single-token hydration. Completed handlers remained slow even while the fetch cache advanced. Commit `4e0c8f0` batches the current token with up to 64 unique actual same-block peers, validating exact collection, block hash, event topic and current ID before hydration. It retains original ordered owner/state updates, DB rollback/retry behavior, immutable facts and event-block metadata reads. The same commit rotates initial requests across the six existing public endpoints, sharing each concrete limiter across fallback rotations; optional paid reserve remains last and is not configured. Caps remain 8,8,5,10,5,5; HTTP retries are disabled. Nine focused helper/RPC/selection tests and typecheck passed, and independent frozen-file review passed. No contract behavior changed.

A fresh `cc_mainnet_v3` schema preserves v1/v2 and the existing RPC cache. The canonical `indexer/deploy.sh mainnet` deployment exited 0, image `registry.fly.io/cc-indexer-mainnet:deployment-01M5B41KFBSCTBDVHXKKACW2SC`, digest `sha256:fdbb6592470d508db81338fa646076af1f603fee2e21b2b6d0496a33e20f338a`, source `4e0c8f0`. Actual build context was 356.91 KB and dependency layers were cached. V3 started historical processing at 22:21:26 UTC, with /health 200 and /ready 503 while incomplete. At 22:22 UTC it had processed 322 Credits Transfer events and 1,188 historical seconds; the fetch head was already 26041930. This is real handler progress, not acceptance. Provider failures are visible in /health/rpc and logs, notably 1rpc.io errors and PublicNode historical-call errors; no paid reserve is silently used.

Next action: finish the historical backfill, then require real `/ready`, fresh `/health/parity`, exact SQL Core/coin/deploy-block identity and state agreement, and indexed head within five blocks using `RPC_URL=<mainnet read RPC> indexer/check-live.sh mainnet`. No indexer acceptance is claimed yet.

## Focused verification and limits

- Keeper ops/executor: 26/26 synthetic tests and typecheck; isolated production workspace install/config loading passed. Independent review of packaging, context allowlist and credential mounts passed. Actual remote builds uploaded only about 443 KB keeper and 345 KB initial indexer public source, excluding `.git`, other worktrees, dependencies, credentials and `.env` files.
- Keeper decision/snapshot tests: 34/34 passed; alert-specific local tests: 3/3 passed. These are synthetic, separate from the real mainnet ticks and real topic delivery above.
- Indexer deploy guards and shell syntax passed; web indexer identity gate test passed 1/1. These do not establish production indexer readiness.
- Initial keeper build failed before upload because paths were resolved relative to the Fly config directory; fixed in `5a3e8e4`. The oversized-root warning was not treated as permission to upload. Automatic review blocked the first paid DB provisioning until the owner approved the stated budget, and blocked OpenSea/keeper credential transfers until their specific approvals. Subsequent transfers followed those approvals. These failures are preserved as failures.
- Source commits so far: `950324e`, `9729c7d`, `5a3e8e4`, `01646d7`, `24b9c8c`, `ae27287`, `d5be6e5`, `4e0c8f0`. No Git push.
- Prior Core-only waivers do not approve coin launch. Existing coin/service freeze records remain pending; no acceptance or test waiver is converted into a pass here. Post-launch fee ingestion, actual keeper paid execution/receipt accounting, buybacks, and coin/pool website transitions remain unproven until authorized launch/use.

## Cost and owner actions

Proposed ongoing capacity is approximately $18.74 per 30 days before traffic, builds and snapshots, using Fly's published iad rates: two 1 GB shared Machines at $6.70 each, one 512 MB at $3.69, and 11 GB of volumes at $0.15/GB. Source: https://docs.fly.io/about/pricing . This is an estimate, not a hard billing cap; the owner approved $30/month and $5 total setup/build retries. No HA replicas or dedicated paid IPv4 were requested.

Current coin-launch verdict: NO-GO while indexer acceptance is pending and keeper is unfunded/disarmed. Minimum later owner actions include funding the dedicated keeper to the stated float, explicitly approving keeper arming/transaction sending, and approving the separate coin-launch release gates. This task authorizes none of those actions automatically.
