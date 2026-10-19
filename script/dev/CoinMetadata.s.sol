// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CoinRenderer} from "../../src/CoinRenderer.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a wallet's credits as a pile: the two pile reads CoinRenderer makes, over `Credits.tokensOf(holder)`
contract HolderPile {
    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    address public immutable holder;

    constructor(address holder_) {
        holder = holder_;
    }

    function pileSize() external view returns (uint256) {
        return CREDITS.balanceOf(holder);
    }

    function pilePage(uint256, uint256 n) external view returns (uint256[] memory ids) {
        ids = CREDITS.tokensOf(holder);
        if (n < ids.length) {
            assembly ("memory-safe") {
                mstore(ids, n)
            }
        }
    }
}

/// the three coin reads CoinRenderer makes
contract DemoCoin {
    function name() external pure returns (string memory) {
        return "CC";
    }

    function symbol() external pure returns (string memory) {
        return "CC";
    }

    function description() external pure returns (string memory) {
        return
            "CC is a coin whose trading fees fund a permanent public bid for Credits. Anyone can sell Credits to the engine at that bid, and the engine sweeps cheaper listings on approved venues. The engine composes 80 Credits into a Statement, holds it, and sells it at a price that starts above cost and falls to a floor. A quarter of every sale burns CC and three quarters buys more Credits. The image is the engine's pile of Credits, up to 80 of them, drawn as a Statement page and re-sampled every block.";
    }
}

/// prints the coin metadata CoinRenderer returns, on a fork. renders CoinRenderer, the pile renderer kept for an owner
/// swap; the launch coin uses LogoCoinRenderer. `CORE` names a deployed Core and `COIN` its coin;
/// without them `HOLDER` names a wallet whose credits stand in for the pile. script/tools/coin-metadata.sh decodes
/// the output into files and a viewer
contract CoinMetadata is Script {
    function run() external {
        address core = vm.envOr("CORE", address(0));
        address coin = vm.envOr("COIN", address(0));
        if (core == address(0)) {
            address holder = vm.envAddress("HOLDER");
            core = address(new HolderPile(holder));
            coin = address(new DemoCoin());
            console.log("pile: the credits of", holder);
        }
        address owner = address(uint160(uint256(keccak256("coin-metadata.owner"))));
        CoinRenderer renderer = new CoinRenderer(owner);
        vm.prank(owner);
        renderer.setCore(ICore(payable(core)));
        console.log("pile size", ICore(payable(core)).pileSize());
        console.log("block", block.number, "prevrandao", block.prevrandao);
        string memory uri = renderer.contractURI(coin);
        console.log("uri bytes", bytes(uri).length);
        console.log(string.concat("CONTRACT_URI=", uri));
    }
}
