// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Lane, ICredits, IStatements, Mainnet, Settings, BUYLISTING_GAS} from "../../src/interfaces/Interfaces.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";
import {ICoreLens} from "../../src/interfaces/ICoreLens.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsTokenV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsHookV2
} from "../../src/interfaces/ArtCoinsV2.sol";
import {V2Stack} from "./V2Stack.sol";
import {Deployed} from "../../script/SystemDeployer.sol";
import {ProdDeployer} from "./ProdDeployer.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {CreditIds} from "./CreditIds.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";
import {RateStore} from "../../src/lib/RateStore.sol";

/// @notice the full system on a mainnet fork, built only from real contracts. the artcoins v2 stack is the live one
/// (`V2Stack`, script/config/v2-mainnet.json), the factory owner (`owner`, who is also the engine owner) sets the
/// factory minimum protocol skim share to 362 as the launch needs, then Core, ControllerV1 and the fee router are
/// deployed through `SystemDeployer.deploySystem` and the coin is launched with `deployTokenAsOwner`. the pool lives in
/// the live pool manager under the v2 hook. fees reach the Core through the fee router: `_buyCoin` and `_sellCoin`
/// flush it right after the swap (set `autoFlush` false to hold the eth in the router), `_flush` does it on demand.
/// the only stand ins are the exit module and exit token, which appear only after `_enterPhase2`.
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
    /// @dev exit token base units per credit reported by the stand in exit module
    uint256 internal constant UNIT = 43_300_000_000_000_000;
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
    /// @dev the fee router: the pool's bounty recipient. `_flush` forwards its eth to the Core
    IFeeRouter internal feeRouter;
    /// @dev the account that calls `flush` in the helpers
    address internal flusher;
    /// @dev when true the swap helpers flush the router right after the swap, so the Core books the fees at once
    bool internal autoFlush = true;
    IControllerV1 internal ctl;
    /// @dev the read only lens `deploySystem` created for the Core
    ICoreLens internal lens;
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

    // ------------------------------------------------------------------ phase 2

    MockExitToken internal xt;
    MockExitModule internal mod;

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
    }

    /// @notice basefee of the compose call. low enough that the 5 percent cap does not bind
    uint256 internal composeBasefee = 0.2 gwei;
    Composed internal composed;
    bool internal isComposed;
    /// @notice state right before the compose, valid while `isComposed`. revert to it to compose again
    uint256 internal preComposeSnap;

    /// @notice the settings the fixture core is deployed with. the default is the launch values of docs/FLOW.md. a
    /// suite that tests another set overrides this
    function _settings() internal view virtual returns (Settings memory) {
        return Mainnet.defaultSettings();
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

    /// @dev the test contract is a caller of the doors that pay eth to their caller (the compose and exit caller payment, the buyListing and buyback payments), so it takes eth
    receive() external payable {}

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // the live v2 stack. its factory owner is the owner of the engine in every test
        v2 = V2Stack.attach();
        owner = v2.owner;
        deployer = _user("deployer");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        flusher = _user("flusher");
        router = new TestSwapRouter();

        // the launch bounty needs the factory minimum protocol skim share at 362: the owner command of docs/DEPLOY.md step 3
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        ESCROW = IArtCoinsFeeEscrowV2(v2.escrow);
        vm.startPrank(owner);
        FACTORY.setMinProtocolSkimShareBps(362);
        vm.stopPrank();
        vm.deal(owner, 1 ether);

        lc = defaultConfig();
        // the core tests are written against this opening bid, whatever the launch default is
        lc.rateStart = OPEN_RATE;
        lc.settings = _settings();
        lc.owner = owner;
        lc.creator = creator;
        lc.creatorPayee = _user("creatorPayee");
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
        // the launch is mined in this block: the split starts when the anti sniper window ends
        startSplitAfterLaunch(lc, d.router, d.coin);
        vm.stopPrank();

        // `deploySystem` filled the router into its own copy of the config
        lc.stack.feeSource = d.router;
        core = ICore(payable(d.core));
        coin = IArtCoinsTokenV2(d.coin);
        ctl = IControllerV1(d.controller);
        lens = ICoreLens(d.lens);
        feeRouter = IFeeRouter(payable(d.router));
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
        return predictCoin(l, owner, address(feeRouter));
    }

    function buildConfig(
        address tokenAdmin,
        address creator_,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory) {
        LaunchConfig memory l = _cfg(name, symbol, salt);
        l.creator = creator_;
        return buildConfig(l, tokenAdmin, address(feeRouter));
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
        if (autoFlush) _flush();
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
        if (autoFlush) _flush();
    }

    /// @notice flushes the fee router as `flusher`. the Core books what the router sends.
    /// returns the eth the Core received from the router (zero when the router held nothing)
    function _flush() internal returns (uint256 toCore) {
        uint256 before = address(core).balance;
        vm.prank(flusher);
        feeRouter.flush();
        toCore = address(core).balance - before;
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

    /// @notice moves past the sniper window and the router split start (the window end plus the deploy margin). the first
    /// flush at or after the start turns the split on
    function _skipToSplitStart() internal {
        _skipSniperWindow();
        uint256 at = feeRouter.splitStart();
        if (block.timestamp < at) vm.warp(at);
    }

    /// @notice generates fees through real buys until the eth pot holds at least `eth`. in steady state about 5.90 percent
    /// of every buy reaches the pot (6.9 points of skim, 96.38 percent to the router, minus the payee), inside
    /// the sniper window more
    function _fundPot(uint256 eth) internal {
        for (uint256 i; i < 8 && core.ethPot() < eth; ++i) {
            uint256 need = eth - core.ethPot();
            _buyCoin(funder, need * 10_000 / 510 + 1000);
        }
        assertGe(core.ethPot(), eth, "pot not funded");
    }

    /// @notice like `_fundPot` but never buys more than the gap needs (the guess is the first flush rate, the highest one),
    /// so the pot lands just over `eth`. for tests that need a pot close to an exact figure
    function _fundPotNear(uint256 eth) internal {
        for (uint256 i; i < 12 && core.ethPot() < eth; ++i) {
            _buyCoin(funder, (eth - core.ethPot()) * 10_000 / 665 + 1e12);
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
    function _warpUntilCeiling(uint256 id, uint256 price) internal {
        _liftRateCap();
        for (uint256 i; i < 400; ++i) {
            if (core.ethRate() >= price) return;
            vm.warp(block.timestamp + 1 hours);
        }
        revert("ceiling never cleared");
    }

    /// @notice the smallest pot at which the clamp of the eth rate is not below the stored rate:
    /// the stored rate
    function _unclampedPot() internal view returns (uint256) {
        return core.rateAtCheckpoint();
    }

    /// @notice sells `n` fresh credits into the eth bid, which puts them in the eth pile in the order returned.
    /// funds the pot first when it cannot carry the sale
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
        vm.prank(seller);
        core.sellForEth(ids);
    }

    /// @notice composes the eth pile through the real controller, once per state lineage. fills the pile to 80
    /// first. the call checks that the core hands Statements the 80 oldest credits with format 0. the state before the
    /// compose is kept in `preComposeSnap`, so a test can revert to it and compose again under other conditions
    function _composeOnce() internal returns (Composed memory c) {
        if (isComposed) return composed;
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);

        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        for (uint256 i; i < 80; ++i) {
            c.ids[i] = page[i];
            (,, uint256 cost,) = core.creditInfo(page[i]);
            c.cost += cost;
        }
        c.potBefore = core.ethPot();
        c.supplyBefore = STATEMENTS.supply();
        vm.fee(composeBasefee);
        preComposeSnap = vm.snapshotState();

        vm.expectCall(address(STATEMENTS), abi.encodeWithSelector(IStatements.compose.selector, c.ids, uint8(0)));
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        core.compose();
        c.gasUsed = gasBefore - gasleft();
        c.sid = c.supplyBefore + 1;
        c.at = uint64(block.timestamp);

        composed = c;
        isComposed = true;
    }

    // ------------------------------------------------------------------ statement sales through the controller

    /// @notice the core holds statement `sid` (its record exists)
    function _isHeld(uint256 sid) internal view returns (bool held) {
        (held,,,) = core.statementInfo(sid);
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

    /// @notice the bid anchor state of the Core, read from its storage: the rate of the last fill, the rate of the first fill
    /// in the current minute bucket and that bucket
    function _anchor() internal view returns (uint256 lastFillRate, uint256 minuteStartRate, uint256 minuteBucket) {
        bytes32 slot = RateStore.SLOT;
        lastFillRate = uint256(vm.load(address(core), slot));
        minuteStartRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
        minuteBucket = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))));
    }

    /// @notice the remembered peak state of the Core, read from its storage: `peakRate` and `peakTime` (peakTime is the
    /// high 64 bits of the word that holds the minute bucket)
    function _peak() internal view returns (uint256 peakRate, uint256 peakTime) {
        bytes32 slot = RateStore.SLOT;
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

    /// @notice composes and buys the statement with `buyer` at the asking price. the buyer now holds the statement and
    /// the proceeds are booked
    function _sellStatement(address buyer) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        price = _buy(buyer, sid);
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice the owner sets the controller at once
    function _setController(address c) internal {
        vm.prank(owner);
        core.setController(c);
    }

    /// @notice the owner sets the exit module at once
    function _setExitModule(address m) internal {
        vm.prank(owner);
        core.setExitModule(m);
    }

    /// @notice adds a target to the core allowlist
    function _allow(address target) internal {
        vm.prank(owner);
        core.addTarget(target);
    }

    // ------------------------------------------------------------------ phase 2

    /// @notice sets the stand in exit module and exit token at once. there is no exit pool: the coin
    /// buyback of the exit token is a dutch auction inside the core
    function _enterPhase2() internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        _setExitModule(address(mod));
    }

    /// @notice composes the eth pile, waits `exitAfter` and exits the statement, which puts half of the
    /// exit token into `xToBuyback`. needs phase 2. returns the exit token the core received
    function _fillExitBuyback() internal returns (uint256 received) {
        Composed memory c = _composeOnce();
        vm.warp(block.timestamp + core.settings().exitAfter);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(c.sid);
        received = xt.balanceOf(address(core)) - before;
    }

    // ------------------------------------------------------------------ checks and small helpers

    /// @notice invariant 5 of the spec: the pots never exceed what the core holds
    function _solvent() internal view {
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots exceed balance");
        address t = core.exitToken();
        if (t != address(0)) {
            assertLe(core.xPot() + core.xToBuyback(), MockExitToken(t).balanceOf(address(core)), "exit pots exceed");
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    /// @dev sets the exit rate as the stored word with the checkpoint time at now and the funded flag its definition
    /// gives (slots 12 and 13 of the Core, test/CoreLayout.t.sol pins them)
    function _storeXRate(uint256 rate) internal {
        uint256 w = uint256(vm.load(address(core), bytes32(uint256(13))));
        w = (w & ~uint256(type(uint64).max)) | block.timestamp;
        uint256 unit = core.unitPerCredit();
        bool funded = unit != 0 && core.xPot() * 1e4 >= rate * unit;
        w = funded ? w | (uint256(1) << 64) : w & ~(uint256(0xff) << 64);
        vm.store(address(core), bytes32(uint256(12)), bytes32(rate));
        vm.store(address(core), bytes32(uint256(13)), bytes32(w));
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }
}
