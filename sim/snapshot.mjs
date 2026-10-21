// Reads the deployed Core and controller at a pinned block and writes sim/live-state.json, the sim's launch
// parameter source. Owner rule: a contract that exists on mainnet is read from its live state, never a config copy.
// Reuses packages/engine (its ABIs and the viem multicall snapshot); it does not define a second ABI set.
//
// This runs once offline and commits the JSON; the sim reads the committed JSON and never calls RPC at run time.
// usage: MAINNET_RPC_URL=<url> node sim/snapshot.mjs [blockNumber]   (default block 26242107)
// rpc: MAINNET_RPC_URL from the environment, else the owner's Tenderly public gateway. The URL is never written to the
// output, logged or committed (it may carry a key).

import { writeFileSync } from 'node:fs';
import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { readSnapshot } from '../packages/engine/src/snapshot.ts';
import { coreAbi, controllerAbi } from '../packages/engine/src/abis.ts';

const CORE = '0xcdb1889ae12074d750CD9B8531B692015465e0dD';
const RPC = process.env.MAINNET_RPC_URL || 'https://gateway.tenderly.co/public/mainnet';
const DEFAULT_BLOCK = 26242107n;

// the 39 Settings fields in the struct's declaration order (script/SettingsFields.sol); the config stores each as a
// JSON number except minCcToChoose, so the sim consumes the live values through the same code path as the config
const SETTINGS_FIELDS = [
  'dropPer100PointsBps', 'dropFloorBps', 'climbPerMinBps', 'ceilBps', 'idleLoosenBps', 'saleFloorBps',
  'saleToBuybackBps', 'recoveryClimbPerMinBps', 'recoveryGapBps', 'peakHalfLife', 'buybackDelay', 'redeemOn',
  'balanceBidOn', 'redeemSlippageBps', 'balanceBidMarginBps', 'redeemBurnBps', 'buybackSlice', 'keeperFee',
  'keeperMaxBaseFee', 'rateCap', 'callerFee', 'callerMaxBaseFee', 'feeToRedeemBurnBps', 'payeePpm', 'pointsPerPage',
  'swapFeeCc', 'saleToArtistBps', 'saleToOperatorBps', 'climbMultiplierCapBps', 'spendCapBps', 'bucketSeconds',
  'balanceBidCapBps', 'idleStepSeconds', 'sniperSeconds', 'reserveWei', 'returnLockSeconds', 'valueModeOn',
  'buyToArtistBps', 'balanceDiscountBps',
];

async function main() {
  const block = process.argv[2] ? BigInt(process.argv[2]) : DEFAULT_BLOCK;
  const client = createPublicClient({ chain: mainnet, transport: http(RPC) });

  // readSnapshot pins to the latest block; pin to the requested block by reading through it directly instead
  const snap = await readSnapshot({
    multicall: (args) => client.multicall({ ...args, blockNumber: block }),
    getBlockNumber: async () => block,
  }, CORE);

  const blk = await client.getBlock({ blockNumber: block });
  // the fields readSnapshot does not already return, in one pinned multicall: RATE_START (a Core view the engine ABI
  // subset omits) and the chain-held controller sale and credit terms. the sale half-life and anchor move/minCost have
  // no view and stay in the config
  const core = { address: CORE, abi: coreAbi };
  const ctrl = { address: snap.controller, abi: controllerAbi };
  const [rateStart, markupBps, startCapBps, decayHours, creditSpreadBps, creditStartBps, creditWindow] = await client.multicall({
    allowFailure: false,
    blockNumber: block,
    contracts: [
      { ...core, functionName: 'RATE_START' },
      { ...ctrl, functionName: 'markupBps' },
      { ...ctrl, functionName: 'startCapBps' },
      { ...ctrl, functionName: 'decayHours' },
      { ...ctrl, functionName: 'creditSpreadBps' },
      { ...ctrl, functionName: 'creditStartBps' },
      { ...ctrl, functionName: 'creditWindow' },
    ],
  });

  const s = snap.settings;
  const settings = {};
  for (const k of SETTINGS_FIELDS) {
    const v = s[k];
    settings[k] = typeof v === 'boolean' ? v : Number(v);
  }

  // controller.quote(), the protected price settings; minLiquidity is a uint128 (stored as the config's number)
  const vq = snap.value.quote;
  const quote = { ...vq, minLiquidity: Number(vq.minLiquidity) };

  const out = {
    core: CORE,
    controller: snap.controller,
    blockNumber: Number(block),
    timestamp: Number(blk.timestamp),
    rateStart: Number(rateStart), // Core.RATE_START(), wei per 100 points; the sim's rateStart
    settings,
    // the chain-held controller sale fields; anchorHalfLife, anchorMinCost and anchorMoveBps have no view and stay in
    // the config
    sale: { markupBps: Number(markupBps), startCapBps: Number(startCapBps), decayHours: Number(decayHours) },
    // Core and controller credit fields (config credit.* names)
    credit: {
      costToPotBps: Number(snap.creditCostToPotBps),
      chosenComposeOn: snap.chosenComposeOn,
      minCcToChoose: snap.minCcToChoose.toString(),
      saleOn: snap.creditSaleOn,
      window: Number(creditWindow),
      spreadBps: Number(creditSpreadBps),
      startBps: Number(creditStartBps),
    },
    quote, // controller.quote()
    // the pot balances the sim models, wei as strings
    pots: {
      ethPot: snap.ethPot.toString(),
      ethToBuyback: snap.ethToBuyback.toString(),
      ethRedeemBurn: snap.ethRedeemBurn.toString(),
      coreEth: snap.coreEth.toString(),
      reserve: snap.reserve.toString(),
    },
  };

  writeFileSync(new URL('./live-state.json', import.meta.url), JSON.stringify(out, null, 2) + '\n');
  console.log('wrote sim/live-state.json at block', out.blockNumber);
}

main().catch((e) => { console.error(e); process.exit(1); });
