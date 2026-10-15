// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {SeaportBasicAdapter} from "../src/adapters/SeaportBasicAdapter.sol";
import {CreditStrategyAdapter} from "../src/adapters/CreditStrategyAdapter.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer} from "./SystemDeployer.sol";

/// @notice the broadcast creation of every contract of ours with `new` and a salt, so `forge script` links `CoreLib` and
/// sends each creation through the deterministic deployer. only the scripts import this file: it pulls the production
/// sources, so it (and every script that inherits it) compiles on the via_ir profile. tests use `Prod` and `deployCode`
/// instead
abstract contract NewProd is SystemDeployer {
    function _newCore(LaunchConfig memory c, address launcher) internal virtual override returns (address) {
        return address(
            new Core{salt: CORE_SALT}(
                c.owner, buildConfig(c, c.owner, address(0)), launcher, address(0), c.payee, c.stack, c.rateStart, c.settings, c.credit, c.artist
            )
        );
    }

    function _newController(address core, LaunchConfig memory c) internal virtual override returns (address) {
        return address(new ControllerV1{salt: CONTROLLER_SALT}(core, c.sale, c.credit));
    }

    function _newSeaportAdapter(address core, address[] memory recipients) internal virtual override returns (address) {
        return address(new SeaportBasicAdapter{salt: SEAPORT_ADAPTER_SALT}(core, recipients));
    }

    function _newStrategyAdapter() internal virtual override returns (address) {
        return address(new CreditStrategyAdapter{salt: STRATEGY_ADAPTER_SALT}());
    }
}
