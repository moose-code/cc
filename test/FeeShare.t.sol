// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
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

/// the payee share of the fee income: `payeePpm` of the income booked by `_book`, pushed to the payee by that book
/// (decision 123). it starts with the first book that has income at or after `launchedAt + SNIPER_SECONDS`, and that
/// book shares nothing. every number comes from real swaps through the live pool and the live skim hook
contract PayeeShareTest is FeeBase {
    // promise: SPEC 1 the payee share starts after the anti sniper window (decision 109)
    /// the share starts after the window, read from the factory record of the coin
    function test_theShareStartsAfterTheWindowFromTheFactoryRecord() public {
        // payeePpm is 0 at launch (decision 120); the owner raises it to observe the share crediting
        Settings memory sp = core.settings();
        sp.payeePpm = 90_909;
        _setSettings(sp);
        (, uint256 launchedAt) = _launchRecord();
        assertEq(launchedAt, launchTime, "the launch time of the factory record");
        assertEq(core.settings().sniperSeconds, 1800);
        assertFalse(core.payeeOn());

        // a book inside the window shares nothing and does not turn the share on
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertFalse(core.payeeOn(), "inside the window");

        // one second before the end of the window
        vm.warp(launchedAt + core.settings().sniperSeconds - 1);
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertFalse(core.payeeOn(), "one second before the end");

        // at the end of the window the book with income turns the share on and shares nothing
        vm.warp(launchedAt + core.settings().sniperSeconds);
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertTrue(core.payeeOn(), "the first book at the end of the window");
        assertEq(f.toPayee, 0, "that book shares nothing");

        // the next book shares
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertGt(f.toPayee, 0);
        assertEq(f.toPayee, f.bountyRise * 90_909 / 1_000_000, "90,909 ppm of the income");
    }

    // promise: SPEC 1 the payee share starts with the first income after the window
    /// a book without income does not turn the share on: the eth that arrives first after the window is the shared-free book
    function test_aBookWithoutIncomeDoesNotTurnTheShareOn() public {
        _skipSniperWindow();
        core.book();
        assertFalse(core.payeeOn());
        autoBook = false;
        _buyCoin(trader, 20 ether);
        uint256 held = address(core).balance - _tracked();
        assertGt(held, 0);
        uint256 payeeBefore = core.payee().balance;
        core.book();
        assertTrue(core.payeeOn());
        assertEq(core.payee().balance, payeeBefore, "the window eth and the first income after it are not shared");
    }

    // promise: SPEC 1 the book pushes the payee its share (decision 123)
    function test_bookPushesThePayeeItsShare() public {
        _stock();
        assertEq(core.payee(), lc.payee);
        assertEq(core.settings().payeePpm, 0, "payeePpm 0 at launch");
        Settings memory sp = core.settings();
        sp.payeePpm = 90_909;
        _setSettings(sp);
        address a = lc.payee;
        uint256 a0 = a.balance;
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, f.bountyRise * 90_909 / 1_000_000);
        assertApproxEqRel(f.toPayee, 0.082 ether, 0.01e18);
        assertEq(a.balance - a0, f.toPayee, "the payee received the pushed share");
        _solvent();
    }

    // promise: SPEC 1 payee and payeePpm are owner settings, effective at once
    /// the owner replaces the payee with `setPayee` and the share with `setSettings`: later books push the new share to
    /// the new payee
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
        uint256 b0 = b.balance;
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, f.bountyRise * 150_000 / 1_000_000);
        assertEq(f.potRise, _toPot(f.bountyRise - f.toPayee));
        assertEq(b.balance - b0, f.toPayee, "the new payee received the push");
        assertEq(a.balance, 0, "the old payee got nothing");
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setPayee(address(0));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setPayee(b);
    }

    // promise: SPEC 1 setSettings books pending income under the old share first
    /// the ppm bound is 200,000: above it `setSettings` reverts, at it the book credits a fifth of the income
    /// income that arrived before `setSettings` is split under the settings in force when it arrived
    function test_setSettingsBooksUnbookedIncomeUnderTheOldShare() public {
        _stock();
        Settings memory s = core.settings();
        uint256 oldPpm = s.payeePpm;
        uint256 payee0 = core.payee().balance;
        vm.deal(address(core), address(core).balance + 1 ether);
        s.payeePpm = 200_000;
        _setSettings(s);
        assertEq(core.payee().balance - payee0, 1 ether * oldPpm / 1_000_000, "the unbooked income took the old share");
        _solvent();
    }

    // promise: INTEGRATION BadSetting on payeePpm
    function test_theShareBoundIsOneMillionPpm() public {
        Settings memory s = core.settings();
        s.payeePpm = 1_000_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("payeePpm")));
        core.setSettings(s);
        s.payeePpm = 1_000_000;
        _setSettings(s);
        _stock();
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, f.bountyRise);
        s.payeePpm = 0;
        _setSettings(s);
        f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(f.toPayee, 0, "a zero share credits nothing");
        assertEq(f.potRise, _toPot(f.bountyRise));
    }

    // promise: SPEC 1 a failing payee never blocks the book, the forced push still delivers (decision 123)
    /// a payee whose receive reverts, or that burns its gas, still receives its share through the forced push: the book
    /// does not revert and every door and every swap works
    function test_aFailingPayeeStillReceivesThroughTheForcedPush() public {
        _stock();
        {
            Settings memory sp = core.settings();
            sp.payeePpm = 90_909;
            _setSettings(sp);
        }
        address[2] memory bad = [address(new RevertingPayee()), address(new GasBurningPayee())];
        for (uint256 i; i < 2; ++i) {
            vm.prank(owner);
            core.setPayee(bad[i]);
            uint256 before = bad[i].balance;
            Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
            assertGt(f.toPayee, 0, "a nonzero share");
            assertEq(bad[i].balance - before, f.toPayee, "the forced push reached the failing payee");
        }
        // doors and swaps are unaffected
        _fillEthPile(5);
        _flow(Kind.SellExactIn, coin.balanceOf(trader) / 10, "");
        address good = makeAddr("goodPayee");
        vm.prank(owner);
        core.setPayee(good);
        uint256 goodBefore = good.balance;
        Flow memory g = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(good.balance - goodBefore, g.toPayee, "the new payee is pushed its share");
        _solvent();
    }

    // promise: INTEGRATION the forced payee push gives the payee no reentry (decision 123)
    /// the payee cannot reenter the Core during the forced push of its share, and the push still lands
    function test_thePushGivesThePayeeNoReentry() public {
        _stock();
        {
            Settings memory sp = core.settings();
            sp.payeePpm = 90_909;
            _setSettings(sp);
        }
        ReenteringPayee p = new ReenteringPayee(core);
        vm.prank(owner);
        core.setPayee(address(p));
        uint256 before = address(p).balance;
        Flow memory f = _flow(Kind.BuyExactIn, 10 ether, "");
        assertEq(address(p).balance - before, f.toPayee, "the push reached the reentering payee");
        assertTrue(p.triedToReenter());
        assertFalse(p.reentered(), "the stipend and the guard stopped the nested calls");
    }

    function _launchRecord() internal view returns (bool ok, uint256 launchedAt) {
        (bool o, bytes memory out) =
            address(FACTORY).staticcall(abi.encodeWithSignature("deploymentInfo(address)", address(coin)));
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
        (bool b,) = address(CORE).call(abi.encodeCall(ICore.book, ()));
        (bool c,) = address(CORE).call{value: 1}(abi.encodeCall(ICore.fund, ()));
        reentered = b || c;
    }
}

/// `feeToRedeemBurnBps`: the share of the fee income after the payee share that `_book` adds to the redeem burn reserve,
/// the rest to the pot. every number comes from real swaps through the live pool and the live skim hook, which pays its bounty leg
/// to the Core. `fund()` adds to the pot whole
contract FeeShareTest is FeeBase {
    uint256 internal constant BASIS = 10_000;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = bps;
        _setSettings(s);
    }

    struct Books {
        uint256 bounty;
        uint256 inflow;
        uint256 dPot;
        uint256 dRb;
        uint256 dBal;
    }

    /// one swap and a book, and what they did to the core's books. the bounty is what the hook itself reports it pushed
    /// to the core, the inflow is the income less the payee share
    function _swap(Kind kind, uint256 amount) internal returns (Books memory b) {
        uint256 pot = core.ethPot();
        uint256 rb = core.ethRedeemBurn();
        uint256 bal = address(core).balance;
        Flow memory f = _flow(kind, amount, "");
        b.bounty = f.skimBounty;
        b.inflow = f.bountyRise - f.toPayee;
        assertEq(f.bountyRise, f.skimBounty, "the core got the bounty leg");
        b.dPot = core.ethPot() - pot;
        b.dRb = core.ethRedeemBurn() - rb;
        b.dBal = address(core).balance - bal;
    }

    function _check(Books memory b, uint16 bps) internal pure {
        uint256 toRb = b.inflow * bps / BASIS;
        assertEq(b.dRb, toRb, "redeem burn share is floor(inflow * bps / 10000)");
        assertEq(b.dPot, b.inflow - toRb, "the rest is the pot share");
        assertEq(b.dBal, b.bounty, "the balance rose by the bounty leg");
    }

    // promise: SPEC 1 fee eth splits between ethPot and the redeem burn reserve by feeToRedeemBurnBps (inv 18)
    function test_split_atZeroHalfAndAllOnExactBuys() public {
        _stock();
        uint16[3] memory bps = [uint16(0), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _share(bps[i]);
            Books memory b = _swap(Kind.BuyExactIn, 1 ether);
            assertEq(b.bounty, 0.09 ether, "9.0 points of one eth reach the core");
            uint256 want = b.inflow * bps[i] / BASIS;
            assertEq(b.dRb, want, "exact redeem burn share");
            assertEq(b.dPot, b.inflow - want, "exact pot share");
            assertApproxEqAbs(
                b.inflow,
                0.09 ether,
                0.00001 ether,
                "9.0 points of the buy reach the engine (core 9.9 less the payee 0.9)"
            );
            _check(b, bps[i]);
            _solvent();
        }
    }

    // ------------------------------------------------------------------ book

    // promise: SPEC 4 eth above the tracked pots is booked as fee income
    /// eth forced into the core is fee income at the next book: split by the settings like the hook's push
    function test_book_countsForcedEthAsIncome() public {
        _share(10_000);
        vm.deal(address(core), address(core).balance + 1.5 ether);
        uint256 pot = core.ethPot();
        uint256 rb = core.ethRedeemBurn();
        core.book();
        assertEq(core.ethRedeemBurn() - rb, 1.5 ether, "the share is all to the reserve");
        assertEq(core.ethPot(), pot);
        assertEq(address(core).balance, _tracked());
        // a second book counts nothing
        core.book();
        assertEq(core.ethRedeemBurn() - rb, 1.5 ether);
    }

    // ------------------------------------------------------------------ a change of the setting

    // promise: SPEC 1 feeToRedeemBurnBps is an owner setting, effective on the next fee
    function test_change_takesEffectOnTheNextFeeAndNeverRewritesTheBooks() public {
        _stock();
        _share(0);
        Books memory b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dRb, 0);
        assertEq(b.dPot, b.inflow);
        uint256 pot = core.ethPot();
        uint256 rb = core.ethRedeemBurn();
        _share(10_000);
        assertEq(core.ethPot(), pot, "the change moves no books");
        assertEq(core.ethRedeemBurn(), rb);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dRb, b.inflow);
        assertEq(b.dPot, 0);
        _share(2_500);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dRb, b.inflow * 2_500 / BASIS);
        assertEq(b.dPot, b.inflow - b.inflow * 2_500 / BASIS);
        _share(0);
        b = _swap(Kind.SellExactIn, coin.balanceOf(trader) / 10);
        assertEq(b.dRb, 0);
        assertEq(b.dPot, b.inflow);
        _solvent();
    }
}

/// the fee that comes back to the core during its own `buyback()` swap is split like any other, and the buyback works
contract FeeShareBuybackTest is FeeBase {
    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = bps;
        _setSettings(s);
    }

    function _event(Vm.Log[] memory logs) internal pure returns (uint256 spent, uint256 tip) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.Buyback.selector) {
                (spent, tip) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _run(uint16 bps) internal {
        _stock();
        _fillEthBuyback();
        _share(bps);
        uint256 pool = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        uint256 rb0 = core.ethRedeemBurn();
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
        assertEq(core.ethRedeemBurn() - rb0, engine * bps / 10_000, "reserve share of the returning skim");
        assertEq(core.ethToBuyback(), pool - slice + (slice - spent - tip), "buyback pot");
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

    // promise: the payee timer is editable before activation and cannot undo the one-way latch afterwards
    function test_editableTimerAndOneWayLatch() public {
        Settings memory s = core.settings();
        s.payeePpm = 100_000;
        s.sniperSeconds = 0;
        _setSettings(s);
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertTrue(core.payeeOn());
        assertEq(f.toPayee, 0);
        s.sniperSeconds = type(uint32).max;
        _setSettings(s);
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertTrue(core.payeeOn());
        assertGt(f.toPayee, 0);
    }
}
