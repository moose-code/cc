// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, ICreditScore, ICreditStrategy} from "../src/interfaces/Interfaces.sol";

contract SpendCapTest is Fixture {
    uint256 private constant SPEND_SLOT = 39;

    function _settings() internal view override returns (Settings memory s) {
        s = Mainnet.defaultSettings();
    }

    function _fund(uint256 amount) private {
        vm.deal(funder, amount);
        vm.prank(funder);
        core.fund{value: amount}();
    }

    function _score(uint256 id) private view returns (uint32) {
        return uint32(ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id)));
    }

    function _flat(uint256 id, uint256 rate, uint16 cap) private {
        Settings memory s = core.settings();
        s.rateCap = 1 ether;
        s.refScore = _score(id);
        s.dropFloorBps = 10_000;
        s.spendCapBps = cap;
        _setSettings(s);
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
        _sell(ids[0]);
        assertEq(_spent(), 1 ether);
        assertEq(_budget(), 1 ether);
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, 1 ether, cost, 1 ether));
        _sell(ids[1]);
        vm.warp((block.timestamp / 60 + 1) * 60);
        _flat(ids[1], 0.5 ether, 100);
        _sell(ids[1]);
        assertEq(_spent(), 0.5 ether);
        assertEq(_snapshot(), 99 ether);
    }

    // promise: the first purchase of a bucket passes a budget under one credit; the second reverts and the next bucket buys again
    function test_firstPurchaseOfABucketPassesASubCreditBudget() public {
        uint256[] memory ids = _credits(seller, 3);
        _flat(ids[0], 1 ether, 100);
        _fund(10 ether);
        _sell(ids[0]);
        assertEq(_budget(), 0.1 ether, "the budget is under one credit");
        assertEq(_spent(), 1 ether, "the full cost is recorded");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, 1 ether, cost, 0.1 ether));
        _sell(ids[1]);
        vm.warp((block.timestamp / 60 + 1) * 60);
        _flat(ids[1], 0.5 ether, 100);
        _sell(ids[1]);
        assertEq(CREDITS.ownerOf(ids[1]), address(core));
        assertEq(_spent(), 0.5 ether);
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
        _sell(ids[0]);
        (uint64 bucket, uint128 budget, uint128 spent) = core.spendState();
        assertEq(bucket, block.timestamp / 60);
        assertEq(budget, 1 ether);
        assertEq(spent, 1 ether);
        vm.warp((block.timestamp / 60 + 1) * 60);
        uint256 pot = core.ethPot();
        (uint64 next, uint128 nextBudget, uint128 nextSpent) = core.spendState();
        assertEq(next, bucket + 1);
        assertEq(nextBudget, pot / 100);
        assertEq(nextSpent, 0);
        _flat(ids[1], 0.5 ether, 100);
        _sell(ids[1]);
        (next, nextBudget, nextSpent) = core.spendState();
        assertEq(next, bucket + 1);
        assertEq(nextBudget, pot / 100);
        assertEq(nextSpent, 0.5 ether);
    }

    // promise: ordinary funding and spending never change the active opening-pot budget
    function test_snapshotFixedAndPotScaling() public {
        uint256[] memory ids = _credits(seller, 3);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        _sell(ids[0]);
        assertEq(_snapshot(), 100 ether);
        assertEq(_budget(), 1 ether);
        _fund(100 ether + 0.1 ether);
        assertEq(core.ethPot(), 200 ether);
        _sell(ids[1]);
        assertEq(_budget(), 1 ether);
        assertEq(_snapshot(), 100 ether);
        vm.warp((block.timestamp / 60 + 1) * 60);
        _fund(200 ether - core.ethPot());
        _sell(ids[2]);
        assertEq(_budget(), 2 ether);
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
        vm.expectRevert(ICore.Slippage.selector);
        vm.prank(seller);
        core.sellForEth(ids, 0.1 ether + 1);
        assertEq(_state(), before_);
        assertEq(CREDITS.ownerOf(ids[0]), seller);
    }

    // promise: disabling the cap permits new inflows to be spent beyond the original snapshot, while counting outflow
    function test_bypassWithNewInflowsStillCounts() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 0.01 ether, 10_000);
        _fund(1 ether);
        _sell(ids[0]);
        _fund(1 ether);
        _flat(ids[1], 1 ether, 10_000);
        _sell(ids[1]);
        assertEq(_snapshot(), 1 ether);
        assertEq(_spent(), 1.01 ether);
    }

    // promise: cap edits reprice the original snapshot immediately without granting another unused budget
    function test_settingsAndRateEditsPreserveUsedBudget() public {
        uint256[] memory ids = _credits(seller, 2);
        _flat(ids[0], 1 ether, 10_000);
        _fund(100 ether);
        _sell(ids[0]);
        Settings memory s = core.settings();
        s.spendCapBps = 50;
        s.bucketSeconds = 100;
        s.keeperFee += 1;
        _setSettings(s);
        assertEq(_spent(), 1 ether);
        assertEq(_snapshot(), 100 ether);
        assertEq(_budget(), 0.5 ether);
        _flat(ids[1], 0.1 ether, 50);
        assertEq(_spent(), 1 ether);
        uint256 cost = core.bidOf(ids[1]);
        vm.expectRevert(abi.encodeWithSelector(ICore.SpendCapReached.selector, 1 ether, cost, 0.5 ether));
        _sell(ids[1]);
        s = core.settings();
        s.spendCapBps = 200;
        _setSettings(s);
        _sell(ids[1]);
        assertEq(_spent(), 1.1 ether);
    }

    // promise: an old expired bucket is not mistaken for an active bucket when its new numeric id happens to match
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

    // promise: a keeper fill includes its caller payment and shares the direct seller's budget
    function test_keeperAndDirectShareBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _flat(LISTED_A, price * 2, 100);
        _fund(price * 300);
        uint256 pot = core.ethPot();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        uint256 outflow = pot - core.ethPot();
        assertEq(outflow, price + keeper.balance - keeperBefore);
        assertEq(_spent(), outflow);
        _flat(ids[0], _budget() - outflow + 1, 100);
        vm.expectPartialRevert(ICore.SpendCapReached.selector);
        _sell(ids[0]);
    }

    // promise: balance-token purchases neither consume nor reset the ETH purchase budget
    function test_balancePurchasesAreExcluded() public {
        _enterPhase2();
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(_spent(), 0);
        assertEq(_snapshot(), 0);
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
        assertGt(pending, 0);
        uint256 expected = core.ethPot() + pending - pending * core.settings().feeToRedeemBurnBps / 10_000;
        _sell(ids[0]);
        assertEq(_snapshot(), expected);
        assertEq(_budget(), expected * 100 / 10_000);
    }

    // promise: a direct purchase followed by a keeper fill uses the same opening snapshot
    function test_directThenKeeperSharesBudget() public {
        uint256[] memory ids = _credits(seller, 1);
        _flat(ids[0], 0.1 ether, 100);
        _fund(100 ether);
        _sell(ids[0]);
        uint256 before_ = core.ethPot();
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _flat(LISTED_A, price * 2, 100);
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        assertEq(_spent(), 0.1 ether + before_ - core.ethPot());
        assertEq(_snapshot(), 100 ether);
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
