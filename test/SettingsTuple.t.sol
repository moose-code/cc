// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettingsFields} from "../script/SettingsFields.sol";

/// @notice the tuple string the settings script prints and check-post.sh reads with `cast` is the Settings struct of
/// the ICore abi, field by field, so it cannot drift from the struct again (audit S-04: 37 types for 39 fields)
contract SettingsTupleTest is Test {
    string internal constant ABI_PATH = "out/ICore.sol/ICore.json";

    /// the json path of the `setSettings` input struct's components in the ICore abi: the abi is scanned for the entry
    /// of that name (foundry's json paths read one value, so a filter expression is not used)
    function _components(string memory json) internal view returns (string memory path) {
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat("$.abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, string.concat(entry, ".name"))) continue;
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".name")))) != keccak256("setSettings")) {
                continue;
            }
            return string.concat(entry, ".inputs[0].components");
        }
        revert("setSettings not in the abi");
    }

    function _count(string memory json, string memory path) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n), "]"))) ++n;
    }

    // promise: the tuple string equals the setSettings input of the ICore abi, type by type and in order
    function test_tupleIsTheAbiStruct() public view {
        string memory json = vm.readFile(ABI_PATH);
        string memory path = _components(json);
        uint256 n = _count(json, path);
        assertEq(n, SettingsFields.N, "the abi struct has N fields");
        string memory tuple = "(";
        for (uint256 i; i < n; ++i) {
            string memory t = vm.parseJsonString(json, string.concat(path, "[", vm.toString(i), "].type"));
            tuple = string.concat(tuple, i == 0 ? "" : ",", t);
        }
        tuple = string.concat(tuple, ")");
        assertEq(SettingsFields.TUPLE, tuple, "TUPLE is the abi tuple");
    }

    // promise: the names of the library are the abi field names in order, and isBool marks exactly the bool fields,
    // so the printed tuple literal has a true or false at every bool
    function test_namesAndBoolsFollowTheAbi() public view {
        string memory json = vm.readFile(ABI_PATH);
        string memory path = _components(json);
        uint256 n = _count(json, path);
        bytes32[39] memory ours = SettingsFields.names();
        assertEq(n, ours.length, "the abi struct has 39 fields");
        for (uint256 i; i < n; ++i) {
            string memory entry = string.concat(path, "[", vm.toString(i), "]");
            string memory name = vm.parseJsonString(json, string.concat(entry, ".name"));
            string memory t = vm.parseJsonString(json, string.concat(entry, ".type"));
            assertEq(ours[i], bytes32(bytes(name)), string.concat("field name ", vm.toString(i)));
            bool isBool = keccak256(bytes(t)) == keccak256("bool");
            assertEq(SettingsFields.isBool(i), isBool, string.concat("isBool ", vm.toString(i)));
        }
    }
}
