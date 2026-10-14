// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CoinRenderer} from "../src/CoinRenderer.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice deploys CoinRenderer for the Core in `CORE`. without --broadcast forge only simulates. the coin admin then
///         sets the address with `setMetadataRenderer` (docs/RUNBOOK.md, the owner commands)
contract DeployCoinRenderer is Script {
    error UnsupportedChain(uint256 chainId);
    error NoCore(address core);
    error SourceCodeChanged(address source);

    function run() external returns (CoinRenderer renderer) {
        if (block.chainid != 1 && block.chainid != 31337) revert UnsupportedChain(block.chainid);
        address core = vm.envAddress("CORE");
        if (core.code.length == 0) revert NoCore(core);
        if (Mainnet.CREDITS.codehash != 0x8ab17e09de9f492357738695c934fb72062a0f1aa0c66eaf388b3fcf659d57d4) {
            revert SourceCodeChanged(Mainnet.CREDITS);
        }
        vm.startBroadcast();
        renderer = new CoinRenderer(ICore(payable(core)));
        vm.stopBroadcast();
        console.log("CoinRenderer", address(renderer));
        console.log("image bytes", bytes(renderer.image()).length);
    }
}
