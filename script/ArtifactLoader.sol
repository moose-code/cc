// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";

/// @notice the key naming, the slot masking and the link placeholder of the runtime code identity check
abstract contract ArtifactIdentity is CommonBase {
    function _idKey(string memory name, string memory what) internal pure returns (string memory) {
        return string.concat("POSTFLIGHT_CODE_", what, "_", name);
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

    function _idZero(bytes memory code, uint256[] memory m) internal pure {
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
}

/// @notice reads the artifact `name` from `out/` and keeps its masked runtime hash, length and slots in the process
/// environment. `PostflightV2` creates one and calls `load` once per artifact: the json and the copies each cheatcode
/// call makes of it are freed when the frame returns, so a run that loads six artifacts stays under a block's gas. a
/// contract created by a script has cheatcode access; `forge script` refuses a self call from the script contract itself
contract ArtifactLoader is ArtifactIdentity {
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
        internal
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

    /// @dev sorts `ids` (decimal AST id strings) ascending by numeric value, in place. insertion sort: the immutable
    /// count is small
    function _sortAstKeys(string[] memory ids) internal pure {
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

    function _toUint(string memory s) internal pure returns (uint256 v) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            v = v * 10 + (uint8(b[i]) - 48);
        }
    }

    /// @dev reads the artifact once: the immutable slots, the library address slots and the hash of the masked compiled
    /// runtime code
    function load(string calldata name) external {
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
    function _idBuilt(string memory j) internal view returns (bytes memory) {
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
}
