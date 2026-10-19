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
/// the rows that the owner can change afterwards (settings, the coin) turn into warnings when the operator names the
/// change: SETTINGS_CHANGED, COIN_CHANGED = 1
abstract contract PostflightChecks is PostflightPool {
    error PrelaunchRateSignoff(bytes32 want, bytes32 given);
    error PrelaunchRateOutOfBounds(uint256 rate);

    /// @notice the deployer of the launch from the environment (DEPLOYER), zero when not given. a test overrides it
    function _deployerEnv() internal view virtual returns (address) {
        return vm.envOr("DEPLOYER", address(0));
    }

    function postflight(LaunchConfig memory c, address core_) internal {
        postflightAs(c, core_, _deployerEnv());
    }

    /// @notice every postflight row. `deployer` (zero when unknown) adds the rows that need the sender of the deploy:
    /// the Core address is the CREATE2 address of the config and the deployer, and the coin equals the factory prediction
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
        _postIdentity(c, coin, deployer, core_);
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }

    /// @notice the postflight of a deploy that stopped before the launch (`DEFER_LAUNCH=1`): the Core, payee and adapter
    /// rows, the Core address row, and four coin rows. the coin is the address the Core holds as its immutable: it has
    /// no code, the factory has no launch record for it, and it equals the factory prediction for `deployer`. the pool
    /// and coin rows run after the launch (`postflightAs`)
    function postflightDeferred(LaunchConfig memory c, address core_, address deployer) internal {
        _reset();
        _code("code: core", core_);
        if (core_.code.length == 0) return;
        ICore core = ICore(payable(core_));
        _postCore(c, core);
        address coin = core.COIN();
        _noCode("deferred: coin has no code", coin);
        (bool okr, bool recorded) = _bool(c.stack.factory, abi.encodeCall(IArtCoinsFactoryV2.isCoin, (coin)));
        _check("deferred: coin salt is unused on the factory", okr && !recorded, vm.toString(coin));
        _postPayee(c, core);
        _postAdapters(c, core);
        if (deployer != address(0)) {
            _eq("core: address is the CREATE2 address of the config and the deployer", core_, coreAddress(c, deployer));
            (bool okp, address want) = _predict(c, deployer, core_);
            _check("deferred: coin equals the factory prediction for the deployer", okp && want == coin, vm.toString(want));
        }
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }

    /// @dev with the deployer known, the Core address is `coreAddress(c, deployer)`, which commits to the creation code
    /// and every constructor argument. the coin equals the factory's prediction for the deployer. the prediction reads
    /// mutable factory state (the default allowlist, the hook escrow), so a later change of it is a warning
    function _postIdentity(LaunchConfig memory c, address coin, address deployer, address core_) private {
        if (deployer == address(0)) return;
        _eq("core: address is the CREATE2 address of the config and the deployer", core_, coreAddress(c, deployer));
        (bool okp, address want) = _predict(c, deployer, core_);
        _warn("warn: coin equals the factory prediction for the deployer", okp && want == coin, vm.toString(want));
    }

    /// @dev the deterministic deployer that `forge script` sends every contract of ours through (CREATE2)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev the CREATE2 salts of the contracts of the deploy. the creation code and the constructor arguments are part of
    /// each address, so a fixed salt gives one address per config and deployer
    bytes32 internal constant CORE_SALT = keccak256("credits.core.v1");
    bytes32 internal constant CONTROLLER_SALT = keccak256("credits.controller.v1");
    bytes32 internal constant SEAPORT_ADAPTER_SALT = keccak256("credits.core.seaportAdapter.v1");
    bytes32 internal constant STRATEGY_ADAPTER_SALT = keccak256("credits.core.strategyAdapter.v1");

    /// @notice the address `forge script` gives the linked library `CoreLib`: CREATE2 through the deterministic deployer,
    /// salt zero, the creation code of the compiled library. it depends on the compiler output only
    function libraryAddress() internal view returns (address) {
        return vm.computeCreate2Address(bytes32(0), keccak256(vm.getCode("CoreLib.sol:CoreLib")), CREATE2_DEPLOYER);
    }

    /// @notice the CREATE2 address of the second linked library, from its compiled creation code
    function opsLibraryAddress() internal view returns (address) {
        return vm.computeCreate2Address(bytes32(0), keccak256(vm.getCode("CoreOpsLib.sol:CoreOpsLib")), CREATE2_DEPLOYER);
    }

    /// @dev the creation code of the Core with the library address linked in, without constructor arguments. the artifact
    /// is read from `out/`, where the library is a placeholder. the result is kept in the process environment, which a
    /// snapshot revert does not touch: the artifact json is large and a run calls `coreAddress` many times
    function _coreCreation() private returns (bytes memory) {
        string memory key = "POSTFLIGHT_CODE_CORE_CREATION";
        if (!vm.envExists(key)) {
            string memory o = vm.parseJsonString(vm.readFile("out/Core.sol/Core.json"), ".bytecode.object");
            string memory lib = vm.toString(libraryAddress());
            o = vm.replace(o, linkPlaceholder("src/lib/CoreLib.sol", "CoreLib"), vm.replace(lib, "0x", ""));
            string memory ops = vm.toString(opsLibraryAddress());
            o = vm.replace(o, linkPlaceholder("src/lib/CoreOpsLib.sol", "CoreOpsLib"), vm.replace(ops, "0x", ""));
            vm.setEnv(key, o);
        }
        return vm.envBytes(key);
    }

    /// @notice the creation code of the Core of `c` launched by `launcher`: the linked creation code and the
    /// constructor arguments
    function coreInitCode(LaunchConfig memory c, address launcher) internal returns (bytes memory) {
        return abi.encodePacked(_coreCreation(), coreConstructorArgs(c, launcher));
    }

    /// @notice the address of the Core of `c` launched by `launcher`: CREATE2 through the deterministic deployer with
    /// `CORE_SALT`. a function of the compiled Core and both libraries, the config and the deployer
    function coreAddress(LaunchConfig memory c, address launcher) internal returns (address) {
        return vm.computeCreate2Address(CORE_SALT, keccak256(coreInitCode(c, launcher)), CREATE2_DEPLOYER);
    }

    /// @notice the constructor arguments of the Core, as the creation transaction carries them and as etherscan wants
    /// them for verification: `(owner, cfg, launcher, coin, payee, stack, rateStart, settings, credit, artist)`. built
    /// from the signed launch config and the deployer only, never from live storage, which the owner can change after launch
    function coreConstructorArgs(LaunchConfig memory c, address launcher) internal view returns (bytes memory) {
        return abi.encode(
            c.owner,
            buildConfig(c, c.owner, address(0)),
            launcher,
            address(0),
            c.payee,
            c.stack,
            c.rateStart,
            c.settings,
            c.credit,
            c.artist
        );
    }

    /// @notice the address of the controller of `core_` and the sale and credit settings of `c`: CREATE2 through the
    /// deterministic deployer with `CONTROLLER_SALT`
    function controllerAddress(address core_, LaunchConfig memory c) internal view returns (address) {
        bytes memory init =
            abi.encodePacked(vm.getCode("ControllerV1.sol:ControllerV1"), abi.encode(core_, c.sale, c.credit, c.quote));
        return vm.computeCreate2Address(CONTROLLER_SALT, keccak256(init), CREATE2_DEPLOYER);
    }

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

    /// @dev both adapters have the compiled code, the Seaport adapter points at the Core and holds the config allowlist,
    /// and the Core approves both and no stack contract
    function _postAdapters(LaunchConfig memory c, ICore core) private {
        (address seaportAt, address strategyAt) =
            (seaportAdapterAddress(address(core), c.seaportRecipients), strategyAdapterAddress());
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
        _check(
            "adapters: both are allowed in the Core",
            core.allowedAdapter(seaportAt) && core.allowedAdapter(strategyAt),
            "seaport and CreditStrategy adapters"
        );
        _check(
            "adapters: no stack contract is allowed",
            !core.allowedAdapter(c.stack.hook) && !core.allowedAdapter(c.stack.factory)
                && !core.allowedAdapter(c.stack.locker) && !core.allowedAdapter(c.stack.escrow)
                && !core.allowedAdapter(c.stack.poolManager) && !core.allowedAdapter(core.COIN())
                && !core.allowedAdapter(address(core)),
            "hook, factory, locker, escrow, pool manager, coin, core"
        );
    }

    /// @notice prints what etherscan verification needs: the library address and the exact `--libraries` flag, then the
    /// constructor arguments of the Core, the controller and the Seaport adapter, built from the signed launch config
    /// and `deployer`, the address that sent the deploy. docs/RUNBOOK.md section 3
    function printVerifyInputs(ICore core, LaunchConfig memory c, address deployer) internal view {
        address lib = findLibrary(address(core).code);
        address ops = findOpsLibrary(address(core).code);
        console.log("verify: library CoreLib at", lib);
        console.log(string.concat("verify: flag  --libraries src/lib/CoreLib.sol:CoreLib:", vm.toString(lib)));
        console.log("verify: library CoreOpsLib at", ops);
        console.log(string.concat("verify: flag  --libraries src/lib/CoreOpsLib.sol:CoreOpsLib:", vm.toString(ops)));
        if (deployer == address(0)) {
            console.log("verify: constructor args NOT printed: set DEPLOYER (the deploy signer)");
            return;
        }
        console.log("verify: core constructor args");
        console.logBytes(coreConstructorArgs(c, deployer));
        console.log("verify: controller constructor args");
        console.logBytes(abi.encode(address(core), c.sale, c.credit, c.quote));
        console.log("verify: seaport adapter constructor args");
        console.logBytes(abi.encode(address(core), c.seaportRecipients));
    }

    function _postCore(LaunchConfig memory c, ICore core) private {
        _eq("core: owner", core.owner(), c.owner);
        uint256 openingRate = _approvedOpeningRate(c);
        _check(
            "core: opening rate equals the approved value",
            core.RATE_START() == openingRate,
            string.concat("live ", vm.toString(core.RATE_START()), " approved ", vm.toString(openingRate))
        );
        Stack memory st = c.stack;
        _check(
            "core: stack equals the config",
            address(core.MANAGER()) == st.poolManager && core.HOOK() == st.hook && core.TICK_SPACING() == st.tickSpacing
                && core.POOL_FEE() == st.poolFee && core.FACTORY() == st.factory && core.LOCKER() == st.locker
                && core.ESCROW() == st.escrow,
            "pool manager, hook, tick spacing, pool fee, factory, locker, escrow"
        );
        _postSettings(c, core);
        _postLibrary(core);
        address ctl = core.controller();
        _eq("core: controller is the deployed controller", ctl, controllerAddress(address(core), c));
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
            runtimeSlotsMatch(ctl, "ControllerV1", new address[](0), ctlWant),
            "the immutable CORE sites of the controller runtime code"
        );
        _check(
            "core: no locks, no balance module",
            !core.controllerLocked() && !core.balanceModuleLocked() && !core.adaptersLocked()
                && core.balanceModule() == address(0),
            "launch state"
        );
        _check(
            "core: no successor or retirement at launch",
            core.successor() == address(0) && !core.successorLocked() && !core.retired(),
            "successor, successor lock, retirement"
        );
        _warn("warn: no pending owner", core.pendingOwner() == address(0), "an owner handover is offered");
        _postSale(c, ctl);
        _check(
            "core: pots covered by balance",
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() <= address(core).balance,
            string.concat("balance ", vm.toString(address(core).balance))
        );
        // the stored price state moves once the pot is funded or a credit is bought, and the owner may reset it with
        // `setRate`, so it is exact only at launch: a difference is a warning. the read `ethRate()` is zero while the pot is
        // empty
        _warn(
            "warn: price state is the opening rate",
            core.ethPot() != 0 || core.rateAtCheckpoint() == openingRate,
            string.concat(
                "rateAtCheckpoint ", vm.toString(core.rateAtCheckpoint()), " openingRate ", vm.toString(openingRate)
            )
        );
    }

    /// @dev the sale settings of the controller must equal the config, like the core settings (SETTINGS_CHANGED=1 turns
    /// the row into a warning once the owner changed them)
    function _postSale(LaunchConfig memory c, address ctl) private {
        if (ctl.code.length == 0) return;
        IControllerV1 k = IControllerV1(ctl);
        bool same = k.markupBps() == c.sale.markupBps && k.startCapBps() == c.sale.startCapBps
            && k.decayHours() == c.sale.decayHours && k.anchorHalfLife() == c.sale.anchorHalfLife
            && k.anchorMinCost() == c.sale.anchorMinCost && k.anchorMoveBps() == c.sale.anchorMoveBps;
        if (_settingsChanged()) {
            _warn(
                "warn: sale settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch"
            );
        } else {
            _check(
                "controller: sale settings equal the config",
                same,
                "markupBps startCapBps decayHours anchorHalfLife anchorMinCost anchorMoveBps"
            );
        }
        // a fresh launch has no sales and no owner change, so the running level of sale prices is at its lower bound
        bool anchored = k.anchorBps() == 10_000;
        if (_settingsChanged()) {
            _warn(
                "warn: controller anchor is 10_000",
                anchored,
                "SETTINGS_CHANGED=1, sales or the owner moved it since launch"
            );
        } else {
            _check("controller: anchor is 10_000", anchored, vm.toString(k.anchorBps()));
        }
        bool creditSame = k.creditSaleOn() == c.credit.saleOn && k.creditWindow() == c.credit.window
            && k.creditSpreadBps() == c.credit.spreadBps && k.creditStartBps() == c.credit.startBps;
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
                "creditSaleOn creditWindow creditSpreadBps creditStartBps"
            );
        }
        // The controller constructor leaves age-only redemption eligibility off. An owner switch before launch would
        // change the signed launch policy even if the other sale settings still matched the config.
        if (_settingsChanged()) {
            _warn("warn: age eligibility is off at launch", !k.ageEligibilityOn(), "SETTINGS_CHANGED=1, owner switched it after launch");
        } else {
            _check("controller: age eligibility is off at launch", !k.ageEligibilityOn(), "ageEligibilityOn");
        }
        (uint32 rate, uint16 step, uint16 tol, uint32 stale, uint32 minSec, uint128 liq) = k.quote();
        bool quoteSame = rate == c.quote.referenceRateBpsPerHour && step == c.quote.referenceStepBps
            && tol == c.quote.tolBps && stale == c.quote.referenceMaxStale && minSec == c.quote.referenceMinSeconds
            && liq == c.quote.minLiquidity;
        if (_settingsChanged()) {
            _warn("warn: reference price settings equal the config", quoteSame, "SETTINGS_CHANGED=1, the owner changed it since launch");
        } else {
            _check(
                "controller: reference price settings equal the config",
                quoteSame,
                "referenceRateBpsPerHour referenceStepBps tolBps referenceMaxStale referenceMinSeconds minLiquidity"
            );
        }
    }

    /// @notice the operator says the owner changed the settings since launch (SETTINGS_CHANGED=1). a test overrides it
    function _settingsChanged() internal view virtual returns (bool) {
        return vm.envOr("SETTINGS_CHANGED", uint256(0)) == 1;
    }

    /// A reset keeps the original constructor config and Core address. Its separate hash approves exactly one
    /// opening rate and the associated 3x cap for the deferred launch.
    function _openingRateHash(LaunchConfig memory c, uint256 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("credits.prelaunchRate.v1"), configHash(c), rate, rate * 3));
    }

    function _approvedOpeningRate(LaunchConfig memory c) internal view virtual returns (uint256 rate) {
        uint256 changed = vm.envOr("PRELAUNCH_RATE", uint256(0));
        bytes32 given = vm.envOr("PRELAUNCH_RATE_HASH", bytes32(0));
        if (changed == 0) {
            if (given != bytes32(0)) revert PrelaunchRateSignoff(bytes32(0), given);
            return c.rateStart;
        }
        if (!SettingsBounds.rateInBounds(changed) || changed > type(uint64).max / 3) {
            revert PrelaunchRateOutOfBounds(changed);
        }
        bytes32 want = _openingRateHash(c, changed);
        if (given != want) revert PrelaunchRateSignoff(want, given);
        return changed;
    }

    /// @dev the settings are owner adjustable after launch. right after the deploy they must equal the config field by
    /// field, so a Core built with other values fails. once the owner has called `setSettings` the live values differ
    /// on purpose: run with SETTINGS_CHANGED=1 and the row turns into a warning that prints the difference
    function _postSettings(LaunchConfig memory c, ICore core) private {
        Settings memory live = core.settings();
        bytes32 bad = SettingsBounds.firstViolation(live);
        _check("core: settings inside the bounds", bad == 0, bad == 0 ? "all fields" : string(abi.encodePacked(bad)));
        Settings memory expected = abi.decode(abi.encode(c.settings), (Settings));
        uint256 openingRate = _approvedOpeningRate(c);
        if (openingRate != c.rateStart) expected.rateCap = uint64(openingRate * 3);
        bool same = keccak256(abi.encode(live)) == keccak256(abi.encode(expected));
        if (_settingsChanged()) {
            _warn("warn: settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch");
        } else {
            _check(
                "core: settings equal the approved launch values",
                same,
                "only rateCap may differ from the constructor config after an approved opening-rate reset"
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
                "core: credit settings equal the config", creditSame, "creditCostToPotBps chosenComposeOn minCcToChoose"
            );
        }
        _soft(
            _settingsChanged(),
            "core: settings.sniperSeconds equals the launch mev window",
            live.sniperSeconds == c.sniperSeconds,
            string.concat("settings ", vm.toString(live.sniperSeconds), " launch ", vm.toString(c.sniperSeconds)),
            "SETTINGS_CHANGED=1"
        );
        // sales are open until the owner pauses them
        if (_settingsChanged()) {
            _warn("warn: core is not paused", !core.paused(), "SETTINGS_CHANGED=1, the owner paused sales since launch");
        } else {
            _check("core: not paused", !core.paused(), core.paused() ? "paused" : "not paused");
        }
        _check("core: ethRate at most rateCap", core.ethRate() <= live.rateCap, vm.toString(core.ethRate()));
    }

    /// @dev the Core links both libraries. the runtime hash masks their call sites; these rows check the code at each
    /// linked address and the value of every masked library and immutable slot
    function _postLibrary(ICore core) private {
        bytes memory code = address(core).code;
        address found = findLibrary(code);
        address ops = findOpsLibrary(code);
        _check(
            "core: linked library is the compiled CoreLib",
            found == libraryAddress(),
            string.concat("library at ", vm.toString(found))
        );
        _check(
            "core: linked ops library is the compiled CoreOpsLib",
            ops == opsLibraryAddress(),
            string.concat("ops library at ", vm.toString(ops))
        );
        uint256[] memory want = new uint256[](8);
        want[0] = uint256(uint160(core.COIN()));
        want[1] = uint256(uint160(address(core.MANAGER())));
        want[2] = uint256(uint160(core.HOOK()));
        want[3] = uint256(int256(core.TICK_SPACING()));
        want[4] = uint256(core.POOL_FEE());
        want[5] = uint256(uint160(core.FACTORY()));
        want[6] = uint256(uint160(core.LOCKER()));
        want[7] = uint256(uint160(core.ESCROW()));
        address[] memory libs = new address[](2);
        libs[0] = found;
        libs[1] = ops;
        _check(
            "core: every library call site and every immutable slot holds the library or the getter value",
            found != address(0) && ops != address(0) && runtimeSlotsMatch(address(core), "Core", libs, want),
            "all compiled library and immutable reference sites"
        );
    }

    /// @notice the address of the compiled `CoreLib` inside a Core runtime code (a push20 whose target has the library
    /// runtime code, own address masked out), zero when there is none
    function findLibrary(bytes memory code) internal view returns (address found) {
        return _findLibrary(code, "CoreLib.sol:CoreLib");
    }

    function findOpsLibrary(bytes memory code) internal view returns (address found) {
        return _findLibrary(code, "CoreOpsLib.sol:CoreOpsLib");
    }

    function _findLibrary(bytes memory code, string memory artifact) private view returns (address found) {
        bytes memory expected = vm.getDeployedCode(artifact);
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
            if (cand.code.length == expected.length && expected.length >= 39 && _tailHash(cand.code) == want) {
                return cand;
            }
        }
    }

    /// @notice whether `lc` is the runtime code of the compiled `CoreLib`, its own address masked out
    function isCompiledLibrary(bytes memory lc) internal view returns (bool) {
        return _isCompiledLibrary(lc, "CoreLib.sol:CoreLib");
    }

    function isCompiledOpsLibrary(bytes memory lc) internal view returns (bool) {
        return _isCompiledLibrary(lc, "CoreOpsLib.sol:CoreOpsLib");
    }

    function _isCompiledLibrary(bytes memory lc, string memory artifact) private view returns (bool) {
        bytes memory expected = vm.getDeployedCode(artifact);
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
        _warn(
            "warn: payee share is not on yet", !core.payeeOn(), "payeeOn: the first book after the window turned it on"
        );
        // the artist cut recipient must be set when the cut is on, and must equal the config
        _check(
            "core: artist set while the artist cut is on",
            core.artist() != address(0) || core.settings().saleToArtistBps == 0,
            "saleToArtistBps is nonzero but the artist is the zero address"
        );
        _soft(
            _settingsChanged(),
            "core: artist equals the config",
            core.artist() == c.artist,
            vm.toString(core.artist()),
            "SETTINGS_CHANGED=1"
        );
    }
}
