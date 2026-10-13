// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {CoreLens} from "../src/CoreLens.sol";
import {SeaportBasicAdapter} from "../src/adapters/SeaportBasicAdapter.sol";
import {CreditStrategyAdapter} from "../src/adapters/CreditStrategyAdapter.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer} from "./SystemDeployer.sol";

/// @notice the broadcast creation of the controller and the core with `new`, so `forge script` links `CoreLib` and
/// sends it through the deterministic deployer. only the scripts import this file: it pulls the production sources, so
/// it (and every script that inherits it) compiles on the via_ir profile. tests use `Prod` and `deployCode` instead
abstract contract NewProd is SystemDeployer {
    function _newController(address core, LaunchConfig memory c) internal virtual override returns (address) {
        return address(new ControllerV1(core, c.sale, c.credit));
    }

    function _newLens(address core) internal virtual override returns (address) {
        return address(new CoreLens{salt: LENS_SALT}(core));
    }

    function _newSeaportAdapter(address core, address[] memory recipients) internal virtual override returns (address) {
        return address(new SeaportBasicAdapter{salt: SEAPORT_ADAPTER_SALT}(core, recipients));
    }

    function _newStrategyAdapter() internal virtual override returns (address) {
        return address(new CreditStrategyAdapter{salt: STRATEGY_ADAPTER_SALT}());
    }

    function _newCore(
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller,
        LaunchConfig memory c,
        address[] memory adapters
    ) internal virtual override returns (address) {
        return address(new Core(owner, cfg, launcher, address(0), controller, c.payee, c.stack, c.rateStart, c.settings, c.credit, adapters));
    }
}
