// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";

/// a payee whose receive reverts
contract RevertingPayee {
    receive() external payable {
        revert("no");
    }
}

/// a payee whose receive burns all the gas it is given
contract GasBurningPayee {
    receive() external payable {
        assembly {
            invalid()
        }
    }
}

/// the payee share of the fee income: `payeePpm` of the income booked by `_book`, credited to `payeeOwed` and paid by
/// `claimPayee`. it starts with the first book that has income at or after `launchedAt + SNIPER_SECONDS`, and that book
/// shares nothing. every number comes from real swaps through the live pool and the live skim hook
contract PayeeShareTest is FeeBase {
    /// the share starts after the window, read from the factory record of the coin
    function test_theShareStartsAfterTheWindowFromTheFactoryRecord() public {
        (, uint256 launchedAt) = _launchRecord();
        assertEq(launchedAt, launchTime, "the launch time of the factory record");
        assertEq(core.SNIPER_SECONDS(), 1800);
        assertFalse(core.payeeOn());

        // a book inside the window shares nothing and does not turn the share on
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertFalse(core.payeeOn(), "inside the window");
        assertEq(core.payeeOwed(), 0);

        // one second before the end of the window
        vm.warp(launchedAt + core.SNIPER_SECONDS() - 1);
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertFalse(core.payeeOn(), "one second before the end");

        // at the end of the window the book with income turns the share on and shares nothing
        vm.warp(launchedAt + core.SNIPER_SECONDS());
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertTrue(core.payeeOn(), "the first book at the end of the window");
        assertEq(f.toPayee, 0, "that book shares nothing");
        assertEq(core.payeeOwed(), 0);

        // the next book shares
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertGt(f.toPayee, 0);
        assertEq(f.toPayee, f.bountyRise * 75_185 / 1_000_000, "75,185 ppm of the income");
    }

    /// a book without income does not turn the share on: the eth that arrives first after the window is the shared-free book
    function test_aBookWithoutIncomeDoesNotTurnTheShareOn() public {
        _skipSniperWindow();
        core.book();
        assertFalse(core.payeeOn());
        autoBook = false;
        _buyCoin(trader, 20 ether);
        uint256 held = address(core).balance - _tracked();
        assertGt(held, 0);
        core.book();
        assertTrue(core.payeeOn());
        assertEq(core.payeeOwed(), 0, "the window eth and the first income after it are not shared");
    }

    /// the share is 0.5 points of volume at launch: 75,185 ppm of 6.65022 points
    function test_theShareIsHalfAPointOfVolume() public {
        _stock();
        Flow memory f = _flow(Kind.BuyExactIn, 100 ether, "");
        assertEq(f.bountyRise, 6.65022 ether);
        assertApproxEqRel(f.toPayee, 0.5 ether, 0.00001e18, "0.5 points of 100 eth");
        assertLe(f.toPayee, 0.5 ether, "rounded down");
    }

    function test_bookCreditsThePayeeAndClaimPaysIt() public {
        _stock();
        assertEq(core.payee(), lc.payee);
        assertEq(core.settings().payeePpm, 75_185);
        address a = lc.payee;
        uint256 a0 = a.balance;
        uint256 owed0 = core.payeeOwed();
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(a.balance, a0, "the book pays nothing out");
        assertEq(core.payeeOwed() - owed0, f.bountyRise * 75_185 / 1_000_000);
        assertApproxEqRel(core.payeeOwed() - owed0, 0.05 ether, 0.01e18);
        uint256 owed = core.payeeOwed();
        address anyone = _user("claimer");
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.PayeeClaimed(a, owed);
        vm.prank(anyone);
        core.claimPayee();
        assertEq(a.balance - a0, owed, "the payee receives what is owed");
        assertEq(anyone.balance, 0, "the caller receives nothing");
        assertEq(core.payeeOwed(), 0);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.claimPayee();
        _solvent();
    }

    /// the owner replaces the payee with `setPayee` and the share with `setSettings`: later books credit the new share,
    /// the eth already owed is claimed by the new payee
    function test_ownerReplacesThePayeeAndTheShare() public {
        _stock();
        address a = lc.payee;
        address b = makeAddr("secondPayee");
        vm.expectEmit(true, false, false, false, address(core));
        emit ICore.PayeeSet(b);
        vm.prank(owner);
        core.setPayee(b);
        assertEq(core.payee(), b);
        Settings memory s = core.settings();
        s.payeePpm = 150_000;
        _setSettings(s);
        uint256 owed0 = core.payeeOwed();
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, f.bountyRise * 150_000 / 1_000_000);
        assertEq(f.potRise, _toPot(f.bountyRise - f.toPayee));
        core.claimPayee();
        assertEq(b.balance, owed0 + f.toPayee, "the new payee claims all of it");
        assertEq(a.balance, 0);
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setPayee(address(0));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setPayee(b);
    }

    /// the ppm bound is 200,000: above it `setSettings` reverts, at it the book credits a fifth of the income
    /// income that arrived before `setSettings` is split under the settings in force when it arrived
    function test_setSettingsBooksUnbookedIncomeUnderTheOldShare() public {
        _stock();
        Settings memory s = core.settings();
        uint256 oldPpm = s.payeePpm;
        uint256 owed0 = core.payeeOwed();
        vm.deal(address(core), address(core).balance + 1 ether);
        s.payeePpm = 200_000;
        _setSettings(s);
        assertEq(core.payeeOwed() - owed0, 1 ether * oldPpm / 1_000_000, "the unbooked income took the old share");
        _solvent();
    }

    function test_theShareBoundIsTwoHundredThousandPpm() public {
        Settings memory s = core.settings();
        s.payeePpm = 200_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("payeePpm")));
        core.setSettings(s);
        s.payeePpm = 200_000;
        _setSettings(s);
        _stock();
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, f.bountyRise / 5);
        s.payeePpm = 0;
        _setSettings(s);
        f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, 0, "a zero share credits nothing");
        assertEq(f.potRise, _toPot(f.bountyRise));
    }

    /// a payee that reverts, or that burns its gas, blocks only its own claim: every door and every swap works and the
    /// share stays owed. the owner replaces the payee and the claim goes through
    function test_aPayeeThatRevertsOrBurnsGasBlocksOnlyItsOwnClaim() public {
        _stock();
        address[2] memory bad = [address(new RevertingPayee()), address(new GasBurningPayee())];
        for (uint256 i; i < 2; ++i) {
            vm.prank(owner);
            core.setPayee(bad[i]);
            _flow(Kind.BuyExactIn, 10 ether, "");
            uint256 owed = core.payeeOwed();
            assertGt(owed, 0);
            vm.expectRevert(ICore.CallFailed.selector);
            core.claimPayee{gas: 3_000_000}();
            assertEq(core.payeeOwed(), owed, "the share stays owed");
        }
        // doors and swaps are unaffected
        _fillEthPile(5);
        _flow(Kind.SellExactIn, coin.balanceOf(trader) / 10, "");
        address good = makeAddr("goodPayee");
        vm.prank(owner);
        core.setPayee(good);
        uint256 owedNow = core.payeeOwed();
        core.claimPayee();
        assertEq(good.balance, owedNow, "the new payee is paid all that is owed");
        assertEq(core.payeeOwed(), 0);
        _solvent();
    }

    /// the payee cannot reenter the Core during its claim
    function test_claimIsGuardedAgainstReentry() public {
        _stock();
        ReenteringPayee p = new ReenteringPayee(core);
        vm.prank(owner);
        core.setPayee(address(p));
        _flow(Kind.BuyExactIn, 10 ether, "");
        uint256 owed = core.payeeOwed();
        core.claimPayee();
        assertEq(address(p).balance, owed);
        assertTrue(p.triedToReenter());
        assertFalse(p.reentered(), "the guard stopped the nested calls");
    }

    function _launchRecord() internal view returns (bool ok, uint256 launchedAt) {
        (bool o, bytes memory out) = address(FACTORY).staticcall(abi.encodeWithSignature("deploymentInfo(address)", address(coin)));
        ok = o;
        // word 0 is the offset, word 9 is launchedAt
        assembly ("memory-safe") {
            launchedAt := mload(add(out, add(0x20, mul(9, 0x20))))
        }
    }
}

/// a payee that tries to call back into the Core when it is paid
contract ReenteringPayee {
    ICore public immutable CORE;
    bool public triedToReenter;
    bool public reentered;

    constructor(ICore core_) {
        CORE = core_;
    }

    receive() external payable {
        triedToReenter = true;
        (bool a,) = address(CORE).call(abi.encodeCall(ICore.claimPayee, ()));
        (bool b,) = address(CORE).call(abi.encodeCall(ICore.book, ()));
        (bool c,) = address(CORE).call{value: 1}(abi.encodeCall(ICore.fund, ()));
        reentered = a || b || c;
    }
}

/// `feeToBuybackBps`: the share of the fee income after the payee share that `_book` adds to the coin buyback, the rest to
/// the pot. every number comes from real swaps through the live pool and the live skim hook, which pays its bounty leg
/// to the Core. `fund()` adds to the pot whole
contract FeeShareTest is FeeBase {
    uint256 internal constant BASIS = 10_000;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        // the redeem burn share is tested separately; zero it so feeToBuybackBps can take its whole range
        s.feeToRedeemBurnBps = 0;
        _setSettings(s);
    }

    struct Books {
        uint256 bounty;
        uint256 inflow;
        uint256 dPot;
        uint256 dBb;
        uint256 dBal;
    }

    /// one swap and a book, and what they did to the core's books. the bounty is what the hook itself reports it pushed
    /// to the core, the inflow is the income less the payee share
    function _swap(Kind kind, uint256 amount) internal returns (Books memory b) {
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        Flow memory f = _flow(kind, amount, "");
        b.bounty = f.skimBounty;
        b.inflow = f.bountyRise - f.toPayee;
        assertEq(f.bountyRise, f.skimBounty, "the core got the bounty leg");
        b.dPot = core.ethPot() - pot;
        b.dBb = core.ethToBuyback() - bb;
        b.dBal = address(core).balance - bal;
    }

    function _check(Books memory b, uint16 bps) internal pure {
        uint256 toBb = b.inflow * bps / BASIS;
        assertEq(b.dBb, toBb, "buyback share is floor(inflow * bps / 10000)");
        assertEq(b.dPot, b.inflow - toBb, "the rest is the pot share");
        assertEq(b.dBal, b.bounty, "the balance rose by the bounty leg");
    }

    function test_split_atZeroHalfAndAllOnExactBuys() public {
        _stock();
        uint16[3] memory bps = [uint16(0), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _share(bps[i]);
            Books memory b = _swap(Kind.BuyExactIn, 1 ether);
            assertEq(b.bounty, 0.0665022 ether, "6.65022 points of one eth reach the core");
            uint256 want = b.inflow * bps[i] / BASIS;
            assertEq(b.dBb, want, "exact buyback share");
            assertEq(b.dPot, b.inflow - want, "exact pot share");
            assertApproxEqAbs(b.inflow, 0.0615022 ether, 0.00001 ether, "6.15 points of the buy reach the engine (core 6.65022 less the payee 0.5)");
            _check(b, bps[i]);
            _solvent();
        }
    }

    function test_split_everySwapKindAndAnOddShare() public {
        _stock();
        _share(3_333);
        _check(_swap(Kind.BuyExactIn, 2 ether), 3_333);
        _check(_swap(Kind.BuyExactOut, 500_000e18), 3_333);
        _check(_swap(Kind.SellExactIn, coin.balanceOf(trader) / 5), 3_333);
        _check(_swap(Kind.SellExactOut, 0.3 ether), 3_333);
        _solvent();
    }

    /// inside the anti sniper window the core gets 89.75022 points (the bounty share of the baseline, 6.65022, plus the whole
    /// extra), none of it shared with the payee, and the engine share is split by the setting
    function test_split_insideTheSniperWindowTakesTheWholeBounty() public {
        _share(5_000);
        Books memory b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.bounty, 0.8975022 ether);
        assertEq(b.inflow, 0.8975022 ether);
        assertEq(b.dBb, b.inflow / 2);
        assertEq(b.dPot, b.inflow - b.inflow / 2);
        _check(b, 5_000);
    }

    function test_split_dustAmountsFromTheHook() public {
        address hook = lc.stack.hook;
        vm.deal(hook, 10 ether);
        _share(5_000);
        uint256[5] memory v = [uint256(0), 1, 3, 4, 10_001];
        for (uint256 i; i < v.length; ++i) {
            uint256 pot = core.ethPot();
            uint256 bb = core.ethToBuyback();
            vm.prank(hook);
            (bool ok,) = address(core).call{value: v[i]}("");
            assertTrue(ok, "receive never reverts");
            core.book();
            assertEq(core.ethToBuyback() - bb, v[i] * 5_000 / BASIS, "floor to the buyback");
            assertEq(core.ethPot() - pot, v[i] - v[i] * 5_000 / BASIS, "the odd wei stays with the pot");
        }
        _solvent();
    }

    /// a plain send from anyone else reverts, and `fund` adds to the pot whole whatever the share is
    function test_split_aSendFromAnyoneElseRevertsAndFundIsNotSplit() public {
        _share(10_000);
        vm.deal(address(this), 5 ether);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        (bool ok, bytes memory why) = address(core).call{value: 1 ether}("");
        assertFalse(ok, "refused");
        assertEq(bytes4(why), ICore.UseFund.selector);
        assertEq(address(core).balance, 0);
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Funded(address(this), 1 ether);
        core.fund{value: 1 ether}();
        assertEq(core.ethPot() - pot, 1 ether, "whole to the pot");
        assertEq(core.ethToBuyback(), bb, "none to the buyback");
    }

    // ------------------------------------------------------------------ book and bookBalance

    /// eth forced into the core is fee income at the next book: split by the settings like the hook's push
    function test_book_countsForcedEthAsIncome() public {
        _share(10_000);
        vm.deal(address(core), address(core).balance + 1.5 ether);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        core.book();
        assertEq(core.ethToBuyback() - bb, 1.5 ether, "the share is all to the buyback");
        assertEq(core.ethPot(), pot);
        assertEq(address(core).balance, _tracked());
        // a second book counts nothing
        core.book();
        assertEq(core.ethToBuyback() - bb, 1.5 ether);
    }

    /// the balance token sent to the core is booked by `bookBalance` to the bid pot
    function test_bookBalance_theBalanceTokenGoesToTheBidPot() public {
        _enterPhase2();
        xt.mint(address(core), 7e18);
        uint256 xp = core.balancePot();
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.BalanceBooked(7e18);
        core.bookBalance();
        assertEq(core.balancePot() - xp, 7e18);
        core.bookBalance();
        assertEq(core.balancePot() - xp, 7e18, "a second call books nothing");
    }

    function test_bookBalance_withoutAModuleDoesNothing() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.BalanceBooked(0);
        core.bookBalance();
        assertEq(core.balancePot(), 0);
    }

    // ------------------------------------------------------------------ a change of the setting

    function test_change_takesEffectOnTheNextFeeAndNeverRewritesTheBooks() public {
        _stock();
        _share(0);
        Books memory b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, 0);
        assertEq(b.dPot, b.inflow);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        _share(10_000);
        assertEq(core.ethPot(), pot, "the change moves no books");
        assertEq(core.ethToBuyback(), bb);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, b.inflow);
        assertEq(b.dPot, 0);
        _share(2_500);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, b.inflow * 2_500 / BASIS);
        assertEq(b.dPot, b.inflow - b.inflow * 2_500 / BASIS);
        _share(0);
        b = _swap(Kind.SellExactIn, coin.balanceOf(trader) / 10);
        assertEq(b.dBb, 0);
        assertEq(b.dPot, b.inflow);
        _solvent();
    }

    function test_change_boundIsTenThousand() public {
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = 0; // so feeToBuybackBps can reach its own bound without the sum bound binding
        s.feeToBuybackBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("feeToBuybackBps")));
        core.setSettings(s);
        s.feeToBuybackBps = 10_000;
        vm.prank(owner);
        core.setSettings(s);
        assertEq(core.settings().feeToBuybackBps, 10_000);
        vm.prank(address(0x5757));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setSettings(s);
    }

    /// with the whole fee going to the buyback the pot gets nothing from swaps, but the rate still checkpoints
    function test_change_allToTheBuybackLeavesThePotAndKeepsTheCheckpoint() public {
        _stock();
        _fundPot(1 ether);
        _share(10_000);
        _warp(6 hours);
        uint256 rate = core.ethRate();
        uint256 pot = core.ethPot();
        _swap(Kind.BuyExactIn, 1 ether);
        assertEq(core.ethPot(), pot, "the pot did not grow");
        assertEq(core.checkpointTime(), block.timestamp, "the fee still checkpoints");
        assertEq(core.rateAtCheckpoint(), rate);
    }
}

/// the fee that comes back to the core during its own `buyback()` swap is split like any other, and the buyback works
contract FeeShareBuybackTest is FeeBase {
    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        // the redeem burn share is tested separately; zero it so feeToBuybackBps can take its whole range
        s.feeToRedeemBurnBps = 0;
        _setSettings(s);
    }

    function _event(Vm.Log[] memory logs) internal pure returns (uint256 spent, uint256 tip) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.Buyback.selector) (spent, tip) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _run(uint16 bps) internal {
        _stock();
        _fillEthBuyback();
        _share(bps);
        uint256 pool = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        uint256 supply = coin.totalSupply();
        uint256 keeperEth = keeper.balance;
        uint256 slice = pool < 1 ether ? pool : 1 ether;
        assertGt(slice, 0);
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Flow memory f;
        _readSkim(f, logs);
        (uint256 spent, uint256 tip) = _event(logs);
        assertGt(f.skimBounty, 0, "the buyback swap paid the hook");
        assertEq(core.ethPot(), pot0, "the skim of the swap waits unbooked, not back inside the call");
        // the book counts the income, split by the share
        assertEq(address(core).balance - _tracked(), f.skimBounty);
        (, uint256 engine) = _payeeSplit(f.skimBounty);
        _book();
        assertEq(core.ethPot() - pot0, engine - engine * bps / 10_000, "pot share of the returning skim");
        assertEq(core.ethToBuyback(), pool - slice + engine * bps / 10_000 + (slice - spent - tip), "buyback pot");
        assertEq(keeper.balance - keeperEth, tip, "the keeper is paid what the event reports");
        assertLt(coin.totalSupply(), supply, "coin was bought and burned");
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(address(core).balance, _tracked(), "no unbooked eth");
        _solvent();
        // and the buyback works again with what came back, when it exceeds the largest payment (0.0065 ether at launch)
        if (core.ethToBuyback() > 0.01 ether) {
            vm.roll(block.number + core.settings().buybackDelay);
            uint256 s2 = coin.totalSupply();
            vm.prank(keeper);
            core.buyback();
            assertLt(coin.totalSupply(), s2, "the second buyback burns too");
            _solvent();
        }
    }

    function test_buyback_skimReturnSplitAtZero() public {
        _run(0);
    }

    function test_buyback_skimReturnSplitAtHalf() public {
        _run(5_000);
    }

    function test_buyback_skimReturnSplitAtAll() public {
        _run(10_000);
    }

    /// with everything routed back, the buyback pot only shrinks by what the swap really consumed net of the skim
    function test_buyback_allToTheBuybackNetCost() public {
        _stock();
        _fillEthBuyback();
        _share(10_000);
        uint256 pool = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Flow memory f;
        _readSkim(f, logs);
        (uint256 spent, uint256 tip) = _event(logs);
        uint256 income = address(core).balance - _tracked();
        (, uint256 engine) = _payeeSplit(income);
        _book();
        assertEq(core.ethPot(), pot0, "the pot did not move");
        uint256 slice = pool < 1 ether ? pool : 1 ether;
        assertEq(core.ethToBuyback(), pool - slice + engine + (slice - spent - tip));
        assertEq(spent + tip + (slice - spent - tip), slice, "the slice is spent, tipped or returned");
    }
}
