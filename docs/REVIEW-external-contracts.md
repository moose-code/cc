# review of the verified Statements, Credits and CreditScore sources against the engine's assumptions

reviewer: independent read-only agent, 2026-10-12. sources from Sourcify (full match) and Etherscan; live reads with cast on publicnode.

## result
every assumption the engine makes holds. the owner roles of the three contracts cannot block composing or transfers or change a stored rating.

## facts
- Statements: owner powers are `addFormat` (append only) and `seal`, plus ownership transfer. no pause, blocklist, transfer hook, upgrade or score setter. renderers run only for metadata. `credits`, `score`, `art` and `composeOpensAt` are immutable.
- Credits: sealed (supply 122,154), so `distribute` reverts and the owner role is inert. `seedOf` and `timestampOf` are written once at mint and stay readable after burn. transfers are unrestricted.
- CreditScore: no owner, no state. `scoreOf(seed, paidAt)` is pure over a compile-time table, so a credit's score never changes. `timestampOf` is the `paidAt` input.
- `Statements.creditScoreOf(id)` returns the stored sum of the statement's credits' scores, written at compose. checked on chain against the per-credit sum for statements 1, 2, 11 and 48.
- a stored rating changes only through `overprint`, on the base, and only the base's owner or an operator approved for all of its owner can call it. the engine never approves an operator on Statements, so its statements' ratings are fixed at compose.
- compose: callable by contracts; burns the 80 credits from the caller (needs `Credits.setApprovalForAll(Statements, true)`); ids distinct, nonzero, owned; format below 8; mints with an `onERC721Received` callback to contract callers. observed gas 7.5M to 8.3M.
- one compose sums at most 80 x 8,000,000 = 640,000,000, which fits the engine's `uint32` rating. an overprinted statement can exceed it; the engine reads the rating at its own compose, before any overprint.

## notes for the engine
- a burned statement still returns its stored `creditScoreOf` and `creditsOf`, while `ownerOf` reverts. nothing may treat a nonzero rating as proof that a statement exists.
- `ownerOf` of a burned credit reverts rather than returning another owner; doors that check `ownerOf(id) == core` revert for a burned id, which is acceptable.
