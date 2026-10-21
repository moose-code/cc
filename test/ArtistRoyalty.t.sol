// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";

/// an artist that counts the pushes it receives
contract CountingArtist {
    uint256 public count;

    receive() external payable {
        count++;
    }
}

/// an artist that refuses eth
contract RevertingArtist {
    receive() external payable {
        revert("no");
    }
}

/// an artist that burns the whole push stipend
contract BurningArtist {
    receive() external payable {
        while (true) {}
    }
}

/// the artist royalty on every engine purchase (decision 163): whatever the engine pays for a credit, it pays
/// `buyToArtistBps` of that amount to the artist on top, in the same currency. the seller receives the displayed bid
/// whole, the pot pays both, the cost basis records both, and the eth bid's pot clamp leaves room for the royalty so a
/// bid the site shows is always payable
contract ArtistRoyaltyTest is LiveFixture {
    uint256 internal constant BPS = 10_000;

    function setUp() public override {
        super.setUp();
        // LiveFixture does not approve the test RawListingAdapter the fresh Fixture did; `_buyRaw` needs it
        _approveRawAdapter();
    }

    function _bps() internal view returns (uint256) {
        return core.settings().buyToArtistBps;
    }

    function _royalty(uint256 pay) internal view returns (uint256) {
        return pay * _bps() / BPS;
    }

    function _setBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.buyToArtistBps = bps;
        if (bps == 1_000) s.balanceDiscountBps = 1_100;
        _setSettings(s);
    }

    // promise: SPEC 3 the launch royalty is 250 bps and the artist is set
    function test_launchValues() public view {
        assertEq(_bps(), 250);
        assertTrue(core.artist() != address(0));
    }

    // promise: SPEC 6 sellForEth pays the seller the displayed bid whole and the artist buyToArtistBps of it on top;
    // the pot and the core's eth fall by both, the cost basis records both, and CreditBought carries both
    function test_sellForEthPaysSellerWholeAndArtistOnTop() public {
        _fundPot(2 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 pay = core.bidOf(ids[0]);
        uint256 royalty = _royalty(pay);
        assertGt(royalty, 0);
        address artist = core.artist();
        uint256 sellerBefore = seller.balance;
        uint256 artistBefore = artist.balance;
        uint256 potBefore = core.ethPot();
        uint256 coreBefore = address(core).balance;
        vm.expectEmit(true, true, false, true, address(core));
        emit ICore.CreditBought(ids[0], seller, pay + royalty, royalty);
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - sellerBefore, pay, "the seller receives the displayed bid whole");
        assertEq(artist.balance - artistBefore, royalty, "the artist receives the royalty");
        assertEq(potBefore - core.ethPot(), pay + royalty, "the pot paid both");
        assertEq(coreBefore - address(core).balance, pay + royalty, "both left the core");
        (bool inPile, uint256 cost,) = core.creditInfo(ids[0]);
        assertTrue(inPile);
        assertEq(cost, pay + royalty, "the cost basis records the price plus the royalty");
        _solvent();
    }

    // promise: SPEC 6 a sellForEth batch pushes the artist once, the sum of the per credit royalties
    function test_batchPushesTheArtistOnce() public {
        _fundPot(5 ether);
        CountingArtist a = new CountingArtist();
        _setArtist(address(a));
        uint256[] memory ids = _credits(seller, 4);
        uint256 royalties;
        // the bid drops per credit: read each credit's pay as the fill will, from the snapshot
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ids.length; ++i) {
            uint256 pay = core.bidOf(ids[i]);
            royalties += _royalty(pay);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
        vm.revertToState(snap);
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(a.count(), 1, "one push per batch");
        assertEq(address(a).balance, royalties, "the sum of the per credit royalties");
    }

    // promise: SPEC 6 a reverting or gas burning artist never blocks a purchase: the push is forced and the eth lands
    function test_hostileArtistNeverBlocksAPurchase() public {
        _fundPot(5 ether);
        RevertingArtist r = new RevertingArtist();
        _setArtist(address(r));
        uint256[] memory ids = _credits(seller, 2);
        uint256 pay = core.bidOf(ids[0]);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(address(r).balance, _royalty(pay), "the forced push landed on a reverting artist");
        BurningArtist b = new BurningArtist();
        _setArtist(address(b));
        pay = core.bidOf(ids[1]);
        vm.prank(seller);
        core.sellForEth(_one(ids[1]));
        assertEq(address(b).balance, _royalty(pay), "the forced push landed on a gas burning artist");
        assertEq(CREDITS.ownerOf(ids[1]), address(core));
    }

    // promise: SPEC 4 the spend ledger counts the royalty: spent after a fill is the price plus the royalty
    function test_ledgerCountsTheRoyalty() public {
        _fundPot(2 ether);
        Settings memory s = core.settings();
        s.spendCapBps = 5_000;
        _setSettings(s);
        uint256[] memory ids = _credits(seller, 1);
        uint256 pay = core.bidOf(ids[0]);
        vm.prank(seller);
        core.sellForEth(ids);
        (,, uint256 spent) = core.spendState();
        assertEq(spent, pay + _royalty(pay), "the ledger counts the whole outflow");
    }

    // promise: SPEC 4 the eth bid's pot clamp divides by 1 + buyToArtistBps / 10_000: with the price state above the
    // room the read is the room over 1.025, and a fill at that read pays the bid and its royalty from the room
    function test_clampLeavesRoomForTheRoyalty() public {
        // the live Core carries an uncontrolled pot and a nonzero reserve and cannot be drained, so the thin-pot clamp
        // is reached through the owner's setters instead of a tiny fresh pot: book the pending income so the pages pot
        // equals ethPot, lift the price state well above the room, then raise the reserve so the room is a small known
        // amount far below the price state and the pot clamp binds
        if (core.ethPot() < 1 ether) _fundPot(1 ether);
        _book();
        _liftRateCap();
        // read RATE_START before the prank: as a call argument it would consume the prank, leaving setRate unpranked
        uint256 openingRate = core.RATE_START();
        vm.prank(owner);
        core.setRate(openingRate);
        uint256 targetRoom = 1e14;
        // reserveWei is a uint64, so the carved reserve can be at most type(uint64).max wei; a live pot above that
        // cannot be clamped this way (re-pin to a block with a smaller pot, or move this case to the fresh Fixture)
        require(core.ethPot() - targetRoom <= type(uint64).max, "live pot too large for a uint64 reserve: re-pin");
        Settings memory s = core.settings();
        s.reserveWei = uint64(core.ethPot() - targetRoom);
        _setSettings(s);
        uint256 room = core.ethPot() - core.reserve();
        assertEq(room, targetRoom, "the reserve sets the room to the target far under the price state");
        assertEq(core.ethRate(), room * BPS / (BPS + _bps()), "the read is the room over 1 + bps");
        // the clamp is per 100 points: a credit at or under 100 points is payable with its royalty from the room
        uint256[] memory ids;
        for (uint256 i; i < 64; ++i) {
            ids = _credits(seller, 1);
            if (_scoreOf(ids[0]) <= RATE_SCORE) break;
        }
        assertLe(_scoreOf(ids[0]), RATE_SCORE, "a credit at or under 100 points");
        uint256 pay = core.bidOf(ids[0]);
        assertEq(pay, core.ethRate() * _scoreOf(ids[0]) / RATE_SCORE);
        assertLe(pay + _royalty(pay), room, "the bid and its royalty fit the room");
        uint256 potBefore = core.ethPot();
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - before, pay, "the displayed bid is the paid bid at the clamp");
        assertEq(core.ethPot(), potBefore - pay - _royalty(pay), "the pot paid the bid and its royalty");
    }

    // promise: SPEC 6 buyListing pays the listing price, the royalty on that price, and the keeper, all three under the
    // room; the keeper payment stays at most the bid less the price; the cost basis records all three
    function test_buyListingPaysTheRoyaltyOnThePrice() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fundPot(10 ether);
        _warpUntilCeiling(LISTED_A, price);
        uint256 bid = core.bidOf(LISTED_A);
        uint256 royalty = _royalty(price);
        address artist = core.artist();
        uint256 artistBefore = artist.balance;
        uint256 potBefore = core.ethPot();
        uint256 room = potBefore - core.reserve();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        uint256 paid = keeper.balance - keeperBefore;
        assertEq(artist.balance - artistBefore, royalty, "the artist receives bps of the listing price");
        assertEq(
            potBefore - core.ethPot(), price + royalty + paid, "the pot paid the price, the royalty and the keeper"
        );
        uint256 gap = bid - price;
        if (room - price - royalty < gap) gap = room - price - royalty;
        _assertListingPay(paid, gap);
        (, uint256 cost,) = core.creditInfo(LISTED_A);
        assertEq(cost, price + royalty + paid, "the cost basis records all three");
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _solvent();
    }

    // promise: SPEC 6 the artist royalty push runs before the keeper payment is measured, so a reverting artist does not
    // cut the keeper's gas refund: the keeper is still paid and the buy lands (decision 163)
    function test_buyListingKeeperCoveredWithRevertingArtist() public {
        RevertingArtist r = new RevertingArtist();
        _setArtist(address(r));
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fundPot(10 ether);
        _warpUntilCeiling(LISTED_A, price);
        uint256 royalty = _royalty(price);
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        uint256 paid = keeper.balance - keeperBefore;
        // the push runs before the keeper payment is measured, so the keeper is still refunded and the royalty lands on
        // the reverting artist through the forced push (exact amounts are pinned in test_buyListingPaysTheRoyaltyOnThePrice)
        assertGt(paid, 0, "the keeper is paid despite the reverting artist");
        assertApproxEqAbs(address(r).balance, royalty, 1, "the forced royalty push landed");
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _solvent();
    }

    // promise: SPEC 6 an adopted credit records the price plus the artist royalty as its cost basis, so its sale floor
    // matches a bought credit (decision 163)
    function test_adoptRecordsTheRoyaltyInTheCostBasis() public {
        _fundPot(5 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), id);
        uint256 price = core.ethPrice();
        uint256 pay = price * _scoreOf(id) / RATE_SCORE;
        assertGt(_royalty(pay), 0, "the launch royalty is nonzero");
        core.adopt(_one(id));
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, pay + _royalty(pay), "the adopted basis is the price plus the royalty");
    }

    // promise: SPEC 6 a listing whose price plus royalty passes the room reverts PotTooSmall before the venue is called
    function test_buyListingRefusesWhenTheRoyaltyDoesNotFit() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        // the live pot cannot be drained to leave no headroom, so the owner lifts the reserve to its uint64 maximum: the
        // room (ethPot less the reserve) is then zero, so the price and its royalty cannot fit
        _book();
        Settings memory s = core.settings();
        s.reserveWei = type(uint64).max;
        _setSettings(s);
        assertGe(core.reserve(), core.ethPot(), "the reserve leaves no room (re-pin if the live pot exceeds a uint64)");
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(price, abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A)), LISTED_A, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_A), STRATEGY, "nothing moved");
    }

    // promise: SPEC 3 the zero artist is refused while either artist cut is nonzero, accepted with both at zero, and
    // the royalty is bounded at 1,000 bps
    function test_zeroArtistRulesAndBound() public {
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setArtist(address(0));
        Settings memory s = core.settings();
        s.saleToArtistBps = 0;
        _setSettings(s);
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setArtist(address(0));
        s.buyToArtistBps = 0;
        _setSettings(s);
        _setArtist(address(0));
        assertEq(core.artist(), address(0));
        s.buyToArtistBps = 250;
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setSettings(s);
        _setArtist(creator);
        s.buyToArtistBps = 1_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buyToArtistBps")));
        core.setSettings(s);
        s.buyToArtistBps = 1_000;
        s.balanceDiscountBps = 1_100; // cover this royalty and the 200-bps redemption shortfall
        _setSettings(s);
        assertEq(_bps(), 1_000);
    }

    // promise: SPEC 3 at buyToArtistBps 0 the doors pay the bid alone: the pot falls by the price, the cost basis is
    // the price, and the artist receives nothing
    function test_zeroRoyaltyPaysTheBidAlone() public {
        _setBps(0);
        _fundPot(2 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 pay = core.bidOf(ids[0]);
        address artist = core.artist();
        uint256 artistBefore = artist.balance;
        uint256 potBefore = core.ethPot();
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(potBefore - core.ethPot(), pay);
        assertEq(artist.balance, artistBefore);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, pay);
    }

    // promise: SPEC 3 the royalty is editable through setSettings and effective for the next fill
    function test_royaltyIsEditable() public {
        _fundPot(2 ether);
        uint256[] memory ids = _credits(seller, 2);
        _setBps(1_000);
        uint256 pay = core.bidOf(ids[0]);
        address artist = core.artist();
        uint256 artistBefore = artist.balance;
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(artist.balance - artistBefore, pay / 10, "10 percent on the next fill");
        _setBps(100);
        pay = core.bidOf(ids[1]);
        artistBefore = artist.balance;
        vm.prank(seller);
        core.sellForEth(_one(ids[1]));
        assertEq(artist.balance - artistBefore, pay / 100, "1 percent after the edit");
    }
}
