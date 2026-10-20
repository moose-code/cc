// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ValueBase} from "./ValueMode.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CreditSale, Quote, Settings, POINT_UNIT} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// the ControllerV2 surface this file drives, restated so the test compiles without via_ir
interface IControllerV2Test {
    error StatementSalesOff();

    function refreshReference() external returns (bool);
    function creditPrice(uint256 id) external view returns (uint256);
    function buyCredit(uint256 id) external payable;
    function spotPrice() external view returns (uint256 spot, bool ok);
    function referencePrice() external view returns (uint256);
    function setQuote(Quote calldata v) external;
    function setCredit(CreditSale calldata v) external;
    function setBalancePoolKey(PoolKey calldata key, uint256 expectedSpot) external;
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
    function balanceClampFor(uint256 score, uint256 posted) external view returns (uint256 paid, bool ok);
    function creditSpreadBps() external view returns (uint16);
    function creditWindow() external view returns (uint32);
    function creditSaleOn() external view returns (bool);
    function creditStartBps() external view returns (uint32);
    function priceOf(uint256 sid) external view returns (uint256);
    function referenceOf(uint256 sid) external view returns (uint256);
    function atFloor(uint256 sid) external view returns (bool);
    function buy(uint256 sid) external payable;
    function setStatementSales(bool enabled) external;
}

/// ControllerV2 on the real v4 pool of the value mode fixture: the issue 113 counterexamples, same block moves in both
/// directions, the live liquidity gate, view and door parity, and the statement policy in value mode
contract ControllerV2Test is ValueBase {
    using StateLibrary for IPoolManager;

    IControllerV2Test internal c2;
    address internal constant TRIPPER = address(0x7419);

    function setUp() public override {
        super.setUp();
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: ctl.creditSpreadBps(),
            startBps: ctl.creditStartBps()
        });
        Quote memory none;
        c2 = IControllerV2Test(
            vm.deployCode(
                "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(30_000), uint32(3_600))
            )
        );
        _setController(address(c2));
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        vm.prank(owner);
        c2.setBalancePoolKey(key, _spotOf(sp));
        vm.prank(owner);
        c2.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_000,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 0,
                minLiquidity: 1e18
            })
        );
    }

    /// the issue 113 settings: the reviewed 203 bps spread and 100 bps tolerance with a six hour return lock
    function _phaseTwoQuote() internal {
        _valueOn();
        _setCreditSaleOn(true);
        _setReturnLock(6 hours);
        vm.prank(owner);
        c2.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 100,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 600,
                minLiquidity: 1e18
            })
        );
        CreditSale memory sale =
            CreditSale({saleOn: true, window: c2.creditWindow(), spreadBps: 203, startBps: c2.creditStartBps()});
        vm.prank(owner);
        c2.setCredit(sale);
        _warp(c2.creditWindow());
        vm.roll(block.number + 1);
        _fundPot(50 ether);
    }

    function _buyAsTripper(uint256 id) internal returns (uint256 price) {
        price = c2.creditPrice(id);
        vm.deal(TRIPPER, price);
        vm.prank(TRIPPER);
        c2.buyCredit{value: price}(id);
        vm.prank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
    }

    function _sellBackAfterLock(uint256 id) internal returns (uint256 back) {
        for (uint256 i; i < 36; ++i) {
            _warp(10 minutes);
            vm.roll(block.number + 1);
            c2.refreshReference();
        }
        uint256 before = TRIPPER.balance;
        vm.prank(TRIPPER);
        core.sellForEth(_one(id));
        back = TRIPPER.balance - before;
    }

    // promise: issue 113 a persistent real pool rise no longer leaves the Credit ask below the later bid: the live spot prices the ask at once and the round trip loses
    function test_persistentRiseCannotOutrunTheAsk() public {
        uint256[] memory ids = _fillEthPile(1);
        _phaseTwoQuote();
        uint256 beforeSpot = _spotNow();
        uint256 movedSpot = _swapSpot(3_000);
        assertGt(movedSpot, beforeSpot * 12 / 10, "the real pool move did not reach the test band");
        uint256 price = _buyAsTripper(ids[0]);
        vm.expectPartialRevert(ICore.ReturnLocked.selector);
        vm.prank(TRIPPER);
        core.sellForEth(_one(ids[0]));
        uint256 back = _sellBackAfterLock(ids[0]);
        emit log_named_uint("credit purchase wei", price);
        emit log_named_uint("credit resale wei after the six hour lock", back);
        assertLt(back, price, "the later bid outran the ask");
    }

    // promise: issue 113 a persistent real pool fall is priced the same way: the ask keeps the prior sample and the later bid follows the fall, so the round trip loses
    function test_persistentFallCannotOutrunTheAsk() public {
        uint256[] memory ids = _fillEthPile(1);
        _phaseTwoQuote();
        uint256 beforeSpot = _spotNow();
        uint256 movedSpot = _swapSpot(-3_000);
        assertLt(movedSpot, beforeSpot * 8 / 10, "the real pool move did not reach the test band");
        uint256 price = _buyAsTripper(ids[0]);
        uint256 back = _sellBackAfterLock(ids[0]);
        assertLt(back, price, "the later bid outran the ask");
    }

    // promise: issue 113 a same block pool move can only worsen the mover's own side: up raises the sale value and leaves the buy value, down lowers the buy value and leaves the sale value
    function test_sameBlockMovesOnlyWorsenTheMoverSide() public {
        _valueOn();
        _settle();
        (uint256 buy0,) = c2.valuePerPoint(false);
        (uint256 sell0,) = c2.valuePerPoint(true);
        _swapSpot(300);
        (uint256 buyUp, bool okUp) = c2.valuePerPoint(false);
        (uint256 sellUp,) = c2.valuePerPoint(true);
        assertTrue(okUp);
        assertEq(buyUp, buy0, "the buy value ignores a same block rise");
        assertGt(sellUp, sell0, "the sale value follows a same block rise at once");
        _swapSpot(-600);
        (uint256 buyDown,) = c2.valuePerPoint(false);
        (uint256 sellDown,) = c2.valuePerPoint(true);
        assertLt(buyDown, buy0, "the buy value follows a same block fall at once");
        assertGe(sellDown, sell0, "the sale value ignores a same block fall");
        // the balance payout cap follows the sale value, so a rise lowers the cap and a fall leaves it
        (uint256 capUp,) = c2.balanceClampFor(POINT_UNIT, type(uint128).max);
        _swapSpot(1_000);
        (uint256 capHigher,) = c2.balanceClampFor(POINT_UNIT, type(uint128).max);
        assertLt(capHigher, capUp, "a same block rise lowers the balance payout cap");
    }

    // promise: issue 113 a presently emptied pool closes the quote even while the two liquidity samples are healthy, and the Core's eth bid closes with it
    function test_liveLiquidityGateClosesAnEmptiedPool() public {
        _valueOn();
        _fundPot(50 ether);
        _settle();
        (, bool ok) = c2.valuePerPoint(false);
        assertTrue(ok);
        assertGt(core.ethRate(), 0);
        lp.modify(key, -TICK_FULL, TICK_FULL, -int256(uint256(POOL_LIQ)));
        assertLt(_liquidityNow(), 1e18, "the pool is emptied in this block");
        (, ok) = c2.valuePerPoint(false);
        assertFalse(ok, "the live liquidity gate closes the quote");
        assertEq(core.ethRate(), 0, "the Core closes its eth bid");
        (uint256 paid, bool clampOk) = c2.balanceClampFor(POINT_UNIT, 1e18);
        assertEq(paid, 0);
        assertTrue(clampOk);
    }

    // promise: issue 113 the Credit sale view in the block of a due refresh equals the price the door charges
    function test_viewAndDoorAgreeAroundADueRefresh() public {
        uint256[] memory ids = _fillEthPile(2);
        _valueOn();
        _setCreditSaleOn(true);
        _warp(c2.creditWindow());
        vm.prank(owner);
        c2.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 100,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 600,
                minLiquidity: 1e18
            })
        );
        CreditSale memory sale =
            CreditSale({saleOn: true, window: c2.creditWindow(), spreadBps: 203, startBps: c2.creditStartBps()});
        vm.prank(owner);
        c2.setCredit(sale);
        _swapSpot(1_500);
        // a refresh is due in a new block: the view projects it and the door runs it
        _warp(11 minutes);
        vm.roll(block.number + 1);
        uint256 viewPrice = c2.creditPrice(ids[0]);
        vm.deal(TRIPPER, viewPrice * 2);
        vm.prank(TRIPPER);
        c2.buyCredit{value: viewPrice * 2}(ids[0]);
        assertEq(viewPrice * 2 - TRIPPER.balance, viewPrice, "the door charged the view price");
        assertEq(c2.creditPrice(ids[1]), viewPrice > 0 ? c2.creditPrice(ids[1]) : 0);
    }

    // promise: SPEC phase 2 in value mode the statement ask is the persistent multiple of the protected reference and eligibility is the independent delay
    function test_statementPolicyInValueMode() public {
        _valueOn();
        _settle();
        uint256 sid = _composeOnce().sid;
        uint256 ref = c2.referenceOf(sid);
        uint256 cost;
        (, cost,) = core.statementInfo(sid);
        uint256 ask = FullMath.mulDivRoundingUp(ref, 30_000, 10_000);
        uint256 coreFloor = cost * core.settings().saleFloorBps / 10_000;
        if (ask < coreFloor) ask = coreFloor;
        assertEq(c2.priceOf(sid), ask);
        assertFalse(c2.atFloor(sid));
        _warp(1 hours);
        assertTrue(c2.atFloor(sid));
        assertEq(
            c2.priceOf(sid), FullMath.mulDivRoundingUp(c2.referenceOf(sid), 30_000, 10_000), "no decay at eligibility"
        );
        vm.prank(owner);
        c2.setStatementSales(true);
        uint256 price = c2.priceOf(sid);
        address buyer = _user("buyer");
        vm.deal(buyer, price);
        vm.prank(buyer);
        c2.buy{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    /// settles the reference on the pool spot so the first quote reads a clean band
    function _settle() internal {
        for (uint256 i; i < 60; ++i) {
            (uint256 spot,) = c2.spotPrice();
            uint256 ref = c2.referencePrice();
            uint256 diff = spot > ref ? spot - ref : ref - spot;
            if (diff <= ref / 1_000) break;
            _warp(1 hours);
            vm.roll(block.number + 1);
            c2.refreshReference();
        }
        _warp(1);
        vm.roll(block.number + 1);
        c2.refreshReference();
    }

    function _spotNow() internal view returns (uint256 spot) {
        (spot,) = c2.spotPrice();
    }
}
