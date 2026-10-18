// A deferred coin needs polling only until its code appears.
export function coinCodePollInterval(live: boolean | undefined): number | false {
  return live === false ? 15_000 : false;
}
