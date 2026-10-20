// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice read only check of a launched system against the config. safe to run against mainnet at any time.
/// `CORE=0x... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. set DEPLOYER to print the verify inputs and to check the CREATE2 address of the Core. the override flags SETTINGS_CHANGED and COIN_CHANGED name a change the owner made after launch. the state of `coin.locked()` (script/Lock.s.sol) is printed as an info row. set CONFIG_HASH to check the signed off hash.
/// prints a table and reverts on any mismatch. run it right after the launch: the supply and rate rows are exact only
/// until the first trade or the first fill. with DEPLOYER set and every row ok it ends with one `record: {json}` line,
/// the addresses read back from the chain that script/deploy.sh writes into deployments/<chainId>.json
contract Postflight is Script, LaunchChecks {
    error RecordMismatch(bytes32 field);

    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        address core = vm.envAddress("CORE");
        _useApprovedRateRecord(c, core);
        // DEFER_LAUNCH=1: the system is deployed and the coin is not launched yet (docs/RUNBOOK.md, deferred launch)
        bool deferred = vm.envOr("DEFER_LAUNCH", uint256(0)) == 1;
        if (deferred) postflightDeferred(c, core, _deployerEnv());
        else postflight(c, core);
        // the same hash preflight printed and Deploy required. when CONFIG_HASH is set it must match
        bytes32 given = vm.envOr("CONFIG_HASH", bytes32(0));
        if (given != bytes32(0)) _eq("config hash equals CONFIG_HASH", configHash(c), given);
        address deployer = vm.envOr("DEPLOYER", address(0));
        _print("postflight");
        if (core.code.length != 0) printVerifyInputs(ICore(payable(core)), c, deployer);
        _require();
        if (deployer != address(0)) _printRecord(ICore(payable(core)), c);
    }

    /// A later postflight can recover its opening-rate signoff from the saved deployment record. The hash remains
    /// bound to this config and the live Core is checked by the normal postflight rows.
    function _useApprovedRateRecord(LaunchConfig memory c, address core) private {
        string memory path = vm.envOr("POSTFLIGHT_RECORD", string(""));
        if (bytes(path).length == 0) return;
        string memory j = vm.readFile(path);
        (uint256 rate, bytes32 hash) = _decodeApprovedRateRecord(c, core, j);
        if (vm.envExists("PRELAUNCH_RATE")) {
            if (vm.envUint("PRELAUNCH_RATE") != rate) revert RecordMismatch("PRELAUNCH_RATE");
        } else {
            vm.setEnv("PRELAUNCH_RATE", vm.toString(rate));
        }
        if (vm.envExists("PRELAUNCH_RATE_HASH")) {
            if (vm.envBytes32("PRELAUNCH_RATE_HASH") != hash) revert RecordMismatch("PRELAUNCH_RATE_HASH");
        } else {
            vm.setEnv("PRELAUNCH_RATE_HASH", vm.toString(hash));
        }
        _useApprovedControllerTimingRecord(c, j);
    }

    function _decodeApprovedRateRecord(LaunchConfig memory c, address core, string memory j)
        internal
        view
        returns (uint256 rate, bytes32 hash)
    {
        if (vm.parseJsonAddress(j, ".core") != core) revert RecordMismatch("core");
        if (vm.parseJsonUint(j, ".chainId") != block.chainid) revert RecordMismatch("chainId");
        if (vm.parseJsonBytes32(j, ".configHash") != configHash(c)) revert RecordMismatch("configHash");
        rate = vm.parseUint(vm.parseJsonString(j, ".openingRate"));
        hash = vm.parseJsonBytes32(j, ".openingRateHash");
        if (hash == bytes32(0)) {
            if (rate != c.rateStart) revert RecordMismatch("openingRate");
            rate = 0;
        } else if (hash != _openingRateHash(c, rate)) {
            revert RecordMismatch("openingRateHash");
        }
    }

    function _decodeApprovedControllerTimingRecord(LaunchConfig memory c, string memory j)
        internal
        view
        returns (bool present, uint256 decayHours, uint256 creditWindow, bytes32 hash)
    {
        bool decaySet = vm.keyExistsJson(j, ".controllerDecayHours");
        bool windowSet = vm.keyExistsJson(j, ".controllerCreditWindow");
        bool hashSet = vm.keyExistsJson(j, ".controllerTimingHash");
        if (!decaySet && !windowSet && !hashSet) return (false, 0, 0, bytes32(0));
        if (!decaySet || !windowSet || !hashSet) revert RecordMismatch("controllerTiming");
        decayHours = vm.parseUint(vm.parseJsonString(j, ".controllerDecayHours"));
        creditWindow = vm.parseUint(vm.parseJsonString(j, ".controllerCreditWindow"));
        hash = vm.parseJsonBytes32(j, ".controllerTimingHash");
        _validateControllerTiming(c, decayHours, creditWindow, hash);
        present = true;
    }

    // Called only after the record's Core, chain, config and opening-rate identity passed above.
    function _useApprovedControllerTimingRecord(LaunchConfig memory c, string memory j) internal {
        (bool present, uint256 decayHours, uint256 creditWindow, bytes32 hash) =
            _decodeApprovedControllerTimingRecord(c, j);
        if (!present) return;
        if (
            _timingEnvSet("PRELAUNCH_DECAY_HOURS") || _timingEnvSet("PRELAUNCH_CREDIT_WINDOW")
                || _timingEnvSet("PRELAUNCH_CONTROLLER_TIMING_HASH")
        ) {
            (uint256 expectedDecay, uint256 expectedWindow) = _approvedControllerTiming(c);
            if (
                expectedDecay != decayHours || expectedWindow != creditWindow
                    || vm.envBytes32("PRELAUNCH_CONTROLLER_TIMING_HASH") != hash
            ) {
                revert RecordMismatch("controllerTiming");
            }
        } else {
            vm.setEnv("PRELAUNCH_DECAY_HOURS", vm.toString(decayHours));
            vm.setEnv("PRELAUNCH_CREDIT_WINDOW", vm.toString(creditWindow));
            vm.setEnv("PRELAUNCH_CONTROLLER_TIMING_HASH", vm.toString(hash));
        }
    }

    function _controllerTimingRecord(LaunchConfig memory c) internal view returns (string memory) {
        (uint256 decayHours, uint256 creditWindow) = _approvedControllerTiming(c);
        if (!_timingEnvSet("PRELAUNCH_CONTROLLER_TIMING_HASH")) return "";
        return string.concat(
            ',"controllerDecayHours":"',
            vm.toString(decayHours),
            '","controllerCreditWindow":"',
            vm.toString(creditWindow),
            '","controllerTimingHash":"',
            vm.toString(_controllerTimingHash(c, decayHours, creditWindow)),
            '"'
        );
    }

    /// @dev the record fields that come from the chain: the Core, its controller and coin, the CREATE2 adapters and
    /// renderer (each code checked by the rows above), both linked libraries, the stack the Core holds and the Core owner
    function _printRecord(ICore k, LaunchConfig memory c) private view {
        uint256 openingRate = _approvedOpeningRate(c);
        bytes32 openingRateHash = vm.envOr("PRELAUNCH_RATE_HASH", bytes32(0));
        string memory contracts = string.concat(
            '"core":"',
            vm.toString(address(k)),
            '","controller":"',
            vm.toString(k.controller()),
            '","coin":"',
            vm.toString(k.COIN()),
            '","seaportAdapter":"',
            vm.toString(seaportAdapterAddress(address(k), c.seaportRecipients)),
            '","strategyAdapter":"',
            vm.toString(strategyAdapterAddress())
        );
        string memory more = string.concat(
            '","renderer":"',
            vm.toString(rendererAddress(c)),
            '","library":"',
            vm.toString(findLibrary(address(k).code)),
            '","opsLibrary":"',
            vm.toString(findOpsLibrary(address(k).code)),
            '","credits":"',
            vm.toString(Mainnet.CREDITS),
            '","statements":"',
            vm.toString(Mainnet.STATEMENTS)
        );
        string memory stack = string.concat(
            '","poolManager":"',
            vm.toString(address(k.MANAGER())),
            '","hook":"',
            vm.toString(k.HOOK()),
            '","poolFee":',
            vm.toString(uint256(k.POOL_FEE())),
            ',"tickSpacing":',
            vm.toString(int256(k.TICK_SPACING())),
            ',"owner":"',
            vm.toString(k.owner()),
            '","configHash":"',
            vm.toString(configHash(c)),
            '","openingRate":"',
            vm.toString(openingRate),
            '","openingRateHash":"',
            vm.toString(openingRateHash),
            '"',
            _controllerTimingRecord(c),
            "}"
        );
        console.log(string.concat("record: {", contracts, more, stack));
    }
}
