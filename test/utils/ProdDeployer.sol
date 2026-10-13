// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {IArtCoinsFactoryV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {Prod} from "./Prod.sol";

/// @notice the test side of `NewProd`: the controller and the core are created from their via_ir artifacts, so no test
/// contract imports the production sources or embeds their creation code
abstract contract ProdDeployer is SystemDeployer {
    function _newController(address core_, LaunchConfig memory c) internal virtual override returns (address) {
        return address(Prod.newController(core_, c.sale, c.credit));
    }

    function _newSeaportAdapter(address core_, address[] memory recipients) internal virtual override returns (address) {
        return Prod.newSeaportAdapter(core_, recipients, SEAPORT_ADAPTER_SALT, CREATE2_DEPLOYER);
    }

    function _newStrategyAdapter() internal virtual override returns (address) {
        return Prod.newStrategyAdapter(STRATEGY_ADAPTER_SALT, CREATE2_DEPLOYER);
    }

    function _newCore(
        address owner_,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller_,
        LaunchConfig memory c,
        address[] memory adapters
    ) internal virtual override returns (address) {
        return address(
            Prod.newCore(owner_, cfg, launcher, controller_, c.payee, c.stack, c.rateStart, c.settings, c.credit, adapters)
        );
    }
}
