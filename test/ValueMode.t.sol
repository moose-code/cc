// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Quote, RATE_SCORE, POINT_UNIT} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {QuoteController} from "./attackers/QuoteController.sol";

/// the value switch (decisions 148, 150 to 154): the controller's rate limited reference of the balance token, its
/// protected buy and sale prices, `valuePerPoint`, and the Core in value mode: the eth bid is the shared balance instance
/// times the value per point at the buy price, every eth or balance fill drops that one instance, the switch resets it,
/// an unusable quote halts the eth routes only, and sales price off the protected value with the cost term dropped
abstract contract ValueBase is Fixture {
    /// wei per balance token base unit is 0.49, so one point (`POINT_UNIT * UNIT` base units) is worth 4.9e13 wei, the
    /// opening eth rate of 4.9e15 per 100 points: `2^96 / sqrt(0.49)`
    uint160 internal constant SP = uint160(FixedPoint96.Q96 * 10 / 7);
    uint128 internal constant LIQ = 1e24;
    PoolKey internal key;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(key, SP);
        _poolState(SP, LIQ);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
        _setQuote(Quote({rateBpsPerHour: 1_000, maxStepBps: 1_000, tolBps: 500, maxStale: 1 days, minLiquidity: 1e18}));
        mod.setAvailable(1e30);
    }

    /// writes the pool's slot 0 sqrt price and its liquidity in the pool manager storage (`StateLibrary` layout: the
    /// pools mapping at slot 6, slot 0 first, the liquidity at offset 3)
    function _poolState(uint160 sp, uint128 liq) internal {
        bytes32 base = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        bytes32 word = vm.load(address(PM), base);
        uint256 rest = uint256(word) & ~uint256(type(uint160).max);
        vm.store(address(PM), base, bytes32(rest | uint256(sp)));
        vm.store(address(PM), bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    /// the spot of sqrt price `sp`, wei per 1e18 base units
    function _spotOf(uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, sp), FixedPoint96.Q96, sp);
    }

    /// the sqrt price of a spot `p` wei per 1e18 base units, by the inverse of `_spotOf` within its rounding
    function _sqrtOf(uint256 p) internal pure returns (uint160) {
        // sp = 2^96 * sqrt(1e18 / p)
        return uint160(FullMath.mulDiv(FixedPoint96.Q96, _sqrt(1e36 / p), 1e9));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _setQuote(Quote memory q) internal {
        vm.prank(owner);
        ctl.setQuote(q);
    }

    function _valueOn() internal {
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.balanceBidCapBps = 11_000;
        s.saleFloorBps = 5_000;
        _setSettings(s);
    }

    /// the eth bid the value mode prices for 100 points at the shared rate `bps`: `bps * valuePerPoint(false) * 100 / 10_000`
    function _valueRate(uint256 bps) internal view returns (uint256) {
        (uint256 v,) = ctl.valuePerPoint(false);
        return bps * v * 100 / 10_000;
    }
}

contract ValueReferenceTest is ValueBase {
    // promise: SPEC 8 setBalancePoolKey starts the reference at the spot, in the owner's transaction
    function test_referenceStartsAtTheSpot() public view {
        assertEq(ctl.refPrice(), _spotOf(SP));
        assertEq(ctl.refTime(), block.timestamp);
    }

    // promise: SPEC 8 an update moves the reference toward the spot by at most rateBpsPerHour times the elapsed time
    function test_observeMovesAtMostTheRate() public {
        uint256 ref0 = ctl.refPrice();
        _poolState(_sqrtOf(ref0 * 2), LIQ); // the spot doubles
        vm.warp(block.timestamp + 30 minutes);
        ctl.observe();
        assertEq(ctl.refPrice(), ref0 * 10_500 / 10_000, "half an hour at 1,000 bps an hour moves 5 percent");
        vm.warp(block.timestamp + 1 hours);
        ctl.observe();
        assertEq(ctl.refPrice(), ref0 * 10_500 / 10_000 * 11_000 / 10_000, "a full hour moves 10 percent more");
    }

    // promise: SPEC 8 a long idle gains one step, the maxStepBps bound
    function test_longIdleGainsOneStep() public {
        uint256 ref0 = ctl.refPrice();
        _poolState(_sqrtOf(ref0 / 2), LIQ); // the spot halves
        vm.warp(block.timestamp + 20 hours);
        ctl.observe();
        assertEq(ctl.refPrice(), ref0 * 9_000 / 10_000, "twenty idle hours move one step of 10 percent");
    }

    // promise: SPEC 8 repeated updates gain nothing beyond the rate: a block by block spam over an hour stays within the
    // compounded rate of one update over the same hour
    function test_spamGainsNothingBeyondTheRate() public {
        uint256 ref0 = ctl.refPrice();
        _poolState(_sqrtOf(ref0 * 2), LIQ);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 300; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            ctl.observe();
            ctl.observe(); // a second call in the same second moves nothing
        }
        uint256 spammed = ctl.refPrice();
        vm.revertToState(snap);
        vm.warp(block.timestamp + 3_600);
        ctl.observe();
        uint256 once = ctl.refPrice();
        assertEq(once, ref0 * 11_000 / 10_000, "one update after an hour");
        // 300 steps of 3.33 bps compound to at most e^(0.1) of the reference, 0.52 percent above one step of 10 percent
        assertLe(spammed, ref0 * 11_052 / 10_000, "the spam stays within the compounded rate");
    }

    // promise: SPEC 8 the protected prices: buys off min(spot, ref + tol), sales off max(spot, ref - tol)
    function test_protectedPricesAtSpotAboveAndBelow() public {
        uint256 ref = ctl.refPrice();
        uint256 unitPoint = POINT_UNIT * UNIT;
        _poolState(_sqrtOf(ref * 2), LIQ); // spot far above the reference
        (uint256 buyHi,) = ctl.valuePerPoint(false);
        (uint256 sellHi,) = ctl.valuePerPoint(true);
        assertEq(buyHi, unitPoint * (ref * 10_500 / 10_000) / 1e18, "a pushed up spot buys at the reference plus the band");
        assertGe(sellHi, unitPoint * ref * 2 / 1e18 * 9_999 / 10_000, "and sells at the spot");
        _poolState(_sqrtOf(ref / 2), LIQ); // spot far below
        (uint256 buyLo,) = ctl.valuePerPoint(false);
        (uint256 sellLo,) = ctl.valuePerPoint(true);
        assertLe(buyLo, unitPoint * ref / 2 / 1e18 * 10_001 / 10_000, "a pushed down spot buys at the spot");
        assertEq(sellLo, FullMath.mulDivRoundingUp(unitPoint, ref * 9_500 / 10_000, 1e18), "and sells at the reference less the band");
        assertLt(buyLo, sellLo, "the buy value stays under the sale value");
    }

    // promise: SPEC 8 the quote is unusable beyond maxStale, under minLiquidity, with no module unit, or with maxStale 0
    function test_unusableStates() public {
        (, bool ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "fresh and deep");
        vm.warp(block.timestamp + 1 days + 1);
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "stale beyond maxStale");
        ctl.observe();
        (, ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "an update refreshes it");
        _poolState(SP, 1e18 - 1);
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "liquidity under the minimum");
        _poolState(SP, LIQ);
        mod.setRevertUnit(true);
        (, ok) = ctl.valuePerPoint(true);
        assertFalse(ok, "a failing unit read");
        mod.setRevertUnit(false);
        _setQuote(Quote({rateBpsPerHour: 1_000, maxStepBps: 1_000, tolBps: 500, maxStale: 0, minLiquidity: 1e18}));
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "maxStale 0, the launch placeholder, keeps it unusable");
    }

    // promise: INTEGRATION BadSetting on setQuote and OnlyOwner
    function test_setQuoteBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("maxStepBps")));
        ctl.setQuote(Quote({rateBpsPerHour: 1, maxStepBps: 10_001, tolBps: 0, maxStale: 1, minLiquidity: 0}));
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("tolBps")));
        ctl.setQuote(Quote({rateBpsPerHour: 1, maxStepBps: 10_000, tolBps: 10_000, maxStale: 1, minLiquidity: 0}));
        ctl.setQuote(Quote({rateBpsPerHour: type(uint32).max, maxStepBps: 10_000, tolBps: 9_999, maxStale: type(uint32).max, minLiquidity: type(uint128).max}));
        vm.stopPrank();
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setQuote(Quote({rateBpsPerHour: 1, maxStepBps: 1, tolBps: 1, maxStale: 1, minLiquidity: 0}));
    }
}

contract ValueModeTest is ValueBase {
    // promise: SPEC 4 the launch keeps value mode off and the quote placeholders unusable
    function test_launchValues() public view {
        Settings memory s = core.settings();
        assertFalse(s.valueModeOn, "value mode off at launch");
        assertEq(lc.quote.tolBps, 500, "the launch band");
        assertEq(lc.quote.maxStale, 0, "maxStale an owner input, unusable until set");
    }

    // promise: SPEC 4 the switch resets the shared instance to its floor and prices the eth bid off it
    function test_switchResetsTheSharedInstanceAndPricesTheBid() public {
        _fundPot(20 ether);
        _warp(2 hours);
        _valueOn();
        assertEq(core.balanceRate(), 9_000, "the switch opens the shared instance at the floor");
        assertEq(core.ethRate(), _valueRate(9_000), "the eth bid is the shared rate times the value per point");
        assertEq(core.ethPrice(), _valueRate(9_000));
        uint256[] memory ids = _credits(seller, 1);
        assertEq(core.bidOf(ids[0]), core.ethRate() * _scoreOf(ids[0]) / RATE_SCORE, "per credit by score");
    }

    // promise: SPEC 4 an eth fill and a balance fill drop the one shared instance; switching currency cannot reset it
    function test_bothRoutesDropTheOneInstance() public {
        _valueOn();
        _fundPot(20 ether);
        _warp(30 minutes);
        uint256 r0 = core.balanceRate();
        uint256[] memory ids = _credits(seller, 2);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        uint256 r1 = core.balanceRate();
        assertLt(r1, r0, "an eth fill drops the shared instance");
        vm.prank(seller);
        core.sellForBalance(_one(ids[1]));
        uint256 r2 = core.balanceRate();
        assertLt(r2, r1, "a balance fill drops the same instance");
        assertEq(core.ethRate(), _valueRate(r2), "and the eth bid reads it");
    }

    // promise: SPEC 4 in value mode the shared instance climbs with the balance bid off and with no usable module, and
    // only the switch and the bid turning on reset it: a settings edit and a module set leave it
    function test_onlyTheSwitchAndTheBidTurningOnReset() public {
        Settings memory s = core.settings();
        s.balanceBidOn = false;
        _setSettings(s);
        _valueOn();
        _warp(30 minutes);
        uint256 climbed = core.balanceRate();
        assertGt(climbed, 9_000, "the shared instance climbs in value mode with the balance bid off");
        s = core.settings();
        s.climbPerMinBps = 50;
        s.recoveryClimbPerMinBps = 50;
        _setSettings(s);
        assertEq(core.balanceRate(), climbed, "a settings edit does not reset it");
        _setBalanceModule(address(mod));
        assertEq(core.balanceRate(), climbed, "a module set does not reset it");
        s = core.settings();
        s.balanceBidOn = true;
        _setSettings(s);
        assertEq(core.balanceRate(), 9_000, "the bid turning on resets it to the floor");
    }

    // promise: SPEC 4 an unusable quote halts the eth routes only: sellForEth and the controller sale doors revert
    // NoQuote; sellForBalance, compose, redeemStatement, buyback and book stay live
    function test_staleQuoteHaltsTheEthRoutesOnly() public {
        Composed memory c = _composeOnce();
        _valueOn();
        _fundPot(20 ether);
        vm.warp(block.timestamp + 1 days + 1); // the reference is stale
        uint256[] memory ids = _credits(seller, 2);
        vm.prank(seller);
        vm.expectRevert(ICore.NoQuote.selector);
        core.sellForEth(_one(ids[0]));
        vm.expectRevert(ICore.NoQuote.selector);
        core.ethRate();
        vm.prank(seller);
        core.sellForBalance(_one(ids[1]));
        core.book();
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "conversion runs by age, no quote read");
    }

    // promise: SPEC 1 a hostile controller quoting a huge value pays at most rateCap and cannot move the balance bid; a
    // zero quote halts the eth bid and leaves conversion and the balance bid live
    function test_hostileQuoteIsBounded() public {
        _valueOn();
        _fundPot(20 ether);
        QuoteController q = new QuoteController(address(core), address(ctl));
        _setController(address(q));
        q.setValue(type(uint256).max, true);
        assertEq(core.ethRate(), core.settings().rateCap, "a huge quote pays the rate cap");
        uint256 bal0 = core.balanceRate();
        q.setValue(0, true);
        vm.expectRevert(ICore.NoQuote.selector);
        core.ethRate();
        q.setValue(1e13, false);
        vm.expectRevert(ICore.NoQuote.selector);
        core.ethRate();
        assertEq(core.balanceRate(), bal0, "the quote never moves the balance bid");
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
    }

    // promise: SPEC 8 in value mode a credit's floor is valueOf(score) times floorMultBps with the cost dropped, and a
    // buy at that floor sold back into the eth bid at its hard cap loses at least the spread
    function test_valueFloorClosesTheRoundTrip() public {
        uint256 id = _fillEthPile(1)[0];
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        ctl.observe();
        uint256 score = _scoreOf(id);
        (uint256 vSell,) = ctl.valuePerPoint(true);
        assertEq(ctl.valueOf(score), FullMath.mulDivRoundingUp(score * UNIT, _spotOf(SP) > ctl.refPrice() * 9_500 / 10_000 ? _spotOf(SP) : ctl.refPrice() * 9_500 / 10_000, 1e18), "valueOf is the protected sale value");
        uint256 price = ctl.creditPrice(id);
        assertEq(price, ctl.valueOf(score) * ctl.floorMultBps() / 10_000, "the floor drops the cost term");
        assertEq(ctl.floorMultBps(), 11_220, "the spread of 200 over the hard cap of 11,000");
        // the most the eth bid pays for this credit: the shared instance at the hard cap times the buy value
        (uint256 vBuy,) = ctl.valuePerPoint(false);
        uint256 mostPaid = 11_000 * vBuy * score / POINT_UNIT / 10_000;
        assertGe(price, mostPaid * 10_200 / 10_000, "the floor clears the bid's ceiling by the spread");
        assertLe(vBuy, vSell, "the buy value is under the sale value");
    }

    /// a buyer of the engine's credits that sells each one straight back
    address internal constant TRIPPER = address(0x7419);

    /// buys pile credit `id` at its sale price through `buyCredit` after an `observe()`, then in the next second sells
    /// it back through the eth door or the balance door. `back` is the eth received, or the balance token received
    /// valued at the pool spot
    function _trip(uint256 id, bool viaBalance) internal returns (uint256 paid, uint256 back) {
        ctl.observe();
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        paid = price * 2 - TRIPPER.balance;
        _nextSecond();
        _tripBack(id, viaBalance);
        uint256 got = xt.balanceOf(TRIPPER);
        back = viaBalance ? got * _spotNow() / 1e18 : TRIPPER.balance - (price * 2 - paid);
        if (got != 0) {
            vm.prank(TRIPPER);
            xt.transfer(address(0xdead), got);
        }
    }

    function _tripBack(uint256 id, bool viaBalance) internal {
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        if (viaBalance) core.sellForBalance(_one(id));
        else core.sellForEth(_one(id));
        vm.stopPrank();
    }

    function _spotNow() internal view returns (uint256 spot) {
        (spot,) = ctl.spotPrice();
    }

    /// a round trip loses at least the spread: what comes back is at most the price paid over (10_000 + spreadBps),
    /// within one wei of the price's rounding. at the hard cap the bound is exact, so the floored price can sit one wei
    /// under the spread over the bid's most
    function _assertLoses(uint256 paid, uint256 back, string memory state) internal view {
        assertGt(back, 0, state);
        uint256 m = 10_000 + ctl.creditSpreadBps();
        assertLe(back * m, (paid + 1) * 10_000, state);
    }

    // promise: SPEC 10 round trips in both currencies at the floor, at the cap after a climb, in the next block, after
    // 20 idle minutes, across a currency switch, at spot above and below the reference and with the reference stale: a
    // credit bought from the engine and sold straight back loses at least the spread
    function test_roundTripsLoseTheSpread() public {
        uint256[] memory ids = _fillEthPile(16);
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
        uint256 k;
        (uint256 paid, uint256 back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth at the floor");
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance at the floor, across a currency switch");
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth in the next block, across a currency switch");
        _warp(20 minutes);
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance after 20 idle minutes");
        _warp(20 minutes);
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth after 20 idle minutes");
        _warp(6 hours);
        assertEq(core.balanceRate(), 11_000, "the shared instance climbed to the cap");
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth at the cap");
        _warp(6 hours);
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance at the cap");
        // the spot pushed up and down against the reference, the reference following at its rate
        uint256 ref = ctl.refPrice();
        uint160[2] memory moved = [_sqrtOf(ref * 3 / 2), _sqrtOf(ref * 6 / 10)];
        for (uint256 i; i < 2; ++i) {
            _poolState(moved[i], LIQ);
            _warp(6 hours);
            (paid, back) = _trip(ids[k++], false);
            _assertLoses(paid, back, i == 0 ? "eth at spot above the reference" : "eth at spot below the reference");
            _warp(6 hours);
            (paid, back) = _trip(ids[k++], true);
            _assertLoses(paid, back, i == 0 ? "balance at spot above the reference" : "balance at spot below the reference");
        }
        // the reference stale after the buy: the eth door refuses, the balance door still loses the spread
        _poolState(SP, LIQ);
        ctl.observe();
        uint256 id = ids[k++];
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price}(id);
        _warp(1 days + 1);
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        vm.expectRevert(ICore.NoQuote.selector);
        core.sellForEth(_one(id));
        vm.stopPrank();
        _tripBack(id, true);
        _assertLoses(price, xt.balanceOf(TRIPPER) * _spotNow() / 1e18, "balance with the reference stale");
    }

    // promise: SPEC 8 a statement's reference in value mode is valueOf(rating) times floorMultBps, its curve rests there
    function test_statementPricesOffTheProtectedFloor() public {
        Composed memory c = _composeOnce();
        _valueOn();
        uint256 ref = ctl.valueOf(core.ratingOf(c.sid)) * ctl.floorMultBps() / 10_000;
        assertEq(ctl.referenceOf(c.sid), ref);
        vm.warp(block.timestamp + uint256(ctl.decayHours()) * 1 hours);
        ctl.observe();
        ref = ctl.valueOf(core.ratingOf(c.sid)) * ctl.floorMultBps() / 10_000;
        assertEq(ctl.priceOf(c.sid), ref, "the aged curve rests at the protected floor, not at saleFloorBps");
    }

    // promise: SPEC 8 the controller sale doors move the reference before they price
    function test_saleDoorsObserve() public {
        uint256 id = _fillEthPile(1)[0];
        _setCreditSaleOn(true);
        uint256 ref0 = ctl.refPrice();
        _poolState(_sqrtOf(ref0 * 2), LIQ);
        vm.warp(block.timestamp + 1 hours);
        uint256 price = ctl.creditPrice(id);
        vm.deal(seller, price * 2);
        vm.prank(seller);
        ctl.buyCredit{value: price * 2}(id);
        assertEq(ctl.refPrice(), ref0 * 11_000 / 10_000, "buyCredit moved the reference one hour of rate");
        assertEq(ctl.refTime(), block.timestamp);
    }

    // promise: INTEGRATION gas of the eth door with the extra value read: a one credit sellForEth in value mode costs at
    // most 150,000 gas over the same sale outside it (the controller's bounded read, the module's unit and available)
    function test_sellForEthGasInValueMode() public {
        _fundPot(20 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 snap = vm.snapshotState();
        vm.prank(seller);
        uint256 g = gasleft();
        core.sellForEth(ids);
        uint256 plain = g - gasleft();
        vm.revertToState(snap);
        _valueOn();
        vm.prank(seller);
        g = gasleft();
        core.sellForEth(ids);
        uint256 valued = g - gasleft();
        emit log_named_uint("sellForEth gas, one credit, eth instance", plain);
        emit log_named_uint("sellForEth gas, one credit, value mode", valued);
        assertLt(valued, plain + 150_000, "the value read costs at most 150,000 gas a credit");
    }
}
