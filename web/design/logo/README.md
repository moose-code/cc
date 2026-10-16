# Handoff: CC logo — four-slot loop

Replaces the current stepped three-square logo everywhere it appears (header on all pages, favicon, OG image). CC = credit cycle: three CMY squares sit on a four-corner track and step clockwise.

Open `preview.html` to see it in motion (light + dark, 160px and 22px header lockup).

## Files
- `CCLogo.tsx` — React component, drop into `web/components/`
- `cc-logo.css` — blend mode per theme; import globally
- `preview.html` — standalone reference

## Geometry (100×100 unit box, scales linearly)
- 3 squares, 58×58
- 4 slots clockwise: TL (6,6) · TR (36,6) · BR (36,36) · BL (6,36)
- Colours in order: C `#00a3e0`, M `#e5007e`, Y `#ffd400`
- Square *i* sits in slot `(i + step) % 4`. Rest frame (step 0): C TL, M TR, Y BR, BL empty.
- Blend: `multiply` on light, `screen` on dark
- Step transition: `left/top .7s cubic-bezier(.6,0,.3,1)`

## Behaviour
- **Header (22px):** static by default. Advance `step` by 1 each time a credit-acquired event lands (same event that updates the next-credit indicator). So the logo literally cycles once per credit.
- **Pending acquire tx:** optional `autoplay` while the user's acquire transaction is pending; stop on success/failure.
- **Reduced motion:** no transitions, no autoplay (handled in component).
- **Favicon / OG / static exports:** rest frame (step 0). Export SVG from the geometry above.

## Implementation steps
1. Add `CCLogo.tsx` and import `cc-logo.css` in the root layout.
2. Replace the existing logo markup in the header with `<CCLogo size={22} step={creditsAcquiredCount} />`. Keep the `CC` / `engine` wordmark next to it unchanged (gap 12px).
3. Wire `step` to the acquired-credit counter (any monotonically increasing number works; component mods by 4).
4. Set `autoplay` on the header logo while an acquire tx from the header button is pending.
5. Generate `favicon.svg` from the rest frame:
   ```svg
   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
     <g style="mix-blend-mode:multiply">
       <rect x="6" y="6" width="58" height="58" fill="#00a3e0"/>
       <rect x="36" y="6" width="58" height="58" fill="#e5007e"/>
       <rect x="36" y="36" width="58" height="58" fill="#ffd400"/>
     </g>
   </svg>
   ```
   Note: add `style="isolation:isolate"` on the root if the blend doesn't render in some favicon contexts; fallback is fine without blending.

## Check
- Light and dark header: overlaps darken (light) / brighten (dark) correctly.
- Logo steps exactly once per acquisition, never on page navigation.
- Reduced-motion: positions jump without animation.
