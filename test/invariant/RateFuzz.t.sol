// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {Settings, RATE_START_MAX_WEI} from "../../src/interfaces/Interfaces.sol";
import {Fixture} from "../utils/Fixture.sol";
import {BidModel} from "../utils/BidModel.sol";

/// @notice plain fuzz tests for the eth rate (SPEC 5.1 and 5.2) with fuzzed times, amounts and
/// fuzzed settings: the climb per minute, the ceiling and its loosening, the drop per credit and the rate cap are all
/// fields of `Settings` that the owner may set, so the model is parameterised by them. the climb is an independent whole minute integer walk, so it shares no code with the core's
/// wad pow. the pot is funded to an exact size by sending eth to the core and calling its real `skim()`, which is how
/// the core books any eth that did not arrive through the hook. credits are real ones, the settings are changed by the
/// real owner call.
contract RateFuzzTest is Fixture {
    /// @dev the seller of the credits, named as in the old unit tests
    address internal alice;

    uint256 internal constant START = OPEN_RATE;

    function setUp() public override {
        super.setUp();
        alice = seller;
    }

    /// @dev grows the pot by exactly `eth`: the eth is sent to the core and booked by the real `skim()`
    function _fund(uint256 eth) internal {
        uint256 pot = core.ethPot();
        vm.deal(address(core), pot + core.ethToBuyback() + eth);
        core.skim();
        assertEq(core.ethPot(), pot + eth, "pot grew by the funded amount");
    }

    /// @dev the least pot that is funded at the rate: it affords one credit
    function _minPot(uint256 rate) internal pure returns (uint256) {
        return rate;
    }

    /// the price state after `mins` whole minutes from the stored rate `r`: at most `rateCap` and the loosened ceiling of
    /// the anchor (idle for `idle` seconds), and an integer walk of `climbPerMinBps` a minute up to the clamp
    /// `pot`, which a price state above it holds
    function _priceAfter(Settings memory s, uint256 r, uint256 pot, uint256 anchor, uint256 idle, uint256 mins)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = BidModel.ceiling(s, anchor, idle);
        if (cap > s.rateCap) cap = s.rateCap;
        if (r >= cap) return cap;
        uint256 target = pot;
        if (target > cap) target = cap;
        if (r >= target) return r;
        for (uint256 j; j < mins; ++j) {
            r = r * (10_000 + s.climbPerMinBps) / 10_000;
            if (r >= target) return target;
        }
        return r;
    }

    /// the read for the price state `p`: lowered to the clamp
    function _readOf(Settings memory s, uint256 pot, uint256 p) internal pure returns (uint256) {
        return BidModel.read(s, pot, p);
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// settings with a random climb, ceiling, drop and floor, the other fields at the launch values. `calm` keeps the climb, the ceiling and the clamp at the launch values
    function _randomSettings(uint256 seed, bool calm) internal view returns (Settings memory s) {
        s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPerCreditBps = uint16(bound(_r(seed, 3), 1, 1_000));
        s.dropFloorBps = uint16(bound(_r(seed, 11), 5_000, 10_000));
        s.rateCap = uint64(RATE_START_MAX_WEI);
        if (!calm) {
            s.climbPerMinBps = uint16(bound(_r(seed, 4), 1, 1_000));
            s.ceilBps = uint16(bound(_r(seed, 5), 10_000, 30_000));
            s.idleLoosenBps = uint16(bound(_r(seed, 6), 1, 2_000));
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// the climb while unfilled: funded from the start, whole minutes of waiting, under random climb, ceiling, drop and rate cap. the price state climbs, the read is lowered to the clamp
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_climbCompoundsPerMinute(uint256 seed, uint256 potSeed, uint256 waitSeed) public {
        Settings memory s = _randomSettings(seed, false);
        _setSettings(s);
        uint256 min = _minPot(START);
        uint256 pot = bound(potSeed, min, min + 1000 ether);
        uint256 mins = bound(waitSeed, 0, 240);
        _fund(pot);
        _warp(mins * 1 minutes);
        uint256 p = _priceAfter(s, START, pot, START, block.timestamp - core.lastFillTime(), mins);
        assertApproxEqRel(core.ethRate(), _readOf(s, pot, p), 1e-7 ether, "compounded per minute, then the clamp");
        assertLe(core.ethRate(), p + p / 1e9, "never above the price state");
    }

    /// no climb while the pot cannot afford one credit, and no retroactive climb once it can,
    /// whatever the settings. the idle time counts toward the ceiling anchor only.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_pauseWhenUnfunded(uint256 seed, uint256 potSeed, uint256 idleSeed, uint256 topSeed, uint256 wait)
        public
    {
        Settings memory s = _randomSettings(seed, false);
        _setSettings(s);
        uint256 min = _minPot(START);
        uint256 pot = bound(potSeed, 0, min - 1);
        uint256 idle = bound(idleSeed, 0, 3000);
        if (pot != 0) _fund(pot);
        _warp(idle * 1 hours);
        assertEq(core.ethRate(), _readOf(s, pot, START), "the price state holds and the read is the clamp");

        uint256 top = bound(topSeed, min - pot, min - pot + 100 ether);
        _fund(top);
        assertEq(core.rateAtCheckpoint(), START, "no retroactive climb, and the clamp is not stored");
        uint256 clamp = BidModel.clamp(s, pot + top);
        assertEq(core.ethRate(), clamp < START ? clamp : START, "the read is the clamp when it binds");

        uint256 mins = bound(wait, 0, 240);
        _warp(mins * 1 minutes);
        uint256 p = _priceAfter(s, START, pot + top, START, block.timestamp - core.lastFillTime(), mins);
        assertApproxEqRel(core.ethRate(), _readOf(s, pot + top, p), 1e-7 ether);
    }

    /// a settings call stores the price state it found, even when it flips the funded flag, and the climb after it
    /// follows the new settings from the change on. no climb is credited under the wrong numbers.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_settingsChangeKeepsTheRateAndClimbsOnTheNewNumbers(
        uint256 seedA,
        uint256 seedB,
        uint256 potSeed,
        uint256 m1,
        uint256 m2
    ) public {
        Settings memory a = _randomSettings(seedA, false);
        _setSettings(a);
        uint256 pot = bound(potSeed, _minPot(START), _minPot(START) + 500 ether);
        _fund(pot);
        m1 = bound(m1, 0, 240);
        _warp(m1 * 1 minutes);
        uint256 p1 = _priceAfter(a, START, pot, START, block.timestamp - core.lastFillTime(), m1);
        assertApproxEqRel(core.ethRate(), _readOf(a, pot, p1), 1e-7 ether);
        Settings memory b = _randomSettings(seedB, false);
        _setSettings(b);
        uint256 r1 = core.rateAtCheckpoint();
        assertApproxEqRel(r1, p1, 1e-7 ether, "the call stores the price state it found");
        uint256 idle = block.timestamp - core.lastFillTime();
        assertEq(
            core.ethRate(), _readOf(b, pot, _priceAfter(b, r1, pot, START, idle, 0)), "the read under the new settings"
        );
        m2 = bound(m2, 0, 240);
        _warp(m2 * 1 minutes);
        uint256 p2 = _priceAfter(b, r1, pot, START, block.timestamp - core.lastFillTime(), m2);
        assertApproxEqRel(core.ethRate(), _readOf(b, pot, p2), 1e-7 ether, "climbing on the new settings");
    }

    /// a fill pays the read and drops the price state by `dropPerCreditBps` per credit, no lower than `dropFloorBps` of
    /// the price state at the first fill of the minute. the anchor is the price state at the last fill, not the rate
    /// paid. the climb, the ceiling and the clamp stay at the launch values and the pot is large, so the clamp never binds
    /// forge-config: default.fuzz.runs = 30
    function testFuzz_fillDropsPerCreditAndSetsTheAnchor(uint256 seed, uint256 potSeed, uint256 waitSeed, uint256 count)
        public
    {
        Settings memory s = _randomSettings(seed, true);
        _setSettings(s);
        uint256 pot = bound(potSeed, 20 ether, 1000 ether);
        uint256 mins = bound(waitSeed, 0, 240);
        uint256 n = bound(count, 1, 3);
        _fund(pot);
        _warp(mins * 1 minutes);
        uint256[] memory ids = _credits(alice, n);
        uint256 p0 = _priceAfter(s, START, pot, START, block.timestamp - core.lastFillTime(), mins);
        assertApproxEqRel(core.ethRate(), _readOf(s, pot, p0), 1e-7 ether);
        // the price state is stored by the first fill's checkpoint: use what the Core stored
        uint256 paid;
        uint256 pn;
        uint256 last;
        (paid, pn, last, p0) = _fillModel(s, ids, pot, p0);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertApproxEqAbs(alice.balance - before, paid, n * 1e6);
        assertApproxEqRel(core.rateAtCheckpoint(), pn, 1e-7 ether, "dropped per credit on the price state");
        assertEq(core.lastFillTime(), block.timestamp);
        (uint256 anchor, uint256 minuteStart,) = _anchor();
        assertApproxEqRel(anchor, last, 1e-7 ether, "the price state at the last fill is the anchor");
        assertApproxEqRel(minuteStart, p0, 1e-7 ether, "the minute started at the first price state");
        _climbAfterFill(s, core.rateAtCheckpoint(), anchor);
    }

    /// the credits of one call: what is paid at the read of each, the price state after them, the price state at the
    /// last fill, and the price state at the first
    function _fillModel(Settings memory s, uint256[] memory ids, uint256 pot, uint256 p0)
        internal
        view
        returns (uint256 paid, uint256 pn, uint256 last, uint256 first)
    {
        pn = p0;
        first = p0;
        for (uint256 i; i < ids.length; ++i) {
            last = pn;
            uint256 rd = BidModel.read(s, pot, pn);
            paid += rd;
            pot -= rd;
            pn = BidModel.dropOnce(s, pn, first);
        }
    }

    /// the anchor restarted: ten minutes later the climb is the base, unless the price state sits at its limit
    function _climbAfterFill(Settings memory s, uint256 rn, uint256 anchor) internal {
        _warp(10 minutes);
        uint256 pot = core.ethPot();
        uint256 p = _priceAfter(s, rn, pot, anchor, 10 minutes, 10);
        assertApproxEqRel(core.ethRate(), _readOf(s, pot, p), 1e-7 ether);
    }

    /// the pot is the only limit of spending: sales pass while the read is not zero, each pays the read, and the loop
    /// ends on ZeroAmount when the pot is drained
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_potIsTheOnlyLimit(uint256 potSeed) public {
        uint256 pot = bound(potSeed, 0.03 ether, 0.05 ether);
        _fund(pot);
        uint256[] memory ids = _credits(alice, 60);
        uint256 spent;
        bool drained;
        for (uint256 i; i < ids.length; ++i) {
            uint256 price = core.ethRate();
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertTrue(price != 0, "a zero price passed");
                spent += price;
            } catch (bytes memory why) {
                assertEq(bytes4(why), ICore.ZeroAmount.selector);
                assertEq(price, 0, "a priced credit was refused");
                drained = true;
                break;
            }
        }
        assertTrue(drained, "the pot was not drained");
        assertEq(spent, pot, "the whole pot was spent, the last sale at the clamp");
        assertEq(core.ethPot(), 0);
    }

    /// below one credit the read is the pot, and a sale pays it whole
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_clampPaysTheWholeSmallPot(uint256 potSeed) public {
        uint256 pot = bound(potSeed, 1, START - 1);
        _fund(pot);
        assertEq(core.ethRate(), pot, "pinned at the clamp");
        uint256[] memory ids = _credits(alice, 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(alice.balance - before, pot);
        assertEq(core.ethPot(), 0);
    }
}
