// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// @notice exact per-point amounts at scores that are not refScore (decision 116). every expected value is hand derived
/// from `rate * score / refScore` and the scaled drop, never read back from `bidOf`. the ratio-1 mechanics are in
/// BidRule.t.sol; these cover the scaling the ratio-1 tests cannot see
contract PerPointExactTest is Fixture {
    using stdStorage for StdStorage;

    address internal who;

    function setUp() public override {
        super.setUp();
        who = _user("exact");
    }

    // the price state after one credit of score `s` bought at state `r`, minute start `start` (CoreLib.drop by hand)
    function _dropHand(uint256 r, uint256 s, uint256 start) internal view returns (uint256) {
        uint256 drop = core.settings().dropPerCreditBps;
        uint256 floorBps = core.settings().dropFloorBps;
        uint256 ref = core.settings().refScore;
        // one rounding, fall rounded up: rate = r * (10_000 * ref - drop * s) / (10_000 * ref)
        uint256 fallNum = drop * s;
        uint256 denom = 10_000 * ref;
        uint256 dropped = fallNum >= denom ? 0 : (r * (denom - fallNum)) / denom;
        uint256 floor = (start * floorBps) / 10_000;
        return dropped > floor ? dropped : floor;
    }

    // a funded engine with the price state restated to `r` in a fresh minute, so the first fill sets the minute start to `r`
    function _armRate(uint256 r) internal {
        _liftRateCap();
        _fundPot(500 ether);
        _warp(2 hours);
        vm.prank(owner);
        core.setRate(r);
    }

    // promise: SPEC 4 CoreLib.drop scales the fall by score / refScore, at two ratios, by hand arithmetic
    function test_drop_scalesTheFallAtRatioTwoAndRatioHalf() public {
        uint256 R = 1e16;
        // ratio 2: refScore is half the credit's score, so the fall is 2 * dropPerCreditBps (1 percent at launch)
        uint256 id2 = _credits(who, 1)[0];
        uint256 s2 = _scoreOf(id2);
        _setRefScore(uint32(s2 / 2));
        _armRate(R);
        assertEq(s2 % 2, 0, "the fixture credit score is even, so refScore = score / 2 is exactly half");
        assertEq(core.bidOf(id2), (R * s2) / (s2 / 2), "ratio 2 doubles the bid");
        vm.prank(who);
        core.sellForEth(_one(id2));
        assertEq(core.rateAtCheckpoint(), (R * 9_900) / 10_000, "ratio 2: the fall is 2 * 50 bps = 100 bps, 1 percent");

        // ratio 1/2: refScore is twice the credit's score, so the fall is 25 bps
        uint256 idH = _credits(who, 1)[0];
        uint256 sH = _scoreOf(idH);
        _setRefScore(uint32(sH * 2));
        _armRate(R);
        vm.prank(who);
        core.sellForEth(_one(idH));
        assertEq(core.rateAtCheckpoint(), (R * 9_975) / 10_000, "ratio 1/2: the fall is 50 / 2 = 25 bps");
    }

    // promise: SPEC 6 a batch of three differing scores pays each credit its scaled bid and drops the rate per credit
    function test_batchOfThree_eachPayoutAndRateAfterInCallOrder() public {
        uint256 R = 1e16;
        uint256 ref = core.settings().refScore;
        uint256[] memory ids = _credits(who, 3);
        uint256[3] memory s = [_scoreOf(ids[0]), _scoreOf(ids[1]), _scoreOf(ids[2])];
        assertTrue(s[0] != ref && s[1] != ref && s[2] != ref, "the fork scores are not refScore");
        assertTrue(s[0] != s[1] && s[1] != s[2] && s[0] != s[2], "the three scores differ");
        _armRate(R);

        uint256 snap = vm.snapshotState();
        uint256 fwd = _expectBatch(ids, s, R, ref);
        vm.revertToState(snap);

        uint256[] memory rev = new uint256[](3);
        (rev[0], rev[1], rev[2]) = (ids[2], ids[1], ids[0]);
        uint256[3] memory sr = [s[2], s[1], s[0]];
        uint256 back = _expectBatch(rev, sr, R, ref);

        // the per-credit payouts and the rate after each fill depend on the order (asserted in `_expectBatch`); the
        // batch total does not, since the one-rounding drop is symmetric in the scores
        assertEq(fwd, back, "the batch total is order independent");
    }

    // sells `ids` in order, asserts each payout, the rate after each fill and the cost basis, and returns the total paid
    function _expectBatch(uint256[] memory ids, uint256[3] memory s, uint256 R, uint256 ref) internal returns (uint256 total) {
        uint256 r = R;
        uint256[3] memory pay;
        for (uint256 i; i < 3; ++i) {
            pay[i] = (r * s[i]) / ref;
            r = _dropHand(r, s[i], R);
        }
        uint256 before = who.balance;
        vm.prank(who);
        core.sellForEth(ids);
        total = who.balance - before;
        assertEq(total, pay[0] + pay[1] + pay[2], "the batch pays the sum of the scaled bids");
        assertEq(core.rateAtCheckpoint(), r, "the rate reflects three scaled drops in order");
        for (uint256 i; i < 3; ++i) {
            (, uint256 c,) = core.creditInfo(ids[i]);
            assertEq(c, pay[i], "the cost basis is the credit's scaled bid");
        }
    }

    // promise: SPEC 4 a ratio above 1 reaches the minute floor in fewer fills than the ratio-1 count (139 in BidRule)
    function test_minuteFloor_reachedInFewerFillsAtRatioAboveOne() public {
        uint256 R = 1e16;
        uint256[] memory ids = _credits(who, 300);
        _armRate(R);
        uint256 floor = (R * core.settings().dropFloorBps) / 10_000;
        uint256 fills;
        for (uint256 i; i < ids.length; ++i) {
            uint256 sc = _scoreOf(ids[i]);
            // refScore half the score (an even score at least 1_600_000 so refScore stays at or above its 800_000
            // bound), so each fall is 1 percent: the floor is reached in about 69 fills
            if (sc < 1_600_000 || sc % 2 != 0) continue;
            _setRefScore(uint32(sc / 2));
            vm.prank(who);
            core.sellForEth(_one(ids[i]));
            fills++;
            if (core.rateAtCheckpoint() == floor) break;
        }
        assertEq(core.rateAtCheckpoint(), floor, "the rate sits on the minute floor");
        assertLt(fills, 139, "fewer fills than the ratio-1 count");
        assertGt(fills, 1, "more than one fill");
    }

    // promise: SPEC 4 adopt floors the scaled price state at 1 wei when the product rounds below 1
    function test_adopt_oneWeiFloorWhenTheScaledPriceRoundsToZero() public {
        // a price state of 1 wei and a score below refScore makes price * score / refScore round to 0; adopt records 1
        uint256 id = _credits(who, 1)[0];
        _setRefScore(8_000_000);
        assertLt(_scoreOf(id), 8_000_000, "the score is below refScore");
        stdstore.target(address(core)).sig("rateAtCheckpoint()").checked_write(uint256(1));
        assertEq(core.ethPrice(), 1, "the price state is 1 wei");
        vm.prank(who);
        CREDITS.transferFrom(who, address(core), id);
        core.adopt(_one(id));
        (, uint256 cost,) = core.creditInfo(id);
        assertEq((1 * _scoreOf(id)) / 8_000_000, 0, "the scaled price rounds to 0");
        assertEq(cost, 1, "adopt records the 1 wei floor");
    }

    // promise: SPEC 4 the payout and the cost basis floor (round down) at a chosen remainder
    function test_rounding_payoutAndCostBasisRoundDown() public {
        // refScore is one above the score, so rate * score / refScore has a remainder and floors below the exact value
        uint256 id = _credits(who, 1)[0];
        uint256 s = _scoreOf(id);
        _setRefScore(uint32(s + 1));
        uint256 R = 1e16;
        _armRate(R);
        uint256 floored = (R * s) / (s + 1);
        assertTrue(floored * (s + 1) < R * s, "the division has a nonzero remainder");
        assertEq(floored * (s + 1) + (R * s) % (s + 1), R * s, "floored is the floor of rate * score / refScore");
        uint256 before = who.balance;
        vm.prank(who);
        core.sellForEth(_one(id));
        assertEq(who.balance - before, floored, "the payout rounds down");
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, floored, "the cost basis rounds down");
    }

    // promise: SPEC 8 the credit sale floor term valueOf(score) floors floorRate * score / refScore
    function test_rounding_creditSaleFloorValueRoundsDown() public {
        uint256 id = _credits(who, 1)[0];
        uint256 s = _scoreOf(id);
        _setRefScore(uint32(s + 1));
        _liftRateCap();
        uint256 R = 1e16;
        vm.prank(owner);
        core.setRate(R);
        assertEq(core.floorRate(), R, "floorRate is the restated rate");
        uint256 floored = (R * s) / (s + 1);
        assertEq(ctl.valueOf(s), floored, "valueOf floors floorRate * score / refScore");
        assertTrue(floored * (s + 1) < R * s, "a nonzero remainder, so it rounded down");
    }

    // promise: SPEC 1 the credit sale floor price is above the sellForEth payout at the rounding boundary, so a round
    // trip would lose even before the same block return guard refuses it
    function test_rounding_buyAtTheFloorIsAboveTheSellForEthPayout() public {
        uint256 id = _fillEthPile(1)[0];
        uint256 s = _scoreOf(id);
        _setRefScore(uint32(s + 1)); // a remainder in both the credit sale floor and the sellForEth payout
        _liftRateCap();
        vm.prank(owner);
        core.setRate(1e16); // a rate far above the recorded cost, so the floor rests on the rate term
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow()); // the price rests at the floor
        uint256 price = ctl.creditPrice(id);
        assertLt(core.bidOf(id), price, "the floor buy price is above the sellForEth payout: no 1 wei profit");
    }
}
