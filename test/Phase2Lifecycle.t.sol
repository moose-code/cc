// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Settings, Quote, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Phase2Deploy} from "../script/Phase2Deploy.s.sol";
import {PushSplitCreator} from "../script/PushSplit.sol";
import {Phase2Wire} from "../script/Phase2Wire.s.sol";
import {Phase2Claims} from "../script/Phase2Claims.s.sol";
import {Phase2SettingsProbe, Phase2ReadbackProbe} from "./Phase2Scripts.t.sol";
import {Phase2WireProbe} from "./Phase2Wire.t.sol";
import {Phase2ClaimsProbe} from "./Phase2ClaimsScripts.t.sol";
import {SetSettingsProbe} from "./SetSettings.t.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface ILifecycleCore {
    function MANAGER() external view returns (address);
    function COIN() external view returns (address);
    function HOOK() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
    function creditCostToPotBps() external view returns (uint16);
}

interface ILifecycleCoin {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ILifecycleToken {
    function balanceOf(address) external view returns (uint256);
    function transfersOpenBlock() external view returns (uint256);
}

interface ILifecycleCredits {
    function setApprovalForAll(address operator, bool approved) external;
    function ownerOf(uint256 id) external view returns (address);
}

interface ILifecycleV2 {
    function buyCredit(uint256 id) external payable;
    function creditPrice(uint256 id) external view returns (uint256);
    function pastWindow(uint64 acquiredAt) external view returns (bool);
    function refreshReference() external returns (bool);
}

contract LifecycleDeployProbe is Phase2Deploy {
    function deploy(Inputs memory i) external returns (Result memory) {
        return deployPhase2(i, false);
    }
}

/// the whole ladder against the live Core and the live BALANCE token on a fork of the current head, with the real
/// scripts in their production order: stage A (deploy), stage B (module, controller, settings with the split), the
/// launch state, the readback, a real Statement conversion with the 10 percent earmark, then stage D (claims
/// allocated, redemption enabled, a real holder's burn, redemption disabled). runs only with LIVE_BALANCE_TOKEN set
contract Phase2LifecycleTest is Test {
    using StateLibrary for IPoolManager;

    /// the live hookless eth / BALANCE pool with liquidity at the head (fee 35,000, spacing 350), one of several
    /// opened in the token's first hour; the owner picks the stage C pool from the readback of the live pools
    uint24 internal constant POOL_FEE = 35_000;
    int24 internal constant POOL_TICK_SPACING = 350;
    SetSettingsProbe internal setSettings;
    address internal constant CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    ICore internal core = ICore(payable(CORE));
    address internal token;
    address internal owner;
    LifecycleDeployProbe internal deployer;
    Phase2WireProbe internal wire;
    Phase2SettingsProbe internal settings;
    Phase2ReadbackProbe internal readback;
    Phase2ClaimsProbe internal claims;
    TestSwapRouter internal router;

    /// the live BALANCE token, defaulted to the mainnet address; `LIVE_BALANCE_TOKEN` overrides it. no skip: a missing
    /// MAINNET_RPC_URL fails the run (vm.envString reverts), it is never silently skipped
    address internal constant LIVE_BALANCE_TOKEN = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    /// the pinned fork block, overridable by `LIVE_FORK_BLOCK`. pinned reads are cached on disk and shared; a head fork
    /// refetches every run and is never used. re-pinned to a recent block before each owner send
    uint256 internal constant LIVE_FORK_BLOCK = 26242107;

    function setUp() public {
        token = vm.envOr("LIVE_BALANCE_TOKEN", LIVE_BALANCE_TOKEN);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("LIVE_FORK_BLOCK", LIVE_FORK_BLOCK));
        owner = core.owner();
        deployer = new LifecycleDeployProbe();
        wire = new Phase2WireProbe();
        settings = new Phase2SettingsProbe();
        settings.configure(CORE);
        readback = new Phase2ReadbackProbe();
        claims = new Phase2ClaimsProbe();
        router = new TestSwapRouter();
        setSettings = new SetSettingsProbe();
        setSettings.configure(CORE, "");
    }

    function _wireInputs(address treasury, address controllerV2, string memory step)
        internal
        pure
        returns (Phase2Wire.Inputs memory i)
    {
        i.core = CORE;
        i.treasury = treasury;
        i.controllerV2 = controllerV2;
        i.step = step;
    }

    IPhase2BalanceTreasury internal t;
    IControllerV2 internal c2;
    address internal split;
    uint256 internal received;

    // promise: decisions 254 to 260 the production ladder runs end to end on the live Core with the live BALANCE token: stage A creates the four contracts with the 10 percent earmark and the split, stage B selects the module and the controller and applies the settings patch with the split as artist, the launch state converts a real held Statement into the treasury with 10 percent earmarked, the readback passes with a positive margin, and stage D allocates claims, enables redemption, pays a real holder's burn its share and disables again; nothing on the Core changes outside these owner sends
    function test_ladderOnTheLiveCoreAndToken() public {
        _stageA();
        _stageB();
        _launchAndConvert();
        _stageC();
        _stageD();
        assertEq(readback.read(CORE, address(t), address(c2)), "", "the readback passes at the end");
    }

    function _stageA() internal {
        Phase2Deploy.Inputs memory di = Phase2Deploy.Inputs({
            core: CORE,
            balanceToken: token,
            statementSaleMultiplierBps: 15_000,
            statementRedeemDelaySeconds: 3_600,
            tokenCodehash: token.codehash,
            allowUnpinnedToken: false,
            split: address(0),
            splitPlan: PushSplitCreator.SplitPlan({artist: core.artist(), operator: core.payee(), controller: owner})
        });
        Phase2Deploy.Result memory r = deployer.deploy(di);
        t = IPhase2BalanceTreasury(r.treasury);
        c2 = IControllerV2(r.controllerV2);
        split = r.split;
        assertEq(t.conversionToClaimBps(), 1_000);
        assertEq(t.balanceToken(), token);
    }

    function _stageB() internal {
        wire.go(_wireInputs(address(t), address(c2), "module"));
        assertEq(core.balanceModule(), address(t));
        assertEq(core.balanceToken(), token);
        wire.go(_wireInputs(address(t), address(c2), "controller"));
        assertEq(core.controller(), address(c2));
        Settings memory before = core.settings();
        uint16 costBefore = ILifecycleCore(CORE).creditCostToPotBps();
        settings.setSplit(split);
        settings.applyAsOwner();
        Settings memory s = core.settings();
        assertEq(core.artist(), split, "the split is the artist");
        assertEq(s.balanceDiscountBps, 2_000, "80 percent payout");
        assertEq(s.buyToArtistBps, 300);
        assertEq(s.saleToArtistBps, 300);
        assertEq(s.saleToOperatorBps, 0);
        // decision 262: the buy and burn shares and the credit cost share stay at their live values through stage C
        assertEq(s.saleToBuybackBps, before.saleToBuybackBps);
        assertEq(s.feeToRedeemBurnBps, before.feeToRedeemBurnBps);
        assertEq(s.redeemBurnBps, before.redeemBurnBps);
        assertEq(ILifecycleCore(CORE).creditCostToPotBps(), costBefore);
    }

    function _launchAndConvert() internal {
        wire.go(_wireInputs(address(t), address(c2), "launch"));
        assertTrue(t.conversionEnabled() && t.workingPaymentsEnabled() && !t.ccRedemptionEnabled());
        assertTrue(t.conversionReady(), "the live token is retired and the renderer registered");
        assertEq(readback.read(CORE, address(t), address(c2)), "", "the readback passes at the launch state");
        uint256[] memory held = core.heldStatements();
        assertGt(held.length, 0, "the live Core holds Statements");
        uint256 sid;
        for (uint256 i; i < held.length; ++i) {
            if (c2.atFloor(held[i])) {
                sid = held[i];
                break;
            }
        }
        assertGt(sid, 0, "an eligible Statement");
        address keeper = address(0x6EEBE2);
        vm.deal(keeper, 1 ether);
        uint256 custodyBefore = t.custody();
        vm.prank(keeper);
        core.redeemStatement(sid);
        received = t.custody() - custodyBefore;
        assertGt(received, 0, "the conversion paid the treasury");
        assertEq(t.claimReserve(), received * 1_000 / 10_000, "10 percent earmarked");
        assertEq(t.working(), received - t.claimReserve());
        uint256 open = ILifecycleToken(token).transfersOpenBlock();
        if (block.number <= open) vm.roll(open + 1);
        assertTrue(t.transfersReady());
        assertEq(t.available(), t.freeWorking(), "working payments are payable once transfers are open");
        assertEq(readback.read(CORE, address(t), address(c2)), "", "the readback passes after the conversion");
        emit log_named_uint("Statement converted", sid);
        emit log_named_uint("BALANCE received", received);
    }

    /// stage C on the live eth / BALANCE pool: the pool key and quote through the wiring script, value mode and the
    /// balance bid through SetSettings, then a buyer takes a pile Credit from the engine and sells it back for BALANCE
    /// after the return lock: the treasury pays the seller and the split's royalty with the real token
    function _stageC() internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        IPoolManager pm = IPoolManager(ILifecycleCore(CORE).MANAGER());
        (uint160 sp,,,) = pm.getSlot0(key.toId());
        assertGt(pm.getLiquidity(key.toId()), 1e21, "the live pool has liquidity");
        Phase2Wire.Inputs memory p = _wireInputs(address(t), address(c2), "pool");
        p.poolFee = POOL_FEE;
        p.poolTickSpacing = POOL_TICK_SPACING;
        p.expectedSpot = (1e18 * FixedPoint96.Q96 / sp) * FixedPoint96.Q96 / sp;
        wire.go(p);
        Phase2Wire.Inputs memory q = _wireInputs(address(t), address(c2), "quote");
        q.quote = Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 100,
            referenceMaxStale: 1_800,
            referenceMinSeconds: 600,
            minLiquidity: 1e21
        });
        wire.go(q);
        Settings memory next = core.settings();
        next.valueModeOn = true;
        next.spendCapBps = 9_999;
        next.balanceBidOn = true;
        setSettings.applyCombined(IControllerV1(address(c2)), next);
        assertTrue(core.settings().balanceBidOn && core.settings().valueModeOn);
        (uint256 value, bool usable) = c2.valuePerPoint(true);
        assertTrue(usable && value != 0, "the protected balance price is usable on the live pool");
        assertEq(readback.read(CORE, address(t), address(c2)), "", "the readback passes with the bid on");
        // a buyer takes the oldest pile Credit past its window from the engine
        uint256[] memory page = core.pilePage(0, 10);
        uint256 id;
        for (uint256 i; i < page.length; ++i) {
            (,, uint64 acquiredAt) = core.creditInfo(page[i]);
            if (ILifecycleV2(address(c2)).pastWindow(acquiredAt)) {
                id = page[i];
                break;
            }
        }
        assertGt(id, 0, "a pile Credit past its window");
        address buyer = address(0xB01E);
        uint256 price = ILifecycleV2(address(c2)).creditPrice(id);
        vm.deal(buyer, price + 1 ether);
        vm.prank(buyer);
        ILifecycleV2(address(c2)).buyCredit{value: price}(id);
        assertEq(ILifecycleCredits(Mainnet.CREDITS).ownerOf(id), buyer, "the buyer holds the Credit");
        vm.prank(buyer);
        ILifecycleCredits(Mainnet.CREDITS).setApprovalForAll(CORE, true);
        // past the return lock; the reference is refreshed in a new block so the clamp prices
        vm.warp(block.timestamp + 7 hours);
        vm.roll(block.number + 1);
        ILifecycleV2(address(c2)).refreshReference();
        uint256 posted = core.balanceBidOf(id);
        assertGt(posted, 0, "the posted 80 percent bid");
        uint256 custodyBefore = t.custody();
        uint256 splitBefore = ILifecycleToken(token).balanceOf(split);
        uint256 sellerBefore = ILifecycleToken(token).balanceOf(buyer);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(buyer);
        core.sellForBalance(ids, 0);
        uint256 paid = ILifecycleToken(token).balanceOf(buyer) - sellerBefore;
        uint256 royalty = ILifecycleToken(token).balanceOf(split) - splitBefore;
        assertGt(paid, 0, "the seller was paid in the real token");
        assertLe(paid, posted, "at most the posted bid, lowered by the clamp");
        assertEq(royalty, paid * 300 / 10_000, "the split got 3 percent of the payout");
        assertEq(custodyBefore - t.custody(), paid + royalty, "both left working funds");
        assertEq(t.totalOwed(), 0, "no accrual: both transfers completed under the bounds");
        emit log_named_uint("Credit sold for BALANCE, paid", paid);
        emit log_named_uint("royalty to the split", royalty);
    }

    function _stageD() internal {
        uint256 allocate = t.freeWorking() / 10;
        claims.go(Phase2Claims.Inputs({treasury: address(t), step: "allocate", amount: allocate, allowEmpty: false}));
        uint256 reserve = t.claimReserve();
        assertEq(reserve, received * 1_000 / 10_000 + allocate);
        claims.go(Phase2Claims.Inputs({treasury: address(t), step: "enable", amount: 0, allowEmpty: false}));
        assertTrue(t.ccRedemptionEnabled());
        address holder = address(0xB0B5);
        uint256 x = _buyCoin(holder, 0.02 ether) / 2;
        assertGt(x, 0);
        ILifecycleCoin coin = ILifecycleCoin(core.COIN());
        uint256 supply = coin.totalSupply();
        (uint256 quote,,, uint64 epoch, bool executable) = t.quoteRedemption(x);
        assertTrue(executable);
        assertEq(quote, x * reserve / supply);
        vm.startPrank(holder);
        coin.approve(address(t), x);
        uint256 out = t.redeemCC(x, holder, quote, block.timestamp, epoch);
        vm.stopPrank();
        assertEq(out, quote);
        assertEq(ILifecycleToken(token).balanceOf(holder), out, "the real token paid the burner");
        assertEq(coin.totalSupply(), supply - x, "the real coin burned exactly the input");
        assertEq(t.claimReserve(), reserve - out);
        claims.go(Phase2Claims.Inputs({treasury: address(t), step: "disable", amount: 0, allowEmpty: false}));
        assertFalse(t.ccRedemptionEnabled());
        emit log_named_uint("CC burned", x);
        emit log_named_uint("BALANCE paid for the burn", out);
    }

    /// buys CC on the live coin pool through the hook route, as the fixture does
    function _buyCoin(address who, uint256 ethIn) internal returns (uint256) {
        ILifecycleCore c = ILifecycleCore(CORE);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(c.COIN()),
            fee: c.POOL_FEE(),
            tickSpacing: c.TICK_SPACING(),
            hooks: IHooks(c.HOOK())
        });
        vm.deal(who, who.balance + ethIn);
        ILifecycleCoin coin = ILifecycleCoin(c.COIN());
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        router.swap{value: ethIn}(key, true, -int256(ethIn), who);
        return coin.balanceOf(who) - before;
    }
}
