// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Settings, Sale, CreditSale} from "../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "./SettingsFields.sol";

/// @notice the owner functions of the Core this script talks to
interface ICoreOwner {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function setSettings(Settings calldata s) external;
    function ethRate() external view returns (uint256);
    function ethPrice() external view returns (uint256);
    function setRate(uint256 rate) external;
}

/// @notice changes the settings of a live Core without touching the fields you do not name. it reads the live struct, applies
/// your overrides, checks the sanity bounds, prints a before and after table and the calldata, and sends nothing
/// unless SEND=1 and the run has `--broadcast` and a signer that is the Core owner. docs/RUNBOOK.md section 7.
///
/// overrides, both may be used, the patch is applied first and the single variables win:
/// * `SET_<field>=<value>`, one variable per field of `Settings`, for example `SET_saleFloorBps=8000`
/// * `SETTINGS_PATCH`, a json object as text or the path of a json file, for example `{"saleFloorBps":8000}`
/// `SET_RATE=<wei per credit>` also prepares `setRate`.
/// with `CONTROLLER=0x...` the same `SET_<field>` variables also change the controller: the fields of `Sale` (`markupBps`,
/// `startCapBps`, `decayHours`, `anchorHalfLife`, `anchorMinCost`) go to `setSale`
/// and the fields of `CreditSale` (`saleOn`, `window`, `floorBps`, `startBps`, `refScore`, `royaltyBps`, `royaltyRecipient`)
/// to `setCredit`. each struct is read live, patched and checked by a simulated call as the owner, which reverts with
/// the first field out of bounds.
/// the controller prices held statements live from the settings, so a setting change reaches every held statement at once.
///
/// `CORE=0x... SET_saleFloorBps=8000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL`
/// (add `SEND=1 --broadcast --ledger` or `--account <name>` to send, as the owner)
contract SetSettings is Script {
    /// @dev a patch names a field that `Settings` does not have
    error UnknownField(string name);
    /// @dev a value does not fit the width of its field
    error ValueTooWide(string name);
    /// @dev the new struct is outside the bounds the Core enforces, `field` is the first one out
    error OutOfBounds(bytes32 field);
    /// @dev the signer is not the Core owner
    error NotOwner(address owner, address signer);

    string internal constant TUPLE =
        "(uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16,uint24)";

    function run() external {
        ICoreOwner core = ICoreOwner(_core());
        Settings memory before_ = core.settings();
        Settings memory next = _apply(before_);
        bytes32 bad = SettingsBounds.firstViolation(next);
        if (bad != 0) revert OutOfBounds(bad);

        _table(before_, next);
        bool settingsChanged = keccak256(abi.encode(before_)) != keccak256(abi.encode(next));
        console.log("setSettings calldata");
        console.logBytes(abi.encodeCall(ICoreOwner.setSettings, (next)));
        console.log(
            string.concat(
                "cast send ", vm.toString(address(core)), " \"setSettings(", TUPLE, ")\" \"", _tuple(next), "\""
            )
        );
        if (!settingsChanged) console.log("the settings are unchanged, setSettings is not needed");
        _warnRateCap(core, next.rateCap);

        uint256 rate = vm.envOr("SET_RATE", uint256(0));
        if (rate != 0) {
            console.log("ethRate now", core.ethRate());
            console.log("setRate calldata");
            console.logBytes(abi.encodeCall(ICoreOwner.setRate, (rate)));
            console.log(
                string.concat("cast send ", vm.toString(address(core)), " \"setRate(uint256)\" ", vm.toString(rate))
            );
        }

        IControllerV1 ctl = IControllerV1(vm.envOr("CONTROLLER", address(0)));
        if (address(ctl) != address(0)) _controllerPlan(ctl, core.owner());

        if (!_send()) {
            console.log("nothing sent. add SEND=1 and --broadcast with the owner as signer to send");
            return;
        }
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        if (signer != core.owner()) revert NotOwner(core.owner(), signer);
        if (settingsChanged) core.setSettings(next);
        if (rate != 0) core.setRate(rate);
        if (address(ctl) != address(0)) {
            (Sale memory ns, CreditSale memory nk, bool saleChanged, bool creditChanged) = _controllerChanges(ctl);
            if (saleChanged) ctl.setSale(ns);
            if (creditChanged) ctl.setCredit(nk);
        }
        vm.stopBroadcast();
        console.log("sent. read it back with settings(), ethRate() and the SettingsSet event");
    }

    /// @dev the live `Sale` and `CreditSale` of the controller with the `SET_<field>` variables applied, and whether each
    /// differs from the live struct
    function _controllerChanges(IControllerV1 c)
        internal
        view
        returns (Sale memory ns, CreditSale memory nk, bool saleChanged, bool creditChanged)
    {
        ns = Sale({
            markupBps: uint16(_field("markupBps", c.markupBps(), type(uint16).max)),
            startCapBps: uint32(_field("startCapBps", c.startCapBps(), type(uint32).max)),
            decayHours: uint16(_field("decayHours", c.decayHours(), type(uint16).max)),
            anchorHalfLife: uint32(_field("anchorHalfLife", c.anchorHalfLife(), type(uint32).max)),
            anchorMinCost: uint128(_field("anchorMinCost", c.anchorMinCost(), type(uint128).max))
        });
        nk = CreditSale({
            saleOn: _field("saleOn", c.creditSaleOn() ? 1 : 0, 1) == 1,
            window: uint32(_field("window", c.creditWindow(), type(uint32).max)),
            floorBps: uint16(_field("floorBps", c.creditFloorBps(), type(uint16).max)),
            startBps: uint32(_field("startBps", c.creditStartBps(), type(uint32).max)),
            royaltyBps: uint16(_field("royaltyBps", c.royaltyBps(), type(uint16).max)),
            royaltyRecipient: vm.envOr("SET_royaltyRecipient", c.royaltyRecipient())
        });
        saleChanged = keccak256(abi.encode(ns))
            != keccak256(
                abi.encode(
                    Sale(
                        c.markupBps(),
                        c.startCapBps(),
                        c.decayHours(),
                        c.anchorHalfLife(),
                        c.anchorMinCost()
                    )
                )
            );
        creditChanged = keccak256(abi.encode(nk))
            != keccak256(
                abi.encode(
                    CreditSale(
                        c.creditSaleOn(),
                        c.creditWindow(),
                        c.creditFloorBps(),
                        c.creditStartBps(),
                        c.royaltyBps(),
                        c.royaltyRecipient()
                    )
                )
            );
    }

    /// @dev `SET_<name>` when set, else the live value. a value above `max` does not fit the field
    function _field(string memory name, uint256 live, uint256 max) internal view returns (uint256) {
        (bool has, uint256 v) = _single(name);
        if (!has) return live;
        if (v > max) revert ValueTooWide(name);
        return v;
    }

    /// @dev prints the changed controller structs with their calldata, after a simulated call as the owner has accepted
    /// them. the controller's own `BadSetting` field is the revert
    function _controllerPlan(IControllerV1 c, address owner_) internal {
        (Sale memory ns, CreditSale memory nk, bool saleChanged, bool creditChanged) = _controllerChanges(c);
        if (saleChanged) {
            _simulate(c, owner_, abi.encodeCall(IControllerV1.setSale, (ns)));
            console.log("setSale calldata");
            console.logBytes(abi.encodeCall(IControllerV1.setSale, (ns)));
        }
        if (creditChanged) {
            _simulate(c, owner_, abi.encodeCall(IControllerV1.setCredit, (nk)));
            console.log("setCredit calldata");
            console.logBytes(abi.encodeCall(IControllerV1.setCredit, (nk)));
        }
        if (!saleChanged && !creditChanged) console.log("the controller settings are unchanged");
    }

    function _simulate(IControllerV1 c, address owner_, bytes memory data) internal {
        vm.prank(owner_);
        (bool ok, bytes memory why) = address(c).call(data);
        if (ok) return;
        bytes32 field;
        assembly ("memory-safe") {
            field := mload(add(why, 36))
        }
        revert OutOfBounds(field);
    }

    /// @dev prints a warning row and returns true when `rateCap` is below the live bid read (`ethRate`) or the live price
    /// state (`ethPrice`). `rateCap` bounds both, so the bid drops to the cap when `setSettings` lands
    function _warnRateCap(ICoreOwner core, uint256 rateCap) internal view returns (bool below) {
        uint256 read = core.ethRate();
        uint256 price = core.ethPrice();
        below = rateCap < read || rateCap < price;
        if (!below) return false;
        console.log(
            string.concat(
                "WARNING rateCap ",
                vm.toString(rateCap),
                " is below the live bid (ethRate ",
                vm.toString(read),
                ") or price state (ethPrice ",
                vm.toString(price),
                "): the bid falls to the cap when setSettings lands"
            )
        );
    }

    /// @dev the Core to change (CORE), the broadcast flag (SEND=1) and the optional rate changes. a test overrides them
    function _core() internal view virtual returns (address) {
        return vm.envAddress("CORE");
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }

    /// @dev the patch text or file path, empty when there is none. a test overrides it
    function _patch() internal view virtual returns (string memory) {
        return vm.envOr("SETTINGS_PATCH", string(""));
    }

    /// @dev the single variable of a field, `has` false when it is not set. a test overrides it
    function _single(string memory name) internal view virtual returns (bool has, uint256 v) {
        string memory key = string.concat("SET_", name);
        if (!vm.envExists(key)) return (false, 0);
        return (true, vm.envUint(key));
    }

    /// @dev the live struct with the patch, then the single variables, applied
    function _apply(Settings memory live) internal view returns (Settings memory s) {
        // a copy, so the live struct stays what it is for the before and after table
        s = abi.decode(abi.encode(live), (Settings));
        string memory patch = _patch();
        if (bytes(patch).length != 0) {
            string memory json = bytes(patch)[0] == "{" ? patch : vm.readFile(patch);
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 k; k < keys.length; ++k) {
                _set(s, keys[k], vm.parseJsonUint(json, string.concat(".", keys[k])));
            }
        }
        bytes32[26] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            string memory name = _name(names[i]);
            (bool has, uint256 v) = _single(name);
            if (has) _set(s, name, v);
        }
    }

    function _set(Settings memory s, string memory name, uint256 v) internal pure {
        bytes32[26] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            if (keccak256(bytes(_name(names[i]))) != keccak256(bytes(name))) continue;
            SettingsFields.set(s, i, v);
            // the setter narrows to the field width: a value that did not fit reads back different
            if (SettingsFields.get(s, i) != v) revert ValueTooWide(name);
            return;
        }
        revert UnknownField(name);
    }

    function _name(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 j; j < n; ++j) {
            out[j] = b[j];
        }
        return string(out);
    }

    /// @dev one line per field: name, live value, new value, a mark when it changes, the bounds
    function _table(Settings memory a, Settings memory b) internal pure {
        console.log("settings: field | live | new | bounds (a * marks a change; recoveryClimbPerMinBps >= climbPerMinBps, redeemSlippageBps <= balanceBidMarginBps, the two switches are 0 or 1)");
        uint256[26] memory lo = SettingsFields.lo();
        uint256[26] memory hi = SettingsFields.hi();
        bytes32[26] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            uint256 x = SettingsFields.get(a, i);
            uint256 y = SettingsFields.get(b, i);
            console.log(
                string.concat(
                    x == y ? "  " : "* ",
                    _name(names[i]),
                    " | ",
                    vm.toString(x),
                    " | ",
                    vm.toString(y),
                    " | ",
                    vm.toString(lo[i]),
                    " to ",
                    vm.toString(hi[i])
                )
            );
        }
    }

    /// @dev the struct as the tuple literal `cast send` takes
    function _tuple(Settings memory s) internal pure returns (string memory out) {
        out = "(";
        for (uint256 i; i < SettingsFields.N; ++i) {
            uint256 v = SettingsFields.get(s, i);
            out = string.concat(out, i == 0 ? "" : ",", i == 11 || i == 12 ? (v == 1 ? "true" : "false") : vm.toString(v));
        }
        out = string.concat(out, ")");
    }
}
