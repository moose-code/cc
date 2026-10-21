// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Report} from "../script/Report.sol";
import {Phase2Deploy} from "../script/Phase2Deploy.s.sol";
import {Phase2Readback} from "../script/Phase2Readback.s.sol";
import {Phase2Settings} from "../script/Phase2Settings.s.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";

/// @dev the deploy script with its environment replaced by arguments and `send` false
contract Phase2DeployProbe is Phase2Deploy {
    function deploy(Inputs memory i) external returns (Result memory) {
        return deployPhase2(i, false);
    }
}

/// @dev the readback rows on given addresses, returning the failed names instead of reverting
contract Phase2ReadbackProbe is Phase2Readback {
    function read(address core, address treasury, address controllerV2) external returns (string memory failed) {
        _reset();
        phase2Readback(core, treasury, controllerV2);
        (failed,) = _failed();
    }
}

/// @dev the settings script with its environment replaced by fields
contract Phase2SettingsProbe is Phase2Settings {
    address internal core_;
    string[] internal forced_;

    function configure(address core) external {
        core_ = core;
    }

    function force(string memory name) external {
        forced_.push(name);
    }

    function previewOn() external returns (Preview memory) {
        return preview(ICore(payable(core_)));
    }

    function applyAsOwner() external {
        ICore core = ICore(payable(core_));
        Preview memory p = preview(core);
        vm.startPrank(core.owner());
        applyPatch(core, p);
        vm.stopPrank();
    }

    function refuse() external view {
        _refuseOverrides();
    }

    function _core() internal view override returns (address) {
        return core_;
    }

    function _overrides() internal view override returns (string[] memory) {
        return forced_;
    }
}

/// @notice the phase 2 operator scripts on the pinned fork against the fixture Core, the real Statements and the standin
/// balance token: the stage A deploy and its readback, the readback refusals and the stage B settings patch
contract Phase2ScriptsTest is Fixture {
    Phase2BalanceTokenStandin internal token;
    Phase2DeployProbe internal deployProbe;
    Phase2ReadbackProbe internal readback;
    Phase2SettingsProbe internal settings;

    function setUp() public override {
        super.setUp();
        token = new Phase2BalanceTokenStandin();
        deployProbe = new Phase2DeployProbe();
        readback = new Phase2ReadbackProbe();
        settings = new Phase2SettingsProbe();
        settings.configure(address(core));
    }

    function _inputs() internal view returns (Phase2Deploy.Inputs memory) {
        return Phase2Deploy.Inputs({
            core: address(core),
            balanceToken: address(token),
            statementSaleMultiplierBps: 30_000,
            statementRedeemDelaySeconds: 3_600
        });
    }

    // promise: PLAN section 8 stage A the deploy script creates the three contracts disabled, bound to the Core, with the live credit sale, and its readback passes
    function test_deployCreatesTheDisabledStackAndReadbackPasses() public {
        Phase2Deploy.Result memory r = deployProbe.deploy(_inputs());
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(r.treasury);
        assertEq(t.core(), address(core));
        assertEq(t.ccToken(), core.COIN());
        assertEq(t.balanceToken(), address(token));
        assertEq(t.predecessor(), address(0));
        assertEq(t.redemptionPolicy(), r.policy);
        assertEq(t.owner(), owner);
        assertFalse(t.conversionEnabled());
        assertFalse(t.workingPaymentsEnabled());
        assertFalse(t.ccRedemptionEnabled());
        assertEq(t.claimReserve(), 0);
        assertEq(t.available(), 0);
        assertFalse(t.conversionReady());
        assertFalse(t.selected());
        IControllerV2 c = IControllerV2(r.controllerV2);
        assertEq(c.CORE(), address(core));
        assertFalse(c.statementSalesEnabled());
        assertEq(c.statementSaleMultiplierBps(), 30_000);
        assertEq(c.statementRedeemDelaySeconds(), 3_600);
        assertEq(c.creditSaleOn(), ctl.creditSaleOn());
        assertEq(c.creditWindow(), ctl.creditWindow());
        assertEq(c.creditSpreadBps(), ctl.creditSpreadBps());
        assertEq(c.creditStartBps(), ctl.creditStartBps());
        assertFalse(c.balancePoolKeySet());
        assertEq(core.controller(), address(ctl), "the deploy changes nothing on the Core");
        assertEq(core.balanceModule(), address(0));
        // the live code equals out/, and out/ equals the pins of script/Checks.sol
        assertTrue(runtimeMatchesArtifact(r.policy, "ProRataRedemptionPolicy"));
        assertTrue(runtimeMatchesArtifact(r.treasury, "Phase2BalanceTreasury"));
        assertTrue(runtimeMatchesArtifact(r.controllerV2, "ControllerV2"));
        assertEq(artifactHash("ProRataRedemptionPolicy"), BUILD_HASH_PRO_RATA_POLICY);
        assertEq(artifactHash("Phase2BalanceTreasury"), BUILD_HASH_PHASE2_TREASURY);
        assertEq(artifactHash("ControllerV2"), BUILD_HASH_CONTROLLER_V2);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "the readback script passes");
        assertEq(readback.read(address(core), r.treasury, address(0)), "", "without the controller too");
    }

    // promise: PLAN section 8 stage A the deploy preview refuses a balance token the treasury constructor would refuse, before any creation
    function test_deployRefusesAWrongBalanceToken() public {
        token.configure(makeAddr("phase2.otherStatements"), 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector, "preview: balance token statements() is the Statements contract"
            )
        );
        deployProbe.deploy(_inputs());
        token = new Phase2BalanceTokenStandin();
        token.configure(token.statements(), 6);
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: balance token decimals() is 18"));
        deployProbe.deploy(_inputs());
    }

    // promise: PLAN section 8 the readback refuses a treasury bound to another Core and altered code, and names the hazard state
    function test_readbackRefusesForeignCoreAlteredCodeAndHazard() public {
        Phase2Deploy.Result memory r = deployProbe.deploy(_inputs());
        vm.mockCall(
            r.treasury, abi.encodeCall(IPhase2BalanceTreasury.core, ()), abi.encode(makeAddr("phase2.otherCore"))
        );
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "treasury: core is the Core");
        vm.clearMockedCalls();
        uint256 snap = vm.snapshotState();
        vm.etch(r.controllerV2, hex"00");
        assertEq(
            readback.read(address(core), r.treasury, r.controllerV2),
            "controllerV2: runtime code is the compiled ControllerV2 (immutables masked)"
        );
        vm.revertToState(snap);
        // the hazard: balance bid on, value mode off and a pool key set on the live controller
        _setSwitches(true, true);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "no pool key, no hazard");
        vm.mockCall(address(ctl), abi.encodeCall(IControllerV1.balancePoolKeySet, ()), abi.encode(true));
        assertEq(
            readback.read(address(core), r.treasury, r.controllerV2),
            "hazard: balanceBidOn with valueModeOn off and a balance pool key set opens a round trip (docs/RUNBOOK.md)"
        );
    }

    // promise: PLAN section 8 stage B the settings script changes exactly saleToBuybackBps, feeToRedeemBurnBps and redeemBurnBps to 0 and creditCostToPotBps to 10000, and refuses the stage C switches
    function test_settingsPatchChangesExactlyTheThreeSharesAndTheCreditCost() public {
        // the fixture launches with feeToRedeemBurnBps 0; mainnet carries the RUNBOOK's 1,000, so set it first
        Settings memory live = core.settings();
        live.feeToRedeemBurnBps = 1_000;
        _setSettings(live);
        live = core.settings();
        assertEq(live.feeToRedeemBurnBps, 1_000);
        Phase2Settings.Preview memory p = settings.previewOn();
        uint256 changed;
        for (uint256 i; i < SettingsFields.N; ++i) {
            if (SettingsFields.get(p.live, i) != SettingsFields.get(p.next, i)) ++changed;
        }
        assertEq(changed, 3, "three fields change");
        assertEq(p.next.saleToBuybackBps, 0);
        assertEq(p.next.feeToRedeemBurnBps, 0);
        assertEq(p.next.redeemBurnBps, 0);
        assertEq(keccak256(abi.encode(p.live)), keccak256(abi.encode(live)), "the live struct is read as is");
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(live)), "the preview sends nothing");
        settings.applyAsOwner();
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(p.next)));
        assertEq(core.creditCostToPotBps(), 10_000);
        settings.force("balanceBidOn");
        vm.expectRevert(abi.encodeWithSelector(Phase2Settings.StageCField.selector, "balanceBidOn"));
        settings.refuse();
    }
}
