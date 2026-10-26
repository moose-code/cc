// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IMarketRedeemer} from "../src/interfaces/IMarketRedeemer.sol";
import {ICreditBid} from "../src/interfaces/ICreditBid.sol";
import {CreditSale, Quote, IdleLoosening, BalanceBid, CcQuote, SpenderState, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice the phase 3 owner sends (docs/specs/PHASE3.md), one `STEP` per run, each with a preview, the sends and a
/// readback. every send is `vm.startBroadcast`, so the no-keystore dry run (`--sender <owner>`, no `--broadcast`)
/// simulates exactly the sends and prints their gas.
///
/// - `deploy`: ProRataRedeemer (fee 0), BalanceTreasuryV2 (v1 as predecessor), ControllerV3 (the live credit sale,
///   the live quote at step 900, Statement ask 1.1x, Statement redemption delay 1 hour, idle loosening at cap 0),
///   MarketRedeemer (premium 500 bps) and CreditBid (the balance bid, a spender of v2). nothing live changes
/// - `migrate` (`TREASURY_V2`, `CONTROLLER_V3`, `MARKET_REDEEMER`, `CREDIT_BID`): v1 switches off,
///   `setBalanceModule(v2)`, v1 `migrateTo(v2)`, the v2 settings, the bid and redeemer 2 registered as spenders with
///   their caps and sweep shares, the bid band, v2 conversion and working payments on (every spender off), `sweep`,
///   the V3 pool key, CC reference, Statement sales and market floor, `setController(V3)`. the v1 `migrateTo` requires
///   its successor to be the selected module, so the module changes before the funds move
/// - `bid`: the bid spender on. run at least the Core's `returnLockSeconds` after `setController(V3)`: credits
///   ControllerV2 sold before the switch carry no V3 sale record
/// - `ens`: `vault.creditcycle.eth` to v2 on its public resolver, from the name's owner (the Core owner). any time
///   after `migrate`
/// - `readback`: the checks alone, right after `migrate`; `LIVE=1` for the running system after `bid` (the bid on,
///   the keeper kept posts reported rather than required fresh)
///
/// `STEP=deploy forge script script/Phase3.s.sol --rpc-url https://gateway.tenderly.co/public/mainnet --sender <owner>`
/// is the dry run; the send adds `--broadcast --slow --account ripe0x`
interface IEnsRegistry {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
}

interface IEnsResolver {
    function addr(bytes32 node) external view returns (address);
    function setAddr(bytes32 node, address a) external;
}

contract Phase3 is Script, LaunchChecks {
    error NotOwner(address owner, address signer);
    error CreateFailed(string name);

    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    /// the owner's choices: decisions 279 to 288
    struct Params {
        uint256 cushion;
        BalanceBid bid;
        uint16 bidShareBps;
        uint128 bidPerCall;
        uint128 bidPerPeriod;
        uint16 proRataShareBps;
        uint128 proRataPerPeriod;
        /// the credit sale spread V3 ships with, set at deploy whatever the live ControllerV2 holds (decision 291:
        /// the engine's ask is 1.25 par, never the cheapest per point ask)
        uint16 creditSpreadBps;
        uint16 statementSaleMultiplierBps;
        uint32 statementRedeemDelaySeconds;
        uint16 quoteStepBps;
        IdleLoosening idle;
        uint16 marketPremiumBps;
        uint128 marketPerCall;
        uint128 marketPerPeriod;
        uint128 marketLifetime;
        uint16 marketShareBps;
        CcQuote ccQuote;
        /// the market floor settings (ControllerV3 7.): the keeper posts the collection's top bid
        IControllerV3.MarketFloor floor;
        /// the first posted floor, wei per Credit, set by the owner in `migrate` so the term is live from the switch
        uint256 floorWei;
    }

    struct Deployed {
        address redeemer;
        address treasury;
        address controller;
        address market;
        address bid;
    }

    function params() public pure returns (Params memory p) {
        p.cushion = 150_000 ether;
        p.bid = BalanceBid({
            floorBps: 8_000,
            capBps: 10_000,
            climbBps: 50,
            stepSeconds: 600,
            dropPer100PointsBps: 29,
            overEthBps: 500
        });
        p.bidShareBps = 2_500;
        p.bidPerCall = 20_000 ether;
        p.bidPerPeriod = 60_000 ether;
        p.proRataShareBps = 0;
        p.proRataPerPeriod = 50_000 ether;
        p.creditSpreadBps = 2_500;
        p.statementSaleMultiplierBps = 11_000;
        p.statementRedeemDelaySeconds = 3_600;
        p.quoteStepBps = 900;
        p.idle = IdleLoosening({stepSeconds: 600, bps: 0, capBps: 0});
        p.marketPremiumBps = 500;
        p.marketPerCall = 5_000 ether;
        p.marketPerPeriod = 20_000 ether;
        p.marketLifetime = type(uint128).max;
        p.marketShareBps = 7_500;
        p.ccQuote = CcQuote({
            rateBpsPerHour: 6_000,
            stepBps: 900,
            maxStale: 3_600,
            minSeconds: 600,
            avgSeconds: 3_600,
            minLiquidity: 1.5e22
        });
        // the keeper's signer posts; a post moves at most 10 percent and at most every 10 minutes; a post older than
        // 6 hours blocks the sales it binds on. the spread over the top bid is 300 bps (PRICING-REVIEW section 7)
        p.floor = IControllerV3.MarketFloor({
            poster: 0x6b9411DD51DF1E41015cD8293C1BBC3E881a4aee,
            spreadBps: 300,
            stepBps: 1_000,
            minSeconds: 600,
            maxStale: 6 hours
        });
        // the collection's top bid on 2026-10-25, 0.0087 ETH; the owner's first post, the keeper moves it from there
        p.floorWei = 0.0087 ether;
    }

    function run() external {
        address core = vm.envOr("CORE", MAINNET_CORE);
        bytes32 step = keccak256(bytes(vm.envString("STEP")));
        Params memory p = params();
        if (step == keccak256("deploy")) {
            deploy(core, p, true);
            return;
        }
        Deployed memory d = Deployed({
            redeemer: address(0),
            treasury: vm.envAddress("TREASURY_V2"),
            controller: vm.envAddress("CONTROLLER_V3"),
            market: vm.envAddress("MARKET_REDEEMER"),
            bid: vm.envAddress("CREDIT_BID")
        });
        d.redeemer = IBalanceTreasuryV2(d.treasury).proRataRedeemer();
        if (step == keccak256("migrate")) migrate(core, d, p, true);
        else if (step == keccak256("bid")) enableBid(core, d, true);
        else if (step == keccak256("ens")) ens(core, d, true);
        else readback(core, d, p, vm.envOr("LIVE", false));
    }

    /// @notice the sends of `deploy`. `broadcast` false creates from this contract, as a test does
    function deploy(address core, Params memory p, bool broadcast) public returns (Deployed memory d) {
        ICore c = ICore(payable(core));
        IControllerV2 v2c = IControllerV2(c.controller());
        address v1 = c.balanceModule();
        CreditSale memory credit = CreditSale({
            saleOn: v2c.creditSaleOn(),
            window: v2c.creditWindow(),
            spreadBps: p.creditSpreadBps,
            startBps: v2c.creditStartBps()
        });
        Quote memory q;
        (q.referenceRateBpsPerHour, q.referenceStepBps, q.tolBps, q.referenceMaxStale, q.referenceMinSeconds, q.minLiquidity)
        = v2c.quote();
        q.referenceStepBps = p.quoteStepBps;
        _reset();
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _info("preview: owner", vm.toString(c.owner()));
        _code("preview: v1 treasury (the predecessor) has code", v1);
        _check(
            "preview: band (1+step)(1+tol)(1-margin) < 1",
            (10_000 + uint256(q.referenceStepBps)) * (10_000 + q.tolBps) * (10_000 - c.settings().balanceBidMarginBps)
                < 1e12,
            vm.toString(q.referenceStepBps)
        );
        _print("phase 3 deploy preview");
        _require();
        _start(c, broadcast);
        d.redeemer = _create("ProRataRedeemer", abi.encode(uint16(0)));
        d.treasury =
            _create("BalanceTreasuryV2", abi.encode(core, c.balanceToken(), d.redeemer, p.proRataPerPeriod, v1));
        d.controller = _create(
            "ControllerV3",
            abi.encode(core, credit, q, uint32(p.statementSaleMultiplierBps), p.statementRedeemDelaySeconds, p.idle)
        );
        d.market = _create("MarketRedeemer", abi.encode(core, p.marketPremiumBps));
        d.bid = _create("CreditBid", abi.encode(d.treasury));
        _stop(broadcast);
        console.log(
            string.concat(
                'record: {"redeemer":"',
                vm.toString(d.redeemer),
                '","treasuryV2":"',
                vm.toString(d.treasury),
                '","controllerV3":"',
                vm.toString(d.controller),
                '","marketRedeemer":"',
                vm.toString(d.market),
                '","creditBid":"',
                vm.toString(d.bid),
                '"}'
            )
        );
    }

    /// @notice the sends of `migrate`, then `readback`
    function migrate(address core, Deployed memory d, Params memory p, bool broadcast) public {
        ICore c = ICore(payable(core));
        _migratePreview(c, d);
        (IControllerV3.PoolKey memory balKey, uint256 balSpot) = _balanceKey(c);
        IControllerV3.PoolKey memory ccKey = IControllerV3.PoolKey({
            currency0: IControllerV3.Currency.wrap(address(0)),
            currency1: IControllerV3.Currency.wrap(c.COIN()),
            fee: c.POOL_FEE(),
            tickSpacing: c.TICK_SPACING(),
            hooks: c.HOOK()
        });
        uint256 ccSpot = _ccSpot(ccKey);
        _start(c, broadcast);
        _moveTreasury(c, d, p);
        IControllerV3 v3 = IControllerV3(d.controller);
        v3.setBalancePoolKey(balKey, balSpot);
        v3.setCcPoolKey(ccKey, ccSpot);
        v3.setCcQuote(p.ccQuote);
        v3.setStatementSales(true);
        v3.setMarketFloor(p.floor);
        v3.postMarketFloor(p.floorWei);
        c.setController(d.controller);
        _stop(broadcast);
        readback(core, d, p, false);
    }

    function _migratePreview(ICore c, Deployed memory d) private {
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(c.balanceModule());
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        _reset();
        _eq("preview: v2 core", t.core(), address(c));
        _eq("preview: v2 predecessor is the live module", t.predecessor(), address(v1));
        _eq("preview: v2 balance token is the Core's", t.balanceToken(), c.balanceToken());
        _eq("preview: v2 coin is the Core's", t.ccToken(), c.COIN());
        _eq("preview: CreditBid core", ICreditBid(d.bid).core(), address(c));
        _eq("preview: V3 CORE", v3.CORE(), address(c));
        _check("preview: v2 switches off, no spender on", !t.conversionEnabled() && !t.workingPaymentsEnabled() && !t.ccRedemptionEnabled(), "");
        _eq("preview: CreditBid treasury", ICreditBid(d.bid).treasury(), d.treasury);
        _check("preview: V3 pool key unset", !v3.balancePoolKeySet(), "");
        _check("preview: Core module and controller unlocked", !c.balanceModuleLocked() && !c.controllerLocked(), "");
        _check("preview: v1 CC redemption off", !v1.ccRedemptionEnabled(), "");
        _eq("preview: MarketRedeemer core", IMarketRedeemer(d.market).core(), address(c));
        _info("preview: v1 custody / claim reserve", string.concat(vm.toString(v1.custody()), " / ", vm.toString(v1.claimReserve())));
        _print("phase 3 migrate preview");
        _require();
    }

    /// @dev the live ControllerV2 pool key and spot, carried to V3
    function _balanceKey(ICore c) private view returns (IControllerV3.PoolKey memory k, uint256 spot) {
        IControllerV2 v2c = IControllerV2(c.controller());
        (IControllerV2.Currency c0, IControllerV2.Currency c1, uint24 fee, int24 spacing, address hooks) =
            v2c.balancePoolKey();
        k = IControllerV3.PoolKey({
            currency0: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c0)),
            currency1: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: hooks
        });
        (spot,) = v2c.spotPrice();
    }

    /// @dev v1 off, the module switch, v1 `migrateTo`, the v2 settings, the bid and redeemer 2 registered as spenders,
    /// the bid band, v2 on, the sweep
    function _moveTreasury(ICore c, Deployed memory d, Params memory p) private {
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(c.balanceModule());
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        v1.setSwitches(false, false, false);
        c.setBalanceModule(d.treasury);
        v1.migrateTo(d.treasury);
        t.setCushion(p.cushion);
        t.registerSpender(d.bid, p.bidPerCall, p.bidPerPeriod, type(uint128).max);
        t.setSpenderShare(d.bid, p.bidShareBps);
        if (p.proRataShareBps != 0) t.setSpenderShare(d.redeemer, p.proRataShareBps);
        t.registerSpender(d.market, p.marketPerCall, p.marketPerPeriod, p.marketLifetime);
        t.setSpenderShare(d.market, p.marketShareBps);
        ICreditBid(d.bid).setBid(p.bid);
        t.setSwitches(true, true);
        t.sweep();
    }

    /// the ens registry, the vault name and its node
    address public constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    bytes32 public constant VAULT_NODE = 0xafdad34bdab44b570b0fafbb86b35b5647eb86dfbd34357f594e910ca745415d;

    /// @notice the send of `ens`: `setAddr(vault.creditcycle.eth, v2)` on the name's current resolver. the name must be
    /// owned by the Core owner in the registry (unwrapped) and v2 must be the Core's module
    function ens(address core, Deployed memory d, bool broadcast) public {
        ICore c = ICore(payable(core));
        IEnsRegistry reg = IEnsRegistry(ENS_REGISTRY);
        IEnsResolver res = IEnsResolver(reg.resolver(VAULT_NODE));
        _reset();
        _eq("preview: vault.creditcycle.eth owner is the Core owner", reg.owner(VAULT_NODE), c.owner());
        _code("preview: the name has a resolver", address(res));
        _eq("preview: v2 is the Core's module", c.balanceModule(), d.treasury);
        _info("preview: addr before", vm.toString(res.addr(VAULT_NODE)));
        _print("phase 3 ens preview");
        _require();
        _start(c, broadcast);
        res.setAddr(VAULT_NODE, d.treasury);
        _stop(broadcast);
        _reset();
        _eq("vault.creditcycle.eth resolves to v2", res.addr(VAULT_NODE), d.treasury);
        _print("phase 3 ens readback");
        _require();
    }

    /// @notice the send of `bid`: the bid spender on, once v2 is the module, the bid is its registered spender past
    /// its activation, and the band is set; then the switch read back
    function enableBid(address core, Deployed memory d, bool broadcast) public {
        ICore c = ICore(payable(core));
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        ICreditBid b = ICreditBid(d.bid);
        SpenderState memory r = t.spenders(d.bid);
        _reset();
        _eq("preview: v2 is the Core's module", c.balanceModule(), d.treasury);
        _eq("preview: Core controller is V3", c.controller(), d.controller);
        _eq("preview: CreditBid treasury", b.treasury(), d.treasury);
        _check("preview: bid registered as a spender, off", r.registered && !r.on, "");
        _check("preview: bid activation passed", block.timestamp >= r.activeAt, vm.toString(r.activeAt));
        (uint16 floorBps, uint16 capBps,,,,) = b.bid();
        _check("preview: band set", floorBps != 0 && capBps != 0, "");
        _check("preview: bid cap under the credit floor multiplier", capBps < IControllerV3(d.controller).floorMultBps(), vm.toString(capBps));
        _check("preview: bid bucket funded", r.bucket != 0, vm.toString(r.bucket));
        _print("phase 3 bid preview");
        _require();
        _start(c, broadcast);
        t.setSpenderOn(d.bid, true);
        _stop(broadcast);
        _reset();
        _check("bid spender on", t.spenders(d.bid).on, "");
        _check("bid enabled", b.bidEnabled(), "");
        _info("bid now (bps of par)", vm.toString(b.bidBpsNow()));
        _print("phase 3 bid readback");
        _require();
    }

    /// @notice the live state after `migrate`: the module and controller, the moved funds, the v2 settings and every
    /// view the Core, keeper, indexer and web read. `live` false is the state right after `migrate` (bid off, the
    /// floor and CC reference fresh from the run); `live` true (`LIVE=1`) is the running system after `bid`: the bid
    /// on, and the two posts reported, not required fresh, since the keeper keeps them
    function readback(address core, Deployed memory d, Params memory p, bool live) public {
        ICore c = ICore(payable(core));
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(t.predecessor());
        _reset();
        _pin("ControllerV3", BUILD_HASH_CONTROLLER_V3, d.controller);
        _pin("BalanceTreasuryV2", BUILD_HASH_TREASURY_V2, d.treasury);
        _pin("ProRataRedeemer", BUILD_HASH_PRO_RATA_REDEEMER, d.redeemer);
        _pin("MarketRedeemer", BUILD_HASH_MARKET_REDEEMER, d.market);
        _pin("CreditBid", BUILD_HASH_CREDIT_BID, d.bid);
        _eq("Core module is v2", c.balanceModule(), d.treasury);
        _eq("Core controller is V3", c.controller(), d.controller);
        _check("v1 migrated, holding only its debt", v1.migrated() && v1.custody() == v1.totalOwed(), vm.toString(v1.custody()));
        _readbackFunds(t, d, p);
        _check("v2 working at or above the cushion", t.working() >= t.cushion(), vm.toString(t.working()));
        _check("v2 conversion and working payments on", t.conversionEnabled() && t.workingPaymentsEnabled(), "");
        if (live) _check("bid spender on, redeemers off", t.spenders(d.bid).on && !t.spenders(d.market).on && !t.spenders(d.redeemer).on, "");
        else _check("every spender off", !t.ccRedemptionEnabled(), "");
        _eq("V3 credit spread", IControllerV3(d.controller).creditSpreadBps(), p.creditSpreadBps);
        _eq("V3 floor multiplier from the spread and the live cap", IControllerV3(d.controller).floorMultBps(), (10_000 + uint256(p.creditSpreadBps)) * c.settings().balanceBidCapBps / 10_000);
        _check("v2 available answers", t.available() == t.working(), vm.toString(t.available()));
        (uint256 vb, bool okb) = v3.valuePerPoint(false);
        (uint256 vs, bool oks) = v3.valuePerPoint(true);
        _check("V3 valuePerPoint answers both sides", okb && oks && vb != 0 && vs >= vb * 10_000 / (10_000 + 700), "");
        _check("Core ethPrice nonzero", c.ethPrice() != 0, vm.toString(c.ethPrice()));
        _check("V3 Statement sales on, ask 1.1x, delay 1 hour", v3.statementSalesEnabled() && v3.statementSaleMultiplierBps() == p.statementSaleMultiplierBps && v3.statementRedeemDelaySeconds() == p.statementRedeemDelaySeconds, "");
        (, uint16 step,,,,) = v3.quote();
        _eq("V3 quote step", step, p.quoteStepBps);
        _check("V3 idle loosening within its cap", v3.idleLoosenBps() <= p.idle.capBps, vm.toString(v3.idleLoosenBps()));
        _check("V3 legacy views", v3.markupBps() == p.statementSaleMultiplierBps && v3.decayHours() == 1 && v3.ageEligibilityOn(), "");
        (bool ready,,) = v3.nextPage();
        _info("V3 nextPage", ready ? "ready" : "not ready");
        _readbackFloor(v3, p, live);
        _readbackRedeemers(t, IControllerV3(d.controller), d, p, live);
        _print("phase 3 readback");
        _require();
    }

    /// @dev the solvency, the buckets and the cushion
    function _readbackFunds(IBalanceTreasuryV2 t, Deployed memory d, Params memory p) private {
        _check("v2 solvent", t.solvent(), vm.toString(t.custody()));
        uint256 bucket = t.spenders(d.redeemer).bucket;
        _info("v2 custody / pro-rata bucket / bid bucket", string.concat(vm.toString(t.custody()), " / ", vm.toString(bucket), " / ", vm.toString(ICreditBid(d.bid).bidBudget())));
        _eq("v2 cushion", t.cushion(), p.cushion);
        _info("bid now (bps of par)", vm.toString(ICreditBid(d.bid).bidBpsNow()));
    }

    /// @dev the market floor reference: set to the params and posted fresh
    function _readbackFloor(IControllerV3 v3, Params memory p, bool live) private {
        (address poster, uint16 fSpread, uint16 fStep, uint32 fMin, uint32 fStale) = v3.marketFloor();
        (uint256 floorAsk, bool floorFresh) = v3.marketFloorAsk();
        bool setOk = poster == p.floor.poster && fSpread == p.floor.spreadBps && fStep == p.floor.stepBps && fMin == p.floor.minSeconds && fStale == p.floor.maxStale;
        _check("V3 market floor set", setOk, "");
        if (live) _info("V3 market floor ask / fresh (the keeper posts)", string.concat(vm.toString(floorAsk), " / ", floorFresh ? "fresh" : "stale"));
        else _check("V3 market floor posted and fresh", floorFresh && floorAsk == p.floorWei * (10_000 + p.floor.spreadBps) / 10_000, vm.toString(floorAsk));
    }

    /// @dev the bid band and spender, the sweep shares, redeemer 2 and the CC reference
    function _readbackRedeemers(IBalanceTreasuryV2 t, IControllerV3 v3, Deployed memory d, Params memory p, bool live) private {
        (uint16 floorBps, uint16 capBps,,,,) = ICreditBid(d.bid).bid();
        _check("bid 8,000 to 10,000 bps of par", floorBps == p.bid.floorBps && capBps == p.bid.capBps, "");
        SpenderState memory rb = t.spenders(d.bid);
        _check(
            "bid registered as a spender, caps",
            rb.registered && rb.on == live && rb.perCall == p.bidPerCall && rb.perPeriod == p.bidPerPeriod,
            ""
        );
        SpenderState memory r2 = t.spenders(d.market);
        _check(
            "v2 sweep shares: bid 2,500, redeemer 2 7,500, redeemer 1 0",
            rb.shareBps == p.bidShareBps && r2.shareBps == p.marketShareBps
                && t.spenders(d.redeemer).shareBps == p.proRataShareBps,
            ""
        );
        _check(
            "redeemer 2 registered, off, caps",
            r2.registered && !r2.on && r2.perCall == p.marketPerCall && r2.perPeriod == p.marketPerPeriod,
            ""
        );
        _info("redeemer 2 bucket", vm.toString(r2.bucket));
        _eq("redeemer 2 premium", IMarketRedeemer(d.market).premiumBps(), p.marketPremiumBps);
        (uint256 ccRef, bool okCc) = v3.ccPrice();
        (uint256 per1e18, bool okM) = IMarketRedeemer(d.market).preview(1e18);
        if (live) {
            _check("V3 CC reference set", v3.ccPoolKeySet() && ccRef != 0, vm.toString(ccRef));
            _info("V3 CC reference usable / redeemer 2 preview (the keeper refreshes)", string.concat(okCc ? "fresh" : "stale", " / ", vm.toString(per1e18)));
        } else {
            _check("V3 CC reference set and usable", v3.ccPoolKeySet() && okCc, vm.toString(ccRef));
            _check("redeemer 2 prices a burn", okM && per1e18 != 0, vm.toString(per1e18));
        }
    }

    /// @dev out/ equals the pinned build and the live code equals out/, immutables masked
    function _pin(string memory name, bytes32 want, address at) private {
        _check(string.concat("build: ", name, " out/ equals the pin"), artifactHash(name) == want, name);
        _check(string.concat("build: ", name, " live code is the pinned build"), runtimeMatchesArtifact(at, name), vm.toString(at));
    }

    using StateLibrary for IPoolManager;

    /// @dev the live spot of the CC pool, wei per 1e18 CC, the expected spot of `setCcPoolKey`
    function _ccSpot(IControllerV3.PoolKey memory k) private view returns (uint256) {
        (uint160 sqrtP,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolId.wrap(keccak256(abi.encode(k))));
        uint256 q = FixedPoint96.Q96;
        return (1e18 * q / sqrtP) * q / sqrtP;
    }

    function _start(ICore c, bool broadcast) private {
        if (broadcast) {
            vm.startBroadcast();
            (, address signer,) = vm.readCallers();
            if (signer != c.owner()) revert NotOwner(c.owner(), signer);
        } else {
            vm.startPrank(c.owner());
        }
    }

    function _stop(bool broadcast) private {
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }

    /// @dev a plain CREATE of artifact `name`, which `forge script` broadcasts as a deployment of the signer
    function _create(string memory name, bytes memory args) private returns (address at) {
        bytes memory init = abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args);
        assembly {
            at := create(0, add(init, 0x20), mload(init))
        }
        if (at.code.length == 0) revert CreateFailed(name);
    }
}
