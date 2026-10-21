// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {Phase2Deploy} from "../../script/Phase2Deploy.s.sol";
import {Phase2Wire} from "../../script/Phase2Wire.s.sol";
import {Phase2Settings} from "../../script/Phase2Settings.s.sol";
import {PushSplitCreator} from "../../script/PushSplit.sol";

/// @notice drives a fork of the live Core to the production stage B state through the real owner scripts, in the
/// RUNBOOK order and with the owner's inputs: Phase2Deploy (policy, treasury, ControllerV2 at 15,000 / 3,600, the push
/// split with the Core's artist 5/6 and payee 1/6 and the owner as controller), Phase2Wire STEP=module then
/// STEP=controller, then Phase2Settings with the split as artist. the same path test/Phase2Lifecycle.t.sol runs, so
/// every suite run with LIVE_STAGE=B starts from the state the owner's stage B sends produce
library LiveStageB {
    struct State {
        address treasury;
        address controllerV2;
        address split;
    }

    function run(address core, address balanceToken) internal returns (State memory st) {
        ICore c = ICore(payable(core));
        Phase2Deploy.Result memory r = new StageBDeploy().deploy(
            Phase2Deploy.Inputs({
                core: core,
                balanceToken: balanceToken,
                statementSaleMultiplierBps: 15_000,
                statementRedeemDelaySeconds: 3_600,
                tokenCodehash: balanceToken.codehash,
                allowUnpinnedToken: false,
                split: address(0),
                splitPlan: PushSplitCreator.SplitPlan({artist: c.artist(), operator: c.payee(), controller: c.owner()})
            })
        );
        StageBWire wire = new StageBWire();
        wire.go(_wire(core, r, "module"));
        wire.go(_wire(core, r, "controller"));
        new StageBSettings(core, r.split).applyAsOwner();
        st = State({treasury: r.treasury, controllerV2: r.controllerV2, split: r.split});
    }

    /// @dev the wire inputs of one step, the other fields left at their defaults as test/Phase2Lifecycle.t.sol does
    function _wire(address core, Phase2Deploy.Result memory r, string memory step)
        private
        pure
        returns (Phase2Wire.Inputs memory i)
    {
        i.core = core;
        i.treasury = r.treasury;
        i.controllerV2 = r.controllerV2;
        i.step = step;
    }
}

contract StageBDeploy is Phase2Deploy {
    function deploy(Inputs memory i) external returns (Result memory) {
        return deployPhase2(i, false);
    }
}

contract StageBWire is Phase2Wire {
    function go(Inputs memory i) external {
        execute(i, false);
    }
}

contract StageBSettings is Phase2Settings {
    address internal immutable CORE_;
    address internal immutable SPLIT_;

    constructor(address core, address split) {
        CORE_ = core;
        SPLIT_ = split;
    }

    function applyAsOwner() external {
        ICore c = ICore(payable(CORE_));
        Preview memory p = preview(c);
        vm.startPrank(c.owner());
        applyPatch(c, p);
        vm.stopPrank();
    }

    function _split() internal view override returns (address) {
        return SPLIT_;
    }

    function _core() internal view override returns (address) {
        return CORE_;
    }

    function _overrides() internal pure override returns (string[] memory none) {}
}
