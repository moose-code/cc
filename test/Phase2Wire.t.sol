// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveValueBase} from "./utils/LiveValueBase.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {CreditSale, Quote} from "../src/interfaces/Interfaces.sol";
import {Phase2Wire} from "../script/Phase2Wire.s.sol";
import {Report} from "../script/Report.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev the script with its environment replaced by arguments
contract Phase2WireProbe is Phase2Wire {
    function go(Inputs memory i) external {
        execute(i, false);
    }
}

/// the stage B and C owner sends through the wiring script on the pinned fork: module and controller selection, the
/// launch switches, the minimum working balance, and ControllerV2's pool key and quote on the value mode pool
contract Phase2WireTest is LiveValueBase {
    using StateLibrary for IPoolManager;

    IPhase2BalanceTreasury internal t;
    IControllerV2 internal c2;
    Phase2WireProbe internal wire;

    function setUp() public override {
        super.setUp();
        // the treasury binds the live BALANCE token (its transfers are open at the pin); the value mode pool that the
        // pool and quote steps read stays the mock xt pool from LiveValueBase, which the tests push and drain
        address policy = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = IPhase2BalanceTreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), liveBalanceToken, policy, address(0))
            )
        );
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: ctl.creditSpreadBps(),
            startBps: ctl.creditStartBps()
        });
        Quote memory none;
        c2 = IControllerV2(
            vm.deployCode(
                "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(15_000), uint32(3_600))
            )
        );
        wire = new Phase2WireProbe();
    }

    function _inputs(string memory step) internal view returns (Phase2Wire.Inputs memory i) {
        i.core = address(core);
        i.treasury = address(t);
        i.controllerV2 = address(c2);
        i.step = step;
        i.quote = Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 100,
            referenceMaxStale: 1_800,
            referenceMinSeconds: 600,
            minLiquidity: 1e18
        });
    }

    // promise: decision 258 the wiring script selects the treasury and ControllerV2 on the Core, turns the launch switches on with CC redemption off, sets the minimum working balance, each with a readback, and its plan hash follows the Core's pointers
    function test_wiresModuleControllerLaunchAndMinimum() public {
        bytes32 before = wire.planHash(_inputs("module"));
        wire.go(_inputs("module"));
        assertEq(core.balanceModule(), address(t));
        assertTrue(t.selected());
        assertTrue(wire.planHash(_inputs("module")) != before, "the hash follows the module pointer");
        Phase2Wire.Inputs memory again = _inputs("module");
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: module changes"));
        wire.go(again);
        wire.go(_inputs("controller"));
        assertEq(core.controller(), address(c2));
        wire.go(_inputs("launch"));
        assertTrue(t.conversionEnabled());
        assertTrue(t.workingPaymentsEnabled());
        assertFalse(t.ccRedemptionEnabled());
        Phase2Wire.Inputs memory m = _inputs("minimum");
        m.minimumWorkingBalance = 5 ether;
        wire.go(m);
        assertEq(t.minimumWorkingBalance(), 5 ether);
        Phase2Wire.Inputs memory bad = _inputs("burn");
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector, "preview: step is module, controller, launch, minimum, pool or quote"
            )
        );
        wire.go(bad);
    }

    // promise: decision 258 the wiring script sets ControllerV2's pool key from the Core's balance token with the expected spot and then its quote, refusing the quote before the pool key and a zero liquidity threshold
    function test_wiresPoolKeyAndQuoteOnTheValueModePool() public {
        // the value mode pool is the fixture's balance token: the fixture module stays selected for this step
        _setController(address(c2));
        Phase2Wire.Inputs memory q = _inputs("quote");
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: ControllerV2 pool key set"));
        wire.go(q);
        Phase2Wire.Inputs memory p = _inputs("pool");
        p.poolFee = 3000;
        p.poolTickSpacing = 60;
        p.poolHooks = address(0);
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        p.expectedSpot = _spotOf(sp);
        wire.go(p);
        assertTrue(c2.balancePoolKeySet());
        q = _inputs("quote");
        q.quote.minLiquidity = 0;
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: min liquidity given"));
        wire.go(q);
        wire.go(_inputs("quote"));
        (uint32 rate,,,,,) = c2.quote();
        assertEq(rate, 1_200);
    }
}
