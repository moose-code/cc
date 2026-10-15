// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Stack, Settings, Sale, Credit, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2} from "../../src/interfaces/ArtCoinsV2.sol";

/// @notice creates the production contracts from their via_ir artifacts. the tests never import the production sources
/// (that would pull them onto the via_ir compiler profile), so `new Core(...)` becomes `Prod.newCore(...)`. a revert
/// of the constructor reaches the caller with its own revert data, so `vm.expectRevert` works as with `new`
library Prod {
    /// test harness for building a Core and controller directly (not through the deploy path)

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev the artist the direct-construction helpers pass: a nonzero, non-forbidden address, so the default
    /// `saleToArtistBps` is accepted. tests that need a specific artist set it with `setArtist` after
    address internal constant DEFAULT_ARTIST = address(0xA12157);

    /// @dev a Core with the default credit settings and no approved adapter. `cfg` is the factory launch config the
    /// Core computes its coin from (the bounty recipient is set by the Core), `launcher` the sender of the launch
    function newCore(
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller,
        address payee,
        Stack memory stack,
        uint256 rateStart,
        Settings memory settings
    ) internal returns (ICore) {
        return newCore(owner, cfg, launcher, controller, payee, stack, rateStart, settings, Mainnet.defaultCredit());
    }

    /// @dev a successor Core of the launched `coin`: the Core of an existing coin takes the coin as an argument
    function newCoreOf(
        address coin,
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address controller,
        address payee,
        Stack memory stack,
        uint256 rateStart,
        Settings memory settings
    ) internal returns (ICore) {
        bytes memory args = abi.encode(
            owner, cfg, address(0), coin, payee, stack, rateStart, settings, Mainnet.defaultCredit(), DEFAULT_ARTIST
        );
        return _wire(ICore(payable(vm.deployCode("Core.sol:Core", args))), owner, controller, new address[](0));
    }

    /// @dev a Core with no approved adapter
    function newCore(
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller,
        address payee,
        Stack memory stack,
        uint256 rateStart,
        Settings memory settings,
        Credit memory credit
    ) internal returns (ICore) {
        return newCore(owner, cfg, launcher, controller, payee, stack, rateStart, settings, credit, new address[](0));
    }

    function newCore(
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller,
        address payee,
        Stack memory stack,
        uint256 rateStart,
        Settings memory settings,
        Credit memory credit,
        address[] memory adapters
    ) internal returns (ICore) {
        bytes memory args =
            abi.encode(owner, cfg, launcher, address(0), payee, stack, rateStart, settings, credit, DEFAULT_ARTIST);
        return _wire(ICore(payable(vm.deployCode("Core.sol:Core", args))), owner, controller, adapters);
    }

    /// @dev the owner sets the controller and the adapters after the construction, as the deploy does
    function _wire(ICore core, address owner, address controller, address[] memory adapters)
        private
        returns (ICore)
    {
        vm.startPrank(owner);
        if (controller != address(0)) core.setController(controller);
        for (uint256 i; i < adapters.length; ++i) {
            core.addAdapter(adapters[i]);
        }
        vm.stopPrank();
        return core;
    }

    function newController(address core, Sale memory sale) internal returns (IControllerV1) {
        return newController(core, sale, Mainnet.defaultCredit());
    }

    function newController(address core, Sale memory sale, Credit memory credit) internal returns (IControllerV1) {
        return IControllerV1(vm.deployCode("ControllerV1.sol:ControllerV1", abi.encode(core, sale, credit)));
    }

    /// @dev sends `init` through the deterministic deployer with `salt`
    function create2(bytes memory init, bytes32 salt, address create2Deployer) internal returns (address created) {
        (bool ok, bytes memory out) = create2Deployer.call(abi.encodePacked(salt, init));
        require(ok && out.length == 20, "create2 failed");
        created = address(bytes20(out));
    }

    /// @dev creates the Seaport adapter through the deterministic deployer, as `forge script` does with
    /// `new SeaportBasicAdapter{salt}`
    function newSeaportAdapter(address core, address[] memory recipients, bytes32 salt, address create2Deployer)
        internal
        returns (address adapter)
    {
        bytes memory init = abi.encodePacked(
            vm.getCode("SeaportBasicAdapter.sol:SeaportBasicAdapter"), abi.encode(core, recipients)
        );
        (bool ok, bytes memory out) = create2Deployer.call(abi.encodePacked(salt, init));
        require(ok && out.length == 20, "seaport adapter create2 failed");
        adapter = address(bytes20(out));
    }

    /// @dev creates the CreditStrategy adapter through the deterministic deployer
    function newStrategyAdapter(bytes32 salt, address create2Deployer) internal returns (address adapter) {
        bytes memory init = vm.getCode("CreditStrategyAdapter.sol:CreditStrategyAdapter");
        (bool ok, bytes memory out) = create2Deployer.call(abi.encodePacked(salt, init));
        require(ok && out.length == 20, "strategy adapter create2 failed");
        adapter = address(bytes20(out));
    }
}
