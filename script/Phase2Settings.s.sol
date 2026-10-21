// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "./SettingsFields.sol";

/// @notice the stage B settings change of docs/reviews/PHASE2-PLAN-fd85ba5-2026-10-20.md section 8: the live 39 field
/// `Settings` with exactly `saleToBuybackBps` 0, `feeToRedeemBurnBps` 0, `redeemBurnBps` 0 and `balanceDiscountBps`
/// `PHASE2_BALANCE_DISCOUNT_BPS` (default 2,000: the posted Credit to BALANCE payout is 80 percent of rating,
/// decision 254), every other field unchanged, and `setCreditCostToPotBps(10000)`. the approach is script/SetSettings.s.sol's (live struct, patch,
/// bounds, before and after table, calldata, a simulated owner call, nothing sent without SEND=1 and --broadcast as the
/// owner) with the patch fixed in code: `SETTINGS_PATCH` and every `SET_<field>` variable are refused, and
/// `balanceBidOn` and `valueModeOn` in particular are stage C and go through SetSettings with the hazard check of
/// docs/RUNBOOK.md. the two legacy pots `ethToBuyback` and `ethRedeemBurn` keep their path: this change stops the
/// inflow and does not return them to `ethPot`.
/// `CORE=0x... forge script script/Phase2Settings.s.sol --rpc-url $MAINNET_RPC_URL` (add `SEND=1 --broadcast` and the
/// owner signer to send)
contract Phase2Settings is Script {
    /// @dev the patched struct is outside the bounds the Core enforces, `field` is the first one out
    error OutOfBounds(bytes32 field);
    /// @dev the signer is not the Core owner
    error NotOwner(address owner, address signer);
    /// @dev `balanceBidOn` or `valueModeOn` was named: those are stage C, through SetSettings
    error StageCField(string name);
    /// @dev `PHASE2_BALANCE_DISCOUNT_BPS` above the Core's 9,999 bound
    error BadDiscount(uint256 given);
    /// @dev a `SET_<field>` or `SETTINGS_PATCH` override was given: this script applies exactly the phase 2 patch
    error UnexpectedOverride(string name);

    uint16 internal constant CREDIT_COST_TO_POT_BPS = 10_000;

    string internal constant TUPLE =
        "(uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16,uint24,uint32,uint96,uint16,uint16,uint16,uint16,uint32,uint32,uint32,uint32,uint64,uint32,bool,uint16,uint16)";

    struct Preview {
        Settings live;
        Settings next;
        bool settingsChanged;
        uint16 liveCostToPot;
        bool costChanged;
    }

    function run() external {
        _refuseOverrides();
        ICore core = ICore(payable(_core()));
        Preview memory p = preview(core);
        if (!_send()) {
            console.log("nothing sent. add SEND=1 and --broadcast with the owner as signer to send");
            return;
        }
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        if (signer != core.owner()) revert NotOwner(core.owner(), signer);
        applyPatch(core, p);
        vm.stopBroadcast();
        console.log("sent. read it back with Phase2Readback (settings rows and creditCostToPotBps)");
    }

    /// @notice the phase 2 patch: a copy of `live` with the three buyback and burn shares at zero and the 80 percent payout
    function phase2Patch(Settings memory live) internal view returns (Settings memory s) {
        s = abi.decode(abi.encode(live), (Settings));
        s.saleToBuybackBps = 0;
        s.feeToRedeemBurnBps = 0;
        s.redeemBurnBps = 0;
        uint256 discount = vm.envOr("PHASE2_BALANCE_DISCOUNT_BPS", uint256(2_000));
        if (discount > 9_999) revert BadDiscount(discount);
        s.balanceDiscountBps = uint16(discount);
    }

    /// @notice reads the live struct, patches it, checks the bounds, prints the changed rows, the pots and the calldata,
    /// and simulates both owner calls on a snapshot
    function preview(ICore core) internal returns (Preview memory p) {
        p.live = core.settings();
        p.next = phase2Patch(p.live);
        bytes32 bad = SettingsBounds.firstViolation(p.next);
        if (bad != 0) revert OutOfBounds(bad);
        p.settingsChanged = keccak256(abi.encode(p.live)) != keccak256(abi.encode(p.next));
        p.liveCostToPot = core.creditCostToPotBps();
        p.costChanged = p.liveCostToPot != CREDIT_COST_TO_POT_BPS;
        _table(p.live, p.next);
        _pots(core);
        console.log(
            string.concat(
                "creditCostToPotBps | ",
                vm.toString(uint256(p.liveCostToPot)),
                " | ",
                vm.toString(uint256(CREDIT_COST_TO_POT_BPS)),
                p.costChanged ? " | changes" : " | unchanged, setCreditCostToPotBps is not needed"
            )
        );
        _calldata(core, p);
        _simulate(core, p);
    }

    /// @notice the two owner calls, in the stage B order: the credit cost share first, then the settings
    function applyPatch(ICore core, Preview memory p) internal {
        if (p.costChanged) core.setCreditCostToPotBps(CREDIT_COST_TO_POT_BPS);
        if (p.settingsChanged) core.setSettings(p.next);
    }

    /// @dev the owner calls on a snapshot, so a Core that refuses them stops the preview before anything is sent
    function _simulate(ICore core, Preview memory p) private {
        uint256 snap = vm.snapshotState();
        vm.startPrank(core.owner());
        applyPatch(core, p);
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// @dev only the fields the patch changes
    function _table(Settings memory a, Settings memory b) private pure {
        console.log("phase 2 settings patch: field | live | new (every other field of the 39 is kept as read)");
        bytes32[39] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            uint256 x = SettingsFields.get(a, i);
            uint256 y = SettingsFields.get(b, i);
            if (x == y) continue;
            console.log(string.concat("* ", _name(names[i]), " | ", vm.toString(x), " | ", vm.toString(y)));
        }
    }

    /// @dev the legacy pots, which this change does not touch
    function _pots(ICore core) private view {
        console.log(
            string.concat(
                "legacy pots (wei): ethToBuyback ",
                vm.toString(core.ethToBuyback()),
                " | ethRedeemBurn ",
                vm.toString(core.ethRedeemBurn())
            )
        );
        console.log(
            "both pots keep their path (the coin buyback and the redeem burn); this change stops their inflow and does not return them to ethPot"
        );
    }

    function _calldata(ICore core, Preview memory p) private pure {
        console.log("setCreditCostToPotBps calldata");
        console.logBytes(abi.encodeCall(ICore.setCreditCostToPotBps, (CREDIT_COST_TO_POT_BPS)));
        console.log(
            string.concat(
                "cast send ",
                vm.toString(address(core)),
                ' "setCreditCostToPotBps(uint16)" ',
                vm.toString(uint256(CREDIT_COST_TO_POT_BPS))
            )
        );
        console.log("setSettings calldata");
        console.logBytes(abi.encodeCall(ICore.setSettings, (p.next)));
        console.log(
            string.concat(
                "cast send ", vm.toString(address(core)), " \"setSettings(", TUPLE, ")\" \"", _tuple(p.next), "\""
            )
        );
        if (!p.settingsChanged) console.log("the settings already carry the patch, setSettings is not needed");
    }

    /// @dev refuses any override: the two stage C switches by name, everything else as unexpected
    function _refuseOverrides() internal view {
        string[] memory given = _overrides();
        for (uint256 i; i < given.length; ++i) {
            bytes32 h = keccak256(bytes(given[i]));
            if (h == keccak256("balanceBidOn") || h == keccak256("valueModeOn")) revert StageCField(given[i]);
            revert UnexpectedOverride(given[i]);
        }
    }

    /// @dev the names of the `SET_<field>` variables found in the environment, and "SETTINGS_PATCH" when that is set. a
    /// test overrides it
    function _overrides() internal view virtual returns (string[] memory found) {
        bytes32[39] memory names = SettingsFields.names();
        string[] memory all = new string[](SettingsFields.N + 1);
        uint256 n;
        for (uint256 i; i < SettingsFields.N; ++i) {
            string memory name = _name(names[i]);
            if (vm.envExists(string.concat("SET_", name))) all[n++] = name;
        }
        if (vm.envExists("SETTINGS_PATCH")) all[n++] = "SETTINGS_PATCH";
        found = new string[](n);
        for (uint256 i; i < n; ++i) {
            found[i] = all[i];
        }
    }

    /// @dev the Core to change (CORE) and the broadcast flag (SEND=1). a test overrides them
    function _core() internal view virtual returns (address) {
        return vm.envAddress("CORE");
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }

    function _name(bytes32 b) private pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 j; j < n; ++j) {
            out[j] = b[j];
        }
        return string(out);
    }

    /// @dev the struct as the tuple literal `cast send` takes (the three booleans are fields 11, 12 and 36)
    function _tuple(Settings memory s) private pure returns (string memory out) {
        out = "(";
        for (uint256 i; i < SettingsFields.N; ++i) {
            uint256 v = SettingsFields.get(s, i);
            out = string.concat(
                out, i == 0 ? "" : ",", i == 11 || i == 12 || i == 36 ? (v == 1 ? "true" : "false") : vm.toString(v)
            );
        }
        out = string.concat(out, ")");
    }
}
