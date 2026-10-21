// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE, Settings} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Handler} from "./invariant/Handler.sol";
import {Wiring} from "./invariant/HandlerBase.sol";
import {FuzzController} from "./attackers/FuzzController.sol";

/// the starting balance side is the live phase 2 treasury on the live BALANCE token; the replacement module and token
/// are fresh stand ins, the subject of the replacement. the old side is read through the live token and `treasury`
contract BalanceTokenReplacementTest is LiveFixture {
    MockBalanceToken private nextToken;
    MockBalanceModule private nextModule;

    /// the balance instance Rate lives at slots 32 to 37 (test/CoreLayout.t.sol): 32 rateAtCheckpoint, 33 the packed
    /// checkpointTime and lastFillTime, 34 anchor.lastFillRate, 35 anchor.minuteStartRate, 37 anchor.peakRate
    function _slot(uint256 i) private view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(i)));
    }

    function setUp() public override {
        super.setUp();
        _enterPhase2();
        nextToken = new MockBalanceToken("Replacement", "R");
        nextModule = new MockBalanceModule(address(nextToken), 2 * UNIT);
    }

    // promise: a replaced module keeps its own token reserve; the Core holds no balance token and never relabels a reserve
    function test_replacementPreservesSeparateModuleCustody() public {
        uint256 oldReserve = _moduleCustody();
        nextToken.mint(address(nextModule), 7e21);
        _setBalanceModule(address(nextModule));
        assertEq(core.balanceToken(), address(nextToken));
        assertEq(_moduleCustody(), oldReserve);
        assertEq(nextModule.available(), 7e21);
        assertEq(nextToken.balanceOf(address(core)), 0);
        _setBalanceModule(address(treasury));
        assertEq(core.balanceToken(), liveBalanceToken);
        assertEq(_moduleCustody(), oldReserve);
        assertEq(nextModule.available(), 7e21);
    }

    // promise: a statement held before a replacement redeems into the module and token selected at redemption time
    function test_heldStatementRedeemsIntoReplacementModule() public {
        uint256 sid = _composeOnce().sid;
        uint256 oldReserve = _moduleCustody();
        _setBalanceModule(address(nextModule));
        _makeEligible(sid);
        uint256 owed = core.ratingOf(sid) * 2 * UNIT;
        core.redeemStatement(sid);
        assertEq(nextModule.available(), owed);
        assertEq(nextToken.balanceOf(address(core)), 0);
        assertEq(_moduleCustody(), oldReserve);
        assertEq(STATEMENTS.ownerOf(sid), address(nextModule));
    }

    // promise: sellForBalance(ids, minOut, expectedToken) reverts BalanceTokenChanged before any credit moves when the
    // token differs, and goes through when it matches
    function test_sellerCanPinThePaymentToken() public {
        uint256[] memory ids = _credits(seller, 1);
        _setBalanceModule(address(nextModule));
        nextToken.mint(address(nextModule), 1e23);
        vm.prank(seller);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.sellForBalance(ids, 0, liveBalanceToken);
        assertEq(CREDITS.ownerOf(ids[0]), seller);
        vm.prank(seller);
        core.sellForBalance(ids, 1, address(nextToken));
        assertGt(nextToken.balanceOf(seller), 0);
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    // promise: setBalanceModule is owner only and the balanceModule lock refuses every later set
    function test_ownerAndModuleLockStillApply() public {
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(nextModule));
        vm.startPrank(owner);
        core.lockBalanceModule();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertEq(core.balanceToken(), liveBalanceToken);
    }

    // promise: a replacement after a lock is refused and the balance token stays the token in force at the lock
    function test_replaceThenLockFreezesTheToken() public {
        nextToken.mint(address(nextModule), 1e24);
        _setBalanceModule(address(nextModule));
        assertEq(core.balanceToken(), address(nextToken));
        vm.prank(owner);
        core.lockBalanceModule();
        MockBalanceModule third = new MockBalanceModule(address(new MockBalanceToken("Third", "T3")), UNIT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(third));
        assertEq(core.balanceModule(), address(nextModule));
        assertEq(core.balanceToken(), address(nextToken));
    }

    // promise: a module set clears dormant adapter approvals of the module and token and refuses a module or token equal
    // to the successor
    function test_replacementValidityAndAdapterFlags() public {
        vm.startPrank(owner);
        core.addAdapter(address(nextModule));
        core.addAdapter(address(nextToken));
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertFalse(core.allowedAdapter(address(nextModule)));
        assertFalse(core.allowedAdapter(address(nextToken)));
        _setBalanceModule(address(treasury));
        // a module whose token equals the successor is refused. the successor is a fresh token, not an ever-set target
        MockBalanceToken collideToken = new MockBalanceToken("Collide", "C");
        MockBalanceModule collideModule = new MockBalanceModule(address(collideToken), UNIT);
        vm.startPrank(owner);
        core.setSuccessor(address(collideToken));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(collideModule));
        vm.stopPrank();
        assertEq(core.balanceToken(), liveBalanceToken);
    }

    // promise: a replaced module and its token stay forbidden targets for setPayee, setArtist, addAdapter, setSuccessor
    // and buyListing quote targets, while re-selecting the old module still goes through
    function test_oldTargetsStayForbiddenAfterReplacement() public {
        _setBalanceModule(address(nextModule));
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setPayee(address(treasury));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setPayee(liveBalanceToken);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setArtist(address(treasury));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(liveBalanceToken);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, address(treasury)));
        core.setSuccessor(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, liveBalanceToken));
        core.setSuccessor(liveBalanceToken);
        // the old module is still a valid module for a re-selection
        core.setBalanceModule(address(treasury));
        vm.stopPrank();
        assertEq(core.balanceToken(), liveBalanceToken);
    }

    // promise: a buyListing quote that targets a replaced module or its token is refused
    function test_oldModuleRejectedAsBuyListingTarget() public {
        _setBalanceModule(address(nextModule));
        uint256[] memory ids = _credits(seller, 1);
        bytes memory data = abi.encodeWithSignature("noop()");
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        _buyRaw(0, data, ids[0], address(treasury));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        _buyRaw(0, data, ids[0], liveBalanceToken);
    }

    // promise: a module replacement preserves a shared instance above its floor and the balance bid's separate discount
    function test_replacementWhileBidOnLeavesTheInstance() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 1_500;
        s.balanceDiscountBps = 2_000;
        _setSettings(s);
        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        uint256 posted = 10_000 - core.settings().balanceDiscountBps;
        assertLt(posted, floor, "the posted bid differs from the instance floor");
        nextToken.mint(address(nextModule), 1e24);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
        _warp(2 hours);
        uint256 clockBefore = _slot(33);
        uint256 rateBefore = _slot(32);
        uint256 anchorBefore = _slot(34);
        assertTrue(uint64(clockBefore) != uint64(block.timestamp), "the clock is behind before the replacement");
        assertGt(rateBefore, floor, "the instance is above its new floor before replacement");
        _setBalanceModule(address(nextModule));
        assertEq(_slot(32), rateBefore, "rateAtCheckpoint is untouched by the replacement");
        assertEq(_slot(33), clockBefore, "the clocks are untouched");
        assertEq(_slot(34), anchorBefore, "anchor.lastFillRate is untouched");
        assertEq(core.balanceRate(), posted, "the read rate is the posted rate");
    }

    // promise: a replacement inside the fill bucket preserves a nonfloor instance and the next sell pays in the new token
    function test_replacementMidBucketThenSell() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 1_500;
        _setSettings(s);
        nextToken.mint(address(nextModule), 1e24);
        uint256[] memory first = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(first);
        // inside the same 60 second bucket as the fill
        _warp(30);
        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        uint256 rateBefore = _slot(32);
        assertGt(rateBefore, floor, "the instance is above its new floor before replacement");
        _setBalanceModule(address(nextModule));
        assertEq(_slot(32), rateBefore, "the instance survives replacement inside the bucket");
        uint256 oldPile = _balanceOf(seller);
        assertGt(oldPile, 0, "the first sell paid the old token");
        uint256[] memory second = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(second, 1, address(nextToken));
        assertGt(nextToken.balanceOf(seller), 0);
        assertEq(_balanceOf(seller), oldPile, "the new sell did not pay the old token");
        assertEq(CREDITS.ownerOf(second[0]), address(core));
    }

    // promise: an old-token pile a seller already holds is untouched by a replacement, and the bid reads on a 6 decimal
    // token the new module reports its rate and per credit payout
    function test_replacementWithSixDecimalToken() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 1_500;
        s.balanceDiscountBps = 2_000;
        _setSettings(s);
        uint256[] memory sold = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(sold);
        uint256 sellerOldPile = _balanceOf(seller);
        assertGt(sellerOldPile, 0, "the seller holds an old-token pile");
        uint256 oldReserve = _moduleCustody();

        MockBalanceToken six = new MockBalanceToken("USD Six", "U6");
        six.setDecimals(6);
        MockBalanceModule sixMod = new MockBalanceModule(address(six), 1e4);
        six.mint(address(sixMod), 1e18);
        _setBalanceModule(address(sixMod));
        assertEq(core.balanceToken(), address(six));
        assertEq(_moduleCustody(), oldReserve, "the old reserve stayed in the old module");

        uint256 posted = 10_000 - core.settings().balanceDiscountBps;
        assertTrue(
            posted != 10_000 - core.settings().balanceBidMarginBps, "the posted rate differs from the instance floor"
        );
        assertEq(core.balanceRate(), posted, "the posted rate survives the module replacement");
        uint256[] memory probe = _credits(seller, 1);
        assertEq(
            core.balanceBidOf(probe[0]), _scoreOf(probe[0]) * 1e4 * posted / 10_000, "the per credit payout scales"
        );

        vm.prank(seller);
        core.sellForBalance(probe, 1, address(six));
        assertGt(six.balanceOf(seller), 0, "the seller received the 6 decimal token");
        assertEq(_balanceOf(seller), sellerOldPile, "the old-token pile is unchanged");
    }

    // promise: the unpinned sellForBalance overloads pay in the token active at execution after a replacement
    function test_unpinnedOverloadsAfterReplacement() public {
        nextToken.mint(address(nextModule), 1e24);
        _setBalanceModule(address(nextModule));
        uint256[] memory a = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(a);
        uint256[] memory b = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(b, 1);
        assertGt(nextToken.balanceOf(seller), 0, "both unpinned overloads paid in the new token");
        assertEq(_balanceOf(seller), 0, "the old token paid nothing");
        assertEq(CREDITS.ownerOf(a[0]), address(core));
        assertEq(CREDITS.ownerOf(b[0]), address(core));
    }

    // promise: setBalancePoolKey takes the current token and refuses a key whose currency1 is a replaced token
    function test_setBalancePoolKeyFollowsTheToken() public {
        nextToken.mint(address(nextModule), 1e24);
        _setBalanceModule(address(nextModule));
        // a key on the old token is refused once the token has changed
        PoolKey memory oldKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(liveBalanceToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(oldKey, uint160((uint256(1) << 96) * 1000));
        IControllerV1.PoolKey memory badCk = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(liveBalanceToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(badCk, 0);
        // a key on the new token is accepted and seeds the reference; valueOf stays the rate term
        uint256 points = RATE_SCORE;
        uint256 rateValue = ctl.valueOf(points);
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(nextToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(newKey, uint160((uint256(1) << 96) / 1000));
        IControllerV1.PoolKey memory goodCk = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(nextToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(goodCk, spotOf(uint160((uint256(1) << 96) / 1000)));
        assertTrue(ctl.balancePoolKeySet(), "the key is accepted");
        assertEq(ctl.valueOf(points), rateValue, "the pool key leaves valueOf");
    }

    // promise: valueOf, priceOf and atFloor are unchanged by a pool key and by a module replacement
    function test_oldPoolIgnoredUntilMatchingTokenSelected() public {
        uint256 sid = _composeOnce().sid;
        uint256 points = RATE_SCORE;
        uint256 rateValue = ctl.valueOf(points);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(liveBalanceToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(key, uint160((uint256(1) << 96) / 1000));
        IControllerV1.PoolKey memory ck = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(liveBalanceToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(ck, spotOf(uint160((uint256(1) << 96) / 1000)));
        uint256 poolPrice = ctl.priceOf(sid);
        bool poolFloor = ctl.atFloor(sid);
        assertEq(ctl.valueOf(points), rateValue, "the pool key leaves valueOf");
        _setBalanceModule(address(nextModule));
        assertEq(ctl.valueOf(points), rateValue, "valueOf is unchanged after the module replacement");
        assertEq(ctl.priceOf(sid), poolPrice, "priceOf is unchanged after the module replacement");
        _setBalanceModule(address(treasury));
        assertEq(ctl.valueOf(points), rateValue, "valueOf is unchanged for the matching token");
        assertEq(ctl.priceOf(sid), poolPrice, "priceOf is unchanged");
        assertEq(ctl.atFloor(sid), poolFloor, "atFloor is unchanged");
    }
}

/// the single currency invariant Handler wires a MockBalanceModule and MockBalanceToken on both sides: its subject is
/// the handler's replacement mechanics, which need a stand in module on both sides, so it stays on the stand in fixture
contract BalanceTokenReplacementHandlerTest is Fixture {
    function setUp() public override {
        super.setUp();
        _useLiveSettings(); // controlled input, live configuration (Addendum 4)
        _enterPhase2();
    }

    // rule: the single currency invariant handler rejects a forbidden token rather than any differing token
    function test_handlerRejectsForbiddenToken() public {
        Wiring memory wiring;
        wiring.core = core;
        wiring.coin = coin;
        wiring.owner = owner;
        wiring.v1 = address(ctl);
        wiring.fuzz = new FuzzController(address(core));
        wiring.module = mod;
        wiring.balanceToken = xt;
        Handler handler = new Handler(wiring);
        handler.replaceModule(1234, 4);
        for (uint256 i; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0);
        }
        assertEq(core.balanceToken(), address(xt));
    }

    // rule: the invariant handler's fresh-token replacement mode changes the token, keeps the old reserve and leaves
    // the Core holding no balance token
    function test_handlerFreshTokenReplacementMode() public {
        Wiring memory wiring;
        wiring.core = core;
        wiring.coin = coin;
        wiring.owner = owner;
        wiring.v1 = address(ctl);
        wiring.fuzz = new FuzzController(address(core));
        wiring.module = mod;
        wiring.balanceToken = xt;
        Handler handler = new Handler(wiring);
        uint256 oldReserve = mod.available();
        handler.replaceModule(99, 8);
        for (uint256 i; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0);
        }
        assertTrue(core.balanceToken() != address(xt), "the token changed");
        assertEq(mod.available(), oldReserve, "the old module reserve is unchanged");
        assertEq(MockBalanceToken(core.balanceToken()).balanceOf(address(core)), 0, "the Core holds no new token");
        assertEq(xt.balanceOf(address(core)), 0, "the Core holds no old token");
    }
}
