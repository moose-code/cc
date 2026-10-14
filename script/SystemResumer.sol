// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";

/// @notice finishes a deploy that stopped before the launch: `deploySystem` creates what has no code at its CREATE2
/// address and sends the owner calls and the launch that are not on chain. shared by the `Resume` script and the tests
abstract contract SystemResumer is SystemDeployer {
    /// @notice the Core at `got` is not the Core `coreAddress(c, deployer)` of this config and deployer
    error CoreMismatch(address want, address got);
    /// @notice the Core of this config and deployer has no code: run `Deploy`
    error NotStarted();
    /// @notice the coin is launched already: nothing to resume
    error AlreadyLaunched();

    /// @notice everything the resume checks before it sends: that `core_` is the Core of this config and deployer, that
    /// it exists and has no coin yet, and the preflight rows that still apply. reverts on any failure. the script runs it
    /// outside the broadcast
    function resumeChecks(address deployer, LaunchConfig memory c, address core_) internal {
        _requireConfig(c);
        address want = coreAddress(c, deployer);
        if (core_ != want) revert CoreMismatch(want, core_);
        if (want.code.length == 0) revert NotStarted();
        if (ICore(payable(want)).COIN().code.length != 0) revert AlreadyLaunched();
        preflightResume(c, deployer);
        _require();
    }

    /// @notice sends the steps the chain is still missing (after `resumeChecks`), then runs postflight and reverts on any
    /// failed row. the caller must be the deployer of the original run, because the Core address and the coin address
    /// depend on it
    function resumeSend(address deployer, LaunchConfig memory c) internal returns (Deployed memory d) {
        d = deploySystem(deployer, c);
        postflightAs(c, d.core, deployer);
        _require();
    }
}
