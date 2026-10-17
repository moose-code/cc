// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";

/// promise: SPEC 4 with value mode off the engine prices exactly as main does. this is a differential guard: it
/// recomputes the bid, climb, drop, ceiling, credit sale price and statement decay from the launch settings (main's
/// rules) and asserts the contract matches, so a value mode change cannot leak into the mode off paths. value mode is
/// off in the default fixture. the climb and ceiling arithmetic mirrors BidRule; the credit and statement curves mirror
/// CreditSale and Sale
contract ModeOffDifferentialTest is Fixture {
    uint256 internal constant BPS = 10_000;

    function _recoveryEqualsClimb() internal {
        Settings memory s = core.settings();
        s.recoveryClimbPerMinBps = s.climbPerMinBps;
        _setSettings(s);
    }

    // the eth bid is the price state per 100 points times the score: rate * score / RATE_SCORE (1e6)
    function test_bidIsPerPoint() public {
        _fundPot(10 ether);
        assertFalse(core.settings().valueModeOn, "value mode off");
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        uint256 rate = core.ethRate();
        assertEq(core.bidOf(ids[0]), rate * score / RATE_SCORE, "bidOf is the per-point rate times the score");
        assertEq(core.bidForScore(score), rate * score / RATE_SCORE, "bidForScore matches");
        assertEq(core.ethPerPoint(), rate / 100, "ethPerPoint is the rate over 100 points");
    }

    // a fill drops the price state by dropPer100PointsBps per 100 points: a unit-score credit drops it 115 bps
    function test_dropIsTheLaunchDrop() public {
        _fundPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        uint256 r0 = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 drop = core.settings().dropPer100PointsBps;
        assertEq(core.rateAtCheckpoint(), r0 * (BPS - drop) / BPS, "the drop is dropPer100PointsBps of the rate paid");
        assertEq(drop, 115, "the launch drop");
    }

    // the price state climbs to the ceiling of 110 percent of the anchor and the anchor loosens 6 percent per full 10
    // idle minutes at a one page pot (the climb reaches it at climbPerMinBps 2 percent a minute)
    function test_climbCeilingAndLoosening() public {
        _recoveryEqualsClimb();
        assertEq(core.settings().ceilBps, 11_000, "ceiling 110 percent");
        assertEq(core.settings().climbPerMinBps, 200, "climb 2 percent a minute");
        assertEq(core.settings().idleLoosenBps, 600, "loosen 6 percent per 10 idle minutes");
        // a pot under one page keeps the pages multiplier at 1x, so the loosening is the base 6 percent
        _fundPot(0.1 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        vm.prank(seller);
        core.sellForEth(_one(id));
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        uint256 base = anchor * 11_000 / BPS;
        assertEq(core.ethRate(), base, "the climb holds at 110 percent before 10 idle minutes");
        // after a full idle interval the anchor loosens by idleLoosenBps scaled by the pages multiplier, so the ceiling
        // rises above the base 110 percent (the exact loosening by pot size is in BidRule)
        _warp(1);
        uint256 loosened = core.ethRate();
        assertGt(loosened, base, "the ceiling loosens above 110 percent after 10 idle minutes");
        _warp(10 minutes);
        assertGt(core.ethRate(), loosened, "and loosens further over another 10 idle minutes");
    }

    // a pile credit at acquisition is asked at creditStartBps (1.5x) of its floor; the floor is recomputed from the
    // contract's views at the same instant, so the comparison does not drift with the climbing floor rate
    function test_creditSaleStartIsOverTheFloor() public {
        _setCreditSaleOn(true);
        uint256 id = _fillEthPile(1)[0];
        (, uint256 cost, uint64 acquiredAt) = core.creditInfo(id);
        assertEq(acquiredAt, block.timestamp, "the credit is fresh, age zero");
        uint256 hi = ctl.valueOf(_scoreOf(id));
        if (cost > hi) hi = cost;
        uint256 floor = hi * ctl.floorMultBps() / BPS;
        uint256 coreFloor = cost * core.settings().saleFloorBps / BPS;
        if (floor < coreFloor) floor = coreFloor;
        assertEq(ctl.creditPrice(id), floor * ctl.creditStartBps() / BPS, "the start ask is creditStartBps of the floor");
        assertEq(ctl.creditStartBps(), 15_000, "the launch 1.5x start");
    }

    // a statement is asked at startBps of its reference at age zero and rests at saleFloorBps of the reference after
    // decayHours
    function test_statementDecay() public {
        Composed memory c = _composeOnce();
        // the reference moves with the climbing floor rate, so read it fresh at each age
        assertEq(ctl.priceOf(c.sid), ctl.referenceOf(c.sid) * ctl.startBps() / BPS, "the start ask is startBps of the reference");
        _warp(uint256(ctl.decayHours()) * 1 hours + 1);
        assertEq(
            ctl.priceOf(c.sid),
            ctl.referenceOf(c.sid) * core.settings().saleFloorBps / BPS,
            "the ask rests at saleFloorBps of the reference after decayHours"
        );
        assertEq(ctl.decayHours(), 4, "the launch 4 hour decay");
    }
}
