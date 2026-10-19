# slither 0.11.6 on src/** (isolated copy of 84ea170, forge build via_ir, lib/ test/ script/ filtered)

111 contracts analysed with 102 detectors, 165 results. Every High and Medium result was read against the code:

| impact | check | n | disposition |
|---|---|---|---|
| High | reentrancy-eth | 3 | `ControllerV1.buy`, `buyCredit`, `buyCredits`: the refund after `sellTo`/`sellCreditTo`; the controller has its own `_busy` flag and the Core doors are guarded. Not exploitable. |
| High | arbitrary-send-eth | 2 | `buyCredit`, `buyCredits` refund `msg.value - price` to `msg.sender`. By design. |
| High | reentrancy-balance | 1 | `Core.buyListing`: balance read before and after the target call, under the Core guard; the check is the point. |
| High | msg-value-loop | 1 | `buyCredits` compares the running `spent` with `msg.value` and forwards `price` per credit; no double counting. |
| High | weak-prng | 1 | `Core._composePage` format from prevrandao, decision 113, cosmetic. |
| Medium | incorrect-equality | 14 | `== 0`, `== 1`, `== lastRefreshBlock` style checks on counters and flags; none on a balance that an attacker can nudge. |
| Medium | reentrancy-no-eth | 7 | `sellTo`, `sellCreditTo`, `redeemStatement`, `buyback`, `collectEscrow`, `_compose`, module `pay`: all under a guard or `onlyCore`; state written after a trusted call (Statements, the module, the pool manager). |
| Medium | unused-return | 8 | tuple destructuring of `statementInfo`, `creditInfo`, `getSlot0`; `module.redeem` return ignored by design (the holding delta is the check); `token.withdraw` return ignored by design (the balance delta is the check). |
| Medium | uninitialized-local | 8 | accumulators declared without `= 0`. |
| Medium | divide-before-multiply | 3 | `_creditPrice` (floor then start, one wei), `_spot` (two divisions by design, documented), `CoinRenderer.page` grid math. |
| Medium | erc20-interface | 1 | `IStatementSource.approve(address,uint256)` is the ERC721 `approve`; false positive. |
| Low and Informational | timestamp 35, calls-loop 18, missing-zero-check 4, naming 29, others | 70 | consistent with the forge lint summary; no new finding. |

Conclusion: no finding from slither adds to the manual review. The tool confirms the attack surface the threat model lists
(three controller doors that forward and refund eth, one Core door that calls an external target) and nothing else.
