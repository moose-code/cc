// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {LogoCoinRenderer} from "../src/LogoCoinRenderer.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

interface IContractUri {
    function contractURI() external view returns (string memory);
}

contract LogoCoinRendererTest is Test {
    // promise: the image is the animated CC logo svg, served to every coin unchanged, and deploy cost is known
    function test_image_is_animated_logo() public {
        LogoCoinRenderer r = new LogoCoinRenderer(address(this));
        string memory img = r.image();
        assertTrue(bytes(img).length > 0, "empty image");
        // svg root with animation present
        assertEq(_slice(img, 0, 5), "<svg ", "not svg");
        assertTrue(_contains(img, "repeatCount=\"indefinite\""), "not animated");
        assertTrue(_contains(img, "#00a3e0") && _contains(img, "#e5007e") && _contains(img, "#ffd400"), "missing cmy");
    }

    function test_deploy_gas() public {
        uint256 g = gasleft();
        new LogoCoinRenderer(address(this));
        emit log_named_uint("create_execution_gas", g - gasleft());
    }

    function _slice(string memory s, uint256 a, uint256 b) internal pure returns (string memory) {
        bytes memory bs = bytes(s);
        bytes memory o = new bytes(b - a);
        for (uint256 i; i < b - a; ++i) o[i] = bs[a + i];
        return string(o);
    }

    function _contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory bs = bytes(s);
        bytes memory bn = bytes(needle);
        if (bn.length == 0 || bn.length > bs.length) return false;
        for (uint256 i; i <= bs.length - bn.length; ++i) {
            bool ok = true;
            for (uint256 j; j < bn.length; ++j) {
                if (bs[i + j] != bn[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

/// the launch names the LogoCoinRenderer in the token config and the coin serves its uri (the promise moved here from
/// CoinRendererTest when the launch switched to the logo renderer)
contract LogoCoinRendererLaunchTest is Fixture {
    LogoCoinRenderer private r;

    function setUp() public override {
        super.setUp();
        r = LogoCoinRenderer(renderer);
    }

    function test_theLaunchNamesTheRendererInTheTokenConfig() public view {
        assertEq(address(r.core()), address(core), "core");
        assertEq(r.owner(), lc.owner, "owner");
        assertEq(renderer, rendererAddress(lc), "create2 address of the owner and the salt");
        assertEq(coin.metadataRenderer(), renderer, "named at launch");
        assertEq(coin.tokenURI(), r.contractURI(address(coin)), "the coin serves the renderer's uri");
        assertEq(coin.tokenURI(), IContractUri(address(coin)).contractURI(), "tokenURI and contractURI agree");
    }

    // promise: the renderer address is a function of the owner and the salt and does not depend on the Core
    function test_theRendererAddressIsAFunctionOfTheConfig() public view {
        LaunchConfig memory c = lc;
        assertEq(rendererAddress(c), renderer);
        c.salt = keccak256("another salt");
        assertTrue(rendererAddress(c) != renderer, "another salt, another renderer");
    }
}
