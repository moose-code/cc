// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CONFIG_HASH=0x... CONTROLLER_NONCE=n DEPLOYER=0x... forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow
/// --private-key $KEY` (or `--account` or `--ledger`). the signer must be the v2 factory owner and the config owner, it
/// comes from the flags only, DEPLOYER only has to agree with it. reads script/config/mainnet.json, or the file named by
/// LAUNCH_CONFIG. refuses to run while owner, creator, name, symbol or salt is unset, while any of SETTINGS_CHANGED, LOCKS_CHANGED,
/// OWNER_CHANGED or COIN_CHANGED is set, unless CONFIG_HASH is the hash that preflight printed for this
/// config, unless CONTROLLER_NONCE is the owner nonce preflight printed, and unless the signer is the factory owner. the order of the transactions
/// (docs/DECISIONS.md 10.4): the library, the controller, the Core, the two adapters, the launch.
/// preflight runs first and postflight runs on the simulated result, both before anything is sent. the full runbook is
/// docs/RUNBOOK.md
contract Deploy is Script, NewProd {
    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        _requireNoChangeFlags();
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        // nothing is signed or sent until the operator's sign off value equals the hash of this config
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        // the signer, read once; the checks run outside the broadcast because they simulate the launch on a snapshot
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        _requireOwner(c, deployer);
        // the owner nonce preflight printed: a transaction since then moved the predicted addresses
        _requireControllerNonce(deployer, vm.envOr("CONTROLLER_NONCE", type(uint256).max));
        // every preflight check runs first. a failed check reverts here, before anything is sent
        preflight(c, deployer);
        _print("preflight");
        _require();
        vm.startBroadcast();
        d = deploySystem(deployer, c);
        vm.stopBroadcast();
        // the same read back as the Postflight script, on the result of the run. a failure reverts the simulation, so
        // nothing is sent
        postflightAs(c, d.core, deployer);
        _print("postflight of the simulated launch");
        _require();
        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("controller", d.controller);
        console.log("seaport adapter", d.seaportAdapter);
        console.log("strategy adapter", d.strategyAdapter);
        console.log("fee recipients NOT locked: script/Lock.s.sol is an owner command for later (docs/RUNBOOK.md)");
        for (uint256 i; i < STEPS; ++i) {
            console.log(string.concat("gas of step ", vm.toString(i)), stepGas[i]);
        }
    }
}
