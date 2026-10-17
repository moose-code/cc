// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ColdAuditTest} from "./ColdAudit.t.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Quote} from "../src/interfaces/Interfaces.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FinalAuditTest is ColdAuditTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    // promise: a reference refresh that pays from an already booked pot emits a Core event that lets the indexer
    // record the changed pot in a block with no other Core call
    function test_paidRefreshHasNoCoreEventForPotDebit() public {
        _valuePool();
        core.fund{value: 1 ether}();
        uint256 potBefore = core.ethPot();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        vm.recordLogs();
        uint256 callerBefore = keeper.balance;
        vm.prank(keeper);
        core.refreshReference();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid = keeper.balance - callerBefore;
        uint256 coreEvents;
        uint256 controllerEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core)) coreEvents++;
            if (logs[i].emitter == address(ctl)) controllerEvents++;
        }
        assertGt(paid, 0, "the refresh paid the keeper");
        assertEq(core.ethPot(), potBefore - paid, "the pot changed");
        assertEq(coreEvents, 0, "no Core event triggers an indexer snapshot");
        assertEq(controllerEvents, 1, "only ReferenceRefreshed is emitted");
        emit log_named_uint("unindexed refresh payment wei", paid);
    }

    // promise: a prior-block spot sample prevents a pool round trip across a refresh boundary from raising a
    // Credit sell payout enough to cover the pool fee and base-fee gas
    function test_priorBlockSampleCanBeManipulatedAcrossRefresh() public {
        _valuePool();
        _addToPot(10 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        uint256 baseline = seller.balance - sellerBefore;
        vm.revertToState(snap);

        uint256 tokenBefore = xt.balanceOf(address(this));
        uint256 gasStart = gasleft();
        router.swap{value: 0.03 ether}(balanceKey, true, -int256(0.03 ether), address(this));
        uint256 gasUsed = gasStart - gasleft();
        uint256 tokenBought = xt.balanceOf(address(this)) - tokenBefore;
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        gasStart = gasleft();
        ctl.refreshReference();
        gasUsed += gasStart - gasleft();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        sellerBefore = seller.balance;
        gasStart = gasleft();
        vm.prank(seller);
        core.sellForEth(ids);
        gasUsed += gasStart - gasleft();
        uint256 manipulated = seller.balance - sellerBefore;
        uint256 ethBeforeReverse = address(this).balance;
        gasStart = gasleft();
        router.swap(balanceKey, false, -int256(tokenBought), address(this));
        gasUsed += gasStart - gasleft();
        uint256 poolLoss = 0.03 ether - (address(this).balance - ethBeforeReverse);
        uint256 gasCost = gasUsed * block.basefee;
        emit log_named_uint("baseline payout wei", baseline);
        emit log_named_uint("manipulated payout wei", manipulated);
        emit log_named_uint("pool round trip loss wei", poolLoss);
        emit log_named_uint("four call base fee gas wei", gasCost);
        assertGt(manipulated - baseline, poolLoss + gasCost, "the cross-block manipulation is profitable");
    }

    // promise: a prior-block spot sample prevents a pool round trip across a refresh boundary from lowering a
    // Credit purchase price enough to cover the pool fee and base-fee gas
    function test_priorBlockSampleCanDiscountCreditPurchase() public {
        _valuePool();
        _setCreditSaleOn(true);
        _addToPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 baseline = ctl.creditPrice(id);
        ctl.buyCredit{value: baseline}(id);
        vm.revertToState(snap);

        uint256 ethBeforeSwap = address(this).balance;
        uint256 gasStart = gasleft();
        router.swap(balanceKey, false, -int256(5e16), address(this));
        uint256 gasUsed = gasStart - gasleft();
        uint256 ethFromSwap = address(this).balance - ethBeforeSwap;
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        gasStart = gasleft();
        ctl.refreshReference();
        gasUsed += gasStart - gasleft();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 discounted = ctl.creditPrice(id);
        gasStart = gasleft();
        ctl.buyCredit{value: discounted}(id);
        gasUsed += gasStart - gasleft();
        uint256 ethBeforeReverse = address(this).balance;
        gasStart = gasleft();
        router.swap{value: 1 ether}(balanceKey, true, int256(5e16), address(this));
        gasUsed += gasStart - gasleft();
        uint256 poolLoss = ethBeforeReverse - address(this).balance - ethFromSwap;
        uint256 gasCost = gasUsed * block.basefee;
        emit log_named_uint("baseline purchase price wei", baseline);
        emit log_named_uint("discounted purchase price wei", discounted);
        emit log_named_uint("pool round trip loss wei", poolLoss);
        emit log_named_uint("four call base fee gas wei", gasCost);
        assertGt(baseline - discounted, poolLoss + gasCost, "the cross-block discount exceeds its cost");
    }

    // promise: the liquidity floor represents depth present through the whole observation interval, rather than
    // liquidity added only in each of two sampled blocks and removed immediately afterward
    function test_twoJitBlocksOpenQuoteWithNoLiveDepth() public {
        _valuePool();
        vm.prank(owner);
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 450,
                referenceMaxStale: 1 hours,
                referenceMinSeconds: 600,
                minLiquidity: 2e18
            })
        );
        TestLiquidityHelper jit = new TestLiquidityHelper();
        xt.approve(address(jit), type(uint256).max);
        (, bool before) = ctl.valuePerPoint(false);
        assertFalse(before);
        for (uint256 i; i < 2; ++i) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            jit.modify{value: 2 ether}(balanceKey, -887220, 887220, int256(1e18));
            assertEq(PM.getLiquidity(balanceKey.toId()), 2e18);
            assertTrue(ctl.refreshReference());
            jit.modify(balanceKey, -887220, 887220, -int256(1e18));
            assertEq(PM.getLiquidity(balanceKey.toId()), 1e18);
        }
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        (, bool after_) = ctl.valuePerPoint(false);
        assertTrue(after_, "two transient samples opened the quote with current depth below minLiquidity");
        emit log_named_uint("configured minLiquidity", 2e18);
        emit log_named_uint("live liquidity after both JIT removals", PM.getLiquidity(balanceKey.toId()));
    }

    // promise: a balance token transferred directly to Core can be moved into the active module for use or recovery
    function test_directBalanceTokenDonationStillCannotBeRecovered() public {
        _enterPhase2();
        xt.mint(address(core), 1e18);
        uint256 moduleBefore = mod.available();
        core.book();
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.rescueToken(address(xt), address(mod), 1e18);
        assertEq(xt.balanceOf(address(core)), 1e18);
        assertEq(mod.available(), moduleBefore);
        emit log_named_uint("balance tokens stranded in Core", xt.balanceOf(address(core)));
    }

    // promise: the phase-two launch harness leaves real hook fees pending until an actual keeper or user door books
    function test_phaseTwoFixtureBooksEachRealTradeImmediately() public {
        _enterPhase2();
        uint256 snap = vm.snapshotState();
        _buyCoin(funder, 0.005 ether);
        uint256 autoBooked = core.ethPot();
        assertGt(autoBooked, 0, "the default fixture called book after the pool swap");
        vm.revertToState(snap);
        autoBook = false;
        _buyCoin(funder, 0.005 ether);
        assertEq(core.ethPot(), 0, "the real hook push waits for the next engine call");
        uint256 pending = address(core).balance - core.ethToBuyback() - core.ethRedeemBurn();
        assertEq(pending, autoBooked, "both paths received the same real swap fee");
        emit log_named_uint("ETH fee booked by fixture immediately", autoBooked);
        emit log_named_uint("ETH fee pending without fixture book", pending);
    }

    // promise: launch fee income books wholly to the ETH buying pot while the redeem-burn share is zero
    function test_launchFeeFlowDoesNotFundRedeemBurn() public {
        autoBook = false;
        assertEq(core.settings().feeToRedeemBurnBps, 0);
        _buyCoin(funder, 0.005 ether);
        uint256 pending = address(core).balance;
        assertGt(pending, 0, "the real hook pushed ETH");
        core.book();
        assertEq(core.ethRedeemBurn(), 0);
        assertEq(core.ethPot(), pending);
        emit log_named_uint("real swap fee all booked to pot wei", pending);
    }

    // promise: an expired value quote leaves the last good ETH bid callable while controller sale quotes stop
    function test_staleValueQuoteFallsBackForEthBid() public {
        _valuePool();
        _addToPot(10 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 before = core.bidOf(ids[0]);
        vm.warp(block.timestamp + 3_601);
        uint256 stale = core.bidOf(ids[0]);
        assertGt(before, 0);
        assertGt(stale, 0, "Core retains a payable bid through a quote outage");
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - sellerBefore, stale);
        vm.expectRevert(IControllerV1.NoQuote.selector);
        ctl.creditPrice(ids[0]);
        emit log_named_uint("ETH payout on stale quote wei", stale);
    }
}
