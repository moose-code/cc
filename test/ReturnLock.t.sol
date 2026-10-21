// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SeaportBase} from "./Seaport.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";

/// a credit the engine sold through `sellCreditTo` is refused at every intake door for `returnLockSeconds` from the sale
/// when anyone offers it back (`ReturnLocked(id, until)`): `sellForEth`, `sellForBalance`, `buyListing` of a listing
/// and `swapCredit` as the incoming credit. the lock follows the credit through transfers; a lock of 0 is no lock.
contract ReturnLockTest is SeaportBase {
    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = _user("rl.buyer");
    }

    /// fills the eth pile with `n` credits, turns the credit sale on, and has `who` buy the first at its price now.
    /// returns the full pile ids; ids[0] is the bought credit, now owned by `who`, and the lock's end
    function _buyFirstBy(address who, uint256 n) internal returns (uint256[] memory ids, uint256 until) {
        // live strategy credits carry real scores (some well above 100 points), so a credit's eth bid can exceed the
        // room `_fillEthPile` funds on its own (`rateAtCheckpoint + reserve`). fund the pot generously first so the
        // pile fill has room for high score credits; this is pot setup, not an override of any live setting
        _fundPot(10 ether);
        ids = _fillEthPile(n);
        _setCreditSaleOn(true);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        ctl.buyCredit{value: price}(ids[0]);
        vm.prank(who);
        CREDITS.setApprovalForAll(address(core), true);
        uint256 lock = core.settings().returnLockSeconds;
        until = block.timestamp + lock;
    }

    function _buyFirst(uint256 n) internal returns (uint256[] memory ids, uint256 until) {
        return _buyFirstBy(buyer, n);
    }

    function _locked(uint256 id, uint256 until) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICore.ReturnLocked.selector, id, until);
    }

    // promise: SPEC 6 the launch return lock is six hours (decision 155)
    function test_launchLockIsSixHours() public view {
        assertEq(core.settings().returnLockSeconds, 21_600);
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by sellForEth to its buyer until the lock ends
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

    // promise: SPEC 6 a credit sold through the credit sale is refused by buyListing of a listing its buyer offers
    function test_buyListingRefusedWhenTheBuyerOffersTheListing() public {
        // the engine sells to the maker, who signs Seaport orders; the maker lists that credit on Seaport, so the
        // quote reports the maker as the offerer and the lock binds
        (uint256[] memory ids, uint256 until) = _buyFirstBy(maker, 1);
        uint256 id = ids[0];
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        vm.warp(until - 1);
        // build and sign the order before the expectRevert: _basicData reads Seaport, which must not be the guarded call
        bytes memory order = _basicData(_open(id, 0.01 ether, 0));
        vm.prank(keeper);
        vm.expectRevert(_locked(id, until));
        core.buyListing(seaportAdapter, id, order);
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by swapCredit as the incoming credit from its buyer
    function test_swapCreditRefusedInsideTheLock() public {
        (uint256[] memory ids, uint256 until) = _buyFirst(2); // ids[0] bought by buyer, ids[1] stays in the pile
        vm.warp(until - 1);
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], until));
        core.swapCredit(ids[0], ids[1]);
    }

    // promise: SPEC 6 a credit sold through the credit sale is refused by sellForBalance from its buyer inside the lock
    function test_sellForBalanceRefusedInsideTheLock() public {
        _enterPhase2();
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        vm.warp(until - 1);
        vm.prank(buyer);
        vm.expectRevert(_locked(ids[0], until));
        core.sellForBalance(_one(ids[0]));
    }

    // promise: a secondary transfer cannot bypass the credit's return lock; the holder can sell after it expires
    function test_secondaryHolderCannotBypassLock() public {
        (uint256[] memory ids, uint256 until) = _buyFirst(1);
        uint256 id = ids[0];
        address secondary = _user("rl.secondary");
        // the buyer sells the credit on to a secondary holder, who is not the engine's buyer
        vm.prank(buyer);
        CREDITS.transferFrom(buyer, secondary, id);
        vm.prank(secondary);
        CREDITS.setApprovalForAll(address(core), true);
        _fundPot(10 ether);
        // inside the window even this new holder cannot sell to the ETH bid
        vm.prank(secondary);
        vm.expectRevert(_locked(id, until));
        core.sellForEth(_one(id));
        vm.warp(until);
        vm.prank(secondary);
        core.sellForEth(_one(id));
        assertEq(CREDITS.ownerOf(id), address(core), "the secondary holder sells after the lock ends");
    }

    // promise: all intake routes share the credit-wide lock even when the engine's buyer transfers the credit
    function test_secondaryHolderCannotUseOtherIntakeRoutes() public {
        _enterPhase2();
        (uint256[] memory ids, uint256 until) = _buyFirst(2);
        uint256 id = ids[0];
        address secondary = maker;
        vm.prank(buyer);
        CREDITS.transferFrom(buyer, secondary, id);
        vm.prank(secondary);
        CREDITS.setApprovalForAll(address(core), true);
        vm.prank(secondary);
        vm.expectRevert(_locked(id, until));
        core.sellForBalance(_one(id));
        vm.prank(secondary);
        vm.expectRevert(_locked(id, until));
        core.swapCredit(id, ids[1]);
        vm.prank(secondary);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        bytes memory order = _basicData(_open(id, 0.01 ether, 0));
        vm.prank(keeper);
        vm.expectRevert(_locked(id, until));
        core.buyListing(seaportAdapter, id, order);
    }

    // promise: SPEC 6 a lock of 0 is no lock: a credit may return in the second of its sale
    function test_zeroLockIsNoLock() public {
        _setReturnLock(0);
        (uint256[] memory ids,) = _buyFirst(1);
        vm.prank(buyer);
        core.sellForEth(_one(ids[0]));
        assertEq(CREDITS.ownerOf(ids[0]), address(core), "a zero lock lets the credit return in the sale's own second");
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
