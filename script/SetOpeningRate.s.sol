// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemResumer} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// Prepares one owner transaction to reset the opening ETH rate before the coin exists. Without SEND=1 this only
/// prints the rate, cap and separate signoff hash. The constructor config and its CONFIG_HASH stay unchanged.
contract SetOpeningRate is Script, SystemResumer, NewProd {
    error BadOpeningRate(uint256 rate);
    error WrongOwner(address want, address got);
    error CoinAlreadyLaunched();
    error WrongSignoff(bytes32 want, bytes32 got);
    error WrongConfigHash(bytes32 want, bytes32 got);
    error WrongReadback();

    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        uint256 rate = vm.envUint("PRELAUNCH_RATE");
        if (!SettingsBounds.rateInBounds(rate) || rate > type(uint64).max / 3) revert BadOpeningRate(rate);
        uint256 cap = rate * 3;
        bytes32 hash = keccak256(abi.encode(keccak256("credits.prelaunchRate.v1"), configHash(c), rate, cap));
        console.log("original CONFIG_HASH", vm.toString(configHash(c)));
        console.log("opening rate wei per 100 points", rate);
        console.log("new rateCap wei per 100 points", cap);
        console.log("PRELAUNCH_RATE_HASH", vm.toString(hash));
        if (vm.envOr("SEND", uint256(0)) != 1) return;

        bytes32 configHashGiven = vm.envOr("CONFIG_HASH", bytes32(0));
        if (configHashGiven != configHash(c)) revert WrongConfigHash(configHash(c), configHashGiven);
        bytes32 given = vm.envOr("PRELAUNCH_RATE_HASH", bytes32(0));
        if (given != hash) revert WrongSignoff(hash, given);
        ICore core = ICore(payable(vm.envAddress("CORE")));
        if (core.COIN().code.length != 0) revert CoinAlreadyLaunched();
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        vm.stopBroadcast();
        if (signer != core.owner()) revert WrongOwner(core.owner(), signer);
        address expectedCore = coreAddress(c, signer);
        if (address(core) != expectedCore) revert CoreMismatch(expectedCore, address(core));
        vm.startBroadcast();
        core.setOpeningRate(rate);
        vm.stopBroadcast();
        if (core.RATE_START() != rate || core.settings().rateCap != cap || core.rateAtCheckpoint() != rate) {
            revert WrongReadback();
        }
    }
}
