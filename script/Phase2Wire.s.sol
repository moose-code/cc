// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Quote} from "../src/interfaces/Interfaces.sol";
import {Report} from "./Report.sol";

/// @notice the owner sends of stages B and C that are not settings patches, each its own reviewed run with a preview,
/// a plan hash a send must restate as `PHASE2_WIRE_PLAN_HASH`, the owner call and a readback. `STEP` selects the
/// send: `module` (`Core.setBalanceModule(TREASURY)`), `controller` (`Core.setController(CONTROLLER_V2)`), `launch`
/// (`treasury.setSwitches(true, true, false)`, the launch state of decision 258), `minimum`
/// (`treasury.setMinimumWorkingBalance(MINIMUM_WORKING_BALANCE)`), `pool` (`ControllerV2.setBalancePoolKey` with
/// `BALANCE_POOL_FEE`, `BALANCE_POOL_TICK_SPACING`, `BALANCE_POOL_HOOKS` and `BALANCE_POOL_EXPECTED_SPOT`, wei per
/// 1e18 BALANCE) and `quote` (`ControllerV2.setQuote` with `QUOTE_RATE_BPS_PER_HOUR` 1200, `QUOTE_STEP_BPS` 200,
/// `QUOTE_TOL_BPS` 100, `QUOTE_MAX_STALE` 1800, `QUOTE_MIN_SECONDS` 600 by default and `QUOTE_MIN_LIQUIDITY`
/// required). nothing is sent without `SEND=1 --broadcast` and the owner as signer.
/// `STEP=module CORE=0x... TREASURY=0x... forge script script/Phase2Wire.s.sol --rpc-url
/// https://gateway.tenderly.co/public/mainnet` (add `SEND=1 PHASE2_WIRE_PLAN_HASH=<printed> --broadcast --account
/// ripe0x` to send)
contract Phase2Wire is Script, Report {
    error NotOwner(address owner, address signer);
    error PlanHashMismatch(bytes32 want, bytes32 given);
    error ValueTooWide(string key);

    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    struct Inputs {
        address core;
        address treasury;
        address controllerV2;
        string step;
        uint256 minimumWorkingBalance;
        uint24 poolFee;
        int24 poolTickSpacing;
        address poolHooks;
        uint256 expectedSpot;
        Quote quote;
    }

    function run() external {
        Inputs memory i = Inputs({
            core: vm.envOr("CORE", MAINNET_CORE),
            treasury: vm.envOr("TREASURY", address(0)),
            controllerV2: vm.envOr("CONTROLLER_V2", address(0)),
            step: vm.envString("STEP"),
            minimumWorkingBalance: vm.envOr("MINIMUM_WORKING_BALANCE", uint256(0)),
            poolFee: uint24(_bounded("BALANCE_POOL_FEE", 0, type(uint24).max)),
            poolTickSpacing: int24(int256(_bounded("BALANCE_POOL_TICK_SPACING", 0, uint256(uint24(type(int24).max))))),
            poolHooks: vm.envOr("BALANCE_POOL_HOOKS", address(0)),
            expectedSpot: vm.envOr("BALANCE_POOL_EXPECTED_SPOT", uint256(0)),
            quote: Quote({
                referenceRateBpsPerHour: uint32(_bounded("QUOTE_RATE_BPS_PER_HOUR", 1_200, type(uint32).max)),
                referenceStepBps: uint16(_bounded("QUOTE_STEP_BPS", 200, type(uint16).max)),
                tolBps: uint16(_bounded("QUOTE_TOL_BPS", 100, type(uint16).max)),
                referenceMaxStale: uint32(_bounded("QUOTE_MAX_STALE", 1_800, type(uint32).max)),
                referenceMinSeconds: uint32(_bounded("QUOTE_MIN_SECONDS", 600, type(uint32).max)),
                minLiquidity: uint128(_bounded("QUOTE_MIN_LIQUIDITY", 0, type(uint128).max))
            })
        });
        bool send = vm.envOr("SEND", uint256(0)) == 1;
        if (send) {
            bytes32 want = planHash(i);
            bytes32 given = vm.envOr("PHASE2_WIRE_PLAN_HASH", bytes32(0));
            if (given != want) revert PlanHashMismatch(want, given);
        }
        execute(i, send);
    }

    function _bounded(string memory key, uint256 dflt, uint256 max) private view returns (uint256 v) {
        v = vm.envOr(key, dflt);
        if (v > max) revert ValueTooWide(key);
    }

    /// @notice the hash of the step and the state it applies to: the chain, the three addresses, the step, every
    /// input, and the Core's current module and controller
    function planHash(Inputs memory i) public view returns (bytes32) {
        ICore core = ICore(payable(i.core));
        return keccak256(
            abi.encode(
                block.chainid,
                i.core,
                i.treasury,
                i.controllerV2,
                keccak256(bytes(i.step)),
                i.minimumWorkingBalance,
                i.poolFee,
                i.poolTickSpacing,
                i.poolHooks,
                i.expectedSpot,
                i.quote,
                core.balanceModule(),
                core.controller()
            )
        );
    }

    /// @notice the preview, the owner call (broadcast only with `send`, else simulated under the owner) and the
    /// readback. a test calls it with its own inputs
    function execute(Inputs memory i, bool send) public {
        ICore core = ICore(payable(i.core));
        bytes32 step = keccak256(bytes(i.step));
        _reset();
        _preview(core, i, step);
        _info("preview: plan hash (PHASE2_WIRE_PLAN_HASH of a send)", vm.toString(planHash(i)));
        _print(string.concat("phase 2 wire preview: ", i.step));
        _require();
        _reset();
        if (send) {
            vm.startBroadcast();
            (, address signer,) = vm.readCallers();
            if (signer != core.owner()) revert NotOwner(core.owner(), signer);
        } else {
            console.log("no send: SEND is not 1, the owner call is simulated only");
            vm.startPrank(core.owner());
        }
        _apply(core, i, step);
        if (send) vm.stopBroadcast();
        else vm.stopPrank();
        _readback(core, i, step);
        _print(string.concat(send ? "phase 2 wire readback: " : "phase 2 wire readback of the simulation: ", i.step));
        _require();
        console.log(
            string.concat(
                'record: {"chainId":',
                vm.toString(block.chainid),
                ',"block":',
                vm.toString(block.number),
                ',"step":"',
                i.step,
                '","balanceModule":"',
                vm.toString(core.balanceModule()),
                '","controller":"',
                vm.toString(core.controller()),
                '"}'
            )
        );
    }

    function _apply(ICore core, Inputs memory i, bytes32 step) private {
        if (step == keccak256("module")) {
            core.setBalanceModule(i.treasury);
        } else if (step == keccak256("controller")) {
            core.setController(i.controllerV2);
        } else if (step == keccak256("launch")) {
            IPhase2BalanceTreasury(i.treasury).setSwitches(true, true, false);
        } else if (step == keccak256("minimum")) {
            IPhase2BalanceTreasury(i.treasury).setMinimumWorkingBalance(i.minimumWorkingBalance);
        } else if (step == keccak256("pool")) {
            IControllerV2(i.controllerV2).setBalancePoolKey(_key(core, i), i.expectedSpot);
        } else if (step == keccak256("quote")) {
            IControllerV2(i.controllerV2).setQuote(i.quote);
        }
    }

    function _key(ICore core, Inputs memory i) private view returns (IControllerV2.PoolKey memory) {
        return IControllerV2.PoolKey({
            currency0: IControllerV2.Currency.wrap(address(0)),
            currency1: IControllerV2.Currency.wrap(core.balanceToken()),
            fee: i.poolFee,
            tickSpacing: i.poolTickSpacing,
            hooks: i.poolHooks
        });
    }

    function _preview(ICore core, Inputs memory i, bytes32 step) private {
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _code("preview: Core has code", i.core);
        _info("preview: owner", vm.toString(core.owner()));
        _info("preview: Core balanceModule / controller", _two(core.balanceModule(), core.controller()));
        _check("preview: Core not paused or retired", !core.paused() && !core.retired(), "paused or retired");
        if (step == keccak256("module")) {
            _code("preview: treasury has code", i.treasury);
            IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
            _eq("preview: treasury core is the Core", t.core(), i.core);
            _check("preview: balance module not locked", !core.balanceModuleLocked(), "balanceModuleLocked");
            _check("preview: module changes", core.balanceModule() != i.treasury, "already selected");
        } else if (step == keccak256("controller")) {
            _code("preview: ControllerV2 has code", i.controllerV2);
            _eq("preview: ControllerV2 CORE is the Core", IControllerV2(i.controllerV2).CORE(), i.core);
            _check("preview: controller not locked", !core.controllerLocked(), "controllerLocked");
            _check("preview: controller changes", core.controller() != i.controllerV2, "already selected");
        } else if (step == keccak256("launch")) {
            IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
            _eq("preview: treasury is the Core's module", core.balanceModule(), i.treasury);
            _check("preview: treasury not migrated", !t.migrated(), "migrated");
            _check("preview: CC redemption stays off at launch", !t.ccRedemptionEnabled(), "redemption on");
        } else if (step == keccak256("minimum")) {
            _code("preview: treasury has code", i.treasury);
            _info("preview: minimum working balance", vm.toString(i.minimumWorkingBalance));
        } else if (step == keccak256("pool")) {
            _code("preview: ControllerV2 has code", i.controllerV2);
            _check("preview: Core has a balance token", core.balanceToken() != address(0), "no module");
            _check("preview: expected spot given", i.expectedSpot != 0, "BALANCE_POOL_EXPECTED_SPOT");
            _info(
                "preview: pool fee / tick spacing / hooks",
                string.concat(
                    vm.toString(uint256(i.poolFee)),
                    " / ",
                    vm.toString(int256(i.poolTickSpacing)),
                    " / ",
                    vm.toString(i.poolHooks)
                )
            );
        } else if (step == keccak256("quote")) {
            _code("preview: ControllerV2 has code", i.controllerV2);
            _check("preview: min liquidity given", i.quote.minLiquidity != 0, "QUOTE_MIN_LIQUIDITY");
            _check(
                "preview: ControllerV2 pool key set",
                IControllerV2(i.controllerV2).balancePoolKeySet(),
                "pool step first"
            );
        } else {
            _check("preview: step is module, controller, launch, minimum, pool or quote", false, i.step);
        }
    }

    function _readback(ICore core, Inputs memory i, bytes32 step) private {
        if (step == keccak256("module")) {
            _eq("readback: Core balanceModule", core.balanceModule(), i.treasury);
            _eq("readback: Core balanceToken", core.balanceToken(), IPhase2BalanceTreasury(i.treasury).balanceToken());
            _check("readback: treasury selected", IPhase2BalanceTreasury(i.treasury).selected(), "selected()");
        } else if (step == keccak256("controller")) {
            _eq("readback: Core controller", core.controller(), i.controllerV2);
            (bool ready,,) = IControllerV2(i.controllerV2).nextPage();
            _info("readback: ControllerV2 nextPage ready", vm.toString(ready));
        } else if (step == keccak256("launch")) {
            IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
            _check(
                "readback: switches conversion on, working payments on, CC redemption off",
                t.conversionEnabled() && t.workingPaymentsEnabled() && !t.ccRedemptionEnabled(),
                "setSwitches"
            );
            _info(
                "readback: conversionReady / transfersReady / available",
                string.concat(
                    vm.toString(t.conversionReady()),
                    " / ",
                    vm.toString(t.transfersReady()),
                    " / ",
                    vm.toString(t.available())
                )
            );
        } else if (step == keccak256("minimum")) {
            _eq(
                "readback: minimumWorkingBalance",
                IPhase2BalanceTreasury(i.treasury).minimumWorkingBalance(),
                i.minimumWorkingBalance
            );
        } else if (step == keccak256("pool")) {
            IControllerV2 c = IControllerV2(i.controllerV2);
            _check("readback: pool key set", c.balancePoolKeySet(), "balancePoolKeySet()");
            (uint256 spot, bool ok) = c.spotPrice();
            _check("readback: spot prices", ok && spot != 0, vm.toString(spot));
            _info("readback: reference price", vm.toString(c.referencePrice()));
        } else if (step == keccak256("quote")) {
            (uint32 rate, uint16 stepBps, uint16 tol, uint32 stale, uint32 minSeconds, uint128 minLiq) =
                IControllerV2(i.controllerV2).quote();
            _check(
                "readback: quote equals the inputs",
                rate == i.quote.referenceRateBpsPerHour && stepBps == i.quote.referenceStepBps && tol == i.quote.tolBps
                    && stale == i.quote.referenceMaxStale && minSeconds == i.quote.referenceMinSeconds
                    && minLiq == i.quote.minLiquidity,
                "quote()"
            );
        }
    }

    function _two(address a, address b) private pure returns (string memory) {
        return string.concat(vm.toString(a), " / ", vm.toString(b));
    }
}
