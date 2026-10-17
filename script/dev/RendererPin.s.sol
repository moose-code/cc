// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ArtifactLoader, ArtifactIdentity} from "../ArtifactLoader.sol";

/// @notice prints the masked runtime hash and length `Checks`/`BuildIdentity` pin for a renderer artifact. dev tool.
contract RendererPin is Script, ArtifactIdentity {
    function run() external {
        string memory name = vm.envOr("ARTIFACT", string("LogoCoinRenderer"));
        ArtifactLoader loader = new ArtifactLoader();
        loader.load(name);
        console2.log(name);
        console2.log("HASH", vm.envString(_idKey(name, "HASH")));
        console2.log("LEN", vm.envString(_idKey(name, "LEN")));
    }
}
