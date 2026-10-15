// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice everything the deploy creates
struct Deployed {
    address core;
    address coin;
    address controller;
    address seaportAdapter;
    address strategyAdapter;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `owner`, who must be the v2 factory owner and the config owner (a deprecated v2 factory takes only its owner, through
/// `deployTokenAsOwner`). every contract of ours is created through the deterministic deployer (CREATE2) at an address
/// that is a function of the salts, the creation code and the config, so the addresses are known before the first
/// transaction. order: the library `CoreLib` (linked and sent by `forge script` before `run`), the Core, the controller
/// (constructed with the Core address), the two listing adapters, `setController`, `setArtist`, `addAdapter` for each adapter,
/// then the launch. a contract that has code at its address is skipped and a state step whose effect is on chain is
/// skipped, so a run that stopped half way continues from the chain state. the recipients of the coin are not locked
/// here, the owner closes them as a separate step (`Lock`)
abstract contract SystemDeployer is LaunchChecks {
    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice a placeholder of the config is unset, or rateStart or a setting is out of bounds
    error ConfigUnset(string what);
    /// @notice the signer is not the address the operator named in DEPLOYER
    error DeployerMismatch(address want, address got);
    /// @notice CONFIG_HASH is not the hash of the config the script loaded. `want` is the hash of this config
    error ConfigHashMismatch(bytes32 got, bytes32 want);
    /// @notice the sender is not the factory owner, or not the config owner: the owner path of the factory is the only way in
    error NotFactoryOwner(address factoryOwner, address sender);
    /// @notice a transaction of the deploy would not fit under the per transaction gas cap
    error TxOverGasCap(uint256 step, uint256 gas);
    /// @notice an environment flag that names an owner change after launch is set. only `Postflight` honors them
    error ChangeFlagSet(string flag);

    /// @dev what a transaction costs on top of the execution gas measured inside the call: the base 21_000 and the
    /// calldata of the largest creation (about 30 kb at 16 gas a byte, a bound)
    uint256 internal constant TX_OVERHEAD = 520_000;
    /// @dev the steps of `stepGas`, in the order they are first sent
    uint256 internal constant STEPS = 8;

    /// @notice execution gas of the transactions of the last `deploySystem`: Core, controller, Seaport adapter,
    /// CreditStrategy adapter, `setController`, `addAdapter` of each adapter, launch. the library goes first and is
    /// measured by the rehearsal
    uint256[8] internal stepGas;

    /// @notice creates the Core at `coreAddress(c, launcher)`. the script (`NewProd`) uses `new` with `CORE_SALT`, a test
    /// base sends the creation code through the deterministic deployer, so the test contracts neither import the
    /// production sources nor embed their code
    function _newCore(LaunchConfig memory c, address launcher) internal virtual returns (address);

    /// @notice creates the controller at `controllerAddress(core, c)`: CREATE2 with `CONTROLLER_SALT`
    function _newController(address core, LaunchConfig memory c) internal virtual returns (address);

    /// @notice creates `SeaportBasicAdapter` at `seaportAdapterAddress(core, recipients)`: CREATE2 through the
    /// deterministic deployer with `SEAPORT_ADAPTER_SALT`
    function _newSeaportAdapter(address core, address[] memory recipients) internal virtual returns (address);

    /// @notice creates `CreditStrategyAdapter` at `strategyAdapterAddress()`: CREATE2 through the deterministic deployer
    /// with `STRATEGY_ADAPTER_SALT`
    function _newStrategyAdapter() internal virtual returns (address);

    /// @notice deploys and launches the whole system
    /// @param owner the address that sends every transaction: the broadcaster or the active prank, the factory owner
    /// and the first owner of the Core
    function deploySystem(address owner, LaunchConfig memory c) internal returns (Deployed memory d) {
        _requireConfig(c);
        _requireOwner(c, owner);
        d.core = _ensureCore(c, owner);
        d.controller = _ensureController(d.core, c);
        (d.seaportAdapter, d.strategyAdapter) = _ensureAdapters(d.core, c);
        _wire(c, d);
        d.coin = ICore(payable(d.core)).COIN();
        if (d.coin.code.length == 0) _launch(c, d.coin, d.core);
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));
    }

    function _ensureCore(LaunchConfig memory c, address owner) private returns (address at) {
        at = coreAddress(c, owner);
        if (at.code.length != 0) return at;
        uint256 g = gasleft();
        address made = _newCore(c, owner);
        _step(0, g);
        if (made != at) revert AddressMismatch("core");
    }

    function _ensureController(address core_, LaunchConfig memory c) private returns (address at) {
        at = controllerAddress(core_, c);
        if (at.code.length != 0) return at;
        uint256 g = gasleft();
        address made = _newController(core_, c);
        _step(1, g);
        if (made != at) revert AddressMismatch("controller");
    }

    function _ensureAdapters(address core_, LaunchConfig memory c)
        private
        returns (address seaportAt, address strategyAt)
    {
        seaportAt = seaportAdapterAddress(core_, c.seaportRecipients);
        if (seaportAt.code.length == 0) {
            uint256 g = gasleft();
            address made = _newSeaportAdapter(core_, c.seaportRecipients);
            _step(2, g);
            if (made != seaportAt) revert AddressMismatch("seaport adapter");
        }
        strategyAt = strategyAdapterAddress();
        if (strategyAt.code.length == 0) {
            uint256 g = gasleft();
            address made = _newStrategyAdapter();
            _step(3, g);
            if (made != strategyAt) revert AddressMismatch("strategy adapter");
        }
    }

    /// @dev the owner calls of the deploy: `setController`, then `addAdapter` for each adapter. a call whose effect is on
    /// chain is skipped
    function _wire(LaunchConfig memory c, Deployed memory d) private {
        ICore core = ICore(payable(d.core));
        if (core.controller() != d.controller) {
            uint256 g = gasleft();
            core.setController(d.controller);
            _step(4, g);
        }
        // the artist cut recipient is set post deploy (owner only); skipped when already on chain
        if (core.artist() != c.artist) core.setArtist(c.artist);
        if (!core.allowedAdapter(d.seaportAdapter)) {
            uint256 g = gasleft();
            core.addAdapter(d.seaportAdapter);
            _step(5, g);
        }
        if (!core.allowedAdapter(d.strategyAdapter)) {
            uint256 g = gasleft();
            core.addAdapter(d.strategyAdapter);
            _step(6, g);
        }
    }

    function _step(uint256 i, uint256 gasBefore) internal {
        uint256 used = gasBefore - gasleft();
        stepGas[i] = used;
        if (used + TX_OVERHEAD > TX_GAS_CAP) revert TxOverGasCap(i, used);
    }

    /// @notice the sender must be the factory owner and the config owner
    function _requireOwner(LaunchConfig memory c, address sender) internal view {
        (bool ok, address fo) = _addr(c.stack.factory, abi.encodeCall(IArtCoinsFactoryV2.owner, ()));
        if (!ok || fo != sender || c.owner != sender) revert NotFactoryOwner(fo, sender);
    }

    /// @notice the launch through the factory as its owner, paying the live deploy fee, with the Core as bounty
    /// recipient. checks the coin address against the one the Core computed
    function _launch(LaunchConfig memory c, address coinAt, address core) internal returns (address coin) {
        IArtCoinsFactoryV2 factory = IArtCoinsFactoryV2(c.stack.factory);
        uint256 fee = factory.deployFee();
        uint256 g = gasleft();
        coin = factory.deployTokenAsOwner{value: fee}(buildConfig(c, c.owner, core), c.protocolBps);
        _step(7, g);
        if (coin != coinAt) revert AddressMismatch("coin");
    }

    /// @notice reverts unless the signer is the deployer the operator named
    function _requireDeployer(address want, address got) internal pure {
        if (want == address(0) || want != got) revert DeployerMismatch(want, got);
    }

    /// @notice reverts when SETTINGS_CHANGED or COIN_CHANGED is set. `Deploy` and `Resume` send transactions that assume
    /// the launch state, and each flag turns failed rows into warnings
    function _requireNoChangeFlags() internal view {
        if (_settingsChanged()) revert ChangeFlagSet("SETTINGS_CHANGED");
        if (_coinChanged()) revert ChangeFlagSet("COIN_CHANGED");
    }

    /// @notice the sign off value: reverts unless `given` is the hash of this config
    function _requireConfigHash(LaunchConfig memory c, bytes32 given) internal view {
        bytes32 want = configHash(c);
        if (given != want) revert ConfigHashMismatch(given, want);
    }

    /// @notice reverts when a placeholder is unset or rateStart or a setting is out of bounds
    function _requireConfig(LaunchConfig memory c) internal pure {
        string[] memory unset = unsetFields(c);
        if (unset.length != 0) revert ConfigUnset(unset[0]);
        if (!rateInBounds(c)) revert ConfigUnset("rateStart");
        if (settingsViolation(c) != 0) revert ConfigUnset("settings");
        if (saleViolation(c) != 0) revert ConfigUnset("sale");
        if (creditViolation(c) != 0) revert ConfigUnset("credit");
    }
}
