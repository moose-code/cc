// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "./SettingsFields.sol";

/// @notice the stage B settings change of docs/reviews/PHASE2-PLAN-fd85ba5-2026-10-20.md section 8: the live 39 field
/// `Settings` with exactly `balanceDiscountBps` `PHASE2_BALANCE_DISCOUNT_BPS` (default 2,000: the posted Credit to
/// BALANCE payout is 80 percent of rating, decision 254), and with `PHASE2_ARTIST=<split>` the split route of decision
/// 255 (`setArtist(split)`, `buyToArtistBps` 300, `saleToArtistBps` 300, `saleToOperatorBps` 0), every other field
/// unchanged. `saleToBuybackBps`, `feeToRedeemBurnBps`, `redeemBurnBps` and `creditCostToPotBps` stay at their live
/// values through stage C (decision 262, superseding decision 247 for launch). the approach is script/SetSettings.s.sol's (live struct, patch,
/// bounds, before and after table, calldata, a simulated owner call, nothing sent without SEND=1 and --broadcast as the
/// owner) with the patch fixed in code: `SETTINGS_PATCH` and every `SET_<field>` variable are refused, and
/// `balanceBidOn` and `valueModeOn` in particular are stage C and go through SetSettings with the hazard check of
/// docs/RUNBOOK.md. the two pots `ethToBuyback` and `ethRedeemBurn` keep their path and their inflow.
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
    /// @dev the patched payout, royalty and earmark leave no working gain on a BALANCE funded Credit;
    /// `ALLOW_NONPOSITIVE_MARGIN=1` records the owner's approval
    error NonPositiveMargin(int256 marginBps);

    uint256 internal constant BPS = 10_000;

    string internal constant TUPLE =
        "(uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16,uint24,uint32,uint96,uint16,uint16,uint16,uint16,uint32,uint32,uint32,uint32,uint64,uint32,bool,uint16,uint16)";

    /// @dev the royalty fields of decision 255 were asked for without the split address that receives them: a 3 percent
    /// royalty to the bare artist would overpay the artist and pay the operator nothing
    error SplitAddressRequired();
    /// @dev `PHASE2_ARTIST` has no code or is the current artist already with other fields unchanged
    error BadSplit(address given);

    struct Preview {
        /// the split that becomes the artist, zero for no change
        address split;
        bool artistChanged;
        Settings live;
        Settings next;
        bool settingsChanged;
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
        console.log("sent. read it back with Phase2Readback (artist and settings rows)");
    }

    /// @notice the phase 2 patch: a copy of `live` with the 80 percent payout and the split's royalty fields; the buyback
    /// and burn shares are kept as read
    function phase2Patch(Settings memory live) internal view returns (Settings memory s) {
        s = abi.decode(abi.encode(live), (Settings));
        uint256 discount = _discountBps();
        if (discount > 9_999) revert BadDiscount(discount);
        s.balanceDiscountBps = uint16(discount);
        // the split route (decision 255): the artist address becomes a splits.org split paying 5/6 to the artist and 1/6
        // to the operator, and every artist flow carries 3 percent, so the artist keeps 2.5 percent and the operator
        // gets 0.5 percent on purchases as on sales; the separate sale operator cut folds into the split
        if (_split() != address(0)) {
            s.buyToArtistBps = uint16(vm.envOr("PHASE2_BUY_TO_ARTIST_BPS", uint256(300)));
            s.saleToArtistBps = uint16(vm.envOr("PHASE2_SALE_TO_ARTIST_BPS", uint256(300)));
            s.saleToOperatorBps = uint16(vm.envOr("PHASE2_SALE_TO_OPERATOR_BPS", uint256(0)));
        } else if (
            vm.envExists("PHASE2_BUY_TO_ARTIST_BPS") || vm.envExists("PHASE2_SALE_TO_ARTIST_BPS")
                || vm.envExists("PHASE2_SALE_TO_OPERATOR_BPS")
        ) {
            revert SplitAddressRequired();
        }
    }

    /// @dev the split that becomes the Core's artist (`PHASE2_ARTIST`), zero when the artist is left as it is. a test
    /// overrides it
    function _split() internal view virtual returns (address) {
        return vm.envOr("PHASE2_ARTIST", address(0));
    }

    /// @dev the posted payout discount (`PHASE2_BALANCE_DISCOUNT_BPS`, default 2,000). a test overrides it
    function _discountBps() internal view virtual returns (uint256) {
        return vm.envOr("PHASE2_BALANCE_DISCOUNT_BPS", uint256(2_000));
    }

    /// @dev the owner's recorded approval of a non positive margin (`ALLOW_NONPOSITIVE_MARGIN=1`). a test overrides it
    function _allowNonPositiveMargin() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_NONPOSITIVE_MARGIN", uint256(0)) == 1;
    }

    /// @notice reads the live struct, patches it, checks the bounds, prints the changed rows, the pots and the calldata,
    /// and simulates both owner calls on a snapshot
    function preview(ICore core) internal returns (Preview memory p) {
        p.live = core.settings();
        p.next = phase2Patch(p.live);
        p.split = _split();
        if (p.split != address(0)) {
            if (p.split.code.length == 0) revert BadSplit(p.split);
            p.artistChanged = core.artist() != p.split;
            console.log(
                string.concat(
                    "artist | ",
                    vm.toString(core.artist()),
                    " | ",
                    vm.toString(p.split),
                    p.artistChanged ? " | changes: setArtist(split), every artist flow pays the split" : " | unchanged"
                )
            );
        }
        bytes32 bad = SettingsBounds.firstViolation(p.next);
        if (bad != 0) revert OutOfBounds(bad);
        p.settingsChanged = keccak256(abi.encode(p.live)) != keccak256(abi.encode(p.next));
        _table(p.live, p.next);
        _kept(core, p.next);
        _pots(core);
        _margin(core, p.next);
        _calldata(core, p);
        _simulate(core, p);
    }

    /// @notice the owner calls, in the stage B order: the split as artist first (so no block pays 3 percent to the bare
    /// artist), then the settings
    function applyPatch(ICore core, Preview memory p) internal {
        if (p.artistChanged) core.setArtist(p.split);
        if (p.settingsChanged) core.setSettings(p.next);
    }

    /// @dev the working gain per 100 BALANCE funded points under the patch: the rating less the posted payout, the
    /// purchase royalty (a share of the payout) and the treasury's claim earmark (the selected module's live value, else
    /// the deploy default of 1,000). ETH funded Credits and inventory already held carry a different cost. a non
    /// positive margin stops the preview unless `ALLOW_NONPOSITIVE_MARGIN=1`
    function _margin(ICore core, Settings memory next) private view {
        uint256 earmark = 1_000;
        string memory source = "deploy default, no module selected";
        address module = core.balanceModule();
        if (module.code.length != 0) {
            (bool ok, bytes memory ret) = module.staticcall(abi.encodeWithSignature("conversionToClaimBps()"));
            if (ok && ret.length >= 32) {
                earmark = abi.decode(ret, (uint256));
                source = "the selected module";
            }
        }
        uint256 payout = BPS - next.balanceDiscountBps;
        uint256 royalty = payout * next.buyToArtistBps / BPS;
        int256 margin = int256(BPS) - int256(payout) - int256(royalty) - int256(earmark);
        console.log(
            string.concat(
                "margin per 100 BALANCE funded points | payout ",
                vm.toString(payout),
                " | royalty ",
                vm.toString(royalty),
                " | earmark ",
                vm.toString(earmark),
                " (",
                source,
                ") | working gain bps ",
                margin < 0 ? string.concat("-", vm.toString(uint256(-margin))) : vm.toString(uint256(margin)),
                " (ETH funded and inherited inventory differ)"
            )
        );
        if (margin <= 0 && !_allowNonPositiveMargin()) revert NonPositiveMargin(margin);
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

    /// @dev the buy and burn settings and the credit cost share this patch keeps at their live values (decision 262)
    function _kept(ICore core, Settings memory next) private view {
        console.log(
            string.concat(
                "kept (decision 262): saleToBuybackBps ",
                vm.toString(uint256(next.saleToBuybackBps)),
                " | feeToRedeemBurnBps ",
                vm.toString(uint256(next.feeToRedeemBurnBps)),
                " | redeemBurnBps ",
                vm.toString(uint256(next.redeemBurnBps)),
                " | creditCostToPotBps ",
                vm.toString(uint256(core.creditCostToPotBps())),
                " | unchanged"
            )
        );
    }

    /// @dev the two pots, which this change does not touch
    function _pots(ICore core) private view {
        console.log(
            string.concat(
                "pots (wei): ethToBuyback ",
                vm.toString(core.ethToBuyback()),
                " | ethRedeemBurn ",
                vm.toString(core.ethRedeemBurn())
            )
        );
        console.log(
            "both pots keep their path (the coin buyback and the redeem burn) and their inflow; this change does not touch them"
        );
    }

    function _calldata(ICore core, Preview memory p) private pure {
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
