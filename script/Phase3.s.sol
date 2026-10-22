// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {CreditSale, Quote, IdleLoosening, BalanceBid} from "../src/interfaces/Interfaces.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice the phase 3 owner sends (docs/specs/PHASE3.md), one `STEP` per run, each with a preview, the sends and a
/// readback. every send is `vm.startBroadcast`, so the no-keystore dry run (`--sender <owner>`, no `--broadcast`)
/// simulates exactly the sends and prints their gas.
///
/// - `deploy`: ProRataRedeemer (fee 0), BalanceTreasuryV2 (v1 as predecessor) and ControllerV3 (the live credit sale,
///   the live quote at step 900, Statement ask 1.1x, Statement redemption delay 7 days, idle loosening). nothing live
///   changes
/// - `migrate` (`TREASURY_V2`, `CONTROLLER_V3`): v1 switches off, `setBalanceModule(v2)`, v1 `migrateTo(v2)`, the v2
///   settings, v2 conversion and working payments on (bid and redeemers off), `sweep`, the V3 pool key and Statement
///   sales, `setController(V3)`. the v1 `migrateTo` requires its successor to be the selected module, so the module
///   changes before the funds move
/// - `bid`: v2 bid on. run at least the Core's `returnLockSeconds` after `setController(V3)`: credits ControllerV2 sold
///   before the switch carry no V3 sale record
/// - `readback`: the checks alone
///
/// `STEP=deploy forge script script/Phase3.s.sol --rpc-url https://gateway.tenderly.co/public/mainnet --sender <owner>`
/// is the dry run; the send adds `--broadcast --slow --account ripe0x`
contract Phase3 is Script, LaunchChecks {
    error NotOwner(address owner, address signer);
    error CreateFailed(string name);

    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    /// the owner's choices: decisions 277 to 281 and the spec's example values
    struct Params {
        uint256 cushion;
        BalanceBid bid;
        uint16 bidShareBps;
        uint16 proRataShareBps;
        uint128 proRataPerPeriod;
        uint16 statementSaleMultiplierBps;
        uint32 statementRedeemDelaySeconds;
        uint16 quoteStepBps;
        IdleLoosening idle;
    }

    struct Deployed {
        address redeemer;
        address treasury;
        address controller;
    }

    function params() public pure returns (Params memory p) {
        p.cushion = 150_000 ether;
        p.bid = BalanceBid({
            floorBps: 8_500,
            capBps: 11_500,
            climbBps: 50,
            stepSeconds: 600,
            dropPer100PointsBps: 29,
            overEthBps: 500,
            maxPerCall: 20_000 ether,
            maxPerPeriod: 60_000 ether
        });
        p.bidShareBps = 2_500;
        p.proRataShareBps = 0;
        p.proRataPerPeriod = 50_000 ether;
        p.statementSaleMultiplierBps = 11_000;
        p.statementRedeemDelaySeconds = 7 days;
        p.quoteStepBps = 900;
        p.idle = IdleLoosening({stepSeconds: 600, bps: 50, capBps: 700});
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
            controller: vm.envAddress("CONTROLLER_V3")
        });
        d.redeemer = IBalanceTreasuryV2(d.treasury).proRataRedeemer();
        if (step == keccak256("migrate")) migrate(core, d, p, true);
        else if (step == keccak256("bid")) enableBid(core, d, true);
        else readback(core, d, p);
    }

    /// @notice the sends of `deploy`. `broadcast` false creates from this contract, as a test does
    function deploy(address core, Params memory p, bool broadcast) public returns (Deployed memory d) {
        ICore c = ICore(payable(core));
        IControllerV2 v2c = IControllerV2(c.controller());
        address v1 = c.balanceModule();
        CreditSale memory credit = CreditSale({
            saleOn: v2c.creditSaleOn(),
            window: v2c.creditWindow(),
            spreadBps: v2c.creditSpreadBps(),
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
        _stop(broadcast);
        console.log(
            string.concat(
                'record: {"redeemer":"',
                vm.toString(d.redeemer),
                '","treasuryV2":"',
                vm.toString(d.treasury),
                '","controllerV3":"',
                vm.toString(d.controller),
                '"}'
            )
        );
    }

    /// @notice the sends of `migrate`, then `readback`
    function migrate(address core, Deployed memory d, Params memory p, bool broadcast) public {
        ICore c = ICore(payable(core));
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(c.balanceModule());
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        IControllerV2 v2c = IControllerV2(c.controller());
        _reset();
        _eq("preview: v2 core", t.core(), core);
        _eq("preview: v2 predecessor is the live module", t.predecessor(), address(v1));
        _eq("preview: V3 CORE", v3.CORE(), core);
        _check("preview: v2 switches off", !t.conversionEnabled() && !t.workingPaymentsEnabled() && !t.bidEnabled(), "");
        _check("preview: V3 pool key unset", !v3.balancePoolKeySet(), "");
        _check("preview: Core module and controller unlocked", !c.balanceModuleLocked() && !c.controllerLocked(), "");
        _check("preview: v1 CC redemption off", !v1.ccRedemptionEnabled(), "");
        _info("preview: v1 custody / claim reserve", string.concat(vm.toString(v1.custody()), " / ", vm.toString(v1.claimReserve())));
        _print("phase 3 migrate preview");
        _require();
        (IControllerV2.Currency c0, IControllerV2.Currency c1, uint24 fee, int24 spacing, address hooks) =
            v2c.balancePoolKey();
        (uint256 spot,) = v2c.spotPrice();
        _start(c, broadcast);
        v1.setSwitches(false, false, false);
        c.setBalanceModule(d.treasury);
        v1.migrateTo(d.treasury);
        t.setCushion(p.cushion);
        t.setBid(p.bid);
        t.setBidShare(p.bidShareBps);
        if (p.proRataShareBps != 0) t.setRedeemerShare(d.redeemer, p.proRataShareBps);
        t.setSwitches(true, true, false);
        t.sweep();
        v3.setBalancePoolKey(
            IControllerV3.PoolKey({
                currency0: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c0)),
                currency1: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c1)),
                fee: fee,
                tickSpacing: spacing,
                hooks: hooks
            }),
            spot
        );
        v3.setStatementSales(true);
        c.setController(d.controller);
        _stop(broadcast);
        readback(core, d, p);
    }

    /// @notice the send of `bid`
    function enableBid(address core, Deployed memory d, bool broadcast) public {
        ICore c = ICore(payable(core));
        _start(c, broadcast);
        IBalanceTreasuryV2(d.treasury).setSwitches(true, true, true);
        _stop(broadcast);
    }

    /// @notice the live state after `migrate`: the module and controller, the moved funds, the v2 settings and every
    /// view the Core, keeper, indexer and web read
    function readback(address core, Deployed memory d, Params memory p) public {
        ICore c = ICore(payable(core));
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(t.predecessor());
        _reset();
        _pin("ControllerV3", BUILD_HASH_CONTROLLER_V3, d.controller);
        _pin("BalanceTreasuryV2", BUILD_HASH_TREASURY_V2, d.treasury);
        _pin("ProRataRedeemer", BUILD_HASH_PRO_RATA_REDEEMER, d.redeemer);
        _eq("Core module is v2", c.balanceModule(), d.treasury);
        _eq("Core controller is V3", c.controller(), d.controller);
        _check("v1 migrated, holding only its debt", v1.migrated() && v1.custody() == v1.totalOwed(), vm.toString(v1.custody()));
        _check("v2 solvent", t.solvent(), vm.toString(t.custody()));
        uint256 bucket = t.redeemers(d.redeemer).bucket;
        _info("v2 custody / pro-rata bucket / bid budget", string.concat(vm.toString(t.custody()), " / ", vm.toString(bucket), " / ", vm.toString(t.bidBudget())));
        _eq("v2 cushion", t.cushion(), p.cushion);
        _check("v2 working at or above the cushion", t.working() >= t.cushion(), vm.toString(t.working()));
        _check("v2 conversion and working payments on, redeemers off", t.conversionEnabled() && t.workingPaymentsEnabled() && !t.ccRedemptionEnabled(), "");
        _check("v2 available answers", t.available() == t.working(), vm.toString(t.available()));
        (uint256 vb, bool okb) = v3.valuePerPoint(false);
        (uint256 vs, bool oks) = v3.valuePerPoint(true);
        _check("V3 valuePerPoint answers both sides", okb && oks && vb != 0 && vs >= vb * 10_000 / (10_000 + 700), "");
        _check("Core ethPrice nonzero", c.ethPrice() != 0, vm.toString(c.ethPrice()));
        _check("V3 Statement sales on, ask 1.1x, delay 7 days", v3.statementSalesEnabled() && v3.statementSaleMultiplierBps() == p.statementSaleMultiplierBps && v3.statementRedeemDelaySeconds() == p.statementRedeemDelaySeconds, "");
        (, uint16 step,,,,) = v3.quote();
        _eq("V3 quote step", step, p.quoteStepBps);
        _check("V3 idle loosening within its cap", v3.idleLoosenBps() <= p.idle.capBps, vm.toString(v3.idleLoosenBps()));
        _check("V3 legacy views", v3.markupBps() == p.statementSaleMultiplierBps && v3.decayHours() == 168 && v3.ageEligibilityOn(), "");
        (bool ready,,) = v3.nextPage();
        _info("V3 nextPage", ready ? "ready" : "not ready");
        _info("v2 bid now (bps of par)", vm.toString(t.bidBpsNow()));
        _print("phase 3 readback");
        _require();
    }

    /// @dev out/ equals the pinned build and the live code equals out/, immutables masked
    function _pin(string memory name, bytes32 want, address at) private {
        _check(string.concat("build: ", name, " out/ equals the pin"), artifactHash(name) == want, name);
        _check(string.concat("build: ", name, " live code is the pinned build"), runtimeMatchesArtifact(at, name), vm.toString(at));
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
