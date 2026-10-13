// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {RawListingAdapter} from "./standins/RawListingAdapter.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";

/// the owner of the core after the timelock was removed: every former queued action is one immediate call with its
/// validity rules, three one way locks, a two step handover. real Core, real stack, the stand in balance module and
/// token, the scripted controller
abstract contract OwnerBase is Fixture {
    MockBalanceToken internal spareToken;
    MockBalanceModule internal spareMod;
    address internal stranger = address(0x5757);
    address internal heir = address(0xEE11);

    function setUp() public virtual override {
        super.setUp();
        spareToken = new MockBalanceToken("Spare Token", "SPT");
        spareMod = new MockBalanceModule(address(spareToken), UNIT);
        vm.deal(heir, 10 ether);
    }

    /// built from its artifact so no test contract embeds its creation code
    function _scripted() internal returns (ScriptedController) {
        return ScriptedController(deployCode("ScriptedController.sol:ScriptedController"));
    }

    // ------------------------------------------------------------------ the six doors, as a table

    uint256 internal constant D_CONTROLLER = 0;
    uint256 internal constant D_MODULE = 1;
    uint256 internal constant D_ADAPTERS = 2;
    uint256 internal constant D_SETTINGS = 3;
    uint256 internal constant D_RATE = 4;
    uint256 internal constant D_REMOVE = 5;
    uint256 internal constant N_DOORS = 7;

    function _doorData(uint256 i) internal returns (bytes memory) {
        if (i == D_CONTROLLER) return abi.encodeCall(ICore.setController, (address(_scripted())));
        if (i == D_MODULE) {
            address token = core.balanceToken() == address(0) ? address(spareToken) : core.balanceToken();
            return abi.encodeCall(ICore.setBalanceModule, (address(new MockBalanceModule(token, UNIT))));
        }
        if (i == D_ADAPTERS) {
            return abi.encodeCall(ICore.addAdapter, (address(uint160(0xA0000 + block.number + gasleft() % 97))));
        }
        if (i == D_SETTINGS) return abi.encodeCall(ICore.setSettings, (core.settings()));
        if (i == D_RATE) return abi.encodeCall(ICore.setRate, (core.rateAtCheckpoint()));
        if (i == D_REMOVE) return abi.encodeCall(ICore.removeAdapter, (address(0xDEAD1)));
        return abi.encodeCall(ICore.transferOwnership, (address(0)));
    }

    /// calls door `i` as `who`
    function _call(uint256 i, address who) internal returns (bool ok, bytes memory out) {
        bytes memory data = _doorData(i);
        vm.prank(who);
        (ok, out) = address(core).call(data);
    }

    function _sel(bytes memory out) internal pure returns (bytes4 s) {
        if (out.length >= 4) s = bytes4(out);
    }

    /// every door but `except` opens for `who`
    function _openExcept(uint256 except, address who) internal {
        for (uint256 i; i < N_DOORS; ++i) {
            if (i == except) continue;
            (bool ok, bytes memory out) = _call(i, who);
            assertTrue(ok, string.concat("door ", vm.toString(i), " is shut: ", vm.toString(_sel(out))));
        }
    }

    function _allShutFor(address who) internal {
        for (uint256 i; i < N_DOORS; ++i) {
            (bool ok, bytes memory out) = _call(i, who);
            assertFalse(ok, string.concat("door ", vm.toString(i), " is open"));
            assertEq(_sel(out), ICore.OnlyOwner.selector, "not the owner error");
        }
        vm.prank(who);
        (bool ok2, bytes memory out2) = address(core).call(abi.encodeCall(ICore.lockController, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
        vm.prank(who);
        (ok2, out2) = address(core).call(abi.encodeCall(ICore.lockBalanceModule, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
        vm.prank(who);
        (ok2, out2) = address(core).call(abi.encodeCall(ICore.lockAdapters, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
    }
}

contract OwnerFormerQueueTest is OwnerBase {
    // ------------------------------------------------------------------ setController

    // promise: SPEC 10 setController takes effect at once
    function test_controller_takesEffectInTheSameBlock() public {
        ScriptedController sc = _scripted();
        uint256 t = block.timestamp;
        uint256 n = block.number;
        vm.expectEmit(address(core));
        emit ICore.ControllerSet(address(sc));
        _setController(address(sc));
        assertEq(core.controller(), address(sc));
        assertEq(block.timestamp, t);
        assertEq(block.number, n);
        // the new controller is read at once: it answers that no page is ready
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    // promise: INTEGRATION ZeroAddress, OnlyOwner on setController
    function test_controller_zeroRevertsAndStrangerRevertsAndASecondSetWorks() public {
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(0x1234));
        _setController(address(0x1234));
        _setController(address(ctl));
        assertEq(core.controller(), address(ctl));
    }

    // ------------------------------------------------------------------ setBalanceModule

    // promise: INTEGRATION BadModule on setBalanceModule
    function test_module_validityRulesAreIntact() public {
        vm.startPrank(owner);
        // no code
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(0xBEEF));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(0));
        // a token without code
        MockBalanceModule m = new MockBalanceModule(address(0xBEEF), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        // a forbidden token: the coin, the credits
        m = new MockBalanceModule(address(coin), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        m = new MockBalanceModule(address(CREDITS), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        // a zero unit, a unit above uint128, a unit read that reverts
        m = new MockBalanceModule(address(spareToken), 0);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        m = new MockBalanceModule(address(spareToken), uint256(type(uint128).max) + 1);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        m = new MockBalanceModule(address(spareToken), UNIT);
        m.setRevertUnit(true);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(m));
        vm.stopPrank();
        assertEq(core.balanceModule(), address(0), "every refused set changed nothing");
        assertEq(core.balanceToken(), address(0));
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(spareMod));
    }

    // promise: SPEC 1 a replaceable balance module with a fixed token (decision 101)
    function test_module_replaceKeepsTheTokenAndTheUnitStaysWithTheModule() public {
        _setBalanceModule(address(spareMod));
        MockBalanceModule second = new MockBalanceModule(address(spareToken), 3 * UNIT);
        _setBalanceModule(address(second));
        assertEq(core.balanceModule(), address(second));
        assertEq(_moduleUnit(), 3 * UNIT, "the unit of the new module");
        // the same module again after its unit changed
        second.setUnitPerPoint(4 * UNIT);
        _setBalanceModule(address(second));
        assertEq(_moduleUnit(), 4 * UNIT, "the module reports the new unit");
        // another balance token is refused
        MockBalanceModule other = new MockBalanceModule(address(new MockBalanceToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(other));
        assertEq(core.balanceModule(), address(second));
    }

    // ------------------------------------------------------------------ addAdapter

    // promise: INTEGRATION ForbiddenTarget on addAdapter
    function test_adapter_forbiddenAddressesAreRefused() public {
        address[12] memory bad = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            core.HOOK(),
            address(PM),
            core.FACTORY(),
            core.LOCKER(),
            core.ESCROW(),
            Mainnet.PERMIT2,
            Mainnet.POSITION_MANAGER,
            Mainnet.UNIVERSAL_ROUTER
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addAdapter(bad[i]);
            assertFalse(core.allowedAdapter(bad[i]));
        }
        // the balance module and the balance token join the list once set, and a flag set earlier on the module is cleared
        address early = address(spareMod);
        _approveAdapter(early);
        assertTrue(core.allowedAdapter(early));
        _setBalanceModule(early);
        assertFalse(core.allowedAdapter(early), "the module set cleared the old flag");
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(early);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(spareToken));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.addAdapter(address(0xA11E));
    }

    // ------------------------------------------------------------------ the queue is gone

    // promise: SPEC 1 every economic number is an owner setting, no timelock
    function test_queue_noQueueNoDelayNoCancelNoFreezeNoImmutableOwner() public {
        string[8] memory sigs = [
            "queue(uint8,bytes)",
            "execute(uint8,bytes)",
            "cancel(uint8,bytes)",
            "TIMELOCK()",
            "OWNER()",
            "frozen()",
            "queuedEta(bytes32)",
            "renounceOwnership()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodeWithSignature(sigs[i], uint8(0), bytes("")));
            assertFalse(ok, sigs[i]);
        }
    }
}

contract OwnerLocksTest is OwnerBase {
    function _lockedErr(bytes32 what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICore.Locked.selector, what);
    }

    // promise: inv 13 the controller lock stays closed
    function test_lockController_blocksOnlyTheControllerSetterForever() public {
        assertFalse(core.controllerLocked());
        vm.expectEmit(address(core));
        emit ICore.ControllerLocked();
        vm.prank(owner);
        core.lockController();
        assertTrue(core.controllerLocked());
        assertFalse(core.balanceModuleLocked());
        assertFalse(core.adaptersLocked());
        address c = core.controller();
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(0x1234));
        // the order of the checks: locked first, even for the zero address
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(0));
        _warp(1000 days);
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(c);
        assertEq(core.controller(), c);
        // every other door is open, and the controller's own sale settings stay adjustable
        _openExcept(D_CONTROLLER, owner);
        vm.startPrank(owner);
        ctl.setMarkupBps(12_000);
        ctl.setStartCapBps(150_000);
        ctl.setFastDecayBpsPerHour(200);
        ctl.setSlowDecayBpsPerHour(50);
        ctl.setKneeBps(12_000);
        ctl.setRoyaltyBps(300);
        ctl.setRoyaltyRecipient(address(0xA27));
        ctl.setAnchorBps(11_000);
        vm.stopPrank();
        assertTrue(core.controllerLocked());
    }

    // promise: INTEGRATION NoBalanceModule on lockBalanceModule
    function test_lockBalanceModule_revertsWhileUnset() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.lockBalanceModule();
        assertFalse(core.balanceModuleLocked());
        // the balance side can still be entered afterwards
        _setBalanceModule(address(spareMod));
        vm.prank(owner);
        core.lockBalanceModule();
        assertTrue(core.balanceModuleLocked());
    }

    // promise: inv 13 the adapters lock stays closed
    function test_lockAdapters_blocksAddButNotRemoveAndKeepsTheOldOnes() public {
        address kept = address(0xA11E);
        _approveAdapter(kept);
        vm.expectEmit(address(core));
        emit ICore.AdaptersLocked();
        vm.prank(owner);
        core.lockAdapters();
        assertTrue(core.adaptersLocked());
        assertFalse(core.controllerLocked());
        assertFalse(core.balanceModuleLocked());
        assertTrue(core.allowedAdapter(kept), "an approved adapter stays approved");
        vm.startPrank(owner);
        vm.expectRevert(_lockedErr("adapters"));
        core.addAdapter(address(0xA11F));
        // the order of the checks: locked first, also for a forbidden address
        vm.expectRevert(_lockedErr("adapters"));
        core.addAdapter(address(core));
        core.removeAdapter(kept);
        vm.stopPrank();
        assertFalse(core.allowedAdapter(kept));
        vm.prank(owner);
        vm.expectRevert(_lockedErr("adapters"));
        core.addAdapter(kept);
        _openExcept(D_ADAPTERS, owner);
    }

    // promise: SPEC 1 the four Core locks are one way
    function test_locks_areIndependentAndOneWayAndRepeatable() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockController();
        core.lockBalanceModule();
        core.lockBalanceModule();
        core.lockAdapters();
        core.lockAdapters();
        vm.stopPrank();
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.adaptersLocked());
        // with all three locked everything else works: settings, rates, removing adapters, the handover
        for (uint256 i; i < N_DOORS; ++i) {
            if (i == D_CONTROLLER || i == D_MODULE || i == D_ADAPTERS) continue;
            (bool ok,) = _call(i, owner);
            assertTrue(ok, "an unlocked door is shut");
        }
        // and the three locked ones stay shut for the owner and for the next owner
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        for (uint256 i; i < 3; ++i) {
            (bool ok, bytes memory out) = _call(i, heir);
            assertFalse(ok);
            assertEq(_sel(out), ICore.Locked.selector);
        }
        // nothing can unlock: there is no function for it
        (bool u,) = address(core).call(abi.encodeWithSignature("unlockController()"));
        assertFalse(u);
    }

}

contract OwnerHandoverTest is OwnerBase {
    // promise: INTEGRATION OnlyPendingOwner
    function test_handover_twoStepsAndOnlyThePendingOwnerAccepts() public {
        assertEq(core.owner(), owner);
        assertEq(core.pendingOwner(), address(0));
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, heir);
        vm.prank(owner);
        core.transferOwnership(heir);
        assertEq(core.pendingOwner(), heir);
        assertEq(core.owner(), owner, "the owner does not move on the first step");
        // the owner keeps every power and the heir has none until it accepts
        _allShutFor(heir);
        // nobody else can accept: a stranger, the old owner, the deployer
        address[3] memory no = [stranger, owner, deployer];
        for (uint256 i; i < no.length; ++i) {
            vm.prank(no[i]);
            vm.expectRevert(ICore.OnlyPendingOwner.selector);
            core.acceptOwnership();
        }
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferred(owner, heir);
        vm.prank(heir);
        core.acceptOwnership();
        assertEq(core.owner(), heir);
        assertEq(core.pendingOwner(), address(0), "pending is cleared");
        // a second accept finds nothing pending
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    // promise: inv 13 former owners hold no power
    function test_handover_theOldOwnerLosesEveryPowerAndTheNewOneHasEvery() public {
        _enterPhase2();
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        _allShutFor(owner);
        // the controller's sale settings follow the live owner
        vm.startPrank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setMarkupBps(12_000);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setStartCapBps(150_000);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setFastDecayBpsPerHour(200);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setSlowDecayBpsPerHour(50);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setKneeBps(12_000);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setRoyaltyBps(300);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setRoyaltyRecipient(address(0xA27));
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setAnchorBps(11_000);
        vm.stopPrank();
        // the new owner has every door
        _openExcept(N_DOORS, heir);
        vm.startPrank(heir);
        ctl.setMarkupBps(12_000);
        ctl.setStartCapBps(150_000);
        ctl.setFastDecayBpsPerHour(200);
        ctl.setSlowDecayBpsPerHour(50);
        ctl.setKneeBps(12_000);
        ctl.setRoyaltyBps(300);
        ctl.setRoyaltyRecipient(address(0xA27));
        ctl.setAnchorBps(11_000);
        core.lockController();
        core.lockBalanceModule();
        core.lockAdapters();
        vm.stopPrank();
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.adaptersLocked());
    }

    // promise: SPEC 10 the two step handover can be cleared or replaced
    function test_handover_zeroClearsPendingAndANewNameReplacesIt() public {
        vm.startPrank(owner);
        core.transferOwnership(heir);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, address(0));
        core.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(core.pendingOwner(), address(0));
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        // naming a second heir replaces the first
        vm.startPrank(owner);
        core.transferOwnership(heir);
        core.transferOwnership(address(0xEE12));
        vm.stopPrank();
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(address(0xEE12));
        core.acceptOwnership();
        assertEq(core.owner(), address(0xEE12));
    }

    // promise: SPEC 10 the owner cannot be zeroed
    function test_handover_ownerCannotBeZeroedAndThereIsNoRenounce() public {
        vm.prank(owner);
        core.transferOwnership(address(0));
        assertEq(core.owner(), owner);
        (bool ok,) = address(core).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok);
        (ok,) = address(core).call(abi.encodeWithSignature("renounce()"));
        assertFalse(ok);
        assertEq(core.owner(), owner);
    }

    // promise: INTEGRATION OnlyPendingOwner
    /// while nothing is pending the pending owner is the zero address, and a call from it must not pass
    /// `acceptOwnership` (review S-9, fixed): the owner stays
    function test_handover_zeroAddressAcceptWhileNothingPendingReverts() public {
        assertEq(core.pendingOwner(), address(0));
        vm.prank(address(0));
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner);
    }

    // promise: SPEC 1 assets leave the Core only through migrate, rescueCoin and rescueNft (inv 8)
    /// the assets: no owner call, of any owner, moves eth, credits, statements or the coin out of the core
    function test_handover_noOwnerDoorMovesAnAsset() public {
        uint256 sid = _composeOnce().sid;
        _enterPhase2();
        _fundPot(1 ether);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        uint256 bal = address(core).balance;
        uint256 credits = CREDITS.balanceOf(address(core));
        uint256 pot = core.ethPot();
        uint256 heirEth = heir.balance;
        _openExcept(N_DOORS, heir);
        vm.startPrank(heir);
        core.lockController();
        core.lockAdapters();
        vm.stopPrank();
        assertEq(address(core).balance, bal);
        assertEq(CREDITS.balanceOf(address(core)), credits);
        assertEq(core.ethPot(), pot);
        assertEq(heir.balance, heirEth);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(STATEMENTS.balanceOf(heir), 0);
        assertEq(coin.balanceOf(heir), 0);
    }
}
