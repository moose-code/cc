// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";

/// the reserve: the eth the pot keeps for processing, the larger of `reserveWei` and 1.5 times the queued compose and
/// redeem caller payments (one compose per full page of the pile at 9,000,000 gas, one redemption per held statement at
/// 600,000 gas, each gas at `callerMaxBaseFee` plus `callerFee`). the bids and `ethRate` read `ethPot` less it; the caller
/// payments, the buyback and the pushes pay from the whole pot. this runs against the live core, whose `reserveWei` floor
/// is already 0.1 eth and whose pile is non empty at the pin, so the queue assertions read the live pile and held set
contract ReserveTest is LiveFixture {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        // book any fee income pending at the pin so `ethPot` and the bid room (which reads unbooked income through the
        // pages pot) start from clean books, and age the live pile past the credit sale window (creditSaleOn is on at the
        // pin) so compose can take the oldest page
        core.book();
        _warp(ctl.creditWindow() + 1);
    }

    /// sets the pot by slot and moves the eth with it, so the next book counts nothing
    function _setPot(uint256 v) internal {
        uint256 old = core.ethPot();
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
        if (v > old) vm.deal(address(core), address(core).balance + v - old);
        else vm.deal(address(core), address(core).balance - (old - v));
        assertEq(core.ethPot(), v);
    }

    /// the reserve formula by hand at the live settings
    function _formula(uint256 pile, uint256 held) internal view returns (uint256) {
        Settings memory s = core.settings();
        uint256 queued = pile / 80 * (9_000_000 * uint256(s.callerMaxBaseFee) + s.callerFee) + held
            * (600_000 * uint256(s.callerMaxBaseFee) + s.callerFee);
        uint256 q = queued * 15 / 10;
        return q > s.reserveWei ? q : s.reserveWei;
    }

    // promise: SPEC 4 the reserve is max(reserveWei, 1.5 times the queued compose and redeem payments)
    /// read against the live pile and held set. the live `reserveWei` floor is 0.1 eth; the reserve follows the hand
    /// formula at every step, a full page adds one page of queued compose payment, and a compose moves a page out of the
    /// pile into one held statement
    function test_formulaFollowsTheQueue() public {
        assertEq(
            core.reserve(),
            _formula(core.pileSize(), core.heldStatements().length),
            "the reserve follows the queue at the live state"
        );
        // drop the floor: the reserve is the queued payments alone
        Settings memory s = core.settings();
        s.reserveWei = 0;
        _setSettings(s);
        assertEq(
            core.reserve(),
            _formula(core.pileSize(), core.heldStatements().length),
            "no floor, the queued payments alone"
        );
        // one full page adds one page of queued compose payment
        uint256 pagePay = 9_000_000 * uint256(s.callerMaxBaseFee) + s.callerFee;
        uint256 before = core.reserve();
        _fillEthPile(80);
        assertEq(core.reserve() - before, pagePay * 15 / 10, "one full page added one page of queued compose payment");
        assertEq(core.reserve(), _formula(core.pileSize(), core.heldStatements().length));
        // a compose moves a page out of the pile into one held statement
        uint256 pileBefore = core.pileSize();
        uint256 heldBefore = core.heldStatements().length;
        _composeOnce();
        assertEq(core.pileSize(), pileBefore - 80, "the page left the pile");
        assertEq(core.heldStatements().length, heldBefore + 1, "one statement is held");
        assertEq(core.reserve(), _formula(core.pileSize(), core.heldStatements().length));
        // the floor binds again once it is above the short queue
        s = core.settings();
        s.reserveWei = 0.1 ether;
        _setSettings(s);
        assertEq(core.reserve(), _formula(core.pileSize(), core.heldStatements().length), "the floor binds the formula");
    }

    // promise: decision 176 lowering the queued reserve starts a fresh funded clock without granting empty hours
    /// several pages queue a reserve above the floor. a pot set just under the reserve leaves the funded clock unstarted,
    /// so idle time does not raise the price. a compose removes a page (floor(pile/80) falls by one), lowering the reserve
    /// below the pot. the compose must not backdate the idle interval, and funded time after it raises the price
    function test_composeReserveDropDoesNotGrantEmptyHours() public {
        _fillEthPile(240);
        uint256 res0 = core.reserve();
        assertGt(res0, 0.1 ether, "the queued pages bind above the reserve floor");
        vm.prank(owner);
        core.setRate(0.0049 ether);
        _setPot(res0 - 1);
        _warp(6 hours);
        assertEq(core.ethPrice(), 0.0049 ether, "the pot under the reserve left the clock unfunded");

        vm.fee(0);
        vm.prank(keeper);
        core.compose();
        assertLt(core.reserve(), res0, "one compose lowered the queued reserve");
        assertGt(core.ethPot(), core.reserve(), "the pot now sits above the lowered reserve");
        assertEq(core.ethPrice(), 0.0049 ether, "the compose did not grant the prior six hours");
        _warp(5 minutes);
        assertGt(core.ethPrice(), 0.0049 ether, "funded time after the compose raises the price");
    }

    // promise: decision 176 raising the queued reserve preserves the funded climb earned before the new page
    /// the pile is filled to one credit short of a page boundary, so one more Credit crosses it and raises the reserve. a
    /// funded pot climbs for four minutes, then the adopt that queues the new page must keep the earned checkpoint rate
    function test_adoptReserveRiseKeepsEarnedClimb() public {
        // land the pile one credit short of the next page boundary (pile mod 80 == 79)
        _fillEthPile(79 - (core.pileSize() % 80));
        vm.prank(owner);
        core.setRate(0.0049 ether);
        _setPot(core.reserve() + 10 ether);
        _warp(4 minutes);
        uint256 earned = core.ethPrice();
        assertGt(earned, 0.0049 ether, "the funded pot climbed for four minutes");

        uint256 resBefore = core.reserve();
        uint256 id = _heldCredit(0);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(core), id);
        core.adopt(_one(id));
        assertGt(core.reserve(), resBefore, "the boundary-crossing Credit queued another page");
        assertEq(core.rateAtCheckpoint(), earned, "the checkpoint kept the funded interval before the reserve grew");
    }

    // promise: decision 176 a controller credit sale cannot backdate a funded climb when the pile crosses a page boundary
    /// the pile is filled to a page boundary (pile mod 80 == 0), so selling one pile Credit out crosses it down and lowers
    /// the reserve. a pot under the reserve leaves the clock unfunded; the sale must not backdate the idle interval
    function test_creditSaleReserveDropDoesNotGrantEmptyHours() public {
        uint256 rem = core.pileSize() % 80;
        uint256[] memory ids = _fillEthPile(rem == 0 ? 80 : 80 - rem);
        uint256 sold = ids[ids.length - 1];
        uint256 res0 = core.reserve();
        assertGt(res0, 0.1 ether, "the queued pages bind above the reserve floor");
        vm.prank(owner);
        core.setRate(0.0049 ether);
        _setPot(res0 - 1);
        _warp(6 hours);
        assertEq(core.ethPrice(), 0.0049 ether, "the pot under the reserve left the clock unfunded");

        (, uint256 cost,) = core.creditInfo(sold);
        vm.deal(address(ctl), cost);
        vm.prank(address(ctl));
        core.sellCreditTo{value: cost}(sold, makeAddr("credit buyer"));
        assertLt(core.reserve(), res0, "the boundary-crossing sale lowered the queue");
        assertEq(core.ethPrice(), 0.0049 ether, "the sale did not grant the prior six hours");
        _warp(5 minutes);
        assertGt(core.ethPrice(), 0.0049 ether, "funded time after the sale raises the price");
    }

    // promise: SPEC 4 ethRate never reads above ethPot less the reserve, and is 0 at or under the reserve
    function test_ethRateNeverAboveThePayable() public {
        uint256[] memory ids = _credits(seller, 1);
        uint256 res = core.reserve();
        _setPot(res);
        assertEq(core.ethRate(), 0, "a pot at the reserve bids nothing");
        vm.prank(seller);
        vm.expectRevert(ICore.PotTooSmall.selector); // the reserve holds the pot, a named refusal (not ZeroAmount)
        core.sellForEth(ids);
        _setPot(res + 1e12);
        assertLe(core.ethRate(), 1e12, "the read is at most the pot above the reserve");
        _setPot(res + 10 ether);
        assertEq(core.ethRate(), core.ethPrice(), "a funded pot reads the price state");
    }

    // promise: SPEC 4 an eth purchase never takes the pot under the reserve
    function test_sellForEthKeepsTheReserve() public {
        uint256[] memory ids = _credits(seller, 5);
        uint256 res = core.reserve();
        // room for about two credits above the reserve
        _setPot(res + core.ethRate() * 9 / 2 * 2);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            try core.sellForEth(_one(ids[i])) {} catch {}
        }
        assertGe(core.ethPot(), core.reserve(), "the pot never falls under the reserve");
    }

    // promise: SPEC 4 a credit whose bid passes the pot less the reserve reverts PotTooSmall
    function test_spendAboveTheRoomReverts() public {
        uint256[] memory ids = _credits(seller, 1);
        // a score above 100 points pays more than the per 100 point read, so a read lowered to the room overpays it
        uint256 score = _scoreOf(ids[0]);
        assertGt(score, RATE_SCORE, "the credit scores above 100 points");
        _setPot(core.reserve() + core.ethPrice() / 2);
        vm.prank(seller);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForEth(ids);
    }

    // promise: SPEC 4 processing still pays from the whole pot: compose pays its caller with the pot at the reserve
    function test_processingPaysFromTheWholePot() public {
        _fillEthPile(80);
        _setPot(core.reserve());
        uint256 before = keeper.balance;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertGt(keeper.balance - before, 0, "the composer is paid out of the reserve");
    }

    // promise: SPEC 6 buyListing refuses a quote above the pot less the reserve and caps the payment at the room
    function test_buyListingRespectsTheRoom() public {
        // the owner approved raw test adapter (installed once by LiveFixture.setUp)
        _approveRawAdapter();
        uint256 id = _heldCredit(0);
        ListingTarget t = new ListingTarget();
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
        _liftRateCap();
        // the live credit bids several times the per 100 point rate, so give the room more than one bid of headroom
        _setPot(core.reserve() + 1 ether);
        uint256 room = core.ethPot() - core.reserve();
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(room + 1, abi.encodeCall(ListingTarget.fill, (id, 0)), id, address(t));
        // the bid reads the room, so a value under the bid is under the room too
        uint256 value = core.bidOf(id) * 9 / 10;
        assertLe(value, room);
        vm.prank(keeper);
        _buyRaw(value, abi.encodeCall(ListingTarget.fill, (id, 0)), id, address(t));
        assertGe(core.ethPot(), core.reserve(), "value plus payment stay inside the room");
    }
}
