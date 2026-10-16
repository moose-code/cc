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

    function setUp() public override {
        super.setUp();
        _enterPhase2();
        nextToken = new MockBalanceToken("Replacement", "R");
        nextModule = new MockBalanceModule(address(nextToken), 2 * UNIT);
    }

    // promise: decision 142 never moves or relabels an old module's token reserve
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

    // promise: a statement held before replacement redeems into the explicitly selected token and module
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

    // promise: a seller can refuse a currency changed between quote and inclusion, before any Credit moves
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

    // promise: replacement remains owner-only and the existing one-way module lock closes it
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

    // promise: a replacement clears dormant adapter approvals and cannot collide with the successor
    function test_replacementValidityAndAdapterFlags() public {
        vm.startPrank(owner);
        core.addAdapter(address(nextModule));
        core.addAdapter(address(nextToken));
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertFalse(core.allowedAdapter(address(nextModule)));
        assertFalse(core.allowedAdapter(address(nextToken)));
        _setBalanceModule(address(mod));
        vm.startPrank(owner);
        core.setSuccessor(address(nextToken));
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(nextModule));
        vm.stopPrank();
        assertEq(core.balanceToken(), address(xt));
    }

    // promise: the old pool cannot price a replacement currency through either use of valueOf
    function test_oldPoolIgnoredUntilMatchingTokenSelected() public {
        uint256 points = core.settings().refScore;
        uint256 rateValue = ctl.valueOf(points);
        PoolKey memory key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(xt)),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        PM.initialize(key, uint160((uint256(1) << 96) / 1000));
        IControllerV1.PoolKey memory ck = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)), currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000, tickSpacing: 60, hooks: address(0)});
        vm.prank(owner);
        ctl.setBalancePoolKey(ck);
        uint256 poolValue = ctl.valueOf(points);
        assertGt(poolValue, rateValue);
        _setBalanceModule(address(nextModule));
        assertEq(ctl.valueOf(points), rateValue);
        _setBalanceModule(address(mod));
        assertEq(ctl.valueOf(points), poolValue);
    }

    // promise: the single-currency invariant handler rejects forbidden tokens rather than every different token
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
        for (uint256 i; i < handler.violationCount(); ++i) assertEq(handler.viol(i), 0);
        assertEq(core.balanceToken(), address(xt));
    }
}
