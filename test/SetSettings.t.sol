// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Sale, CreditSale} from "../src/interfaces/Interfaces.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {SetSettings, ICoreOwner} from "../script/SetSettings.s.sol";

/// @dev the script with its environment replaced by fields, so parallel tests never share an environment variable
contract SetSettingsProbe is SetSettings {
    address internal core_;
    string internal patch_;
    string[] internal names_;
    uint256[] internal values_;

    function configure(address core, string memory patch) external {
        core_ = core;
        patch_ = patch;
    }

    function single(string memory name, uint256 v) external {
        names_.push(name);
        values_.push(v);
    }

    function _core() internal view override returns (address) {
        return core_;
    }

    function _patch() internal view override returns (string memory) {
        return patch_;
    }

    function _single(string memory name) internal view override returns (bool, uint256) {
        for (uint256 i; i < names_.length; ++i) {
            if (keccak256(bytes(names_[i])) == keccak256(bytes(name))) return (true, values_[i]);
        }
        return (false, 0);
    }

    function warnRateCap(uint256 rateCap) external view returns (bool) {
        return _warnRateCap(ICoreOwner(core_), rateCap);
    }

    function previewController(IControllerV1 c, address owner_) external {
        ICoreOwner core = ICoreOwner(core_);
        Settings memory live = core.settings();
        ControllerChanges memory changes = _prepareController(c, live, live.saleFloorBps);
        _previewBatch(core, live, false, 0, c, changes);
    }

    function applyCombined(IControllerV1 c, Settings memory next) external {
        ICoreOwner core = ICoreOwner(core_);
        ControllerChanges memory changes = _prepareController(c, next, core.settings().saleFloorBps);
        _previewBatch(core, next, true, 0, c, changes);
        vm.startPrank(core.owner());
        _applyBatch(core, next, true, 0, c, changes);
        vm.stopPrank();
    }

    function controllerChanges(IControllerV1 c) external view returns (bool changed) {
        (,, changed,) = _controllerChanges(c);
    }

    function applyTo(Settings memory s) external view returns (Settings memory) {
        return _apply(s);
    }

    /// @dev whether `_apply` left the struct it was handed untouched (the before side of the table)
    function leavesTheInputAlone(Settings memory live) external view returns (bool) {
        bytes32 before_ = keccak256(abi.encode(live));
        _apply(live);
        return keccak256(abi.encode(live)) == before_;
    }
}

/// @notice `script/SetSettings.s.sol` on the fixture core: the overrides touch only the fields they name, bad input is
/// refused, a dry run sends nothing
contract SetSettingsTest is Fixture {
    SetSettingsProbe internal probe;

    function setUp() public override {
        super.setUp();
        probe = new SetSettingsProbe();
        probe.configure(address(core), "");
    }

    /// @dev how many of the 24 fields differ between two structs, and whether field `i` is among them
    function _diff(Settings memory a, Settings memory b) internal pure returns (uint256 n, uint256 first) {
        first = type(uint256).max;
        for (uint256 i; i < SettingsFields.N; ++i) {
            if (SettingsFields.get(a, i) == SettingsFields.get(b, i)) continue;
            if (n++ == 0) first = i;
        }
    }

    // promise: RUNBOOK the SetSettings owner command changes the fields it names
    function test_oneVariableChangesOneField() public {
        Settings memory live = core.settings();
        probe.single("saleFloorBps", 8_000);
        Settings memory out = probe.applyTo(live);
        (uint256 n, uint256 first) = _diff(live, out);
        assertEq(n, 1);
        assertEq(first, 5, "saleFloorBps is the 6th field");
        assertEq(out.saleFloorBps, 8_000);
    }

    // promise: RUNBOOK the SetSettings owner command keeps the other fields at their live value
    /// the fields you do not name keep the live value even after the owner changed them
    function test_leavesTheOtherFieldsAtTheirLiveValue() public {
        Settings memory s = core.settings();
        s.saleToBuybackBps = 3_000;
        s.buybackSlice = 1 ether;
        _setSettings(s);
        probe.single("keeperFee", 0.001 ether);
        Settings memory out = probe.applyTo(core.settings());
        (uint256 n,) = _diff(s, out);
        assertEq(n, 1);
        assertEq(out.saleToBuybackBps, 3_000);
        assertEq(out.buybackSlice, 1 ether);
        assertEq(out.keeperFee, 0.001 ether);
    }

    // promise: RUNBOOK the SetSettings owner command refuses an unknown field or a too wide value
    function test_unknownFieldAndTooWideValue() public {
        Settings memory live = core.settings();
        probe.configure(address(core), '{"saleFloorBpz": 8000}');
        vm.expectRevert(abi.encodeWithSelector(SetSettings.UnknownField.selector, "saleFloorBpz"));
        probe.applyTo(live);
        probe.configure(address(core), "");
        probe.single("dropPerCreditBps", 65_536);
        vm.expectRevert(abi.encodeWithSelector(SetSettings.ValueTooWide.selector, "dropPerCreditBps"));
        probe.applyTo(live);
    }

    // promise: RUNBOOK the SetSettings owner command refuses a value outside the bounds
    /// run() refuses a value outside the bounds before it prints a calldata
    function test_runRefusesOutOfBounds() public {
        probe.single("spendCapBps", 0);
        vm.expectRevert(abi.encodeWithSelector(SetSettings.OutOfBounds.selector, bytes32("spendCapBps")));
        probe.run();
    }

    // promise: RUNBOOK a dry run of an owner command sends nothing
    /// a dry run (no SEND) prints and changes nothing, the owner can send what it printed
    function test_dryRunSendsNothingAndTheCalldataWorks() public {
        Settings memory live = core.settings();
        probe.single("saleFloorBps", 8_000);
        probe.run();
        assertEq(abi.encode(core.settings()), abi.encode(live), "a dry run changes nothing");
        Settings memory next = probe.applyTo(live);
        vm.prank(owner);
        (bool ok,) = address(core).call(abi.encodeCall(core.setSettings, (next)));
        assertTrue(ok, "the printed calldata is accepted by the core");
        assertEq(core.settings().saleFloorBps, 8_000);
    }

    // promise: previewing controller settings never consumes the changes the subsequent broadcast must send
    function test_controllerPreviewRestoresStateAndKeepsChangePlanned() public {
        uint256 before_ = ctl.anchorMoveBps();
        probe.single("anchorMoveBps", 10_000);
        probe.previewController(ctl, owner);
        assertEq(ctl.anchorMoveBps(), before_);
        assertTrue(probe.controllerChanges(ctl));
    }

    // promise: each new field is independently patchable without changing adjacent ABI values
    function test_newFieldsAndTypedWidths() public {
        Settings memory live = core.settings();
        probe.configure(
            address(core),
            '{"spendCapBps":50,"bucketSeconds":100,"balanceBidCapBps":20000,"idleStepSeconds":30,"sniperSeconds":0}'
        );
        Settings memory next = probe.applyTo(live);
        assertEq(next.spendCapBps, 50);
        assertEq(next.bucketSeconds, 100);
        assertEq(next.balanceBidCapBps, 20_000);
        assertEq(next.idleStepSeconds, 30);
        assertEq(next.sniperSeconds, 0);
        assertEq(next.climbMultiplierCapBps, live.climbMultiplierCapBps);
        probe.configure(address(core), "");
        probe.single("bucketSeconds", uint256(type(uint32).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(SetSettings.ValueTooWide.selector, "bucketSeconds"));
        probe.applyTo(live);
    }

    // promise: coordinated floor/start edits are previewed and applied in a valid order in both directions
    function test_combinedFloorAndMarkupUpdatesBothDirections() public {
        probe.single("markupBps", 22_000);
        Settings memory next = core.settings();
        next.saleFloorBps = 20_000;
        probe.applyCombined(ctl, next);
        assertEq(core.settings().saleFloorBps, 20_000);
        assertEq(ctl.markupBps(), 22_000);
        probe = new SetSettingsProbe();
        probe.configure(address(core), "");
        probe.single("markupBps", 12_000);
        next.saleFloorBps = 10_000;
        probe.applyCombined(ctl, next);
        assertEq(core.settings().saleFloorBps, 10_000);
        assertEq(ctl.markupBps(), 12_000);
    }
}
