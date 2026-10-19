// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LogoCoinRenderer} from "../../src/LogoCoinRenderer.sol";
import {ICoinRenderer} from "../../src/interfaces/ICoinRenderer.sol";
import {IArtCoinsTokenV2} from "../../src/interfaces/ArtCoinsV2.sol";

/// The empty-config coin fields used when no deployed coin is supplied.
contract DemoCoin {
    function name() external pure returns (string memory) {
        return "CC";
    }

    function symbol() external pure returns (string memory) {
        return "CC";
    }

    function description() external pure returns (string memory) {
        return "";
    }
}

/// Prints metadata through the live coin's renderer, or the launch LogoCoinRenderer with the current empty fields.
/// script/tools/coin-metadata.sh decodes the URI into files and a viewer.
contract CoinMetadata is Script {
    function run() external {
        address coin = vm.envOr("COIN", address(0));
        ICoinRenderer renderer;
        if (coin == address(0)) {
            coin = address(new DemoCoin());
            renderer = new LogoCoinRenderer(address(uint160(uint256(keccak256("coin-metadata.owner")))));
        } else {
            renderer = ICoinRenderer(IArtCoinsTokenV2(coin).metadataRenderer());
        }
        string memory uri = renderer.contractURI(coin);
        console.log("renderer", address(renderer));
        console.log("block", block.number);
        console.log("uri bytes", bytes(uri).length);
        console.log(string.concat("CONTRACT_URI=", uri));
    }
}
