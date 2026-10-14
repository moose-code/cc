// Hand-written subset of src/interfaces/ICore.sol, IControllerV1.sol and
// ISeaportBasicAdapter.sol: the views and actions the app calls, and the events
// the feed decodes.

import { parseAbi } from "viem";

export const coreAbi = parseAbi([
  // views
  "function COIN() view returns (address)",
  "function controller() view returns (address)",
  "function balanceModule() view returns (address)",
  "function balanceToken() view returns (address)",
  "function ethRate() view returns (uint256)",
  "function ethPrice() view returns (uint256)",
  "function floorRate() view returns (uint256)",
  "function ethPot() view returns (uint256)",
  "function ethToBuyback() view returns (uint256)",
  "function ethRedeemBurn() view returns (uint256)",
  "function balancePot() view returns (uint256)",
  "function payeeOwed() view returns (uint256)",
  "function pileSize() view returns (uint256)",
  "function pilePage(uint256 startAfter, uint256 n) view returns (uint256[] ids)",
  "function creditInfo(uint256 id) view returns (bool inPile, uint256 cost, uint64 acquiredAt)",
  "function heldStatements() view returns (uint256[] sids)",
  "function statementInfo(uint256 sid) view returns (bool held, uint256 cost, uint64 composedAt)",
  "function statementAge(uint256 sid) view returns (uint256)",
  "function ratingOf(uint256 sid) view returns (uint256)",
  "function composerOf(uint256 sid) view returns (address)",
  "function settings() view returns ((uint16 dropPerCreditBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm))",
  "function paused() view returns (bool)",
  "function retired() view returns (bool)",
  "function chosenComposeOn() view returns (bool)",
  "function minCcToChoose() view returns (uint96)",
  // actions
  "function sellForEth(uint256[] ids, uint256 minOut)",
  "function sellForBalance(uint256[] ids, uint256 minOut)",
  "function compose()",
  "function compose(uint8 format)",
  "function composeChosen(uint256[80] ids, uint8 format)",
  "function setHeldFormat(uint256 sid, uint8 format)",
  "function redeemStatement(uint256 sid)",
  "function buyback()",
  "function book()",
]);

export const controllerAbi = parseAbi([
  // views
  "function priceOf(uint256 sid) view returns (uint256 price)",
  "function grossPriceOf(uint256 sid) view returns (uint256)",
  "function referenceOf(uint256 sid) view returns (uint256)",
  "function atFloor(uint256 sid) view returns (bool)",
  "function creditPrice(uint256 id) view returns (uint256 price)",
  "function grossCreditPrice(uint256 id) view returns (uint256)",
  "function creditSaleOn() view returns (bool)",
  "function creditWindow() view returns (uint32)",
  "function pastWindow(uint64 acquiredAt) view returns (bool)",
  "function nextPage() view returns (bool ready, uint256[80] ids, uint8 format)",
  "function pointRate() view returns (uint256)",
  "function valueOf(uint256 points) view returns (uint256)",
  "function royaltyOwed() view returns (uint256)",
  // actions
  "function buy(uint256 sid) payable",
  "function buyCredit(uint256 id) payable",
  "function buyCredits(uint256[] ids) payable",
  "function claimRoyalty()",
]);

// Credits: the holdings read and the Core approval.
export const creditsAbi = parseAbi([
  "function tokensOf(address owner) view returns (uint256[])",
  "function isApprovedForAll(address owner, address operator) view returns (bool)",
  "function setApprovalForAll(address operator, bool approved)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address a) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

export const tokenUriAbi = parseAbi(["function tokenURI(uint256 id) view returns (string)"]);

// Events of the Core and the controller.
export const engineEventsAbi = parseAbi([
  // Core
  "event CreditBought(uint256 indexed id, address indexed from, uint256 cost)",
  "event EthRateFill(uint256 spent, uint256 rate, uint256 pot)",
  "event ListingBought(uint256 indexed id, address indexed adapter, address indexed caller, uint256 cost, uint256 paid, uint256 rate)",
  "event CreditAdopted(uint256 indexed id, uint256 cost)",
  "event Composed(uint256 indexed sid, uint256[80] ids, uint8 format, uint256 cost, address indexed caller)",
  "event HeldFormatSet(uint256 indexed sid, uint8 format, address indexed caller)",
  "event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback)",
  "event CreditSold(uint256 indexed id, address indexed buyer, uint256 price)",
  "event StatementRedeemed(uint256 indexed sid, uint256 received)",
  "event Buyback(address indexed caller, uint256 amountIn, uint256 paid)",
  "event FeesAdded(uint256 amount)",
  "event Funded(address indexed from, uint256 amount)",
  "event SettingsSet((uint16 dropPerCreditBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm) settings)",
  "event PausedSet(bool paused)",
  "event ControllerSet(address controller)",
  "event BalanceModuleSet(address balanceModule, address balanceToken, uint256 unitPerPoint)",
  // ControllerV1
  "event Bought(uint256 indexed sid, address indexed buyer, uint256 price)",
  "event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps)",
  "event RoyaltyClaimed(address indexed to, uint256 amount)",
]);

// The coin burn is Transfer(core, address(0), amount); the balance token paid to a seller is Transfer(core, seller, amount).
export const transferEventAbi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"]);
