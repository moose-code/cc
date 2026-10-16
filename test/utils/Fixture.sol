// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {
    ICredits,
    IStatements,
    IBalanceModule,
    ICreditScore,
    Mainnet,
    Settings,
    Stack,
    Sale,
    CreditSale,
    BUYLISTING_GAS
} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2, IArtCoinsFeeEscrowV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {V2Stack} from "./V2Stack.sol";
import {Deployed} from "../../script/SystemDeployer.sol";
import {ProdDeployer} from "./ProdDeployer.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";
import {MockBalanceModule} from "../standins/MockBalanceModule.sol";
import {CreditIds} from "./CreditIds.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";
import {Prod} from "./Prod.sol";

/// @notice the full system on a mainnet fork, built only from real contracts. the artcoins v2 stack is the one of the
/// record (`V2Stack`; STACK=master selects the master stack fork, script/config/v2-master.json). the factory owner
/// (`owner`, who is also the engine owner) deploys Core and ControllerV1 through `SystemDeployer.deploySystem` and the
/// coin is launched with `deployToken`. the pool lives in
/// the live pool manager under the v2 hook. the hook pushes the fees straight to the Core: `_buyCoin` and `_sellCoin`
/// book them right after the swap (set `autoBook` false to leave the eth unbooked), `_book` does it on demand.
/// the only stand ins are the balance module and balance token, which appear only after `_enterPhase2`.
/// the sniper window is OPEN after setUp (the pool was just born). call `_skipSniperWindow` for steady state fees.
/// @dev every address is namespaced because common labels are delegated accounts on mainnet that sweep eth
abstract contract Fixture is Test, ProdDeployer {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    address internal constant DEAD = Mainnet.DEAD;

    /// @dev credits the CreditStrategy lists for sale at the pinned block. they are never handed out as plain credits
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    /// @dev the opening bid of the fixture core, wei per credit
    uint256 internal constant OPEN_RATE = 1_732_000_000_000_000;
    /// @dev balance token base units per credit reported by the stand in balance module
    /// balance token base units per stored score unit (one ten-thousandth of a point). a credit of average score (about
    /// 4.33e6 in stored units) is paid about 4.33e16 of balance token, the magnitude the per credit unit had before the
    /// per point rebuild
    uint256 internal constant UNIT = 1e10;
    /// @dev the sniper window of the launch, seconds
    uint256 internal constant SNIPER_WINDOW = 1800;
    bytes32 internal constant FIXTURE_SALT = keccak256("credits-engine fixture coin");
    /// @dev the fixture coin launches with both metadata fields set, so the launch, the preflight and the postflight
    /// rows run on non empty values
    string internal constant FIXTURE_IMAGE = "ipfs://fixture-image";
    string internal constant FIXTURE_DESCRIPTION = "fixture coin description";

    // ------------------------------------------------------------------ swap attribution hook data (same encoding on v2)

    struct PoolSwapData {
        bytes mevModuleSwapData;
        bytes poolExtensionSwapData;
    }

    struct PCAttribution {
        bytes32 sourceId;
        address referrer;
        bytes16 campaignId;
        uint24 referralBps;
    }

    struct PCSwapData {
        PCAttribution attribution;
        bytes extensionPayload;
    }

    // ------------------------------------------------------------------ the system

    /// @dev the launch config of the fixture: the default (live artcoins stack) with the placeholders filled
    LaunchConfig internal lc;
    ICore internal core;
    IArtCoinsTokenV2 internal coin;
    /// @dev the v2 stack the fixture deployed on the fork, and its factory and escrow
    V2Stack.Stack internal v2;
    IArtCoinsFactoryV2 internal FACTORY;
    IArtCoinsFeeEscrowV2 internal ESCROW;
    /// @dev when true the swap helpers book the fees right after the swap (`core.book()`)
    bool internal autoBook = true;
    IControllerV1 internal ctl;
    /// @dev the launch adapters `deploySystem` created and the Core approves
    address internal seaportAdapter;
    address internal strategyAdapter;
    address internal renderer;
    /// @dev the test adapter that prices any call (`_buyRaw`), approved by the owner in `setUp`
    address internal rawAdapter;
    PoolKey internal launchKey;
    bytes32 internal poolId;
    TestSwapRouter internal router;
    uint256 internal launchTime;

    address internal deployer;
    address internal owner;
    address internal creator;
    address internal keeper;
    address internal seller;
    address internal funder;

    uint256 internal creditCursor;

    // ------------------------------------------------------------------ the balance side

    MockBalanceToken internal xt;
    MockBalanceModule internal mod;

    // ------------------------------------------------------------------ compose

    /// @notice what one real compose did
    struct Composed {
        uint256 sid;
        uint256 supplyBefore;
        uint256[80] ids;
        /// @dev sum of the cost bases of the credits
        uint256 cost;
        uint256 potBefore;
        uint64 at;
        /// @dev gas of the whole call as the caller saw it
        uint256 gasUsed;
        /// @dev the caller payment the compose sent from `ethPot` (decision 138)
        uint256 paid;
    }

    /// @notice the format `compose()` derives for a page whose first credit id is `headId`, at the current prevrandao
    function defaultFormat(uint256 headId) internal view returns (uint8) {
        return uint8(uint256(keccak256(abi.encode(block.prevrandao, headId))) % 8);
    }

    /// @notice basefee of the compose call. low enough that the 5 percent cap does not bind
    uint256 internal composeBasefee = 0.2 gwei;
    Composed internal composed;
    bool internal isComposed;
    /// @notice state right before the compose, valid while `isComposed`. revert to it to compose again
    uint256 internal preComposeSnap;

    /// @notice the settings the fixture core is deployed with. the default is the launch values of docs/DECISIONS.md. a
    /// suite that tests another set overrides this
    function _settings() internal view virtual returns (Settings memory) {
        Settings memory cfg = Mainnet.defaultSettings();
        // General fixtures exercise their own promises; budget tests retain launch enforcement explicitly.
        cfg.spendCapBps = 10_000;
        return cfg;
    }

    /// @dev the gas of the last external call as a transaction, before the refund, and the refund. forge reports the call
    /// net of the refund (up to 20 percent of the gross, EIP-3529), the Core meters the gross with `gasleft`. decoded by
    /// position, so a forge-std struct with more fields than the installed forge answers does not matter
    function _lastCallGross() internal view returns (uint256 gross, uint256 refunded) {
        (bool ok, bytes memory out) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok, "lastCallGas");
        uint256 net;
        int256 refund;
        (, net,, refund) = abi.decode(out, (uint256, uint256, uint256, int256));
        refunded = refund < 0 ? 0 : uint256(refund);
        gross = net + refunded;
    }

    /// @dev the most one `buyListing` can pay at the base fee now, before the cap at the bid less the cost
    function _maxListingPay() internal view returns (uint256) {
        Settings memory s = core.settings();
        uint256 rate = block.basefee < s.keeperMaxBaseFee ? block.basefee : s.keeperMaxBaseFee;
        return BUYLISTING_GAS * rate + s.keeperFee;
    }

    /// @dev checks the payment of one `buyListing` against the rule: at most the bid less the cost (`gap`), at most the
    /// largest payment of the base fee now, and, below the gap, the keeper fee plus whole gas units at the base fee
    function _assertListingPay(uint256 paid, uint256 gap) internal view {
        assertLe(paid, gap, "the payment stays inside the bid");
        assertLe(paid, _maxListingPay(), "the payment stays inside the gas cap");
        if (paid == gap) return;
        Settings memory s = core.settings();
        uint256 rate = block.basefee < s.keeperMaxBaseFee ? block.basefee : s.keeperMaxBaseFee;
        assertGe(paid, s.keeperFee, "the keeper fee is paid whole");
        if (rate == 0) assertEq(paid, s.keeperFee, "no base fee, the keeper fee alone");
        else assertEq((paid - s.keeperFee) % rate, 0, "whole gas units at the base fee");
    }

    /// @dev the test contract is a caller of the doors that pay eth to their caller (the compose and redeem caller payment, the buyListing and buyback payments), so it takes eth
    receive() external payable {}

    function setUp() public virtual {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        else vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        // the v2 stack of the record (STACK=master selects the master stack fork). its factory owner is the owner of
        // the engine in every test
        v2 = V2Stack.attach();
        owner = v2.owner;
        deployer = _user("deployer");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        router = new TestSwapRouter();

        FACTORY = IArtCoinsFactoryV2(v2.factory);
        ESCROW = IArtCoinsFeeEscrowV2(v2.escrow);
        vm.deal(owner, 1 ether);

        lc = defaultConfig();
        // the core tests are written against this opening bid, whatever the launch default is
        lc.rateStart = OPEN_RATE;
        lc.settings = _settings();
        lc.owner = owner;
        lc.creator = creator;
        lc.artist = creator;
        // the core tests compose right after the fill, so they start with the credit sale window off. the launch value is
        // on (test/Config.t.sol pins it) and the sale tests switch it on
        lc.credit.saleOn = false;
        lc.payee = _user("payee");
        lc.name = "Fixture Coin";
        lc.symbol = "FIXT";
        lc.image = FIXTURE_IMAGE;
        lc.description = FIXTURE_DESCRIPTION;
        lc.salt = FIXTURE_SALT;
        lc.stack.hook = v2.hook;
        lc.stack.factory = v2.factory;
        lc.stack.locker = v2.locker;
        lc.stack.escrow = v2.escrow;
        lc.mevModule = v2.mev;
        vm.startPrank(owner);
        Deployed memory d = deploySystem(owner, lc);
        vm.stopPrank();

        core = ICore(payable(d.core));
        coin = IArtCoinsTokenV2(d.coin);
        ctl = IControllerV1(d.controller);
        seaportAdapter = d.seaportAdapter;
        strategyAdapter = d.strategyAdapter;
        renderer = d.renderer;
        // placed with `etch` at a fixed address, so the creation nonces of the test contract stay as the suites expect
        rawAdapter = _user("rawAdapter");
        vm.etch(rawAdapter, vm.getDeployedCode("RawListingAdapter.sol:RawListingAdapter"));
        vm.prank(owner);
        core.addAdapter(rawAdapter);
        launchKey = d.launchKey;
        poolId = d.poolId;
        launchTime = block.timestamp;
    }

    // ------------------------------------------------------------------ builders on the fixture config

    function _cfg(string memory name, string memory symbol, bytes32 salt) private view returns (LaunchConfig memory l) {
        l = lc;
        l.name = name;
        l.symbol = symbol;
        l.salt = salt;
    }

    function predictCoin(address tokenAdmin, string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (address)
    {
        LaunchConfig memory l = _cfg(name, symbol, salt);
        l.owner = tokenAdmin;
        return predictCoin(l, owner, address(core));
    }

    function buildConfig(address tokenAdmin, address creator_, string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory)
    {
        LaunchConfig memory l = _cfg(name, symbol, salt);
        l.creator = creator_;
        return buildConfig(l, tokenAdmin, address(core));
    }

    /// @notice a Core built as `deploySystem` builds it, on the stack `st`: the Core is the bounty recipient of its own
    /// config, so its `COIN` is the factory prediction for that config and not the fixture coin
    function _launchCore(address controller_, Stack memory st, uint256 rate, Settings memory s)
        internal
        returns (ICore)
    {
        return Prod.newCore(owner, buildConfig(lc, owner, address(0)), owner, controller_, lc.payee, st, rate, s);
    }

    /// @notice a successor Core of the fixture coin: it is bound to the launched coin, the bounty recipient of the pool
    /// stays where it is until the coin admin repoints it
    function _successorCore(address controller_, uint256 rate, Settings memory s) internal returns (ICore) {
        return Prod.newCoreOf(
            address(coin), owner, buildConfig(lc, owner, address(0)), controller_, lc.payee, lc.stack, rate, s
        );
    }

    function poolKeyOf(address coin_) internal view returns (PoolKey memory) {
        return poolKeyOf(coin_, lc.stack);
    }

    /// @notice a namespaced account with no code
    function _user(string memory label) internal returns (address a) {
        a = makeAddr(string.concat("lifecycle.", label, ".4b1d"));
        assertEq(a.code.length, 0, "account has code on the fork");
    }

    // ------------------------------------------------------------------ swaps through the real pool

    /// @notice buys coin with `ethIn` eth, exact in, through the real pool. `who` is funded for it
    /// @return coinOut the coin `who` received
    function _buyCoin(address who, uint256 ethIn) internal returns (uint256 coinOut) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        router.swap{value: ethIn}(launchKey, true, -int256(ethIn), who);
        coinOut = coin.balanceOf(who) - before;
        if (autoBook) _book();
    }

    /// @notice sells `coinIn` coin for eth, exact in, through the real pool
    /// @return ethOut the eth `who` received after the skim
    function _sellCoin(address who, uint256 coinIn) internal returns (uint256 ethOut) {
        vm.prank(who);
        coin.approve(address(router), type(uint256).max);
        uint256 before = who.balance;
        vm.prank(who);
        router.swap(launchKey, false, -int256(coinIn), who);
        ethOut = who.balance - before;
        if (autoBook) _book();
    }

    /// @notice books the fee income the pool pushed into the Core
    function _book() internal {
        core.book();
    }

    /// @notice swap hook data that names `referrer` and asks for `bps` of volume (100k denominator)
    function _referralData(address referrer, uint24 bps) internal pure returns (bytes memory) {
        PCSwapData memory inner = PCSwapData(PCAttribution(bytes32(0), referrer, bytes16(0), bps), "");
        return abi.encode(PoolSwapData("", abi.encode(inner)));
    }

    /// @notice moves past the anti sniper window, so skim is the 10 points baseline
    function _skipSniperWindow() internal {
        uint256 end = launchTime + SNIPER_WINDOW + 1;
        if (block.timestamp < end) vm.warp(end);
    }

    /// @notice moves past the sniper window. the first book with income after it turns the payee share on
    function _skipToPayeeStart() internal {
        _skipSniperWindow();
    }

    /// @notice generates fees through real buys until the eth pot holds at least `eth`. in steady state about 5.90 percent
    /// of every buy reaches the pot (6.9 points of skim, 96.38 percent to the Core, minus the payee), inside
    /// the sniper window more
    function _fundPot(uint256 eth) internal {
        // about 5.31 percent of a buy reaches the pot now (5.90 points to the engine, less the 10 percent redeem burn
        // share); the estimate undershoots so each iteration overshoots the gap
        for (uint256 i; i < 16 && core.ethPot() < eth; ++i) {
            uint256 need = eth - core.ethPot();
            _buyCoin(funder, need * 10_000 / 460 + 1000);
        }
        assertGe(core.ethPot(), eth, "pot not funded");
    }

    // ------------------------------------------------------------------ credits

    /// @notice moves `n` real credits from the CreditStrategy to `to` and approves the core for them
    /// @return ids the credit ids
    function _credits(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(creditCursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            vm.prank(STRATEGY);
            CREDITS.transferFrom(STRATEGY, to, id);
            ids[got++] = id;
        }
        vm.prank(to);
        CREDITS.setApprovalForAll(address(core), true);
    }

    /// @notice warps an hour at a time until the ceiling of credit `id` reaches `price`. the real listings cost more
    /// than the launch `rateCap` allows the bid to reach, so the owner lifts the cap to its bound first
    /// warps until the eth bid for credit `id` (`bidOf`, the rate scaled by its score over refScore) covers `price`
    function _warpUntilCeiling(uint256 id, uint256 price) internal {
        _liftRateCap();
        for (uint256 i; i < 400; ++i) {
            if (core.bidOf(id) >= price) return;
            vm.warp(block.timestamp + 1 hours);
        }
        revert("ceiling never cleared");
    }

    /// @notice the smallest pot at which the clamp of the eth rate is not below the stored rate:
    /// the stored rate
    function _unclampedPot() internal view returns (uint256) {
        return core.rateAtCheckpoint();
    }

    /// @notice fills the eth pile with `n` fresh credits in the order returned, funding the pot first when needed. each
    /// credit is sold with `refScore` set to its own score, so score / refScore is 1 and it is recorded at the full
    /// rate; `refScore` is restored after. this gives the compose and sale tests a flat per-credit cost basis. the tests
    /// of the per-point payout and the scaled drop are test/PerPoint.t.sol, test/PerPointExact.t.sol and the invariants
    function _fillEthPile(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        // a price state that idle time loosened above the opening rate is restated to the opening rate
        uint256 opening = core.RATE_START();
        if (core.rateAtCheckpoint() > opening) {
            vm.prank(owner);
            core.setRate(opening);
        }
        uint256 room = _unclampedPot();
        if (core.ethPot() < room) _fundPot(room);
        uint256 total = core.ethRate() * n;
        if (core.ethPot() < total * 6) _fundPot(total * 6);
        uint32 savedRef = core.settings().refScore;
        for (uint256 i; i < n; ++i) {
            _refScoreToCredit(ids[i]);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
        if (core.settings().refScore != savedRef) _setRefScore(savedRef);
    }

    /// @notice composes the eth pile through the real controller, once per state lineage. fills the pile to 80
    /// first. the call checks that the core hands Statements the 80 oldest credits with the format `compose()` derives from
    /// `prevrandao` and the first page id. the state before the
    /// compose is kept in `preComposeSnap`, so a test can revert to it and compose again under other conditions
    function _composeOnce() internal returns (Composed memory c) {
        if (isComposed) return composed;
        uint256 size = core.pileSize();
        if (size < 80) _fillEthPile(80 - size);

        uint256[] memory page = core.pilePage(0, 80);
        for (uint256 i; i < 80; ++i) {
            c.ids[i] = page[i];
            (, uint256 cost,) = core.creditInfo(page[i]);
            c.cost += cost;
        }
        c.potBefore = core.ethPot();
        c.supplyBefore = STATEMENTS.supply();
        vm.fee(composeBasefee);
        preComposeSnap = vm.snapshotState();

        vm.expectCall(
            address(STATEMENTS), abi.encodeWithSelector(IStatements.compose.selector, c.ids, defaultFormat(c.ids[0]))
        );
        uint256 keeperBefore = keeper.balance;
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        core.compose();
        c.gasUsed = gasBefore - gasleft();
        c.paid = keeper.balance - keeperBefore;
        c.sid = c.supplyBefore + 1;
        c.at = uint64(block.timestamp);

        composed = c;
        isComposed = true;
    }

    // ------------------------------------------------------------------ statement sales through the controller

    /// @notice the core holds statement `sid` (its record exists)
    function _isHeld(uint256 sid) internal view returns (bool held) {
        (held,,) = core.statementInfo(sid);
    }

    /// @notice `who` buys statement `sid` through the controller at the asking price of this block. `who` is funded
    /// for it. returns the price paid
    function _buy(address who, uint256 sid) internal returns (uint256 price) {
        price = ctl.priceOf(sid);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        ctl.buy{value: price}(sid);
    }

    /// @notice the owner lifts `rateCap` to its upper bound, for suites that climb past the launch cap
    function _liftRateCap() internal {
        Settings memory s = core.settings();
        if (s.rateCap < 1e18) {
            s.rateCap = 1e18;
            _setSettings(s);
        }
    }

    /// first slot of `State.anchor` in the Core (four words)
    bytes32 internal constant ANCHOR_SLOT = bytes32(uint256(28));

    /// @notice the bid anchor state of the Core, read from its storage: the rate of the last fill, the rate of the first fill
    /// in the current minute bucket and that bucket
    function _anchor() internal view returns (uint256 lastFillRate, uint256 minuteStartRate, uint256 minuteBucket) {
        bytes32 slot = ANCHOR_SLOT;
        lastFillRate = uint256(vm.load(address(core), slot));
        minuteStartRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
        minuteBucket = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))));
    }

    /// @notice the remembered peak state of the Core, read from its storage: `peakRate` and `peakTime` (peakTime is the
    /// high 64 bits of the word that holds the minute bucket)
    function _peak() internal view returns (uint256 peakRate, uint256 peakTime) {
        bytes32 slot = ANCHOR_SLOT;
        peakTime = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))) >> 64);
        peakRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 3)));
    }

    /// @notice the eth spent in the swap and the eth paid to the caller, from the `Buyback` event of `logs`
    function _buybackEvent(Vm.Log[] memory logs) internal view returns (uint256 spent, uint256 paid) {
        bytes32 sig = ICore.Buyback.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == sig) {
                (spent, paid) = abi.decode(logs[i].data, (uint256, uint256));
                return (spent, paid);
            }
        }
        revert("no Buyback event");
    }

    /// @notice the owner changes the settings
    function _setSettings(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    /// @notice the sale settings of the controller as a struct
    function _sale() internal view returns (Sale memory s) {
        s = Sale({
            markupBps: ctl.markupBps(),
            startCapBps: ctl.startCapBps(),
            decayHours: ctl.decayHours(),
            anchorHalfLife: ctl.anchorHalfLife(),
            anchorMinCost: ctl.anchorMinCost(),
            anchorMoveBps: ctl.anchorMoveBps()
        });
    }

    /// @notice the credit sale and rating reference settings of the controller as a struct
    function _creditSale() internal view returns (CreditSale memory c) {
        c = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            floorBps: ctl.creditFloorBps(),
            startBps: ctl.creditStartBps()
        });
    }

    /// @notice the owner sets the Core setting `refScore` through `setSettings`, the other settings unchanged
    function _setRefScore(uint32 v) internal {
        Settings memory s = core.settings();
        s.refScore = v;
        _setSettings(s);
    }

    /// @notice the owner sets the Core setting `swapFeeCc` through `setSettings`, the other settings unchanged
    function _setSwapFeeCc(uint96 v) internal {
        Settings memory s = core.settings();
        s.swapFeeCc = v;
        _setSettings(s);
    }

    /// @notice the score of credit `id` from the CreditScore contract, the per-credit source every eth door reads
    function _scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// @notice sets `refScore` to credit `id`'s score, so the eth bid pays the full rate for it (score / refScore is 1).
    /// isolates the rate mechanics from the per-point scaling, which the invariants and the dedicated per-point tests cover
    function _refScoreToCredit(uint256 id) internal {
        _setRefScore(uint32(_scoreOf(id)));
    }

    /// @notice the owner turns the credit sale window on or off through `setCredit`, the other credit settings unchanged
    function _setCreditSaleOn(bool on) internal {
        CreditSale memory c = _creditSale();
        c.saleOn = on;
        vm.prank(owner);
        ctl.setCredit(c);
    }

    /// @notice the owner sets the artist cut recipient through `Core.setArtist`
    function _setArtist(address v) internal {
        vm.prank(owner);
        core.setArtist(v);
    }

    /// @notice the owner sets `anchorMinCost` through `setSale`, the other sale settings unchanged
    function _setAnchorMinCost(uint128 v) internal {
        Sale memory s = _sale();
        s.anchorMinCost = v;
        vm.prank(owner);
        ctl.setSale(s);
    }

    /// @notice composes and buys the statement with `buyer` at the asking price. the buyer now holds the statement and
    /// the proceeds are booked
    function _sellStatement(address buyer) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        price = _buy(buyer, sid);
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice the `unitPerPoint()` the module set on the core reports now
    function _moduleUnit() internal view returns (uint256) {
        return IBalanceModule(core.balanceModule()).unitPerPoint();
    }

    /// @notice the owner sets the controller at once
    function _setController(address c) internal {
        vm.prank(owner);
        core.setController(c);
    }

    /// @notice the owner sets the balance module at once
    function _setBalanceModule(address m) internal {
        vm.prank(owner);
        core.setBalanceModule(m);
    }

    /// @notice the owner sets the two balance side switches
    function _setSwitches(bool redeemOn, bool balanceBidOn) internal {
        Settings memory s = core.settings();
        s.redeemOn = redeemOn;
        s.balanceBidOn = balanceBidOn;
        _setSettings(s);
    }

    /// @notice the `params` the test adapter turns into the call of `target` with `value` and `data`
    function _raw(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(target, value, data);
    }

    /// @notice `buyListing` through the test adapter: the Core calls `target` with `value` and `data`
    function _buyRaw(uint256 value, bytes memory data, uint256 id, address target) internal {
        core.buyListing(rawAdapter, id, _raw(target, value, data));
    }

    /// @notice the owner approves a listing adapter
    function _approveAdapter(address adapter) internal {
        vm.prank(owner);
        core.addAdapter(adapter);
    }

    // ------------------------------------------------------------------ the balance side

    /// @notice sets the stand in balance module and balance token and turns both balance side switches on, so redemptions and the
    /// balance token bid both run. the module holds the balance token (the Core holds none): it is funded a launch
    /// allocation, and redemptions mint their proceeds into it
    function _enterPhase2() internal {
        xt = new MockBalanceToken("Balance Token", "XT");
        mod = new MockBalanceModule(address(xt), UNIT);
        xt.mint(address(mod), 1e24);
        _setBalanceModule(address(mod));
        _setSwitches(true, true);
    }

    /// @notice the balance token the module holds, the pot of the balance bid (`available()` of the stand in)
    function _moduleHolding() internal view returns (uint256) {
        return xt.balanceOf(address(mod));
    }

    /// @notice initializes a native eth / balance token uniswap v4 pool and points the controller at it, so the balance bid
    /// can price its eth cost basis (decision 92). the pool sqrt price makes the balance token cheap in eth, so the
    /// decision 87 value floor is far below the sale curve and the balance bid's eth cost basis is the eth market bid.
    /// a suite that needs the value floor to bind sets its own pool price. needs the balance side (the balance token set)
    function _setBalancePool() internal {
        _setBalancePoolFor(address(xt));
    }

    /// @notice the same for an arbitrary balance token (a suite that sets a non default balance token on the core)
    function _setBalancePoolFor(address token) internal {
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(vk, uint160((uint256(1) << 96) * 1000));
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
    }

    /// @notice warps until the controller's curve price of a statement has reached its floor, which makes it eligible
    /// for redemption. the launch curve falls from 150 percent to 100 percent of the reference over 50 hours
    function _makeEligible(uint256 sid) internal {
        for (uint256 i; i < 400 && !ctl.atFloor(sid); ++i) {
            vm.warp(block.timestamp + 1 hours);
        }
    }

    /// @notice composes the eth pile, makes the statement eligible and redeems it, which mints the balance token into
    /// the module. needs the balance side. returns the balance token the module received
    function _fillBalanceBuyback() internal returns (uint256 received) {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        uint256 before = _moduleHolding();
        core.redeemStatement(c.sid);
        received = _moduleHolding() - before;
    }

    // ------------------------------------------------------------------ checks and small helpers

    /// @notice adds `amount` to the eth pot whole through `fund`. the fee income above the pots is booked first
    function _addToPot(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        core.fund{value: amount}();
    }

    /// @notice the eth the core tracks: the pots and the redeem burn reserve (the payee share is pushed, not held)
    function _tracked() internal view returns (uint256) {
        return core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn();
    }

    /// @notice invariant 5 of the spec: the eth pots never exceed what the core holds. the balance token is held by the
    /// module, not the core, so there is no balance pot to check
    function _solvent() internal view {
        assertLe(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), address(core).balance, "eth pots exceed balance"
        );
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }
}
