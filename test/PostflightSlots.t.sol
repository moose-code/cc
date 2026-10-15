// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";

/// @notice the content of the masked slots of the runtime code, and the guards of `Deploy` and `Resume`.
///  1. the identity hash of the Core and the controller masks the library address slots and the immutable slots. the
///     slot row requires every one of them to hold the library or the getter value. one foreign call site of `CoreLib`,
///     or one divergent site of an immutable, fails it while the identity row still passes (finding 2 of
///     docs/reviews/REVIEW-security.md),
///  2. `_requireNoChangeFlags` reverts for each owner change flag and both scripts call it.
contract PostflightSlotsTest is Fixture {
    string internal constant SLOTS_ROW =
        "core: every library call site and every immutable slot holds the library or the getter value";
    string internal constant IDENTITY_ROW =
        "core: runtime code is the compiled Core (immutables and the library address masked)";
    string internal constant CONTROLLER_IDENTITY_ROW =
        "controller: runtime code is the compiled ControllerV1 (immutables masked)";
    string internal constant CONTROLLER_ROW = "controller: every CORE slot of the runtime code is the Core";

    bool internal fSettings;
    bool internal fCoin;

    function _settingsChanged() internal view override returns (bool) {
        return fSettings;
    }

    function _coinChanged() internal view override returns (bool) {
        return fCoin;
    }

    function _row(string memory name) internal view returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return rows[i].ok;
        }
        revert("row missing");
    }

    function _failedList() internal returns (string memory list) {
        postflightAs(lc, address(core), owner);
        (list,) = _failed();
    }

    /// @dev the start offsets of the sites of immutable number `group` (ascending AST id, declaration order) of `name`
    function _immutableSites(string memory name, uint256 group) internal view returns (uint256[] memory starts) {
        string memory j = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        string[] memory ids = vm.parseJsonKeys(j, ".deployedBytecode.immutableReferences");
        string memory path = string.concat(".deployedBytecode.immutableReferences.", ids[group]);
        uint256 n;
        while (vm.keyExistsJson(j, string.concat(path, "[", vm.toString(n), "]"))) ++n;
        starts = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            starts[k] = vm.parseJsonUint(j, string.concat(path, "[", vm.toString(k), "].start"));
        }
    }

    /// @dev the offsets of the operands of the push20 sites of `lib` in `c`
    function _librarySites(bytes memory c, address lib) internal pure returns (uint256[] memory out) {
        uint256[] memory tmp = new uint256[](c.length / 21);
        uint256 n;
        for (uint256 i; i + 21 <= c.length; ++i) {
            if (c[i] != 0x73) continue;
            address cand;
            assembly {
                cand := shr(96, mload(add(add(c, 0x21), i)))
            }
            if (cand == lib) tmp[n++] = i + 1;
        }
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    function _foreignLibrary() internal returns (address evil) {
        address lib = findLibrary(address(core).code);
        evil = makeAddr("foreign library");
        bytes memory lc2 = lib.code;
        lc2[lc2.length - 1] = bytes1(uint8(lc2[lc2.length - 1]) ^ 1);
        vm.etch(evil, lc2);
    }

    function _point(bytes memory c, uint256 operand, address to) internal pure {
        bytes20 e = bytes20(to);
        for (uint256 k; k < 20; ++k) {
            c[operand + k] = e[k];
        }
    }

    /// @dev the reviewer's probe: one of the six `CoreLib` call sites of the Core points at a copy with one flipped
    /// byte. the identity hash masks the slot and `findLibrary` finds the compiled library through the other sites, so
    /// only the slot row sees it. a library runs by DELEGATECALL in the Core storage
    function test_oneForeignLibrarySiteFailsPostflight() public {
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0));
        uint256[] memory sites = _librarySites(address(core).code, lib);
        assertEq(sites.length, 8, "the Core calls CoreLib at eight sites");
        address evil = _foreignLibrary();
        for (uint256 s; s < sites.length; ++s) {
            bytes memory c = address(core).code;
            _point(c, sites[s], evil);
            vm.etch(address(core), c);
            assertEq(_failedList(), SLOTS_ROW, "one foreign site");
            assertTrue(_row(IDENTITY_ROW), "the identity hash still passes: it masks the slot");
            _point(c, sites[s], lib);
            vm.etch(address(core), c);
            assertEq(_failedList(), "", "restored");
        }
    }

    /// @dev one site of an immutable holds another value than the other sites and the getter. every one of the 10
    /// immutables of the Core and its last site
    function test_oneDivergentImmutableSiteFailsPostflight() public {
        for (uint256 g; g < 10; ++g) {
            uint256[] memory sites = _immutableSites("Core", g);
            assertGt(sites.length, 0, "an immutable is read at least once");
            // an immutable read only by its public getter has no second site to diverge from the getter
            if (sites.length == 1) continue;
            bytes memory c = address(core).code;
            c[sites[sites.length - 1] + 31] = bytes1(uint8(c[sites[sites.length - 1] + 31]) ^ 1);
            vm.etch(address(core), c);
            postflightAs(lc, address(core), owner);
            assertFalse(_row(SLOTS_ROW), "the slot row fails");
            assertTrue(_row(IDENTITY_ROW), "the identity hash still passes: it masks the slot");
            c[sites[sites.length - 1] + 31] = bytes1(uint8(c[sites[sites.length - 1] + 31]) ^ 1);
            vm.etch(address(core), c);
        }
        assertEq(_failedList(), "", "restored");
    }

    function test_oneDivergentControllerSiteFailsPostflight() public {
        uint256[] memory sites = _immutableSites("ControllerV1", 0);
        assertEq(sites.length, 18);
        for (uint256 s; s < sites.length; ++s) {
            bytes memory k = address(ctl).code;
            k[sites[s] + 31] = bytes1(uint8(k[sites[s] + 31]) ^ 1);
            vm.etch(address(ctl), k);
            postflightAs(lc, address(core), owner);
            assertFalse(_row(CONTROLLER_ROW), "one divergent CORE site");
            assertTrue(_row(CONTROLLER_IDENTITY_ROW), "the identity hash still passes: it masks the slot");
            k[sites[s] + 31] = bytes1(uint8(k[sites[s] + 31]) ^ 1);
            vm.etch(address(ctl), k);
        }
        assertEq(_failedList(), "", "restored");
    }

    // ------------------------------------------------------------------ Deploy and Resume

    function requireNoFlags() external view {
        _requireNoChangeFlags();
    }

    // Deploy and Resume send transactions that assume the launch state: they refuse a named owner change
    function test_deployAndResumeRefuseEveryChangeFlag() public {
        this.requireNoFlags();
        string[2] memory names = ["SETTINGS_CHANGED", "COIN_CHANGED"];
        for (uint256 i; i < 2; ++i) {
            fSettings = i == 0;
            fCoin = i == 1;
            vm.expectRevert(abi.encodeWithSelector(ChangeFlagSet.selector, names[i]));
            this.requireNoFlags();
        }
        fCoin = false;
        this.requireNoFlags();
    }

    /// @dev the scripts are not importable from a test (they pull the production sources onto the via_ir profile), so
    /// the call sites are read from the source
    function test_theScriptsCallTheGuards() public view {
        string memory d = vm.readFile("script/Deploy.s.sol");
        string memory r = vm.readFile("script/Resume.s.sol");
        assertTrue(vm.contains(d, "        _requireNoChangeFlags();\n"), "Deploy refuses the change flags");
        assertTrue(vm.contains(r, "        _requireNoChangeFlags();\n"), "Resume refuses the change flags");
        assertTrue(vm.contains(d, "preflight(c, deployer);"), "Deploy runs preflight");
        // the guards sit before the config is loaded, so nothing else runs while a flag is set
        assertTrue(
            _indexOf(d, "_requireNoChangeFlags();") < _indexOf(d, "loadConfig("), "Deploy: flags before the config"
        );
        assertTrue(
            _indexOf(r, "_requireNoChangeFlags();") < _indexOf(r, "loadConfig("), "Resume: flags before the config"
        );
    }

    function _indexOf(string memory s, string memory needle) internal pure returns (uint256) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        for (uint256 i; i + b.length <= a.length; ++i) {
            uint256 k;
            while (k < b.length && a[i + k] == b[k]) ++k;
            if (k == b.length) return i;
        }
        return type(uint256).max;
    }
}
