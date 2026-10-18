// Jack's balance token constants, the single source the sim's balance model reads.
// ConversionLineageWithdrawals in jckbtchr-vv/credits at commit 9318c713974ee18658ac5aeddab45f0e1e45b585
// (SCORE_TO_TOKEN, decimals, the quote and withdraw math). script/tools/upstream-balance.sh pins and verifies the same
// build; test/UpstreamBalance.t.sol and test/LaunchDayPhase2.t.sol assert these against the real bytecode on a fork.
// A change in Jack's repo is a one-line change here.

// token decimals.
export const DECIMALS = 18;
// one whole balance token in base units.
export const ONE = 10 ** DECIMALS;
// base units a redemption owes per stored score unit. a score is in ten-thousandths of a point, so this is base units
// per ten-thousandth of a point. Jack's SCORE_TO_TOKEN and the module's unitPerPoint.
export const UNIT_PER_POINT = 1e14;

// the base units Jack's contract quotes, and pays on withdraw, for a statement of stored rating `scoreUnits`
// (the sum of its credits' stored scores). quote == withdraw == scoreUnits * UNIT_PER_POINT.
export function redeemQuote(scoreUnits) {
  return scoreUnits * UNIT_PER_POINT;
}
