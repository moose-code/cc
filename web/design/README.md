# Handoff: CC Engine web app redesign

## Overview
A full visual redesign of the `web/` app in `ripe0x/cc`: the engine home page (explainer, stats, ledger, swap panel), credits index and detail, statements index and detail, the swap panel states, and a light/dark theme system. The look is a print-shop system drawn from the Credits artwork: four CMYK inks, an 8×8 unit, crop and registration marks, ledger-style tables.

Contract reads, hooks and write paths stay exactly as they are (`lib/live.ts`, `lib/engine.ts`, `lib/events.ts`, `lib/tx.ts`). This is a presentation-layer change.

## About the design files
`CC Engine Approved.dc.html` is a **design reference built in HTML**, not production code. Open it in a browser (keep `support.js` next to it) to see every screen on one pannable canvas. Recreate the designs in the existing Next.js 14 app using its patterns: `globals.css` for styles, the existing components and hooks for data. Don't copy the inline styles or the sample data generator.

All numbers in the file are sample values. Every value in the build comes from the chain, as it does today.

## Fidelity
**High fidelity.** Colors, type, spacing, rules and copy are final. Match them exactly.

## Build order (one Claude Code task each)
1. **Tokens + theme.** Add the CSS variables below to `globals.css` with light and dark values. Add the theme control. Swap hard-coded colors for variables.
2. **Shell.** Header, page head band, footer, buttons, segmented toggles, fact rows, history rows, art tile with crop marks.
3. **Engine home** (`app/page.tsx`, `Flywheel.tsx`, `StatsBar.tsx`, `EngineFeed.tsx`, `TradePanel.tsx`).
4. **Credits index** (`app/credits/page.tsx`).
5. **Credit detail** (`app/credits/[id]/page.tsx`).
6. **Statements index** (`app/statements/page.tsx`, `components/Cards.tsx`).
7. **Statement detail** (`components/StatementLive.tsx`).
8. **Swap states** (`components/TradePanel.tsx`).
9. **Mobile pass** (390px) for the shell, home and trade.

---

## Design tokens

### Color (CSS variables, light / dark)
| token | use | light | dark |
|---|---|---|---|
| `--paper` | page background | `#f6f5f0` | `#121211` |
| `--surface` | cards, inputs, selected rows | `#ffffff` | `#1a1a18` |
| `--ink` | text, key plate, filled controls, selection | `#1a1a1a` | `#ecebe6` |
| `--on-ink` | text on filled controls | `#f6f5f0` | `#121211` |
| `--structure` | section rules, table heads, outlines | `#1a1a1a` | `#55534e` |
| `--divider` | cell dividers, dashed rules | `#d9d7cf` | `#2e2d2a` |
| `--hairline` | row rules, art outline | `#e3e1d9` | `#232220` |
| `--muted` | labels, secondary text | `#6e6c64` | `#9a988f` |
| `--quiet` | timestamps, captions | `#8a877e` | `#7d7b73` |
| `--faint` | numerals, empty checkboxes | `#a8a69e` | `#6a6861` |
| `--disabled` | placeholder values (`0.00`) | `#c4c1b7` | `#4a4944` |
| `--c` | cyan plate | `#00a3e0` | same |
| `--m` | magenta plate | `#e5007e` | same |
| `--y` | yellow plate | `#ffd400` | same |
| `--k` | key plate edge (= ink) | `#1a1a1a` | `#ecebe6` |

**Ink meanings, used consistently:** magenta = credits, yellow = statements, cyan = the user / wallet / balance token, key = engine / pot / burn. Use them for 8px square status marks, 3px top edges on cells (`box-shadow: inset 0 3px 0 var(--m)`), and the loop accents. Never for text or large fills, except the pot cell (a full `--ink` fill).

Errors use magenta: a `--m` 1px border on the input and `--m` text for the failing value. There is no red.

### Dark mode rules
1. **Black paper, white art.** The page turns black. Credit and statement art **always** renders on `#ffffff` with a `--hairline` outline. Never invert or filter the art.
2. The key plate prints white: everything that was `--ink` follows the token.
3. C, M and Y keep their values. Overlapping inks (the logo) use `mix-blend-mode: multiply` in light and `screen` in dark.
4. Filled controls invert: primary button, active toggle segment, pot cell.
5. Pages never set colors directly; only tokens.
6. **Theme control:** a three-way segmented control in the footer (auto · light · dark). Default `auto` follows `prefers-color-scheme`. Store the choice in `localStorage`, apply it as `data-theme` on `<html>` before first paint (inline script in `layout.tsx`) so there's no flash. No transition animation.

### Typography
- Family: **IBM Plex Mono** (400, 500, 600) for the app. Load it through `next/font/google`.
- All copy is lowercase except token symbols (`ETH`, `$CC`, `$BALANCE`), plate letters (C M Y K) and the `CC` wordmark.
- Use `font-variant-numeric: tabular-nums` on every number.

| role | size / weight | notes |
|---|---|---|
| detail hero id (`#14727`, `180`) | 40 / 500, line-height 1 | |
| big value (price on detail, swap amount) | 30 / 500 (detail), 26 / 400 (swap fields) | unit after it at 13 `--muted` |
| stat value | 24 / 500 | |
| explainer headline | 22 / 600, lh 1.25 | 18 on mobile |
| page title | 20 / 600 | |
| card price | 16 / 600 | `ETH` 11 `--muted` after it |
| section title, group name | 14 / 600 | |
| body | 13 / 400 | lh 1.5–1.55 for paragraphs |
| secondary | 12 / 400 `--muted` | |
| label (uppercase exception) | 11 / 400, `text-transform: uppercase`, `letter-spacing: 0.06em`, `--muted` | section labels: status, price, history, buy credits… |
| caption | 11 / 400 `--quiet` | |

### Spacing and shape
- 4px base. Common values: 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48.
- Page gutters 24px. Detail main area padding 40px.
- **No border radius anywhere**, except the registration mark circle and the radio dot.
- **No shadows**, except the 3px inset ink edges and the 1px artboard outline.
- Rules: 1px solid. Structure rules `--structure`; row rules `--hairline`; key-value rows use 1px **dashed** `--divider`. Table heads have a 1px `--structure` bottom (2px top on the home ledger).
- Desktop layout is a 2-column grid: `minmax(0,1fr) 400px`, a 1px `--structure` rule between them. The 400px right rail holds actions.

### Recurring marks
- **Crop marks:** four 10×10 L-shapes (1px `--ink`) offset 12px outside the corners of hero art (8px / 6px on smaller tiles and inputs).
- **Registration mark:** 16px circle-and-cross, 1px `--ink`, beside hero art. Decorative.
- **Art tile:** the art at 1:1 on `#fff` with a 1px `--hairline` outline. Thumbnails are 24, 28, 32 or 40px; card art fills the card minus 8px padding.

---

## Shell

### Header (52px)
- Left: logo (three 16px squares C, M, Y offset 3px with multiply), `CC` 15/600, `engine` 11 `--quiet`. Then the nav with 24px gaps: engine, credits, statements, sell, compose, balance, keeper. Active item is `--ink` 600; the rest are `--muted`.
- Right: short address (12 `--muted`), then a 32px outlined status button (1px `--ink`, 6px `--c` square, `connected`). Disconnected: a filled `connect wallet` button. Keep RainbowKit; restyle its button.
- Mobile: logo, a filled `connect` (36px), and a 44×44 `≡` toggle that opens the nav.

### Page head band (64px)
1px `--structure` top and bottom, 3px inset top edge in the page's ink (credits M, statements Y). Left: title 20/600 plus a meta line (12 `--muted`, for example `96 held by engine · bid 0.0089 ETH at rating 50 · ~3 bought an hour`). Right: the grid|table segmented toggle and `sort: newest ▾`.

### Detail breadcrumb (48px)
`← credits / #14727` (12px, the id 600) on the left; `← prev  next →` on the right. 3px ink top edge.

### Footer (32px)
`independent tool · not affiliated with Credits`, the theme control, and four 10px C/M/Y/K squares. 11 `--quiet`, 1px `--structure` top.

### Controls
- Primary button: 48px tall, full width, `--ink` fill, `--on-ink` text, 600.
- Secondary: 48px, 1px `--ink` outline.
- Disabled: 1px `--divider` outline, `--faint` text. Disabled buttons say why (`enter an amount`, `not enough ETH`).
- Segmented toggle: 1px `--ink` box, segments padded 5×12, active segment inverted.
- Checkbox: 12–16px square, 1px border; checked = `--ink` fill with a white ✓.

---

### Loading and motion
The app is one surface: the header and footer never move, and data arriving never pushes what is already on screen. `components/Skeleton.tsx` holds the pieces; `app/globals.css` "loading and motion" holds the styles.

- **Loading is not empty, and not zero.** A value whose source has not answered is a skeleton, never `0`, `—` or an empty list. `—` means answered with nothing; an empty state ("no statements for sale right now.") shows only after the source answered. Hooks say which: `usePile().loading`, `useFeed().loading`, `useStatementIndex().loading`, `useStatementView().isPending`, `useCreditDetail().loading`, `useMarketStats().loading`, `useScan().ready`.
- **Skeletons hold the final box.** A skeleton is a flat block in the text colour at 9%, square like the print grid, pulsing as one (1.6 s). It takes the width of the text it stands for (`Sk w="11ch"`), the shape of the card, row or rail section it replaces (`SkCard`, `SkSideSec`, `SkFacts`, `SkHistory`, the ledger and listings rows), and the real labels stay real. Rows and lines that arrive later are reserved from the start: the flywheel split line, the stats sub lines, the page head meta line (`PageHead metaW`, and on a phone `metaLines`), the sell royalty note. Counts known early size the skeleton (held statements from the snapshot).
- **Art loads on white.** A tile still loading pulses in its own box, tinted from `--art-wait` on `--art` in both themes; art that arrives after the first render fades in over 260 ms, art already cached shows at once.
- **Arrival.** Content replacing a skeleton fades in once over 220 ms (`.fx-in`); later updates of a shown value do not fade (eth figures tween as before).
- **Navigation.** `app/template.tsx` fades each route's content in over 180 ms between the fixed header and footer, and makes it fill the space between them, so the footer sits at the bottom while a page loads. The detail routes have `loading.tsx` (`components/DetailLoading.tsx`): a click shows the detail layout with the real id at once while the server resolves the metadata. Data is cached across navigation, so a revisit renders at once.
- **Reduced motion** keeps the skeletons still and drops the fades.

## Screens

### 01 Engine home (desktop `Engine desktop`, mobile `Engine mobile`, `Trade mobile`)
Order from top: header, **explainer band**, stats row, then the 2-column body (ledger left, rail right with next-credit / next-statement progress and the swap panel).

**Explainer band.** Grid `380px minmax(0,1fr)`. The left column width must line up with the right edge of the second stat cell below it; derive both grids from the same tracks.
- Left: headline `a machine that collects Credits, funded by $CC trading`, then the paragraph `trading fees fill a pot. the pot buys Credits, every 80 become a statement, and statement sales pay the pot back.`, then `full mechanics →` pinned to the bottom.
- Right: five steps on a 9-column grid (`step 56px step 56px …`). Each step: a 36px glyph row, then `01 trade $CC` (13, numeral `--faint`, title 600) and a one-line description (12 `--muted`).
  - 01 trade $CC: five 4px-wide volume bars, each with a 3px `--ink` cap. `every trade pays a 9.9% fee` (see open items).
  - 02 the pot: a 36px `--ink` chip with the live pot (`0.5365` + `ETH` in `--faint`). `fees collect here`
  - 03 buy credits: a 32px credit thumbnail. `a standing bid, priced by credit rating`
  - 04 compose: an 8×10 grid of 3px cells (gap 1), filled to `pileSize`. `80 credits make one statement`
  - 05 sell or redeem: a four-bar step-down ladder. `statements are listed for ETH or redeemed for $BALANCE`
  - Arrows between glyphs: a 1px `--ink` line with a 7px solid triangle head, vertically centred on the glyph row.
  - A return line runs from under 05 back to under 02 (1px `--ink`, open at the top, arrowhead pointing up into 02). It is labelled on a `--paper` knockout: **`75%` of sales back to the pot · `25%` buys and burns $CC**.
- Mobile: the steps stack vertically with 76px rows. Vertical arrows run between the glyphs, and a right-side bracket goes from 05 back up to 02. The 75/25 split sits as two lines under the steps.

**Stats row.** Grid `repeat(4,minmax(0,1fr)) minmax(0,1.3fr)`: credits held, statements held, $BALANCE, $CC burned (with %), pot. Each cell gets a 3px top edge in M, Y, C, K; the pot cell is a full `--ink` fill. Label is 11 uppercase with an 8px ink square; value is 24/500.

**Engine ledger.** Columns `56px 180px minmax(0,1fr) 64px 64px 88px`: time, entry, ref, plates, rating, ETH.
- Credit row (40px): magenta mark, `credit acquired`, a 24px thumbnail and `credit #id`, the plate letters (C M Y K, printed plates `--ink`, hidden ones `#d4d2ca`), rating, price.
- Statement row: on `--surface` with `--structure` top and bottom rules. It has a 56px thumbnail, `statement 180`, and the meta line `format 4 · 80 credits · cost 0.5378 ETH`.

### 02 Credits index (`Credits grid`, `Credits table`)
One list of **all credits held by the engine**, best value first, paginated (`showing 24 of 96 · load more`). No plate letters.
- **Head:** the title with a short meta on its line, `304 held by engine · next statement composes in ~2m`; the view toggle and sort on the right. The bid lives in the site header and what credits trade for in the market report, so neither repeats here.
- **Market report** (`components/MarketReport.tsx`, `web/lib/market-report.ts`), above the grid: a bordered row of cells on `--surface`. The intro cell, `MARKET · 7D` and `median the engine paid, and the lowest asks now: the engine's and the market's. pick a band to filter.`, then one cell per rating band: `under 500`, `500–599`, `600–649`, `650–699`, `700+` (sized to where credits trade; most rate 600 to 650). A band cell: `rating 600–649`, the median the engine paid at its bid or from a listing over the last 7 days (`0.0381 ETH`, 20/600), the change against the 7 days before and how many it bought (`+4.2% · 507 bought`, the change only with 5 or more prior sales), then under a dashed rule the lowest asks now as two key and value rows: `engine 0.0444` (the cheapest held credit in the band) and `market 0.0410` (the cheapest OpenSea or CreditStrategy ask of the keeper's view; `—` without one). A band cell is a filter for the grid: the picked one carries the 3px `--m` edge, picking it again clears it, and an empty pick reads `no credits listed in this band right now.` In chain mode the report reads the newest 200 purchases and says `MARKET · LATEST 200`. Below 1300px the intro takes its own row; below 860px the bands go two to a row.
- **Grid:** 6 columns, 12px gap. Card on `--surface`, 1px `--hairline` border (`--ink` when selected, with a ✓ box top-left on the art). Under the art, from top:
  1. **price** `0.0121` 16/600 + `ETH` 11 `--muted` (the price leads the card);
  2. `#14727` on the left and `rating 61` on the right (12 `--muted`; always the full word "rating");
  3. while the credit sale is on, a dashed rule, then `vs median` and the price against its band's 7-day median paid (`+51%`);
  4. `floor in` on the left (11 `--quiet`) and the time on the right (`--ink`).
  - No "for sale" label and no arrows on cards.
- **Table:** columns `checkbox · art 28 · credit · rating · price ETH · vs median · paid ETH · got by · bought · floor in`. The rating, price, vs median, paid, bought and floor in heads sort: a click sorts by that column, a second flips it, the active head is `--ink` with `↑` or `↓`. A phone keeps rating, price, vs median and floor in.
- **Sort** (`web/lib/credit-sort.ts`): `best value` (default: the price lowest against its band's median first), `price`, `price / pt`, `rating`, `newest`, `composing soon` (the queue, which is also the floor order) and `paid`. A value not known yet sorts last. The choice is kept in this browser. The unit lives in the header, so cells show bare numbers.
- **Rail:**
  - **Buy credits** (shown while `creditSaleOn`): a short explainer, the selected list (thumbnail, `credit #id`, `rating n`, price `ETH`, ×), selected count and total, the `buy 2 credits` button, and `prices keep falling while in window · excess refunded`.
  - Under it, **how compose timing works**: three numbered lines, then `sell your credits to the engine →`.
- **Compose estimate per credit:** credits compose first in, first out, in pages of 80. For a credit at queue position `p`, with `n` held, page index `k = floor(p/80)`, and a buy rate `r` per hour taken from the last ~24h of `CreditBought` events:
  - **page full:** if `(k+1)*80 ≤ n`, ETA = time until the newest credit in that page is past `creditWindow`.
  - **page still filling:** otherwise, ETA = `((k+1)*80 − n) / r` hours + `creditWindow`.
  - Always show it with `~`, rounded to hours (minutes under 2h). With no buys in 24h, show `—`.

### 03 Credit detail (four states: `Credit · for sale`, `Credit · at floor`, `Credit · composed`, `Credit · sold`)
**Main column:** a `440px minmax(0,1fr)` grid with a 48px gap and 40px padding.
- Left: hero art with crop marks, then `PNG ↓  SVG ↓  etherscan ↗` and the registration mark.
- Right:
  - label `credit` and `#id` at 40/500;
  - facts (140px key column): credit rating, holder, paid by engine, got by, acquired, transaction id;
  - **history** rows (72px time, ink mark plus text, 96px value right-aligned).
- Below both, a full-width **plate breakdown** band. It shows the four 8×8 plates (C, M, Y, K, each marked `shown` or `hidden`, with hidden plates at `#cfcdc5`), `=`, the composite, and one explanatory sentence. The header line is `transaction id → SHA-256 → 4 × 8×8 plates → credit`.

**Rail, by state** (from `useCredit` + scan events):
| state | condition | rail |
|---|---|---|
| for sale | `inPile && creditSaleOn && left > 0` | status (M) `for sale` + compose estimate box (`composes into statement 182 in 25h 12m`, `position 6 of 80`, 8×10 mini map with this credit in M); **price** 30/500 + `falling / floor in 2h 34m`; price curve; `buy credit`; **swap** panel |
| at floor | `inPile && left <= 0` | status (K) `at floor, waiting to compose`; compose box; price + `at floor`; curve with the marker on the flat part; buy; swap |
| composed | last event `composed` | status (Y) `composed`; statement card (thumbnail, `statement 180`, its state and price, `view statement →`) |
| sold | last event `sold` | status (C) `sold`; sold for / engine paid / to buyback |
If `creditSaleOn` is false, drop the price, curve and buy section, and keep the status and the compose estimate.

- **Countdown:** the compose estimate on detail shows a live `h m` countdown. On index pages it is a static `~` estimate.
- **Price curve** (SVG 352×92): a 1px `--ink` line falling linearly from the start price to the floor over `creditWindow`, then flat. The floor is a dashed `--hairline` line; now is a dashed vertical with an 8px M square on the line. Labels below: `bought 13:46 · floor 17:46 · composed`.
- **Swap panel** (`Core.swapCredit`): the copy `trade one of your credits with an equal or higher rating for this one.` and `10,000 CC burned` (read `swapFeeCc`). Radio rows show only the wallet's credits that score at or above this one. The button is `swap in credit #id` (secondary). Copy states: not connected → `connect to swap`; none eligible → `none of your credits rates at or above this one.`

### 04 Statements index (`Statements grid`, `Statements table`)
- **Meta:** `5 for sale · 172 sold · 3 redeemed · 180 composed · next composes in ~1h 20m`.
- **Grid:** 6 columns in two sections. The **for sale** section is captioned `price falls over 12h to its floor`; the **sold & redeemed** section follows. Card: art, `statement 180` 600 with `r 412`, then the price `ETH` and a state mark: Y `for sale ↓`, Y `at floor`, divider-colored `sold`, C `redeemed`.
- **Table:** columns `art 40 · statement · rating · format · price ETH · vs cost · state · composed`.

### 05 Statement detail (`Statement detail`)
Same layout as credit detail.
- **Main column:** facts are credit rating, format (`3 · restyled from 5`), engine cost, credits, composed (`6h ago · default compose`), holder. History covers composed, restyled and for sale.
- **Full-width band:** **80 credits** as a 16-column tile grid; each tile links to its credit. The caption reads `composed in the order the engine bought them`.
- **Rail:**
  1. **Status / price.** Y `for sale`; price 30/500 with `falling / floor in 5h 00m`; the curve (1.5× reference falling to the floor over the controller's window, 12h); `buy statement`; then `75% of the sale goes back to the pot · 25% buys and burns $CC`.
  2. **Restyle.** `current: 3`, the copy, and an 8-segment format picker 0–7. The button stays disabled until the user picks a different format **and** holds `minCcToChoose`; it reads `restyle to format n`.
  3. **Redeem.** Always visible while held and `balanceOn`. Disabled until `atFloor && redeemOn`, with the right-side caption `opens at floor · ~5h`; when enabled it reads `redeem for $BALANCE`.

### 05a Forming statement (`components/StatementForming.tsx`)
A statement id the Core has not minted yet: `id >= nextStatementId` (Statements supply plus one). Default compose takes the 80 oldest pile credits and ids are sequential, so page `k = id - nextStatementId` of the pile, credits `k*80` to `k*80+79` oldest first, is that statement while it forms. The `/statements` **forming** cards are its thumbnails and link here; the index and this page share one page split (`web/lib/forming.ts`).

- **States.** `in progress`: the page has fewer than 80 credits (only the last page). `upcoming`: 80 credits, waiting for the newest to clear the sale window, or for an earlier page to compose first. `ready to compose`: page 0, full and past the window (`snapshot.page.ready`). `engine paused` replaces the time while the Core is paused. An id past the last page with credits reads `not forming yet`; a page the chain-mode pile read did not reach (the 200 credit cap) reads `unavailable until the full pile loads`.
- **Main column.** The hero is the thumbnail's art at hero size: the page's actual Credit tiles in the 8×10 sheet grid, empty slots blank, on white with crop marks. Facts: state, credits `52 / 80`, engine cost (`… ETH so far`, the sum of the page's credit costs), credit rating (`… so far`, the sum of their scores, which is the rating the statement will carry; indexer mode only, else `—`), format `set at compose`. History: `now` forming line, newest credit bought, first credit bought, each linking its credit.
- **Full-width band.** The page's credits as the 16-column grid, linking each credit, captioned `gathering in the order the engine bought them`.
- **Rail** (ink Y, hollow status mark). Status and a copy line for the state. Then the compose box: `composes in` a countdown (full page) or `~25h` estimate (filling page, buy rate plus window), the 8×10 mini map of filled slots, and for `k > 0` the caption `after statement N`. Page 0 when ready shows `compose statement` (`Core.compose()`, random format; the compose page keeps the format choice). While the credit sale is on, a caption says the membership is provisional: a credit bought out of the pile leaves the page and the next oldest moves in, and `composeChosen` (off at launch) can take credits out of order.
- **Navigation.** Prev and next run across forming and composed ids, newest first. When the statement composes, the same URL turns into the composed detail on the next refresh.

### 06 Swap states (`TradePanel.tsx`)
The panel, top to bottom:
1. `$CC price` with the 24h change beside it (`+2.4% 24h`, muted, spot now against the spot 7,200 blocks earlier; for a younger pool `since launch`, against the opening price of its PoolManager `Initialize` event), and `mkt cap ↗`, linking to the token's DexScreener page;
2. the buy|sell toggle (36px);
3. the input box on `--surface` with a 1px `--divider` border and two crop marks: a **you pay** field and a **you receive** field;
4. detail rows;
5. an optional notice;
6. the button;
7. the `trading fee` caption, then the token contract (`$CC 0x28ef…c789 ↗`) linking to evm.now.
**The price impact row is removed.**

**Field details:**
- Label row: `you pay` on the left; on the right, `balance 1.204` and `max` (underlined) once connected.
- The amount is 26px. Under any non-zero amount, show `≈ $860` (11 `--muted`), from the ETH/USD feed (`lib/market.ts`) and the pool price.

**Detail rows** (dashed): `to the pot 0.0248 ETH · 9.9%`, `minimum received`, `slippage 1% ▾`.

**Notices:** `--surface`, 1px `--divider`, a 3px left ink edge, a 12/600 title and a 12 `--muted` body.

| # | state | trigger | specifics |
|---|---|---|---|
| 01 | not connected | `!isConnected` | empty fields, only the slippage row, `connect wallet` |
| 02 | no amount | connected, amount empty | balance + max, `enter an amount` disabled |
| 03 | quoting | quoter in flight | `quoting…` beside you receive, receive value at `--disabled`, rows `—`, `getting quote…` disabled |
| 04 | ready | quote ok | full rows, `buy $CC` / `sell $CC` |
| 05 | insufficient | amount > balance | magenta input border, magenta balance and amount, `not enough ETH` / `not enough $CC` disabled |
| 06 | approvals (sell) | allowance missing | step list: approve $CC → approve Permit2 → sell $CC. Done steps show a filled square and their **tx link**; the current step has an M centre; the button names the current step |
| 07 | confirm in wallet | write requested | C notice `confirm in your wallet` / `nothing has been sent yet.`, `waiting for wallet…` disabled. No tx link yet |
| 08 | pending | hash received | `buying $CC` + **tx link** `0x9c4e…07ab ↗`, a 20-cell progress strip, `submitted 8s ago · usually under 30s`, `buying…` disabled |
| 09 | success | receipt ok | result card (`bought`, amount + `≈ $`, **tx link**, paid, to the pot), M notice `your trade fed the engine` / `0.0248 ETH is now in the pot, enough for about n credits at the current bid.` (n = pot share ÷ the bid at rating `refScore`), `trade again` |
| 10 | failed | revert / slippage | M notice with the reason, **reverted tx link**, `try again`. User rejection returns to 04 with no notice |
Panel height may vary between states; the content below it absorbs the change.

---

## Copy rules
- Lowercase everywhere except token symbols and plate letters.
- Prices: always `ETH` after the number, unless the column header already says `price ETH`.
- Say **"held by engine"**, never "pile".
- Always write `rating` in full on cards and rows. The table header may say `rating`.
- Estimates carry `~`. Live countdowns don't.

## Open items to confirm before shipping
- **Trade fee:** the designs say 9.9%, but `Flywheel.tsx` says "skims 10%, 9 points of it into the engine" and the README says 6.9 points. Use the live setting and word the explainer and the `to the pot` row from it.
- **Statement format names:** `0 · grid` … `7 · seal` are placeholders. Use the `Format` attribute from token metadata.
- **Statement art:** the mock uses a stand-in grid. Render the real token image (`useTokenMeta`), square, on white.
- **Buy-rate window** for the compose ETA (suggested: 24h).

## Assets
No image assets. The logo, marks, glyphs, curves and progress strips are CSS or inline SVG. Credit art comes from the existing `CreditTile`. Font: IBM Plex Mono (Google Fonts).

## Files
- `CC Engine Approved.dc.html`: every approved screen, by section: 01 engine, 02 credits index, 03 credit detail, 04 statements, 05 dark mode (token sheet + dark credits grid), 06 swap states. Open it in a browser; `support.js` must sit beside it.
- `support.js`: the runtime for viewing the reference file only. Don't ship it.
- `screenshots/`: one PNG per screen (01–15), named to match the sections above. Use them for visual checks; take measurements from the README and the HTML.
