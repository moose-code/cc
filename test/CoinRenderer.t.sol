// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {CoinRenderer, IBalancesArtwork} from "../src/CoinRenderer.sol";
import {ICoinRenderer} from "../src/interfaces/ICoinRenderer.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// the Balances renderer on the LiveFixture pin, where the live Core has no balance module: the binding rules, the
/// metadata shape and the logo fallback. the launch deploys the LogoCoinRenderer; this spec deploys a CoinRenderer
/// bound to the live Core
contract CoinRendererTest is LiveFixture {
    CoinRenderer private r;

    function setUp() public override {
        super.setUp();
        r = new CoinRenderer(owner);
        vm.prank(owner);
        r.setCore(ICore(payable(address(core))));
    }

    // promise: the Core is bound once, by the owner
    function test_setCoreIsOwnerOnlyAndOnce() public {
        CoinRenderer fresh = new CoinRenderer(owner);
        vm.expectRevert(ICoinRenderer.NotOwner.selector);
        fresh.setCore(ICore(payable(address(core))));
        vm.startPrank(owner);
        vm.expectRevert(ICoinRenderer.ZeroCore.selector);
        fresh.setCore(ICore(payable(address(0))));
        fresh.setCore(ICore(payable(address(core))));
        vm.expectRevert(ICoinRenderer.CoreSet.selector);
        fresh.setCore(ICore(payable(address(core))));
        vm.stopPrank();
        CoinRenderer unbound = new CoinRenderer(owner);
        vm.expectRevert(ICoinRenderer.ZeroCore.selector);
        unbound.image();
    }

    // promise: a balance module with no Balances artwork draws the CC logo, so the coin's metadata never reverts on it
    function test_aModuleWithoutArtworkDrawsTheLogo() public view {
        // stage B selects a fresh treasury whose artwork depends on the stage B funding; the zero module of the pin
        // is the case under test
        if (_liveStageB()) return;
        assertEq(core.balanceModule(), address(0), "no balance module at the pin");
        assertEq(r.image(), ICoinRenderer(renderer).image(), "the launch logo");
    }

    // promise: contractURI names Credit Cycle and carries the coin's symbol and description with the live image
    function test_contractURICarriesTheCoinFieldsAndTheImage() public view {
        string memory uri = r.contractURI(address(coin));
        string memory prefix = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, prefix), "json data uri");
        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        string memory expected = string.concat(
            '{"name":"Credit Cycle","symbol":"',
            coin.symbol(),
            '","description":"',
            coin.description(),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(r.image())),
            '"}'
        );
        assertEq(json, expected, "json");
    }
}

interface IBalanceTransfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// the Balances renderer after stage C, where the live treasury is the Core's balance module and holds Balances #1670.
/// a fork of its own: LiveFixture's pin predates the treasury
contract CoinRendererTreasuryTest is Test {
    /// @dev the post stage C fork block, overridable by `TREASURY_FORK_BLOCK`
    uint256 internal constant FORK_BLOCK = 26250700;
    ICore internal constant CORE = ICore(payable(0xcdb1889ae12074d750CD9B8531B692015465e0dD));
    address internal constant COIN = 0x28ef14A55DC93CDCB9001FA038A184967146C789;
    address internal constant TREASURY = 0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496;
    address internal constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant BALANCE_HOLDER = 0x5F7a8fb8cc29e795ba19191Dd74D69A90cDADB88;
    IBalancesArtwork internal constant ARTWORK = IBalancesArtwork(0x3F2BA6C00c386986686A429c52099AaCD51b7e38);

    CoinRenderer private r;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("TREASURY_FORK_BLOCK", FORK_BLOCK));
        r = new CoinRenderer(address(this));
        r.setCore(CORE);
    }

    // promise: the image is the live Balances artwork of the Core's balance module
    function test_theImageIsTheTreasuryArtwork() public view {
        assertEq(CORE.balanceModule(), TREASURY, "the treasury is the module");
        assertEq(ARTWORK.tokenIdOf(TREASURY), 1670, "the treasury's artwork");
        assertEq(r.image(), ARTWORK.svg(1670), "the artwork's own drawing");
    }

    // promise: the image follows the treasury's BALANCE, read on every call
    function test_theImageFollowsTheTreasuryBalance() public {
        string memory before = r.image();
        vm.prank(BALANCE_HOLDER);
        IBalanceTransfer(BALANCE).transfer(TREASURY, 1_000e18);
        string memory afterwards = r.image();
        assertNotEq(keccak256(bytes(afterwards)), keccak256(bytes(before)), "a new balance, a new drawing");
        assertEq(afterwards, ARTWORK.svg(1670), "still the artwork's own drawing");
    }

    // promise: the coin's metadata answers within an eth_call gas cap
    function test_gasOfContractURI() public view {
        uint256 g = gasleft();
        string memory uri = r.contractURI(COIN);
        g -= gasleft();
        console2.log("contractURI gas", g, "bytes", bytes(uri).length);
        assertLt(g, 10_000_000, "well under a 50M eth_call cap");
    }
}
