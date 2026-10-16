// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice read only check of a launched system against the config. safe to run against mainnet at any time.
/// `CORE=0x... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. set DEPLOYER to print the verify inputs and to check the CREATE2 address of the Core. the override flags SETTINGS_CHANGED and COIN_CHANGED name a change the owner made after launch. the state of `coin.locked()` (script/Lock.s.sol) is printed as an info row. set CONFIG_HASH to check the signed off hash.
/// prints a table and reverts on any mismatch. run it right after the launch: the supply and rate rows are exact only
/// until the first trade or the first fill. with DEPLOYER set and every row ok it ends with one `record: {json}` line,
/// the addresses read back from the chain that script/deploy.sh writes into deployments/<chainId>.json
contract Postflight is Script, LaunchChecks {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        address core = vm.envAddress("CORE");
        postflight(c, core);
        // the same hash preflight printed and Deploy required. when CONFIG_HASH is set it must match
        bytes32 given = vm.envOr("CONFIG_HASH", bytes32(0));
        if (given != bytes32(0)) _eq("config hash equals CONFIG_HASH", configHash(c), given);
        address deployer = vm.envOr("DEPLOYER", address(0));
        _print("postflight");
        if (core.code.length != 0) printVerifyInputs(ICore(payable(core)), c, deployer);
        _require();
        if (deployer != address(0)) _printRecord(ICore(payable(core)), c);
    }

    /// @dev the record fields that come from the chain: the Core, its controller and coin, the CREATE2 adapters and
    /// renderer (each code checked by the rows above), the linked CoreLib, the stack the Core holds and the Core owner
    function _printRecord(ICore k, LaunchConfig memory c) private view {
        string memory contracts = string.concat(
            '"core":"',
            vm.toString(address(k)),
            '","controller":"',
            vm.toString(k.controller()),
            '","coin":"',
            vm.toString(k.COIN()),
            '","seaportAdapter":"',
            vm.toString(seaportAdapterAddress(address(k), c.seaportRecipients)),
            '","strategyAdapter":"',
            vm.toString(strategyAdapterAddress())
        );
        string memory more = string.concat(
            '","renderer":"',
            vm.toString(rendererAddress(c)),
            '","library":"',
            vm.toString(findLibrary(address(k).code)),
            '","credits":"',
            vm.toString(Mainnet.CREDITS),
            '","statements":"',
            vm.toString(Mainnet.STATEMENTS)
        );
        string memory stack = string.concat(
            '","poolManager":"',
            vm.toString(address(k.MANAGER())),
            '","hook":"',
            vm.toString(k.HOOK()),
            '","poolFee":',
            vm.toString(uint256(k.POOL_FEE())),
            ',"tickSpacing":',
            vm.toString(int256(k.TICK_SPACING())),
            ',"owner":"',
            vm.toString(k.owner()),
            '"}'
        );
        console.log(string.concat("record: {", contracts, more, stack));
    }
}
