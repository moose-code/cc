# acceptance review of c02435e (read only, no tests run)

verdict: ACCEPT WITH LISTED FIXES. every decided behavior of 42 to 58 is in the code and the launch config matches the decided values. no code defect found against an owner decision. the defects are in the intent records (overbroad guarantee wording, stale statuses, two missing decisions, quotes that cannot be confirmed) and one owner-visible tension (buyback tip). one launch input is still empty (image, description).

## section 1 rows (SPEC.md lines 14-37)
| # | row (decisions cited) | result |
|---|---|---|
| 1 | bid always sellable at or below rateCap (42, 48) | ok. quote 42 verbatim (1aabe7 msg 1135). code: Core.sol:514-534 (no controller read), CoreLib.sol:220-243. status cites "invariants on 06009bd", but E-DEEP-1e2c4b3 and E-DEEP-CARRY-14c6306 exist: stale citation |
| 2 | risk: market above rateCap, fast rise (42,46,49,50) | wording ok, figures match the owner-visible table (msg 1986: 35 percent an hour, 2.3 h, 4.6 h). owner "C" (msg 1990) answered "Do C now and start on E?"; FLOW 50 records C only. STALE: "being built (NEXT 26)": built at dfd6001 (STATUS.md:32, SettingsBounds.sol:16, mainnet.json idleLoosenBps 2000) |
| 3 | assets leave only via migrate/rescue (8,28,32,33) | claim ok in code (CoreLib migrate/rescue). cites 33 but not 48 and 52, which amend it. decision 8 still carries the removed spendCapBps text (DECISIONS.md:20) |
| 4 | statement leaves only at or above hard floor (FLOW s4, 56) | DEFECT: wider than code. house reserve is set at listing/reprice (Core.sol:683-705, 788-795). setSettings does not reprice (Core.sol:1091-1118), so after `saleFloorBps` is raised a no-bid listing can clear at its old reserve below the new floor until someone calls `repriceStatement`. DECISIONS.md:163 says "reserve was at least the hard floor when it was set"; the row and the settings table ("no sale leaves the Core below it") drop that qualifier. the row is classed a guarantee "under every setting" |
| 5 | locks one way (9.6, 10.2) | not re-verified beyond reading Core.sol:995-1045 |
| 6 | never stops buying for unsold statements (2) | ok, no inventory gate in src |
| 7 | must not push floor down (43) | quotes verbatim (msg 1304). "must not" is a director reading of a rhetorical question, the row says unproved. code: no Core function sells a credit. ok |
| 8 | empty pot never raises price (44) | ok. quote verbatim (msg 1276). CoreLib.sol:226-232 (no climb when pot is 0), Core.sol:350-355 receive checkpoints first |
| 9 | pot spent as sellers come (37,45,56) | ok. quote verbatim incl. typo (msg 1276). no spendCap or window in src (grep clean), Settings has 26 fields |
| 10 | keeper not overpaid (41,46) | quote verbatim but the owner said it about `reimburseBps` only (msg 513). holds for exit repay (Core.sol:660-664, 80 percent of gas) and the buyListing tip (below gas, FLOW 56). does NOT hold for the buyback tip: 0.5 percent of the slice (Core.sol:889,895), 0.0025 eth at the launch slice, not tied to gas; REVIEW-sandwich says it exceeds gas below about 9 gwei. owner call, see section 4 |
| 11 | compose/composeExit repay nothing (41) | ok. owner words exist (1aabe7 msgs 2057, 2082 "no, no repayment for compose!"). Core.sol:613-657 pays nobody |
| 12 | first migrate retires (33,48,52) | code ok: Core.sol:503-506 `_openDoor`, CoreLib.sol:593, 410-420; xPot moves, xToBuyback and ethToBuyback stay. FLOW 48 says the owner's "yes agree with your recs" covered "move the exit token pots"; the rec shown to the owner (msg 1351) covered retire, keep ethToBuyback and accept rateCap, and the exit token move came from the director (msg 1394), later amended by 52 ("B"). owner's earlier words "migrate only credits and eth" (75f67902 msg 1628) are literal narrower than xPot moving |
| 13 | every number an owner setting (3,15) | ok |
| 14 | opening bid at market, rateCap 10x (NEXT 11, 46) | 10x ok (quote verbatim msg 1142; Checks.sol:172). "opening at market" cites NEXT 11, a director item, not a FLOW decision. the only owner support is "he agreed 75% is too slow" (handoff summary, msg 54) and blanket "implement ... items in next.md" (msg 277). no owner quote for 100 percent |
| 15 | buyback slice 0.5 eth, bound 1 eth (51) | ok. quotes verbatim (msgs 2054, 2142). code SettingsBounds.sol:28. STALE status "being built (NEXT 26)" |
| 16 | payee 0.75, protocol 0.25, engine the rest (31) | numbers ok (payeePpm 112778 = 0.7499985 points). cannot confirm owner words: no 0.75 in either transcript; msg 54 says payee "1.0 or 0.5, WAITING". "protocol 0.25" is 0.24978 points. "engine the rest" is 5.9002 points of router inflow |
| 17 | name CC, image/description launch params (53,54) | ok. quotes verbatim (msg 2285). Builder.sol:40-41, configHash covers them |
| 18 | every credit same worth (55) | ok. quote verbatim (msg 2327). no score in src. STALE: "independent review running": REVIEW-next29.md and E-REVIEW-NEXT29-c8892a2 exist. FLOW 55 says adopt books "at the current bid"; code books `ethPrice` (price state before the pot clamp, CoreLib adopt, deliberate per Core.sol:1066-1073) |
| 19 | buyListing stays (57) | ok. quote verbatim (msg 2502). Core.sol:542 |
| 20 | holders trust owner key (8) | ok |

other section 1 checks. 56 quote "all your recs are approved" verbatim (msg 2421), list matches msg 2412. 52 "B" and 50 "C" ok.

## decisions 42-58 missing from section 1 or runbook
- 47 (burn router and $balance readiness): no row. only STATUS.md:60 "intent gap". docs say it is unwritten.
- 58 (sellForEth short form stays, batch of 115): no row. INTEGRATION.md:34-56 covers the behavior.
- 57: keeper triggers (30 min below bid, full page a few hours, proceeds a day) appear only in FLOW; DEPLOY keeper duties (lines 344-356) omit buyListing. acceptable, keeper is a later project.
- all other behaviors (41-46, 48-56) are in code and config.

## launch values (script/config/mainnet.json)
ok: idleLoosenBps 2000; buybackSlice 5e17 (bound 1 eth in code); rateStart 8.9e15, rateCap 8.9e16 (10x, preflight Checks.sol:172); payeePpm 112778 to creatorPayee = owner; bountyBps 9638; no spend cap field; name and symbol CC; image and description fields present.
open: image and description are empty strings. preflight only WARNs (Checks.sol:300), so the candidate can launch with no image. FLOW 54 and STATUS.md:52 say the owner supplies them. a filled value changes CONFIG_HASH and the predicted coin address.
stale runbook text: RUNBOOK.md:372 says the buyback burns "one slice of at most 1 eth"; the launch slice is 0.5.

## goal conflicts (docs, code and tests agree, owner goal at risk)
1. credits into statements depends on unpaid composers (decision 41). prior analysis (msg 1856) says flow stops if the owner stops composing above about 0.55 gwei. owner decided it; row 11 states the assumption. no fix, keep visible.
2. section 1 intro says a statement sold below cost beats an unsold one. the launch `saleFloorBps` 7500 and sale floor 7500 refuse any sale below 75 percent of cost, and with no exitModule an unsold statement waits. consistent with the owner's "may sell below cost" only down to the floor. the intro sentence and "acquire as many credits as possible early" have no owner quote (only msg 54 summary: "statements may sell below cost. volume matters more than profit").
3. short form `sellForEth(ids)` pays min(price, pot) (decision 58). a small pot pays a seller far below the bid, and the cost basis (hence the statement reserve) is that low amount. owner chose B knowingly.
4. buyback tip not gas bound (row 10). owner has said "don't overpay the keeper" only for exit repay.
5. floor effect of the bid is unproved (sim has no competing bidders), as row 7 says. no conflict found in the never-locked goal: no gate, no controller read on the buy door, rate stops only at rateCap or retirement.

## stale records to fix
STATUS.md:11 "decisions 1 to 47"; :36 "no candidate is frozen" (project/director-state.json candidate is 1e2c4b3); :46,:48,:50 "being built". DECISIONS.md decision 1, section 2 table (flatBps, avgScore, spendCapBps), decision 8 spend cap text and decision 33 (overprint, hourly window) are not marked superseded by 55 and 56 in place, though the FLOW header says superseded text is marked in place.

## not checked
evidence.json validity against the diff; any test or invariant result; gas figures (115 batch, 8.71M compose); rescueCoin/rescueNft bodies; FeeRouter beyond flush; preflight run; chain state; the simulator; decisions 1-41 and 38-40 quotes (31 only partly); transcripts other than the two given; integer stall of the rate near a few hundred wei (needs thousands of dumped credits, not reachable economically).
