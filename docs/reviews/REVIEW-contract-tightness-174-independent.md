# Independent focused review: contract cleanup and executable statement quote

Reviewer: `final_review`, a separate read-only agent that authored no source changes. Director/implementer: root agent. Date: 2026-10-18.

Reviewed source: immutable isolated clone based on `d1c27ab`, with the final `src/**/*.sol` and `test/ValueMode.t.sol` file set. Its SHA256 is `1fd09d17862bebe4c8c23f6cbf917fd510d9a7226cfdee62882396ab9585682c`: concatenate each sorted source path, a NUL and its bytes, followed by the regression test path, NUL and bytes. The record identifies source independently of later build-pin and state-document updates.

Owner goal: remove unused/unnecessary contract code, correct comments/NatSpec and improve developer legibility. Claims challenged: the fixed-scale spot calculation preserves both integer floors without overflow; dead-wrapper and unused-result removals preserve checks; the final statement quote respects the Core's unconditional cost minimum while retaining a value-only reference.

Method: static source/caller review in isolated clones, comparison with `a6099d2` and `d1c27ab`, and inspection of the real-pool regression. The reviewer did not edit files or run Forge. Build pins were separately verified by the director's BuildIdentity run.

Initial findings, all corrected and checked again:

1. The shared instance indirectly affects executable balance payouts through the value-mode cap, although the posted balance rate stays flat. Both Core and CoreLib comments now distinguish them.
2. Cost is excluded from value-mode sale references, while final quotes retain the Core's historical cost minimum. The Settings comment now makes this distinction.
3. Sale start caps and linear decay describe the reference curve before the final cost clamp. The cost floor may flatten the final quote or exceed its curve start cap. The Sale comments now state that caveat.
4. Liquidity equal to `minLiquidity` passes; the overview now says “at least”. The owner pool-key seeding exception remains explicit.

Final reviewer result: no remaining findings. No runtime defect found in the reviewed cleanup/fix. `_spot` preserves both divisions and fits uint256; `_quote` enforces the Core floor without changing the reference. This is focused static review, not release acceptance or exhaustive security assurance. Test results and final build sizes are in the main pass record.
