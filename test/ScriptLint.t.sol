// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice `forge script` reverts the whole run when a script contract uses `address(this)`; a test contract using the
/// same checks does not. this scans the scripts, and `script/tools/check-preflight.sh` runs the real script on a fork
contract ScriptLintTest is Test {
    // promise: scripts do not use address this
    function test_scriptsDoNotUseAddressThis() public view {
        VmSafe.DirEntry[] memory files = vm.readDir("script");
        uint256 scanned;
        for (uint256 i; i < files.length; ++i) {
            if (!vm.contains(files[i].path, ".sol")) continue;
            ++scanned;
            assertFalse(vm.contains(vm.readFile(files[i].path), "address(this)"), files[i].path);
        }
        assertGt(scanned, 10, "script files found");
    }
}
