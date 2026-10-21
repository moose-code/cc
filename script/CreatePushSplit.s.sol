// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PushSplitCreator, SplitConfig, ISplitFactoryV2, ISplitWalletV2} from "./PushSplit.sol";

/// @notice creates the decision 255 push split on its own (script/PushSplit.sol): Phase2Deploy creates it as its
/// fourth creation, this script is for creating only the split, for instance after a change of the recipients. the
/// preview creates the split in simulation, proves the push and prints the keeper's `SPLIT_*` lines and the
/// `PHASE2_ARTIST` value. nothing is sent without `SEND=1 --broadcast`.
/// inputs: `CORE` (default the mainnet Core) for the artist, the operator (its `payee`) and the controller (its
/// `owner`); `SPLIT_ARTIST`, `SPLIT_OPERATOR`, `SPLIT_CONTROLLER` override each.
/// `forge script script/CreatePushSplit.s.sol --rpc-url https://gateway.tenderly.co/public/mainnet` (add `SEND=1
/// --broadcast --account ripe0x` to create)
contract CreatePushSplit is PushSplitCreator {
    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    function run() external {
        SplitPlan memory p = plan();
        requireSplitPlan(p);
        console.log("push factory", PUSH_FACTORY);
        console.log("artist (5/6)", p.artist);
        console.log("operator (1/6)", p.operator);
        console.log("controller", p.controller);
        console.log("expected split hash");
        console.logBytes32(splitHashOf(splitConfig(p.artist, p.operator)));
        bool send = _send();
        if (send) vm.startBroadcast();
        address split = createPushSplit(p, msg.sender);
        if (send) vm.stopBroadcast();
        acceptSplit(split, p);
        console.log("split", split);
        console.log(send ? "created" : "preview only. add SEND=1 and --broadcast with a signer to create");
        printSplitLines(split, p);
    }

    /// @dev the artist, operator and controller: environment overrides, else the Core's artist, payee and owner
    function plan() public view returns (SplitPlan memory p) {
        ICore core = ICore(payable(vm.envOr("CORE", MAINNET_CORE)));
        p.artist = vm.envOr("SPLIT_ARTIST", core.artist());
        p.operator = vm.envOr("SPLIT_OPERATOR", core.payee());
        p.controller = vm.envOr("SPLIT_CONTROLLER", core.owner());
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }
}
