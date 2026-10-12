// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// shared interfaces. fixed by the project director. do not change signatures without sign off.

enum Lane {
    Eth,
    Exit
}

interface IController {
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format);
}

interface IExitModule {
    function exitToken() external view returns (address);
    /// exit token base units per credit
    function unitPerCredit() external view returns (uint256);
    /// called by the core after it transfers the statement to the module
    function exit(uint256 statementId) external returns (uint256 out);
}

/// the surface controllers rely on. piles are insertion ordered linked lists, oldest first
interface ICoreViews {
    function pileSize(Lane lane) external view returns (uint256);
    function pilePage(Lane lane, uint256 startAfter, uint256 n) external view returns (uint256[] memory ids); // startAfter 0 starts at head
    function creditInfo(uint256 id) external view returns (bool inPile, Lane lane, uint256 cost, uint64 acquiredAt);
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 composedAt);
    function heldStatements() external view returns (uint256[] memory sids);
}

/// what the controller needs of the core beyond the views: the live owner and the one door that sells a statement
interface ICoreSale {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function sellTo(uint256 sid, address buyer) external payable;
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
/// in `src/lib/SettingsBounds.sol`. the types are narrow so the whole struct packs into four storage slots
/// (a hot path reads it with a handful of loads). docs/FLOW.md section 2 has the meaning of every field
struct Settings {
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
    /// the hard floor of a statement sale, bps of the statement cost. `sellTo` takes no payment below it and the
    /// controller prices at or above it
    uint16 saleFloorBps;
    /// seconds an eth lane statement must have been held since its compose before phase 2 may redeem it
    uint32 exitAfter;
    /// share of sale proceeds that goes to the coin buyback, bps
    uint16 saleToBuybackBps;
    /// share of exit token from eth lane exits that goes to the coin buyback, bps
    uint16 exitToBuybackBps;
    /// seconds in which the remembered peak halves. the ceiling anchor is `max(last fill rate, peak now)`
    uint32 peakHalfLife;
    /// climb of the eth rate per minute while the price state is below the remembered peak, bps, compounded. at or above
    /// the peak the rate climbs `climbPerMinBps`. at least `climbPerMinBps`
    uint16 recoveryClimbPerMinBps;
    uint128 buybackSlice;
    /// blocks between two coin buybacks
    uint16 buybackDelay;
    /// fixed fee paid to the caller of `buyback` and `buyListing`, wei. the `buyback` fee is scaled by the eth spent over
    /// the largest swap budget the `buybackSlice` setting allows, the `buyListing` fee is paid whole
    uint64 keeperFee;
    /// base fee ceiling of the gas refund of `buyback` and `buyListing`, wei
    uint48 keeperMaxBaseFee;
    /// exit rate cap and floor, bps of one credit's exit value
    uint16 xRateCap;
    uint16 xRateFloor;
    uint16 xRateClimbPerHour;
    uint16 xRateDropPerCredit;
    /// seconds
    uint32 xAuctionHalfLife;
    /// credits per exit buyback slice, each worth `unitPerCredit` of exit token
    uint16 exitSliceCredits;
    /// the most the eth rate can be, wei per credit. the price state and the read stay at or below it, `setRate`
    /// refuses above it, and the rate bounds apply to it
    uint64 rateCap;
    /// share of exit token from EXIT lane exits that goes to the coin buyback, bps, the rest to the exit bid pot
    uint16 exitLaneToBuybackBps;
    /// share of the swap fee eth that the fee router flushes to the core (booked in `receive()`) that goes to the coin buyback,
    /// the rest to the pot, bps. eth booked later by `skim` goes to the pot whole
    uint16 feeToBuybackBps;
    /// fixed fee paid to the caller of `compose`, `composeExit` and `exitStatement`, wei, from `ethPot`. zero turns the
    /// whole payment of those doors off when `callerMaxBaseFee` is zero too
    uint64 callerFee;
    /// base fee ceiling of the gas refund of `compose`, `composeExit` and `exitStatement`, wei. zero refunds no gas
    uint48 callerMaxBaseFee;
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
    /// lowest asking price, bps of the statement cost
    uint16 floorBps;
    /// seconds for the part of the anchor above 10_000 to halve
    uint32 anchorHalfLife;
    /// the least statement cost, in wei, whose sale moves the anchor
    uint128 anchorMinCost;
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
            saleFloorBps: 7_500,
            exitAfter: 105 hours,
            saleToBuybackBps: 5_000,
            exitToBuybackBps: 5_000,
            peakHalfLife: 21_600,
            recoveryClimbPerMinBps: 200,
            buybackSlice: 0.5 ether,
            buybackDelay: 25,
            keeperFee: 0.0005 ether,
            keeperMaxBaseFee: 10 gwei,
            xRateCap: 9_700,
            xRateFloor: 3_000,
            xRateClimbPerHour: 100,
            xRateDropPerCredit: 20,
            xAuctionHalfLife: 6 hours,
            exitSliceCredits: 20,
            rateCap: 26_700_000_000_000_000,
            exitLaneToBuybackBps: 0,
            feeToBuybackBps: 0,
            callerFee: 0,
            callerMaxBaseFee: 0
        });
    }

    /// the launch sale: start at 1.5 times the anchor (at most 1_000 percent of cost), falling 1 percent of cost
    /// an hour to 100 percent, then 0.25 percent an hour to 75 percent, the anchor halving its excess over 10_000 every
    /// 7 days, and moving only on statements that cost at least 0.1 eth
    function defaultSale() internal pure returns (Sale memory) {
        return Sale({
            markupBps: 15_000,
            startCapBps: 100_000,
            fastDecayBpsPerHour: 100,
            kneeBps: 10_000,
            slowDecayBpsPerHour: 25,
            floorBps: 7_500,
            anchorHalfLife: 7 days,
            anchorMinCost: 0.1 ether
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
