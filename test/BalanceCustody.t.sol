// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// @notice balance custody in the module (decision 117): the module holds the balance token, the Core holds none. a
/// redemption keeps its proceeds in the module and the Core checks the module's holding rose; the bid pays through the
/// module's `pay` and the Core checks the seller's holding rose; a misbehaving module reverts and the bid off accumulates
contract BalanceCustodyTest is Fixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("custody");
        _enterPhase2();
    }

    // promise: SPEC 9 sellForBalance reverts BadModule when the module pays the seller less than the total
    function test_sellForBalance_payUnderpaysRevertsBadModule() public {
        uint256[] memory ids = _credits(user, 1);
        mod.setPayOutBps(9_000); // the module sends 90 percent of what the core asks
        vm.prank(user);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 redeemStatement reverts BadModule when the module's holding rises less than required
    function test_redeem_moduleHoldingShortRevertsBadModule() public {
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        mod.setPayBps(10_000 - core.settings().redeemSlippageBps - 1); // mints less than the required rise
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(sid);
    }

    // promise: SPEC 9 sellForBalance reverts PotTooSmall when the module's available is below the batch
    function test_sellForBalance_availableBelowBatchRevertsPotTooSmall() public {
        uint256[] memory ids = _credits(user, 6);
        uint256 refScore = RATE_SCORE;
        uint256 floorBps = 10_000 - core.settings().balanceBidMarginBps;
        // available fixed so its bps of par is exactly the floor: each credit pays score * unit * floor / 10_000. six
        // credits keep the summed score above refScore, so the running total passes available before the batch ends
        mod.setAvailable(UNIT * floorBps * refScore / 10_000);
        vm.prank(user);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 the bid off is the accumulate mode: redemptions keep filling the module and sellForBalance reverts
    function test_bidOff_accumulates() public {
        _setSwitches(true, false); // redeem on, the balance bid off
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        uint256 held = _moduleHolding();
        core.redeemStatement(sid);
        assertGt(_moduleHolding(), held, "a redemption raised the module holding while the bid is off");
        uint256[] memory ids = _credits(user, 1);
        vm.prank(user);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(ids);
    }
}
