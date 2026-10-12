// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
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

    function test_oneVariableChangesOneField() public {
        Settings memory live = core.settings();
        probe.single("saleFloorBps", 8_000);
        Settings memory out = probe.applyTo(live);
        (uint256 n, uint256 first) = _diff(live, out);
        assertEq(n, 1);
        assertEq(first, 5, "saleFloorBps is the 6th field");
        assertEq(out.saleFloorBps, 8_000);
    }

    function test_theLiveStructIsNotChangedInPlace() public {
        probe.single("saleFloorBps", 8_000);
        assertTrue(probe.leavesTheInputAlone(core.settings()));
    }

    function test_patchTextAndPatchFile() public {
        Settings memory live = core.settings();
        probe.configure(address(core), '{"saleFloorBps": 8000, "redeemBurnBps": 3000}');
        Settings memory out = probe.applyTo(live);
        (uint256 n,) = _diff(live, out);
        assertEq(n, 2);
        assertEq(out.saleFloorBps, 8_000);
        assertEq(out.redeemBurnBps, 3_000);
        // the same patch from a file
        probe.configure(address(core), "test/data/SettingsPatch.json");
        Settings memory fromFile = probe.applyTo(live);
        assertEq(abi.encode(fromFile), abi.encode(out));
    }

    function test_singleVariableWinsOverThePatch() public {
        probe.configure(address(core), '{"saleFloorBps": 8000}');
        probe.single("saleFloorBps", 7_000);
        assertEq(probe.applyTo(core.settings()).saleFloorBps, 7_000);
    }

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

    /// run() refuses a value outside the bounds before it prints a calldata
    function test_runRefusesOutOfBounds() public {
        probe.single("saleFloorBps", 999);
        vm.expectRevert(abi.encodeWithSelector(SetSettings.OutOfBounds.selector, bytes32("saleFloorBps")));
        probe.run();
    }

    /// the rateCap row warns when the new cap sits below the live bid read or the price state
    function test_rateCapBelowTheLiveBidWarns() public {
        uint256 price = core.ethPrice();
        assertGt(price, 1, "setup: the price state is positive");
        assertTrue(probe.warnRateCap(price - 1), "a cap below the price state warns");
        assertFalse(probe.warnRateCap(price), "a cap at the price state is quiet");
        assertFalse(probe.warnRateCap(core.settings().rateCap), "the live cap is quiet");
    }

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
}
