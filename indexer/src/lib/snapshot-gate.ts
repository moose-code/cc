/** A persisted row marks a canonical snapshot complete; a failed write or rollback leaves it absent. */
export async function snapshotOnce(
  blockNumber: bigint,
  find: (blockNumber: bigint) => Promise<unknown>,
  write: () => Promise<void>,
): Promise<void> {
  if (await find(blockNumber)) return;
  await write();
}
