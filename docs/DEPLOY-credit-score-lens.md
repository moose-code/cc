# CreditScoreLens mainnet deployment

Owner deployment, 2026-10-13 (FLOW 111). The agent did not sign or submit the transaction.

- Chain: Ethereum mainnet (1).
- Contract: [0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6](https://etherscan.io/address/0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6).
- [Transaction](https://etherscan.io/tx/0x3c28df17faec9cfea715b0435117bb05a8d3fc7fbf5732845cebb61523066f02): successful receipt, block 26186035, one zero-value CREATE, no pending transactions.
- Gas used: 372958. Effective gas price: 103980546 wei. Actual receipt fee: 0.000038780376475068 ETH.
- Runtime: 1478 bytes, hash 0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058, matching the reviewed artifact.

The owner's live verification script checked mainnet, exact helper/source runtime hashes and all five methods against direct source calls at block 26186035. Native integer results:

```text
creditScore(1)                 1324012
creditScores([1,2,3])          [1324012,2249257,1543512]
creditRarity(1)                1011963384
creditTraits(1)                (9,58,47,0,0)
statementScore(1)              417224564
```

[Sourcify job](https://sourcify.dev/server/v2/verify/eb4c10d6-9367-4203-9ab9-692cf7323e93) completed at 2026-10-13 20:43:20 UTC with creation/runtime matches. Its [verified contract record](https://sourcify.dev/server/v2/contract/1/0x7a3f3967cbb63e8d56e3f093069c62a25eebbda6?fields=all) contains on-chain and recompiled runtime bytecode with the same hash above, and helper source text identical to the committed source. These public status reads were performed without submission or credentials.

Etherscan verification remains unconfirmed. The owner's CLI failed an ABI request with a 3-calls/sec rate limit. Sourcify's separate automatic forwarding reported its daily source-submission limit; this is not evidence of the owner's key quota. The public Etherscan HTML request returned 403, so it did not establish verification status.

The retry at commit 4f5a891 selects Etherscan only, skips the redundant ABI precheck, and polls every 10 seconds for up to five attempts. The helper's on-chain identity/result checks still run before publication. Use the existing address; do not deploy again:

```bash
cd /Users/dd/CascadeProjects/cc/cc && git switch main && forge clean && bash script/deploy-credit-score-lens.sh verify 0x7a3f3967cbb63e8d56e3f093069c62a25eebbda6
```

This helper record does not accept or deploy the credits engine.
