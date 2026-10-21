// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Report} from "./Report.sol";

interface IClaimsToken {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice the post launch claim activation of decision 260: phase 2 launches with CC redemption off and the claim
/// system is added days later in reviewed owner sends, one per run. `STEP` selects the send: `allocate` moves
/// `CLAIM_AMOUNT` of free working funds into the claim reserve (`allocateToClaims`); `fund` pulls `CLAIM_AMOUNT` from
/// the owner (`approve` then `fundClaims`, two transactions in one send); `enable` turns CC redemption on with the
/// other two switches as they are; `disable` turns it off. every step previews first, reads back after, and prints a
/// plan hash a send must restate as `PHASE2_CLAIMS_PLAN_HASH`. `enable` refuses an empty claim reserve unless
/// `ALLOW_EMPTY_CLAIMS=1`, and refuses a treasury that is not selected for claims or whose token's transfers are not
/// open. nothing is sent without `SEND=1 --broadcast` and the owner as signer.
/// `STEP=allocate TREASURY=0x... CLAIM_AMOUNT=<base units> forge script script/Phase2Claims.s.sol --rpc-url
/// https://gateway.tenderly.co/public/mainnet` (add `SEND=1 PHASE2_CLAIMS_PLAN_HASH=<printed> --broadcast --account
/// ripe0x` to send)
contract Phase2Claims is Script, Report {
    error NotOwner(address owner, address signer);
    error BadStep(string step);
    error PlanHashMismatch(bytes32 want, bytes32 given);
    error AmountRequired();

    struct Inputs {
        address treasury;
        string step;
        uint256 amount;
        bool allowEmpty;
    }

    function run() external {
        Inputs memory i = Inputs({
            treasury: vm.envAddress("TREASURY"),
            step: vm.envString("STEP"),
            amount: vm.envOr("CLAIM_AMOUNT", uint256(0)),
            allowEmpty: vm.envOr("ALLOW_EMPTY_CLAIMS", uint256(0)) == 1
        });
        bool send = vm.envOr("SEND", uint256(0)) == 1;
        if (send) {
            bytes32 want = planHash(i);
            bytes32 given = vm.envOr("PHASE2_CLAIMS_PLAN_HASH", bytes32(0));
            if (given != want) revert PlanHashMismatch(want, given);
        }
        execute(i, send);
    }

    /// @notice the hash of the step and the state it applies to: the chain, the treasury, the step, the amount, the
    /// claim reserve and the switches as read
    function planHash(Inputs memory i) public view returns (bytes32) {
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
        return keccak256(
            abi.encode(
                block.chainid,
                i.treasury,
                keccak256(bytes(i.step)),
                i.amount,
                t.claimReserve(),
                t.conversionEnabled(),
                t.workingPaymentsEnabled(),
                t.ccRedemptionEnabled()
            )
        );
    }

    /// @notice the preview, the send (broadcast only with `send`) and the readback. a test calls it with its own
    /// inputs and `send` false, or with `send` true under a prank of the owner
    function execute(Inputs memory i, bool send) public {
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
        bytes32 step = keccak256(bytes(i.step));
        _reset();
        _preview(t, i);
        _info("preview: plan hash (PHASE2_CLAIMS_PLAN_HASH of a send)", vm.toString(planHash(i)));
        _print(string.concat("phase 2 claims preview: ", i.step));
        _require();
        _reset();
        if (send) {
            vm.startBroadcast();
            (, address signer,) = vm.readCallers();
            if (signer != t.owner()) revert NotOwner(t.owner(), signer);
        } else {
            console.log("no send: SEND is not 1, the owner call is simulated only");
            vm.startPrank(t.owner());
        }
        if (step == keccak256("allocate")) {
            if (i.amount == 0) revert AmountRequired();
            t.allocateToClaims(i.amount);
        } else if (step == keccak256("fund")) {
            if (i.amount == 0) revert AmountRequired();
            address owner = t.owner();
            IClaimsToken token = IClaimsToken(t.balanceToken());
            if (token.allowance(owner, i.treasury) < i.amount) token.approve(i.treasury, i.amount);
            t.fundClaims(i.amount);
        } else if (step == keccak256("enable")) {
            t.setSwitches(t.conversionEnabled(), t.workingPaymentsEnabled(), true);
        } else if (step == keccak256("disable")) {
            t.setSwitches(t.conversionEnabled(), t.workingPaymentsEnabled(), false);
        } else {
            revert BadStep(i.step);
        }
        if (send) vm.stopBroadcast();
        else vm.stopPrank();
        _readback(t, i, step);
        _print(
            string.concat(send ? "phase 2 claims readback: " : "phase 2 claims readback of the simulation: ", i.step)
        );
        _require();
        _record(t, i);
    }

    function _preview(IPhase2BalanceTreasury t, Inputs memory i) private {
        bytes32 step = keccak256(bytes(i.step));
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _code("preview: treasury has code", i.treasury);
        _info("preview: owner", vm.toString(t.owner()));
        _info(
            "preview: switches conversion / working / redemption",
            string.concat(
                vm.toString(t.conversionEnabled()),
                " / ",
                vm.toString(t.workingPaymentsEnabled()),
                " / ",
                vm.toString(t.ccRedemptionEnabled())
            )
        );
        _info("preview: claim reserve", vm.toString(t.claimReserve()));
        _info("preview: free working", vm.toString(t.freeWorking()));
        _check("preview: not migrated", !t.migrated(), "migrated");
        if (step == keccak256("allocate")) {
            _check("preview: amount given", i.amount != 0, "CLAIM_AMOUNT");
            _check("preview: free working covers the amount", t.freeWorking() >= i.amount, vm.toString(t.freeWorking()));
        } else if (step == keccak256("fund")) {
            _check("preview: amount given", i.amount != 0, "CLAIM_AMOUNT");
            IClaimsToken token = IClaimsToken(t.balanceToken());
            _check(
                "preview: owner holds the amount",
                token.balanceOf(t.owner()) >= i.amount,
                vm.toString(token.balanceOf(t.owner()))
            );
            _check("preview: transfers open for the pull", t.transfersReady(), "transfersReady()");
        } else if (step == keccak256("enable")) {
            _check("preview: redemption is off", !t.ccRedemptionEnabled(), "already on");
            _check("preview: treasury selected for claims", t.selectedForClaims(), "selectedForClaims()");
            _check("preview: transfers open", t.transfersReady(), "transfersReady()");
            _check("preview: solvent", t.solvent(), "solvent()");
            _check(
                "preview: claim reserve funded (ALLOW_EMPTY_CLAIMS=1 waives)",
                t.claimReserve() != 0 || i.allowEmpty,
                "claimReserve is 0"
            );
        } else if (step == keccak256("disable")) {
            _check("preview: redemption is on", t.ccRedemptionEnabled(), "already off");
        } else {
            _check("preview: step is allocate, fund, enable or disable", false, i.step);
        }
    }

    function _readback(IPhase2BalanceTreasury t, Inputs memory i, bytes32 step) private {
        _info("readback: claim reserve", vm.toString(t.claimReserve()));
        _info("readback: free working", vm.toString(t.freeWorking()));
        _check("readback: solvent", t.solvent(), "solvent()");
        if (step == keccak256("enable")) {
            _check("readback: redemption on", t.ccRedemptionEnabled(), "ccRedemptionEnabled()");
            (uint256 out,,,, bool executable) = t.quoteRedemption(1e18);
            _check(
                "readback: a burn of 1e18 CC quotes and executes",
                (out != 0 && executable) || (t.claimReserve() == 0 && i.allowEmpty),
                string.concat(vm.toString(out), " executable ", vm.toString(executable))
            );
        } else if (step == keccak256("disable")) {
            _check("readback: redemption off", !t.ccRedemptionEnabled(), "ccRedemptionEnabled()");
        } else {
            _check(
                "readback: redemption unchanged by a funding step",
                true,
                string.concat("redemption ", vm.toString(t.ccRedemptionEnabled()))
            );
        }
    }

    function _record(IPhase2BalanceTreasury t, Inputs memory i) private view {
        console.log(
            string.concat(
                'record: {"chainId":',
                vm.toString(block.chainid),
                ',"block":',
                vm.toString(block.number),
                ',"treasury":"',
                vm.toString(i.treasury),
                '","step":"',
                i.step,
                '","amount":',
                vm.toString(i.amount),
                ',"claimReserve":',
                vm.toString(t.claimReserve()),
                ',"ccRedemptionEnabled":',
                vm.toString(t.ccRedemptionEnabled()),
                ',"configEpoch":',
                vm.toString(uint256(t.configEpoch())),
                "}"
            )
        );
    }
}
