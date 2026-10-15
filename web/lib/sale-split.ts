// Destination shares of a statement sale price, in percent (Core.sellTo): the artist and operator cuts come off the
// price, then saleToBuybackBps of the rest buys and burns $CC and the remainder goes to the pot.
export function statementSaleSplit(s: { saleToArtistBps: number; saleToOperatorBps: number; saleToBuybackBps: number }) {
  const restBps = 10000 - s.saleToArtistBps - s.saleToOperatorBps;
  const buyback = (restBps * s.saleToBuybackBps) / 1e6;
  return { pot: restBps / 100 - buyback, buyback, cuts: (s.saleToArtistBps + s.saleToOperatorBps) / 100 };
}
