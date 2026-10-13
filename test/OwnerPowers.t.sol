// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
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
    uint256 internal constant D_TARGETS = 2;
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
        if (i == D_TARGETS) {
            return abi.encodeCall(ICore.addTarget, (address(uint160(0xA0000 + block.number + gasleft() % 97))));
        }
        if (i == D_SETTINGS) return abi.encodeCall(ICore.setSettings, (core.settings()));
        if (i == D_RATE) return abi.encodeCall(ICore.setRate, (core.rateAtCheckpoint()));
        if (i == D_REMOVE) return abi.encodeCall(ICore.removeTarget, (address(0xDEAD1)));
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
        (ok2, out2) = address(core).call(abi.encodeCall(ICore.lockTargets, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
    }
}

contract OwnerFormerQueueTest is OwnerBase {
    // ------------------------------------------------------------------ setController

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

    /// compose runs under the new controller in the same block it was set
    function test_controller_composeUsesTheNewControllerAtOnce() public {
        _fillEthPile(80);
        ScriptedController sc = _scripted();
        uint256[] memory page = core.pilePage(0, 80);
        uint256[80] memory p;
        for (uint256 i; i < 80; ++i) {
            p[i] = page[i];
        }
        sc.setPage(true, p, 0);
        _setController(address(sc));
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        assertTrue(_isHeld(sid), "composed from the page of the new controller");
    }

    // ------------------------------------------------------------------ setBalanceModule

    function test_module_firstSetTakesEffectInTheSameBlock() public {
        vm.expectEmit(address(core));
        emit ICore.BalanceModuleSet(address(spareMod), address(spareToken), UNIT);
        _setBalanceModule(address(spareMod));
        assertEq(core.balanceModule(), address(spareMod));
        assertEq(core.balanceToken(), address(spareToken));
        assertEq(core.unitPerPoint(), UNIT);
        // the balance side is live in the same block once the bid is turned on
        _setBalanceMode(2);
        _setBalancePoolFor(address(spareToken));
        uint256[] memory ids = _credits(seller, 1);
        spareToken.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

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
        assertEq(core.unitPerPoint(), 0);
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(spareMod));
    }

    function test_module_replaceKeepsTheTokenAndReadsTheUnitAgain() public {
        _setBalanceModule(address(spareMod));
        MockBalanceModule second = new MockBalanceModule(address(spareToken), 3 * UNIT);
        _setBalanceModule(address(second));
        assertEq(core.balanceModule(), address(second));
        assertEq(core.unitPerPoint(), 3 * UNIT, "the unit of the new module");
        // the same module again after its unit changed
        second.setUnitPerPoint(4 * UNIT);
        _setBalanceModule(address(second));
        assertEq(core.unitPerPoint(), 4 * UNIT, "the unit is read again");
        // another balance token is refused
        MockBalanceModule other = new MockBalanceModule(address(new MockBalanceToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(other));
        assertEq(core.balanceModule(), address(second));
        assertEq(core.unitPerPoint(), 4 * UNIT);
    }

    // ------------------------------------------------------------------ addTarget

    function test_target_addTakesEffectInTheSameBlock() public {
        address t = address(0xA11E);
        uint256 id = 35377;
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(0, "", id, t);
        vm.expectEmit(address(core));
        emit ICore.TargetAdded(t);
        _allow(t);
        assertTrue(core.allowedTarget(t));
        // the same call now passes the allow list and fails further in
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(0, "", id, t);
        vm.expectEmit(address(core));
        emit ICore.TargetRemoved(t);
        vm.prank(owner);
        core.removeTarget(t);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(0, "", id, t);
    }

    function test_target_forbiddenAddressesAreRefused() public {
        address[13] memory bad = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            core.HOOK(),
            core.FEE_SOURCE(),
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
            core.addTarget(bad[i]);
            assertFalse(core.allowedTarget(bad[i]));
        }
        // the balance module and the balance token join the list once set, and a flag set earlier on the module is cleared
        address early = address(spareMod);
        _allow(early);
        assertTrue(core.allowedTarget(early));
        _setBalanceModule(early);
        assertFalse(core.allowedTarget(early), "the module set cleared the old flag");
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(early);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(spareToken));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.addTarget(address(0xA11E));
    }

    function test_target_removeIsImmediateAndHarmlessForUnknown() public {
        _allow(address(0xA11E));
        vm.startPrank(owner);
        core.removeTarget(address(0xA11E));
        core.removeTarget(address(0xA11E));
        core.removeTarget(address(0x1));
        vm.stopPrank();
        assertFalse(core.allowedTarget(address(0xA11E)));
        // the launch targets are removable too
        assertTrue(core.allowedTarget(Mainnet.SEAPORT));
        vm.prank(owner);
        core.removeTarget(Mainnet.SEAPORT);
        assertFalse(core.allowedTarget(Mainnet.SEAPORT));
    }

    // ------------------------------------------------------------------ the queue is gone

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

    function test_lockController_blocksOnlyTheControllerSetterForever() public {
        assertFalse(core.controllerLocked());
        vm.expectEmit(address(core));
        emit ICore.ControllerLocked();
        vm.prank(owner);
        core.lockController();
        assertTrue(core.controllerLocked());
        assertFalse(core.balanceModuleLocked());
        assertFalse(core.targetsLocked());
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
        ctl.setFloorBps(8_000);
        ctl.setAnchorBps(11_000);
        vm.stopPrank();
        assertTrue(core.controllerLocked());
    }

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

    function test_lockBalanceModule_blocksOnlyTheModuleSetterAndTheUnitStaysFixed() public {
        _enterPhase2();
        vm.expectEmit(address(core));
        emit ICore.BalanceModuleLocked();
        vm.prank(owner);
        core.lockBalanceModule();
        assertTrue(core.balanceModuleLocked());
        assertFalse(core.controllerLocked());
        assertFalse(core.targetsLocked());
        address m = core.balanceModule();
        mod.setUnitPerPoint(9 * UNIT);
        vm.startPrank(owner);
        vm.expectRevert(_lockedErr("balanceModule"));
        core.setBalanceModule(address(spareMod));
        // the same module again, which is how the unit is updated: also locked
        vm.expectRevert(_lockedErr("balanceModule"));
        core.setBalanceModule(m);
        // a module that would be refused anyway is refused as locked first
        vm.expectRevert(_lockedErr("balanceModule"));
        core.setBalanceModule(address(0xBEEF));
        vm.stopPrank();
        assertEq(core.balanceModule(), m);
        assertEq(core.unitPerPoint(), UNIT, "the unit cannot be updated any more");
        _openExcept(D_MODULE, owner);
    }

    function test_lockTargets_blocksAddButNotRemoveAndKeepsTheOldOnes() public {
        address kept = address(0xA11E);
        _allow(kept);
        vm.expectEmit(address(core));
        emit ICore.TargetsLocked();
        vm.prank(owner);
        core.lockTargets();
        assertTrue(core.targetsLocked());
        assertFalse(core.controllerLocked());
        assertFalse(core.balanceModuleLocked());
        assertTrue(core.allowedTarget(kept), "an allowed target stays allowed");
        vm.startPrank(owner);
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(address(0xA11F));
        // the order of the checks: locked first, also for a forbidden address
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(address(core));
        core.removeTarget(kept);
        vm.stopPrank();
        assertFalse(core.allowedTarget(kept));
        vm.prank(owner);
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(kept);
        _openExcept(D_TARGETS, owner);
    }

    function test_locks_areIndependentAndOneWayAndRepeatable() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockController();
        core.lockBalanceModule();
        core.lockBalanceModule();
        core.lockTargets();
        core.lockTargets();
        vm.stopPrank();
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.targetsLocked());
        // with all three locked everything else works: settings, rates, removing targets, the handover
        for (uint256 i; i < N_DOORS; ++i) {
            if (i == D_CONTROLLER || i == D_MODULE || i == D_TARGETS) continue;
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

    function test_locks_onlyTheOwnerLocks() public {
        _enterPhase2();
        _allShutFor(stranger);
        _allShutFor(deployer);
        _allShutFor(address(ctl));
        assertFalse(core.controllerLocked() || core.balanceModuleLocked() || core.targetsLocked());
    }

    /// a locked controller cannot be swapped, so a controller that goes bad stays: compose reverts, the doors that do
    /// not read the controller stay open
    function test_locks_aLockedControllerStaysEvenWhenItBreaks() public {
        ScriptedController sc = _scripted();
        _setController(address(sc));
        vm.prank(owner);
        core.lockController();
        sc.setRevertPage(true);
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(ctl));
        assertEq(core.controller(), address(sc));
    }
}

contract OwnerHandoverTest is OwnerBase {
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
        ctl.setFloorBps(8_000);
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
        ctl.setFloorBps(8_000);
        ctl.setAnchorBps(11_000);
        core.lockController();
        core.lockBalanceModule();
        core.lockTargets();
        vm.stopPrank();
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.targetsLocked());
    }

    /// the new owner can hand over again, and the chain of owners never has two at once
    function test_handover_aChainOfOwners() public {
        address[3] memory chain = [address(0xAA01), address(0xAA02), address(0xAA03)];
        address cur = owner;
        for (uint256 i; i < 3; ++i) {
            vm.prank(cur);
            core.transferOwnership(chain[i]);
            vm.prank(chain[i]);
            core.acceptOwnership();
            assertEq(core.owner(), chain[i]);
            _allShutFor(cur);
            cur = chain[i];
        }
        _openExcept(N_DOORS, cur);
    }

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

    function test_handover_theOldOwnerCannotCancelAfterTheAcceptAndAStrangerCannotStart() public {
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(stranger);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(owner);
        assertEq(core.owner(), heir);
        assertEq(core.pendingOwner(), address(0));
    }

    /// a handover to a contract and to the same owner both work
    function test_handover_toAContractAndToItself() public {
        address c = address(ctl);
        vm.prank(owner);
        core.transferOwnership(c);
        vm.prank(c);
        core.acceptOwnership();
        assertEq(core.owner(), c);
        vm.prank(c);
        core.transferOwnership(c);
        vm.prank(c);
        core.acceptOwnership();
        assertEq(core.owner(), c);
        assertEq(core.pendingOwner(), address(0));
    }

    /// while nothing is pending the pending owner is the zero address, and a call from it must not pass
    /// `acceptOwnership` (review S-9, fixed): the owner stays
    function test_handover_zeroAddressAcceptWhileNothingPendingReverts() public {
        assertEq(core.pendingOwner(), address(0));
        vm.prank(address(0));
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner);
    }

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
        core.lockTargets();
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
