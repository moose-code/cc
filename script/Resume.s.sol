// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Deployed} from "./SystemDeployer.sol";
import {SystemResumer} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice Internal script of `script/deploy.sh RESUME=state`. The wrapper verifies the original signed config lock
/// before invoking this script. reverts while SETTINGS_CHANGED or COIN_CHANGED is set. run it as the same deployer as the
/// original run. CORE must be the Core address of this config and deployer. sends the contracts that have no code at
/// their address and the missing owner calls. It checks the complete deferred state before launching the coin.
/// LAUNCH_ONLY=1 first requires every step before the launch on chain (`NotDeferred`). It reverts when the coin is
/// launched already. The runbook is docs/RUNBOOK.md section 6.
contract Resume is Script, SystemResumer, NewProd {
    error ConfigLockMismatch();

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
        string memory lock = vm.readFile(vm.envString("CONFIG_LOCK"));
        if (
            vm.parseJsonUint(lock, ".scriptChainId") != block.chainid
                || vm.parseJsonAddress(lock, ".deployer") != deployer
                || vm.parseJsonBytes32(lock, ".configHash") != configHash(c)
        ) revert ConfigLockMismatch();
        // the checks simulate the launch on a snapshot, so they run outside the broadcast
        resumeChecks(deployer, c, core);
        // LAUNCH_ONLY=1: the deploy was DEFER_LAUNCH, so the launch is the only transaction left
        if (vm.envOr("LAUNCH_ONLY", uint256(0)) == 1) launchOnlyChecks(deployer, c, core, vm.envAddress("RECORD_TOKEN_DEPLOYER"));
        bool deferred = vm.envOr("DEFER_LAUNCH", uint256(0)) == 1;
        vm.startBroadcast();
        Deployed memory d = resumeSendUntilLaunch(deployer, c);
        vm.stopBroadcast();
        // A partial recovery first completes missing prelaunch steps. Check their resulting state before sending the
        // irreversible factory launch, including controller settings and Core locks changed after the deferred run.
        this.prelaunchGate(c, d.core, deployer);
        if (!deferred) {
            vm.startBroadcast();
            _launch(c, d.coin, d.core);
            vm.stopBroadcast();
        }
        // deploy.sh runs the postlaunch readback in a separate Postflight script after receipts are on chain.
        console.log("coin", d.coin);
        console.log("renderer", d.renderer);
    }

    /// @notice Checks the completed prelaunch state in a separate call so artifact reads from resumeChecks are released.
    function prelaunchGate(LaunchConfig memory c, address core, address deployer) external {
        postflightDeferred(c, core, deployer);
        _require();
    }
}
