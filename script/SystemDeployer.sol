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
    address lens;
    address seaportAdapter;
    address strategyAdapter;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `owner`, who must be the v2 factory owner and the config owner (a deprecated v2 factory takes only its owner, through
/// `deployTokenAsOwner`). order (docs/DECISIONS.md 10.4): the library `CoreLib` (linked by `forge script` before `run`), the
/// controller, the Core (its constructor takes the launch config with the Core as bounty recipient and computes the coin
/// address with the factory's `predictToken`), the lens `CoreLens` (read only, pointing at the Core), the two listing
/// adapters (CREATE2 through the deterministic deployer, their addresses are passed to the Core constructor), then the
/// launch. the controller and Core addresses are predicted and every prediction is checked after creation. the
/// recipients of the coin are not locked here, the owner closes them as a separate step (`Lock`)
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
    /// @notice CONTROLLER_NONCE is not the nonce the controller would be created at now. `want` is that nonce
    error ControllerNonceMismatch(uint256 got, uint256 want);

    /// @dev what a transaction costs on top of the execution gas measured inside the call: the base 21_000 and the
    /// calldata of the largest creation (about 30 kb at 16 gas a byte, a bound)
    uint256 internal constant TX_OVERHEAD = 520_000;
    /// @dev the steps of `stepGas`, in the order they are sent
    uint256 internal constant STEPS = 6;

    /// @notice execution gas of the transactions of the last `deploySystem`: controller, core, launch, lens, Seaport
    /// adapter, CreditStrategy adapter (sent right after the core). the library goes first and is measured by the rehearsal
    uint256[6] internal stepGas;

    /// @notice creates the controller and the core. the script (`NewProd`) uses `new`, a test base uses
    /// `deployCode` on the artifacts, so the test contracts neither import the production sources nor embed their code
    function _newController(address core, LaunchConfig memory c) internal virtual returns (address);

    /// @notice creates the lens of `core` at `lensAddress(core)`: CREATE2 through the deterministic deployer with `LENS_SALT`
    function _newLens(address core) internal virtual returns (address);

    /// @notice creates `SeaportBasicAdapter` at `seaportAdapterAddress(core, recipients)`: CREATE2 through the
    /// deterministic deployer with `SEAPORT_ADAPTER_SALT`
    function _newSeaportAdapter(address core, address[] memory recipients) internal virtual returns (address);

    /// @notice creates `CreditStrategyAdapter` at `strategyAdapterAddress()`: CREATE2 through the deterministic deployer
    /// with `STRATEGY_ADAPTER_SALT`
    function _newStrategyAdapter() internal virtual returns (address);

    /// @notice creates the Core. `cfg` is the launch config with the zero address as bounty recipient (the Core sets
    /// itself), `launcher` is the sender of the launch transaction
    function _newCore(
        address owner,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg,
        address launcher,
        address controller,
        LaunchConfig memory c,
        address[] memory adapters
    ) internal virtual returns (address);

    /// @notice deploys and launches the whole system
    /// @param owner the address that sends every transaction: the broadcaster or the active prank, the factory owner
    /// and the first owner of the Core
    function deploySystem(address owner, LaunchConfig memory c) internal returns (Deployed memory d) {
        _requireConfig(c);
        _requireOwner(c, owner);
        uint64 nonce = vm.getNonce(owner);
        address controllerAt = vm.computeCreateAddress(owner, nonce);
        address coreAt = vm.computeCreateAddress(owner, nonce + 1);

        uint256 g = gasleft();
        d.controller = _newController(coreAt, c);
        _step(0, g);
        g = gasleft();
        d.core = _newCore(c.owner, buildConfig(c, c.owner, address(0)), owner, d.controller, c, launchAdapters(coreAt, c));
        _step(1, g);
        if (d.controller != controllerAt) revert AddressMismatch("controller");
        if (d.core != coreAt) revert AddressMismatch("core");
        g = gasleft();
        d.lens = _newLens(d.core);
        _step(3, g);
        if (d.lens != lensAddress(d.core)) revert AddressMismatch("lens");
        (d.seaportAdapter, d.strategyAdapter) = _ensureAdapters(d.core, c);

        d.coin = _launch(c, ICore(payable(d.core)).COIN(), d.core);
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));
    }

    /// @dev creates each adapter that has no code at its address. the addresses are functions of the Core and the config,
    /// so a run that stopped after the Core sends the missing ones whatever the deployer nonce is
    function _ensureAdapters(address core_, LaunchConfig memory c)
        internal
        returns (address seaportAt, address strategyAt)
    {
        seaportAt = seaportAdapterAddress(core_, c.seaportRecipients);
        if (seaportAt.code.length == 0) {
            uint256 g = gasleft();
            address made = _newSeaportAdapter(core_, c.seaportRecipients);
            _step(4, g);
            if (made != seaportAt) revert AddressMismatch("seaport adapter");
        }
        strategyAt = strategyAdapterAddress();
        if (strategyAt.code.length == 0) {
            uint256 g = gasleft();
            address made = _newStrategyAdapter();
            _step(5, g);
            if (made != strategyAt) revert AddressMismatch("strategy adapter");
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
        _step(2, g);
        if (coin != coinAt) revert AddressMismatch("coin");
    }

    /// @notice reverts unless the signer is the deployer the operator named
    function _requireDeployer(address want, address got) internal pure {
        if (want == address(0) || want != got) revert DeployerMismatch(want, got);
    }

    /// @notice reverts when any of SETTINGS_CHANGED, LOCKS_CHANGED, OWNER_CHANGED or COIN_CHANGED is set.
    /// `Deploy` and `Resume` send transactions that assume the launch state, and each flag turns failed rows into warnings
    function _requireNoChangeFlags() internal view {
        if (_settingsChanged()) revert ChangeFlagSet("SETTINGS_CHANGED");
        if (_locksChanged()) revert ChangeFlagSet("LOCKS_CHANGED");
        if (_ownerChanged()) revert ChangeFlagSet("OWNER_CHANGED");
        if (_coinChanged()) revert ChangeFlagSet("COIN_CHANGED");
    }

    /// @notice reverts unless `given` is the nonce the controller is created at: the nonce preflight printed. any owner
    /// transaction after preflight moves the predicted controller and core addresses
    function _requireControllerNonce(address deployer, uint256 given) internal view {
        uint256 want = _controllerNonce(deployer);
        if (given != want) revert ControllerNonceMismatch(given, want);
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
