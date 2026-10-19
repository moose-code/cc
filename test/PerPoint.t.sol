// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// @notice the per-point eth bid: every eth door prices a credit at
/// `ethRate() * score / RATE_SCORE` (100 points), and a fill drops the rate by `dropPer100PointsBps * score / RATE_SCORE`.
/// the balance side and the statement reference already read the score; the eth doors scale the bid and the drop by
/// `score / RATE_SCORE`
contract PerPointTest is Fixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("per point");
    }

    // promise: SPEC 4 bidOf is the rate times the credit's score over 100 points (RATE_SCORE)
    function test_bidOfScalesTheRateByScoreOver100Points() public {
        _fundPot(20 ether);
        uint256[] memory ids = _credits(user, 4);
        uint256 rate = core.ethRate();
        uint256 ref = RATE_SCORE;
        for (uint256 i; i < ids.length; ++i) {
            assertEq(core.bidOf(ids[i]), rate * _scoreOf(ids[i]) / ref, "bidOf is rate times score over 100 points");
            assertGt(_scoreOf(ids[i]), 0, "the score is never zero");
        }
    }

    // promise: SPEC 4 a credit richer than 100 points is bid more than one poorer
    function test_aRicherCreditIsBidMore() public {
        _fundPot(20 ether);
        uint256[] memory ids = _credits(user, 8);
        uint256 lo = ids[0];
        uint256 hi = ids[0];
        for (uint256 i = 1; i < ids.length; ++i) {
            if (_scoreOf(ids[i]) < _scoreOf(lo)) lo = ids[i];
            if (_scoreOf(ids[i]) > _scoreOf(hi)) hi = ids[i];
        }
        if (_scoreOf(hi) > _scoreOf(lo)) assertGt(core.bidOf(hi), core.bidOf(lo), "the richer credit is bid more");
    }

    // promise: SPEC 6 sellForEth pays the per-credit bid and drops the rate by dropPer100PointsBps times score over 100 points (RATE_SCORE)
    function test_sellForEthPaysThePerCreditBidAndScalesTheDrop() public {
        _fundPot(20 ether);
        uint256 id = _credits(user, 1)[0];
        uint256 score = _scoreOf(id);
        uint256 ref = RATE_SCORE;
        uint256 rate = core.ethRate();
        uint256 want = rate * score / ref;
        assertEq(core.bidOf(id), want, "bidOf matches the door");

        uint256 before = user.balance;
        vm.prank(user);
        core.sellForEth(_one(id));
        assertEq(user.balance - before, want, "the seller is paid the per-credit bid");
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, want + want * core.settings().buyToArtistBps / 10_000, "the cost basis is the per-credit bid plus its royalty");

        uint256 fallNum = uint256(core.settings().dropPer100PointsBps) * score;
        uint256 denom = 10_000 * ref;
        uint256 dropped = fallNum >= denom ? 0 : rate * (denom - fallNum) / denom;
        uint256 floor = rate * core.settings().dropFloorBps / 10_000;
        assertEq(core.rateAtCheckpoint(), dropped > floor ? dropped : floor, "the drop scales by score over 100 points");
    }

    // promise: SPEC 4 adopt records the price state times the credit's score over 100 points (RATE_SCORE)
    function test_adoptBasisScalesByScore() public {
        _fundPot(5 ether);
        uint256 id = _credits(user, 1)[0];
        vm.prank(user);
        CREDITS.transferFrom(user, address(core), id);
        uint256 price = core.ethPrice();
        uint256 ref = RATE_SCORE;
        core.adopt(_one(id));
        (, uint256 cost,) = core.creditInfo(id);
        uint256 pay = price * _scoreOf(id) / ref;
        uint256 want = pay + pay * core.settings().buyToArtistBps / 10_000;
        if (want == 0) want = 1;
        assertEq(cost, want, "the adopt basis is the price state scaled by score plus the artist royalty");
    }
}
