// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// shared interfaces. fixed by the project director. do not change signatures without sign off.

interface IController {
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format);
    /// true when the curve price of statement `sid` has reached its floor, `saleFloorBps` of the reference. the curve age
    /// excludes paused seconds, so eligibility is frozen while sales are paused. the core reads it to gate the balance side
    /// redemption
    function atFloor(uint256 sid) external view returns (bool);
    /// true when a credit acquired at `acquiredAt` may be composed: always while the credit sale is off, otherwise once
    /// the credit window has passed. the core reads it to gate a chosen compose
    function pastWindow(uint64 acquiredAt) external view returns (bool);
}

interface IBalanceModule {
    function balanceToken() external view returns (address);
    /// balance token base units per stored score unit. a score is in ten-thousandths of a point (a score of 132.4012 is
    /// stored as 1_324_012), so this is base units per ten-thousandth of a point, not per whole point. a statement
    /// redemption owes `rating * unitPerPoint`, where `rating` is the sum of its credits' stored scores. the core and
    /// the controller read it at each use
    function unitPerPoint() external view returns (uint256);
    /// called by the core after it transfers the statement to the module
    function redeem(uint256 statementId) external returns (uint256 out);
}

interface ICreditScore {
    /// score of a credit in ten-thousandths of a point, 800_000 to 8_000_000 (80 to 800 points). pure in `seed` and
    /// `paidAt`, which are fixed at mint
    function scoreOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
}

/// the surface controllers rely on. the pile is an insertion ordered linked list, oldest first
interface ICoreViews {
    function pileSize() external view returns (uint256);
    function pilePage(uint256 startAfter, uint256 n) external view returns (uint256[] memory ids); // startAfter 0 starts at head
    function creditInfo(uint256 id) external view returns (bool inPile, uint256 cost, uint64 acquiredAt);
    /// wei per credit the eth bid pays now, the price state lowered to the pot
    function ethRate() external view returns (uint256);
    /// wei per credit of the price state now, before the pot clamp `ethRate` applies. the cost basis of an adopted
    /// credit is this price. in later blocks the climb heads toward the larger pot
    function ethPrice() external view returns (uint256);
    /// wei per credit of the floor rate now: the larger of the price state climbed before the pot clamp and the
    /// remembered peak of the eth bid decayed to now. selling credits lowers only the rate and the peak decays between
    /// fills, so the maximum holds against a sale within the block. the controller's `pointRate` divides it by `refScore`
    function floorRate() external view returns (uint256);
    function statementInfo(uint256 sid) external view returns (bool held, uint256 cost, uint64 composedAt);
    /// the seconds a held statement has aged outside every pause. reverts `NotForSale` when the core does not hold it
    function statementAge(uint256 sid) external view returns (uint256);
    /// the stored rating of a statement: the sum of its credits' scores, read from Statements at compose
    function ratingOf(uint256 sid) external view returns (uint256);
    function heldStatements() external view returns (uint256[] memory sids);
    function balanceModule() external view returns (address);
    function balanceToken() external view returns (address);
}

/// what the controller needs of the core beyond the views: the live owner and the two doors that sell custody out, a
/// statement and a pile credit
interface ICoreSale {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function sellTo(uint256 sid, address buyer) external payable;
    /// sends pile credit `id` to `buyer` for `msg.value`, at least the credit's cost. only the controller
    function sellCreditTo(uint256 id, address buyer) external payable;
}

/// the coin calls the core makes. the live token burns from the caller or from an account that approved the caller
interface ICoin {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface ICredits {
    function seedOf(uint256 id) external view returns (bytes21);
    function timestampOf(uint256 id) external view returns (uint64);
    function tokensOf(address owner) external view returns (uint256[] memory);
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function approve(address to, uint256 id) external;
    function transferFrom(address from, address to, uint256 id) external;
}

interface IStatements {
    function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId);
    function creditsOf(uint256 statementId) external view returns (uint256);
    /// the statement's rating, the sum of its credits' scores in ten-thousandths of a point
    function creditScoreOf(uint256 statementId) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function supply() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ICreditStrategy {
    function nftForSale(uint256 tokenId) external view returns (uint256 price);
    function sellTargetNFT(uint256 tokenId) external payable;
}

// bounds of the Core constructor argument `rateStart` and of `rateCap`, wei per credit. one definition for the Core and the scripts
uint256 constant RATE_START_MIN_WEI = 1e13;
uint256 constant RATE_START_MAX_WEI = 1e18;

// the most gas of a buyback the caller's refund counts, so a gas burning hook cannot inflate it. a buyback counts
// about 267,000 gas. read by the Core and by the `buybackSlice` bound
uint256 constant BUYBACK_GAS = 600_000;

// the most gas of a buyListing the caller's payment counts, so a gas burning target cannot inflate it. the largest
// measured buyListing (CreditStrategy path, four gas burning router payees flushing) is 946,000 gas as a transaction,
// 450,000 to 490,000 without the router load. read by the Core
uint256 constant BUYLISTING_GAS = 1_500_000;

/// every economic setting of the Core. one struct in Core storage, owner settable at once through `setSettings`, bounds
/// in `src/lib/SettingsBounds.sol`. the types are narrow so the whole struct packs into three storage slots
/// (a hot path reads it with a handful of loads). the field order is the slot layout: slot 0 holds the rate and sale
/// fields and the balance mode and bps, slot 1 the buyback and keeper fields, slot 2 the rate cap, caller fields and fee
/// split. docs/FLOW.md section 2 has the meaning of every field
struct Settings {
    // slot 0
    /// fall of the eth rate per credit bought, bps of the rate before that credit
    uint16 dropPerCreditBps;
    /// within one minute the rate falls no lower than this share of the rate at the first fill of that minute, bps
    uint16 dropFloorBps;
    /// climb of the eth rate per minute, bps, compounded
    uint16 climbPerMinBps;
    /// the rate stays at or below this share of the ceiling anchor, bps. the anchor is the rate of the last fill
    uint16 ceilBps;
    /// growth of the ceiling anchor per full 10 minutes since the last fill, bps of the anchor
    uint16 idleLoosenBps;
    /// the floor of a statement sale, bps of the statement cost in `sellTo` and bps of the controller reference in the
    /// controller's curve. the reference is at least the cost, so the controller's floor is at least the Core's
    uint16 saleFloorBps;
    /// share of sale proceeds that goes to the coin buyback, bps
    uint16 saleToBuybackBps;
    /// climb of the eth rate per minute while the price state is below the recovery level
    /// `peak * (10_000 - recoveryGapBps) / 10_000`, bps, compounded. at or above the level the rate climbs
    /// `climbPerMinBps`. at least `climbPerMinBps`
    uint16 recoveryClimbPerMinBps;
    /// the recovery climb applies only while the price state is more than `recoveryGapBps` below the remembered peak,
    /// bps of the peak: below `peak * (10_000 - recoveryGapBps) / 10_000`. at or above that level the climb is
    /// `climbPerMinBps`. 0 makes every fill start the recovery climb
    uint16 recoveryGapBps;
    /// seconds in which the remembered peak halves. the ceiling anchor is `max(last fill rate, peak now)`
    uint32 peakHalfLife;
    /// blocks between two coin buybacks
    uint16 buybackDelay;
    /// whether `redeemStatement` runs
    bool redeemOn;
    /// whether `sellForBalance` runs
    bool balanceBidOn;
    /// a redemption must raise the balance token balance by at least `rating * unitPerPoint * (10_000 - redeemSlippageBps)
    /// / 10_000`, bps
    uint16 redeemSlippageBps;
    /// the balance token bid pays `score * unitPerPoint * (10_000 - balanceBidMarginBps) / 10_000` per credit, bps
    uint16 balanceBidMarginBps;
    /// share of `ethRedeemBurn` moved into the coin buyback on each redemption, bps
    uint16 redeemBurnBps;
    // slot 1
    uint128 buybackSlice;
    /// fixed fee paid to the caller of `buyback` and `buyListing`, wei. the `buyback` fee is scaled by the eth spent over
    /// the largest swap budget the `buybackSlice` setting allows, the `buyListing` fee is paid whole
    uint64 keeperFee;
    /// base fee ceiling of the gas refund of `buyback` and `buyListing`, wei
    uint48 keeperMaxBaseFee;
    // slot 2
    /// the most the eth rate can be, wei per credit. the price state and the read stay at or below it, `setRate`
    /// refuses above it, and the rate bounds apply to it
    uint64 rateCap;
    /// fixed fee paid to the caller of `compose` and `redeemStatement`, wei, from `ethPot`. zero turns the whole payment
    /// of those doors off when `callerMaxBaseFee` is zero too
    uint64 callerFee;
    /// base fee ceiling of the gas refund of `compose` and `redeemStatement`, wei. zero refunds no gas
    uint48 callerMaxBaseFee;
    /// share of the swap fee eth booked in `receive()` that fills `ethRedeemBurn`, bps. the rest goes to the pot. eth
    /// booked later by `skim` goes to the pot whole
    uint16 feeToRedeemBurnBps;
}

/// the sale settings of the controller, its constructor argument and the `sale` block of the launch config.
/// bounds are enforced by the controller (docs/FLOW.md 9.3). the controller keeps one more value, the anchor, which
/// starts at 10_000
struct Sale {
    /// the start price over the anchor, bps
    uint16 markupBps;
    /// the most the start price can be, bps of the statement cost
    uint32 startCapBps;
    /// fall of the asking price per hour above the knee, bps of the statement cost
    uint16 fastDecayBpsPerHour;
    /// the price where the fast fall ends and the slow fall starts, bps of the statement cost
    uint32 kneeBps;
    /// fall of the asking price per hour at or below the knee, bps of the statement cost
    uint16 slowDecayBpsPerHour;
    /// seconds for the part of the anchor above 10_000 to halve
    uint32 anchorHalfLife;
    /// the least statement cost, in wei, whose sale moves the anchor
    uint128 anchorMinCost;
}

/// the credit settings of the launch: the constructor arguments the Core and the controller take for the credit sale
/// window, chosen composition and the rating reference. owner adjustable afterwards, so the launch rules only check
/// bounds (`src/lib/CreditBounds.sol`). the Core reads `costToPotBps`, `chosenComposeOn` and `minCcToChoose`; the
/// controller reads `saleOn`, `window`, `floorBps`, `startBps` and `refScore`
struct Credit {
    // core
    /// share of the sold credit's cost booked to the buying pot, bps. the rest of the payment funds the coin buyback.
    /// 0 to 10_000
    uint16 costToPotBps;
    /// whether a caller may name the 80 credits and the format of a compose through `composeChosen`
    bool chosenComposeOn;
    /// least coin balance a caller of `composeChosen` must hold
    uint96 minCcToChoose;
    // controller
    /// whether pile credits are for sale from acquisition and compose waits for a credit's window to pass
    bool saleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit sits before compose may
    /// take it. 1 minute to 30 days
    uint32 window;
    /// the credit sale floor over the larger of the credit's cost and its `valueOf` score, bps. 10_000 to 40_000
    uint16 floorBps;
    /// the credit sale start price over the floor, bps. 10_000 to 200_000
    uint32 startBps;
    /// the per-credit score the statement reference divides the rating by, in ten-thousandths of a point. 1 to 8_000_000
    uint32 refScore;
    /// the share of every sale price added on top and claimable by `royaltyRecipient`, bps. 0 to 1_000
    uint16 royaltyBps;
    /// the address `claimRoyalty` pays
    address royaltyRecipient;
}

/// the artcoins stack a launch runs on. a deploy input of the Core, so a new artcoins version needs no code change.
/// `feeSource` (the fee router) is the only address whose eth the Core books as fees. the rest feed the pool key and the
/// forbidden targets
struct Stack {
    address poolManager;
    address hook;
    int24 tickSpacing;
    uint24 poolFee;
    address factory;
    address locker;
    address escrow;
    /// the fee router: the pool's bounty recipient. the Core books eth from it as fees and forbids it as a target
    address feeSource;
}

library Mainnet {
    address internal constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address internal constant STATEMENTS = 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b;
    /// scores a credit from its seed and paid time. read for the balance token bid, once per credit sold
    address internal constant CREDIT_SCORE = 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7;
    address internal constant CREDIT_STRATEGY = 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6;
    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // the artcoins v2 stack addresses are config inputs and not constants: `defaultStack` leaves them zero, the Core
    // refuses a zero member and the deploy script refuses a zero config. script/config/v2-mainnet.json records the live
    // stack, script/config/mainnet.json carries it into the launch config, test/utils/V2Stack.sol reads it for the tests

    /// the dynamic fee flag every artcoins pool uses, and its tick spacing
    uint24 internal constant POOL_FEE = 0x800000;
    int24 internal constant TICK_SPACING = 200;

    /// the launch values of docs/FLOW.md section 2
    function defaultSettings() internal pure returns (Settings memory) {
        return Settings({
            dropPerCreditBps: 50,
            dropFloorBps: 5_000,
            climbPerMinBps: 50,
            ceilBps: 11_000,
            idleLoosenBps: 200,
            saleFloorBps: 10_000,
            saleToBuybackBps: 5_000,
            recoveryClimbPerMinBps: 200,
            recoveryGapBps: 1_000,
            peakHalfLife: 21_600,
            buybackDelay: 25,
            redeemOn: false,
            balanceBidOn: false,
            redeemSlippageBps: 200,
            balanceBidMarginBps: 2_000,
            redeemBurnBps: 2_000,
            buybackSlice: 0.5 ether,
            keeperFee: 0.0005 ether,
            keeperMaxBaseFee: 10 gwei,
            rateCap: 26_700_000_000_000_000,
            callerFee: 0,
            callerMaxBaseFee: 0,
            feeToRedeemBurnBps: 1_000
        });
    }

    /// the launch sale: start at 1.5 times the anchor (at most 1_000 percent of cost), falling 1 percent of cost
    /// an hour to 100 percent of cost, where it stays (the knee and the floor are both 100 percent), the anchor halving
    /// its excess over 10_000 every 7 days, and moving only on statements that cost at least 0.1 eth
    function defaultSale() internal pure returns (Sale memory) {
        return Sale({
            markupBps: 15_000,
            startCapBps: 100_000,
            fastDecayBpsPerHour: 100,
            kneeBps: 10_000,
            slowDecayBpsPerHour: 25,
            anchorHalfLife: 7 days,
            anchorMinCost: 0.1 ether
        });
    }

    /// the launch credit settings: the credit sale is off, its window is 4 hours, the floor is 110 percent and the
    /// start 300 percent of the floor, the reference per-credit score is the launch average, the whole credit cost
    /// funds the pot, and chosen composition is off with no coin balance required
    function defaultCredit() internal pure returns (Credit memory) {
        return Credit({
            costToPotBps: 10_000,
            chosenComposeOn: false,
            minCcToChoose: 0,
            saleOn: false,
            window: 4 hours,
            floorBps: 11_000,
            startBps: 30_000,
            refScore: 4_330_000,
            royaltyBps: 250,
            royaltyRecipient: address(0)
        });
    }

    /// the default stack: the fixed parts of mainnet. the v2 members (hook, factory, locker, escrow) and the fee router
    /// are zero and are filled by the config before a launch
    function defaultStack() internal pure returns (Stack memory) {
        return Stack({
            poolManager: POOL_MANAGER,
            hook: address(0),
            tickSpacing: TICK_SPACING,
            poolFee: POOL_FEE,
            factory: address(0),
            locker: address(0),
            escrow: address(0),
            feeSource: address(0)
        });
    }
}
