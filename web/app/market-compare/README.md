# Private Credit / BALANCE comparison

Read-only operator page at /market-compare. No navigation link. During \`next dev\`, it is available without a password. In production/preview it returns 404 unless both server-only \`MARKET_COMPARE_ENABLED=true\` and a random \`MARKET_COMPARE_PASSWORD\` (20+ characters) are set; the browser uses HTTPS Basic Auth (username \`cc\`). Do not use a short password. No credentials go into NEXT_PUBLIC variables.

The page reuses the existing /api/listings keeper view (OpenSea + CreditStrategy), displays its freshness, and reads BALANCE Uniswap v4 onchain pool spot and exact-input sell quotes. When ControllerV2 has a configured pool key, that is authoritative. Before Stage C, provide all four NEXT_PUBLIC_COMPARE_* pool fields in the environment: BALANCE token, fee, tick spacing and hook. Use parameters verified from a live initialized pool; no pool is guessed. Set these for local forks too.

Without a valid BALANCE pool, the page shows the ETH listing/rating ranking but refuses to invent token conversions. When CC's BALANCE bid is not live, its 80% payout is explicitly a configuration preview, not an executable offer. When it is live, the page reads per-Credit \`balanceBidOf\` for displayed rows. Table ETH values use pool *spot* estimates; choosing a row displays a separate Uniswap v4 exact-input quote for its payout (subject to movement, fees and gas). No purchase route is called.

The 10% contribution is taken from successful Statement conversion receipts; it is not deducted from the Credit seller's payout. The 3% artist/operator fee is **on top of** the seller payout. The surplus calculation is for BALANCE-funded purchases that are actually composed and redeemed at par, not ETH-funded acquisitions, and excludes gas.
