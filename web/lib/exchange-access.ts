// Public builds stay closed until the owner explicitly enables publication; local development remains available.
// The same rule gates every private route: the server-only flag must be exactly "true" outside next dev.
function privateRouteEnabled(mode: string | undefined, enabled: string | undefined) {
  return mode === "development" || enabled === "true";
}

// /claim, the CC burn for a share of the claim reserve: CLAIM_ENABLED, off in production and deploy previews until the
// owner opens CC burns (decision 260 stage D), open in local development
export function claimEnabled(mode: string | undefined, enabled: string | undefined) {
  return privateRouteEnabled(mode, enabled);
}
