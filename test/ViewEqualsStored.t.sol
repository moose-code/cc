// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";

/// @notice every value a view quotes equals the value the next call uses, in the same block, after fee income arrives
/// with no engine call and after idle time. the eth bid (`ethRate`, `bidOf` against the `sellForEth` payout), the
/// balance bid (`balanceBidOf` against the `sellForBalance` payout), and the purchase budget (`spendState` against the
/// budget the next purchase enforces). cold cases, hand set state, numbers logged. the equalities hold because every
/// door books the unbooked fee income as its first step and the views read the same pending aware pot: the bid
/// checkpoints against it, and the purchase budget projects `spendCapBps` of it, the pot the first purchase snapshots.
contract ViewEqualsStoredTest is Fixture {
    /// forces `amount` wei into the Core with no engine call, the way a selfdestruct or a raw hook transfer lands eth
    /// the Core has not booked
    function _pushUnbooked(uint256 amount) internal {
        vm.deal(address(core), address(core).balance + amount);
    }

    /// sells `id` once for eth, returns the wei the seller received
    function _sellOneForEth(address who, uint256 id) internal returns (uint256 paid) {
        uint256 before = who.balance;
        vm.prank(who);
        core.sellForEth(_one(id));
        paid = who.balance - before;
    }

    // ------------------------------------------------------------------ eth bid

    // promise: a fresh deploy quotes the eth bid the first fill pays
    function test_ethBidEqualsFill_freshDeployOneSell() public {
        _skipSniperWindow();
        _addToPot(0.5 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        uint256 quotedRate = core.ethRate();
        uint256 quotedBid = core.bidOf(id);
        uint256 paid = _sellOneForEth(seller, id);
        emit log_named_uint("ethRate quoted (wei per 100 points)", quotedRate);
        emit log_named_uint("bidOf quoted (wei)", quotedBid);
        emit log_named_uint("fill paid (wei)", paid);
        assertEq(paid, quotedBid, "fill paid differs from the bid quoted in the same block");
    }

    // promise: unbooked fee income then idle time: bidOf equals the eth the next fill pays
    function test_ethBidEqualsFill_unbookedIncomeThenWarp() public {
        _skipSniperWindow();
        _addToPot(0.5 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        // fee income arrives with no engine call, then ten idle minutes climb the price state
        _pushUnbooked(0.3 ether);
        _warp(10 minutes);
        uint256 quotedRate = core.ethRate();
        uint256 quotedBid = core.bidOf(id);
        uint256 paid = _sellOneForEth(seller, id);
        emit log_named_uint("ethRate quoted with unbooked income (wei per 100 points)", quotedRate);
        emit log_named_uint("bidOf quoted (wei)", quotedBid);
        emit log_named_uint("fill paid (wei)", paid);
        assertEq(paid, quotedBid, "fill paid differs from the bid quoted while income waited unbooked");
    }

    // promise: a fresh launch with only unbooked hook income (ethPot zero): bidOf equals the next fill payout
    function test_ethBidEqualsFill_freshLaunchOnlyUnbookedIncome() public {
        _skipSniperWindow();
        // the exact launch stall state of decision 147: no door has booked, so ethPot is zero while the Core holds eth
        assertEq(core.ethPot(), 0, "the fresh fixture has an empty pot");
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        _pushUnbooked(1 ether);
        _warp(30 minutes);
        uint256 quotedRate = core.ethRate();
        uint256 quotedBid = core.bidOf(id);
        uint256 paid = _sellOneForEth(seller, id);
        emit log_named_uint("ethPot booked (wei)", 0);
        emit log_named_uint("ethRate quoted, empty booked pot (wei per 100 points)", quotedRate);
        emit log_named_uint("bidOf quoted (wei)", quotedBid);
        emit log_named_uint("fill paid (wei)", paid);
        assertEq(paid, quotedBid, "fresh launch fill paid differs from the bid quoted over unbooked income");
    }

    // ------------------------------------------------------------------ balance bid

    // promise: balance tokens arrive at the module then idle time: balanceBidOf equals the next fill payout
    function test_balanceBidEqualsFill_tokensArriveThenWarp() public {
        _enterPhase2();
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        // the module available() is the balance pot of the balance bid; tokens land at it with no engine call
        xt.mint(address(mod), 1e22);
        _warp(10 minutes);
        uint256 quotedRate = core.balanceRate();
        uint256 quotedBid = core.balanceBidOf(id);
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(_one(id));
        uint256 paid = xt.balanceOf(seller) - before;
        emit log_named_uint("balanceRate quoted (bps of par)", quotedRate);
        emit log_named_uint("balanceBidOf quoted (balance token)", quotedBid);
        emit log_named_uint("fill paid (balance token)", paid);
        assertEq(paid, quotedBid, "balance fill paid differs from balanceBidOf quoted in the same block");
    }

    // ------------------------------------------------------------------ purchase budget

    /// @dev spendState quotes the purchase budget as `spendCapBps` of the pages pot (`ethPot` plus the pot share of the
    /// unbooked fee income the next `_book` adds). the first purchase of a fresh bucket books that income first and
    /// snapshots `(ethPot + pendingShare) * spendCapBps`, so the quote equals the budget the next purchase enforces
    /// (decision 147: the spend view follows the same pending aware pot the climb clamp does)
    // promise: spendState quotes the purchase budget the next purchase of the bucket enforces
    function test_spendBudgetQuotedEqualsEnforced_withUnbookedIncome() public {
        (uint128 quoted, uint128 enforced,) = _spendBudgetQuotedAndEnforced();
        assertEq(quoted, enforced, "the purchase budget quoted differs from the budget the next purchase enforces");
    }

    // promise: records the spendState quote against the enforced budget with its numbers
    function test_spendBudgetDivergenceNumbers() public {
        (uint128 quoted, uint128 enforced, uint256 pot) = _spendBudgetQuotedAndEnforced();
        emit log_named_uint("booked pot at the quote (wei)", pot);
        emit log_named_uint("spendState budget quoted (wei)", quoted);
        emit log_named_uint("budget the next purchase enforced (wei)", enforced);
        emit log_named_int("enforced minus quoted (wei)", int256(uint256(enforced)) - int256(uint256(quoted)));
    }

    /// @dev sets a binding cap, books a pot, opens a fresh bucket, pushes unbooked income, reads the quoted budget,
    /// runs the first purchase of the bucket, and reads the budget that purchase snapshotted (the enforced budget)
    function _spendBudgetQuotedAndEnforced() internal returns (uint128 quoted, uint128 enforced, uint256 pot) {
        _skipSniperWindow();
        Settings memory s = core.settings();
        s.spendCapBps = 5_000; // 50 percent, so the budget binds
        _setSettings(s);
        _addToPot(1 ether);
        // a fresh bucket with no purchase yet, so spendState reads the opening pot budget
        _warp(uint256(s.bucketSeconds) + 1);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        // fee income arrives with no engine call
        _pushUnbooked(1 ether);
        pot = core.ethPot();
        (, quoted,) = core.spendState();
        _sellOneForEth(seller, id); // the first purchase of the bucket books the income and snapshots the budget
        (, enforced,) = core.spendState();
    }
}
