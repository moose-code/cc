// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ValueBase} from "./ValueMode.t.sol";
import {Settings, Quote} from "../src/interfaces/Interfaces.sol";

/// a sustained pool push against the value mode reference, on a real v4 pool holding $20,000 at an ETH price of $3,000.
/// the attacker owns the credits, pushes the pool spot up 8 percent with a real swap, holds it through the refreshes the
/// quote window needs, sells into the eth bid and swaps the pool back. net = the extra eth the manipulated sale pays over
/// the same sale with no push, less the attacker's pool round trip loss, less the swap gas at 0.5 gwei. pool arbitrage is
/// not modelled, which favors the attacker
contract ReferenceManipulationTest is ValueBase {
    uint256 internal constant ETH_USD = 3_000;
    uint256 internal constant POOL_USD = 20_000;
    /// full range liquidity holding `POOL_USD`: the pool holds 0.7 L eth and 1.4286 L tokens at the opening spot, so its
    /// value in eth is 1.4 L
    uint128 internal constant LIQ = uint128((POOL_USD * 1e18 / ETH_USD) * 10 / 14);
    uint256 internal constant GAS_PRICE = 0.5 gwei;
    uint256 internal constant PUSH_BPS = 800;
    /// the launch spend budget: 20 bps of a 10 eth pot, 0.02 eth per 1,800 second bucket. the fixture pot is larger than
    /// 10 eth, so the test sets the cap in bps that yields the same budget in wei
    uint256 internal constant BUDGET = 0.02 ether;
    uint32 internal constant BUCKET = 1_800;

    uint256[] internal ids;

    struct Run {
        bool ok;
        uint256 payout;
        uint256 poolLoss;
        uint256 gasCost;
    }

    function setUp() public override {
        super.setUp();
        _addFullRange(-int256(uint256(POOL_LIQ - LIQ)));
    }

    // ------------------------------------------------------------------ helpers

    function _refresh() internal {
        _warp(600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
    }

    function _quote(uint8 samples, uint16 step) internal {
        _setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: step,
                tolBps: 100,
                referenceMaxStale: 3_600,
                referenceMinSeconds: 600,
                minLiquidity: 1e18,
                referenceSamples: samples
            })
        );
    }

    /// the pot funded, the quote with two healthy refreshes, value mode on, ten credits at the attacker. `capOn` sets the
    /// spend cap to a `BUDGET` wei budget per `bucket` seconds, off leaves 9,999 bps
    function _arm(uint8 samples, uint16 step, bool capOn, uint32 bucket) internal {
        _fundPot(10 ether);
        _quote(samples, step);
        _refresh();
        _refresh();
        _valueOn();
        Settings memory s = core.settings();
        uint256 bps = BUDGET * 10_000 / core.ethPot();
        s.spendCapBps = capOn ? uint16(bps == 0 ? 1 : bps) : 9_999;
        s.bucketSeconds = bucket;
        _setSettings(s);
        ids = _credits(seller, 10);
    }

    function _wealth(uint256 spot0) internal view returns (uint256) {
        return address(this).balance + xt.balanceOf(address(this)) * spot0 / 1e18;
    }

    /// one world from the armed state: an optional push, `samples` refreshes, a sale of the first `k` credits, an
    /// optional swap back. the state is restored at the end
    function _run(bool push, uint256 k, uint8 samples) internal returns (Run memory r) {
        uint256 snap = vm.snapshotState();
        (uint256 spot0,) = ctl.spotPrice();
        vm.deal(address(this), 2_000 ether);
        uint256 w0 = _wealth(spot0);
        uint256 gasUsed;
        if (push) {
            uint160 limit = _sqrtOf(spot0 * (10_000 + PUSH_BPS) / 10_000);
            uint256 g = gasleft();
            router.swapWithLimit{value: 1_000 ether}(key, true, -int256(1_000 ether), limit, address(this), "");
            gasUsed += g - gasleft() + 21_000;
        }
        for (uint256 i; i < samples; ++i) {
            _refresh();
        }
        vm.roll(block.number + 1);
        uint256[] memory batch = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            batch[i] = ids[i];
        }
        uint256 before = seller.balance;
        vm.prank(seller);
        try core.sellForEth(batch) {
            r.ok = true;
            r.payout = seller.balance - before;
        } catch {}
        if (push) {
            uint160 back = _sqrtOf(spot0);
            uint256 g2 = gasleft();
            router.swapWithLimit(key, false, -int256(1e24), back, address(this), "");
            gasUsed += g2 - gasleft() + 21_000;
            uint256 w1 = _wealth(spot0);
            r.poolLoss = w0 > w1 ? w0 - w1 : 0;
            r.gasCost = gasUsed * GAS_PRICE;
        }
        vm.revertToState(snap);
    }

    function _attack(uint256 k, uint8 samples, string memory label) internal returns (int256 net, uint256 extraBps) {
        Run memory base = _run(false, k, samples);
        Run memory man = _run(true, k, samples);
        net = int256(man.payout) - int256(base.payout) - int256(man.poolLoss) - int256(man.gasCost);
        extraBps = man.payout > base.payout && base.payout != 0 ? (man.payout - base.payout) * 10_000 / base.payout : 0;
        emit log_string(label);
        emit log_named_uint("  credits", k);
        emit log_named_uint("  baseline payout wei", base.payout);
        emit log_named_uint("  manipulated payout wei", man.payout);
        emit log_named_uint("  extra payout bps", extraBps);
        emit log_named_uint("  pool round trip loss wei", man.poolLoss);
        emit log_named_uint("  swap gas cost wei", man.gasCost);
        emit log_named_int("  net wei", net);
        emit log_named_uint("  baseline sale fills", base.ok ? 1 : 0);
        emit log_named_uint("  manipulated sale fills", man.ok ? 1 : 0);
    }

    /// the largest batch up to ten credits the spend budget lets the manipulated world sell
    function _maxBatch(uint8 samples) internal returns (uint256 k) {
        for (k = 10; k > 1; --k) {
            if (_run(true, k, samples).ok) return k;
        }
        return 1;
    }

    // ------------------------------------------------------------------ the new rules: 3 samples, step 50, spend cap

    // promise: with 3 samples, a 50 bps step and the spend cap, one credit sold into an 8 percent push loses
    function test_newRulesOneCredit() public {
        _arm(3, 50, true, BUCKET);
        (, uint128 budget,) = core.spendState();
        assertLe(budget, 0.021 ether, "the bucket budget is 0.02 eth");
        (int256 net,) = _attack(1, 3, "new rules");
        assertLe(net, 0, "one credit nets at most zero");
    }

    // promise: the spend cap refuses a ten credit batch after its first credit, and the attack loses
    function test_newRulesTenCredits() public {
        _arm(3, 50, true, BUCKET);
        assertFalse(_run(true, 10, 3).ok, "ten credits exceed the bucket budget");
        (int256 net,) = _attack(10, 3, "new rules, ten credits");
        assertLe(net, 0, "ten credits net at most zero");
    }

    // promise: the largest batch the bucket budget allows loses
    function test_newRulesLargestAllowedBatch() public {
        _arm(3, 50, true, BUCKET);
        uint256 k = _maxBatch(3);
        emit log_named_uint("largest batch", k);
        (int256 net,) = _attack(k, 3, "new rules, largest batch");
        assertLe(net, 0, "the largest allowed batch nets at most zero");
    }

    // promise: the extra payout of a sale after a held push is at most the reference step compounded with the band,
    // (1 + 50 bps)(1 + 100 bps), against (1 + 200 bps)(1 + 100 bps) under the old rules. with the spend cap off the ten
    // credit net is positive, so the cap is part of the fix
    function test_newQuoteBoundsTheExtraPayoutAndTheCapBoundsTheBatch() public {
        uint256 snap = vm.snapshotState();
        _arm(1, 200, false, 60);
        (int256 oldNet, uint256 oldBps) = _attack(10, 1, "old rules, cap off");
        vm.revertToState(snap);
        _arm(3, 50, false, 60);
        (int256 uncapped, uint256 newBps) = _attack(10, 3, "new quote, cap off, ten credits");
        assertLe(newBps, 155, "extra payout at most 1.55 percent of the sale");
        assertGe(oldBps, 295, "old rules pay about 3 percent extra");
        assertLt(uncapped, oldNet, "the new quote cuts the ten credit net");
    }

    // ------------------------------------------------------------------ the old rules: 1 sample, step 200, cap off

    // promise: with one sample, a 200 bps step and the cap off, ten credits profit, so the new rules change the outcome
    function test_oldRulesTenCreditsProfit() public {
        _arm(1, 200, false, 60);
        (int256 one,) = _attack(1, 1, "old rules");
        (int256 ten,) = _attack(10, 1, "old rules");
        emit log_named_int("old rules net, 1 credit", one);
        assertGt(ten, 0, "ten credits profit under the old rules");
    }

    // ------------------------------------------------------------------ release and honest moves

    // promise: a push released before the Nth refresh leaves the reference and the bid unmoved
    function test_pushReleasedBeforeTheThirdRefreshDoesNotMoveTheReference() public {
        _quote(3, 50);
        _refresh();
        _refresh();
        uint256 ref0 = ctl.referencePrice();
        (uint256 spot0,) = ctl.spotPrice();
        (uint256 bid0,) = ctl.valuePerPoint(false);
        vm.deal(address(this), 2_000 ether);
        router.swapWithLimit{value: 1_000 ether}(
            key, true, -int256(1_000 ether), _sqrtOf(spot0 * (10_000 + PUSH_BPS) / 10_000), address(this), ""
        );
        _refresh();
        _refresh();
        assertApproxEqRel(ctl.referencePrice(), ref0, 1e15, "two held refreshes leave the reference");
        router.swapWithLimit(key, false, -int256(1e24), _sqrtOf(spot0), address(this), "");
        _refresh();
        assertApproxEqRel(ctl.referencePrice(), ref0, 1e15, "the release leaves the reference");
        vm.roll(block.number + 1);
        (uint256 bid1,) = ctl.valuePerPoint(false);
        assertApproxEqRel(bid1, bid0, 1e15, "the bid price is unchanged");
    }

    // promise: a genuine 20 percent rise is tracked by the reference within 42 refreshes (7 hours)
    function test_honestTwentyPercentMoveIsTracked() public {
        _quote(3, 50);
        _refresh();
        _refresh();
        uint256 spot = _swapSpot(2_000);
        uint256 n;
        while (ctl.referencePrice() < spot * 9_999 / 10_000 && n < 80) {
            _refresh();
            ++n;
        }
        emit log_named_uint("refreshes to track a 20 percent rise", n);
        emit log_named_uint("hours", n * 600 / 3_600);
        assertLe(n, 42, "tracked within 42 refreshes");
        assertGe(n, 36, "the step bounds the speed");
    }
}
