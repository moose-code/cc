// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet, Stack, Settings} from "../src/interfaces/Interfaces.sol";
import {ICoreLib} from "../src/interfaces/ICoreLib.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {ISeaportBasicAdapter} from "../src/interfaces/ISeaportBasicAdapter.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {PostflightPool} from "./PostflightPool.sol";

/// @notice reads a launched system back and compares it with the config. read only, safe against mainnet any time.
/// run it right after the launch: the supply and rate rows are exact at launch and tolerant once trading started.
/// the rows that the owner can change afterwards (settings, locks, owner, the coin) turn into warnings when the
/// operator names the change: SETTINGS_CHANGED, LOCKS_CHANGED, OWNER_CHANGED, COIN_CHANGED = 1
abstract contract PostflightChecks is PostflightPool {
    /// @notice the deployer of the launch from the environment (DEPLOYER), zero when not given. a test overrides it
    function _deployerEnv() internal view virtual returns (address) {
        return vm.envOr("DEPLOYER", address(0));
    }

    function postflight(LaunchConfig memory c, address core_) internal {
        postflightAs(c, core_, _deployerEnv());
    }

    /// @notice every postflight row. `deployer` (zero when unknown) adds the rows that need the creation nonces: the
    /// controller was created by it right before the Core, and the coin equals the factory prediction
    function postflightAs(LaunchConfig memory c, address core_, address deployer) internal {
        _reset();
        _code("code: core", core_);
        if (core_.code.length == 0) return;
        ICore core = ICore(payable(core_));
        _postCore(c, core);
        address coin = core.COIN();
        _code("code: coin", coin);
        if (coin.code.length == 0) return;
        bytes32 poolId = _postPool(c, core_, coin);
        _postCoin(c, core_, coin, poolId);
        _postPayee(c, core);
        _postAdapters(c, core);
        _postPrediction(c, coin, deployer, core_);
        _postUnreadable(c);
    }

    /// @dev the coin equals the factory's prediction for the deployer. the prediction reads mutable factory state (the
    /// default allowlist, the hook escrow), so a later change of it is a warning, never a failure. it proves the allowlist
    /// the coin was built with when the factory state is still the launch state
    function _postPrediction(LaunchConfig memory c, address coin, address deployer, address core_) private {
        if (deployer == address(0)) return;
        (bool ok,) = _coreNonce(core_, deployer);
        if (!ok) return;
        (bool okp, address want) = _predict(c, deployer, core_);
        _warn("warn: coin equals the factory prediction for the deployer", okp && want == coin, vm.toString(want));
    }

    /// @dev the deterministic deployer that `forge script` sends the library and the listing adapters through (CREATE2)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev the CREATE2 salts of the two listing adapters
    bytes32 internal constant SEAPORT_ADAPTER_SALT = keccak256("credits.core.seaportAdapter.v1");
    bytes32 internal constant STRATEGY_ADAPTER_SALT = keccak256("credits.core.strategyAdapter.v1");

    /// @notice the address of `SeaportBasicAdapter` for `core_` and the launch allowlist `recipients`: CREATE2 through
    /// the deterministic deployer with `SEAPORT_ADAPTER_SALT` and the creation code with the Core and the recipients as
    /// constructor arguments
    function seaportAdapterAddress(address core_, address[] memory recipients) internal view returns (address) {
        bytes memory init =
            abi.encodePacked(vm.getCode("SeaportBasicAdapter.sol:SeaportBasicAdapter"), abi.encode(core_, recipients));
        return vm.computeCreate2Address(SEAPORT_ADAPTER_SALT, keccak256(init), CREATE2_DEPLOYER);
    }

    /// @notice the address of `CreditStrategyAdapter`: CREATE2 through the deterministic deployer with
    /// `STRATEGY_ADAPTER_SALT` and the creation code (no constructor arguments)
    function strategyAdapterAddress() internal view returns (address) {
        return vm.computeCreate2Address(
            STRATEGY_ADAPTER_SALT,
            keccak256(vm.getCode("CreditStrategyAdapter.sol:CreditStrategyAdapter")),
            CREATE2_DEPLOYER
        );
    }

    /// @notice the adapter list of the Core constructor at launch: the Seaport adapter, then the CreditStrategy adapter
    function launchAdapters(address core_, LaunchConfig memory c) internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = seaportAdapterAddress(core_, c.seaportRecipients);
        a[1] = strategyAdapterAddress();
    }

    /// @dev both adapters have the compiled code, the Seaport adapter points at the Core and holds the config allowlist,
    /// and the Core approves both and no stack contract
    function _postAdapters(LaunchConfig memory c, ICore core) private {
        (address seaportAt, address strategyAt) = (
            seaportAdapterAddress(address(core), c.seaportRecipients), strategyAdapterAddress()
        );
        _code("code: seaport adapter", seaportAt);
        _code("code: strategy adapter", strategyAt);
        _check(
            "adapters: runtime code is the compiled adapters (immutables masked)",
            runtimeMatchesArtifact(seaportAt, "SeaportBasicAdapter")
                && runtimeMatchesArtifact(strategyAt, "CreditStrategyAdapter"),
            string.concat(vm.toString(seaportAt), " ", vm.toString(strategyAt))
        );
        if (seaportAt.code.length != 0) {
            ISeaportBasicAdapter a = ISeaportBasicAdapter(seaportAt);
            _eq("adapters: seaport adapter core", a.CORE(), address(core));
            bool listed = true;
            for (uint256 i; i < c.seaportRecipients.length; ++i) {
                listed = listed && a.allowedRecipient(c.seaportRecipients[i]);
            }
            _check("adapters: seaport recipients are the config allowlist", listed, "fee collector allowed");
        }
        // the owner may remove an adapter or add another after launch: LOCKS_CHANGED=1 turns the row into a warning
        bool allowed = core.allowedAdapter(seaportAt) && core.allowedAdapter(strategyAt);
        if (_locksChanged()) {
            _warn("warn: adapters are allowed", allowed, "LOCKS_CHANGED=1, the owner changed them");
        } else {
            _check("adapters: both are allowed in the Core", allowed, "seaport and CreditStrategy adapters");
        }
        _check(
            "adapters: no stack contract is allowed",
            !core.allowedAdapter(c.stack.hook) && !core.allowedAdapter(c.stack.factory)
                && !core.allowedAdapter(c.stack.locker) && !core.allowedAdapter(c.stack.escrow)
                && !core.allowedAdapter(c.stack.poolManager) && !core.allowedAdapter(core.COIN())
                && !core.allowedAdapter(address(core)),
            "hook, factory, locker, escrow, pool manager, coin, core"
        );
    }

    /// @dev nonces to scan down from the deployer nonce when looking for the creation of the Core
    uint256 internal constant NONCE_SCAN = 4096;

    /// @notice the operator names the first controller by hand (FIRST_CONTROLLER) when the deployer is unknown. a test
    /// overrides it
    function _firstControllerEnv() internal view virtual returns (address) {
        return vm.envOr("FIRST_CONTROLLER", address(0));
    }

    /// @notice the controller the Core was created with, never read from the Core: the deploy creates the controller at
    /// the deployer nonce n and the Core at n + 1 (`SystemDeployer.deploySystem`), so it is the create
    /// address one nonce before the one that gives `core_`. scans down from the deployer nonce. `found` is false when the deployer is
    /// unknown and FIRST_CONTROLLER is not set, or the scan finds nothing
    function firstController(address core_, address deployer) internal view returns (address ctl, bool found) {
        address named = _firstControllerEnv();
        if (named != address(0)) return (named, true);
        (bool ok, uint256 n) = _coreNonce(core_, deployer);
        if (!ok) return (address(0), false);
        return (vm.computeCreateAddress(deployer, n - 1), true);
    }

    /// @notice the deployer nonce the Core was created at, scanning down from the deployer nonce. the deploy creates the
    /// controller at n - 1 and the Core at n (`SystemDeployer.deploySystem`)
    function _coreNonce(address core_, address deployer) internal view returns (bool, uint256) {
        if (deployer == address(0)) return (false, 0);
        uint256 top = vm.getNonce(deployer);
        uint256 stop = top > NONCE_SCAN ? top - NONCE_SCAN : 1;
        if (stop < 1) stop = 1;
        for (uint256 n = top; n >= stop; --n) {
            if (vm.computeCreateAddress(deployer, n) == core_) return (true, n);
        }
        return (false, 0);
    }

    /// @notice the constructor arguments of the Core as its creation transaction carried them, in the encoding etherscan
    /// wants for verification: `(owner, cfg, launcher, coin, controller, payee, stack, rateStart, settings, credit, adapters)`.
    /// built only from the signed launch config, the deployer and the first controller: the original owner `c.owner`,
    /// the launch config with the zero address as bounty recipient, the zero address as `coin`, `c.payee`, `c.stack`, `c.rateStart`, `c.settings` and
    /// `c.credit`. nothing here reads the live `owner`, `controller`, `payee`, `settings` or credit settings, all of
    /// which the owner can change after launch (audit finding A02)
    function coreConstructorArgs(ICore core, LaunchConfig memory c, address firstController_, address deployer)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            c.owner,
            buildConfig(c, c.owner, address(0)),
            deployer,
            address(0),
            firstController_,
            c.payee,
            c.stack,
            c.rateStart,
            c.settings,
            c.credit,
            launchAdapters(address(core), c)
        );
    }

    /// @notice prints what etherscan verification needs: the library address and the exact `--libraries` flag, the
    /// constructor arguments of the Core (from the config, see `coreConstructorArgs`) and of the controller, then the
    /// live controller and settings on separate lines labelled as live. docs/RUNBOOK.md section 3. `deployer` is the
    /// address that sent the deploy, it finds the first controller
    function printVerifyInputs(ICore core, LaunchConfig memory c, address deployer) internal view {
        address lib = findLibrary(address(core).code);
        console.log("verify: library CoreLib at", lib);
        console.log(string.concat("verify: flag  --libraries src/lib/CoreLib.sol:CoreLib:", vm.toString(lib)));
        (address first, bool found) = firstController(address(core), deployer);
        if (found) {
            console.log("verify: first controller (creation input)", first);
            console.log("verify: core constructor args");
            console.logBytes(coreConstructorArgs(core, c, first, deployer));
            console.log("verify: controller constructor args");
            console.logBytes(abi.encode(address(core), c.sale, c.credit));
            console.log("verify: seaport adapter constructor args");
            console.logBytes(abi.encode(address(core), c.seaportRecipients));
        } else {
            console.log(
                "verify: core constructor args NOT printed: set DEPLOYER (the deploy signer) or FIRST_CONTROLLER"
            );
        }
        // the live values are not constructor inputs: the owner can change them at any time
        console.log("verify: LIVE controller now, NOT a constructor input", core.controller());
        console.log("verify: LIVE settings now, NOT a constructor input, abi encoded");
        console.logBytes(abi.encode(core.settings()));
        console.log("verify: LIVE owner now, NOT a constructor input", core.owner());
        if (found && core.controller() != first) console.log("verify: note the live controller is not the first one");
    }

    function _postCore(LaunchConfig memory c, ICore core) private {
        // after a handover the live owner is the new one: OWNER_CHANGED=1 turns the row into a warning
        if (_ownerChanged()) {
            _warn("warn: owner equals the config", core.owner() == c.owner, "OWNER_CHANGED=1, a handover ran");
        } else {
            _eq("core: owner", core.owner(), c.owner);
        }
        _eq("core: RATE_START", core.RATE_START(), c.rateStart);
        _postSettings(c, core);
        _postLibrary(core);
        _eq("core: pool manager", address(core.MANAGER()), c.stack.poolManager);
        _eq("core: hook", core.HOOK(), c.stack.hook);
        _eq("core: tick spacing", uint256(int256(core.TICK_SPACING())), uint256(int256(c.stack.tickSpacing)));
        _eq("core: pool fee", uint256(core.POOL_FEE()), uint256(c.stack.poolFee));
        _eq("core: factory", core.FACTORY(), c.stack.factory);
        _eq("core: locker", core.LOCKER(), c.stack.locker);
        _eq("core: escrow", core.ESCROW(), c.stack.escrow);
        _check(
            "code: stack addresses",
            c.stack.poolManager.code.length != 0 && c.stack.hook.code.length != 0 && c.stack.factory.code.length != 0
                && c.stack.locker.code.length != 0 && c.stack.escrow.code.length != 0,
            "pool manager, hook, factory, locker, escrow"
        );
        address ctl = core.controller();
        _code("code: controller", ctl);
        if (ctl.code.length != 0) _eq("controller: core", address(IControllerV1(ctl).CORE()), address(core));
        _check(
            "core: runtime code is the compiled Core (immutables and the library address masked)",
            runtimeMatchesArtifact(address(core), "Core"),
            vm.toString(address(core))
        );
        _check(
            "controller: runtime code is the compiled ControllerV1 (immutables masked)",
            runtimeMatchesArtifact(ctl, "ControllerV1"),
            vm.toString(ctl)
        );
        uint256[] memory ctlWant = new uint256[](1);
        ctlWant[0] = uint256(uint160(address(core)));
        _check(
            "controller: every CORE slot of the runtime code is the Core",
            runtimeSlotsMatch(ctl, "ControllerV1", address(0), ctlWant),
            "the 28 immutable sites of the controller runtime code"
        );
        // after launch the owner may lock or set the balance module: LOCKS_CHANGED=1 turns the row into a report line
        bool launchState = !core.controllerLocked() && !core.balanceModuleLocked() && !core.adaptersLocked()
            && core.balanceModule() == address(0);
        if (_locksChanged()) {
            _warn("warn: no locks, no balance module", launchState, "LOCKS_CHANGED=1, the owner changed them");
        } else {
            _check("core: no locks, no balance module", launchState, "launch state");
        }
        _warn("warn: no pending owner", core.pendingOwner() == address(0), "an owner handover is offered");
        _postSale(c, ctl);
        _check(
            "core: pots covered by balance",
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() + core.payeeOwed() <= address(core).balance,
            string.concat("balance ", vm.toString(address(core).balance))
        );
        // the stored price state moves once the pot is funded or a credit is bought, and the owner may reset it with
        // `setRate`, so it is exact only at launch: a difference is a warning. the read `ethRate()` is zero while the pot is
        // empty
        _warn(
            "warn: price state is rateStart",
            core.ethPot() != 0 || core.rateAtCheckpoint() == c.rateStart,
            string.concat(
                "rateAtCheckpoint ", vm.toString(core.rateAtCheckpoint()), " rateStart ", vm.toString(c.rateStart)
            )
        );
    }

    /// @notice the operator says the owner locked a setter or set the balance module since launch (LOCKS_CHANGED=1). a test
    /// overrides it
    function _locksChanged() internal view virtual returns (bool) {
        return vm.envOr("LOCKS_CHANGED", uint256(0)) == 1;
    }

    /// @notice the operator says the owner role was handed over since launch (OWNER_CHANGED=1). a test overrides it
    function _ownerChanged() internal view virtual returns (bool) {
        return vm.envOr("OWNER_CHANGED", uint256(0)) == 1;
    }

    /// @dev the sale settings of the controller must equal the config, like the core settings (SETTINGS_CHANGED=1 turns
    /// the row into a warning once the owner changed them)
    function _postSale(LaunchConfig memory c, address ctl) private {
        if (ctl.code.length == 0) return;
        IControllerV1 k = IControllerV1(ctl);
        bool same = k.markupBps() == c.sale.markupBps
            && k.startCapBps() == c.sale.startCapBps && k.fastDecayBpsPerHour() == c.sale.fastDecayBpsPerHour
            && k.kneeBps() == c.sale.kneeBps && k.slowDecayBpsPerHour() == c.sale.slowDecayBpsPerHour
            && k.anchorHalfLife() == c.sale.anchorHalfLife
            && k.anchorMinCost() == c.sale.anchorMinCost;
        if (_settingsChanged()) {
            _warn(
                "warn: sale settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch"
            );
        } else {
            _check("controller: sale settings equal the config", same, "markupBps startCapBps fastDecayBpsPerHour kneeBps slowDecayBpsPerHour anchorHalfLife anchorMinCost");
        }
        // a fresh launch has no sales and no owner change, so the running level of sale prices is at its lower bound
        bool anchored = k.anchorBps() == 10_000;
        if (_settingsChanged()) {
            _warn("warn: controller anchor is 10_000", anchored, "SETTINGS_CHANGED=1, sales or the owner moved it since launch");
        } else {
            _check("controller: anchor is 10_000", anchored, vm.toString(k.anchorBps()));
        }
        bool creditSame = k.creditSaleOn() == c.credit.saleOn && k.creditWindow() == c.credit.window
            && k.creditFloorBps() == c.credit.floorBps && k.creditStartBps() == c.credit.startBps
            && k.refScore() == c.credit.refScore && k.royaltyBps() == c.credit.royaltyBps
            && k.royaltyRecipient() == c.credit.royaltyRecipient;
        if (_settingsChanged()) {
            _warn(
                "warn: credit sale settings equal the config",
                creditSame,
                "SETTINGS_CHANGED=1, the owner changed them since launch"
            );
        } else {
            _check(
                "controller: credit sale settings equal the config",
                creditSame,
                "creditSaleOn creditWindow creditFloorBps creditStartBps refScore royaltyBps royaltyRecipient"
            );
        }
        _info(
            "controller: sale",
            string.concat(
                "markup ",
                vm.toString(k.markupBps()),
                " start cap ",
                vm.toString(k.startCapBps()),
                " fast decay ",
                vm.toString(k.fastDecayBpsPerHour()),
                " bps/h to knee ",
                vm.toString(k.kneeBps()),
                " then slow decay ",
                vm.toString(k.slowDecayBpsPerHour()),
                " anchor ",
                vm.toString(k.anchorBps()),
                " anchor half life ",
                vm.toString(k.anchorHalfLife()),
                "s anchor min cost ",
                vm.toString(k.anchorMinCost()),
                " wei"
            )
        );
    }

    /// @notice the operator says the owner changed the settings since launch (SETTINGS_CHANGED=1). a test overrides it
    function _settingsChanged() internal view virtual returns (bool) {
        return vm.envOr("SETTINGS_CHANGED", uint256(0)) == 1;
    }

    /// @dev the settings are owner adjustable after launch. right after the deploy they must equal the config field by
    /// field, so a Core built with other values fails. once the owner has called `setSettings` the live values differ
    /// on purpose: run with SETTINGS_CHANGED=1 and the row turns into a warning that prints the difference
    function _postSettings(LaunchConfig memory c, ICore core) private {
        Settings memory live = core.settings();
        bytes32 bad = SettingsBounds.firstViolation(live);
        _check("core: settings inside the bounds", bad == 0, bad == 0 ? "all fields" : string(abi.encodePacked(bad)));
        bool same = keccak256(abi.encode(live)) == keccak256(abi.encode(c.settings));
        if (_settingsChanged()) {
            _warn("warn: settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch");
        } else {
            _check(
                "core: settings equal the config",
                same,
                "set SETTINGS_CHANGED=1 only after the owner called setSettings"
            );
        }
        bool creditSame = core.creditCostToPotBps() == c.credit.costToPotBps
            && core.chosenComposeOn() == c.credit.chosenComposeOn && core.minCcToChoose() == c.credit.minCcToChoose;
        if (_settingsChanged()) {
            _warn(
                "warn: core credit settings equal the config",
                creditSame,
                "SETTINGS_CHANGED=1, the owner changed them since launch"
            );
        } else {
            _check(
                "core: credit settings equal the config",
                creditSame,
                "creditCostToPotBps chosenComposeOn minCcToChoose"
            );
        }
        // sales are open until the owner pauses them
        if (_settingsChanged()) {
            _warn("warn: core is not paused", !core.paused(), "SETTINGS_CHANGED=1, the owner paused sales since launch");
        } else {
            _check("core: not paused", !core.paused(), core.paused() ? "paused" : "not paused");
        }
        _info(
            "core: rate cap", string.concat("rateCap ", vm.toString(live.rateCap))
        );
        _check("core: ethRate at most rateCap", core.ethRate() <= live.rateCap, vm.toString(core.ethRate()));
        _info(
            "core: sale floor",
            string.concat("saleFloorBps ", vm.toString(live.saleFloorBps))
        );
        _info(
            "core: splits",
            string.concat(
                "sale to buyback ",
                vm.toString(live.saleToBuybackBps),
                " fee to redeem burn ",
                vm.toString(live.feeToRedeemBurnBps),
                " payee ppm ",
                vm.toString(live.payeePpm)
            )
        );
        _info(
            "core: balance side",
            string.concat(
                "redeemOn ",
                live.redeemOn ? "true" : "false",
                " balanceBidOn ",
                live.balanceBidOn ? "true" : "false",
                " redeem slippage ",
                vm.toString(live.redeemSlippageBps),
                " balance bid margin ",
                vm.toString(live.balanceBidMarginBps),
                " redeem burn ",
                vm.toString(live.redeemBurnBps),
                " (bps)"
            )
        );
    }

    /// @dev the Core is linked against `CoreLib`: its address is the operand of eight push20 sites in the Core runtime
    /// code. the first row finds a push20 operand whose code is the compiled library (its own address masked out). the
    /// second reads every library address slot and every immutable slot of the Core runtime code and requires each to
    /// hold that library or the value the matching getter returns, because the identity hash masks all of them
    function _postLibrary(ICore core) private {
        address found = findLibrary(address(core).code);
        _check(
            "core: linked library is the compiled CoreLib",
            found != address(0),
            string.concat("library at ", vm.toString(found))
        );
        uint256[] memory want = new uint256[](10);
        want[0] = uint256(uint160(core.COIN()));
        want[1] = core.RATE_START();
        want[2] = uint256(uint160(address(core.MANAGER())));
        want[3] = uint256(uint160(core.HOOK()));
        want[4] = uint256(int256(core.TICK_SPACING()));
        want[5] = uint256(core.POOL_FEE());
        want[6] = uint256(uint160(core.FACTORY()));
        want[7] = uint256(uint160(core.LOCKER()));
        want[8] = uint256(uint160(core.ESCROW()));
        want[9] = core.SNIPER_SECONDS();
        _check(
            "core: every library call site and every immutable slot holds the library or the getter value",
            found != address(0) && runtimeSlotsMatch(address(core), "Core", found, want),
            "the 8 CoreLib call sites and the 27 immutable sites of the Core runtime code"
        );
    }

    /// @notice the address of the compiled `CoreLib` inside a Core runtime code (a push20 whose target has the library
    /// runtime code, own address masked out), zero when there is none
    function findLibrary(bytes memory code) internal view returns (address found) {
        bytes memory expected = vm.getDeployedCode("CoreLib.sol:CoreLib");
        bytes32 want = _tailHash(expected);
        for (uint256 i; i + 21 <= code.length; ++i) {
            address cand;
            bool push20;
            assembly ("memory-safe") {
                push20 := eq(byte(0, mload(add(add(code, 0x20), i))), 0x73)
                cand := shr(96, mload(add(add(code, 0x21), i)))
            }
            if (!push20) continue;
            // the size is read without copying the code: only a candidate of the right size is copied and hashed
            if (cand.code.length == expected.length && expected.length >= 39 && _tailHash(cand.code) == want) return cand;
        }
    }

    /// @notice whether `lc` is the runtime code of the compiled `CoreLib`, its own address masked out
    function isCompiledLibrary(bytes memory lc) internal view returns (bool) {
        bytes memory expected = vm.getDeployedCode("CoreLib.sol:CoreLib");
        return lc.length == expected.length && lc.length >= 39 && _tailHash(lc) == _tailHash(expected);
    }

    /// @dev hash of library runtime code with its own address masked out. a library starts with
    /// `PUSH1 0x80 PUSH1 0x40 MSTORE ADDRESS PUSH32 <its own address>` (the guard against a direct call), the 32 bytes
    /// at offset 7 differ between the compiled code and a deployed copy
    function _tailHash(bytes memory b) private pure returns (bytes32 h) {
        bytes memory c = bytes.concat(b);
        assembly ("memory-safe") {
            mstore(add(add(c, 0x20), 7), 0)
            h := keccak256(add(c, 0x20), mload(c))
        }
    }

    /// @dev the payee state of the Core: the payee is the config payee, the share starts after the launch window. the
    /// owner can replace the payee afterwards (SETTINGS_CHANGED=1 turns the row into a warning). the share state and the
    /// owed amount move once trading runs, so they are rows that are exact only at launch
    function _postPayee(LaunchConfig memory c, ICore core) private {
        _soft(
            _settingsChanged(),
            "core: payee equals the config",
            core.payee() == c.payee,
            vm.toString(core.payee()),
            "SETTINGS_CHANGED=1"
        );
        _warn("warn: payee share is not on yet", !core.payeeOn(), "payeeOn: the first book after the window turned it on");
        _warn("warn: payee owes nothing", core.payeeOwed() == 0, string.concat("payeeOwed ", vm.toString(core.payeeOwed())));
        _eq("core: SNIPER_SECONDS equals the config", core.SNIPER_SECONDS(), uint256(c.sniperSeconds));
        _info(
            "core: payee share",
            string.concat(vm.toString(core.settings().payeePpm), " ppm of the fee income, unclaimed ", vm.toString(core.payeeOwed()), " wei")
        );
    }

    /// @dev what a read back cannot cover, said in the output
    function _postUnreadable(LaunchConfig memory c) private {
        _info(
            "not readable on chain",
            "protocolBps argument, sniper fee config, the deploy fee paid, the salt itself"
        );
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }
}
