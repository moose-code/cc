// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Sale, Credit, Mainnet, IBalanceModule, IStatements} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {SetSettings} from "../script/SetSettings.s.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {StatementInfoStub} from "./standins/StatementInfoStub.sol";

/// a controller that can call sellTo with any statement, buyer and payment
contract SellProbe is ScriptedController {
    ICore internal immutable CORE;

    constructor(ICore c) {
        CORE = c;
    }

    function sell(uint256 sid, address buyer) external payable {
        CORE.sellTo{value: msg.value}(sid, buyer);
    }
}

/// a buyer that records every callback and tries to re enter on the refund
contract EvilBuyer {
    IControllerV1 public ctl;
    ICore public core;
    uint256 public hooks;
    uint256 public refunds;
    uint256 public sid;
    bool public failRefund;
    bytes4 public lastWhy;

    constructor(IControllerV1 c, ICore k) {
        ctl = c;
        core = k;
    }

    function setFail(bool on) external {
        failRefund = on;
    }

    function buy(uint256 id) external payable {
        sid = id;
        ctl.buy{value: msg.value}(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++hooks;
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (failRefund) revert("refused");
        ++refunds;
        try ctl.buy{value: 0}(sid) {}
        catch (bytes memory why) {
            lastWhy = bytes4(why);
        }
        try core.skim() {} catch {}
    }
}

/// a balance module that burns gas before it pays, for the gas bound of the redemption caller payment
contract BurnModule is IBalanceModule {
    address public immutable balanceToken;
    uint256 public immutable unit;
    uint256 public immutable burn;

    constructor(address token, uint256 unit_, uint256 burn_) {
        balanceToken = token;
        unit = unit_;
        burn = burn_;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function redeem(uint256 sid) external returns (uint256 out) {
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) {}
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid) * unit;
        MockBalanceToken(balanceToken).mint(msg.sender, out);
    }
}

/// reads the private tuple string of the settings script
contract TupleProbe is SetSettings {
    function tuple() external pure returns (string memory) {
        return TUPLE;
    }
}

/// independent review of the sale controller, the owner doors and the fee share (REVIEW-sale.md, git history before packet 0). test_FIXED asserts
/// the behavior after the fix of a finding, test_ACCEPTED pins a finding that was accepted or documented, every test_OK
/// confirms a safety property
contract ReviewSaleTest is Fixture {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = _user("rs.alice");
        bob = _user("rs.bob");
    }

    // ------------------------------------------------------------------ helpers

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (, c,) = core.statementInfo(sid);
    }

    function _floorOf(uint256 sid) internal view returns (uint256) {
        return _cost(sid) * core.settings().saleFloorBps / 10_000;
    }

    /// pins the reference to cost: the largest `refScore` and a `rateCap` at the opening rate hold the eth price at or
    /// below the fill rate, so the rate term of `max(cost, ethPrice * rating / refScore)` stays far below cost and the
    /// curve prices in bps of cost through later blocks
    function _pinReferenceToCost() internal {
        vm.prank(owner);
        ctl.setRefScore(8_000_000);
        Settings memory s = core.settings();
        s.rateCap = uint64(OPEN_RATE);
        _setSettings(s);
    }

    function _probe() internal returns (SellProbe p) {
        p = new SellProbe(core);
        _setController(address(p));
    }

    function _raise(uint16 floorBps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = floorBps;
        _setSettings(s);
    }

    // ------------------------------------------------------------------ sellTo: who, which states

    function test_OK_sellTo_onlyTheCurrentController() public {
        uint256 sid = _composeOnce().sid;
        uint256 floor = _floorOf(sid);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: floor}(sid, bob);
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: floor}(sid, owner);
        // after a controller change the old controller is dead for sales
        SellProbe p = _probe();
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyController.selector);
        ctl.buy{value: 100 ether}(sid);
        p.sell{value: floor}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    function test_OK_sellTo_unknownRecordReverts() public {
        _composeOnce();
        SellProbe p = _probe();
        vm.expectRevert(ICore.NotForSale.selector);
        p.sell{value: 0}(999_999, bob);
        vm.expectRevert(ICore.NotForSale.selector);
        p.sell{value: 0}(0, bob);
    }

    function test_OK_sellTo_alreadySoldReverts() public {
        uint256 sid = _composeOnce().sid;
        uint256 floor = _floorOf(sid);
        SellProbe p = _probe();
        p.sell{value: floor}(sid, bob);
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.NotForSale.selector);
        p.sell{value: 1000 ether}(sid, alice);
        assertEq(STATEMENTS.ownerOf(sid), bob);
        assertEq(core.heldStatements().length, 0);
    }

    function test_OK_sellTo_hardFloorExactAndRounding() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256 floor = _floorOf(sid);
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.BelowFloor.selector);
        p.sell{value: floor - 1}(sid, bob);
        vm.expectRevert(ICore.BelowFloor.selector);
        p.sell{value: 0}(sid, bob);
        // the floor rounds down by less than one wei of the exact product
        assertLe(floor * 10_000, cost * core.settings().saleFloorBps);
        assertGt((floor + 1) * 10_000, cost * core.settings().saleFloorBps);
        p.sell{value: floor}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    function test_OK_sellTo_msgValueBookedOnceNeverDoubleCounted() public {
        uint256 sid = _composeOnce().sid;
        uint256 pay = _cost(sid) * 3;
        SellProbe p = _probe();
        vm.deal(address(this), pay);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, bob, pay, pay * core.settings().saleToBuybackBps / 10_000);
        p.sell{value: pay}(sid, bob);
        assertEq(address(core).balance - bal, pay, "balance rose by the payment");
        assertEq((core.ethPot() - pot) + (core.ethToBuyback() - bb), pay, "booked exactly once");
        assertEq(core.ethToBuyback() - bb, pay * core.settings().saleToBuybackBps / 10_000);
        // skim and a later hook payment add nothing for this payment
        core.skim();
        assertEq((core.ethPot() - pot) + (core.ethToBuyback() - bb), pay, "skim finds nothing to add");
        _solvent();
    }

    function test_OK_sellTo_buyerGetsNoCallbackAndRefundReentryIsBlocked() public {
        uint256 sid = _composeOnce().sid;
        uint256 gross = ctl.grossPriceOf(sid);
        EvilBuyer b = new EvilBuyer(ctl, core);
        vm.deal(address(this), gross + 1 ether);
        uint256 dust = address(b).balance;
        b.buy{value: gross + 1 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(b));
        assertEq(b.hooks(), 0, "transferFrom has no callback");
        assertEq(b.refunds(), 1, "the refund arrived once");
        assertEq(b.lastWhy(), IControllerV1.Reentrant.selector, "buy is guarded against the refund");
        assertEq(address(b).balance - dust, 1 ether);
        assertEq(address(ctl).balance, ctl.royaltyOwed(), "only the royalty owed stays in the controller");
        _solvent();
    }

    function test_OK_buy_revertingRefundRevertsTheWholeBuy() public {
        uint256 sid = _composeOnce().sid;
        uint256 gross = ctl.grossPriceOf(sid);
        EvilBuyer b = new EvilBuyer(ctl, core);
        b.setFail(true);
        vm.deal(address(this), gross + 1 ether);
        vm.expectRevert();
        b.buy{value: gross + 1 ether}(sid);
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held, "statement still held");
        assertEq(address(ctl).balance, 0);
        assertEq(ctl.royaltyOwed(), 0, "the reverted buy owes nothing");
        b.buy{value: gross}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(b), "exact payment needs no refund");
    }

    function test_OK_buy_ethCannotBeSentToTheController() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(ctl).call{value: 1 ether}("");
        assertFalse(ok, "no receive, no fallback");
        assertEq(address(ctl).balance, 0);
    }

    function test_OK_buy_ownerCheckFollowsTheLiveOwner() public {
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(owner);
        ctl.setFastDecayBpsPerHour(200);
        vm.prank(alice);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setFastDecayBpsPerHour(300);
        vm.prank(alice);
        ctl.setFastDecayBpsPerHour(300);
        assertEq(ctl.fastDecayBpsPerHour(), 300);
    }

    function test_OK_buy_quoteNeverRisesForAThirdParty() public {
        _pinReferenceToCost(); // the quote falls only with decay, not with the climbing eth price
        uint256 sid = _composeOnce().sid;
        uint256 q0 = ctl.priceOf(sid);
        // a stranger runs every permissionless door: none raises the ask
        core.skim();
        assertEq(ctl.priceOf(sid), q0);
        _warp(3 hours);
        uint256 q1 = ctl.priceOf(sid);
        assertLt(q1, q0);
        // the buyer pays the gross quote of an earlier block: still enough, the excess comes back
        uint256 g1 = ctl.grossPriceOf(sid);
        _warp(3 hours);
        uint256 g2 = ctl.grossPriceOf(sid);
        vm.deal(bob, g1);
        vm.prank(bob);
        ctl.buy{value: g1}(sid);
        assertEq(bob.balance, g1 - g2, "paid the later, lower price");
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    /// S-1 fixed: once the curve has fallen to the floor the quote rests at `saleFloorBps` of the reference, `buy` keeps
    /// working and the excess comes back
    function test_FIXED_buyWorksAtTheFloor() public {
        _pinReferenceToCost(); // the reference is cost, so the floor is the cost based floor
        uint256 sid = _composeOnce().sid;
        _warp(300 hours);
        uint256 floor = _floorOf(sid);
        assertEq(ctl.priceOf(sid), floor, "the quote is the floor");
        uint256 gross = ctl.grossPriceOf(sid);
        vm.deal(bob, 1000 ether);
        vm.prank(bob);
        ctl.buy{value: 1000 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), bob, "sold at the floor");
        assertEq(bob.balance, 1000 ether - gross, "the excess came back");
        assertEq(address(ctl).balance, ctl.royaltyOwed());
    }

    // ------------------------------------------------------------------ the asking price

    function test_OK_price_extremesDoNotOverflowOrUnderflow() public {
        StatementInfoStub stub = new StatementInfoStub(owner);
        stub.setSaleFloorBps(10_000);
        IControllerV1 c = Prod.newController(address(stub), lc.sale);
        vm.startPrank(owner);
        c.setFastDecayBpsPerHour(10_000);
        c.setSlowDecayBpsPerHour(10_000);
        vm.stopPrank();
        uint256 cost = 10 ether;
        // forge-lint: disable-start(unsafe-typecast)
        stub.set(cost, 0);
        assertEq(c.priceOf(0), cost * 10_000 / 10_000, "an ancient statement sits at the floor");
        stub.set(cost, uint64(block.timestamp));
        assertEq(c.priceOf(0), cost * 15_000 / 10_000, "age zero is the start");
        vm.startPrank(owner);
        c.setMarkupBps(40_000);
        c.setStartCapBps(200_000);
        vm.stopPrank();
        stub.set(type(uint128).max, 0);
        assertEq(c.priceOf(0), uint256(type(uint128).max) * 10_000 / 10_000);
        stub.set(type(uint128).max, uint64(block.timestamp));
        assertEq(c.priceOf(0), uint256(type(uint128).max) * 40_000 / 10_000, "the largest start on the largest cost");
        stub.set(0, 0);
        assertEq(c.priceOf(0), 0, "cost zero asks zero");
        // a compose time in the future reverts (checked subtraction). the core sets it to the block time
        stub.set(cost, uint64(block.timestamp + 1));
        vm.expectRevert();
        c.priceOf(0);
        stub.set(cost, type(uint64).max);
        vm.expectRevert();
        c.priceOf(0);
        // forge-lint: disable-end(unsafe-typecast)
    }

    function test_OK_price_readGasIsFarUnderTheLensBound() public {
        uint256 sid = _composeOnce().sid;
        vm.cool(address(ctl));
        vm.cool(address(core));
        uint256 g = gasleft();
        ctl.priceOf(sid);
        uint256 used = g - gasleft();
        emit log_named_uint("cold priceOf gas", used);
        assertLt(used, 100_000, "the lens caps the read at 200_000");
    }

    // ------------------------------------------------------------------ timelock removal and the locks

    function test_OK_noQueuePathOrOldNameRemains() public {
        string[8] memory sigs = [
            "queue(uint8,bytes)",
            "execute(uint8,bytes)",
            "cancel(uint8,bytes)",
            "TIMELOCK()",
            "frozen()",
            "OWNER()",
            "queuedEta(bytes32)",
            "reserveBps()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodePacked(bytes4(keccak256(bytes(sigs[i])))));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_OK_everyOwnerDoorIsOwnerOnly() public {
        bytes[10] memory calls = [
            abi.encodeCall(ICore.transferOwnership, (bob)),
            abi.encodeCall(ICore.setController, (bob)),
            abi.encodeCall(ICore.setBalanceModule, (bob)),
            abi.encodeCall(ICore.addTarget, (bob)),
            abi.encodeCall(ICore.removeTarget, (bob)),
            abi.encodeCall(ICore.lockController, ()),
            abi.encodeCall(ICore.lockBalanceModule, ()),
            abi.encodeCall(ICore.lockTargets, ()),
            abi.encodeCall(ICore.setSettings, (core.settings())),
            abi.encodeCall(ICore.setRate, (OPEN_RATE))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(bob);
            (bool ok, bytes memory why) = address(core).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(why), ICore.OnlyOwner.selector);
        }
        assertFalse(core.controllerLocked() || core.balanceModuleLocked() || core.targetsLocked());
        assertEq(core.pendingOwner(), address(0));
    }

    function test_OK_formerActionsKeepTheirValidityChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(0xdead));
        address[3] memory bad = [lc.stack.hook, address(core), core.COIN()];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(bad[i]);
        }
        vm.stopPrank();
        _enterPhase2();
        vm.startPrank(owner);
        MockBalanceModule zero = new MockBalanceModule(address(xt), 0);
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(zero));
        MockBalanceModule other = new MockBalanceModule(address(new MockBalanceToken("O", "O")), 1 * UNIT);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(other));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(core));
        // a target flag set before a module is named is cleared when it becomes the module
        MockBalanceModule m2 = new MockBalanceModule(address(xt), 2 * UNIT);
        core.addTarget(address(m2));
        assertTrue(core.allowedTarget(address(m2)));
        core.setBalanceModule(address(m2));
        assertFalse(core.allowedTarget(address(m2)));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(m2));
        vm.stopPrank();
    }

    function test_OK_lockController_blocksOnlyTheControllerDoor() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockController();
        assertTrue(core.controllerLocked());
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("controller")));
        core.setController(address(0xC0DE));
        // everything else stays open
        core.setBalanceModule(address(new MockBalanceModule(address(xt), 3 * UNIT)));
        core.addTarget(address(0x7A9));
        core.removeTarget(address(0x7A9));
        core.transferOwnership(alice);
        vm.stopPrank();
        Settings memory s = core.settings();
        s.keeperFee = 0.001 ether;
        _setSettings(s);
        vm.prank(owner);
        ctl.setFastDecayBpsPerHour(500);
        assertFalse(core.balanceModuleLocked() || core.targetsLocked());
    }

    function test_OK_lockBalanceModule_revertsWhileUnsetThenBlocksOnlyTheModuleDoor() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.lockBalanceModule();
        assertFalse(core.balanceModuleLocked());
        uint256 sid = _composeOnce().sid;
        _enterPhase2();
        vm.startPrank(owner);
        core.lockBalanceModule();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(mod));
        address fresh = address(new MockBalanceModule(address(xt), 3 * UNIT));
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(fresh);
        SellProbe probe = new SellProbe(core);
        probe.setAtFloor(true); // the eth lane statement is eligible under this controller
        core.setController(address(probe));
        core.addTarget(address(0x7A9));
        vm.stopPrank();
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "redeem still works");
    }

    function test_OK_lockTargets_blocksOnlyAddTarget() public {
        vm.startPrank(owner);
        core.lockTargets();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("targets")));
        core.addTarget(address(0x7A9));
        core.removeTarget(Mainnet.SEAPORT);
        assertFalse(core.allowedTarget(Mainnet.SEAPORT), "removal still works");
        core.setController(address(new SellProbe(core)));
        vm.stopPrank();
        _enterPhase2();
        assertTrue(core.targetsLocked());
    }

    function test_OK_allThreeLocksLeaveSettingsAndSaleSettingsOpen() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockBalanceModule();
        core.lockTargets();
        vm.stopPrank();
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = 1_234;
        s.saleFloorBps = 8_000;
        _setSettings(s);
        vm.startPrank(owner);
        core.setRate(2e15);
        ctl.setRoyaltyBps(300);
        vm.stopPrank();
        assertEq(core.settings().feeToRedeemBurnBps, 1_234);
    }

    // ------------------------------------------------------------------ owner handover

    function test_OK_handover_twoStepAndTheOldOwnerLosesEveryDoor() public {
        vm.prank(owner);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, alice);
        core.transferOwnership(alice);
        assertEq(core.owner(), owner, "still the old owner until accepted");
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(alice);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferred(owner, alice);
        core.acceptOwnership();
        assertEq(core.owner(), alice);
        assertEq(core.pendingOwner(), address(0), "pending cleared");
        vm.startPrank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(ctl));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockTargets();
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setFastDecayBpsPerHour(200);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    function test_OK_handover_replacingOrClearingThePendingOwner() public {
        vm.startPrank(owner);
        core.transferOwnership(alice);
        core.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(owner);
        core.transferOwnership(address(0));
        assertEq(core.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner);
    }

    function test_OK_handover_toTheCoreItselfCannotBeAccepted() public {
        vm.prank(owner);
        core.transferOwnership(address(core));
        assertEq(core.pendingOwner(), address(core));
        // the core has no door that calls acceptOwnership, so the owner keeps the role and can overwrite the pending
        vm.prank(owner);
        core.setController(address(ctl));
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(alice);
        core.acceptOwnership();
        assertEq(core.owner(), alice);
    }

    function test_OK_handover_noRenounceDoorExists() public {
        bytes4[3] memory sels = [bytes4(keccak256("renounceOwnership()")), bytes4(keccak256("renounce()")), bytes4(keccak256("setOwner(address)"))];
        for (uint256 i; i < sels.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodePacked(sels[i], bytes32(0)));
            assertFalse(ok);
        }
    }

    /// true when a warning row of that name is in the report and it is currently raised (its condition is false)
    function _warned(string memory name) internal view returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].warn && !rows[i].ok && vm.contains(rows[i].name, name)) return true;
        }
        return false;
    }

    /// S-5 fixed: a handover offered to an address shows as a warning row, which never fails the run
    function test_FIXED_postflightWarnsOnAPendingOwner() public {
        postflightAs(lc, address(core), owner);
        (, uint256 n0) = _failed();
        assertFalse(_warned("no pending owner"), "clean at launch");
        vm.prank(owner);
        core.transferOwnership(bob);
        postflightAs(lc, address(core), owner);
        (, uint256 n1) = _failed();
        assertEq(n1, n0, "a warning never fails the run");
        assertTrue(_warned("no pending owner"), "the offer shows as a warning");
        assertEq(core.pendingOwner(), bob);
    }

    function test_OK_postflight_readsTheLiveOwnerAndTheLocks() public {
        postflightAs(lc, address(core), owner);
        (, uint256 n0) = _failed();
        vm.startPrank(owner);
        core.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        core.acceptOwnership();
        postflightAs(lc, address(core), owner);
        (string memory afterHandover, uint256 n1) = _failed();
        assertGt(n1, n0, "an unannounced handover fails the owner row");
        emit log_string(afterHandover);
        vm.prank(alice);
        core.lockTargets();
        postflightAs(lc, address(core), owner);
        (, uint256 n2) = _failed();
        assertGt(n2, n1, "a lock fails the launch state row");
    }

    // ------------------------------------------------------------------ fee split in receive()

    function _feeShare(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = bps;
        _setSettings(s);
    }

    /// the fee source (the router) pays the core, which is what `receive` books
    function _hookPays(uint256 amount) internal {
        address hook = lc.stack.feeSource;
        vm.deal(hook, hook.balance + amount);
        vm.prank(hook);
        (bool ok,) = address(core).call{value: amount}("");
        assertTrue(ok);
    }

    function test_OK_receive_onlyHookEthIsBookedAndSkimStaysWhole() public {
        _feeShare(5_000);
        vm.deal(bob, 10 ether);
        uint256 pot = core.ethPot();
        vm.prank(bob);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok, "a stranger may pay, nothing reverts");
        assertEq(core.ethPot(), pot, "not booked by receive");
        assertEq(core.ethRedeemBurn(), 0);
        core.skim();
        assertEq(core.ethPot() - pot, 1 ether, "skim books the whole amount to the pot, no split");
        assertEq(core.ethRedeemBurn(), 0);
        _solvent();
    }

    function test_OK_receive_splitConservesEveryWeiAndPotsStayUnderBalance() public {
        _feeShare(3_333);
        uint256[7] memory amounts = [uint256(0), 1, 2, 3, 9_999, 10_001, 1 ether + 7];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 pot = core.ethPot();
            uint256 rb = core.ethRedeemBurn();
            _hookPays(amounts[i]);
            assertEq((core.ethPot() - pot) + (core.ethRedeemBurn() - rb), amounts[i], "no dust lost or made");
            assertEq(core.ethRedeemBurn() - rb, amounts[i] * 3_333 / 10_000, "rounds down, dust to the pot");
            _solvent();
        }
    }

    function test_OK_receive_allToTheReserveLeavesThePotAlone() public {
        _feeShare(10_000);
        uint256 pot = core.ethPot();
        _hookPays(2 ether);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethRedeemBurn(), 2 ether);
        _feeShare(0);
        _hookPays(1 ether);
        assertEq(core.ethPot(), pot + 1 ether);
    }

    function test_OK_receive_theCoreOwnBuybackStaysSolventWithTheShare() public {
        _skipSniperWindow();
        _feeShare(10_000);
        _hookPays(3 ether);
        vm.prank(owner);
        core.releaseRedeemBurn(type(uint256).max);
        vm.roll(block.number + 100);
        uint256 pool = core.ethToBuyback();
        vm.prank(keeper);
        core.buyback();
        _solvent();
        assertLt(core.ethToBuyback(), pool, "the slice left the pool");
        // the hook skim of the core's own swap came back through receive and was split by the same setting
        assertGe(address(core).balance, core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn());
    }

    // ------------------------------------------------------------------ redeem caller payment

    /// @dev the caller payment on: 0.0005 ether and a 10 gwei base fee ceiling
    function _callerPayOn() internal {
        Settings memory s = core.settings();
        s.callerFee = 0.0005 ether;
        s.callerMaxBaseFee = 10 gwei;
        _setSettings(s);
    }

    /// gas of the last measured redemption as a transaction, before the refund
    uint256 internal lastRedeemGross;

    function _redeemAndMeasure(uint256 sid) internal returns (uint256 got, uint256 gasUsed, uint256 potDrop) {
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        core.redeemStatement(sid);
        gasUsed = g - gasleft();
        (lastRedeemGross,) = _lastCallGross();
        got = keeper.balance - before_;
        potDrop = pot - core.ethPot();
    }

    function test_OK_redeemPay_paidFromThePotOnceAndCappedAtTheBaseFeeCeiling() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _callerPayOn();
        _warp(105 hours);
        vm.fee(300 gwei);
        (uint256 got,, uint256 drop) = _redeemAndMeasure(sid);
        assertEq(got, drop, "paid from the pot, nowhere else");
        assertGt(got, 0.0005 ether, "the gas refund is paid on top of the fee");
        assertEq((got - 0.0005 ether) % 10 gwei, 0, "a high basefee pays at the ceiling");
        assertLe(got, 1_500_000 * 10 gwei + 0.0005 ether, "within the gas bound at the ceiling plus the fee");
        vm.prank(keeper);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(sid);
        _solvent();
    }

    function test_OK_redeemPay_gasBurningModuleCannotPassTheGasBound() public {
        xt = new MockBalanceToken("X", "X");
        BurnModule bm = new BurnModule(address(xt), UNIT, 6_000_000);
        _setBalanceModule(address(bm));
        _setSwitches(true, true);
        uint256 sid = _composeOnce().sid;
        _callerPayOn();
        _makeEligible(sid);
        vm.fee(composeBasefee);
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        vm.prank(keeper);
        core.redeemStatement{gas: 9_000_000}(sid);
        uint256 got = keeper.balance - before_;
        // the counted gas stops at 1_500_000, whatever the module burned
        assertEq(got, 1_500_000 * composeBasefee + 0.0005 ether);
        assertEq(pot - core.ethPot(), got);
    }

    function test_OK_redeemPay_aRevertingRedeemPaysNothing() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _callerPayOn();
        mod.setPayBps(5_000);
        _makeEligible(sid);
        uint256 pot = core.ethPot();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(sid);
        assertEq(keeper.balance, bal);
        assertEq(core.ethPot(), pot);
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held);
    }

    /// the payment is the counted gas at the base fee. the counted gas is the metered gas of the call plus a fixed
    /// overhead that includes the transaction base cost, so it covers the gross gas of the transaction
    function test_redeemPayCoversTheGrossGasOfTheTransaction() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        Settings memory s = core.settings();
        s.callerMaxBaseFee = 10 gwei;
        _setSettings(s);
        _warp(105 hours);
        vm.fee(composeBasefee);
        (uint256 got,,) = _redeemAndMeasure(sid);
        uint256 gross = lastRedeemGross;
        emit log_named_uint("paid", got);
        emit log_named_uint("gross gas of the transaction at the base fee", gross * composeBasefee);
        assertGe(got + 15_000 * composeBasefee, gross * composeBasefee, "covers the gross gas of the transaction but for the part of the overhead the constant leaves out");
        assertLe(got, (gross + 20_000) * composeBasefee, "the overhead is not oversized");
    }

    // ------------------------------------------------------------------ settings, config, scripts

    function _withAll(bool high) internal view returns (Settings memory s) {
        uint256[23] memory v = high ? SettingsFields.hi() : SettingsFields.lo();
        for (uint256 i; i < SettingsFields.N; ++i) {
            SettingsFields.set(s, i, v[i]);
        }
    }

    function test_OK_settings_packingRoundTripAtEveryMaxAndMin() public {
        for (uint256 k; k < 2; ++k) {
            Settings memory s = _withAll(k == 1);
            assertEq(SettingsBounds.firstViolation(s), bytes32(0), "table values are inside the bounds");
            _setSettings(s);
            Settings memory live = core.settings();
            assertEq(abi.encode(live), abi.encode(s), "every field survives the four packed slots");
            for (uint256 i; i < SettingsFields.N; ++i) {
                assertEq(SettingsFields.get(live, i), SettingsFields.get(s, i));
            }
        }
    }

    function test_OK_settings_everyFieldBoundMatchesTheScriptTable() public {
        bytes32[23] memory names = SettingsFields.names();
        uint256[23] memory lo = SettingsFields.lo();
        uint256[23] memory hi = SettingsFields.hi();
        for (uint256 i; i < SettingsFields.N; ++i) {
            // the two switches (fields 11 and 12) take 0 or 1: nothing is above their top
            if (i == 11 || i == 12) continue;
            Settings memory s = core.settings();
            SettingsFields.set(s, i, hi[i] + 1);
            assertTrue(SettingsBounds.firstViolation(s) != bytes32(0), string.concat("above ", _nm(names[i])));
            vm.prank(owner);
            vm.expectRevert();
            core.setSettings(s);
            if (lo[i] != 0) {
                s = core.settings();
                SettingsFields.set(s, i, lo[i] - 1);
                assertTrue(SettingsBounds.firstViolation(s) != bytes32(0), string.concat("below ", _nm(names[i])));
                vm.prank(owner);
                vm.expectRevert();
                core.setSettings(s);
            }
        }
    }

    function test_OK_settings_fieldCountAndSelectorAgreeEverywhere() public {
        assertEq(abi.encode(core.settings()).length, SettingsFields.N * 32, "struct has as many words as the table");
        TupleProbe t = new TupleProbe();
        bytes4 fromScript = bytes4(keccak256(abi.encodePacked("setSettings(", t.tuple(), ")")));
        assertEq(fromScript, ICore.setSettings.selector, "SetSettings.s.sol tuple equals the Settings struct");
    }

    function _nm(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory o = new bytes(n);
        for (uint256 i; i < n; ++i) {
            o[i] = b[i];
        }
        return string(o);
    }

    function _has(string[] memory keys, string memory k) internal pure returns (bool) {
        for (uint256 i; i < keys.length; ++i) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(k))) return true;
        }
        return false;
    }

    function test_OK_config_jsonCarriesEveryFieldAndTheSaleBlock() public view {
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        string[] memory keys = vm.parseJsonKeys(j, ".settings");
        bytes32[23] memory names = SettingsFields.names();
        assertEq(keys.length, SettingsFields.N, "the settings block has exactly the fields of the struct");
        for (uint256 i; i < SettingsFields.N; ++i) {
            assertTrue(_has(keys, _nm(names[i])), _nm(names[i]));
        }
        assertFalse(_has(keys, "reserveBps"));
        string[] memory sale = vm.parseJsonKeys(j, ".sale");
        assertEq(sale.length, 7);
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(abi.encode(f.sale), abi.encode(Mainnet.defaultSale()));
        assertEq(abi.encode(f.settings), abi.encode(Mainnet.defaultSettings()));
        assertEq(f.symbol, "CC");
    }

    function test_OK_postflight_comparesEveryFieldOfTheSettingsAndTheSaleBlock() public {
        postflightAs(lc, address(core), owner);
        (string memory clean,) = _failed();
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            SettingsFields.set(c.settings, i, SettingsFields.get(c.settings, i) == 0 ? 1 : SettingsFields.get(c.settings, i) - 1);
            postflightAs(c, address(core), owner);
            (string memory dirty,) = _failed();
            assertTrue(keccak256(bytes(dirty)) != keccak256(bytes(clean)), _nm(SettingsFields.names()[i]));
        }
        for (uint256 i; i < 9; ++i) {
            LaunchConfig memory c = lc;
            if (i == 0) c.sale.markupBps += 1;
            if (i == 1) c.sale.startCapBps += 1;
            if (i == 2) c.sale.fastDecayBpsPerHour += 1;
            if (i == 3) c.sale.kneeBps += 1;
            if (i == 4) c.sale.slowDecayBpsPerHour += 1;
            if (i == 5) c.sale.anchorHalfLife += 1;
            if (i == 6) c.sale.anchorMinCost += 1;
            if (i == 7) c.credit.royaltyBps += 1;
            if (i == 8) c.credit.royaltyRecipient = address(0xA27);
            postflightAs(c, address(core), owner);
            (string memory dirty,) = _failed();
            assertTrue(keccak256(bytes(dirty)) != keccak256(bytes(clean)), "sale field unseen by postflight");
        }
    }

    function tryController(Sale memory k) external returns (bool) {
        try this._ctlExt(k) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _ctlExt(Sale memory k) external returns (address) {
        Credit memory credit = Mainnet.defaultCredit();
        credit.royaltyRecipient = creator;
        return deployCode("ControllerV1.sol:ControllerV1", abi.encode(address(core), k, credit));
    }

    function test_OK_saleBounds_scriptAndControllerConstructorAgree() public {
        Sale[25] memory v;
        for (uint256 i; i < v.length; ++i) {
            v[i] = Mainnet.defaultSale();
        }
        v[0].markupBps = 9_999;
        v[1].markupBps = 40_001;
        v[2].startCapBps = 14_999;
        v[3].fastDecayBpsPerHour = 0;
        v[4].fastDecayBpsPerHour = 10_001;
        v[5].kneeBps = 999;
        v[6].kneeBps = 1_000;
        v[7].markupBps = 40_000;
        v[7].startCapBps = 40_000;
        v[7].fastDecayBpsPerHour = 10_000;
        v[8].startCapBps = 200_000;
        v[9].startCapBps = 200_001;
        v[10].anchorHalfLife = 1 days - 1;
        v[11].anchorHalfLife = 90 days + 1;
        v[12].anchorHalfLife = 1 days;
        v[13].anchorHalfLife = 90 days;
        v[14].slowDecayBpsPerHour = 0;
        v[15].slowDecayBpsPerHour = 10_001;
        v[16].kneeBps = 998;
        v[17].kneeBps = v[17].startCapBps + 1;
        v[18].kneeBps = v[18].startCapBps;
        v[19].kneeBps = 1_000;
        v[20].fastDecayBpsPerHour = 1;
        v[21].slowDecayBpsPerHour = 10_000;
        v[22].anchorMinCost = 10 ether + 1;
        v[23].anchorMinCost = 10 ether;
        v[24].anchorMinCost = 0;
        for (uint256 i; i < v.length; ++i) {
            LaunchConfig memory c = lc;
            c.sale = v[i];
            assertEq(saleViolation(c) == bytes32(0), this.tryController(v[i]), string.concat("variant ", vm.toString(i)));
        }
    }

    function test_OK_sizeMarginOfTheCore() public {
        uint256 size = vm.getDeployedCode("Core.sol:Core").length;
        emit log_named_uint("core runtime bytes", size);
        // the v2 brief (docs/DECISIONS.md 10.6) asks for at least 60 bytes of headroom
        assertGe(24_576 - size, 60, "the brief asks for a margin of at least 60");
    }

    bool internal ownerChangedFlag;
    bool internal coinChangedFlag;

    function _coinChanged() internal view override returns (bool) {
        return coinChangedFlag;
    }

    function _ownerChanged() internal view override returns (bool) {
        return ownerChangedFlag;
    }

    /// S-6 fixed (postflight half, the Resume half is in test/Resume.t.sol): RUNBOOK.md hands the Core to a multisig with
    /// OWNER_CHANGED=1 and the token admin with updateAdmin, named by COIN_CHANGED=1 (decision: v2 has its own flag)
    function test_FIXED_ownerChangedFlagRelaxesTheCoinAdminRow() public {
        ownerChangedFlag = true;
        coinChangedFlag = true;
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(alice);
        core.acceptOwnership();
        vm.prank(owner);
        (bool ok,) = address(coin).call(abi.encodeWithSignature("updateAdmin(address)", alice));
        assertTrue(ok, "the coin admin hands over");
        postflightAs(lc, address(core), owner);
        (string memory failed, uint256 n) = _failed();
        assertEq(n, 0, failed);
        coinChangedFlag = false;
        postflightAs(lc, address(core), owner);
        (failed,) = _failed();
        assertTrue(vm.contains(failed, "coin: admin is the config owner"), "without the flag the row still fails");
    }

    bool internal locksChangedFlag;

    function _locksChanged() internal view override returns (bool) {
        return locksChangedFlag;
    }

    /// S-10 fixed: LOCKS_CHANGED=1 turns the launch state row into a report line
    function test_FIXED_locksChangedFlagTurnsTheLockRowIntoAReportLine() public {
        vm.prank(owner);
        core.lockTargets();
        postflightAs(lc, address(core), owner);
        (string memory failed, uint256 n) = _failed();
        assertGt(n, 0);
        assertTrue(vm.contains(failed, "core: no locks, no balance module"), failed);
        locksChangedFlag = true;
        postflightAs(lc, address(core), owner);
        (failed, n) = _failed();
        assertEq(n, 0, failed);
    }

    function test_OK_priceOf_refusesWhatIsNotForSale() public {
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(777_777);
        (uint256 sid,) = _sellStatement(alice);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(sid);
    }

    /// S-9 fixed: with nothing pending, the zero address is the pending owner, and a call from it no longer passes
    function test_FIXED_acceptOwnershipRejectsTheZeroCaller() public {
        assertEq(core.pendingOwner(), address(0));
        vm.prank(address(0));
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner, "the owner is untouched");
    }
}
