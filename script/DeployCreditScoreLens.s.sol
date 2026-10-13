// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

/// @notice Deploy CreditScoreLens on Ethereum mainnet after checking its three on-chain sources.
/// @dev Without --broadcast, forge script only simulates deployment. No constructor arguments are needed.
contract DeployCreditScoreLens is Script {
    error UnsupportedChain(uint256 chainId);
    error SourceCodeChanged(address source);
    error DeploymentFailed();

    /// @notice Deploy the compiled CreditScoreLens artifact and print its address and runtime hash.
    /// @return lens The deployed CreditScoreLens address in the simulation or broadcast.
    function run() external returns (address lens) {
        if (block.chainid != 1) revert UnsupportedChain(block.chainid);
        _checkSource(
            0x97630aA70AB14ed9883B41dAfccBc11349723043,
            0x8ab17e09de9f492357738695c934fb72062a0f1aa0c66eaf388b3fcf659d57d4
        );
        _checkSource(
            0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7,
            0xeea220f30cd748713b758d3cecf2a3c9e814381ace6d276390663d7e334ddf9d
        );
        _checkSource(
            0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b,
            0x6ea1df2fdef523d462711ac890c1be3df13badae863912f8453018251488f6ae
        );
        bytes memory creationCode = vm.getCode("CreditScoreLens.sol:CreditScoreLens");
        vm.startBroadcast();
        assembly ("memory-safe") {
            lens := create(0, add(creationCode, 32), mload(creationCode))
        }
        vm.stopBroadcast();
        if (lens == address(0)) revert DeploymentFailed();
        console.log("CreditScoreLens", lens);
        console.log("Runtime code hash");
        console.logBytes32(lens.codehash);
    }

    /// @dev Refuse deployment against source bytecode different from the verified mainnet contracts.
    function _checkSource(address source, bytes32 expected) private view {
        if (source.codehash != expected) revert SourceCodeChanged(source);
    }
}
