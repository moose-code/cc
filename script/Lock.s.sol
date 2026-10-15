// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice sends `coin.lock()` for the launched system at `CORE`: the allowlist, the restriction switch and the hook's
/// coin admin settings freeze. the hook bounty recipient (the Core), the pool extension and the baseline skim are
/// frozen, so `lowerBaselineSkim` can no longer lower the engine's fee per swap. the pool pays the Core from then on,
/// and a later engine takes the fee stream only by `Core.migrate`. one way. an owner command for later: the deploy
/// leaves the coin unlocked. runs the postflight first and stops on any failed row, requires the hook bounty recipient
/// to be the Core whatever COIN_CHANGED says, sends nothing unless SEND=1 and the run has `--broadcast` and a signer
/// that is the coin admin. the lock read back at the end is read in forge's simulation, the confirmation is the
/// `coin: lock` row of Postflight against the chain.
/// `CORE=0x... forge script script/Lock.s.sol --rpc-url $MAINNET_RPC_URL` (add `SEND=1 --broadcast --ledger` or
/// `--account <name>` to send). docs/RUNBOOK.md section 4
contract Lock is Script, LaunchChecks {
    /// @dev the signer is not the admin of the coin
    error NotCoinAdmin(address admin, address signer);
    /// @dev the recipients are still unlocked after the simulated transaction
    error NotLocked();
    /// @dev the hook pays another address than the Core: the lock would freeze it
    error BountyRecipientNotCore(address recipient, address core);

    function run() external {
        LaunchConfig memory c = _config();
        address core = _core();
        postflight(c, core);
        _print("postflight before the lock");
        _require();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(ICore(payable(core)).COIN());
        if (t.locked()) {
            console.log("the coin is locked already, nothing to send");
            return;
        }
        address recipient = address(_hookSkim(c.stack.hook, t.canonicalPoolId()).bountyRecipient);
        if (recipient != core) revert BountyRecipientNotCore(recipient, core);
        console.log("coin", address(t));
        console.log("coin admin", t.admin());
        console.log("lock calldata");
        console.logBytes(abi.encodeCall(IArtCoinsTokenV2.lock, ()));
        console.log(string.concat("cast send ", vm.toString(address(t)), " \"lock()\""));
        if (!_send()) {
            console.log("nothing sent. add SEND=1 and --broadcast with the coin admin as signer to send");
            return;
        }
        address signer = _startBroadcast();
        if (signer != t.admin()) revert NotCoinAdmin(t.admin(), signer);
        t.lock();
        vm.stopBroadcast();
        if (!t.locked()) revert NotLocked();
        console.log("simulated: the coin reads as locked after the transaction");
        console.log("confirm on chain once it is mined: the coin: lock row of Postflight");
    }

    /// @dev the launch config (LAUNCH_CONFIG or the shipped file), the Core (CORE), the broadcast flag (SEND=1) and the
    /// start of the broadcast. a test overrides them
    function _config() internal virtual returns (LaunchConfig memory) {
        return loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
    }

    function _core() internal view virtual returns (address) {
        return vm.envAddress("CORE");
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }

    function _startBroadcast() internal virtual returns (address signer) {
        vm.startBroadcast();
        (, signer,) = vm.readCallers();
    }
}
