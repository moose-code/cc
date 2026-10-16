// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
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

contract BalanceTokenReplacementTest is Fixture {
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

    // rule: a replaced module keeps its own token reserve; the Core holds no balance token and never relabels a reserve
    function test_replacementPreservesSeparateModuleCustody() public {
        uint256 oldReserve = xt.balanceOf(address(mod));
        nextToken.mint(address(nextModule), 7e21);
        _setBalanceModule(address(nextModule));
        assertEq(core.balanceToken(), address(nextToken));
        assertEq(xt.balanceOf(address(mod)), oldReserve);
        assertEq(nextModule.available(), 7e21);
        assertEq(nextToken.balanceOf(address(core)), 0);
        _setBalanceModule(address(mod));
        assertEq(core.balanceToken(), address(xt));
        assertEq(mod.available(), oldReserve);
        assertEq(nextModule.available(), 7e21);
    }

    // rule: a statement held before a replacement redeems into the module and token selected at redemption time
    function test_heldStatementRedeemsIntoReplacementModule() public {
        uint256 sid = _composeOnce().sid;
        uint256 oldReserve = mod.available();
        _setBalanceModule(address(nextModule));
        _makeEligible(sid);
        uint256 owed = core.ratingOf(sid) * 2 * UNIT;
        core.redeemStatement(sid);
        assertEq(nextModule.available(), owed);
        assertEq(nextToken.balanceOf(address(core)), 0);
        assertEq(mod.available(), oldReserve);
        assertEq(STATEMENTS.ownerOf(sid), address(nextModule));
    }

    // rule: sellForBalance(ids, minOut, expectedToken) reverts BalanceTokenChanged before any credit moves when the
    // token differs, and goes through when it matches
    function test_sellerCanPinThePaymentToken() public {
        uint256[] memory ids = _credits(seller, 1);
        _setBalanceModule(address(nextModule));
        nextToken.mint(address(nextModule), 1e23);
        vm.prank(seller);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.sellForBalance(ids, 0, address(xt));
        assertEq(CREDITS.ownerOf(ids[0]), seller);
        vm.prank(seller);
        core.sellForBalance(ids, 1, address(nextToken));
        assertGt(nextToken.balanceOf(seller), 0);
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    // rule: setBalanceModule is owner only and the balanceModule lock refuses every later set
    function test_ownerAndModuleLockStillApply() public {
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(nextModule));
        vm.startPrank(owner);
        core.lockBalanceModule();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("balanceModule")));
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertEq(core.balanceToken(), address(xt));
    }

    // rule: a replacement after a lock is refused and the balance token stays the token in force at the lock
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

    // rule: a module set clears dormant adapter approvals of the module and token and refuses a module or token equal
    // to the successor
    function test_replacementValidityAndAdapterFlags() public {
        vm.startPrank(owner);
        core.addAdapter(address(nextModule));
        core.addAdapter(address(nextToken));
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertFalse(core.allowedAdapter(address(nextModule)));
        assertFalse(core.allowedAdapter(address(nextToken)));
        _setBalanceModule(address(mod));
        // a module whose token equals the successor is refused. the successor is a fresh token, not an ever-set target
        MockBalanceToken collideToken = new MockBalanceToken("Collide", "C");
        MockBalanceModule collideModule = new MockBalanceModule(address(collideToken), UNIT);
        vm.startPrank(owner);
        core.setSuccessor(address(collideToken));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(collideModule));
        vm.stopPrank();
        assertEq(core.balanceToken(), address(xt));
    }

    // rule: a replaced module and its token stay forbidden targets for setPayee, setArtist, addAdapter, setSuccessor
    // and buyListing quote targets, while re-selecting the old module still goes through
    function test_oldTargetsStayForbiddenAfterReplacement() public {
        _setBalanceModule(address(nextModule));
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setPayee(address(mod));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setPayee(address(xt));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setArtist(address(mod));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(xt));
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, address(mod)));
        core.setSuccessor(address(mod));
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, address(xt)));
        core.setSuccessor(address(xt));
        // the old module is still a valid module for a re-selection
        core.setBalanceModule(address(mod));
        vm.stopPrank();
        assertEq(core.balanceToken(), address(xt));
    }

    // rule: a buyListing quote that targets a replaced module or its token is refused
    function test_oldModuleRejectedAsBuyListingTarget() public {
        _setBalanceModule(address(nextModule));
        uint256[] memory ids = _credits(seller, 1);
        bytes memory data = abi.encodeWithSignature("noop()");
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        _buyRaw(0, data, ids[0], address(mod));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        _buyRaw(0, data, ids[0], address(xt));
    }

    // rule: setBalanceModule while balanceBidOn resets the balance instance rate, clock and anchor to the floor
    function test_replacementWhileBidOnResetsToFloor() public {
        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        nextToken.mint(address(nextModule), 1e24);
        // a fill then a warp leave the stored clock behind the current time
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
        _warp(2 hours);
        uint64 clockBefore = uint64(_slot(33));
        assertTrue(clockBefore != uint64(block.timestamp), "the clock is behind before the replacement");
        _setBalanceModule(address(nextModule));
        assertEq(_slot(32), floor, "rateAtCheckpoint is the floor");
        assertEq(uint64(_slot(33)), uint64(block.timestamp), "checkpointTime is fresh");
        assertEq(uint64(_slot(33) >> 64), uint64(block.timestamp), "lastFillTime is fresh");
        assertEq(_slot(34), floor, "anchor.lastFillRate is the floor");
        assertEq(_slot(35), floor, "anchor.minuteStartRate is the floor");
        assertEq(_slot(37), floor, "anchor.peakRate is the floor");
        assertEq(core.balanceRate(), floor, "the read rate is the floor");
    }

    // rule: a replacement inside the fill bucket resets the instance and the next sell pays in the new token
    function test_replacementMidBucketThenSell() public {
        nextToken.mint(address(nextModule), 1e24);
        uint256[] memory first = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(first);
        // inside the same 60 second bucket as the fill
        _warp(30);
        _setBalanceModule(address(nextModule));
        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        assertEq(_slot(32), floor, "the instance reset to the floor inside the bucket");
        uint256 oldPile = xt.balanceOf(seller);
        assertGt(oldPile, 0, "the first sell paid the old token");
        uint256[] memory second = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(second, 1, address(nextToken));
        assertGt(nextToken.balanceOf(seller), 0);
        assertEq(xt.balanceOf(seller), oldPile, "the new sell did not pay the old token");
        assertEq(CREDITS.ownerOf(second[0]), address(core));
    }

    // rule: an old-token pile a seller already holds is untouched by a replacement, and the bid reads on a 6 decimal
    // token the new module reports its rate and per credit payout
    function test_replacementWithSixDecimalToken() public {
        uint256[] memory sold = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(sold);
        uint256 sellerOldPile = xt.balanceOf(seller);
        assertGt(sellerOldPile, 0, "the seller holds an old-token pile");
        uint256 oldReserve = mod.available();

        MockBalanceToken six = new MockBalanceToken("USD Six", "U6");
        six.setDecimals(6);
        MockBalanceModule sixMod = new MockBalanceModule(address(six), 1e4);
        six.mint(address(sixMod), 1e18);
        _setBalanceModule(address(sixMod));
        assertEq(core.balanceToken(), address(six));
        assertEq(mod.available(), oldReserve, "the old reserve stayed in the old module");

        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        assertEq(core.balanceRate(), floor, "the rate reads the floor on the 6 decimal token");
        uint256[] memory probe = _credits(seller, 1);
        assertEq(core.balanceBidOf(probe[0]), _scoreOf(probe[0]) * 1e4 * floor / 10_000, "the per credit payout scales");

        vm.prank(seller);
        core.sellForBalance(probe, 1, address(six));
        assertGt(six.balanceOf(seller), 0, "the seller received the 6 decimal token");
        assertEq(xt.balanceOf(seller), sellerOldPile, "the old-token pile is unchanged");
    }

    // rule: the unpinned sellForBalance overloads pay in the token active at execution after a replacement
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
        assertEq(xt.balanceOf(seller), 0, "the old token paid nothing");
        assertEq(CREDITS.ownerOf(a[0]), address(core));
        assertEq(CREDITS.ownerOf(b[0]), address(core));
    }

    // rule: setBalancePoolKey takes the current token and refuses a key whose currency1 is a replaced token
    function test_setBalancePoolKeyFollowsTheToken() public {
        nextToken.mint(address(nextModule), 1e24);
        _setBalanceModule(address(nextModule));
        // a key on the old token is refused once the token has changed
        PoolKey memory oldKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(oldKey, uint160((uint256(1) << 96) * 1000));
        IControllerV1.PoolKey memory badCk = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(badCk);
        // a key on the new token is accepted and prices valueOf above the rate floor
        uint256 points = core.settings().refScore;
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
        ctl.setBalancePoolKey(goodCk);
        assertGt(ctl.valueOf(points), rateValue, "the new token pool key prices valueOf");
    }

    // rule: valueOf, priceOf and atFloor ignore a pool key whose currency1 is not the current token
    function test_oldPoolIgnoredUntilMatchingTokenSelected() public {
        uint256 sid = _composeOnce().sid;
        uint256 points = core.settings().refScore;
        uint256 rateValue = ctl.valueOf(points);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(key, uint160((uint256(1) << 96) / 1000));
        IControllerV1.PoolKey memory ck = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(ck);
        uint256 poolValue = ctl.valueOf(points);
        uint256 poolPrice = ctl.priceOf(sid);
        bool poolFloor = ctl.atFloor(sid);
        assertGt(poolValue, rateValue);
        _setBalanceModule(address(nextModule));
        assertEq(ctl.valueOf(points), rateValue, "valueOf drops the stale pool term");
        assertLe(ctl.priceOf(sid), poolPrice, "priceOf drops the stale pool term");
        _setBalanceModule(address(mod));
        assertEq(ctl.valueOf(points), poolValue, "valueOf restores the pool term for the matching token");
        assertEq(ctl.priceOf(sid), poolPrice, "priceOf restores the pool term");
        assertEq(ctl.atFloor(sid), poolFloor, "atFloor restores");
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
