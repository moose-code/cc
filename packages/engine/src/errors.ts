// One line for a failed transaction or simulation, read from the viem error chain.

export const CANCELLED = "cancelled in wallet";

// shortMessage, metaMessages, details and errorName of up to 6 nested causes. Router and quoter reverts missing from
// the abi arrive as the 4 byte selector.
export function txError(e: unknown): string {
  const parts: string[] = [];
  let cur: any = e;
  for (let d = 0; cur && d < 6; d++, cur = cur.cause) {
    parts.push(cur.shortMessage, ...(cur.metaMessages ?? []), cur.details, cur.data?.errorName, cur.name);
    if (!cur.shortMessage && cur.message) parts.push(String(cur.message).split("\n")[0]);
  }
  const all = parts.filter(Boolean).join("\n");
  if (/user rejected|user denied|rejected the request/i.test(all)) return CANCELLED;
  if (/SpendCapReached|0x3e085885/i.test(all)) return "eth purchase budget exhausted, try again in the next bucket";
  if (/ReturnLocked|0x8dd81991/i.test(all)) return "the engine sold this credit recently, it returns after the return lock";
  if (/NoQuote|0xc3186163/i.test(all)) return "the balance token price quote is unavailable, eth sales and engine sales wait for it";
  if (/V4TooLittleReceived|V4TooMuchRequested|slippage|0x8b063d73|0x12bacdd3/i.test(all)) return "price moved, try again";
  if (/TransactionDeadlinePassed|0x5bf6f916/.test(all)) return "deadline passed, try again";
  if (/insufficient funds/i.test(all)) return "not enough eth for gas";
  const sig = all.match(/reverted with the following signature:\s*(0x[0-9a-f]{8})/i)?.[1];
  if (sig) return `reverted ${sig}`;
  const named = all.match(/(?:error|reverted with reason):?\s+(\w+)\(/i)?.[1];
  return (named ?? parts.find(Boolean) ?? "transaction failed").slice(0, 80);
}

// the custom error name of a revert in the chain (`errorName` of a decoded ContractFunctionRevertedError), if any
export function revertName(e: unknown): string | undefined {
  let cur: any = e;
  for (let d = 0; cur && d < 6; d++, cur = cur.cause) if (cur.data?.errorName) return cur.data.errorName;
  return undefined;
}
