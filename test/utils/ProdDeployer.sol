// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {Prod} from "./Prod.sol";

/// @notice the test side of `NewProd`: every contract is created from its via_ir artifact through the deterministic
/// deployer, so no test contract imports the production sources or embeds their creation code
abstract contract ProdDeployer is SystemDeployer {
    function _newCore(LaunchConfig memory c, address launcher) internal virtual override returns (address) {
        bytes memory init = abi.encodePacked(vm.getCode("Core.sol:Core"), coreConstructorArgs(c, launcher));
        return Prod.create2(init, CORE_SALT, CREATE2_DEPLOYER);
    }

    function _newController(address core_, LaunchConfig memory c) internal virtual override returns (address) {
        bytes memory init =
            abi.encodePacked(vm.getCode("ControllerV1.sol:ControllerV1"), abi.encode(core_, c.sale, c.credit, c.quote));
        return Prod.create2(init, CONTROLLER_SALT, CREATE2_DEPLOYER);
    }

    function _newSeaportAdapter(address core_, address[] memory recipients) internal virtual override returns (address) {
        return Prod.newSeaportAdapter(core_, recipients, SEAPORT_ADAPTER_SALT, CREATE2_DEPLOYER);
    }

    function _newStrategyAdapter() internal virtual override returns (address) {
        return Prod.newStrategyAdapter(STRATEGY_ADAPTER_SALT, CREATE2_DEPLOYER);
    }

    function _newRenderer(LaunchConfig memory c) internal virtual override returns (address) {
        bytes memory init = abi.encodePacked(vm.getCode("LogoCoinRenderer.sol:LogoCoinRenderer"), abi.encode(c.owner));
        return Prod.create2(init, rendererSalt(c), CREATE2_DEPLOYER);
    }
}
