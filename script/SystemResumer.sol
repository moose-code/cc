// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";

/// @notice how far a deploy got. read from the chain, never from a file
enum Stage {
    NoCore, // no code at the core address, nothing to resume (run Deploy again)
    CoreOnly, // controller and core deployed, the launch through the factory is not sent
    Done // coin launched
}

/// @notice finishes a deploy that stopped half way: detects the stage on chain and sends only the missing steps, as the
/// factory owner. shared by the `Resume` script and the tests
abstract contract SystemResumer is SystemDeployer {
    /// @notice the core at the given address was not built from this config
    error CoreMismatch(string what);

    /// @notice the stage of the deploy of `core`, from chain state only
    function detectStage(LaunchConfig memory, address core) internal view returns (Stage) {
        if (core.code.length == 0) return Stage.NoCore;
        address coin = ICore(payable(core)).COIN();
        if (coin.code.length == 0) return Stage.CoreOnly;
        return Stage.Done;
    }

    /// @dev the core must be the one this config would have built, and its coin the one the config predicts
    function _requireCoreMatches(LaunchConfig memory c, address deployer, address core_, bool launching) private view {
        ICore core = ICore(payable(core_));
        if (!_ownerChanged() && core.owner() != c.owner) revert CoreMismatch("owner (OWNER_CHANGED=1 after a handover)");
        if (core.RATE_START() != c.rateStart) revert CoreMismatch("rateStart");
        // the owner can call `setSettings` as soon as the core exists. a core whose settings differ from the signed config
        // is finished only on purpose, with SETTINGS_CHANGED=1 (the postflight at the end warns and prints it)
        if (!_settingsChanged() && keccak256(abi.encode(core.settings())) != keccak256(abi.encode(c.settings))) {
            revert CoreMismatch("settings (SETTINGS_CHANGED=1 if the owner changed them)");
        }
        if (
            address(core.MANAGER()) != c.stack.poolManager || core.HOOK() != c.stack.hook
                || core.TICK_SPACING() != c.stack.tickSpacing || core.POOL_FEE() != c.stack.poolFee
                || core.FACTORY() != c.stack.factory || core.LOCKER() != c.stack.locker
                || core.ESCROW() != c.stack.escrow
        ) revert CoreMismatch("stack");
        if (launching) {
            // before the launch the factory prediction for the deployer and this config must give the Core's coin
            (bool ok, address want) = _predict(c, deployer, core_);
            if (!ok || want != core.COIN()) revert CoreMismatch("coin prediction (config or deployer)");
        }
    }

    /// @notice everything the resume checks before it sends: the stage, that the core is the one this config builds, and
    /// the preflight rows that still apply. reverts on any failure. the script runs it outside the broadcast
    function resumeChecks(address deployer, LaunchConfig memory c, address core_) internal returns (Stage from) {
        _requireConfig(c);
        from = detectStage(c, core_);
        if (from == Stage.NoCore) revert CoreMismatch("no code at the core address, run Deploy instead");
        _requireCoreMatches(c, deployer, core_, from == Stage.CoreOnly);
        preflightResume(c, deployer, from == Stage.CoreOnly);
        _require();
    }

    /// @notice sends the steps the chain is still missing (after `resumeChecks`), then runs postflight and reverts on any
    /// failed row. the caller must be the deployer of the original run, because the coin address depends on it
    function resumeSend(address deployer, LaunchConfig memory c, address core_, Stage from)
        internal
        returns (Deployed memory d)
    {
        ICore core = ICore(payable(core_));
        d.core = core_;
        d.coin = core.COIN();
        d.controller = core.controller();
        (d.seaportAdapter, d.strategyAdapter) = _ensureAdapters(core_, c);
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));

        if (from == Stage.CoreOnly) {
            _requireOwner(c, deployer);
            _launch(c, d.coin, core_);
        }
        postflightAs(c, core_, deployer);
        _require();
    }
}
