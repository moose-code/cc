// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";

/// @notice balance custody in the module (decision 117): the module holds the balance token, the Core holds none. a
/// redemption keeps its proceeds in the module and the Core checks the module's holding rose; the bid pays through the
/// module's `pay` and the Core checks the seller's holding rose; a misbehaving module reverts and the bid off accumulates.
/// ported to the live fork: the Core, controller, coin, Statements and the BALANCE token are the live mainnet contracts,
/// the phase 2 treasury is the fresh module. the two misbehaving-module promises keep a mock standin selected on the live
/// Core (a live contract always pays exactly and cannot misbehave); the available-cap and bid-off promises run on the live
/// treasury itself
contract BalanceCustodyTest is LiveFixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("custody");
        _enterPhase2();
    }

    // promise: SPEC 9 sellForBalance reverts BadModule when the module pays the seller less than the total
    function test_sellForBalance_payUnderpaysRevertsBadModule() public {
        // the subject is a misbehaving module, not a live contract: select a mock on the live Core that underpays
        MockBalanceToken mockXt = new MockBalanceToken("Balance Token", "XT");
        MockBalanceModule mockMod = new MockBalanceModule(address(mockXt), _moduleUnit());
        mockXt.mint(address(mockMod), 1e24);
        vm.prank(owner);
        core.setBalanceModule(address(mockMod));
        uint256[] memory ids = _credits(user, 1);
        mockMod.setPayOutBps(9_000); // the module sends 90 percent of what the core asks
        vm.prank(user);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 redeemStatement reverts BadModule when the module's holding rises less than required
    function test_redeem_moduleHoldingShortRevertsBadModule() public {
        // a live treasury always converts the full amount; the short-holding case needs a misbehaving mock on the live Core
        MockBalanceToken mockXt = new MockBalanceToken("Balance Token", "XT");
        MockBalanceModule mockMod = new MockBalanceModule(address(mockXt), _moduleUnit());
        mockXt.mint(address(mockMod), 1e24);
        vm.prank(owner);
        core.setBalanceModule(address(mockMod));
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        mockMod.setPayBps(10_000 - core.settings().redeemSlippageBps - 1); // mints less than the required rise
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(sid);
    }

    // promise: SPEC 9 sellForBalance reverts PotTooSmall when the module's available is below the batch's payouts plus
    // their artist royalties
    function test_sellForBalance_availableBelowBatchRevertsPotTooSmall() public {
        uint256[] memory ids = _credits(user, 6);
        // available at the posted payout of one 100 point credit: six credits sum far above it, so the running total of
        // payouts and royalties passes available before the batch ends. cap the live treasury's available to exactly that
        // by raising its minimum working balance, leaving custody well above it
        uint256 x = _moduleUnit() * RATE_SCORE * core.balanceRate() / 10_000;
        // hoist the custody read before the prank: a call in the argument would consume the prank and the setter would
        // revert OnlyOwner
        uint256 cap = _moduleCustody() - x;
        vm.prank(owner);
        treasury.setMinimumWorkingBalance(cap);
        vm.prank(user);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 the bid off is the accumulate mode: redemptions keep filling the module and sellForBalance reverts
    function test_bidOff_accumulates() public {
        _setSwitches(true, false); // redeem on, the balance bid off
        uint256 sid = _eligibleHeldStatement();
        uint256 held = _moduleCustody();
        core.redeemStatement(sid);
        assertGt(_moduleCustody(), held, "a redemption raised the module holding while the bid is off");
        uint256[] memory ids = _credits(user, 1);
        vm.prank(user);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(ids);
    }
}
