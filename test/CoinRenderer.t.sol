// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {CoinRenderer} from "../src/CoinRenderer.sol";

interface IStatementArt {
    function svg(bytes21[80] memory seeds, uint64[80] memory timestamps) external pure returns (string memory);
}

/// the coin's metadata renderer, deployed and set by the launch: the pile as a page, whole under 80, sampled per block
/// above, drawn by the live code
contract CoinRendererTest is Fixture {
    /// Statements.art() at the fork block, the drawing the live statements use
    IStatementArt private constant LIVE_ART = IStatementArt(0x82D2000f7C7Bc14FCFAD82Dca47620eC017269f1);
    string private constant BLANK =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10000 12500" shape-rendering="crispEdges"><rect width="10000" height="12500" fill="#ffffff"/></svg>';

    CoinRenderer private r;

    function setUp() public override {
        super.setUp();
        r = CoinRenderer(renderer);
    }

    function test_theLaunchSetsTheRendererOnTheCoin() public view {
        assertEq(address(r.core()), address(core), "core");
        assertEq(coin.metadataRenderer(), renderer, "set on the coin");
        assertEq(coin.contractURI(), r.contractURI(address(coin)), "the coin serves the renderer's uri");
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
        return r.page(seeds, paidAt, n);
    }

    function test_anEmptyPileIsABlankPage() public view {
        assertEq(core.pileSize(), 0, "pile");
        assertEq(r.image(), BLANK, "blank page");
    }

    function test_contractURICarriesTheCoinFieldsAndTheImage() public view {
        string memory uri = r.contractURI(address(coin));
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
        string memory svg = r.image();
        assertEq(_cells(svg), 30, "cells");
        assertEq(svg, _pageOf(core.pilePage(0, 30), 30), "pile order");
        vm.prevrandao(bytes32(uint256(7)));
        assertEq(r.image(), svg, "prevrandao changes nothing under 80");
    }

    function test_aPileOver80IsSampledPerBlock() public {
        _fillEthPile(90);
        vm.prevrandao(bytes32(uint256(1)));
        string memory a = r.image();
        assertEq(_cells(a), 80, "80 cells");
        assertEq(r.image(), a, "same block, same page");
        vm.prevrandao(bytes32(uint256(2)));
        string memory b = r.image();
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
        assertEq(r.page(seeds, paidAt, 80), LIVE_ART.svg(seeds, paidAt), "live drawing");
    }

    function test_gasOfAFullPage() public {
        _fillEthPile(90);
        uint256 g = gasleft();
        string memory uri = r.contractURI(address(coin));
        g -= gasleft();
        console2.log("contractURI gas at 80 cells", g, "bytes", bytes(uri).length);
        assertLt(g, 40_000_000, "under a 50M eth_call cap with margin");
    }
}
