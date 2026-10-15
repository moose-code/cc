# credits engine indexer

Ponder 0.17.8 indexer for the Core, its controllers, the coin burns, the balance token and the Credits and Statements collections. Spec and web data contract: `docs/INDEXER.md`.

## run locally

```
cd indexer && npm ci
createdb cc_indexer_local   # once; local Postgres, same database kind as deployed
DATABASE_URL=postgresql://localhost/cc_indexer_local npx ponder dev --port 42169   # anvil fork at the record rpcUrl
```

Local runs use Postgres. With PGlite the `/sql` endpoint returns no rows for the `credit` table (a session temp table named `credit` shadows it), so the web health check stays in chain mode. The launch entry `indexer` in `.claude/launch.json` runs the command above.

Endpoints: `/graphql`, `/sql` (`@ponder/client`), `/health/parity` (503 when a reconciliation check failed), `/health/rpc` (requests and failures per endpoint), `/ready`.

## commands

| command | purpose |
|---|---|
| `npm run abis` | regenerate `abis/Core.ts` and `abis/ControllerV1.ts` from forge `out/` (run `forge build` first) |
| `npm run typecheck` | `tsc --noEmit` |
| `npm test` | `node --test` on `src/lib` |
| `DRY_RUN=1 ./deploy.sh <local\|mainnet>` | evaluates every deploy check without deploying |

## configuration

`ponder.config.ts` reads addresses and the Core deploy block from `deployments/<chainId>.json` (`DEPLOYMENT_RECORD`) and refuses to start on a missing value. `.env.example` lists the variables. Chain 1 requires `DATABASE_URL`, `CREDITS_START_BLOCK` and `STATEMENTS_START_BLOCK` (set in `env/mainnet.env`).

## external ABIs (`abis/external.ts`)

Confirmed by read-only calls on the mainnet fork (chain 31337) and by code presence at the deploy blocks:

- Credits `0x97630aA70AB14ed9883B41dAfccBc11349723043`: `Transfer(address,address,uint256)` events, `ownerOf`, `seedOf` (bytes21), `timestampOf` (uint64), `tokenURI`. Code first present at block 26037292.
- Statements `0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b`: `Transfer`, `ownerOf`, `creditScoreOf`, `formatOf`, `tokenURI`, `supply`. Code first present at block 26100733.
- CreditScore `0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7`: `scoreOf(bytes21,uint64)`, `traitsOf(bytes21,uint64)` returning five values.
