// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ICoinRenderer} from "../src/interfaces/ICoinRenderer.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemBuilder} from "./Builder.sol";
import {Report} from "./Report.sol";
import {ArtifactIdentity, ArtifactLoader} from "./ArtifactLoader.sol";


/// @notice the safe readers and the coin side of the postflight (docs/DECISIONS.md 10.4): every read is a staticcall that
/// reports a failure instead of reverting, so a wrong address turns into a failed row and never aborts the table
abstract contract PostflightV2 is SystemBuilder, Report, ArtifactIdentity {
    /// @dev the gas bound of the coin's `tokenURI()` read in the postflight. the page of 80 cells costs about 25,000,000
    uint256 internal constant URI_READ_GAS = 60_000_000;

    // ------------------------------------------------------------------ runtime code identity

    /// @dev the loader is created on first use and is not part of any broadcast. its external call returns before the
    /// next artifact is read, which frees the json and the copies each cheatcode call makes of it
    ArtifactLoader private _loader;

    function _idEnsure(string memory name) private {
        if (vm.envExists(_idKey(name, "HASH"))) return;
        if (address(_loader) == address(0)) _loader = new ArtifactLoader();
        _loader.load(name);
    }

    function _idSlots(string memory name) private returns (uint256[] memory imm, uint256[] memory lnk) {
        _idEnsure(name);
        (imm, lnk) = abi.decode(vm.envBytes(_idKey(name, "SLOTS")), (uint256[], uint256[]));
    }

    /// @notice the keccak256 of the runtime code of the compiled artifact `name` (`Core`, `CoreLib`, `ControllerV1`,
    /// `SeaportBasicAdapter`, `CreditStrategyAdapter`) with the immutable slots and the library address slots zeroed, as read from `out/`
    function artifactHash(string memory name) internal returns (bytes32) {
        _idEnsure(name);
        return vm.envBytes32(_idKey(name, "HASH"));
    }

    /// @notice whether the runtime code at `at` is the runtime code of the compiled artifact `name` (`Core`,
    /// `ControllerV1`), the immutable slots and the linked library address masked in both (the method of
    /// test/BuildIdentity.t.sol). false when `at` has no code. the artifact side is read once and kept, and the copy
    /// of the live code is released, so a run of hundreds of postflights stays cheap
    function runtimeMatchesArtifact(address at, string memory name) internal returns (bool ok) {
        if (at.code.length == 0) return false;
        (uint256[] memory imm, uint256[] memory lnk) = _idSlots(name);
        bytes32 want = vm.envBytes32(_idKey(name, "HASH"));
        uint256 len = vm.envUint(_idKey(name, "LEN"));
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        bytes memory live = at.code;
        if (live.length == len) {
            _idZero(live, imm);
            _idZero(live, lnk);
            ok = keccak256(live) == want;
        }
        assembly {
            mstore(0x40, fmp)
        }
    }

    /// @notice whether every masked slot of the runtime code at `at` holds the value the live contract reports: each
    /// library address slot equals `lib`, and every site of the immutable with index g (declaration order) holds
    /// `want[g]`. the runtime hash comparison masks these slots, so this is the check of their content. false when `at`
    /// has no code or `want` does not have one entry per immutable
    function runtimeSlotsMatch(address at, string memory name, address lib, uint256[] memory want)
        internal
        returns (bool ok)
    {
        if (at.code.length == 0) return false;
        (uint256[] memory imm, uint256[] memory lnk) = _idSlots(name);
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        bytes memory live = at.code;
        ok = true;
        for (uint256 i; i < lnk.length && ok; ++i) {
            ok = _slotWord(live, lnk[i]) == uint256(uint160(lib));
        }
        for (uint256 i; i < imm.length && ok; ++i) {
            uint256 g = imm[i] >> 192;
            ok = g < want.length && _slotWord(live, imm[i]) == want[g];
        }
        assembly {
            mstore(0x40, fmp)
        }
    }

    /// @dev the big endian value of a slot, at most 32 bytes. a slot outside the code reads as a mismatch
    function _slotWord(bytes memory code, uint256 m) private pure returns (uint256 w) {
        uint256 start = uint64(m >> 128);
        uint256 len = uint128(m);
        if (len > 32 || start + len > code.length) return type(uint256).max;
        for (uint256 i; i < len; ++i) {
            w = (w << 8) | uint8(code[start + i]);
        }
    }

    /// @dev a staticcall that never reverts. ok is false when the call failed or returned less than a word
    function _word(address target, bytes memory data) internal view returns (bool ok, uint256 w) {
        bytes memory out;
        (ok, out) = target.staticcall(data);
        if (ok && out.length >= 32) w = abi.decode(out, (uint256));
        else ok = false;
    }

    function _addr(address target, bytes memory data) internal view returns (bool ok, address a) {
        uint256 w;
        (ok, w) = _word(target, data);
        if (w > type(uint160).max) ok = false;
        a = address(uint160(w));
    }

    function _bool(address target, bytes memory data) internal view returns (bool ok, bool b) {
        uint256 w;
        (ok, w) = _word(target, data);
        if (w > 1) ok = false;
        b = w == 1;
    }

    function _hookGlobals(address hook) internal view returns (IArtCoinsHookV2.HookGlobals memory g) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.globals, ()));
        if (ok && out.length == 64) g = abi.decode(out, (IArtCoinsHookV2.HookGlobals));
    }

    function _hookInfo(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.PoolInfo memory p) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.poolInfo, (poolId)));
        if (ok && out.length == 256) p = abi.decode(out, (IArtCoinsHookV2.PoolInfo));
    }

    function _hookSkim(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.SkimConfig memory k) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.skimConfig, (poolId)));
        if (ok && out.length == 160) k = abi.decode(out, (IArtCoinsHookV2.SkimConfig));
    }

    function _deployment(address factory, address coin)
        internal
        view
        returns (bool ok, IArtCoinsFactoryV2.DeploymentInfoV2 memory info)
    {
        bytes memory out;
        (ok, out) = factory.staticcall(abi.encodeCall(IArtCoinsFactoryV2.deploymentInfo, (coin)));
        if (ok && out.length >= 416) info = abi.decode(out, (IArtCoinsFactoryV2.DeploymentInfoV2));
        else ok = false;
    }

    /// @notice the factory's `predictToken` through a staticcall that reports a failure instead of reverting
    function _predict(LaunchConfig memory c, address sender, address core)
        internal
        view
        returns (bool ok, address coin)
    {
        bytes memory data =
            abi.encodeCall(IArtCoinsFactoryV2.predictToken, (sender, buildConfig(c, c.owner, core)));
        uint256 w;
        (ok, w) = _word(c.stack.factory, data);
        coin = address(uint160(w));
    }

    /// @notice the operator says the owner changed the coin since launch: unrestrict, lock, a new admin or a changed
    /// allowlist (COIN_CHANGED=1). a test overrides it
    function _coinChanged() internal view virtual returns (bool) {
        return vm.envOr("COIN_CHANGED", uint256(0)) == 1;
    }

    /// @dev a row that is a failure until the operator names the change, then a warning
    function _soft(bool changed, string memory name, bool ok, string memory detail, string memory flag) internal {
        if (changed) _warn(string.concat("warn: ", name), ok, string.concat(flag, " set: ", detail));
        else _check(name, ok, detail);
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ------------------------------------------------------------------ the coin

    function _postCoin(LaunchConfig memory c, address core, address coin_, bytes32 poolId) internal {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin_);
        _check(
            "coin: supply at most the config supply",
            t.totalSupply() <= c.supply,
            string.concat("supply ", vm.toString(t.totalSupply()))
        );
        _warn(
            "warn: coin supply is the config supply (less the locker dust)",
            t.totalSupply() + 1e6 >= c.supply,
            "coin was burned since launch"
        );
        _check(
            "coin: launcher, canonical hook, canonical pool id and pool manager equal the config",
            t.launcher() == c.stack.factory && t.canonicalHook() == c.stack.hook && t.canonicalPoolId() == poolId
                && t.poolManager() == c.stack.poolManager,
            "launcher is the factory"
        );
        bool ch = _coinChanged();
        _soft(ch, "coin: admin is the config owner", t.admin() == c.owner, vm.toString(t.admin()), "COIN_CHANGED=1");
        _soft(ch, "coin: restricted as in the config", t.restricted() == c.restricted, "restricted()", "COIN_CHANGED=1");
        _soft(ch, "coin: image equals the config", _same(t.imageUrl(), c.image), t.imageUrl(), "COIN_CHANGED=1");
        _soft(ch, "coin: description equals the config", _same(t.description(), c.description), t.description(), "COIN_CHANGED=1");
        _postRenderer(c, core, t, ch);
        _postAllowlist(c, core, t, ch);
        _postLock(t);
        _warn("warn: core holds no coin", t.balanceOf(core) == 0, "coin sent by an allowlisted holder, the owner can call rescueCoin");
    }

    /// @dev `coin.lock()` freezes the allowlist, `unrestrict` and the hook's coin admin settings (bounty recipient,
    /// pool extension, baseline skim including `lowerBaselineSkim`). it is a later owner decision (script/Lock.s.sol),
    /// so the row reports the state and the deploy leaves the coin unlocked
    function _postLock(IArtCoinsTokenV2 t) private {
        _info("coin: lock", t.locked() ? "locked" : "unlocked, script/Lock.s.sol locks it as an owner decision");
    }

    /// @dev the coin's metadata renderer is the `CoinRenderer` of the config, at its CREATE2 address, bound to the
    /// Core, and the coin's `tokenURI()` returns a json data uri. the admin may replace the renderer (`COIN_CHANGED=1`)
    function _postRenderer(LaunchConfig memory c, address core, IArtCoinsTokenV2 t, bool ch) private {
        address at = rendererAddress(c);
        if (at.code.length != 0) {
            _check(
                "renderer: runtime code is the compiled LogoCoinRenderer",
                runtimeMatchesArtifact(at, "LogoCoinRenderer"),
                vm.toString(at)
            );
            (bool ok, address bound) = _addr(at, abi.encodeCall(ICoinRenderer.core, ()));
            _check("renderer: core is the Core", ok && bound == core, vm.toString(bound));
        }
        _soft(ch, "coin: metadata renderer is the CoinRenderer of the config", t.metadataRenderer() == at, vm.toString(t.metadataRenderer()), "COIN_CHANGED=1");
        (bool okUri, string memory uri) = _tokenUri(address(t));
        _soft(
            ch,
            "coin: tokenURI returns a json data uri",
            okUri && _hasPrefix(uri, "data:application/json;base64,"),
            string.concat(vm.toString(bytes(uri).length), " bytes"),
            "COIN_CHANGED=1"
        );
    }

    /// @dev the coin's `tokenURI()` through a staticcall bounded by `URI_READ_GAS`. `ok` is false when the call fails, runs
    /// out of gas or returns less than an encoded string. the coin encodes the return value
    function _tokenUri(address coin) internal view returns (bool ok, string memory uri) {
        bytes memory out;
        (ok, out) = coin.staticcall{gas: URI_READ_GAS}(abi.encodeCall(IArtCoinsTokenV2.tokenURI, ()));
        if (ok && out.length >= 64) uri = abi.decode(out, (string));
        else ok = false;
    }

    function _hasPrefix(string memory s, string memory p) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @dev the allowlist cannot be listed on chain. what is checked: the locker is on it (the factory seeds the
    /// launch's locker and extensions), every extra entry of the config is, and no account of the system is: the Core
    /// is off it, the buyback take passes the restriction through the transfer allowance the hook grants
    function _postAllowlist(LaunchConfig memory c, address core, IArtCoinsTokenV2 t, bool ch) private {
        bool listed = t.isAllowed(c.stack.locker);
        for (uint256 i; i < c.allowed.length; ++i) {
            listed = listed && t.isAllowed(c.allowed[i]);
        }
        _soft(ch, "coin: allowlist holds the locker and the config entries", listed, "isAllowed", "COIN_CHANGED=1");
        address[9] memory off = [
            core,
            c.owner,
            c.creator,
            c.payee,
            c.stack.hook,
            c.stack.poolManager,
            c.stack.factory,
            c.mevModule,
            ICoreController(core).controller()
        ];
        bool none = true;
        for (uint256 i; i < off.length; ++i) {
            none = none && !t.isAllowed(off[i]);
        }
        _soft(ch, "coin: allowlist holds none of core, owner, creator, payee, hook, factory, mev module, controller", none, "isAllowed", "COIN_CHANGED=1");
    }
}

interface ICoreController {
    function controller() external view returns (address);
}
