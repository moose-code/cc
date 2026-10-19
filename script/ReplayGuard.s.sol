// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemResumer} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// Read-only guard for a saved-transaction replay after the Core exists. It checks the live opening rate,
/// settings, config, factory and owner before deploy.sh may replay a saved coin-launch transaction.
contract ReplayGuard is Script, SystemResumer, NewProd {
    function run() external {
        LaunchConfig memory c = _config();
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        resumeChecks(vm.envAddress("DEPLOYER"), c, vm.envAddress("CORE"));
    }

    function _config() internal view virtual returns (LaunchConfig memory) {
        return loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
    }
}
