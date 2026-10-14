// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {CoinRenderer} from "../src/CoinRenderer.sol";
import {DeployCoinRenderer} from "../script/DeployCoinRenderer.s.sol";

interface IStatementArt {
    function svg(bytes21[80] memory seeds, uint64[80] memory timestamps) external pure returns (string memory);
}

/// the coin's metadata renderer: the pile as a page, whole under 80, sampled per block above, drawn by the live code
contract CoinRendererTest is Fixture {
    /// Statements.art() at the fork block, the drawing the live statements use
    IStatementArt private constant LIVE_ART = IStatementArt(0x82D2000f7C7Bc14FCFAD82Dca47620eC017269f1);
    string private constant BLANK =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10000 12500" shape-rendering="crispEdges"><rect width="10000" height="12500" fill="#ffffff"/></svg>';

    CoinRenderer private renderer;

    function setUp() public override {
        super.setUp();
        renderer = new CoinRenderer(core);
    }

    function _cells(string memory svg) private pure returns (uint256 n) {
        bytes memory needle = bytes('<svg x="');
        bytes memory hay = bytes(svg);
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 k; k < needle.length && hit; ++k) {
                hit = hay[i + k] == needle[k];
            }
            if (hit) ++n;
        }
    }

    function _pageOf(uint256[] memory ids, uint256 n) private view returns (string memory) {
        bytes21[80] memory seeds;
        uint64[80] memory paidAt;
        for (uint256 i; i < n; ++i) {
            seeds[i] = CREDITS.seedOf(ids[i]);
            paidAt[i] = CREDITS.timestampOf(ids[i]);
        }
        return renderer.page(seeds, paidAt, n);
    }

    function test_anEmptyPileIsABlankPage() public view {
        assertEq(core.pileSize(), 0, "pile");
        assertEq(renderer.image(), BLANK, "blank page");
    }

    function test_contractURICarriesTheCoinFieldsAndTheImage() public view {
        string memory uri = renderer.contractURI(address(coin));
        string memory prefix = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, prefix), "json data uri");
        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        string memory expected = string.concat(
            '{"name":"', coin.name(), '","symbol":"', coin.symbol(), '","description":"', FIXTURE_DESCRIPTION,
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(BLANK)), '"}'
        );
        assertEq(json, expected, "json");
    }

    function test_aPileUnder80IsDrawnWholeInPileOrder() public {
        _fillEthPile(30);
        string memory svg = renderer.image();
        assertEq(_cells(svg), 30, "cells");
        assertEq(svg, _pageOf(core.pilePage(0, 30), 30), "pile order");
        vm.prevrandao(bytes32(uint256(7)));
        assertEq(renderer.image(), svg, "prevrandao changes nothing under 80");
    }

    function test_aPileOver80IsSampledPerBlock() public {
        _fillEthPile(90);
        vm.prevrandao(bytes32(uint256(1)));
        string memory a = renderer.image();
        assertEq(_cells(a), 80, "80 cells");
        assertEq(renderer.image(), a, "same block, same page");
        vm.prevrandao(bytes32(uint256(2)));
        string memory b = renderer.image();
        assertEq(_cells(b), 80, "80 cells");
        assertNotEq(keccak256(bytes(a)), keccak256(bytes(b)), "another block, another sample");
        assertNotEq(keccak256(bytes(a)), keccak256(bytes(_pageOf(core.pilePage(0, 80), 80))), "sampled, not the oldest 80");
    }

    function test_aFullPageMatchesTheLiveStatementArt() public view {
        bytes21[80] memory seeds;
        uint64[80] memory paidAt;
        for (uint256 i; i < 80; ++i) {
            uint256 id = CreditIds.at(i);
            seeds[i] = CREDITS.seedOf(id);
            paidAt[i] = CREDITS.timestampOf(id);
        }
        assertEq(renderer.page(seeds, paidAt, 80), LIVE_ART.svg(seeds, paidAt), "live drawing");
    }

    function test_theDeployScriptDeploysForTheCoreInTheEnvironment() public {
        vm.setEnv("CORE", vm.toString(address(core)));
        vm.chainId(1);
        CoinRenderer deployed = new DeployCoinRenderer().run();
        assertEq(address(deployed.core()), address(core), "core");
        assertEq(deployed.image(), BLANK, "renders");
    }

    function test_gasOfAFullPage() public {
        _fillEthPile(90);
        uint256 g = gasleft();
        string memory uri = renderer.contractURI(address(coin));
        g -= gasleft();
        console2.log("contractURI gas at 80 cells", g, "bytes", bytes(uri).length);
        assertLt(g, 40_000_000, "under a 50M eth_call cap with margin");
    }
}
