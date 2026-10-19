// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE, Settings} from "../src/interfaces/Interfaces.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// @notice exact per-point amounts at scores other than 100 points. every expected value is hand derived from
/// `rate * score / RATE_SCORE` and the scaled drop, never read back from `bidOf`. the ratio-1 mechanics are in
/// BidRule.t.sol; these cover the scaling the ratio-1 tests cannot see. a credit's score is mocked to the exact value
/// a ratio needs, so `score / RATE_SCORE` is that ratio
contract PerPointExactTest is Fixture {
    using stdStorage for StdStorage;

    address internal who;

    function setUp() public override {
        super.setUp();
        who = _user("exact");
    }

    // the price state after one credit of score `s` bought at state `r`, minute start `start` (CoreLib.drop by hand)
    function _dropHand(uint256 r, uint256 s, uint256 start) internal view returns (uint256) {
        uint256 drop = core.settings().dropPer100PointsBps;
        uint256 floorBps = core.settings().dropFloorBps;
        // one rounding, fall rounded up: rate = r * (10_000 * RATE_SCORE - drop * s) / (10_000 * RATE_SCORE)
        uint256 fallNum = drop * s;
        uint256 denom = 10_000 * RATE_SCORE;
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

    // promise: SPEC 4 CoreLib.drop scales the fall by score / RATE_SCORE, at two ratios, by hand arithmetic
    function test_drop_scalesTheFallAtRatioTwoAndRatioHalf() public {
        uint256 R = 1e16;
        // ratio 2: the score is twice 100 points, so the fall is 2 * dropPer100PointsBps
        uint256 id2 = _credits(who, 1)[0];
        _mockScore(id2, 2 * RATE_SCORE);
        _armRate(R);
        assertEq(core.bidOf(id2), (R * 2 * RATE_SCORE) / RATE_SCORE, "ratio 2 doubles the bid");
        vm.prank(who);
        core.sellForEth(_one(id2));
        assertEq(
            core.rateAtCheckpoint(), _dropHand(R, 2 * RATE_SCORE, R), "ratio 2: the fall is 2 * dropPer100PointsBps"
        );

        // ratio 1/2: the score is half 100 points, so the fall is dropPer100PointsBps / 2
        uint256 idH = _credits(who, 1)[0];
        _mockScore(idH, RATE_SCORE / 2);
        _armRate(R);
        vm.prank(who);
        core.sellForEth(_one(idH));
        assertEq(
            core.rateAtCheckpoint(), _dropHand(R, RATE_SCORE / 2, R), "ratio 1/2: the fall is dropPer100PointsBps / 2"
        );
    }

    // promise: SPEC 6 a batch of three differing scores pays each credit its scaled bid and drops the rate per credit
    function test_batchOfThree_eachPayoutAndRateAfterInCallOrder() public {
        uint256 R = 1e16;
        uint256[] memory ids = _credits(who, 3);
        uint256[3] memory s = [uint256(700_000), 1_300_000, 2_200_000];
        for (uint256 i; i < 3; ++i) {
            _mockScore(ids[i], s[i]);
            assertTrue(s[i] != RATE_SCORE, "the scores are not 100 points");
        }
        _armRate(R);

        uint256 snap = vm.snapshotState();
        uint256 fwd = _expectBatch(ids, s, R);
        vm.revertToState(snap);

        uint256[] memory rev = new uint256[](3);
        (rev[0], rev[1], rev[2]) = (ids[2], ids[1], ids[0]);
        uint256[3] memory sr = [s[2], s[1], s[0]];
        uint256 back = _expectBatch(rev, sr, R);

        // the per-credit payouts and the rate after each fill depend on the order (asserted in `_expectBatch`); the
        // batch total is order independent up to the one-wei rounding of each per-credit drop
        assertApproxEqAbs(fwd, back, 1, "the batch total is order independent up to one wei");
    }

    // sells `ids` in order, asserts each payout, the rate after each fill and the cost basis, and returns the total paid
    function _expectBatch(uint256[] memory ids, uint256[3] memory s, uint256 R) internal returns (uint256 total) {
        uint256 r = R;
        uint256[3] memory pay;
        for (uint256 i; i < 3; ++i) {
            pay[i] = (r * s[i]) / RATE_SCORE;
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
            assertEq(c, pay[i] + pay[i] * core.settings().buyToArtistBps / 10_000, "the cost basis is the scaled bid plus its royalty");
        }
    }

    // promise: SPEC 4 a ratio above 1 reaches the bucket floor in fewer fills than the ratio-1 count (139 in BidRule)
    function test_bucketFloor_reachedInFewerFillsAtRatioAboveOne() public {
        uint256 R = 1e16;
        uint256[] memory ids = _credits(who, 300);
        // a real minute floor, so the compounding drop rests on it (launch dropFloorBps is 1, no practical floor)
        Settings memory st = core.settings();
        st.dropFloorBps = 5_000;
        _setSettings(st);
        _armRate(R);
        uint256 floor = (R * core.settings().dropFloorBps) / 10_000;
        uint256 fills;
        for (uint256 i; i < ids.length; ++i) {
            // the score twice 100 points, so each fall is 2 * dropPer100PointsBps: the floor is reached sooner
            _mockScore(ids[i], 2 * RATE_SCORE);
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
        // a price state of 1 wei and a score below 100 points makes price * score / RATE_SCORE round to 0; adopt records 1
        uint256 id = _credits(who, 1)[0];
        _mockScore(id, RATE_SCORE / 2);
        stdstore.target(address(core)).sig("rateAtCheckpoint()").checked_write(uint256(1));
        assertEq(core.ethPrice(), 1, "the price state is 1 wei");
        vm.prank(who);
        CREDITS.transferFrom(who, address(core), id);
        core.adopt(_one(id));
        (, uint256 cost,) = core.creditInfo(id);
        assertEq((1 * (RATE_SCORE / 2)) / RATE_SCORE, 0, "the scaled price rounds to 0");
        assertEq(cost, 1, "adopt records the 1 wei floor");
    }

    // promise: SPEC 4 the payout and the cost basis floor (round down) at a chosen remainder
    function test_rounding_payoutAndCostBasisRoundDown() public {
        // a rate and score whose product is not a multiple of RATE_SCORE, so the division has a remainder
        uint256 id = _credits(who, 1)[0];
        uint256 s = 1_333_333;
        _mockScore(id, s);
        uint256 R = 1e16 + 1;
        _armRate(R);
        uint256 floored = (R * s) / RATE_SCORE;
        assertTrue(floored * RATE_SCORE < R * s, "the division has a nonzero remainder");
        uint256 before = who.balance;
        vm.prank(who);
        core.sellForEth(_one(id));
        assertEq(who.balance - before, floored, "the payout rounds down");
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, floored + floored * core.settings().buyToArtistBps / 10_000, "the cost basis rounds down, plus its royalty");
    }

    // promise: SPEC 8 the credit sale floor term valueOf(score) floors floorRate * score / RATE_SCORE
    function test_rounding_creditSaleFloorValueRoundsDown() public {
        uint256 id = _credits(who, 1)[0];
        uint256 s = 1_333_333;
        _mockScore(id, s);
        _liftRateCap();
        uint256 R = 1e16 + 1;
        vm.prank(owner);
        core.setRate(R);
        assertEq(core.floorRate(), R, "floorRate is the restated rate");
        uint256 floored = (R * s) / RATE_SCORE;
        assertEq(ctl.valueOf(s), floored, "valueOf floors floorRate * score / RATE_SCORE");
        assertTrue(floored * RATE_SCORE < R * s, "a nonzero remainder, so it rounded down");
    }

    // promise: SPEC 1 the credit sale floor price is above the sellForEth payout at the rounding boundary, so a round
    // trip would lose even before the same block return guard refuses it
    function test_rounding_buyAtTheFloorIsAboveTheSellForEthPayout() public {
        uint256 id = _fillEthPile(1)[0];
        _mockScore(id, 1_333_333); // a remainder in both the credit sale floor and the sellForEth payout
        _liftRateCap();
        vm.prank(owner);
        core.setRate(1e16); // a rate far above the recorded cost, so the floor rests on the rate term
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow()); // the price rests at the floor
        uint256 price = ctl.creditPrice(id);
        assertLt(core.bidOf(id), price, "the floor buy price is above the sellForEth payout: no 1 wei profit");
    }
}
