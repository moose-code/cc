// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// a credit the engine sold through `sellCreditTo` is refused at every intake door for `returnLockSeconds` from the sale
/// (`ReturnLocked(id, until)`): `sellForEth`, `sellForBalance`, `buyListing`, and `swapCredit` as the incoming credit.
/// the Core stores the sale timestamp; a lock of 0 refuses the credit in the second of the sale only, the same block rule
contract ReturnLockTest is Fixture {
    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = _user("rl.buyer");
    }

    /// fills the eth pile with `n` credits, turns the credit sale on, and has `buyer` buy the first at its price now.
    /// returns the full pile ids; ids[0] is the bought credit, now owned by `buyer`, and the lock's end
    function _buyFirst(uint256 n) internal returns (uint256[] memory ids, uint256 until) {
        ids = _fillEthPile(n);
        _setCreditSaleOn(true);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, buyer.balance + price);
        vm.prank(buyer);
        ctl.buyCredit{value: price}(ids[0]);
        vm.prank(buyer);
        CREDITS.setApprovalForAll(address(core), true);
        uint256 lock = core.settings().returnLockSeconds;
        until = block.timestamp + (lock == 0 ? 1 : lock);
    }

    function _locked(uint256 id, uint256 until) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICore.ReturnLocked.selector, id, until);
    }

    // promise: SPEC 6 the launch return lock is one day
    function test_launchLockIsOneDay() public view {
        assertEq(core.settings().returnLockSeconds, 86_400);
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by sellForEth until the lock ends
    function test_sellForEthRefusedUntilTheLockEnds() public {
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        uint256 id = ids[0];
        vm.prank(buyer);
        vm.expectRevert(_locked(id, until));
        core.sellForEth(_one(id));
        vm.warp(until - 1);
        vm.roll(block.number + 7_000);
        vm.prank(buyer);
        vm.expectRevert(_locked(id, until));
        core.sellForEth(_one(id));
        vm.warp(until);
        _fundPot(10 ether); // the day's climb raised the bid above the pot the pile was filled with
        vm.prank(buyer);
        core.sellForEth(_one(id));
        assertEq(CREDITS.ownerOf(id), address(core), "the credit returns at the lock's end");
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by buyListing inside the lock
    function test_buyListingRefusedInsideTheLock() public {
        _approveAdapter(rawAdapter);
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        vm.warp(until - 1);
        vm.expectRevert(_locked(ids[0], until));
        core.buyListing(rawAdapter, ids[0], "");
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by swapCredit as the incoming credit inside the lock
    function test_swapCreditRefusedInsideTheLock() public {
        (uint256[] memory ids, uint256 until) = _buyFirst(2); // ids[0] bought by buyer, ids[1] stays in the pile
        vm.warp(until - 1);
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], until));
        core.swapCredit(ids[0], ids[1]);
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by sellForBalance inside the lock
    function test_sellForBalanceRefusedInsideTheLock() public {
        _enterPhase2();
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        vm.warp(until - 1);
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], until));
        core.sellForBalance(_one(ids[0]));
    }

    // promise: SPEC 6 a lock of 0 keeps the same block rule: refused in the second of the sale, allowed the next
    function test_zeroLockIsTheSameBlockRule() public {
        _setReturnLock(0);
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        assertEq(until, block.timestamp + 1, "the lock ends one second after the sale");
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], until));
        core.sellForEth(_one(ids[0]));
        _nextSecond();
        vm.prank(buyer);
        core.sellForEth(_one(ids[0]));
    }

    // promise: SPEC 6 the lock reads the live setting against the stored sale time, so an owner change moves its end
    function test_lockFollowsTheLiveSetting() public {
        (uint256[] memory ids,) = _buyFirst(1);
        uint256 soldAt = block.timestamp;
        _setReturnLock(3_600);
        vm.warp(soldAt + 3_599);
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], soldAt + 3_600));
        core.sellForEth(_one(ids[0]));
        vm.warp(soldAt + 3_600);
        vm.prank(buyer);
        core.sellForEth(_one(ids[0]));
    }

    // promise: SPEC 6 a credit the engine never sold passes every intake door at any time
    function test_neverSoldCreditPasses() public {
        uint256[] memory held = _credits(seller, 1);
        _fundPot(1 ether);
        vm.prank(seller);
        core.sellForEth(held);
        assertEq(CREDITS.ownerOf(held[0]), address(core));
    }
}
