// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BidModel} from "../utils/BidModel.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {
    ICredits,
    ICreditScore,
    ICreditStrategy,
    IStatements,
    Mainnet,
    Settings,
    RATE_SCORE,
    BUYBACK_GAS,
    BUYLISTING_GAS
} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsTokenV2, IArtCoinsMevSkimV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {MockBalanceModule} from "../standins/MockBalanceModule.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";
import {ComposeCall} from "../utils/ComposeCall.sol";

/// everything the handler needs to know about the system under test.
struct Wiring {
    ICore core;
    IArtCoinsTokenV2 coin;
    TestSwapRouter router;
    PoolKey launchKey;
    bytes32 poolId;
    address hook;
    address mev;
    address owner;
    address v1;
    FuzzController fuzz;
    ProbeTarget probe;
    address rawAdapter;
    MockBalanceModule module;
    MockBalanceToken balanceToken;
    bool canSwapController;
    string tag;
}

/// @notice base of the handler for the SPEC section 10 invariant suites, on the flow rework surface. every action is bounded, never reverts, and keeps
/// ghost accounting that the invariant functions check. a violation is written to the `viol` counters and never
/// asserted here, because under `fail_on_revert = false` a reverting handler would hide it.
///
/// actors hold real credits moved out of the CreditStrategy by prank in the fixture. coin trades go through the
/// real launch pool on the real PoolManager under the live skim hook, which pays its bounty into the core's
/// `receive()`, where it waits for the next book. the anti sniper window skims up to 90 percent of a swap, so the fee model reads the live skim rate.
abstract contract HandlerBase is Test {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 internal constant A_BUY_COIN = 0;
    uint8 internal constant A_SELL_COIN = 1;
    uint8 internal constant A_SELL_FOR_ETH = 2;
    uint8 internal constant A_LISTING_STRATEGY = 3;
    uint8 internal constant A_LISTING_HOSTILE = 4;
    uint8 internal constant A_WARP = 5;
    uint8 internal constant A_ROLL = 6;
    uint8 internal constant A_COMPOSE = 7;
    uint8 internal constant A_BUYBACK = 8;
    uint8 internal constant A_SWAP_CREDIT = 9; // a holder swaps a pile credit for one of equal or higher score
    uint8 internal constant A_DONATE = 10;
    uint8 internal constant A_CONTROLLER_SEED = 11;
    uint8 internal constant A_CONTROLLER_SWAP = 12;
    uint8 internal constant A_PROBE_CONTROLLER = 13;
    uint8 internal constant A_SELL_FOR_BALANCE = 14;
    uint8 internal constant A_REDEEM_STATEMENT = 15;
    uint8 internal constant A_MODULE_MODE = 16;
    uint8 internal constant A_WALLET_MOVE = 17;
    uint8 internal constant A_SET_SETTINGS = 18;
    uint8 internal constant A_SET_INVALID = 19;
    uint8 internal constant A_SET_RATE = 20;
    uint8 internal constant A_OWNER_MISC = 21;
    uint8 internal constant A_REPLACE_MODULE = 22;
    // the sale and owner actions of HandlerSale
    uint8 internal constant A_BUY = 23;
    uint8 internal constant A_OWNER_SELL = 24;
    uint8 internal constant A_SALE_SETTINGS = 25;
    uint8 internal constant A_HOSTILE_OWNER = 26;
    uint8 internal constant A_LOCK = 27;
    uint8 internal constant A_HANDOVER = 28;
    // anyone books the fee income and forces the payee share out, now and then after the owner replaces the payee
    uint8 internal constant A_BOOK = 29;
    // reserved: the former standalone payee claim, folded into the book under the push model
    uint8 internal constant A_CLAIM_PAYEE = 30;
    // the owner takes a stray NFT out of the core
    uint8 internal constant A_RESCUE_NFT = 31;
    // the successor doors and the migration of everything the core tracks
    uint8 internal constant A_MIGRATE = 32;
    // anyone puts credits the core holds without a record into the eth pile
    uint8 internal constant A_ADOPT = 33;
    // the owner pauses and resumes sales on the core
    uint8 internal constant A_PAUSE = 34;
    // the module changes its unit and the owner releases part of the redeem burn reserve
    uint8 internal constant A_CHANGE_UNIT = 35;
    uint8 internal constant A_RELEASE_REDEEM = 36;
    // the credit sale window: a buyer pays the curve price of one pile credit, or a batch of them
    uint8 internal constant A_BUY_CREDIT = 37;
    uint8 internal constant A_BUY_CREDITS = 38;
    // a caller names the 80 pile credits and the format of a compose
    uint8 internal constant A_COMPOSE_CHOSEN = 39;
    // the owner sets the credit sale, chosen compose and rating reference settings
    uint8 internal constant A_CREDIT_SETTINGS = 40;
    // a coin holder restyles a statement the core holds
    uint8 internal constant A_SET_HELD_FORMAT = 41;
    // a buy whose hook bounty is left unbooked, so the next action runs over pending fee income (decision 147)
    uint8 internal constant A_BUY_COIN_NOBOOK = 42;
    uint256 internal constant N_ACTIONS = 43;

    // violation codes
    uint256 internal constant V_ETH_OUT = 1; // eth left the core beyond what the action explains
    uint256 internal constant V_ETH_IN = 2; // eth arrived in the core beyond what the action explains
    uint256 internal constant V_X_OUT = 3; // balance token left the core beyond what the action explains
    uint256 internal constant V_X_IN = 4; // balance token arrived in the core beyond what the action explains
    uint256 internal constant V_ABOVE_CAP = 5; // a credit was bought above the rate read before the action
    uint256 internal constant V_LISTING_PAY = 6; // a buyListing payment outside min(bid less cost, gas cap at the base fee plus keeperFee)
    uint256 internal constant V_DEPART = 8; // a statement left the core without a recorded legal redemption
    uint256 internal constant V_REDEEM_SHORT = 9; // a redemption that returned less than credits * unit per credit
    uint256 internal constant V_MODEL = 10; // the core disagrees with the handler's ghost model
    uint256 internal constant V_RATE_BOUND = 11; // the rate moved faster or slower than the settings in force allow
    uint256 internal constant V_SPEND = 13; // a spend above the pot at that moment
    uint256 internal constant V_HOSTILE_OK = 14; // a hostile listing target got through
    uint256 internal constant V_PROBE_OK = 15; // a controller attack call succeeded
    uint256 internal constant V_REENTER = 16; // a reentry attempt succeeded
    uint256 internal constant V_REVERT_CHANGED = 17; // a reverted action changed core state
    uint256 internal constant V_BUYBACK = 18; // a buyback slice or tip outside the rules
    /// the gas bounds of the caller payment (private constants of the core, restated here)
    uint256 internal constant COMPOSE_GAS = 13_700_000;
    uint256 internal constant REDEEM_GAS = 1_500_000;
    uint256 internal constant V_COMPOSE = 19; // a compose that paid its caller outside the caller payment rule, took an invalid page or made another statement than the next id
    uint256 internal constant V_POT = 20; // pot bookkeeping off from the action's flows
    uint256 internal constant V_RECEIVE = 21; // the core's receive() reverted, or a swap failed for an unexplained reason
    uint256 internal constant V_SUPPLY = 22; // coin supply differs from the ghost, or rose
    uint256 internal constant V_SETTINGS = 24; // settings changed outside the owner's call, or an owner call misbehaved
    uint256 internal constant V_OWNER = 25; // an owner action moved assets or the books it must not touch
    uint256 internal constant V_SALE_PATH = 26; // a sellTo or buy sale outside the rules: price, booking, holder or record
    uint256 internal constant V_LOCK = 27; // a one way lock came undone, or a handover left a power behind
    uint256 internal constant V_PAYEE = 28; // the payee share, its latch or its forced push broke the rule
    uint256 internal constant V_RETIRED = 29; // a retired core took a call at one of the six doors, or the retired flag disagrees with the ghost
    uint256 internal constant N_VIOL = 30;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant DEAD = Mainnet.DEAD;
    bytes32 internal constant SKIM_SPLIT = keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    ICore public core;
    IArtCoinsTokenV2 public coin;
    TestSwapRouter public router;
    PoolKey public launchKey;
    bytes32 public poolId;
    /// the v2 hook and the mev module of the launch. the hook pushes its bounty to the core
    address internal HOOK;
    address internal mev;
    /// the payee share ghosts: whether the share is on, the payee the owner last set and the launch time of the
    /// factory record. the share is pushed to the payee by `_book`, not held, so there is no owed ghost
    bool public gPayeeOn;
    address public gPayee;
    uint256 public gLaunchedAt;
    uint256 public gSpendBucket;
    uint256 public gSpendSeconds;
    uint256 public gSpendSnapshot;
    uint256 public gSpendBudget;
    uint256 public gSpent;
    uint256 public gCapViolations;
    uint256 public gCappedFills;
    uint256 public gCapRejections;
    bool public gSpendActive;
    address public owner;
    address public v1;
    FuzzController public fuzz;
    ProbeTarget public probe;
    address public rawAdapter;
    MockBalanceModule public module;
    MockBalanceToken public balanceToken;
    /// balance token sent straight to the Core by the donate action, per token. the Core never moves balance token on
    /// its own account, so this dust stays with it (decision 143/144: no general sweep). keyed by token because a
    /// module replacement onto a fresh token changes which token the Core holds
    mapping(address => uint256) public gDonatedX;
    bool public canSwapController;
    string public tag;

    address[] public actors;
    address public keeper;
    mapping(address => uint256[]) internal inventory;
    uint256[] internal candidates;
    uint256[] internal probeIds;
    mapping(uint256 => bool) internal gone;
    /// every controller that was ever installed or probed. none may hold anything.
    address[] public controllers;

    /// what the owner and every controller held when the run began, per asset. invariant 8: none may ever hold more
    struct Base {
        uint256 eth;
        uint256 coin;
        uint256 credits;
        uint256 statements;
        uint256 balanceToken;
    }

    mapping(address => Base) public baseOf;
    address[] public watched;

    // per action counters. the handler never reverts, so these survive failing core calls.
    uint256[N_ACTIONS] public attempts;
    uint256[N_ACTIONS] public successes;
    /// `setHeldFormat` calls by a funded caller that restyled a held statement to a format different from its own
    uint256 public fundedRestyles;
    uint256[N_ACTIONS] public skips;
    /// attempts the ghost model expected to succeed that reverted anyway
    uint256[N_ACTIONS] public unexpectedFails;
    /// the selector of the latest unexpected revert of each action
    bytes4[N_ACTIONS] public lastUnexpected;
    string[N_ACTIONS] internal names;

    uint256[N_VIOL] public viol;
    /// set by the first successful `migrate`. from then on the six doors must refuse with `Retired`
    bool public gRetired;
    string[N_VIOL] public violMsg;

    // coin supply ghost. the expected supply falls by the coin the eth buyback bought and burned. coin taxed to the
    // burn address is held there, not burned
    uint256 public gSupply;
    uint256 public gDead;
    uint256 public gBurnedByBuyback;
    /// coin burned by the swapCredit fee (`swapFeeCc` per swap)
    uint256 public gBurnedBySwap;
    uint256 internal gSupplyLast;
    /// swaps and buybacks that ran while the anti sniper skim was above the baseline
    uint256 public windowSwaps;

    // the core's receive(). direct sends made, and the ones that failed
    uint256 public receiveSends;
    uint256 public receiveFails;
    /// swaps through the real pool that failed, by revert selector
    mapping(bytes4 => uint256) public swapFails;
    bytes4[] public swapFailSels;

    // ghost credits
    struct CG {
        bool inPile;
        uint256 cost;
    }

    mapping(uint256 => CG) public cg;
    uint256[] internal cgList;

    // ghost statements. status: the one place every statement ever composed sits at any time
    uint8 public constant S_HELD = 1; // held by the core for sale or redemption
    uint8 public constant S_SOLD = 2; // sold by the controller through `sellTo`, the buyer holds it
    uint8 public constant S_REDEEMED = 3; // handed to the balance module

    struct SG {
        uint8 status;
        uint256 cost;
        uint64 composedAt;
        uint256 floor; // sold: the hard floor (cost * saleFloorBps) in force at the sale
        uint256 price; // sold: the price paid
        address buyer; // sold: who holds it
        uint256 required; // redeem: credit count times unit per credit
        uint256 received; // redeem: balance token the core received
        address module; // redeem: the module that took it
    }

    mapping(uint256 => SG) internal _sg;
    uint256[] public everHeld;

    /// the keccak of the settings the owner last set, which nobody else can change
    bytes32 public gSettingsHash;

    /// ledger of the eth books: the pots (`ethPot + ethToBuyback`) when the run began, the eth the core booked into them
    /// since (booked fees, sale payments, funded eth) and the eth that left them (credit purchases, tips,
    /// redemption repayments, buyback spends, migrations). each amount is the one measured at the recipient by the action
    uint256 public gEthStart;
    uint256 public gEthIn;
    uint256 public gEthOut;

    constructor(Wiring memory w) {
        core = w.core;
        coin = w.coin;
        router = w.router;
        launchKey = w.launchKey;
        poolId = w.poolId;
        HOOK = w.hook;
        mev = w.mev;
        gPayeeOn = core.payeeOn();
        gPayee = core.payee();
        gLaunchedAt = _launchedAt(core.FACTORY(), address(w.coin));
        owner = w.owner;
        v1 = w.v1;
        fuzz = w.fuzz;
        probe = w.probe;
        rawAdapter = w.rawAdapter;
        module = w.module;
        balanceToken = w.balanceToken;
        canSwapController = w.canSwapController;
        tag = w.tag;
        keeper = makeAddr("credeng.inv.keeper");
        string[N_ACTIONS] memory n = [
            "buyCoin",
            "sellCoin",
            "sellForEth",
            "listingStrategy",
            "listingHostile",
            "warp",
            "roll",
            "compose",
            "buyback",
            "swapCredit",
            "donate",
            "controllerSeed",
            "controllerSwap",
            "probeController",
            "sellForBalance",
            "redeemStatement",
            "moduleMode",
            "walletMove",
            "setSettings",
            "setSettingsInvalid",
            "setRate",
            "ownerMisc",
            "replaceModule",
            "buy",
            "ownerSell",
            "saleSettings",
            "hostileOwner",
            "lockDoor",
            "handover",
            "book",
            "reserved",
            "rescueNft",
            "migrate",
            "adopt",
            "pause",
            "changeUnit",
            "releaseRedeem",
            "buyCredit",
            "buyCredits",
            "composeChosen",
            "creditSettings",
            "setHeldFormat",
            "buyCoinNoBook"
        ];
        names = n;
        controllers.push(w.v1);
        controllers.push(address(w.fuzz));
        // the owner and the controllers are watched from the start. a contract created at an address that already
        // holds eth on the fork starts with that eth
        watched.push(w.owner);
        watched.push(w.v1);
        watched.push(address(w.fuzz));
        for (uint256 i; i < watched.length; ++i) {
            _snapBase(watched[i]);
        }
        gSettingsHash = keccak256(abi.encode(core.settings()));
        gSupply = coin.totalSupply();
        gSupplyLast = gSupply;
        gDead = coin.balanceOf(DEAD);
    }

    /// true once the balance module is set in the core
    function phase2() public view returns (bool) {
        return core.balanceModule() != address(0);
    }

    /*//////////////////////////////////////////////////////////////
                               FIXTURE HOOKS
    //////////////////////////////////////////////////////////////*/

    function addActor(address a) external {
        actors.push(a);
    }

    function giveCredits(address a, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            inventory[a].push(ids[i]);
        }
    }

    function setCandidates(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            candidates.push(ids[i]);
        }
    }

    function setProbeIds(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            probeIds.push(ids[i]);
        }
    }

    /// the fixture reports credits it sold into the core and statements it composed before the run starts, so
    /// the ghost model starts in step with the core.
    function seedGhostPile(uint256 id, uint256 cost) external {
        _addCredit(id, cost);
    }

    /// a statement the core held before the run began, read back from the core
    function seedGhostStatement(uint256 sid) external {
        (, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
        SG storage g = _sg[sid];
        g.cost = cost;
        g.composedAt = composedAt;
        g.status = S_HELD;
        everHeld.push(sid);
    }

    /// a statement bought before the run began, with the buyer and the price paid
    function seedGhostSold(uint256 sid, address buyer, uint256 price) external {
        (, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
        SG storage g = _sg[sid];
        g.cost = cost;
        g.composedAt = composedAt;
        g.status = S_SOLD;
        g.floor = cost * core.settings().saleFloorBps / 10_000;
        g.price = price;
        g.buyer = buyer;
        everHeld.push(sid);
    }

    /// Fixture inputs are measured around its real prefill purchases, independently of Core storage.
    function seedSpendBooks(uint256 openingPot, uint256 spent, uint256 at) external {
        Settings memory cfg = core.settings();
        gSpendSeconds = cfg.bucketSeconds;
        gSpendBucket = at / cfg.bucketSeconds;
        gSpendSnapshot = openingPot;
        gSpendBudget = FullMath.mulDiv(openingPot, cfg.spendCapBps, 10_000);
        gSpent = spent;
        gSpendActive = true;
    }

    function seedEthBooks() external {
        gEthStart = core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn();
        gPayeeOn = core.payeeOn();
    }

    function everHeldCount() external view returns (uint256) {
        return everHeld.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// the credits the ghost has had in a pile at some time, in the order they first entered
    function everPiledCount() external view returns (uint256) {
        return cgList.length;
    }

    function everPiled(uint256 i) external view returns (uint256) {
        return cgList[i];
    }

    function statementGhost(uint256 sid) external view returns (SG memory) {
        return _sg[sid];
    }

    function watchedCount() external view returns (uint256) {
        return watched.length;
    }

    function controllerCount() external view returns (uint256) {
        return controllers.length;
    }

    function actionName(uint256 a) external view returns (string memory) {
        return names[a];
    }

    function actionCount() external pure returns (uint256) {
        return N_ACTIONS;
    }

    function violationCount() external pure returns (uint256) {
        return N_VIOL;
    }

    function tally(uint256 a, string memory kind) public view returns (uint256) {
        return vm.envOr(string.concat("INV_", tag, "_", names[a], "_", kind), uint256(0));
    }

    /*//////////////////////////////////////////////////////////////
                               SMALL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _bump(uint8 a, string memory kind) internal {
        string memory key = string.concat("INV_", tag, "_", names[a], "_", kind);
        vm.setEnv(key, vm.toString(vm.envOr(key, uint256(0)) + 1));
    }

    uint8 internal lastAct;

    function _att(uint8 a) internal {
        lastAct = a;
        attempts[a]++;
        _bump(a, "att");
    }

    function _ok(uint8 a) internal {
        successes[a]++;
        _bump(a, "ok");
    }

    function _skip(uint8 a) internal {
        skips[a]++;
        _bump(a, "skip");
    }

    /// which ever composed statements a picker may return
    uint256 internal constant K_HELD = 0; // held by the core
    uint256 internal constant K_ANY = 1;

    /// a statement the ghost has seen, from `seed` on, of the kind asked. not found when there is none
    function _pickBy(uint256 seed, uint256 kind) internal view returns (uint256 sid, bool found) {
        uint256 n = everHeld.length;
        for (uint256 k; k < n; ++k) {
            sid = everHeld[(seed % n + k) % n];
            SG storage g = _sg[sid];
            if (kind == K_ANY) return (sid, true);
            if (g.status == S_HELD) return (sid, true);
        }
        return (0, false);
    }

    function _unexpected(uint8 a, bytes memory why) internal {
        if (why.length >= 4 && bytes4(why) == ICore.SpendCapReached.selector) {
            ++gCapRejections;
            return;
        }
        unexpectedFails[a]++;
        if (why.length >= 4) {
            lastUnexpected[a] = bytes4(why);
            vm.setEnv(string.concat("INV_", tag, "_", names[a], "_lastsel"), vm.toString(bytes32(bytes4(why))));
        }
        _bump(a, "unexpected");
    }

    /// the `buyListing` call of a listing action on a retired core
    function _retiredListing(uint8 a, address target) internal returns (bool) {
        return _retiredRefusal(a, keeper, abi.encodeCall(ICore.buyListing, (target, 1, "")));
    }

    /// the credits an actor holds, at most the first one: the argument of a call a retired core refuses
    function _firstOf(address who) internal view returns (uint256[] memory ids) {
        ids = new uint256[](inventory[who].length == 0 ? 0 : 1);
        if (ids.length == 1) ids[0] = inventory[who][0];
    }

    /// after a migrate the core is retired and `sellForEth`, `buyListing`, `adopt`, `compose`, `composeChosen` and
    /// `sellForBalance` revert `Retired`. the action sends its call instead of its own body, checks the selector and
    /// that the books stayed, and ends. returns false while the core is not retired
    function _retiredRefusal(uint8 a, address who, bytes memory data) internal returns (bool) {
        if (!gRetired) return false;
        uint256 bal = address(core).balance;
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();
        _att(a);
        vm.prank(who);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok) _flag(V_RETIRED, "a retired core took a call at a door it must refuse");
        else if (bytes4(out) != ICore.Retired.selector) _unexpected(a, out);
        else _ok(a);
        _failed(bal, pot, rate, "a retired door");
        return true;
    }

    function _flag(uint256 code, string memory what) internal {
        viol[code]++;
        if (bytes(violMsg[code]).length == 0) violMsg[code] = what;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// lo * (hi / lo) ^ f with f taken from x, so small and large values are both common.
    function _logBound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 f = (x % 1_000_001) * 1e12;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ratioLn = FixedPointMathLib.lnWad(int256(hi * 1e18 / lo));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 e = int256(f) * ratioLn / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 v = lo * uint256(FixedPointMathLib.expWad(e)) / 1e18;
        return v < lo ? lo : (v > hi ? hi : v);
    }

    function _removeFrom(uint256[] storage list, uint256 id) internal {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == id) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }

    function _addCredit(uint256 id, uint256 cost) internal {
        if (!cg[id].inPile && cg[id].cost == 0) cgList.push(id);
        cg[id] = CG(true, cost);
    }

    function _ownerOf(uint256 sid) internal view returns (address o) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", sid));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    /// the balance token the core has set, zero before the balance side
    function _xt() internal view returns (MockBalanceToken) {
        return MockBalanceToken(core.balanceToken());
    }

    function _xBal(address who) internal view returns (uint256) {
        address t = core.balanceToken();
        return t == address(0) ? 0 : MockBalanceToken(t).balanceOf(who);
    }

    /// pool price helpers, coin and eth in raw units at the current launch pool price.
    function _sqrtP() internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(launchKey.toId());
    }

    /// eth is currency0 and the coin currency1, so the pool price is coin per eth and sqrtP squared is that price
    function _coinFor(uint256 eth) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(eth, p, 1 << 96), p, 1 << 96);
    }

    function _ethFor(uint256 coinAmt) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(coinAmt, 1 << 96, p), 1 << 96, p);
    }

    /// the most eth one batch of sales may spend: the pot
    /// the eth a non oversized sell may spend: the pot less the reserve at a pile grown by the largest batch (10), so a
    /// batch that carries the pile across a page and raises the reserve still fits
    function _budget() internal view returns (uint256) {
        return core.ethPot().zeroFloorSub(_reserveAt(core.settings(), core.pileSize() + 10, core.heldStatements().length));
    }

    /// the most an eth purchase may spend now: `ethPot` less the reserve
    function _room() internal view returns (uint256) {
        return core.ethPot().zeroFloorSub(core.reserve());
    }

    /// the reserve of `CoreLib._reserve` for `pile` pile credits and `held` held statements under `st`: the larger of
    /// `reserveWei` and 1.5 times one compose per full page at 9,000,000 gas and one redemption per statement at 600,000
    /// gas, each gas at `callerMaxBaseFee` plus `callerFee`
    function _reserveAt(Settings memory st, uint256 pile, uint256 held) internal pure returns (uint256) {
        uint256 base = st.callerMaxBaseFee;
        uint256 fee = st.callerFee;
        uint256 queued = pile / 80 * (9_000_000 * base + fee) + held * (600_000 * base + fee);
        return uint256(st.reserveWei).max(queued * 15 / 10);
    }

    /*//////////////////////////////////////////////////////////////
                         LEDGER AND RATE GUARDS
    //////////////////////////////////////////////////////////////*/

    /// eth flows of one action. `out` and `in_` are what the action explains, measured at the recipients.
    function _eth(uint256 b0, uint256 out, uint256 in_, string memory what) internal {
        gEthOut += out;
        uint256 b1 = address(core).balance;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 expected = int256(b0) + int256(in_) - int256(out);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 actual = int256(b1);
        if (actual < expected) _flag(V_ETH_OUT, what);
        else if (actual > expected) _flag(V_ETH_IN, what);
    }

    function _x(uint256 b0, uint256 out, uint256 in_, string memory what) internal {
        if (core.balanceToken() == address(0)) return;
        uint256 b1 = _xBal(address(core));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 expected = int256(b0) + int256(in_) - int256(out);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 actual = int256(b1);
        if (actual < expected) _flag(V_X_OUT, what);
        else if (actual > expected) _flag(V_X_IN, what);
    }

    /// a reverted action must leave the core's books untouched.
    function _failed(uint256 b0, uint256 pot0, uint256 rate0, string memory what) internal {
        if (address(core).balance != b0 || core.ethPot() != pot0 || core.ethRate() != rate0) {
            _flag(V_REVERT_CHANGED, what);
        }
    }

    struct RS {
        Settings st;
        uint256 rate;
        uint256 pot;
        uint256 anchor;
        uint256 lastFill;
        uint256 stored;
        uint256 cp;
        uint256 peakRate;
        uint256 peakTime;
        uint256 pend;
        uint256 res;
    }

    function _rs() internal view returns (RS memory s) {
        s.st = core.settings();
        s.rate = core.ethRate();
        s.pot = core.ethPot();
        s.res = core.reserve();
        s.pend = _pendingPot(s.st);
        s.stored = core.rateAtCheckpoint();
        s.cp = core.checkpointTime();
        (s.anchor,,) = _anchorState();
        (s.peakRate, s.peakTime) = _peakState();
        s.lastFill = core.lastFillTime();
    }

    /// the share of the unbooked fee income that the next `_book` adds to the pot: the eth above the tracked pots, less
    /// the payee share (while `payeeOn`) and the redeem burn reserve share of the rest
    function _pendingPot(Settings memory st) internal view returns (uint256) {
        uint256 tracked = core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn();
        uint256 income = address(core).balance > tracked ? address(core).balance - tracked : 0;
        if (core.payeeOn()) income -= income * st.payeePpm / 1_000_000;
        return income - income * st.feeToRedeemBurnBps / 10_000;
    }

    /// first slot of `State.anchor` in the Core (four words)
    bytes32 internal constant ANCHOR_SLOT = bytes32(uint256(28));

    /// the bid anchor state of the core, read from its storage: the rate of the last fill, the rate of the first fill in
    /// the current minute bucket, and that bucket
    function _anchorState() internal view returns (uint256 lastFillRate, uint256 minuteStartRate, uint256 bucket) {
        bytes32 slot = ANCHOR_SLOT;
        lastFillRate = uint256(vm.load(address(core), slot));
        minuteStartRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
        bucket = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))));
    }

    /// the remembered peak state: `peakRate` and `peakTime`, in the third and fourth words of `State.anchor` (peakTime is
    /// the high 64 bits of the word that holds the minute bucket)
    function _peakState() internal view returns (uint256 peakRate, uint256 peakTime) {
        bytes32 slot = ANCHOR_SLOT;
        peakTime = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))) >> 64);
        peakRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 3)));
    }

    /// the price state right now, from the core's checkpoint and peak state
    function _priceBid(Settings memory st) internal view returns (BidModel.Bid memory) {
        (uint256 peakRate, uint256 peakTime) = _peakState();
        (uint256 anchor,,) = _anchorState();
        return BidModel.Bid({
            r: core.rateAtCheckpoint(),
            pot: (core.ethPot() + _pendingPot(st)).zeroFloorSub(core.reserve()),
            pagesPot: core.ethPot() + _pendingPot(st),
            lastFillRate: anchor,
            peakRate: peakRate,
            peakTime: peakTime,
            lastFillTime: core.lastFillTime(),
            checkpointTime: core.checkpointTime(),
            nowTs: block.timestamp
        });
    }

    /// the rate a fill in the next transaction starts its minute from: the stored start inside the current minute
    /// bucket, `rate` (the price state at the fill) when the bucket is new
    function _minuteStartNow(uint256 rate) internal view returns (uint256) {
        (, uint256 start, uint256 bucket) = _anchorState();
        return bucket == block.timestamp / core.settings().bucketSeconds ? start : rate;
    }

    /// the price state of the eth rate right now, from the stored rate, the anchor and the peak: bounded by the ceiling
    /// and `rateCap`, climbing up to the clamp
    function _priceNow(Settings memory st) internal view returns (uint256) {
        return BidModel.priceNow(st, _priceBid(st));
    }

    /// invariant 6 and its companions, against the settings in force over the interval (they cannot change inside
    /// one action or one warp, only the owner's calls change them and those are checked on their own). across a warp
    /// the read equals the model read from the state the interval started in. in an interval without time passing
    /// (any action except a warp, `setRate` and `setSettings`) the stored rate is at most the larger of the stored rate
    /// and the price state at the start of the interval, and the read equals the model read from the state and the
    /// settings at the end.
    function _rsCheck(RS memory s, uint256 dt) internal {
        uint256 rate1 = core.ethRate();
        uint256 p = BidModel.priceNow(
            s.st,
            BidModel.Bid({
                r: s.stored,
                pot: (s.pot + s.pend).zeroFloorSub(s.res),
                pagesPot: s.pot + s.pend,
                lastFillRate: s.anchor,
                peakRate: s.peakRate,
                peakTime: s.peakTime,
                lastFillTime: s.lastFill,
                checkpointTime: s.cp,
                nowTs: block.timestamp
            })
        );
        if (dt != 0) {
            if (rate1 != BidModel.read(s.st, (s.pot + s.pend).zeroFloorSub(s.res), p)) {
                _flag(V_RATE_BOUND, "the rate after a warp differs from the model");
            }
        } else {
            // the contract checkpoints `m` and the clamp from the pot at checkpoint time, which an action that moves
            // the balance before it books (a skim then a book, or a book then a spend) shifts off the start pot. the
            // checkpoint pot lies between the start and end pots and priceNow rises with the pot, so the stored rate is
            // bounded by the larger of the two model prices
            Settings memory end = core.settings();
            uint256 pEnd = BidModel.priceNow(
                end,
                BidModel.Bid({
                    r: s.stored,
                    pot: (core.ethPot() + _pendingPot(end)).zeroFloorSub(core.reserve()),
                    pagesPot: core.ethPot() + _pendingPot(end),
                    lastFillRate: s.anchor,
                    peakRate: s.peakRate,
                    peakTime: s.peakTime,
                    lastFillTime: s.lastFill,
                    checkpointTime: s.cp,
                    nowTs: block.timestamp
                })
            );
            if (core.rateAtCheckpoint() > s.stored.max(p).max(pEnd)) {
                _flag(V_RATE_BOUND, "the stored rate rose with no time passing");
            }
            if (rate1 != BidModel.read(end, (core.ethPot() + _pendingPot(end)).zeroFloorSub(core.reserve()), _priceNow(end))) {
                _flag(V_RATE_BOUND, "the read differs from the price state lowered to the clamp of the end pot");
            }
            if (core.reserve() != _reserveAt(end, core.pileSize(), core.heldStatements().length)) {
                _flag(V_MODEL, "the reserve differs from its formula");
            }
        }
    }

    /// eth booked into the pots (the pot share and the buyback share) enters the ledger
    function _booked(uint256 amount) internal {
        gEthIn += amount;
    }

    /// a spend of `x` eth from the pot, which held `potBefore` when it began. a spend above the pot is a violation.
    /// returns the pot left, floored at zero: a handler call that reverts after the flag drops the flag, so the
    /// arithmetic that follows a recorded spend must not underflow
    function _syncSpendGhost() internal {
        Settings memory cfg = core.settings();
        if (gSpendActive && gSpendBucket != block.timestamp / gSpendSeconds) gSpendActive = false;
        if (gSpendActive) {
            gSpendBucket = block.timestamp / cfg.bucketSeconds;
            gSpendBudget = FullMath.mulDiv(gSpendSnapshot, cfg.spendCapBps, 10_000);
        }
        gSpendSeconds = cfg.bucketSeconds;
    }

    function _recordSpend(uint256 x, uint256 potBefore) internal returns (uint256 left) {
        _syncSpendGhost();
        Settings memory cfg = core.settings();
        if (!gSpendActive) {
            gSpendActive = true;
            gSpendBucket = block.timestamp / cfg.bucketSeconds;
            gSpendSnapshot = potBefore;
            gSpendBudget = FullMath.mulDiv(potBefore, cfg.spendCapBps, 10_000);
            gSpent = 0;
        }
        bool firstOfBucket = gSpent == 0;
        gSpent += x;
        if (cfg.spendCapBps != 10_000) {
            ++gCappedFills;
            if (!firstOfBucket && gSpent > gSpendBudget) ++gCapViolations;
        }
        if (x > potBefore) _flag(V_SPEND, "a spend above the pot at that moment");
        left = potBefore > x ? potBefore - x : 0;
    }

    /// a refused sale above the pot ends in `PotTooSmall`. an arithmetic panic means the pot check is gone
    function _refusedAbovePot(bytes memory why) internal {
        if (why.length >= 4 && bytes4(why) == 0x4e487b71) _flag(V_SPEND, "a sale above the pot ended in a panic");
    }

    /// the stored price state and the read after the sells of one call at `costs`: each credit drops the price state, and the
    /// read after it is the price state lowered to the clamp of the smaller pot
    function _rateAfterSells(Settings memory st, SellPre memory p, uint256[] memory costs, uint256[] memory scores)
        internal
        returns (uint256 stored, uint256 r)
    {
        stored = p.price;
        uint256 pot = p.pot;
        uint256 start = p.minuteStart;
        for (uint256 i; i < costs.length; ++i) {
            // the exact per-credit payout: the read (the price state lowered to the pot left less the reserve at the pile
            // before this credit) times the credit's score over 100 points, from the handler's own rate model
            uint256 room = pot.zeroFloorSub(_reserveAt(st, p.pile + i, p.held));
            uint256 expected = FullMath.mulDiv(BidModel.read(st, room, stored), scores[i], RATE_SCORE);
            if (costs[i] != expected) {
                _flag(V_MODEL, "sellForEth payout differs from read times score over 100 points");
            }
            start = BidModel.startAfter(st, stored, start);
            stored = _dropped(st, stored, start, scores[i]);
            pot = pot > costs[i] ? pot - costs[i] : 0;
        }
        r = _readAfterFill(st, stored, pot);
    }

    /// the read right after a fill: the stored price state, lowered to the clamp of the pot left less the reserve now
    function _readAfterFill(Settings memory st, uint256 stored, uint256 pot) internal view returns (uint256) {
        return BidModel.read(st, pot.zeroFloorSub(core.reserve()), stored);
    }

    /// the rate after one credit of score `score` bought with the price state `r`, where `start` is the price state at
    /// the first fill of the minute. the fall scales by `score / 100 points`
    function _dropped(Settings memory st, uint256 r, uint256 start, uint256 score) internal pure returns (uint256) {
        return BidModel.dropOnce(st, r, start, score);
    }

    /// the score of credit `id` from the CreditScore contract, the per-credit source the Core reads
    function _scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /*//////////////////////////////////////////////////////////////
                         LOG PARSING AND SKIM MODEL
    //////////////////////////////////////////////////////////////*/

    /// what the live hook reported for the swaps in `logs`: the eth volume it skimmed on, the core's leg (the
    /// bounty, which the hook pushes into the core's `receive()`) and the creator's leg
    function _skimOf(Vm.Log[] memory logs) internal view returns (uint256 volume, uint256 bounty, uint256 protocol) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != HOOK || logs[i].topics[0] != SKIM_SPLIT) continue;
            if (logs[i].topics.length > 1 && logs[i].topics[1] != poolId) continue;
            (uint256 v, uint256 b, uint256 p,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            volume += v;
            bounty += b;
            protocol += p;
        }
    }

    /// the skim rate the live anti sniper module reports for the next swap, in bps of volume. 9_000 (90 percent) at
    /// launch, falling linearly to the 1000 bps (10 percent) baseline over the window
    function _skimBps() internal view returns (uint256 bps) {
        (uint24 b,) = IArtCoinsMevSkimV2(mev).currentSkimBps(poolId);
        bps = b;
        if (bps < 1000) bps = 1000;
    }

    /// the legs of a skim of `skim` eth at the rate `bps`, from the rules of the hook written out independently: the
    /// baseline part of the skim (10 points over the live rate) splits 90 percent to the bounty recipient (the Core)
    /// and the rest to the protocol, and the whole extra above the baseline goes to the bounty recipient
    function _expectSkim(uint256 skim, uint256 bps) internal pure returns (uint256 bounty, uint256 protocol) {
        uint256 base = skim * 1000 / bps;
        if (base > skim) base = skim;
        uint256 share = base * 9_000 / 10_000;
        protocol = base - share;
        bounty = share + (skim - base);
    }

    /// whether `skim` is the skim the hook takes on a swap whose pool eth amount was `volume`. a buy (eth in) skims
    /// on top of the pool amount, a sell skims out of it. exact input swaps round down once, so two wei of play
    function _skimTotalOk(uint256 volume, bool buy, uint256 bps, uint256 skim) internal pure returns (bool) {
        // a buy skims on top of the pool amount. a sell reports either the gross eth out (skim = volume * bps / 1e4) or
        // the net one (skim = volume * bps / (1e4 - bps)), by the kind of exact swap. the rounding of the pool amount is
        // scaled by bps / (10_000 - bps), which is 9 at the 90 point start
        uint256 tol = 3 + 2 * bps / (10_000 - bps);
        uint256 onTop = volume * bps / (10_000 - bps);
        if (skim + tol >= onTop && skim <= onTop + tol) return true;
        if (buy) return false;
        uint256 gross = volume * bps / 10_000;
        return skim + 2 >= gross && skim <= gross + 2;
    }

    /// the launch time of the factory record of `coin_`, zero when it is not recorded
    function _launchedAt(address factory, address coin_) internal view returns (uint256 at) {
        (bool ok, bytes memory out) = factory.staticcall(abi.encodeWithSignature("deploymentInfo(address)", coin_));
        if (!ok || out.length < 320) return 0;
        // word 0 is the offset of the record, word 9 is `launchedAt`
        assembly ("memory-safe") {
            at := mload(add(out, add(0x20, mul(9, 0x20))))
        }
    }

    /// the eth the core tracks: the three pots (the payee share is pushed by the book, not held)
    function _tracked() internal view returns (uint256) {
        return core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn();
    }

    /// the eth held above the tracked eth: what the next book counts as fee income
    function _unbooked() internal view returns (uint256) {
        uint256 t = _tracked();
        uint256 b = address(core).balance;
        return b > t ? b - t : 0;
    }

    /// the model of one book on the income `inc`, written out again here: nothing for no income, the payee share of
    /// `payeePpm` once it is on, the first book with income at or after `launchedAt + settings.sniperSeconds` turns it on and
    /// shares nothing. updates the latch ghost. returns the share pushed to the payee and the part that goes to the pots
    function _bookModel(uint256 inc) internal returns (uint256 share, uint256 toPots) {
        if (inc == 0) return (0, 0);
        if (gPayeeOn) share = inc * core.settings().payeePpm / 1_000_000;
        else if (block.timestamp >= gLaunchedAt + core.settings().sniperSeconds) gPayeeOn = true;
        toPots = inc - share;
    }

    struct Pots {
        uint256 pot;
        uint256 tb;
        uint256 rb;
    }

    function _pots() internal view returns (Pots memory p) {
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rb = core.ethRedeemBurn();
    }

    /// the three pots after a book of `toPots`, against the state `p` before it: the redeem burn share of the settings
    /// comes off `toPots`, the rest goes to the pot. the payee share left the core, so the pots carry only `toPots`
    function _potsAfterBook(Pots memory p, uint256, uint256 toPots, string memory what) internal {
        Settings memory st = core.settings();
        uint256 rb = toPots * st.feeToRedeemBurnBps / 10_000;
        if (core.ethPot() != p.pot + toPots - rb || core.ethToBuyback() != p.tb || core.ethRedeemBurn() != p.rb + rb) {
            _flag(V_POT, string.concat("fee income not booked by the split: ", what));
        }
        if (core.payeeOn() != gPayeeOn) _flag(V_PAYEE, string.concat("payee latch differs from the model: ", what));
    }

    /// the forced push of the payee share lands: the payee holds `share` more than before the book, even a payee whose
    /// receive reverts (solady forces the transfer). the payee is never the owner or a controller, so invariant 8 holds
    function _pushedToPayee(uint256 payeeBefore, uint256 share, string memory what) internal {
        if (gPayee.balance != payeeBefore + share) {
            _flag(V_PAYEE, string.concat("the book did not push the payee share: ", what));
        }
    }

    /// books the fee income with `core.book()` as `who` and checks it against the model: the pots, the forced payee push
    /// and the latch. the whole income enters the ledger and the pushed share leaves it. returns the income counted and
    /// the part booked into the pots
    function _bookNow(address who, string memory what) internal returns (uint256 inc, uint256 toPots) {
        inc = _unbooked();
        Pots memory p = _pots();
        uint256 payeeBefore = gPayee.balance;
        vm.prank(who);
        try core.book() {}
        catch {
            _flag(V_POT, string.concat("book reverted: ", what));
            return (inc, 0);
        }
        uint256 share;
        (share, toPots) = _bookModel(inc);
        _potsAfterBook(p, share, toPots, what);
        _pushedToPayee(payeeBefore, share, what);
        gEthIn += inc;
        gEthOut += share;
    }

    /// books the income left unbooked by the previous action before an action reads the books
    function _settle() internal {
        if (_unbooked() != 0) _bookNow(keeper, "settle");
    }

    /// the selector a failed swap really died of. the pool manager wraps a revert of the hook, so look inside
    function _rootSelector(bytes memory why) internal pure returns (bytes4 sel) {
        if (why.length < 4) return bytes4(0);
        sel = bytes4(why);
        if (sel == bytes4(0x90bfb865) && why.length >= 4 + 4 * 32) {
            bytes memory rest = new bytes(why.length - 4);
            for (uint256 i; i < rest.length; ++i) {
                rest[i] = why[i + 4];
            }
            (,, bytes memory reason,) = abi.decode(rest, (address, bytes4, bytes, bytes));
            if (reason.length >= 4) sel = bytes4(reason);
        }
    }

    /// counts a failed real swap by revert selector. a failed push into the core's `receive()` makes the hook revert
    /// with BidForwardFailed, which is the one reason that must never appear
    function _swapFailed(bytes memory why) internal {
        bytes4 sel = _rootSelector(why);
        if (swapFails[sel]++ == 0) swapFailSels.push(sel);
        if (sel == bytes4(keccak256("BidForwardFailed()"))) {
            receiveFails++;
            _flag(V_RECEIVE, "the core receive() reverted inside a real swap");
        }
    }

    function swapFailSelCount() external view returns (uint256) {
        return swapFailSels.length;
    }

    /// checks the coin after every action: the supply equals the ghost and never rose, the burn address never lost
    /// coin, and the core never holds coin
    function _coinCheck() internal {
        uint256 s = coin.totalSupply();
        if (s != gSupply) _flag(V_SUPPLY, "coin total supply differs from the ghost of buyback burns");
        if (s > gSupplyLast) _flag(V_SUPPLY, "coin total supply rose");
        gSupplyLast = s;
        uint256 d = coin.balanceOf(DEAD);
        if (d < gDead) _flag(V_SUPPLY, "the burn address lost coin");
        gDead = d;
        if (coin.balanceOf(address(core)) != 0) _flag(V_SUPPLY, "the core holds coin");
    }

    /// the settings are the owner's alone: after every action they equal what the owner last set
    function _settingsCheck() internal {
        if (keccak256(abi.encode(core.settings())) != gSettingsHash) {
            _flag(V_SETTINGS, "the settings differ from what the owner last set");
        }
    }

    function _snapBase(address who) internal {
        Base storage b = baseOf[who];
        b.eth = who.balance;
        b.coin = coin.balanceOf(who);
        b.credits = CREDITS.balanceOf(who);
        b.statements = STATEMENTS.balanceOf(who);
        b.balanceToken = _xBal(who);
    }

    /// every action starts from booked books, so its model reads the pot the core reads
    modifier checked() {
        _settle();
        _;
        _afterAction();
    }

    /// the actions that start with the door's own book (the paying doors that read the pot): the income waits for the
    /// door, and `_beginPull` models the book the door makes
    modifier pulls() {
        _;
        _afterAction();
    }

    function _afterAction() internal {
        _syncSpendGhost();
        _coinCheck();
        _settingsCheck();
        _potCheck();
        if (core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() + gEthOut != gEthStart + gEthIn) {
            _flag(V_PAYEE, string.concat("the ledger is off after ", names[lastAct]));
        }
        if (core.payeeOn() != gPayeeOn) {
            _flag(V_PAYEE, "the payee latch differs from the model after an action");
        }
    }

    /// the next fill pays the read, so the read at the end of every action is at most the pot and the share of the
    /// unbooked income that the next book adds to it
    function _potCheck() internal {
        if (core.ethRate() > (core.ethPot() + _unbooked()).zeroFloorSub(core.reserve())) {
            _flag(V_SPEND, "the read is above the pot less the reserve, the next fill would spend the reserve");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              POOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    struct SwapPre {
        uint256 bal;
        uint256 pot;
        uint256 tb;
        uint256 rate;
        uint256 bps;
        bool exactIn;
        bool buy;
    }

    /// buys coin with eth through the launch pool. exact in or exact out. the skim of the live hook goes to the Core
    /// and the next book puts it in the pot. inside the sniper window that is most of the swap
    function buyCoin(uint256 aSeed, uint256 amtSeed, uint256 mode) external checked {
        uint8 a = A_BUY_COIN;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 25 ether);
        SwapPre memory p;
        p.exactIn = mode % 3 != 0;
        p.buy = true;
        p.bps = _skimBps();
        // an exact out buy pays the gross up of the skim on top, which is large inside the window
        uint256 value = p.exactIn ? eth : eth * 2 * 10_000 / (10_000 - p.bps) + 1e12;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = p.exactIn ? -int256(eth) : int256(_coinFor(eth * 8 / 10));
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        RS memory rs = _rs();
        vm.deal(who, who.balance + value);
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap{value: value}(launchKey, true, spec, who) {
            _ok(a);
            _afterSwap(p, vm.getRecordedLogs(), p.exactIn ? eth : 0, "buyCoin");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyCoin");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    /// buys coin through the launch pool and leaves the hook bounty unbooked, then lets time pass before any book: the
    /// fee income waits above the pots while the clock advances (decision 147). over the warp the read must stay at or
    /// below the pot plus the pending pot share, the clamp the climb counts for unbooked income, which the invariant
    /// harness otherwise never runs because every action settles first. the drip is booked at the end, so the action
    /// leaves booked books for the next one
    function buyCoinNoBook(uint256 aSeed, uint256 amtSeed, uint256 dtSeed) external checked {
        uint8 a = A_BUY_COIN_NOBOOK;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 25 ether);
        SwapPre memory p;
        p.exactIn = true;
        p.buy = true;
        p.bps = _skimBps();
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        vm.deal(who, who.balance + eth);
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        // forge-lint: disable-next-line(unsafe-typecast)
        try router.swap{value: eth}(launchKey, true, -int256(eth), who) {
            _ok(a);
            _afterSwapNoBook(p, vm.getRecordedLogs());
            // time passes with the bounty still unbooked
            uint256 dt = _logBound(dtSeed, 60, 6 hours);
            vm.warp(block.timestamp + dt);
            vm.roll(block.number + dt / 12 + 1);
            // decision 147: the read rides the pot plus the pending pot share, never above it (the next fill's clamp)
            if (core.ethRate() > core.ethPot() + _pendingPot(core.settings())) {
                _flag(V_RATE_BOUND, "the read rose above the pot plus the pending pot share over the unbooked warp");
            }
            // book the drip, so the action ends with booked books for the next action
            _bookNow(keeper, "buyCoinNoBook");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyCoinNoBook");
            _swapFailed(why);
        }
    }

    /// the books after a swap whose bounty is left unbooked: the core booked nothing inside the swap and the bounty leg
    /// rose the balance above the pots, where it waits for a later book. the skim rules are checked the same as a booked
    /// swap, but no `_bookNow` runs
    function _afterSwapNoBook(SwapPre memory p, Vm.Log[] memory logs) internal {
        (uint256 volume, uint256 bounty, uint256 protocol) = _skimOf(logs);
        if (p.bps > 1000) windowSwaps++;
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.tb) _flag(V_POT, "the core booked inside the swap");
        if (address(core).balance != p.bal + bounty) _flag(V_POT, "the core received other than the hook bounty leg");
        if (volume != 0) {
            (uint256 eb, uint256 ep) = _expectSkim(bounty + protocol, p.bps);
            if (bounty != eb) _flag(V_POT, "skim bounty differs from the hook rules at the live rate");
            if (protocol != ep) _flag(V_POT, "skim creator leg differs from the hook rules at the live rate");
            if (!_skimTotalOk(volume, p.buy, p.bps, bounty + protocol)) {
                _flag(V_POT, "skim total differs from the hook rules at the live rate");
            }
        }
    }

    /// tries to move coin between wallets and into a side pool. the coin is restricted: the pool is the only way to
    /// move it, so a wallet to wallet transfer must revert and move nothing. a transfer to the core reverts as well (the
    /// core is not on the allowlist), unless the token admin lists the sender: then the coin sits in the core and the
    /// owner takes it out again with `rescueCoin`. the books of the core must not move either way
    function walletMove(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_WALLET_MOVE;
        address who = _actor(aSeed);
        address other = _actor(aSeed >> 8);
        uint256 bal = coin.balanceOf(who);
        if (bal < 2 || who == other) return _skip(a);
        uint256 amt = bound(amtSeed, 1, bal / 2);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 supply0 = coin.totalSupply();
        _att(a);
        vm.prank(who);
        try coin.transfer(other, amt) returns (bool) {
            _flag(V_SUPPLY, "a wallet to wallet transfer of the restricted coin went through");
        } catch {
            _ok(a);
        }
        if (amtSeed % 3 == 0) {
            vm.prank(who);
            try coin.transfer(address(core), amt) returns (bool) {
                _flag(V_SUPPLY, "a transfer of the restricted coin to the core went through");
            } catch {}
            if (coin.balanceOf(address(core)) != 0) _flag(V_SUPPLY, "the core holds coin");
            _allowRescue(who, amt);
        }
        _eth(b0, 0, 0, "walletMove");
        if (core.ethPot() != pot0) _flag(V_POT, "a coin move changed the pot");
        if (coin.totalSupply() != supply0) _flag(V_SUPPLY, "a coin move changed the supply");
    }

    /// the revert of the coin's allowlist setter for a caller that is not the token admin
    bytes4 internal constant COIN_NOT_ADMIN = 0x7bfa4b9f;

    /// the owner lists `who` on the coin allowlist. the token admin is the account that launched the coin, so the call
    /// succeeds exactly while the caller is that admin and the allowlist is open, and reverts with `COIN_NOT_ADMIN`
    /// otherwise (after a handover of the core the owner is no longer the admin). on success `who` sends `amt` coin to
    /// the core, a stranger's `rescueCoin` reverts with OnlyOwner, the owner's `rescueCoin` returns exactly `amt` to
    /// `who` and leaves no coin in the core, and `who` is taken off the list again
    function _allowRescue(address who, uint256 amt) internal {
        bool mayList = owner == coin.admin() && !coin.locked();
        vm.prank(owner);
        try coin.setAllowed(who, true) {
            if (!mayList) _flag(V_OWNER, "the allowlist changed for a caller that is not the token admin");
        } catch (bytes memory why) {
            if (mayList || bytes4(why) != COIN_NOT_ADMIN) {
                _unexpected(A_WALLET_MOVE, why);
            }
            return;
        }
        if (!mayList) return;
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        coin.transfer(address(core), amt);
        if (coin.balanceOf(address(core)) != amt) _flag(V_SUPPLY, "the allowlisted transfer did not reach the core");
        address stranger = address(uint160(uint256(keccak256(abi.encode("rescuer", who, amt)))));
        vm.prank(stranger);
        try core.rescueCoin(who, amt) {
            _flag(V_OWNER, "a stranger rescued coin from the core");
        } catch (bytes memory why) {
            if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(A_WALLET_MOVE, why);
        }
        vm.prank(owner);
        core.rescueCoin(who, amt);
        if (coin.balanceOf(who) != before) _flag(V_OWNER, "rescueCoin did not return exactly the coin sent");
        if (coin.balanceOf(address(core)) != 0) _flag(V_SUPPLY, "rescueCoin left coin in the core");
        vm.prank(owner);
        coin.setAllowed(who, false);
    }

    /// sells coin for eth through the launch pool. exact in or exact out.
    function sellCoin(uint256 aSeed, uint256 fracSeed, uint256 mode) external checked {
        uint8 a = A_SELL_COIN;
        address who = _actor(aSeed);
        uint256 bal = coin.balanceOf(who);
        if (bal < 1e6) return _skip(a);
        SwapPre memory p;
        p.exactIn = mode % 4 != 0;
        p.bps = _skimBps();
        uint256 part = bal * bound(fracSeed, 1, 100) / 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = p.exactIn ? -int256(part) : int256(_ethFor(part / 3));
        if (spec == 0) return _skip(a);
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap(launchKey, false, spec, who) {
            _ok(a);
            _afterSwap(p, vm.getRecordedLogs(), 0, "sellCoin");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "sellCoin");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    /// the books after a real swap. the core's only inflow is the hook's bounty leg, it must equal what the hook
    /// reported, what the rules of the hook give for the skimmed volume at the rate read before, and it must all
    /// be booked into the pot. `exactVolume` is the eth volume the swap must have skimmed on, when known
    function _afterSwap(SwapPre memory p, Vm.Log[] memory logs, uint256 exactVolume, string memory what) internal {
        (uint256 volume, uint256 bounty, uint256 protocol) = _skimOf(logs);
        if (p.bps > 1000) windowSwaps++;
        // the hook pushed the bounty leg to the core, which books nothing inside the swap. the book that follows counts it
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.tb) _flag(V_POT, "the core booked inside the swap");
        if (address(core).balance != p.bal + bounty) _flag(V_POT, "the core received other than the hook bounty leg");
        (uint256 held, uint256 toPots) = _bookNow(keeper, what);
        if (held != bounty) _flag(V_POT, "the book counted other than the hook bounty leg");
        // the book keeps `toPots` in the core and pushed the payee share out, so the balance rose by `toPots`
        _eth(p.bal, 0, toPots, what);
        if (volume != 0) {
            (uint256 eb, uint256 ep) = _expectSkim(bounty + protocol, p.bps);
            if (bounty != eb) _flag(V_POT, "skim bounty differs from the hook rules at the live rate");
            if (protocol != ep) _flag(V_POT, "skim creator leg differs from the hook rules at the live rate");
            if (!_skimTotalOk(volume, p.buy, p.bps, bounty + protocol)) {
                _flag(V_POT, "skim total differs from the hook rules at the live rate");
            }
        }
        // the hook reports the pool eth amount, which is the eth spent less the skim on an exact input buy
        if (exactVolume != 0 && (volume + bounty + protocol) + 2 < exactVolume) {
            _flag(V_POT, "skim volume is not the eth the swap spent");
        }
        if (exactVolume != 0 && (volume + bounty + protocol) > exactVolume) {
            _flag(V_POT, "skim volume is not the eth the swap spent");
        }
        // the whole skim is at most 90 percent of the gross eth of the swap. an exact output swap grosses the
        // skim up on top of the eth the pool moved
        uint256 gross = p.buy ? volume + bounty + protocol : volume;
        if ((bounty + protocol) * 10_000 > gross * 9_000 + 10_000) {
            _flag(V_POT, "skim above 90 percent of the swap");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              BUYING CREDITS
    //////////////////////////////////////////////////////////////*/

    struct SellPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 price;
        uint256 minuteStart;
        uint256 sellerBal;
        uint256[] ceil;
        Pull pull;
        uint256 pile;
        uint256 held;
    }

    /// @dev the ids `sellForEth` offers: walks the actor inventory from a picked offset, within the budget unless overshoot
    function _pickIds(address who, uint256 len, uint256 want, uint256 pick, bool overshoot)
        internal
        view
        returns (uint256[] memory ids, uint256 n)
    {
        ids = new uint256[](want);
        uint256 budget = _budget();
        uint256 sum;
        for (uint256 k; k < len && k < want * 3 + 4 && n < want; ++k) {
            uint256 id = inventory[who][(pick % len + k) % len];
            uint256 c = core.bidOf(id);
            // a credit priced at zero (an empty pot clamps the bid to zero) cannot be sold: the core refuses a zero spend
            if (c != 0 && (sum + c <= budget || overshoot)) {
                ids[n++] = id;
                sum += c;
            }
        }
    }

    /// sells credits the actor holds into the eth bid. ids are picked to fit the budget, so most calls pass,
    /// and now and then the call is made oversized or with a duplicate id to prove the core refuses it.
    function sellForEth(uint256 aSeed, uint256 nSeed, uint256 pick, uint256 mode) external pulls {
        uint8 a = A_SELL_FOR_ETH;
        address who = _actor(aSeed);
        if (_retiredRefusal(a, who, abi.encodeWithSignature("sellForEth(uint256[])", _firstOf(who)))) return;
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        bool overshoot = mode % 9 == 0;
        (uint256[] memory ids, uint256 n) = _pickIds(who, len, want, pick, overshoot);
        if (n == 0) return _skip(a);
        assembly {
            mstore(ids, n)
        }
        bool dup = mode % 17 == 0 && n > 1;
        if (dup) ids[1] = ids[0];

        SellPre memory p;
        p.pull = _beginPull();
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.pile = core.pileSize();
        p.held = core.heldStatements().length;
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.minuteStart = _minuteStartNow(p.price);
        p.sellerBal = who.balance;
        p.ceil = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p.ceil[i] = core.bidOf(ids[i]);
        }
        RS memory rs = _rs();
        _endPull(p.pull);
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.sellForEth(ids) {
            _ok(a);
            _afterSell(who, ids, p, rs.st);
        } catch (bytes memory why) {
            _failed(p.pull.bal0, p.pull.pot0, p.pull.rate0, "sellForEth");
            _refusedAbovePot(why);
            rs = p.pull.rs0;
            if (!overshoot && !dup && !(bytes4(why) == ICore.ZeroAmount.selector && _hasZeroSpend(ids, rs.st, p))) {
                _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    /// A tiny rate can round a later credit to zero after an earlier credit's drop.
    function _hasZeroSpend(uint256[] memory ids, Settings memory st, SellPre memory p) internal view returns (bool) {
        bool active = gSpendActive && gSpendBucket == block.timestamp / gSpendSeconds;
        uint256 budget = FullMath.mulDiv(active ? gSpendSnapshot : p.pot, st.spendCapBps, 10_000);
        uint256 spent = active ? gSpent : 0;
        for (uint256 i; i < ids.length; ++i) {
            uint256 score = _scoreOf(ids[i]);
            uint256 room = p.pot.zeroFloorSub(_reserveAt(st, p.pile + i, p.held));
            uint256 cost = FullMath.mulDiv(BidModel.read(st, room, p.price), score, RATE_SCORE);
            if (cost == 0) return true;
            if (cost > room) return false;
            if (st.spendCapBps != 10_000 && spent != 0 && (spent > budget || cost > budget - spent)) return false;
            spent += cost;
            p.pot -= cost;
            p.minuteStart = BidModel.startAfter(st, p.price, p.minuteStart);
            p.price = BidModel.dropOnce(st, p.price, p.minuteStart, score);
        }
        return false;
    }

    function _afterSell(address who, uint256[] memory ids, SellPre memory p, Settings memory st) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _pullChecks(p.pull, logs);
        uint256[] memory costs = new uint256[](ids.length);
        uint256 total;
        uint256 count;
        uint256 ceilSum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.CreditBought.selector) continue;
            uint256 id = uint256(logs[i].topics[1]);
            uint256 cost = abi.decode(logs[i].data, (uint256));
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == id) {
                    costs[j] = cost;
                    // invariant 2: no credit is bought above the read taken just before the action
                    if (cost > p.ceil[j]) _flag(V_ABOVE_CAP, "sellForEth above the read taken before");
                    ceilSum += p.ceil[j];
                    break;
                }
            }
            total += cost;
            count++;
        }
        if (count != ids.length) _flag(V_MODEL, "sellForEth bought a different number of credits");
        uint256 potLeft = p.pot;
        for (uint256 i; i < ids.length; ++i) {
            potLeft = _recordSpend(costs[i], potLeft);
        }
        uint256 paid = who.balance - p.sellerBal;
        if (paid != total) _flag(V_MODEL, "sellForEth paid differs from the sum of its events");
        if (paid > ceilSum) _flag(V_ABOVE_CAP, "sellForEth paid above the sum of the reads");
        _eth(p.bal, paid, 0, "sellForEth");
        if (core.ethPot() != potLeft) _flag(V_POT, "sellForEth pot not reduced by the price");

        // the drop on each fill, independently: dropPer100PointsBps times score over 100 points, no lower than the minute floor
        uint256[] memory scores = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            scores[i] = _scoreOf(ids[i]);
            _addCredit(ids[i], costs[i]);
            _removeFrom(inventory[who], ids[i]);
        }
        (uint256 stored, uint256 r) = _rateAfterSells(st, p, costs, scores);
        if (core.rateAtCheckpoint() != stored || core.ethRate() != r) {
            _flag(V_RATE_BOUND, "drop on fill differs from the scaled dropPer100PointsBps with the minute floor");
        }
        if (core.lastFillTime() != block.timestamp) _flag(V_RATE_BOUND, "fill did not reset the fill clock");
    }

    /// buy a listed credit from the real CreditStrategy when the ceiling allows. now and then the call is made
    /// with a wrong value or wrong calldata or above the ceiling, and must revert without moving eth.
    function listingStrategy(uint256 pick, uint256 mode) external pulls {
        uint8 a = A_LISTING_STRATEGY;
        if (_retiredListing(a, STRATEGY)) return;
        uint256 id;
        uint256 price;
        bool allowed;
        uint256 n = candidates.length;
        for (uint256 k; k < n; ++k) {
            uint256 cand = candidates[(pick % n + k) % n];
            if (gone[cand]) continue;
            uint256 p = ICreditStrategy(STRATEGY).nftForSale(cand);
            if (p == 0) continue;
            // the keeper payment is booked as spend on top of the price and stays inside the bid, which is inside the pot
            if (core.bidOf(cand) >= p) {
                id = cand;
                price = p;
                allowed = true;
                break;
            }
            if (id == 0) {
                id = cand;
                price = p;
            }
        }
        if (id == 0 || (!allowed && mode % 4 != 0)) return _skip(a);
        uint256 variant = mode % 7;
        uint256 value = variant == 0 ? price - 1 : price;
        uint256 dataId = variant == 1 ? candidates[(pick % n + 1) % n] : id;
        bytes memory data = abi.encodeCall(ICreditStrategy.sellTargetNFT, (dataId));
        _listing(a, id, value, data, STRATEGY, 0, allowed && variant > 1);
    }

    /// buy through a hostile target. only the honest modes may succeed, every other mode must revert and leave
    /// the core's eth where it was.
    function listingHostile(uint256 pick, uint256 modeSeed) external pulls {
        uint8 a = A_LISTING_HOSTILE;
        if (_retiredListing(a, address(probe))) return;
        uint256 n = probeIds.length;
        if (n < 2 || !core.allowedAdapter(rawAdapter)) return _skip(a);
        uint256 id = probeIds[pick % n];
        uint256 wrongId = probeIds[(pick % n + 1) % n];
        if (gone[id] || gone[wrongId]) return _skip(a);
        uint256 ceiling = core.bidOf(id);
        uint256 budget = _budget();
        uint256 cap = ceiling < budget ? ceiling : budget;
        if (cap < 100) return _skip(a);
        uint256 m = modeSeed % 9;
        probe.setMode(m);
        uint256 value = cap / 2 + 1;
        bytes memory data = abi.encodeCall(ProbeTarget.fill, (id, wrongId));
        uint256 t0 = address(probe).balance;
        // the probe sends part of the value back in modes 4 and 5, which the core refuses (a plain send reverts)
        bool hon = probe.honest(m);
        _listing(a, id, value, data, address(probe), 0, hon);
        if (!hon && viol[V_HOSTILE_OK] == 0 && address(probe).balance != t0) {
            // a hostile mode that reverted must also leave the target's eth where it was
            _flag(V_REVERT_CHANGED, "hostile target eth moved without a buy");
        }
        if (probe.reentered() != 0) _flag(V_REENTER, "a reentry attempt succeeded");
    }

    struct LPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 price;
        uint256 minuteStart;
        uint256 keeperBal;
        uint256 ceiling;
        Pull pull;
        uint256 res;
    }

    /// the shared body of the listing actions, through the test adapter. `refund` is the eth the target sends back to the
    /// core during the call, which stays unbooked
    function _listing(
        uint8 a,
        uint256 id,
        uint256 value,
        bytes memory data,
        address target,
        uint256 refund,
        bool expect
    ) internal {
        LPre memory p;
        p.pull = _beginPull();
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.res = core.reserve();
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.minuteStart = _minuteStartNow(p.price);
        p.keeperBal = keeper.balance;
        p.ceiling = core.bidOf(id);
        RS memory rs = _rs();
        _endPull(p.pull);
        vm.recordLogs();
        _att(a);
        vm.prank(keeper);
        try core.buyListing(rawAdapter, id, abi.encode(target, value, data)) {
            _ok(a);
            _afterListing(a, id, value, refund, p, rs.st);
        } catch (bytes memory why) {
            _failed(p.pull.bal0, p.pull.pot0, p.pull.rate0, "buyListing");
            rs = p.pull.rs0;
            if (expect) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterListing(uint8 a, uint256 id, uint256 value, uint256 refund, LPre memory p, Settings memory st)
        internal
    {
        _pullChecks(p.pull, vm.getRecordedLogs());
        if (a == A_LISTING_HOSTILE && !probe.honest(probe.mode())) {
            _flag(V_HOSTILE_OK, "a hostile listing target got a buy through");
        }
        uint256 paid = keeper.balance - p.keeperBal;
        uint256 cost = value;
        uint256 score = _scoreOf(id);
        // the per-credit bid from the handler's own rate model, not from `bidOf`: the read before the action times the
        // credit's score over 100 points. the value and the payment are capped at it
        uint256 room = p.pot.zeroFloorSub(p.res);
        uint256 ceiling = FullMath.mulDiv(BidModel.read(st, room, p.price), score, RATE_SCORE);
        if (value > ceiling) _flag(V_ABOVE_CAP, "listing value above the ceiling");
        if (cost + paid > ceiling) _flag(V_ABOVE_CAP, "listing cost plus payment above the ceiling");
        if (cost + paid > room) _flag(V_SPEND, "listing cost plus payment above the pot less the reserve");
        _listingPayChecks(paid, (ceiling > cost ? ceiling - cost : 0).min(room > cost ? room - cost : 0), st);
        uint256 potLeft = _recordSpend(cost + paid, p.pot);
        _eth(p.bal, paid + cost, refund, "buyListing");
        if (core.ethPot() != potLeft) _flag(V_POT, "listing pot not reduced by cost and the payment");
        uint256 stored = _dropped(st, p.price, p.minuteStart, score);
        if (core.rateAtCheckpoint() != stored || core.ethRate() != _readAfterFill(st, stored, potLeft)) {
            _flag(V_RATE_BOUND, "drop on fill differs from dropPer100PointsBps with the minute floor");
        }
        if (CREDITS.ownerOf(id) != address(core)) _flag(V_MODEL, "listing did not deliver the credit");
        gone[id] = true;
        _addCredit(id, cost + paid);
    }

    /// the payment of one `buyListing`: at most the bid less the cost, at most the gas cap at the capped base fee plus
    /// the keeper fee, and below the gap the keeper fee plus whole gas units at the capped base fee
    function _listingPayChecks(uint256 paid, uint256 gap, Settings memory st) internal {
        uint256 rate = block.basefee < st.keeperMaxBaseFee ? block.basefee : st.keeperMaxBaseFee;
        if (paid > gap || paid > BUYLISTING_GAS * rate + st.keeperFee) {
            _flag(V_LISTING_PAY, "listing payment above min(bid less cost, gas cap plus keeperFee)");
        } else if (
            paid != gap
                && (paid < st.keeperFee || (rate == 0 ? paid != st.keeperFee : (paid - st.keeperFee) % rate != 0))
        ) {
            _flag(V_LISTING_PAY, "listing payment is not the keeper fee plus whole gas units at the capped base fee");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  TIME
    //////////////////////////////////////////////////////////////*/

    /// mostly minutes to hours, now and then days. the price state climbs 1 to 8 percent an hour, so a
    /// fuzz that warps days at a time pins it at the clamp.
    function warp(uint256 dtSeed) external checked {
        _att(A_WARP);
        _advance(dtSeed % 10 == 0 ? _logBound(dtSeed / 10, 1 hours, 3 days) : _logBound(dtSeed / 10, 60, 6 hours), 0);
        _ok(A_WARP);
    }

    function roll(uint256 nSeed) external checked {
        _att(A_ROLL);
        uint256 n = bound(nSeed, 1, 300);
        _advance(n * 12, n);
        _ok(A_ROLL);
    }

    function _advance(uint256 dt, uint256 blocks_) internal {
        RS memory s = _rs();
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (blocks_ == 0 ? dt / 12 + 1 : blocks_));
        _rsCheck(s, dt);
    }

    /*//////////////////////////////////////////////////////////////
                         COMPOSE AND SALE
    //////////////////////////////////////////////////////////////*/

    /// the page the controller would answer, asked the way the core asks it.
    function _peekPage() internal view returns (bool ready, uint256[] memory ids) {
        ids = new uint256[](80);
        // the core reads the controller under a fixed gas cap of 500_000, and so does the model
        (bool ok, bytes memory out) = core.controller().staticcall{gas: 500_000}(abi.encodeWithSignature("nextPage()"));
        if (!ok || out.length < 82 * 32) return (false, ids);
        (uint256 flag, uint256[80] memory p,) = abi.decode(out, (uint256, uint256[80], uint256));
        for (uint256 i; i < 80; ++i) {
            ids[i] = p[i];
        }
        return (flag == 1, ids);
    }

    function _validPage(uint256[] memory ids) internal view returns (bool) {
        for (uint256 i; i < 80; ++i) {
            CG storage c = cg[ids[i]];
            if (!c.inPile) return false;
            for (uint256 j; j < i; ++j) {
                if (ids[j] == ids[i]) return false;
            }
        }
        return true;
    }

    struct CPre {
        uint256 pot;
        uint256 rate;
        uint256 bal;
        uint256 callerBal;
        uint256 supply;
        uint256 sum;
        uint256 basefee;
        Settings st;
        bool valid;
        Pull pull;
        /// the acquisition time of each credit on the page, read before the compose for the window ghost check
        uint64[] acq;
        /// the format a chosen compose names
        uint256 fmt;
    }

    /// composes the controller's page. rare by gate, because it costs about 8m gas.
    function compose(uint256 gate, uint256 feeSeed) external pulls {
        uint8 a = A_COMPOSE;
        if (_retiredRefusal(a, keeper, ComposeCall.noArgs())) return;
        (bool ready, uint256[] memory ids) = _peekPage();
        // a pile of 80 is composed on one gate in two. a short pile only now and then, to see NotReady
        if (ready ? gate % 2 != 0 : gate % 13 != 0) return _skip(a);
        CPre memory p;
        // the basefee is set before the snapshot of the pull, which restores the block environment
        p.basefee = _logBound(feeSeed, 0.05 gwei, 300 gwei);
        vm.fee(p.basefee);
        p.pull = _beginPull();
        p.valid = ready && _validPage(ids);
        p.st = core.settings();
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.bal = address(core).balance;
        p.callerBal = keeper.balance;
        p.supply = STATEMENTS.supply();
        p.acq = new uint64[](80);
        if (p.valid) {
            for (uint256 i; i < 80; ++i) {
                p.sum += cg[ids[i]].cost;
                (,, p.acq[i]) = core.creditInfo(ids[i]);
            }
        }
        RS memory rs = _rs();
        _endPull(p.pull);
        vm.recordLogs();
        _att(a);
        vm.prank(keeper);
        try core.compose() {
            _ok(a);
            _afterCompose(ids, p);
        } catch (bytes memory why) {
            rs = p.pull.rs0;
            _composeFailed(a, p, why);
        }
        _rsCheck(rs, 0);
    }

    /// a caller names 80 pile credits and a format for a compose. the handler names the oldest 80 ghost pile credits
    /// and a random format. the model expects success only with the real controller in force, chosen compose on, the
    /// caller's coin balance at least the minimum, and, while the credit sale is on, every named credit past its window
    function composeChosen(uint256 fmtSeed, uint256 gate) external pulls {
        uint8 a = A_COMPOSE_CHOSEN;
        uint256[80] memory ids;
        uint64[] memory acq = new uint64[](80);
        uint256 sum;
        uint256 got;
        for (uint256 i; i < cgList.length && got < 80; ++i) {
            uint256 id = cgList[i];
            if (!cg[id].inPile) continue;
            ids[got] = id;
            (,, acq[got]) = core.creditInfo(id);
            sum += cg[id].cost;
            got++;
        }
        uint8 format = uint8(fmtSeed % 8);
        if (_retiredRefusal(a, keeper, abi.encodeCall(ICore.composeChosen, (ids, format)))) return;
        if (got < 80) return _skip(a);
        // a compose of 80 costs several million gas: gate it so a run does not spend its depth here
        if (gate % 2 != 0) return _skip(a);
        bool ctlReal = core.controller() == v1;
        bool windowOk = true;
        if (ctlReal && IControllerV1(v1).creditSaleOn()) {
            uint256 window = IControllerV1(v1).creditWindow();
            uint64 newest;
            for (uint256 i; i < 80; ++i) {
                if (acq[i] > newest) newest = acq[i];
            }
            windowOk = uint256(newest) + window <= block.timestamp;
        }
        bool expect = core.chosenComposeOn() && coin.balanceOf(keeper) >= core.minCcToChoose() && ctlReal && windowOk;
        CPre memory p;
        p.basefee = _logBound(fmtSeed, 0.05 gwei, 300 gwei);
        vm.fee(p.basefee);
        p.pull = _beginPull();
        p.st = core.settings();
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.bal = address(core).balance;
        p.callerBal = keeper.balance;
        p.supply = STATEMENTS.supply();
        p.sum = sum;
        p.acq = acq;
        p.fmt = format;
        RS memory rs = _rs();
        _endPull(p.pull);
        vm.recordLogs();
        _att(a);
        vm.prank(keeper);
        try core.composeChosen(ids, format) {
            _ok(a);
            _afterComposeChosen(ids, p);
        } catch (bytes memory why) {
            rs = p.pull.rs0;
            _failed(p.pull.bal0, p.pull.pot0, p.pull.rate0, "composeChosen");
            if (expect && !_hostileController()) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /// a coin holder sets the format of a held statement. the caller is the first actor from the seed that holds at
    /// least `minCcToChoose` coin, and the call must succeed and read back through `formatOf`. when no actor holds that
    /// much, the call is made by the seed's actor and must revert `BelowMinCc`. only held statements are named
    function setHeldFormat(uint256 sSeed, uint256 fmtSeed) external checked {
        uint8 a = A_SET_HELD_FORMAT;
        (uint256 sid, bool found) = _pickBy(sSeed, K_HELD);
        if (!found) return _skip(a);
        (bool held,,) = core.statementInfo(sid);
        if (!held) return _skip(a);
        uint8 format = uint8(fmtSeed % 8);
        uint256 min = core.minCcToChoose();
        address caller = _actor(sSeed >> 8);
        bool funded;
        for (uint256 i; i < actors.length; ++i) {
            address c = _actor((sSeed >> 8) + i);
            if (coin.balanceOf(c) >= min) {
                caller = c;
                funded = true;
                break;
            }
        }
        bool changed = STATEMENTS.formatOf(sid) != format;
        _att(a);
        vm.prank(caller);
        try core.setHeldFormat(sid, format) {
            _ok(a);
            if (!funded) _flag(V_MODEL, "setHeldFormat took a caller below minCcToChoose");
            if (STATEMENTS.formatOf(sid) != format) _flag(V_MODEL, "formatOf differs from the format set");
            else if (funded && changed) fundedRestyles++;
        } catch (bytes memory why) {
            if (funded || bytes4(why) != ICore.BelowMinCc.selector) _unexpected(a, why);
            else _ok(a);
        }
    }

    /// the checks after a chosen compose, the same as a regular compose: the new statement is the next id and held, the
    /// caller payment is inside the rule, the cost basis is the sum of the credits' costs, and no composed credit was
    /// inside its credit sale window
    function _afterComposeChosen(uint256[80] memory ids, CPre memory p) internal {
        _pullChecks(p.pull, vm.getRecordedLogs());
        uint256 sid = STATEMENTS.supply();
        if (STATEMENTS.formatOf(sid) != p.fmt) {
            _flag(V_COMPOSE, "the chosen statement format differs from the one named");
        }
        if (sid != p.supply + 1 || STATEMENTS.ownerOf(sid) != address(core)) {
            _flag(V_COMPOSE, "chosen compose statement id is not supply + 1 or not held by the core");
        }
        _callerPayment(V_COMPOSE, p.st, COMPOSE_GAS, p.pot, p.bal, p.callerBal, "composeChosen");
        (bool held, uint256 coreCost, uint64 composedAt) = core.statementInfo(sid);
        if (!held || coreCost != p.sum) _flag(V_MODEL, "chosen statement cost basis differs from the ghost sum");
        if (composedAt != block.timestamp) _flag(V_MODEL, "the chosen compose time is not the block time");
        _windowGhost(p.acq, block.timestamp);
        for (uint256 i; i < 80; ++i) {
            cg[ids[i]].inPile = false;
        }
        SG storage g = _sg[sid];
        g.cost = p.sum;
        g.composedAt = composedAt;
        g.status = S_HELD;
        everHeld.push(sid);
    }

    /// while the credit sale is on and the real controller is in force, every composed credit must have sat past its
    /// window at the compose: the core and the controller gate compose on it. a credit still inside its window reaching
    /// a statement is a violation
    function _windowGhost(uint64[] memory acq, uint256 composeTime) internal {
        if (core.controller() != v1 || !IControllerV1(v1).creditSaleOn()) return;
        uint256 window = IControllerV1(v1).creditWindow();
        for (uint256 i; i < acq.length; ++i) {
            if (acq[i] != 0 && uint256(acq[i]) + window > composeTime) {
                _flag(V_COMPOSE, "a composed credit was inside its credit sale window");
            }
        }
    }

    function _composeFailed(uint8 a, CPre memory p, bytes memory why) internal {
        _failed(p.pull.bal0, p.pull.pot0, p.pull.rate0, "compose");
        // a hostile controller may burn the core's 500_000 gas read of its page. the fuzz controller tries its
        // state changing attacks only inside the core's frame (each one halting a static frame burns the 300_000 gas
        // it was given), so the handler's own uncapped looking pre check cannot see that cost and the core answers
        // NotReady for a page the pre check saw as ready
        bool hostileNotReady = bytes4(why) == ICore.NotReady.selector && _hostileController();
        if (p.valid && !hostileNotReady) {
            _unexpected(a, why);
        }
    }

    /// @dev the caller payment of `compose`, `composeChosen` and `redeemStatement`: at most the counted gas bound at the base
    /// fee capped by `callerMaxBaseFee` plus `callerFee`, at least the fee when the pot covers it, at most the pot,
    /// exactly zero when both settings are zero, and exactly the debit of the pot and the outflow of the core
    function _callerPayment(
        uint256 code,
        Settings memory st,
        uint256 gasBound,
        uint256 pot0,
        uint256 bal0,
        uint256 callerBal0,
        string memory what
    ) internal {
        uint256 pay = keeper.balance - callerBal0;
        uint256 rate = block.basefee < st.callerMaxBaseFee ? block.basefee : st.callerMaxBaseFee;
        uint256 most = gasBound * rate + st.callerFee;
        if (pay > most) _flag(code, string.concat(what, " paid above the gas bound plus the fee"));
        if (pay > pot0) _flag(code, string.concat(what, " paid above the pot"));
        uint256 least = st.callerFee < pot0 ? st.callerFee : pot0;
        if (pay < least) _flag(code, string.concat(what, " paid below the fee"));
        if (st.callerFee == 0 && st.callerMaxBaseFee == 0 && pay != 0) {
            _flag(code, string.concat(what, " paid with the payment off"));
        }
        if (core.ethPot() != pot0 - pay) _flag(V_POT, string.concat(what, " did not debit the pot by the payment"));
        _eth(bal0, pay, 0, what);
    }

    function _afterCompose(uint256[] memory ids, CPre memory p) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _pullChecks(p.pull, logs);
        if (!p.valid) _flag(V_COMPOSE, "composed a page the ghost model considers invalid");
        uint256 sid = STATEMENTS.supply();
        // the core ignores the controller's format: the default is derived from prevrandao and the head credit id
        uint256 want = uint256(keccak256(abi.encode(block.prevrandao, ids[0]))) % 8;
        if (STATEMENTS.formatOf(sid) != want) {
            _flag(V_COMPOSE, "the composed statement format differs from the default");
        }
        if (sid != p.supply + 1 || STATEMENTS.ownerOf(sid) != address(core)) {
            _flag(V_COMPOSE, "new statement id is not supply + 1 or not held by the core");
        }
        _callerPayment(V_COMPOSE, p.st, COMPOSE_GAS, p.pot, p.bal, p.callerBal, "compose");
        uint256 cost = p.sum;
        (bool held, uint256 coreCost, uint64 composedAt) = core.statementInfo(sid);
        if (!held || coreCost != cost) _flag(V_MODEL, "statement cost basis differs from the ghost sum");
        if (composedAt != block.timestamp) _flag(V_MODEL, "the compose time is not the block time");
        _windowGhost(p.acq, block.timestamp);
        for (uint256 i; i < 80; ++i) {
            cg[ids[i]].inPile = false;
        }
        SG storage g = _sg[sid];
        g.cost = cost;
        g.composedAt = composedAt;
        g.status = S_HELD;
        everHeld.push(sid);
    }

    /// the controller in force is the hostile fuzz controller, which may burn the gas of its page or answer short
    function _hostileController() internal view returns (bool) {
        return core.controller() == address(fuzz) && fuzz.hostile();
    }

    /*//////////////////////////////////////////////////////////////
                           BUYBACK, SKIM, DONATE
    //////////////////////////////////////////////////////////////*/

    struct BbPre {
        uint256 bal;
        uint256 pot;
        uint256 pool;
        uint256 rate;
        uint256 slice;
        uint256 maxPay;
        uint256 gasRate;
        uint256 whoBal;
        uint256 dead;
        uint256 bps;
        Settings st;
    }

    /// the eth buyback: the core swaps a slice of the buyback pot for coin in the real pool and burns the coin on
    /// the token. the hook's skim of that swap comes back into the core's receive() as an inflow. the supply ghost
    /// falls by the coin the pool handed to the core, measured from the token's transfer events
    function buyback(uint256 aSeed) external checked {
        uint8 a = A_BUYBACK;
        address who = _actor(aSeed);
        BbPre memory p;
        p.st = core.settings();
        p.pool = core.ethToBuyback();
        if (p.pool == 0 || (block.number < core.lastBuybackBlock() + p.st.buybackDelay && aSeed % 5 != 0)) {
            return _skip(a);
        }
        p.slice = p.pool < p.st.buybackSlice ? p.pool : p.st.buybackSlice;
        p.gasRate = block.basefee < p.st.keeperMaxBaseFee ? block.basefee : p.st.keeperMaxBaseFee;
        p.maxPay = BUYBACK_GAS * p.gasRate + p.st.keeperFee;
        // a slice under twice the largest payment reverts with SliceTooSmall
        if (p.slice < 2 * p.maxPay) return _skip(a);
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.whoBal = who.balance;
        p.dead = coin.balanceOf(DEAD);
        p.bps = _skimBps();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.buyback() {
            _ok(a);
            _afterBuyback(who, p, vm.getRecordedLogs());
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyback");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    function _afterBuyback(address who, BbPre memory p, Vm.Log[] memory logs) internal {
        uint256 tip = who.balance - p.whoBal;
        uint256 spent;
        uint256 evTip;
        uint256 bought;
        uint256 burned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.Buyback.selector) {
                (spent, evTip) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].emitter == address(coin) && logs[i].topics[0] == TRANSFER) {
                (uint256 amt) = abi.decode(logs[i].data, (uint256));
                if (address(uint160(uint256(logs[i].topics[2]))) == address(core)) bought += amt;
                if (address(uint160(uint256(logs[i].topics[1]))) == address(core) && logs[i].topics[2] == 0) {
                    burned += amt;
                }
            }
        }
        (uint256 volume, uint256 bounty, uint256 protocol) = _skimOf(logs);
        uint256 budget = p.slice - p.maxPay;
        if (p.bps > 1000) windowSwaps++;
        if (bought == 0) _flag(V_BUYBACK, "buyback bought no coin");
        if (burned != bought) _flag(V_BUYBACK, "buyback did not burn exactly the coin it bought");
        if (spent == 0 || spent > budget) {
            _flag(V_BUYBACK, "buyback spent more than the slice less the largest payment");
        }
        if (evTip != tip) _flag(V_BUYBACK, "buyback payment event differs from what the caller received");
        // the payment is the keeper fee scaled by the budget spent over the largest budget the setting allows, plus
        // counted gas at the capped base fee
        uint256 feePart = p.st.keeperFee * spent / (p.st.buybackSlice - p.maxPay);
        if (tip < feePart || tip > feePart + BUYBACK_GAS * p.gasRate) {
            _flag(V_BUYBACK, "buyback payment is outside the scaled fee plus the gas refund cap");
        } else if (p.gasRate == 0 ? tip != feePart : (tip - feePart) % p.gasRate != 0) {
            _flag(V_BUYBACK, "buyback gas refund is not counted gas at the capped base fee");
        }
        _buybackPotChecks(p, spent, tip, bounty);
        // a dust swap (the skim of it rounds to nothing) emits no skim event at all, and the fee share can now leave
        // one wei in the buyback pot, so a volume of zero is right when the whole skim rounds to zero
        _buybackSkimChecks(p, volume, bounty, protocol, spent, bought);
    }

    /// @dev the book and pot checks of a buyback (a helper so the locals of `_afterBuyback` fit the stack)
    function _buybackPotChecks(BbPre memory p, uint256 spent, uint256 tip, uint256 bounty) internal {
        // the skim of the swap reached the core inside the unlock and waits for the book, which splits it by the settings
        if (core.ethToBuyback() != p.pool - spent - tip) {
            _flag(V_BUYBACK, "buyback pot is not the pot less what was spent and paid, before the book");
        }
        (uint256 held, uint256 toPots) = _bookNow(keeper, "buyback");
        if (held != bounty) _flag(V_BUYBACK, "the book counted other than the hook bounty leg");
        // eth leaves as the swap input plus the payment; the skim comes back and the book keeps toPots, having pushed
        // the payee share out
        _eth(p.bal, spent + tip, toPots, "buyback");
        uint256 rb = toPots * core.settings().feeToRedeemBurnBps / 10_000;
        if (core.ethToBuyback() != p.pool - spent - tip) {
            _flag(V_BUYBACK, "buyback pot is not the pot less what was spent and paid");
        }
        if (core.ethPot() != p.pot + toPots - rb) _flag(V_POT, "buyback skim not booked to the pot");
    }

    /// @dev the skim and burn checks of a buyback (a helper so the locals of `_afterBuyback` fit the stack)
    function _buybackSkimChecks(
        BbPre memory p,
        uint256 volume,
        uint256 bounty,
        uint256 protocol,
        uint256 spent,
        uint256 bought
    ) internal {
        bool dust = volume == 0 && spent * p.bps / 10_000 == 0;
        uint256 sum = volume + bounty + protocol;
        if ((sum != spent) && !dust) _flag(V_BUYBACK, "buyback skim volume plus skim is not the eth spent");
        (uint256 eb, uint256 ep) = _expectSkim(bounty + protocol, p.bps);
        if (bounty != eb || protocol != ep) _flag(V_BUYBACK, "buyback skim differs from the hook rules");
        if (coin.balanceOf(DEAD) != p.dead) _flag(V_BUYBACK, "the buyback moved coin to the burn address");
        gSupply -= bought;
        gBurnedByBuyback += bought;
    }

    /// puts eth into the core five ways, and in the balance side balance token. by mode: a plain send from an account
    /// (refused with UseFund), `fund` (added to the pot whole), a push from the hook or from the escrow (accepted, left for
    /// the next book), and eth forced in without a call (left for the next book too). `receive()` must accept every
    /// hook and escrow send and refuse every other
    function donate(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_DONATE;
        address who = _actor(aSeed);
        uint256 amt = _logBound(amtSeed, 1, 5 ether);
        uint256 mode = amtSeed % 5;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 tb0 = core.ethToBuyback();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        if (mode == 0) {
            vm.deal(who, who.balance + amt);
            receiveSends++;
            vm.prank(who);
            (bool sent, bytes memory why) = address(core).call{value: amt}("");
            if (sent) _flag(V_RECEIVE, "a plain send from an account was accepted");
            else if (bytes4(why) != ICore.UseFund.selector) _flag(V_RECEIVE, "a plain send reverted other than UseFund");
            else _ok(a);
            _failed(b0, pot0, rate0, "donate");
        } else if (mode == 1) {
            vm.deal(who, who.balance + amt);
            vm.prank(who);
            try core.fund{value: amt}() {
                _ok(a);
                _booked(amt);
                _eth(b0, 0, amt, "fund");
                if (core.ethPot() != pot0 + amt || core.ethToBuyback() != tb0) {
                    _flag(V_POT, "fund did not add the whole amount to the pot");
                }
            } catch (bytes memory why) {
                _failed(b0, pot0, rate0, "donate");
                _unexpected(a, why);
            }
        } else if (mode == 2 || mode == 3) {
            address sender = mode == 2 ? HOOK : core.ESCROW();
            vm.deal(sender, sender.balance + amt);
            receiveSends++;
            vm.prank(sender);
            (bool sent,) = address(core).call{value: amt}("");
            if (!sent) {
                receiveFails++;
                _flag(V_RECEIVE, "a send from the hook or the escrow was refused");
                _failed(b0, pot0, rate0, "donate");
            } else {
                _ok(a);
                _eth(b0, 0, amt, "donate");
                if (core.ethPot() != pot0 || core.ethToBuyback() != tb0) _flag(V_POT, "a push was booked by receive");
            }
        } else {
            // eth forced in, as a selfdestruct would
            vm.deal(address(core), address(core).balance + amt);
            _ok(a);
            _eth(b0, 0, amt, "forced eth");
        }
        if (phase2() && amtSeed % 3 == 0) {
            uint256 dust = amt * 1000;
            _xt().mint(address(core), dust);
            gDonatedX[address(_xt())] += dust;
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               SWAP CREDIT
    //////////////////////////////////////////////////////////////*/

    /// the sum of the scores of the credits in the pile, read from the chain
    function _pileScore() internal view returns (uint256 sum) {
        uint256[] memory ids = core.pilePage(0, core.pileSize());
        for (uint256 i; i < ids.length; ++i) {
            sum += _scoreOf(ids[i]);
        }
    }

    /// the dedicated swapper and the credits it holds outside the pile. no other action spends them, so the swap always
    /// has an incoming credit
    address public swapper;
    uint256[] internal swapperCredits;

    function setSwapper(address who, uint256[] calldata ids) external {
        swapper = who;
        for (uint256 i; i < ids.length; ++i) {
            swapperCredits.push(ids[i]);
        }
    }

    /// the swapper swaps a pile credit for one it owns of equal or higher score, for the `swapFeeCc` coin fee it burns.
    /// the swapper's highest score credit goes in for the pile's lowest score credit, so a payable pair is used when one
    /// exists. the pile score must not fall, the incoming credit inherits the node and the outgoing one returns to the
    /// swapper, and the fee burns the swapper's coin
    function swapCredit(uint256, uint256 pick) external checked {
        uint8 a = A_SWAP_CREDIT;
        if (_retiredRefusal(a, swapper, abi.encodeCall(ICore.swapCredit, (1, 1)))) return;

        // the incoming credit: the swapper's credit of the highest score
        uint256 len = swapperCredits.length;
        if (len == 0) return _skip(a);
        uint256 inId;
        uint256 inScore;
        for (uint256 i; i < len; ++i) {
            uint256 id = swapperCredits[(pick + i) % len];
            uint256 sc = _scoreOf(id);
            if (inId == 0 || sc > inScore) {
                inId = id;
                inScore = sc;
            }
        }
        // the outgoing credit: the pile credit of the lowest score
        uint256 outId;
        uint256 outScore = type(uint256).max;
        for (uint256 i; i < cgList.length; ++i) {
            uint256 id = cgList[i];
            if (!cg[id].inPile) continue;
            uint256 sc = _scoreOf(id);
            if (sc < outScore) {
                outScore = sc;
                outId = id;
            }
        }
        if (outId == 0) return _skip(a);

        uint256 fee = core.settings().swapFeeCc;
        // the swapper burns the fee from coin it already holds, part of the launch supply
        if (fee != 0 && coin.balanceOf(swapper) < fee) return _skip(a);

        if (inScore < outScore) {
            // the score rule refuses the swap and changes nothing
            _att(a);
            vm.prank(swapper);
            try core.swapCredit(inId, outId) {
                _flag(V_MODEL, "swapCredit took a lower score credit");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.ScoreTooLow.selector) _unexpected(a, why);
            }
            return;
        }

        if (fee != 0) {
            vm.prank(swapper);
            coin.approve(address(core), fee);
        }
        // the incoming credit inherits the outgoing one's cost basis, read from the chain
        (, uint256 cost,) = core.creditInfo(outId);
        uint256 before = _pileScore();
        _att(a);
        vm.prank(swapper);
        try core.swapCredit(inId, outId) {
            _ok(a);
            // the pile score of the swap must not fall
            if (_pileScore() < before) _flag(V_MODEL, "swapCredit lowered the pile score");
            // the incoming credit inherits the outgoing one's node, the outgoing one returns to the swapper
            cg[outId].inPile = false;
            _addCredit(inId, cost);
            _removeFrom(swapperCredits, inId);
            swapperCredits.push(outId);
            // the fee burned the swapper's coin
            if (fee != 0) {
                gSupply -= fee;
                gBurnedBySwap += fee;
            }
        } catch (bytes memory why) {
            _unexpected(a, why);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADOPT
    //////////////////////////////////////////////////////////////*/

    /// anyone adopts credits the core holds without a record. by mode: an actor sends 1 to 4 of its credits straight to
    /// the core and adopts them (each gets the cost basis of the model price state times its score over 100 points, at
    /// least 1 wei, and the rate state, the pots and the balance stay as they were), adopts a credit that is in a pile
    /// (`InPile`), adopts a credit an actor holds (`NotHolder`), adopts an empty list (`Empty`) or the zero id
    /// (`ZeroId`). a refused call changes nothing
    function adopt(uint256 aSeed, uint256 nSeed, uint256 mode) external pulls {
        uint8 a = A_ADOPT;
        address who = _actor(aSeed);
        if (_retiredRefusal(a, who, abi.encodeCall(ICore.adopt, (_firstOf(who))))) return;
        uint256 m = mode % 9;
        uint256[] memory ids;
        bytes4 want;
        if (m < 5) {
            uint256 len = inventory[who].length;
            if (len == 0) return _skip(a);
            ids = new uint256[](bound(nSeed, 1, 4).min(len));
            for (uint256 k; k < ids.length; ++k) {
                ids[k] = inventory[who][(nSeed / 7 + k) % len];
            }
            if (_hasDuplicate(ids)) return _skip(a);
            for (uint256 k; k < ids.length; ++k) {
                vm.prank(who);
                CREDITS.transferFrom(who, address(core), ids[k]);
                _removeFrom(inventory[who], ids[k]);
            }
        } else if (m == 5 || m == 6) {
            uint256 n = cgList.length;
            if (n == 0) return _skip(a);
            uint256 id;
            for (uint256 k; k < n && id == 0; ++k) {
                uint256 c = cgList[(nSeed + k) % n];
                if (cg[c].inPile) id = c;
            }
            if (id == 0) return _skip(a);
            ids = new uint256[](1);
            ids[0] = id;
            want = ICore.InPile.selector;
        } else if (m == 7) {
            uint256 len = inventory[who].length;
            if (len == 0) return _skip(a);
            ids = new uint256[](1);
            ids[0] = inventory[who][nSeed % len];
            want = ICore.NotHolder.selector;
        } else {
            ids = new uint256[](nSeed % 2);
            want = ids.length == 0 ? ICore.Empty.selector : ICore.ZeroId.selector;
        }

        // the door books first, so the state the call prices against is the state after that book
        address caller = _actor(aSeed >> 32);
        Pull memory pull = _beginPull();
        AdoptPre memory p = _adoptPre(ids);
        _endPull(pull);
        vm.recordLogs();
        _att(a);
        vm.prank(caller);
        try core.adopt(ids) {
            if (want != bytes4(0)) _flag(V_MODEL, "adopt took an id that must be refused");
            else _ok(a);
            _pullChecks(pull, vm.getRecordedLogs());
            _adoptPost(p, ids, want == bytes4(0));
            _rsCheck(p.rs, 0);
        } catch (bytes memory why) {
            if (want == bytes4(0) || bytes4(why) != want) _unexpected(a, why);
            _failed(pull.bal0, pull.pot0, pull.rate0, "adopt");
            _adoptPost(p, ids, false);
            _rsCheck(pull.rs0, 0);
        }
    }

    struct AdoptPre {
        RS rs;
        uint256 b0;
        uint256 tb0;
        uint256 size0;
        uint256 anchor0;
        uint256 floor0;
        uint256 bucket0;
        uint256[] costs;
    }

    /// the state an adopt must leave alone, and the cost basis the model gives each id
    function _adoptPre(uint256[] memory ids) internal view returns (AdoptPre memory p) {
        p.rs = _rs();
        p.b0 = address(core).balance;
        p.tb0 = core.ethToBuyback();
        p.size0 = core.pileSize();
        uint256 price = _priceNow(p.rs.st);
        p.costs = new uint256[](ids.length);
        for (uint256 k; k < ids.length; ++k) {
            p.costs[k] = FullMath.mulDiv(price, _scoreOf(ids[k]), RATE_SCORE).max(1);
        }
        (p.anchor0, p.floor0, p.bucket0) = _anchorState();
    }

    /// after the call: the pile grew by the ids when the call was meant to pass and not at all otherwise, each adopted
    /// credit has the modelled record (and enters the ghost), and the rate state, the pots and the balance
    /// are as before
    function _adoptPost(AdoptPre memory p, uint256[] memory ids, bool passes) internal {
        // a refused call reverted whole, pull included: the state is the one before the pull, which `_failed` checks
        if (!passes && p.size0 != core.pileSize()) {
            _flag(V_MODEL, "a refused adopt changed the pile");
            return;
        }
        if (!passes) return;
        uint256 grew = core.pileSize() - p.size0;
        if (grew != (passes ? ids.length : 0)) {
            _flag(V_MODEL, "adopt changed the pile by another number than its credits");
        }
        if (passes && grew == ids.length) {
            for (uint256 k; k < ids.length; ++k) {
                (bool inPile, uint256 cost, uint64 at) = core.creditInfo(ids[k]);
                if (!inPile || cost != p.costs[k] || at != block.timestamp) {
                    _flag(V_MODEL, "an adopted credit has another record than the price state");
                }
                _addCredit(ids[k], p.costs[k]);
            }
        }
        (uint256 anchor1, uint256 floor1, uint256 bucket1) = _anchorState();
        if (
            core.rateAtCheckpoint() != p.rs.stored || core.checkpointTime() != p.rs.cp
                || core.lastFillTime() != p.rs.lastFill || anchor1 != p.anchor0 || floor1 != p.floor0
                || bucket1 != p.bucket0
        ) _flag(V_RATE_BOUND, "adopt moved the rate state");
        if (core.ethPot() != p.rs.pot || core.ethToBuyback() != p.tb0 || address(core).balance != p.b0) {
            _flag(V_POT, "adopt moved eth or a pot");
        }
    }

    function _hasDuplicate(uint256[] memory ids) internal pure returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                if (ids[i] == ids[j]) return true;
            }
        }
        return false;
    }

    /// anyone books the fee income, now and then after the hook or the escrow pushed some eth. the book counts
    /// everything above the tracked eth, splits it by the model, pushes the payee share and leaves nothing unbooked. now
    /// and then the owner first points the payee at a fresh, reverting or burning account: the forced push reaches each
    function book(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_BOOK;
        address who = _actor(aSeed);
        _att(a);
        uint256 m = amtSeed % 6;
        if ((m == 1 || m == 2 || m == 3) && owner == core.owner()) {
            address next = m == 1
                ? address(uint160(uint256(keccak256(abi.encode("payee", aSeed))) | 0x10000))
                : (m == 2 ? _badPayee(false) : _badPayee(true));
            vm.prank(owner);
            try core.setPayee(next) {
                gPayee = next;
            } catch (bytes memory why) {
                _unexpected(a, why);
            }
        }
        if (amtSeed % 3 == 0) {
            uint256 amt = _logBound(amtSeed >> 4, 1, 3 ether);
            address sender = amtSeed % 2 == 0 ? HOOK : core.ESCROW();
            vm.deal(sender, sender.balance + amt);
            vm.prank(sender);
            (bool ok,) = address(core).call{value: amt}("");
            if (!ok) _flag(V_RECEIVE, "a send from the hook or the escrow was refused");
        }
        uint256 b0 = address(core).balance;
        RS memory rs = _rs();
        (uint256 inc, uint256 toPots) = _bookNow(who, "book");
        // the book keeps the pots in the core and pushes the payee share out, so the balance falls by the share
        if (address(core).balance != b0 - (inc - toPots)) _flag(V_PAYEE, "a book moved other than the pushed share");
        if (_unbooked() != 0) _flag(V_POT, "a book left eth unbooked");
        if (inc != 0) {
            // the book checkpointed the rate before the pot grew
            if (core.checkpointTime() != block.timestamp) _flag(V_RATE_BOUND, "a book with income did not checkpoint");
        }
        _ok(a);
        // the book checkpointed the rate: with the pages multiplier read at the current rate (decision 128 variant d),
        // the checkpoint can move the read, so the read follows the model from the state the book left rather than
        // matching the pre book quote exactly
        _rsCheck(rs, 0);
    }

    /// a payee that reverts, or one that burns all its gas, created once each
    address internal revertingPayee;
    address internal burningPayee;

    function _badPayee(bool burn) internal returns (address) {
        if (revertingPayee == address(0)) {
            revertingPayee = address(new RevertingPayee());
            burningPayee = address(new BurningPayee());
        }
        return burn ? burningPayee : revertingPayee;
    }

    /// one door call with the book inside it. `*0` is the state before the book (what a reverted door leaves), the rest is
    /// what the book does to the state: the income, the part booked into the pots and the share credited to the payee
    struct Pull {
        uint256 snap;
        uint256 bal0;
        uint256 pot0;
        uint256 rate0;
        RS rs0;
        uint256 income;
        uint256 toPots;
        uint256 share;
        uint256 payee0;
    }

    /// the eth pot doors (`sellForEth`, `buyListing`, `compose`, `composeChosen`, `adopt`) start with the core's book of the
    /// fee income. this runs the same book now, under a snapshot, so the state read between `_beginPull` and `_endPull`
    /// is the state the door prices against. the handler writes no storage in between. `_endPull` restores the state
    /// before the book, and the door then runs the book itself
    function _beginPull() internal returns (Pull memory q) {
        q.bal0 = address(core).balance;
        q.pot0 = core.ethPot();
        q.rate0 = core.ethRate();
        q.rs0 = _rs();
        q.income = _unbooked();
        q.payee0 = gPayee.balance;
        Pots memory p = _pots();
        q.snap = vm.snapshotState();
        uint256 payeeBefore = gPayee.balance;
        if (q.income != 0) {
            try core.book() {} catch {}
        }
        q.toPots = core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() - p.pot - p.tb - p.rb;
        q.share = gPayee.balance - payeeBefore;
    }

    function _endPull(Pull memory q) internal {
        vm.revertToStateAndDelete(q.snap);
    }

    /// after a door succeeded: the book inside it did what the model gives. the income was counted once (one `FeesAdded` of
    /// the income less the payee share, none for no income), the payee share and the latch follow the model, and the
    /// pots took the part the model gives
    function _pullChecks(Pull memory q, Vm.Log[] memory logs) internal {
        uint256 events;
        uint256 seen;
        uint256 seenPayee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.FeesAdded.selector) continue;
            events++;
            (seen, seenPayee) = abi.decode(logs[i].data, (uint256, uint256));
        }
        (uint256 share, uint256 toPots) = _bookModel(q.income);
        if (events != (q.income != 0 ? 1 : 0)) _flag(V_PAYEE, "the door booked other than the book rule gives");
        if (q.income != 0 && (seen != toPots || seenPayee != share)) {
            _flag(V_PAYEE, "the door logged other than the income less the share and the pushed share");
        }
        if (share != q.share || toPots != q.toPots + q.share - share) {
            _flag(V_PAYEE, "the door book differs from the model of the book");
        }
        _pushedToPayee(q.payee0, share, "door book");
        gEthIn += q.income;
        gEthOut += share;
        if (core.payeeOn() != gPayeeOn) {
            _flag(V_PAYEE, "the payee latch after the door differs from the model");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                CONTROLLER
    //////////////////////////////////////////////////////////////*/

    /// changes the answers of the fuzz controller. in the hostile suite it stays hostile.
    function controllerSeed(uint256 seed) external checked {
        _att(A_CONTROLLER_SEED);
        fuzz.setSeed(seed);
        _ok(A_CONTROLLER_SEED);
    }

    /// the owner swaps the controller at once, between the v1 controller and the fuzz controller
    function controllerSwap(uint256 which) external checked {
        uint8 a = A_CONTROLLER_SWAP;
        if (!canSwapController) return _skip(a);
        address target = which % 2 == 0 ? v1 : address(fuzz);
        if (target == core.controller()) return _skip(a);
        _att(a);
        bool locked = core.controllerLocked();
        vm.prank(owner);
        try core.setController(target) {
            if (locked) _flag(V_LOCK, "a locked controller door took a new controller");
            if (core.controller() != target) _flag(V_MODEL, "controller not set at once");
            _ok(a);
        } catch (bytes memory why) {
            if (!locked || bytes4(why) != ICore.Locked.selector) _unexpected(a, why);
            else _ok(a);
        }
    }

    /// the controller address makes calls that need an authority or an asset it does not have, outside any
    /// staticcall. none may succeed.
    function probeController(uint256 r) external checked {
        uint8 a = A_PROBE_CONTROLLER;
        _att(a);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        uint256 mask = fuzz.probe(r);
        _ok(a);
        if (mask != 0) _flag(V_PROBE_OK, string.concat("controller attack calls succeeded, mask ", vm.toString(mask)));
        _failed(b0, pot0, rate0, "probeController");
    }

    /*//////////////////////////////////////////////////////////////
                                 PHASE 2
    //////////////////////////////////////////////////////////////*/

    struct XPre {
        uint256 xbal;
        uint256 balancePotPre;
        uint256 xto;
        uint256 unit;
        uint256 rate;
        uint256 actorX;
    }

    /// @dev slots of `State.balance` (the balance bid Rate instance): rateAtCheckpoint at 32, checkpointTime|lastFillTime
    /// at 33, its Anchor (lastFillRate, minuteStartRate, minuteBucket|peakTime, peakRate) at 34 to 37
    bytes32 internal constant BAL_RATE_SLOT = bytes32(uint256(32));
    bytes32 internal constant BAL_CP_SLOT = bytes32(uint256(33));
    bytes32 internal constant BAL_ANCHOR_SLOT = bytes32(uint256(34));

    /// @dev the balance bid clamp now, available as bps of par for a 100 point credit, read from the module
    function _availBps(uint256 unit) internal view returns (uint256) {
        uint256 denom = RATE_SCORE * unit;
        uint256 avail = module.available();
        uint256 cap = core.settings().balanceBidCapBps;
        if (denom == 0) return cap;
        return FullMath.mulDiv(avail, 10_000, denom).min(cap);
    }

    /// @dev available as bps of par for a 100 point credit, uncapped: the pages pot of the balance instance
    function _availBpsRaw(uint256 unit) internal view returns (uint256) {
        uint256 denom = RATE_SCORE * unit;
        return denom == 0 ? 0 : module.available() * 10_000 / denom;
    }

    /// @dev the balance instance price state as a BidModel.Bid, the clamp set to `availBps`, the pages pot to the
    /// uncapped available as bps of par, and the cap 10_000
    function _balanceBidState(uint256 availBps, uint256 unit) internal view returns (BidModel.Bid memory b) {
        uint256 cp = uint256(vm.load(address(core), BAL_CP_SLOT));
        b = BidModel.Bid({
            r: uint256(vm.load(address(core), BAL_RATE_SLOT)),
            pot: availBps,
            pagesPot: _availBpsRaw(unit),
            lastFillRate: uint256(vm.load(address(core), BAL_ANCHOR_SLOT)),
            peakRate: uint256(vm.load(address(core), bytes32(uint256(BAL_ANCHOR_SLOT) + 3))),
            peakTime: uint64(uint256(vm.load(address(core), bytes32(uint256(BAL_ANCHOR_SLOT) + 2))) >> 64),
            lastFillTime: uint64(cp >> 64),
            checkpointTime: uint64(cp),
            nowTs: block.timestamp
        });
    }

    /// @dev the exact balance token total a batch of `ids` pays, the shared model on the balance instance: the price
    /// state climbed to now (cap 10_000, clamp availBps), each credit paid score * unit * min(rate, availBps) / 10_000,
    /// the rate dropped per credit floored at 10_000 - balanceBidMarginBps
    function _balanceExpected(uint256[] memory ids, uint256 n, uint256 unit) internal view returns (uint256 total) {
        Settings memory st = core.settings();
        uint256 availBps = _availBps(unit);
        uint256 price = BidModel.priceNow(st, _balanceBidState(availBps, unit), st.balanceBidCapBps);
        uint256 floorBps = 10_000 - st.balanceBidMarginBps;
        uint256 bucket = uint64(uint256(vm.load(address(core), bytes32(uint256(BAL_ANCHOR_SLOT) + 2))));
        uint256 minuteStart = bucket == block.timestamp / core.settings().bucketSeconds
            ? uint256(vm.load(address(core), bytes32(uint256(BAL_ANCHOR_SLOT) + 1)))
            : price;
        for (uint256 i; i < n; ++i) {
            uint256 score = _scoreOf(ids[i]);
            total += score * unit * BidModel.read(st, availBps, price, st.balanceBidCapBps) / 10_000;
            minuteStart = BidModel.startAfter(st, price, minuteStart);
            price = BidModel.dropOnce(st, price, minuteStart, score, floorBps);
        }
    }

    /// @dev the ids `sellForBalance` offers: walks the actor inventory from a picked offset while the rising prices fit
    /// the module's available holding. the per credit price uses the undropped rate, an upper bound since later credits
    /// drop lower, so a picked batch never passes available
    function _pickBalanceIds(address who, uint256 len, uint256 want, uint256 pick, uint256 unit)
        internal
        view
        returns (uint256[] memory ids, uint256 n)
    {
        ids = new uint256[](want);
        uint256 avail = module.available();
        uint256 used;
        Settings memory st = core.settings();
        uint256 availBps = _availBps(unit);
        uint256 rate = BidModel.read(
            st,
            availBps,
            BidModel.priceNow(st, _balanceBidState(availBps, unit), st.balanceBidCapBps),
            st.balanceBidCapBps
        );
        // the floor rule of CoreLib._fillBalance (review ac8da10 M1): a clamped rate below the floor
        // `10_000 - balanceBidMarginBps` closes the bid with PotTooSmall. an available too short to pay the floor
        // makes no batch payable, so offer none
        if (rate < 10_000 - st.balanceBidMarginBps) return (ids, 0);
        for (uint256 k; k < len && k < want * 3 + 4 && n < want; ++k) {
            uint256 id = inventory[who][(pick % len + k) % len];
            uint256 price = _scoreOf(id) * unit * rate / 10_000;
            if (price != 0 && used + price <= avail) {
                used += price;
                ids[n++] = id;
            }
        }
    }

    /// sells credits into the balance token bid. ids are picked so the prices fit the pot. the recorded eth cost basis is
    /// the score-scaled floor rate backstop uses the fixed 100 point basis, so the bid does not call the
    /// controller
    function sellForBalance(uint256 aSeed, uint256 nSeed, uint256 pick) external checked {
        uint8 a = A_SELL_FOR_BALANCE;
        if (!phase2() || !core.settings().balanceBidOn) return _skip(a);
        address who = _actor(aSeed);
        if (_retiredRefusal(a, who, abi.encodeWithSignature("sellForBalance(uint256[])", _firstOf(who)))) return;
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        // the bid pays by the module's live unit (`_unitOf`), nonzero here. a module set to fail its unit read
        // (`module.revertUnit()`) reverts the whole bid
        uint256 unit = _unitOf();
        if (unit == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        (uint256[] memory ids, uint256 n) = _pickBalanceIds(who, len, want, pick, unit);
        if (n == 0) return _skip(a);
        assembly {
            mstore(ids, n)
        }
        XPre memory p;
        p.xbal = _xBal(address(core));
        p.balancePotPre = _xBal(address(module));
        p.unit = unit;
        p.actorX = _xBal(who);
        uint256 bound_ = _balanceExpected(ids, n, unit);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.sellForBalance(ids) {
            if (module.revertUnit()) _flag(V_MODEL, "the bid went through with a failing live unit read");
            _ok(a);
            _afterSellBalance(who, p, bound_, b0);
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "sellForBalance");
            if (module.revertUnit()) _ok(a);
            else _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /// @dev the checks after a successful `sellForBalance` (a helper so the locals fit the stack). the credit enters the
    /// one pile with an eth cost basis (the `CreditBought` event), the module pays the seller balance tokens from its holding
    function _afterSellBalance(address who, XPre memory p, uint256 bound_, uint256 b0) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 floorBps = 10_000 - core.settings().balanceBidMarginBps;
        uint256 floorSum;
        uint256 capSum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.CreditBought.selector) continue;
            uint256 cost = abi.decode(logs[i].data, (uint256));
            uint256 id = uint256(logs[i].topics[1]);
            // the recorded eth cost is the score-scaled floor rate backstop, at least 1 wei
            if (cost == 0) _flag(V_MODEL, "sellForBalance recorded a zero eth cost basis");
            uint256 par = _scoreOf(id) * p.unit;
            capSum += FullMath.mulDiv(par, core.settings().balanceBidCapBps, 10_000);
            floorSum += par * floorBps / 10_000;
            _addCredit(id, cost);
            _removeFrom(inventory[who], id);
        }
        uint256 paid = _xBal(who) - p.actorX;
        // the balance tokens paid are the rising per credit bid summed with its drops, the shared-model figure above
        if (paid != bound_) _flag(V_ABOVE_CAP, "sellForBalance paid differs from the per point bid read before");
        // Independently bound every payment by the configured floor and cap.
        if (paid < floorSum) _flag(V_MODEL, "sellForBalance paid below the floor");
        if (paid > capSum) _flag(V_ABOVE_CAP, "sellForBalance paid above configured cap");
        // the module paid the seller: its holding fell by the price, the core holds no balance token
        if (_xBal(address(core)) != p.xbal) _flag(V_POT, "sellForBalance moved the core's balance token");
        if (p.balancePotPre - _xBal(address(module)) != paid) {
            _flag(V_POT, "the module holding did not fall by the price");
        }
        _eth(b0, 0, 0, "sellForBalance");
    }

    /// the unit the core reads from the module in `redeemStatement` and `sellForBalance`: the module's `unitPerPoint()`
    /// now, 0 while the module fails the read
    function _unitOf() internal view returns (uint256 u) {
        return module.revertUnit() ? 0 : module.currentUnit();
    }

    /// the controller's eligibility answer read the way the core reads it: a revert, a short answer or a false reads as
    /// not eligible
    function _ctlAtFloor(uint256 sid) internal view returns (bool) {
        (bool ok, bytes memory out) =
            core.controller().staticcall{gas: 200_000}(abi.encodeWithSignature("atFloor(uint256)", sid));
        return ok && out.length == 32 && abi.decode(out, (bool));
    }

    struct EPre {
        uint256 xbal;
        uint256 balancePotPre;
        uint256 b0;
        uint256 pot0;
        uint256 rate0;
        uint256 toBuyback0;
        uint256 reserve0;
        uint256 rating;
        uint256 unit;
        uint256 required;
        uint256 callerBal;
        uint256 gasUsed;
        uint256 cost;
        bool ripe;
        /// the selector the call must revert with when the model says it reverts, zero when the cause is the module
        bytes4 refusal;
        Settings st;
    }

    /// redeems a held statement through the module. a statement is eligible when its asking price is at or below its
    /// cost. redemption runs only while `redeemOn` is true. the module may be set to underpay, and then the redemption
    /// must revert
    function redeemStatement(uint256 sIdx, uint256 aSeed) external checked {
        uint8 a = A_REDEEM_STATEMENT;
        if (!phase2()) return _skip(a);
        uint256[] memory held = core.heldStatements();
        if (held.length == 0) return _skip(a);
        uint256 sid = held[sIdx % held.length];
        EPre memory p;
        p.st = core.settings();
        SG storage g = _sg[sid];
        bool modeOn = p.st.redeemOn;
        bool eligible = _ctlAtFloor(sid);
        p.unit = _unitOf();
        p.ripe = modeOn && eligible;
        if (!modeOn) p.refusal = ICore.RedeemOff.selector;
        else if (!eligible) p.refusal = ICore.NotEligible.selector;
        else if (p.unit == 0) p.refusal = ICore.BadModule.selector;
        // an ineligible statement is only tried now and then, to see the refusal
        if (!p.ripe && aSeed % 6 != 0) return _skip(a);
        p.xbal = _xBal(address(core));
        p.balancePotPre = _xBal(address(module));
        p.b0 = address(core).balance;
        p.pot0 = core.ethPot();
        p.rate0 = core.ethRate();
        p.toBuyback0 = core.ethToBuyback();
        p.reserve0 = core.ethRedeemBurn();
        p.rating = core.ratingOf(sid);
        p.required = p.rating * p.unit * (10_000 - p.st.redeemSlippageBps) / 10_000;
        p.callerBal = keeper.balance;
        p.cost = g.cost;
        RS memory rs = _rs();
        _att(a);
        uint256 g0 = gasleft();
        vm.prank(keeper);
        try core.redeemStatement(sid) {
            p.gasUsed = g0 - gasleft();
            _ok(a);
            _afterRedeem(sid, p);
        } catch (bytes memory why) {
            _failed(p.b0, p.pot0, p.rate0, "redeemStatement");
            if (_ownerOf(sid) == address(0) || _ownerOf(sid) == address(module)) {
                _flag(V_DEPART, "a redemption reverted but the statement left the core");
            }
            if (p.refusal != 0 && bytes4(why) != p.refusal) {
                _unexpected(a, why);
            } else if (p.refusal == 0 && module.payBps() >= 10_000) {
                // the module overpays or pays exactly, so the required amount arrives: the redemption must not revert
                _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    function _afterRedeem(uint256 sid, EPre memory p) internal {
        if (!p.ripe) _flag(V_DEPART, "an ineligible statement redeemed");
        // the proceeds stay in the module: its holding rises by at least the required amount, the core holds no balance token
        uint256 received = _xBal(address(module)) - p.balancePotPre;
        if (received < p.required) {
            _flag(V_REDEEM_SHORT, "redemption returned less than rating * unitPerPoint less slippage");
        }
        if (p.unit == 0) _flag(V_REDEEM_SHORT, "redemption with an unreadable unit per point");
        if (_xBal(address(core)) != p.xbal) _flag(V_POT, "a redemption moved the core's balance token");
        // every redemption moves redeemBurnBps of the reserve into the coin buyback
        uint256 released = p.reserve0 * p.st.redeemBurnBps / 10_000;
        if (core.ethRedeemBurn() != p.reserve0 - released) {
            _flag(V_POT, "redeem burn reserve not reduced by redeemBurnBps");
        }
        if (core.ethToBuyback() != p.toBuyback0 + released) {
            _flag(V_POT, "the released reserve did not reach the coin buyback");
        }
        _callerPayment(V_REDEEM_SHORT, p.st, REDEEM_GAS, p.pot0, p.b0, p.callerBal, "redeemStatement");
        if (_ownerOf(sid) != address(module)) _flag(V_DEPART, "redeemed statement is not with the module");
        SG storage g = _sg[sid];
        g.status = S_REDEEMED;
        g.required = p.required;
        g.received = received;
        g.module = address(module);
    }

    /// sets the module to underpay, to fail unit reads, to change its unit, or back to normal.
    function moduleMode(uint256 s) external checked {
        uint8 a = A_MODULE_MODE;
        if (!phase2()) return _skip(a);
        _att(a);
        uint256 m = s % 8;
        if (m < 4) {
            module.setPayBps(10_000);
            module.setRevertUnit(false);
        } else if (m == 4) {
            // underpay below the slippage floor so the redemption must revert
            module.setPayBps(10_000 - (1 + (s >> 8) % 5000));
        } else if (m == 5) {
            module.setRevertUnit(true);
        } else {
            module.setUnitPerPoint(_logBound(s >> 8, 5e6, 2e7));
        }
        _ok(a);
    }
}

/// a payee whose receive reverts
contract RevertingPayee {
    receive() external payable {
        revert("no");
    }
}

/// a payee whose receive burns all the gas it is given
contract BurningPayee {
    receive() external payable {
        assembly {
            invalid()
        }
    }
}
