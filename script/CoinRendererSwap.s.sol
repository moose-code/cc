// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CoinRenderer} from "../src/CoinRenderer.sol";
import {ICore} from "../src/interfaces/ICore.sol";

interface IRendererSwapCoin {
    function admin() external view returns (address);
    function metadataRenderer() external view returns (address);
    function setMetadataRenderer(address renderer) external;
    function tokenURI() external view returns (string memory);
    function contractURI() external view returns (string memory);
}

/// Runs deploy, bind and activate in order. RENDERER_STEP=1/2/3 retains individual steps; unset or 0 runs all.
/// Preview without --broadcast; send with the explicit owner --sender, --account ripe0x and --slow.
contract CoinRendererSwap is Script {
    address private constant OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    ICore private constant CORE = ICore(payable(0xcdb1889ae12074d750CD9B8531B692015465e0dD));
    IRendererSwapCoin private constant COIN = IRendererSwapCoin(0x28ef14A55DC93CDCB9001FA038A184967146C789);
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 private constant SALT = keccak256("credits.coinRenderer.balances.creditCycle.v1");

    function run() public {
        uint256 step = vm.envOr("RENDERER_STEP", uint256(0));
        if (step == 0) {
            _runStep(1);
            _runStep(2);
            _runStep(3);
        } else {
            _runStep(step);
        }
    }

    function _runStep(uint256 step) private {
        require(block.chainid == 1, "mainnet only");
        require(msg.sender == OWNER, "use the owner sender");
        require(CORE.owner() == OWNER && COIN.admin() == OWNER, "authority changed");
        bytes memory init = abi.encodePacked(type(CoinRenderer).creationCode, abi.encode(OWNER));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_DEPLOYER);
        require(step >= 1 && step <= 3, "RENDERER_STEP must be 1, 2 or 3");
        console2.log("chain", block.chainid);
        console2.log("signer", OWNER);
        console2.log("renderer", predicted);
        console2.log("current renderer", COIN.metadataRenderer());
        console2.log("native value", uint256(0));
        CoinRenderer renderer = CoinRenderer(predicted);
        if (step == 1) {
            require(predicted.code.length == 0, "renderer already deployed; inspect receipts");
            require(CREATE2_DEPLOYER.code.length != 0, "missing CREATE2 deployer");
            console2.log("deploy CoinRenderer: constructor owner", OWNER);
            vm.startBroadcast(OWNER);
            address deployed = address(new CoinRenderer{salt: SALT}(OWNER));
            vm.stopBroadcast();
            require(deployed == predicted && renderer.owner() == OWNER, "deployment mismatch");
        } else {
            require(predicted.code.length != 0 && renderer.owner() == OWNER, "missing candidate renderer");
            if (step == 2) {
                require(address(renderer.core()) == address(0), "already bound; inspect receipts");
                console2.log("setCore", address(CORE));
                vm.startBroadcast(OWNER);
                renderer.setCore(CORE);
                vm.stopBroadcast();
                require(address(renderer.core()) == address(CORE), "binding mismatch");
            } else {
                require(address(renderer.core()) == address(CORE), "wrong Core");
                require(COIN.metadataRenderer() == 0x0D2022F8D780884A1B46de156CBfc4f36423504c, "current renderer changed");
                string memory expected = renderer.contractURI(address(COIN));
                console2.log("setMetadataRenderer", predicted);
                vm.startBroadcast(OWNER);
                COIN.setMetadataRenderer(predicted);
                vm.stopBroadcast();
                require(COIN.metadataRenderer() == predicted, "activation mismatch");
                require(keccak256(bytes(COIN.tokenURI())) == keccak256(bytes(expected)), "tokenURI mismatch");
                require(keccak256(bytes(COIN.contractURI())) == keccak256(bytes(expected)), "contractURI mismatch");
            }
        }
    }
}
