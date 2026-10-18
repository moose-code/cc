// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {ICoinRenderer} from "../src/interfaces/ICoinRenderer.sol";
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

    /// @notice a step before the launch is not on chain, so the run is not a deferred deploy awaiting its launch
    error NotDeferred(string what);

    /// @notice the extra rows of `LAUNCH_ONLY`: the controller, both adapters and the renderer have code at their
    /// addresses, the renderer is bound to the Core, and the Core points at the controller and allows both adapters. only
    /// the launch is then left to send. reverts on the first missing step
    function launchOnlyChecks(LaunchConfig memory c, address core_) internal view {
        ICore k = ICore(payable(core_));
        address ctl = controllerAddress(core_, c);
        address sea = seaportAdapterAddress(core_, c.seaportRecipients);
        address strat = strategyAdapterAddress();
        address ren = rendererAddress(c);
        if (ctl.code.length == 0) revert NotDeferred("controller");
        if (sea.code.length == 0) revert NotDeferred("seaport adapter");
        if (strat.code.length == 0) revert NotDeferred("strategy adapter");
        if (ren.code.length == 0) revert NotDeferred("renderer");
        if (address(ICoinRenderer(ren).core()) != core_) revert NotDeferred("renderer setCore");
        if (k.controller() != ctl) revert NotDeferred("setController");
        if (!k.allowedAdapter(sea)) revert NotDeferred("addAdapter seaport");
        if (!k.allowedAdapter(strat)) revert NotDeferred("addAdapter strategy");
    }

    /// @notice sends the steps the chain is still missing (after `resumeChecks`). the caller must be the deployer of the
    /// original run, because the Core address and the coin address depend on it. the postflight runs after it, outside
    /// the broadcast (`resumePostflight`)
    function resumeSend(address deployer, LaunchConfig memory c) internal returns (Deployed memory d) {
        d = deploySystem(deployer, c);
    }

    /// @notice the postflight of a resumed deploy, reverting on any failed row
    function resumePostflight(address deployer, LaunchConfig memory c, Deployed memory d) internal {
        postflightAs(c, d.core, deployer);
        _require();
    }
}
