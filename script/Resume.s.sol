// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Deployed} from "./SystemDeployer.sol";
import {SystemResumer} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CORE=0x... CONFIG_HASH=0x... DEPLOYER=0x... forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast
/// --slow --private-key $KEY`. reverts while SETTINGS_CHANGED or COIN_CHANGED is set. run it as the same deployer as the
/// original run. CORE must be the Core address of this config and deployer. sends the contracts that have no code at
/// their address, the owner calls and the launch that are not on chain yet. reverts when the Core does not exist (run
/// Deploy) or the coin is launched already. then runs postflight. the runbook is docs/RUNBOOK.md section 6
contract Resume is Script, SystemResumer, NewProd {
    function run() external {
        _requireNoChangeFlags();
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        address core = vm.envAddress("CORE");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        // the checks simulate the launch on a snapshot, so they run outside the broadcast
        resumeChecks(deployer, c, core);
        vm.startBroadcast();
        Deployed memory d = resumeSend(deployer, c);
        vm.stopBroadcast();
        console.log("coin", d.coin);
    }
}
