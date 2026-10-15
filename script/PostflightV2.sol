// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemBuilder} from "./Builder.sol";
import {Report} from "./Report.sol";

/// @notice the safe readers and the coin side of the postflight (docs/DECISIONS.md 10.4): every read is a staticcall that
/// reports a failure instead of reverting, so a wrong address turns into a failed row and never aborts the table
abstract contract PostflightV2 is SystemBuilder, Report {
    // ------------------------------------------------------------------ runtime code identity

    /// @dev json objects decode in key order: length, then start
    struct IdRef {
        uint256 length;
        uint256 start;
    }

    /// @dev the {start, length} pairs (packed start << 128 | length) of an artifact's slots. an immutable slot carries
    /// its group (the index of the immutable in ascending AST id order, which is declaration order) in the bits from 192.
    /// the artifact json is large (a postflight runs hundreds of times in the mutation matrix, and a snapshot revert
    /// would drop contract storage), so the slots, the length and the masked hash of the compiled runtime code are read
    /// once and kept in the process environment, which a snapshot revert does not touch
    function _idCollect(string memory j, string memory path, uint256[] memory acc, uint256 group)
        private
        view
        returns (uint256[] memory)
    {
        IdRef[] memory refs = abi.decode(vm.parseJson(j, path), (IdRef[]));
        uint256[] memory out = new uint256[](acc.length + refs.length);
        for (uint256 i; i < acc.length; ++i) {
            out[i] = acc[i];
        }
        for (uint256 i; i < refs.length; ++i) {
            out[acc.length + i] = (group << 192) | (refs[i].start << 128) | refs[i].length;
        }
        return out;
    }

    function _idKey(string memory name, string memory what) private pure returns (string memory) {
        return string.concat("POSTFLIGHT_CODE_", what, "_", name);
    }

    /// @dev sorts `ids` (decimal AST id strings) ascending by numeric value, in place. insertion sort: the immutable
    /// count is small
    function _sortAstKeys(string[] memory ids) private pure {
        for (uint256 i = 1; i < ids.length; ++i) {
            string memory key = ids[i];
            uint256 kv = _toUint(key);
            uint256 j = i;
            while (j != 0 && _toUint(ids[j - 1]) > kv) {
                ids[j] = ids[j - 1];
                --j;
            }
            ids[j] = key;
        }
    }

    function _toUint(string memory s) private pure returns (uint256 v) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            v = v * 10 + (uint8(b[i]) - 48);
        }
    }

    /// @dev reads the artifact once: the immutable slots, the library address slots and the hash of the masked compiled
    /// runtime code
    function _idLoad(string memory name) private {
        string memory j = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        uint256[] memory imm = new uint256[](0);
        // an artifact without immutables has no such key
        string[] memory ids = vm.keyExistsJson(j, ".deployedBytecode.immutableReferences")
            ? vm.parseJsonKeys(j, ".deployedBytecode.immutableReferences")
            : new string[](0);
        // parseJsonKeys returns the keys in the json's lexicographic order, which equals ascending AST id only while
        // every id has the same digit width; a 5 digit id sorts before a 4 digit one. the group index must be the
        // ascending AST id order (declaration order), so the keys are sorted numerically first
        _sortAstKeys(ids);
        for (uint256 i; i < ids.length; ++i) {
            imm = _idCollect(j, string.concat(".deployedBytecode.immutableReferences.", ids[i]), imm, i);
        }
        uint256[] memory lnk = new uint256[](0);
        string[] memory files = vm.parseJsonKeys(j, ".deployedBytecode.linkReferences");
        for (uint256 i; i < files.length; ++i) {
            string memory fp = string.concat(".deployedBytecode.linkReferences['", files[i], "']");
            string[] memory libs = vm.parseJsonKeys(j, fp);
            for (uint256 k; k < libs.length; ++k) {
                lnk = _idCollect(j, string.concat(fp, ".", libs[k]), lnk, 0);
            }
        }
        bytes memory built = _idBuilt(j);
        _idZero(built, imm);
        _idZero(built, lnk);
        vm.setEnv(_idKey(name, "LEN"), vm.toString(built.length));
        vm.setEnv(_idKey(name, "HASH"), vm.toString(keccak256(built)));
        vm.setEnv(_idKey(name, "SLOTS"), vm.toString(abi.encode(imm, lnk)));
    }

    /// @dev the runtime code of the artifact in `j` with every library placeholder replaced by zeros. `getDeployedCode`
    /// refuses an artifact with unlinked libraries in a script that does not import the library's user (`Preflight`,
    /// `Postflight`), and the link slots are masked anyway. the placeholder of a library is `__$` and the first 34 hex
    /// characters of keccak256("<source file>:<library>") and `$__`
    function _idBuilt(string memory j) private view returns (bytes memory) {
        string memory o = vm.parseJsonString(j, ".deployedBytecode.object");
        string[] memory files = vm.parseJsonKeys(j, ".deployedBytecode.linkReferences");
        for (uint256 i; i < files.length; ++i) {
            string[] memory libs =
                vm.parseJsonKeys(j, string.concat(".deployedBytecode.linkReferences['", files[i], "']"));
            for (uint256 k; k < libs.length; ++k) {
                o = vm.replace(o, linkPlaceholder(files[i], libs[k]), "0000000000000000000000000000000000000000");
            }
        }
        return vm.parseBytes(o);
    }

    /// @notice the link placeholder of a library in an artifact: `__$`, the first 34 hex characters of
    /// keccak256("<source file>:<library>") and `$__`
    function linkPlaceholder(string memory file, string memory lib) internal pure returns (string memory) {
        bytes memory h = bytes(vm.toString(keccak256(bytes(string.concat(file, ":", lib)))));
        bytes memory ph = new bytes(40);
        ph[0] = "_";
        ph[1] = "_";
        ph[2] = "$";
        for (uint256 b; b < 34; ++b) {
            ph[3 + b] = h[2 + b];
        }
        ph[37] = "$";
        ph[38] = "_";
        ph[39] = "_";
        return string(ph);
    }

    function _idZero(bytes memory code, uint256[] memory m) private pure {
        for (uint256 i; i < m.length; ++i) {
            uint256 start = uint64(m[i] >> 128);
            uint256 len = uint128(m[i]);
            require(start + len <= code.length, "mask outside the code");
            // calldata past its end reads as zeros: one copy zeroes the whole range
            assembly {
                calldatacopy(add(add(code, 0x20), start), calldatasize(), len)
            }
        }
    }

    function _idEnsure(string memory name) private {
        if (!vm.envExists(_idKey(name, "HASH"))) _idLoad(name);
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
        _soft(ch, "coin: no metadata renderer", t.metadataRenderer() == address(0), vm.toString(t.metadataRenderer()), "COIN_CHANGED=1");
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
