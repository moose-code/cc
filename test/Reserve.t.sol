// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";

/// the reserve: the eth the pot keeps for processing, the larger of `reserveWei` and 1.5 times the queued compose and
/// redeem caller payments (one compose per full page of the pile at 9,000,000 gas, one redemption per held statement at
/// 600,000 gas, each gas at `callerMaxBaseFee` plus `callerFee`). the bids and `ethRate` read `ethPot` less it; the caller
/// payments, the buyback and the pushes pay from the whole pot
contract ReserveTest is Fixture {
    using stdStorage for StdStorage;

    /// the launch reserve floor, which the general fixture sets to 0
    function _settings() internal view override returns (Settings memory s) {
        s = super._settings();
        s.reserveWei = 0.1 ether;
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
        uint256 queued = pile / 80 * (9_000_000 * uint256(s.callerMaxBaseFee) + s.callerFee)
            + held * (600_000 * uint256(s.callerMaxBaseFee) + s.callerFee);
        uint256 q = queued * 15 / 10;
        return q > s.reserveWei ? q : s.reserveWei;
    }

    // promise: SPEC 4 the reserve is max(reserveWei, 1.5 times the queued compose and redeem payments)
    function test_formulaFollowsTheQueue() public {
        assertEq(core.reserve(), 0.1 ether, "an empty queue keeps the floor");
        Settings memory s = core.settings();
        s.reserveWei = 0;
        _setSettings(s);
        assertEq(core.reserve(), 0, "no queue and no floor");
        _fillEthPile(80);
        // one page at the launch caller settings: 1.5 * (9,000,000 * 3 gwei + 0.0003 eth) = 0.04095 eth
        assertEq(core.reserve(), 0.04095 ether, "one full page");
        assertEq(core.reserve(), _formula(core.pileSize(), 0));
        _composeOnce();
        // the page left the pile and one statement is held: 1.5 * (600,000 * 3 gwei + 0.0003 eth) = 0.00315 eth
        assertEq(core.pileSize(), 0);
        assertEq(core.reserve(), 0.00315 ether, "one held statement");
        assertEq(core.reserve(), _formula(0, 1));
        s = core.settings();
        s.reserveWei = 0.1 ether;
        _setSettings(s);
        assertEq(core.reserve(), 0.1 ether, "the floor binds above a short queue");
    }

    // promise: SPEC 4 ethRate never reads above ethPot less the reserve, and is 0 at or under the reserve
    function test_ethRateNeverAboveThePayable() public {
        uint256[] memory ids = _credits(seller, 1);
        uint256 res = core.reserve();
        _setPot(res);
        assertEq(core.ethRate(), 0, "a pot at the reserve bids nothing");
        vm.prank(seller);
        vm.expectRevert(ICore.ZeroAmount.selector);
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
        _approveAdapter(rawAdapter);
        uint256 id = _heldCredit(0);
        ListingTarget t = new ListingTarget();
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
        _liftRateCap();
        _setPot(core.reserve() + 0.01 ether);
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
