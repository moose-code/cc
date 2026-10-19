# Launch owner review

Prepared on 2026-10-19 for the owner's review before any mainnet deployment. This is a decision list, not a deployment authorization. The frozen-candidate evidence and exact revision will be linked here after verification.

## Provisional choices made during repair

| choice | recommendation implemented for local review | consequence to accept before launch |
|---|---|---|
| Value-mode ETH quote failure | Return `NoQuote` and stop ETH Credit purchases when the protected quote is unavailable. Do not reuse a stale last-good rate or a live spot outside the protection rule. | A missing or failing BALANCE pool/controller quote can stop the ETH bid until pricing recovers or the owner turns value mode off. |
| Credit return lock | Apply the configured lock to a Credit sold by the engine across every intake door, even after a transfer to another holder. | A buyer cannot sell that Credit back to the engine within the launch 6-hour lock, including after a legitimate transfer. The same token ID remains otherwise transferable. |
| Opening-rate reset | Allow the owner to reset `RATE_START` only before the predicted coin has code, with the 3x cap reset atomically. Require a separate rate-and-cap signoff hash for deferred launch, recovery and postflight. | The owner can change the bid upward before coin launch; a mistaken or compromised owner decision can overpay sellers once funded. Reconfirm the market anchor on deployment day. |
| Keeper uncertain transactions | Persist sent hash and nonce, stop further paid sends until the receipt is reconciled, and fail closed on malformed spend records. | RPC/relay trouble can stop the keeper and require operator recovery. It prevents nonce reuse and budget resets after an uncertain send or corrupt ledger. |
| Keeper listing cooldown | Cool only deterministic order-specific failures. Let transport and receipt uncertainty follow transaction recovery. | A bad listing waits before retry; service outages do not silently hide otherwise valid listings for five minutes. |
| Reference refresh caller payment | Keep the current caller payment on a successful reference update, even if the current two liquidity samples still close protected quotes. | At the launch 3 gwei gas cap and 0.0003 ETH fee, a 600-second cadence allows at most 144 paid refreshes per day. The contractual per-call cap is 0.0009 ETH, or 0.1296 ETH per day if the pot can fund every call. Actual gas payment is lower when measured gas is below 200,000. A liquidity gate on payment would also remove the incentive to gather the two samples needed to reopen pricing. Review this incentive before phase two. |
| Pool postflight | Require the live factory protocol recipient to equal the configured hook recipient and the initial v4 pool LP fee to be zero. | A factory recipient change or unexpected fee halts launch postflight until reconciled. |
| Historical master fixture | Keep it as historical test material, but use the deployed live v2 stack and pinned chain-id-1 block for launch gates. | Master-fixture evidence does not prove the live-stack path. |
| Interrupted deployment | Recompute missing transactions from the original signed config and live state. Do not replay Forge's saved transactions. A stopped deferred run stays deferred. | Preserve the nonsecret config lock and its separate durable backup. If either is inconsistent with the partial chain state, halt and review before any further transaction. |

PR #111's prelaunch reset is incorporated selectively; its removal of resume owner checks is not adopted. PR #112's fail-closed quote and cross-holder return-lock ideas are incorporated selectively; its conflicting decision numbers and unrelated changes are not adopted as a whole.

The owner already chose the phase-two 203/100-bps spread/tolerance, same-token inactive BALANCE reserve recovery on request, rollback when the artist royalty module call wholly fails, and the royalty/slippage-aware BALANCE break-even relationship with wide individual ranges. The relationship makes a 10,000-bps redemption shortfall incompatible with the maximum 9,999-bps discount while balance acquisition is enabled; no test should assert that impossible combined settings tuple is valid.

## Inputs and acceptance still needed from the owner

1. **Opening bid:** review the deployment-day price of 100 Credit points. The current config uses 0.0049 ETH with a 0.0147 ETH cap. If changed after deferred Core deployment, review the exact new rate, 3x cap, signoff hash and reset transaction.
2. **Coin metadata and final launch config:** supply the final image and description, and review the coin fee, recipients, owner, artist, payee, salt, supply and factory record together.
3. **Phase-two reference controls:** choose the reference rate, step, maximum staleness and minimum BALANCE pool liquidity against actual deployed depth. The 203/100 pair alone is insufficient to activate value mode safely.
4. **Operator setup:** provision the mainnet signer, funded keeper wallet, read and private RPCs, relay, OpenSea access, indexer database/hosting, alert destination and website deployment. Run exactly one keeper process per signer and state directory; the transaction ledger is durable but has no cross-process signer lock. Verify the proxy forwarding contract before setting `TRUSTED_PROXY_HOPS`.
5. **Service and recovery acceptance:** observe production RPC pending-fee estimation, relay inclusion and replacement, historical wallet balance and finalized-block reads, OpenSea latency/order fulfillment, indexer replay/parity and alert delivery against the final record. Keep the keeper signer dedicated: an unrelated wallet top-up between pre-send and receipt can look like a Core caller payment and mask an underpaid door. The signed gas ceiling protects the daily spend budget, but this receipt-based profitability check still needs production observation. A local fork cannot prove these external services. An Anvil impersonated `eth_sendTransaction` can be accepted before its returned hash is persisted, so use the signed-keystore path for the transaction recovery rehearsal.
6. **Transaction authorization:** review the decoded pre-state and exact action for each broadcast, including local Anvil rehearsal and later mainnet transactions, under the chain-operations procedure. No mainnet transaction is part of this candidate preparation.
7. **Recovery backup:** choose a durable absolute `CONFIG_LOCK_BACKUP` path outside the checkout. The deploy wrapper writes the nonsecret chain, deployer and config hash there before the first live broadcast and requires it for recovery. Review the backup location and preservation procedure.

## Release result

Pending the frozen candidate, its broad suite, deep invariants, same-record local lifecycle, local transaction confirmations, independent review and owner acceptance. A green local test suite alone does not close the service and launch-input gates above.
