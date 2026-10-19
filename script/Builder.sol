// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Stack} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig, ConfigReader} from "./LaunchConfig.sol";

/// @notice builds the v2 factory config and the coin address prediction of a launch from a `LaunchConfig`
/// (docs/DECISIONS.md 10.4). shared by the deploy, the preflight, the postflight and the tests
abstract contract SystemBuilder is ConfigReader {
    /// @dev the CREATE2 salt prefix of the launch renderer; the deterministic deployer is `PostflightChecks.CREATE2_DEPLOYER`
    bytes32 internal constant RENDERER_SALT = keccak256("credits.coinRenderer.v1");

    /// @notice the CREATE2 salt of the renderer of `l`: `RENDERER_SALT` and the config `salt`
    function rendererSalt(LaunchConfig memory l) internal pure returns (bytes32) {
        return keccak256(abi.encode(RENDERER_SALT, l.salt));
    }

    /// @notice the address of the `LogoCoinRenderer` of `l`: CREATE2 through the deterministic deployer with `rendererSalt`
    /// and the creation code with the config owner as constructor argument. the Core is not an input, so the token
    /// config names the renderer before the Core exists. a renderer is bound to one Core, so a launch with a different
    /// Core under the same owner and `salt` needs another `salt`
    function rendererAddress(LaunchConfig memory l) internal view returns (address) {
        bytes memory init = abi.encodePacked(vm.getCode("LogoCoinRenderer.sol:LogoCoinRenderer"), abi.encode(l.owner));
        return vm.computeCreate2Address(rendererSalt(l), keccak256(init), 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }

    /// @notice the pool key of a coin: native eth against the coin, dynamic fee flag, spacing 200, the v2 hook
    function poolKeyOf(address coin, Stack memory s) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: s.poolFee,
            tickSpacing: s.tickSpacing,
            hooks: IHooks(s.hook)
        });
    }

    /// @notice the v2 factory config of the launch. the token admin is the owner. the bounty recipient is `recipient`
    /// (the Core; the Core constructor sets it itself, so it takes the config with the zero address). the referral rate
    /// is 0: the engine names no referrer. the pool holds one full range position. the coin is restricted and its
    /// allowlist is `l.allowed` plus the entries the factory seeds. the Core is not listed: the buyback take reaches it
    /// through the transfer allowance the hook grants for the swap (docs/DECISIONS.md decision 29). the coin's metadata
    /// renderer is the `CoinRenderer` of the config (decision 127)
    function buildConfig(LaunchConfig memory l, address tokenAdmin, address recipient)
        internal
        view
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c.token = IArtCoinsFactoryV2.TokenConfigV2({
            tokenAdmin: tokenAdmin,
            name: l.name,
            symbol: l.symbol,
            salt: l.salt,
            image: l.image,
            description: l.description,
            totalSupply: l.supply,
            renderer: rendererAddress(l)
        });
        c.pool = IArtCoinsFactoryV2.PoolConfigV2({
            hook: l.stack.hook,
            tickIfToken0IsCoin: l.startTick,
            tickSpacing: l.stack.tickSpacing,
            extension: address(0),
            extensionData: ""
        });
        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            baselineSkimBps: l.baselineSkimBps,
            bountyBps: l.bountyBps,
            bountyRecipient: payable(recipient),
            referralBps: 0
        });
        int24[] memory lower = new int24[](1);
        lower[0] = l.positionLower;
        int24[] memory upper = new int24[](1);
        upper[0] = l.positionUpper;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;
        c.locker = IArtCoinsFactoryV2.LockerConfigV2({
            locker: l.stack.locker,
            tickLower: lower,
            tickUpper: upper,
            positionBps: positionBps
        });
        c.mev = IArtCoinsFactoryV2.MevConfigV2({
            module: l.mevModule, startingSkimBps: l.sniperStartBps, windowSeconds: l.sniperSeconds
        });
        c.restriction = IArtCoinsFactoryV2.RestrictionConfigV2({restricted: l.restricted, allowed: l.allowed});
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](0);
    }

    /// @notice keccak256 of the canonical abi encoding of the whole launch config. it covers every value the launch
    /// depends on (the overrides included) and none of the machine (not the deployer). the operator signs off this
    /// one value: preflight prints it, `Deploy` needs it in CONFIG_HASH and postflight prints it again
    function configHash(LaunchConfig memory l) internal pure returns (bytes32) {
        return keccak256(abi.encode(l));
    }

    /// @notice the address the v2 factory will give the coin, from its own `predictToken`. it depends on the sender
    /// (the owner, who signs the launch), the whole config (the Core address included) and mutable factory state
    /// (the default allowlist and the hook escrow), so read it right before the launch
    function predictCoin(LaunchConfig memory l, address sender, address core)
        internal
        view
        returns (address)
    {
        return IArtCoinsFactoryV2(l.stack.factory).predictToken(sender, buildConfig(l, l.owner, core));
    }
}
