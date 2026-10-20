// Public builds stay closed until the owner explicitly enables publication; local development remains available.
export function exchangeEnabled(mode: string | undefined, enabled: string | undefined) {
  return mode === "development" || enabled === "true";
}
