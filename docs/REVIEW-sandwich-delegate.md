# two facts for the launch: the buyback sandwich at thinner pool depth, the owner's 7702 delegate

measured 2026-10-10 by a read only investigator subagent in its own clone of 5146ebe. not in the repository: the probe test it wrote.

## 1. buyback sandwich at reduced pool depth

method: fork at block 26158000. the attacker buys `front` eth of coin, the keeper calls `buyback()` with the slice forced into storage, the attacker sells back. net is eth back minus eth in, after the steady 6.9 point skim on both legs. depth is reduced by removing 75 or 90 percent of the liquidity of the locked launch position (id 449080) as the locker, at an unchanged price. for each cell the attacker uses the best of 21 front sizes from 0.02x to 64x the slice.

attacker net in eth (negative: the attacker loses):

| slice | launch depth | 0.25x depth | 0.1x depth |
|---|---|---|---|
| 0.5 | -0.01012 | -0.00038 | +0.0764 |
| 1 | -0.01378 | +0.0958 | +0.3349 |
| 2 | -0.00152 | +0.5558 | +0.9762 |

largest slice that is unprofitable to sandwich: about 2.06 eth at launch depth, 0.515 at 0.25x, 0.205 at 0.1x, close to linear in depth. at launch depth a 3 eth slice nets the attacker +0.1126 (matching REVIEW-v2port V2R-2) and 4 eth +0.383.

consequence: the launch `buybackSlice` of 1 eth stays unprofitable down to about 0.49x of launch depth. the bound of 2 eth sits about 3 percent below break even at launch depth. excluded: the attacker's gas and builder tips, and price drift (lower depth is modelled as removed liquidity at the same price).

## 2. the owner's EIP 7702 delegate

method: `cast code` at block 26163820, the Sourcify API, the verified source, view calls on the owner at block 26163823, `getLogs` from block 25,900,000.

* the owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9 has code `0xef0100612373d7003d694220f7800eeaf8e3924c0951d3`, nonce 3822.
* the delegate 0x612373d7003d694220f7800eeaf8e3924c0951d3: runtime 24,504 bytes, code hash `0xff0357b543bbb94845b6791a8becac5e87d467814f86538a62649c877227d631`, not a proxy. Sourcify full match as `CaliburEntry` (solc 0.8.29), `namespaceAndVersion()` returns `Uniswap.Calibur.1.0.0`. its runtime equals Uniswap's canonical Calibur at 0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00 except the two embedded self addresses.
* who can act as the owner: the owner key, or a registered unexpired key (none registered: `keyCount()` is 0, no `Registered` or `ApproveNative` events). signed batches can be relayed by anyone but need the owner key's signature, a nonce and a deadline. `executeUserOp` and `validateUserOp` accept only the ERC-4337 entry point 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108 and check the signature. key and entry point management is callable by the account itself only. native allowances: none found.
* pinning: preflight can check `owner.code == 0xef0100612373d7003d694220f7800eeaf8e3924c0951d3`, `delegate.codehash == 0xff0357b5...d631`, `keyCount() == 0` and the entry point. the owner key can redelegate at any time, so the pin holds for the moment preflight runs.
* unknown: a chain id 0 authorization signed earlier cannot be ruled out from chain data, per spender native allowances cannot be enumerated, and who deployed this copy is unconfirmed.
