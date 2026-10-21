// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {RATE_SCORE, Settings, Mainnet, ICreditStrategy} from "../src/interfaces/Interfaces.sol";

/// the ETH purchase budget of a bucket, against the live Core/controller/pile on a mainnet fork. the fresh deploy
/// priced clean round pots with a mocked unit score so the per-credit outflow equalled the stored rate; live credits
/// carry their real scores, so every expected outflow here is read from `core.bidOf(id)` (the real scaled bid) and
/// every snapshot and budget is read from the live pot the first purchase of the bucket books, never a round literal.
/// two cases need inputs no real credit or pot can produce (a pot small enough that the budget rounds to zero, and
/// absolute timestamps that collide two bucket ids): they live in `SpendCapControlledTest` on the fresh `Fixture`.
contract SpendCapTest is LiveFixture {
    uint256 private constant SPEND_SLOT = 39;

    function setUp() public override {
        super.setUp();
        // the budget promises read the price alone and exclude the reserve: the ledger counts the artist royalty as
        // outflow (test/ArtistRoyalty.t.sol) and the reserve floor is test/Reserve.t.sol. the fresh deploy set these in
        // its `_settings()` deploy override, which LiveFixture cannot run (it binds the live Core); apply them as the
        // owner here instead, the only settings this suite's budget math needs
        Settings memory s = core.settings();
        s.reserveWei = 0;
        s.buyToArtistBps = 0;
        _setSettings(s);
        // the failed-venue case prices through the test raw adapter, which LiveFixture does not approve in its setUp
        _approveRawAdapter();
        // LISTED_A (35377) of the fresh fixture no longer exists at the pin; LISTED_C (18683) is live listed here and the
        // keeper-fill cases use it
        assertGt(
            ICreditStrategy(STRATEGY).nftForSale(LISTED_C), 0, "LISTED_C is listed by the live strategy at the pin"
        );
        assertEq(CREDITS.ownerOf(LISTED_C), STRATEGY, "and the strategy holds it");
    }

    function _fund(uint256 amount) private {
        vm.deal(funder, funder.balance + amount);
        vm.prank(funder);
        core.fund{value: amount}();
    }

    /// sets the live rate to `rate` under a cap that admits it and a drop floor that holds the rate flat across a batch,
    /// at spend cap `cap`. the fresh deploy also forced the credit to read as 100 points (`_unitScore`) so the per-credit
    /// outflow equalled `rate`; on live the score is never mocked, so the outflow is the real scaled bid `core.bidOf(id)`
    function _flat(uint256 id, uint256 rate, uint16 cap) private {
        Settings memory s = core.settings();
        s.rateCap = uint64(rate < 1 ether ? 1 ether : rate);
        s.dropFloorBps = 10_000;
        s.spendCapBps = cap;
        _setSettings(s);
        vm.prank(owner);
        core.setRate(rate);
    }

    /// the eth the pot pays for credit `id` now: the scaled bid plus its artist royalty, the amount `_spend` books. the
    /// royalty is zero in this suite (setUp), so this is `bidOf`, read live, never a round literal
    function _outflow(uint256 id) private view returns (uint256) {
        uint256 pay = core.bidOf(id);
        return pay + pay * core.settings().buyToArtistBps / 10_000;
    }

    function _sell(uint256 id) private {
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    function _budget() private view returns (uint256) {
        return uint128(uint256(vm.load(address(core), bytes32(SPEND_SLOT))) >> 72);
    }

    function _spent() private view returns (uint256) {
        return uint128(uint256(vm.load(address(core), bytes32(SPEND_SLOT + 1))));
    }

    function _snapshot() private view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(SPEND_SLOT + 2)));
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                core.ethPot(),
                core.rateAtCheckpoint(),
                core.lastFillTime(),
                core.pileSize(),
                vm.load(address(core), bytes32(SPEND_SLOT)),
                vm.load(address(core), bytes32(SPEND_SLOT + 1)),
                vm.load(address(core), bytes32(SPEND_SLOT + 2))
            )
        );
    }

    // promise: exact budget succeeds; overspending returns exact amounts and the next bucket opens a fresh budget
    function test_exactBudgetAndNextBucket() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 1 ether, 100);
        _fund(100 ether);
        uint256 snap = core.ethPot();
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        assertEq(_spent(), out0);
        assertEq(_snapshot(), snap);
        assertEq(_budget(), snap * 100 / 10_000);
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, out0, cost, snap * 100 / 10_000));
        _sell(ids[1]);
        vm.warp((block.timestamp / 60 + 1) * 60);
        _flat(ids[1], 0.5 ether, 100);
        uint256 snap2 = core.ethPot();
        uint256 out1 = _outflow(ids[1]);
        _sell(ids[1]);
        assertEq(_spent(), out1);
        assertEq(_snapshot(), snap2);
    }

    // promise: the first purchase of a bucket passes a budget under one credit; the second reverts and the next bucket buys again
    function test_firstPurchaseOfABucketPassesASubCreditBudget() public {
        uint256[] memory ids = _credits(seller, 3);
        _flat(ids[0], 1 ether, 100);
        _fund(10 ether);
        uint256 snap = core.ethPot();
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        assertEq(_budget(), snap * 100 / 10_000);
        assertLt(_budget(), out0, "the budget is under one credit");
        assertEq(_spent(), out0, "the full cost is recorded");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, out0, cost, snap * 100 / 10_000));
        _sell(ids[1]);
        vm.warp((block.timestamp / 60 + 1) * 60);
        _flat(ids[1], 0.5 ether, 100);
        uint256 out1 = _outflow(ids[1]);
        _sell(ids[1]);
        assertEq(CREDITS.ownerOf(ids[1]), address(core));
        assertEq(_spent(), out1);
    }

    // promise: a batch whose first credit alone exceeds the budget fills that credit and reverts at the second
    function test_batchFirstCreditPassesSecondReverts() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 1 ether, 100);
        _fund(10 ether);
        uint256[] memory both = new uint256[](2);
        both[0] = ids[0];
        both[1] = ids[1];
        vm.expectPartialRevert(ICore.SpendCapReached.selector);
        vm.prank(seller);
        core.sellForEth(both);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    // promise: spendState reads the live bucket, and the next bucket reads zero spent with the projected budget
    function test_spendStateReadsTheLiveBucket() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 1 ether, 100);
        _fund(100 ether);
        uint256 snap = core.ethPot();
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        (uint64 bucket, uint128 budget, uint128 spent) = core.spendState();
        assertEq(bucket, block.timestamp / 60);
        assertEq(budget, snap * 100 / 10_000);
        assertEq(spent, out0);
        vm.warp((block.timestamp / 60 + 1) * 60);
        uint256 pot = core.ethPot();
        (uint64 next, uint128 nextBudget, uint128 nextSpent) = core.spendState();
        assertEq(next, bucket + 1);
        assertEq(nextBudget, pot * 100 / 10_000);
        assertEq(nextSpent, 0);
        _flat(ids[1], 0.5 ether, 100);
        uint256 out1 = _outflow(ids[1]);
        _sell(ids[1]);
        (next, nextBudget, nextSpent) = core.spendState();
        assertEq(next, bucket + 1);
        assertEq(nextBudget, pot * 100 / 10_000);
        assertEq(nextSpent, out1);
    }

    // promise: ordinary funding and spending never change the active opening-pot budget
    function test_snapshotFixedAndPotScaling() public {
        uint256[] memory ids = _credits(seller, 3);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        uint256 snap = core.ethPot();
        _sell(ids[0]);
        assertEq(_snapshot(), snap);
        assertEq(_budget(), snap * 100 / 10_000);
        _fund(100 ether);
        assertGt(core.ethPot(), snap, "funding grew the pot");
        _sell(ids[1]);
        assertEq(_budget(), snap * 100 / 10_000, "the budget is unchanged by funding and spending");
        assertEq(_snapshot(), snap, "the snapshot stays at the opening pot");
        vm.warp((block.timestamp / 60 + 1) * 60);
        uint256 snap2 = core.ethPot();
        _sell(ids[2]);
        assertEq(_snapshot(), snap2, "the next bucket snapshots the grown pot");
        assertEq(_budget(), snap2 * 100 / 10_000, "and its budget scales with it");
        assertGt(_budget(), snap * 100 / 10_000, "the grown pot gives a larger budget");
    }

    // promise: a failing last credit rolls back the whole direct batch for both overloads
    function test_batchIsAtomicForBothOverloads() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 1 ether, 100);
        _fund(100 ether);
        bytes32 before_ = _state();
        vm.expectPartialRevert(ICore.SpendCapReached.selector);
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(_state(), before_);
        assertEq(CREDITS.ownerOf(ids[0]), seller);
        assertEq(CREDITS.ownerOf(ids[1]), seller);
        vm.expectPartialRevert(ICore.SpendCapReached.selector);
        vm.prank(seller);
        core.sellForEth(ids, 1);
        assertEq(_state(), before_);
    }

    // promise: minimum-output failure also rolls back snapshot, spend, custody and rate
    function test_minOutFailureRollsBackBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        bytes32 before_ = _state();
        // the single credit pays its scaled bid; a floor one wei above it fails `minOut`
        uint256 pay = core.bidOf(ids[0]);
        vm.expectRevert(ICore.Slippage.selector);
        vm.prank(seller);
        core.sellForEth(ids, pay + 1);
        assertEq(_state(), before_);
        assertEq(CREDITS.ownerOf(ids[0]), seller);
    }

    // promise: disabling the cap permits new inflows to be spent beyond the original snapshot, while counting outflow
    function test_bypassWithNewInflowsStillCounts() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 0.01 ether, 10_000);
        _fund(1 ether);
        uint256 snap = core.ethPot();
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        // a new inflow, then a second purchase whose outflow alone carries the total spent past the fixed snapshot. the
        // cap is disabled, so the only bound is the pot room; the rate targets a bid near the snapshot, inside the room
        _fund(2 ether);
        uint256 rate1 = snap * RATE_SCORE / _scoreOf(ids[1]);
        _flat(ids[1], rate1, 10_000);
        uint256 out1 = _outflow(ids[1]);
        _sell(ids[1]);
        assertEq(_snapshot(), snap, "the snapshot stays at the first purchase pot");
        assertEq(_spent(), out0 + out1, "every outflow is counted even past the snapshot");
        assertGt(out0 + out1, snap, "the second inflow is spent beyond the original snapshot");
    }

    // promise: cap edits reprice the original snapshot immediately without granting another unused budget
    function test_settingsAndRateEditsPreserveUsedBudget() public {
        uint256[] memory ids = _credits(seller, 2);
        _fund(100 ether);
        uint256 snap = core.ethPot();
        // target the first outflow at one percent of the snapshot, between the 0.5 percent cap below and the 2 percent
        // cap above, so the already-spent exceeds the tightened budget but leaves room under the loosened one
        uint256 rate0 = (snap * 100 / 10_000) * RATE_SCORE / _scoreOf(ids[0]);
        _flat(ids[0], rate0, 10_000);
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        Settings memory s = core.settings();
        s.spendCapBps = 50;
        s.bucketSeconds = 100;
        s.keeperFee += 1;
        _setSettings(s);
        assertEq(_spent(), out0);
        assertEq(_snapshot(), snap);
        assertEq(_budget(), snap * 50 / 10_000);
        assertGt(out0, snap * 50 / 10_000, "the already-spent exceeds the tightened budget");
        _flat(ids[1], 0.1 ether, 50);
        assertEq(_spent(), out0);
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, out0, cost, snap * 50 / 10_000));
        _sell(ids[1]);
        s = core.settings();
        s.spendCapBps = 200;
        _setSettings(s);
        uint256 out1 = _outflow(ids[1]);
        assertLe(out0 + out1, snap * 200 / 10_000, "the loosened budget covers both outflows");
        _sell(ids[1]);
        assertEq(_spent(), out0 + out1);
    }

    // promise: a keeper fill includes its caller payment and shares the direct seller's budget
    function test_keeperAndDirectShareBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_C);
        _flat(LISTED_C, price * 2, 100);
        _fund(price * 300);
        uint256 pot = core.ethPot();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_C, "");
        uint256 outflow = pot - core.ethPot();
        assertEq(outflow, price + keeper.balance - keeperBefore);
        assertEq(_spent(), outflow);
        // a direct sell whose scaled bid pushes the shared budget over reverts: the keeper fill already opened it
        uint256 rate0 = _budget() * RATE_SCORE / _scoreOf(ids[0]);
        _flat(ids[0], rate0, 100);
        vm.expectPartialRevert(ICore.SpendCapReached.selector);
        _sell(ids[0]);
    }

    // promise: balance-token purchases neither consume nor reset the ETH purchase budget
    function test_balancePurchasesAreExcluded() public {
        _enterPhase2();
        // the live Core carries a stale bucket from before the pin, so the eth spend slots are read before and after:
        // a balance sell must leave both untouched
        uint256 spentBefore = _spent();
        uint256 snapBefore = _snapshot();
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(_spent(), spentBefore, "a balance purchase does not consume the eth budget");
        assertEq(_snapshot(), snapBefore, "nor resets its snapshot");
    }

    // promise: spend cap rejects 0 and values above a whole share while accepting both endpoints
    function test_spendCapBounds() public {
        Settings memory s = core.settings();
        s.spendCapBps = 0;
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("spendCapBps")));
        _setSettings(s);
        s.spendCapBps = 1;
        _setSettings(s);
        s.spendCapBps = 10_000;
        _setSettings(s);
        s.spendCapBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("spendCapBps")));
        _setSettings(s);
    }

    // promise: the first purchase snapshots the booked pending-fee share and excludes the reserve
    function test_pendingFeesAreBookedBeforeSnapshot() public {
        uint256[] memory ids = _credits(seller, 1);
        _flat(ids[0], 0.001 ether, 100);
        _fund(10 ether);
        autoBook = false;
        _buyCoin(funder, 1 ether);
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0, "a swap left fee income unbooked");
        // the first purchase books the pending fee share into the pot and snapshots the booked pot; booking it here
        // gives the pot that purchase will snapshot (the booking formula is test/Book.t.sol, not recomputed here)
        core.book();
        uint256 expected = core.ethPot();
        _sell(ids[0]);
        assertEq(_snapshot(), expected);
        assertEq(_budget(), expected * 100 / 10_000);
    }

    // promise: a direct purchase followed by a keeper fill uses the same opening snapshot
    function test_directThenKeeperSharesBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        uint256 snap = core.ethPot();
        uint256 out0 = _outflow(ids[0]);
        _sell(ids[0]);
        uint256 before_ = core.ethPot();
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_C);
        _flat(LISTED_C, price * 2, 100);
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_C, "");
        assertEq(_spent(), out0 + before_ - core.ethPot());
        assertEq(_snapshot(), snap);
    }

    // promise: a venue call failing its custody check leaves both the purchase budget and ETH untouched
    function test_failedVenueRollsBackWithoutOpeningBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        bytes32 before_ = _state();
        uint256 targetBalance = address(0xBEEF).balance;
        vm.expectRevert(ICore.NoCredit.selector);
        _buyRaw(1, "", ids[0], address(0xBEEF));
        assertEq(_state(), before_);
        assertEq(address(0xBEEF).balance, targetBalance);
    }
}

/// the two budget promises that need an input no live pot or clock can produce: a pot small enough that the budget
/// rounds to zero, and absolute timestamps that make a later bucket's numeric id collide with an earlier one. both run
/// on the fresh `Fixture` deploy with a controlled pot and a mocked unit score, so the per-credit outflow equals the
/// stored rate exactly. the live counterparts on `SpendCapTest` cover the general shape of each
contract SpendCapControlledTest is Fixture {
    uint256 private constant SPEND_SLOT = 39;

    function _settings() internal view override returns (Settings memory s) {
        s = Mainnet.defaultSettings();
        // the budget suites price wei sized pots; the reserve floor is test/Reserve.t.sol's
        s.reserveWei = 0;
        // the ledger counts the artist royalty as outflow (test/ArtistRoyalty.t.sol); the budget promises here read
        // the price alone, so the royalty is off
        s.buyToArtistBps = 0;
    }

    function _fund(uint256 amount) private {
        vm.deal(funder, amount);
        vm.prank(funder);
        core.fund{value: amount}();
    }

    function _flat(uint256 id, uint256 rate, uint16 cap) private {
        Settings memory s = core.settings();
        s.rateCap = 1 ether;
        s.dropFloorBps = 10_000;
        s.spendCapBps = cap;
        _setSettings(s);
        // the credit reads as 100 points, so its bid is the full rate (score over 100 points is 1)
        _unitScore(id);
        vm.prank(owner);
        core.setRate(rate);
    }

    function _sell(uint256 id) private {
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    function _budget() private view returns (uint256) {
        return uint128(uint256(vm.load(address(core), bytes32(SPEND_SLOT))) >> 72);
    }

    function _spent() private view returns (uint256) {
        return uint128(uint256(vm.load(address(core), bytes32(SPEND_SLOT + 1))));
    }

    function _snapshot() private view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(SPEND_SLOT + 2)));
    }

    // promise: an old expired bucket is not mistaken for an active bucket when its new numeric id happens to match
    /// live counterpart: SpendCapTest.test_exactBudgetAndNextBucket (the next bucket opens a fresh snapshot and budget)
    function test_durationEditAfterExpirySnapshotsFresh() public {
        uint256[] memory ids = _credits(seller, 2);
        vm.warp(120);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        _sell(ids[0]);
        vm.warp(220);
        Settings memory s = core.settings();
        s.bucketSeconds = 100;
        _setSettings(s);
        _flat(ids[1], 0.1 ether, 100);
        _sell(ids[1]);
        assertEq(_spent(), 0.1 ether);
        assertEq(_snapshot(), 99.9 ether);
    }

    // promise: bucket zero initializes normally; a zero-rounded budget admits the first purchase and refuses the second
    /// live counterpart: SpendCapTest.test_firstPurchaseOfABucketPassesASubCreditBudget (a sub-credit budget passes the
    /// first purchase and reverts the second)
    function test_zeroBucketAndZeroRoundedBudget() public {
        uint256[] memory ids = _credits(seller, 2);
        vm.warp(1);
        _flat(ids[0], 1, 1);
        _fund(9_999);
        _sell(ids[0]);
        assertEq(_spent(), 1);
        assertEq(_budget(), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, 1, core.bidOf(ids[1]), 0));
        _sell(ids[1]);
        assertEq(_spent(), 1);
    }
}
