// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, ICreditStrategy, ICreditScore, Stack, Mainnet, Settings, BUYLISTING_GAS} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {BidModel} from "./utils/BidModel.sol";

/// shared helpers of the core unit suites. everything runs on the real stack of the Fixture: the live coin, hook,
/// pool, Credits, Statements, CreditStrategy and Seaport. a test that needs an exact pot donates
/// eth to the core and calls `skim()`, which is the real path for eth that did not come from the hook
abstract contract CoreBase is Fixture {
    using stdStorage for StdStorage;

    /// @dev the account that sells credits in these suites
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = seller;
    }

    /// @dev sends `amount` of eth to the core from a plain account and books it with `skim`. the pot is exactly
    /// `amount` higher afterwards
    function _fund(uint256 amount) internal {
        vm.deal(funder, funder.balance + amount);
        vm.prank(funder);
        (bool ok,) = address(core).call{value: amount}("");
        assertTrue(ok, "donation");
        core.skim();
    }

    /// @dev the rate after one credit bought at `r`, the first fill of its minute, at the drop of the settings now
    function _dropped(uint256 r) internal view returns (uint256) {
        return BidModel.dropOnce(core.settings(), r, r);
    }

    function _listing(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _page(uint256 first, uint256 fill) internal pure returns (uint256[80] memory ids) {
        for (uint256 i; i < 80; ++i) {
            ids[i] = fill;
        }
        ids[0] = first;
    }

    /// @dev puts `n` fresh credits of `who` in the eth pile through the sell door, with the pot topped up first
    function _sellN(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(who, n);
        _fund(20 ether);
        vm.prank(who);
        core.sellForEth(ids);
    }

    /// @dev builds a core with other constructor arguments. external, so a revert of the constructor can be expected
    function mk(address owner_, address coin_, address ctl_, Stack memory st, uint256 r, Settings memory s)
        external
        returns (ICore)
    {
        return Prod.newCore(owner_, coin_, ctl_, st, r, s);
    }
}

contract CoreUnitTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                              parameters
    //////////////////////////////////////////////////////////////*/

    /// the constants that are left. every other economic number is a setting, covered in Flow.t.sol
    function test_constructorState() public view {
        assertEq(core.owner(), owner);
        assertEq(core.pendingOwner(), address(0));
        assertEq(core.COIN(), address(coin));
        assertEq(core.HOOK(), lc.stack.hook);
        assertEq(core.controller(), address(ctl));
        assertTrue(core.allowedTarget(Mainnet.SEAPORT));
        assertTrue(core.allowedTarget(Mainnet.CREDIT_STRATEGY));
        assertTrue(CREDITS.isApprovedForAll(address(core), address(STATEMENTS)));
        assertEq(core.rateAtCheckpoint(), OPEN_RATE);
        assertEq(core.ethRate(), 0, "an empty pot reads zero");
        assertEq(core.lastFillTime(), launchTime);
        assertEq(core.ethPot(), 0);
        assertEq(core.exitModule(), address(0));
        assertEq(core.exitToken(), address(0));
        assertEq(core.unitPerPoint(), 0);
        assertFalse(core.controllerLocked());
        assertFalse(core.exitModuleLocked());
        assertFalse(core.targetsLocked());
    }

    function _stack8(Stack memory st, uint256 which, address to) internal pure returns (Stack memory bad) {
        bad = Stack(
            st.poolManager,
            st.hook,
            st.tickSpacing,
            st.poolFee,
            st.factory,
            st.locker,
            st.escrow,
            st.feeSource
        );
        if (which == 0) bad.poolManager = to;
        if (which == 1) bad.hook = to;
        if (which == 2) bad.factory = to;
        if (which == 3) bad.locker = to;
        if (which == 4) bad.escrow = to;
        if (which == 5) bad.feeSource = to;
    }

    function test_constructorRejectsZero() public {
        Stack memory st = lc.stack;
        uint256 r = lc.rateStart;
        Settings memory s = lc.settings;
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.mk(address(0), address(coin), address(ctl), st, r, s);
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.mk(owner, address(0), address(ctl), st, r, s);
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.mk(owner, address(coin), address(0), st, r, s);
        // every address of the stack is required
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(ICore.ZeroAddress.selector);
            this.mk(owner, address(coin), address(ctl), _stack8(st, i, address(0)), r, s);
        }
        Stack memory flat = _stack8(st, 99, address(0));
        flat.tickSpacing = 0;
        vm.expectRevert(ICore.BadStack.selector);
        this.mk(owner, address(coin), address(ctl), flat, r, s);
        flat.tickSpacing = 32_768;
        vm.expectRevert(ICore.BadStack.selector);
        this.mk(owner, address(coin), address(ctl), flat, r, s);
        flat.tickSpacing = 32_767;
        this.mk(owner, address(coin), address(ctl), flat, r, s);
    }

    /// every stack member must be a contract, the coin is not checked (it does not exist yet)
    function test_constructorRequiresCodeAtTheStack() public {
        Stack memory st = lc.stack;
        uint256 r = lc.rateStart;
        Settings memory s = lc.settings;
        address nobody = makeAddr("no code");
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, nobody));
            this.mk(owner, address(coin), address(ctl), _stack8(st, i, nobody), r, s);
        }
        // the coin has no code at construction time and that is fine
        this.mk(owner, nobody, address(ctl), st, r, s);
    }

    /// the opening bid is a deploy input bounded to [1e13, 1e18] wei per credit
    function test_rateStartBounds() public {
        Settings memory s = lc.settings;
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(coin), address(ctl), lc.stack, 1e13 - 1, s);
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(coin), address(ctl), lc.stack, 1e18 + 1, s);
        ICore lo = this.mk(owner, address(coin), address(ctl), lc.stack, 1e13, s);
        s.rateCap = 1e18;
        ICore hi = this.mk(owner, address(coin), address(ctl), lc.stack, 1e18, s);
        assertEq(lo.RATE_START(), 1e13);
        assertEq(lo.rateAtCheckpoint(), 1e13);
        assertEq(hi.RATE_START(), 1e18);
        assertEq(hi.rateAtCheckpoint(), 1e18);
    }

    /// the stack is stored as given, nothing of it is hardcoded in the core. the six members that are only
    /// addresses are stand in code
    function test_stackIsStored() public {
        Stack memory other = Stack(
            address(0x1111),
            address(0x2222),
            60,
            3000,
            address(0x3333),
            address(0x4444),
            address(0x5555),
            address(0x6666)
        );
        for (uint160 a = 0x1111; a <= 0x6666; a += 0x1111) {
            vm.etch(address(a), hex"00");
        }
        // the whole fee receipt goes to the pot here, so the booking is the full amount
        Settings memory st = lc.settings;
        st.feeToRedeemBurnBps = 0;
        ICore c2 = this.mk(owner, address(coin), address(ctl), other, lc.rateStart, st);
        assertEq(address(c2.MANAGER()), address(0x1111));
        assertEq(c2.HOOK(), address(0x2222));
        assertEq(c2.TICK_SPACING(), 60);
        assertEq(c2.POOL_FEE(), 3000);
        assertEq(c2.FACTORY(), address(0x3333));
        assertEq(c2.LOCKER(), address(0x4444));
        assertEq(c2.ESCROW(), address(0x5555));
        assertEq(c2.FEE_SOURCE(), address(0x6666));
        // only the configured fee source is booked as fee income, the hook included is not
        vm.deal(address(0x6666), 1 ether);
        vm.prank(address(0x6666));
        (bool ok,) = address(c2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(c2.ethPot(), 1 ether);
        vm.deal(address(0x2222), 1 ether);
        vm.prank(address(0x2222));
        (ok,) = address(c2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(c2.ethPot(), 1 ether, "the hook is not the fee source");
        vm.deal(address(feeRouter), 1 ether);
        vm.prank(address(feeRouter));
        (ok,) = address(c2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(c2.ethPot(), 1 ether, "the default fee router is not special to this core");
    }

    /*//////////////////////////////////////////////////////////////
                           fee intake and skim
    //////////////////////////////////////////////////////////////*/

    /// eth the router flushes after a real swap is booked at once. eth from anyone else waits for `skim`
    function test_receiveBooksHookEth_skimBooksTheRest() public {
        _skipSniperWindow();
        // the whole fee receipt goes to the pot here, so the pot equals the full router inflow
        Settings memory s0 = core.settings();
        s0.feeToRedeemBurnBps = 0;
        _setSettings(s0);
        _buyCoin(funder, 1 ether);
        uint256 pot = core.ethPot();
        assertEq(pot, 0.0665022 ether, "6.65022 points of a 1 eth buy");
        assertEq(address(core).balance, pot);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(core).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), pot, "a plain send books nothing");
        assertEq(address(core).balance, pot + 2 ether);

        core.skim();
        assertEq(core.ethPot(), pot + 2 ether);
        core.skim();
        assertEq(core.ethPot(), pot + 2 ether, "nothing left to book");
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                               rate climb
    //////////////////////////////////////////////////////////////*/

    function test_rate_unfundedNeverClimbs() public {
        assertEq(core.rateAtCheckpoint(), OPEN_RATE);
        assertEq(core.ethRate(), 0, "an empty pot reads zero");
        _warp(1000 hours);
        assertEq(core.ethRate(), 0);

        // one credit costs 1.732e15 at the start rate. below a pot of that size the read is the clamp, which is the
        // pot, and the price state holds
        uint256 last;
        uint256[4] memory steps = [uint256(1e14), 2e14, 4e14, 8e14];
        for (uint256 i; i < steps.length; ++i) {
            _fund(steps[i]);
            _warp(1000 hours);
            assertEq(core.ethRate(), core.ethPot(), "the read is the clamp of the pot");
            assertGe(core.ethRate(), last, "the read does not fall as the pot grows");
            last = core.ethRate();
            assertEq(core.rateAtCheckpoint(), OPEN_RATE, "the price state holds at the opening rate");
        }
        uint256 clamp = last;
        _warp(10 minutes);
        assertEq(core.ethRate(), clamp, "held there");
        // the price state does not climb above the clamp: it waited at the opening rate
        _fund(10 ether);
        assertEq(core.rateAtCheckpoint(), OPEN_RATE, "the price state waited at the opening rate");
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_051_140_132_040_790_642 / 1e18, 1e9, "then 10 minutes at 0.5 percent");
    }

    /// at exactly the pot where the clamp equals the rate there is no room to climb, one wei less is a clamp one wei
    /// under the rate
    function test_rate_clampIsThePotToTheWei() public {
        _fund(OPEN_RATE - 1);
        _warp(1000 hours);
        assertEq(core.ethRate(), OPEN_RATE - 1, "one wei short: the clamp is one wei under the rate");
        _fund(1);
        _warp(1000 hours);
        assertEq(core.ethRate(), OPEN_RATE, "funded to the wei: the clamp equals the rate");
        _fund(1e16);
        assertEq(core.ethRate(), OPEN_RATE);
        _warp(1 hours);
        assertApproxEqRel(
            core.ethRate(), OPEN_RATE * 1_348_850_152_549_316_069 / 1e18, 1e9, "room above the clamp, 60 minutes"
        );
    }

    /// @dev lifts the ceiling to its bound so a climb curve of an hour is not cut by the launch ceiling of 110 percent
    function _wideCeiling() internal {
        Settings memory s = core.settings();
        s.ceilBps = 30_000;
        _setSettings(s);
    }

    /// the climb is 0.5 percent a minute compounded from the checkpoint, and 1.005^n of the stored rate is exact
    /// for whole minutes
    function test_rate_climbsPerMinuteCompounded() public {
        _wideCeiling();
        _fund(10 ether);
        _warp(1 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1.005e18 / 1e18, 1e9, "1 minute");
        _warp(9 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_051_140_132_040_790_642 / 1e18, 1e9, "10 minutes");
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_104_895_577_186_730_786 / 1e18, 1e9, "20 minutes");
        _warp(40 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_348_850_152_549_316_069 / 1e18, 1e9, "60 minutes");
    }

    /// a fraction of a minute climbs as a fractional exponent
    function test_rate_climbsInsideAMinute() public {
        _fund(10 ether);
        _warp(30);
        assertApproxEqRel(
            core.ethRate(), OPEN_RATE * 1_002_496_882_788_171_067 / 1e18, 1e9, "half a minute is 1.005^0.5"
        );
    }

    /// the climb at other settings: 2 percent a minute
    function test_rate_climbAtChangedSettings() public {
        Settings memory s = core.settings();
        s.climbPerMinBps = 200;
        s.ceilBps = 30_000;
        _setSettings(s);
        _fund(10 ether);
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_218_994_419_994_757_130 / 1e18, 1e9, "10 minutes at 2 percent");
    }

    function test_rate_checkpointKeepsTheCurve() public {
        _wideCeiling();
        _fund(10 ether);
        _warp(30 minutes);
        uint256 r30 = core.ethRate();
        _fund(1);
        assertEq(core.rateAtCheckpoint(), r30);
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(core.lastFillTime(), launchTime);
        _warp(30 minutes);
        assertApproxEqRel(
            core.ethRate(), OPEN_RATE * 1_348_850_152_549_316_069 / 1e18, 1e9, "same curve as without the checkpoint"
        );
    }

    function test_rate_climbStopsAtTheClamp() public {
        // a pot of 2.4 credits at the opening rate: the climb stops at the pot
        uint256 pot = OPEN_RATE * 12 / 5;
        _fund(pot);
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), OPEN_RATE * 1_051_140_132_040_790_642 / 1e18, 1e9);
        _warp(100 hours);
        assertEq(core.ethRate(), pot, "stops where the pot affords one credit");
        _warp(10_000 hours);
        assertEq(core.ethRate(), pot);

        // more fees lift the clamp and the climb resumes from the checkpoint.
        _fund(pot);
        assertEq(core.rateAtCheckpoint(), pot);
        _warp(1 hours);
        assertApproxEqRel(
            core.ethRate(), pot * 1_348_850_152_549_316_069 / 1e18, 1e9, "60 minutes at 0.5 percent from the clamp"
        );
    }

    /// the same clamp when the pot is filled by real swaps: it is measured, not assumed
    function test_rate_climbStopsAtTheClampWithRealFees() public {
        _skipSniperWindow();
        _fundPot(0.001 ether);
        uint256 pot = core.ethPot();
        assertLt(pot, OPEN_RATE, "the pot is under one credit");
        _warp(2000 hours);
        assertEq(core.ethRate(), pot, "clamp at what the pot affords");
    }

    /// at the clamp a credit can be sold in the same block: the sale pays the read, which is the pot, and empties it
    function test_rate_atTheClampACreditSells() public {
        _fund(0.001 ether);
        _warp(3000 hours);
        uint256 rate = core.ethRate();
        assertEq(rate, 0.001 ether, "at the clamp");
        uint256[] memory ids = _credits(alice, 2);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        assertEq(alice.balance - before, rate, "paid the pot");
        assertEq(core.ethPot(), 0);
        assertLt(core.rateAtCheckpoint(), OPEN_RATE, "the fill dropped the rate");
        assertEq(core.ethRate(), 0, "an empty pot reads zero");
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(_one(ids[1]));
    }

    /// the pot shrinks below one credit while the rate sits at the clamp. the next checkpoint applies
    /// no climb under the smaller pot and the rate never rises again. no real path shrinks the pot without also
    /// dropping the rate, so the pot slot is written directly and the balance is set to match
    function test_rate_potDropHoldsThePriceState() public {
        _fund(OPEN_RATE * 2);
        _warp(100 hours);
        uint256 cap = core.ethRate();
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap);
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(1e15));
        vm.deal(address(core), 1e15);
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap, "no climb applied under the smaller pot");
        _warp(500 hours);
        assertEq(core.ethRate(), core.ethPot(), "the read is the clamp of the smaller pot");
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap, "the price state never rose");
        _solvent();
    }

    /// a fill drops the rate by `dropPerCreditBps`, makes the rate paid the ceiling anchor and restarts the climb clock
    function test_rate_dropAndClockResetOnFill() public {
        // the post fill climb is checked against the single rate formula; match the recovery rate to the climb rate so a
        // fill does not switch to the faster recovery climb (that is covered in test/Recovery.t.sol)
        Settings memory cs = core.settings();
        cs.recoveryClimbPerMinBps = cs.climbPerMinBps;
        _setSettings(cs);
        _fund(10 ether);
        _warp(30 hours);
        uint256 id = _credits(alice, 1)[0];
        uint256 rate = core.ethRate();
        uint256 price = rate;

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id));

        assertEq(alice.balance - before, price);
        assertEq(core.ethPot(), 10 ether - price);
        assertEq(core.rateAtCheckpoint(), rate * 9_950 / 10_000, "0.5 percent below the rate paid");
        (uint256 anchor, uint256 minuteStart,) = _anchor();
        assertEq(anchor, rate, "the rate paid is the ceiling anchor");
        assertEq(minuteStart, rate, "and the start of the minute");
        assertEq(core.lastFillTime(), block.timestamp);
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(CREDITS.ownerOf(id), address(core));
        (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, price);
        assertEq(core.pileSize(Lane.Eth), 1);
        _solvent();

        // the climb restarts from the dropped rate, and the ceiling is 110 percent of the rate paid
        uint256 after_ = core.rateAtCheckpoint();
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), after_ * 1_051_140_132_040_790_642 / 1e18, 1e9);
        _warp(10 hours);
        assertEq(
            core.ethRate(),
            rate * 11_000 * (10_000 + 200 * 61) / 1e8,
            "ceiling 110 percent of the rate paid, loosened 2 percent per 10 idle minutes"
        );
    }

    function test_sellForEth_multiDropsPerCredit() public {
        _fund(10 ether);
        uint256[] memory ids = _credits(alice, 3);
        uint256 r = OPEN_RATE;
        uint256 p = 10 ether;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 price = r;
            r = BidModel.dropOnce(core.settings(), r, OPEN_RATE);
            p -= price;
            total += price;
        }
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(alice.balance - before, total);
        assertEq(core.rateAtCheckpoint(), r);
        assertEq(core.ethPot(), p);
        assertEq(core.pileSize(Lane.Eth), 3);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                              sell door
    //////////////////////////////////////////////////////////////*/

    function test_sellForEth_minOut() public {
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        uint256 price = core.ethRate();

        vm.prank(alice);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForEth(_one(id), price + 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id), price);
        assertEq(alice.balance - before, price);
    }

    /// minOut guards the sum over many ids, and a rate drop inside the call lowers it
    function test_sellForEth_minOutIsTheTotalAfterTheDrops() public {
        _fund(10 ether);
        uint256[] memory ids = _credits(alice, 3);
        uint256 first = core.ethRate();
        vm.prank(alice);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForEth(ids, first * 3);
        uint256 before = alice.balance;
        vm.prank(alice);
        // the second credit is paid 0.5 percent below the first, the third 0.5 percent below the second
        core.sellForEth(ids, first * 2_985 / 1_000);
        assertLt(alice.balance - before, first * 3, "later credits were paid at the dropped rate");
    }

    /// an empty pot reads a rate of 0: a sale reverts `ZeroAmount` and a purchase reverts `PotTooSmall`. a pot of 1 wei
    /// reads 1 wei: a sale pays it and a purchase of 2 wei reverts `PotTooSmall`
    function test_tinyPotSellsItsWeiAndBuysNothing() public {
        uint256[] memory ids = _credits(alice, 2);
        bytes memory data = abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A));
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.buyListing(1, data, LISTED_A, Mainnet.CREDIT_STRATEGY);
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(_one(ids[0]));

        vm.deal(address(core), 1);
        core.skim();
        assertEq(core.ethPot(), 1);
        assertEq(core.ethRate(), 1);
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.buyListing(2, data, LISTED_A, Mainnet.CREDIT_STRATEGY);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        assertEq(alice.balance - before, 1, "paid the wei");
        assertEq(core.ethPot(), 0);
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(_one(ids[1]));
    }

    function test_sellForEth_guards() public {
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);

        vm.prank(alice);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForEth(none);

        vm.prank(alice);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForEth(_one(0));

        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(ids);

        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForEth(ids);

        // not approved
        address bob = _user("bob");
        uint256 id = CreditIds.at(500);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, bob, id);
        vm.prank(bob);
        vm.expectRevert();
        core.sellForEth(_one(id));
    }

    function test_sellForEth_cannotSellACreditTheCoreOwns() public {
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        vm.prank(alice);
        core.sellForEth(_one(id));
        vm.prank(alice);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForEth(_one(id));
    }

    /*//////////////////////////////////////////////////////////////
                         controller is only read
    //////////////////////////////////////////////////////////////*/

    /// the sell door does not read the controller: a controller with no code changes nothing, and compose is not ready
    function test_controller_isNotReadBySellForEth() public {
        _fund(10 ether);
        uint256[] memory ids = _credits(alice, 2);
        uint256 rate = core.ethRate();
        assertEq(rate, OPEN_RATE);
        _setController(address(0xBEEF));
        assertEq(core.ethRate(), rate);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        assertEq(alice.balance - before, rate);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    /*//////////////////////////////////////////////////////////////
                           buyListing: real strategy
    //////////////////////////////////////////////////////////////*/

    /// funds the pot and warps hour by hour until the ceiling clears the listing price of id.
    function _fundAndClimb(uint256 id, uint256 price) internal {
        _fund(10 ether);
        _warpUntilCeiling(id, price);
    }

    function test_buyListing_aboveCeilingReverts() public {
        _fund(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertGt(price, core.ethRate(), "start rate is far below the listing");
        vm.prank(keeper);
        vm.expectRevert(ICore.AboveCeiling.selector);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
    }

    struct PayRun {
        uint256 paid;
        uint256 gap;
        uint256 used;
    }

    /// moves credit `id` from the strategy to a fresh `ListingTarget` and allows it
    function _listingTarget(uint256 id) internal returns (ListingTarget t) {
        t = new ListingTarget();
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
        _allow(address(t));
    }

    /// one `buyListing` of credit `id` through `target` with `data`, at base fee `bf` and gas price `gp`, for `value`
    /// less `gapWanted` under the bid when `gapWanted` is nonzero. checks the books: the keeper gets the payment, the
    /// pot pays the cost and the payment, the cost basis is both
    function _payRun(address target, bytes memory data, uint256 id, uint256 cost, uint256 bf, uint256 gp)
        internal
        returns (PayRun memory r)
    {
        vm.fee(bf);
        vm.txGasPrice(gp);
        uint256 ceiling = core.ethRate();
        r.gap = ceiling - cost;
        uint256 pot = core.ethPot();
        uint256 before = keeper.balance;
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(cost, data, id, target);
        r.used = g - gasleft();
        r.paid = keeper.balance - before;
        _assertListingPay(r.paid, r.gap);
        assertEq(core.ethPot(), pot - cost - r.paid, "the pot pays the cost and the payment");
        (,, uint256 basis,) = core.creditInfo(id);
        assertEq(basis, cost + r.paid, "the cost basis is the cost plus the payment");
        assertLe(basis, ceiling, "the engine pays at most its bid");
        _solvent();
    }

    /// the payment is the gas counted at the base fee plus the whole keeper fee, on the real strategy path. the counted
    /// gas covers the gas used and the transaction base cost, and scales with the base fee
    function test_buyListing_paysCountedGasAtTheBaseFeePlusTheFee() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        uint256 snap = vm.snapshotState();
        PayRun memory a = _payRun(STRATEGY, _listing(LISTED_A), LISTED_A, price, 1 gwei, 1 gwei);
        uint256 fee = core.settings().keeperFee;
        assertEq(fee, 0.0005 ether);
        assertGt(a.gap, a.paid, "the gap does not bind");
        assertEq((a.paid - fee) % 1 gwei, 0, "whole gas units");
        uint256 counted = (a.paid - fee) / 1 gwei;
        assertGe(counted, a.used + 21_000, "the counted gas covers the gas used and the transaction base cost");
        assertLe(counted, a.used + 120_000, "and carries no more than the work after the count");
        emit log_named_uint("buyListing strategy path: gas used", a.used);
        emit log_named_uint("buyListing strategy path: gas counted", counted);
        vm.revertToState(snap);
        PayRun memory b = _payRun(STRATEGY, _listing(LISTED_A), LISTED_A, price, 2 gwei, 2 gwei);
        assertEq(b.paid - fee, 2 * (a.paid - fee), "the gas part scales with the base fee");
    }

    /// a base fee above `keeperMaxBaseFee` pays at the ceiling, and the gas price above the base fee is not refunded
    function test_buyListing_baseFeeCeilingAndPriorityFee() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        assertEq(core.settings().keeperMaxBaseFee, 10 gwei);
        uint256 snap = vm.snapshotState();
        PayRun memory atCeiling = _payRun(STRATEGY, _listing(LISTED_A), LISTED_A, price, 10 gwei, 10 gwei);
        vm.revertToState(snap);
        PayRun memory above = _payRun(STRATEGY, _listing(LISTED_A), LISTED_A, price, 300 gwei, 300 gwei);
        assertEq(above.paid, atCeiling.paid, "a base fee above the ceiling pays at the ceiling");
        vm.revertToState(snap);
        PayRun memory tipped = _payRun(STRATEGY, _listing(LISTED_A), LISTED_A, price, 10 gwei, 500 gwei);
        assertEq(tipped.paid, atCeiling.paid, "the gas price above the base fee changes nothing");
    }

    /// the keeper fee is paid whole at a zero base fee, whatever the cost
    function test_buyListing_keeperFeeIsPaidWhole() public {
        _fundAndClimb(LISTED_A, 0.036 ether);
        uint256 id = CreditIds.at(540);
        ListingTarget t = _listingTarget(id);
        Settings memory s = core.settings();
        s.keeperFee = 0.005 ether;
        _setSettings(s);
        uint256 cost = 0.01 ether;
        PayRun memory r = _payRun(address(t), abi.encodeCall(ListingTarget.fill, (id, 0)), id, cost, 0, 0);
        assertEq(r.paid, 0.005 ether, "the whole fee, no gas part");
    }

    /// a gap smaller than the payment is the payment, so cost plus payment equals the bid. a zero gap pays nothing
    function test_buyListing_paymentIsCappedAtTheGap() public {
        _fund(10 ether);
        uint256 ceiling = core.ethRate();
        uint256[4] memory gaps = [uint256(0), 1, 1000, 0.0004 ether];
        for (uint256 i; i < gaps.length; ++i) {
            uint256 id = CreditIds.at(545 + i);
            ListingTarget t = _listingTarget(id);
            uint256 snap = vm.snapshotState();
            PayRun memory r =
                _payRun(address(t), abi.encodeCall(ListingTarget.fill, (id, 0)), id, ceiling - gaps[i], 1 gwei, 1 gwei);
            assertEq(r.paid, gaps[i], "the payment is the gap");
            (,, uint256 basis,) = core.creditInfo(id);
            assertEq(basis, ceiling, "cost plus payment is the bid");
            vm.revertToState(snap);
        }
    }

    /// the bid is lowered to the pot, so the payment cannot take the pot below zero: with a pot under the price state
    /// the bid is the pot, a listing 100 wei under that leaves a 100 wei payment and an empty pot
    function test_buyListing_paymentIsCappedAtThePot() public {
        _fund(0.001 ether);
        uint256 bid = core.ethRate();
        assertEq(bid, core.ethPot(), "the pot clamps the bid");
        uint256 id = CreditIds.at(552);
        ListingTarget t = _listingTarget(id);
        PayRun memory r = _payRun(address(t), abi.encodeCall(ListingTarget.fill, (id, 0)), id, bid - 100, 5 gwei, 5 gwei);
        assertEq(r.paid, 100);
        assertEq(core.ethPot(), 0, "the pot is empty, not below it");
    }

    /// the counted gas stops at `BUYLISTING_GAS`: a target that burns 3 million gas is paid for 1.5 million
    function test_buyListing_countedGasIsCappedAtTheConstant() public {
        _fundAndClimb(LISTED_A, 0.036 ether);
        uint256 id = CreditIds.at(553);
        ListingTarget t = _listingTarget(id);
        Settings memory s = core.settings();
        s.keeperFee = 0;
        _setSettings(s);
        uint256 cost = 0.01 ether;
        PayRun memory r = _payRun(address(t), abi.encodeCall(ListingTarget.fill, (id, 3_000_000)), id, cost, 1 gwei, 1 gwei);
        assertGt(r.used, 3_000_000, "the call burned the gas");
        assertEq(r.paid, BUYLISTING_GAS * 1 gwei, "the gas counted stops at the constant");
    }

    function test_buyListing_failedCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _fundAndClimb(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();

        // wrong value, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA - 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        // wrong calldata, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA, _listing(LISTED_B), LISTED_A, STRATEGY);

        // asked for one id but the call delivers another.
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_A, STRATEGY);

        assertEq(core.ethPot(), pot);
        assertEq(core.ethRate(), rate);
        assertEq(core.pileSize(Lane.Eth), 0);

        // an unrelated buy still goes through.
        vm.prank(keeper);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(core.pileSize(Lane.Eth), 1);

        // the core never buys a credit it already owns.
        vm.prank(keeper);
        vm.expectRevert(ICore.AlreadyOwned.selector);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    /// targets that were never allowed, and every address the core itself refuses, are not callable
    function test_buyListing_targetGuards() public {
        _fund(10 ether);
        address[12] memory refused = [
            address(0xABCD),
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            lc.stack.hook,
            Mainnet.POOL_MANAGER,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            Mainnet.PERMIT2,
            Mainnet.UNIVERSAL_ROUTER
        ];
        vm.startPrank(keeper);
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(ICore.TargetNotAllowed.selector);
            core.buyListing(1, "", LISTED_A, refused[i]);
        }
        vm.expectRevert(ICore.ZeroId.selector);
        core.buyListing(1, "", 0, STRATEGY);
        vm.stopPrank();
    }

    /// the listing is real and the pot affords it: a value above the pot fails first with `PotTooSmall`, a value the
    /// pot holds buys
    function test_buyListing_potCheck() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fund(price * 4);
        _warpUntilCeiling(LISTED_A, price);
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.buyListing(price * 4 + 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        vm.prank(keeper);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                       buyListing: hostile targets
    //////////////////////////////////////////////////////////////*/

    function test_buyListing_hostileTargetThatKeepsEthReverts() public {
        HostileTarget hostile = new HostileTarget();
        _allow(address(hostile));
        _fund(10 ether);
        uint256 before = address(core).balance;
        uint256 hostileBefore = address(hostile).balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        assertEq(address(core).balance, before, "core balance");
        assertEq(address(hostile).balance, hostileBefore, "the eth went nowhere");
        assertEq(core.ethPot(), 10 ether, "pot");
    }

    function _probe(uint256 id, uint256 mode) internal returns (ProbeTarget p) {
        p = new ProbeTarget(address(core));
        p.setMode(mode);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(p), id);
        _allow(address(p));
    }

    /// a target that refunds part of what it was paid: the cost is net of the refund, the refund is booked nowhere
    function test_buyListing_refundIsNotBooked() public {
        uint256 id = CreditIds.at(630);
        ProbeTarget p = _probe(id, 5);
        _fund(10 ether);
        uint256 ceiling = core.ethRate();
        uint256 value = ceiling * 3 / 4;
        uint256 cost = value - value / 2;
        uint256 excessBefore = address(core).balance - core.ethPot() - core.ethToBuyback();
        uint256 listingBefore = address(p).balance;

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, 0)), id, address(p));
        uint256 paid = keeper.balance - keeperBefore;
        _assertListingPay(paid, ceiling - cost);

        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, cost + paid, "cost is net of the refund");
        assertEq(core.ethPot(), 10 ether - cost - paid);
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), excessBefore, "refund booked nowhere");
        assertEq(address(p).balance - listingBefore, cost, "the listing kept the net price");
        _solvent();

        // skim sees nothing extra.
        uint256 pot = core.ethPot();
        core.skim();
        assertEq(core.ethPot(), pot);
    }

    /// a target that sends back more than it was paid leaves the core richer: a negative cost is refused
    function test_buyListing_refundAboveValueReverts() public {
        uint256 id = CreditIds.at(631);
        ProbeTarget p = _probe(id, 4);
        vm.deal(address(p), 1);
        _fund(10 ether);
        uint256 value = core.ethRate() / 2;
        vm.prank(keeper);
        vm.expectRevert(ICore.BadCost.selector);
        core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, 0)), id, address(p));
    }

    /// reentry from the target into every guarded door fails, and a wrong or doubled delivery reverts the buy
    function test_buyListing_probeModes() public {
        _fund(10 ether);
        for (uint256 m; m <= 8; ++m) {
            uint256 id = CreditIds.at(600 + m);
            ProbeTarget p = _probe(id, m);
            vm.deal(address(p), 1 ether);
            uint256 value = (core.ethRate() / 2).min(core.ethPot() / 20);
            vm.prank(keeper);
            try core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, CreditIds.at(620 + m))), id, address(p)) {
                assertTrue(p.honest(m), "a hostile mode succeeded");
            } catch {
                assertFalse(p.honest(m), "an honest mode failed");
            }
            assertEq(p.reentered(), 0, "a reentry got through");
            if (m == 7 || m == 8) assertGt(p.attempts(), 0, "the target did try");
            _solvent();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                owner
    //////////////////////////////////////////////////////////////*/

    function test_owner_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(ctl));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setExitModule(address(mod));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.addTarget(address(0x1234));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.removeTarget(STRATEGY);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockController();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockExitModule();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockTargets();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(alice);
        vm.stopPrank();
    }

    /// the controller changes at once, with an event, and never to zero
    function test_owner_setControllerAtOnce() public {
        address newCtl = address(new ScriptedController());
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true);
        emit ICore.ControllerSet(newCtl);
        core.setController(newCtl);
        assertEq(core.controller(), newCtl);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.stopPrank();
    }

    function test_owner_lockControllerIsForever() public {
        _setController(address(new ScriptedController()));
        vm.expectEmit(false, false, false, false);
        emit ICore.ControllerLocked();
        vm.prank(owner);
        core.lockController();
        assertTrue(core.controllerLocked());

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("controller")));
        core.setController(address(ctl));

        // the other powers survive the lock
        HostileTarget t = new HostileTarget();
        _allow(address(t));
        assertTrue(core.allowedTarget(address(t)));
        vm.prank(owner);
        core.removeTarget(address(t));
        assertFalse(core.allowedTarget(address(t)));
        assertFalse(core.exitModuleLocked());
        assertFalse(core.targetsLocked());
    }

    function test_owner_lockExitModule() public {
        // no module yet: phase 2 cannot be locked out by accident
        vm.prank(owner);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.lockExitModule();
        assertFalse(core.exitModuleLocked());

        _enterPhase2();
        vm.expectEmit(false, false, false, false);
        emit ICore.ExitModuleLocked();
        vm.prank(owner);
        core.lockExitModule();
        assertTrue(core.exitModuleLocked());

        MockExitModule other = new MockExitModule(address(xt), 1 * UNIT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("exitModule")));
        core.setExitModule(address(other));
        // naming the same module again to refresh the unit is blocked too
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("exitModule")));
        core.setExitModule(address(mod));
        assertEq(core.exitModule(), address(mod));
    }

    function test_owner_lockTargets() public {
        address t = address(new HostileTarget());
        _allow(t);
        vm.expectEmit(false, false, false, false);
        emit ICore.TargetsLocked();
        vm.prank(owner);
        core.lockTargets();
        assertTrue(core.targetsLocked());

        address t2 = address(new HostileTarget());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("targets")));
        core.addTarget(t2);
        // removing still works
        vm.prank(owner);
        core.removeTarget(t);
        assertFalse(core.allowedTarget(t));
    }

    function test_owner_twoStepHandover() public {
        address bob = _user("bob");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ICore.OwnershipTransferStarted(owner, alice);
        core.transferOwnership(alice);
        assertEq(core.pendingOwner(), alice);
        assertEq(core.owner(), owner, "nothing changes until the accept");

        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit ICore.OwnershipTransferred(owner, alice);
        core.acceptOwnership();
        assertEq(core.owner(), alice);
        assertEq(core.pendingOwner(), address(0));

        // the old owner lost every power, the new one has them
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.removeTarget(STRATEGY);
        vm.prank(alice);
        core.removeTarget(STRATEGY);
        assertFalse(core.allowedTarget(STRATEGY));
        // the accept cannot be replayed
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    function test_owner_handoverCanBeClearedOrReplaced() public {
        address bob = _user("bob");
        vm.startPrank(owner);
        core.transferOwnership(alice);
        core.transferOwnership(bob);
        assertEq(core.pendingOwner(), bob);
        core.transferOwnership(address(0));
        assertEq(core.pendingOwner(), address(0));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        // with nothing pending nobody can accept (the zero address cannot send a transaction)
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    function test_owner_exitModuleReplaceable() public {
        _enterPhase2();
        assertEq(core.exitModule(), address(mod));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), UNIT);

        // a second set with the same exit token goes through and reads the unit again
        MockExitModule other = new MockExitModule(address(xt), 1 * UNIT);
        _setExitModule(address(other));
        assertEq(core.exitModule(), address(other));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), 1 * UNIT);

        // a module with another exit token reverts, and the state stays
        MockExitModule alien = new MockExitModule(address(new MockExitToken("x", "x")), 1 * UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.setExitModule(address(alien));
        assertEq(core.exitModule(), address(other));
    }

    function test_owner_exitModuleValidation() public {
        MockExitModule coinModule = new MockExitModule(address(coin), 1 * UNIT);
        MockExitModule ghost = new MockExitModule(address(0x5678), 1 * UNIT);
        address[7] memory badTokens = [
            lc.stack.hook,
            Mainnet.POOL_MANAGER,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            address(CREDITS),
            address(STATEMENTS)
        ];
        address[] memory bad = new address[](3 + badTokens.length);
        bad[0] = address(0x1234); // no code
        bad[1] = address(coinModule); // the exit token is the coin
        bad[2] = address(ghost); // the exit token has no code
        for (uint256 i; i < badTokens.length; ++i) {
            bad[3 + i] = address(new MockExitModule(badTokens[i], 1 * UNIT));
        }
        vm.startPrank(owner);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ICore.BadModule.selector);
            core.setExitModule(bad[i]);
        }
        vm.stopPrank();
        assertEq(core.exitModule(), address(0));
    }

    /// a module whose unit is zero, above uint128, or unreadable is refused when it is set
    function test_owner_exitModuleRefusesBadUnits() public {
        uint256[4] memory units = [uint256(0), uint256(type(uint128).max) + 1, type(uint256).max, 1 * UNIT];
        for (uint256 i; i < units.length; ++i) {
            MockExitModule m = new MockExitModule(address(new MockExitToken("X", "X")), units[i]);
            if (i == 3) m.setRevertUnit(true);
            vm.prank(owner);
            vm.expectRevert(ICore.BadModule.selector);
            core.setExitModule(address(m));
            assertEq(core.exitModule(), address(0));
        }
    }

    function test_owner_targets() public {
        address[12] memory forbidden = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            lc.stack.hook,
            Mainnet.POOL_MANAGER,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            address(0),
            Mainnet.POSITION_MANAGER,
            Mainnet.UNIVERSAL_ROUTER
        ];
        vm.startPrank(owner);
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(forbidden[i]);
        }
        vm.stopPrank();

        // the exit module and the exit token are forbidden once they exist.
        _enterPhase2();
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(mod));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(xt));
        vm.stopPrank();
    }

    function test_owner_removeTargetIsImmediate() public {
        assertTrue(core.allowedTarget(STRATEGY));
        vm.prank(owner);
        core.removeTarget(STRATEGY);
        assertFalse(core.allowedTarget(STRATEGY));
        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, STRATEGY);

        // a target that later becomes the exit module can no longer be called.
        xt = new MockExitToken("X", "X");
        mod = new MockExitModule(address(xt), UNIT);
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        _setExitModule(address(mod));
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(mod));
    }

    /*//////////////////////////////////////////////////////////////
                                  views
    //////////////////////////////////////////////////////////////*/

    function test_views_piles() public {
        _fund(10 ether);
        uint256[] memory a = _credits(alice, 3);
        uint256[] memory b = _credits(alice, 2);
        vm.startPrank(alice);
        core.sellForEth(a);
        _warp(10);
        core.sellForEth(b);
        vm.stopPrank();

        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pileSize(Lane.Exit), 0);
        assertEq(core.pilePage(Lane.Eth, 0, 1)[0], a[0]);
        assertEq(core.pilePage(Lane.Exit, 0, 1).length, 0);
        assertEq(core.pilePage(Lane.Eth, a[0], 1)[0], a[1]);
        assertEq(core.pilePage(Lane.Eth, a[2], 1)[0], b[0]);
        assertEq(core.pilePage(Lane.Eth, b[1], 1).length, 0);

        uint256[] memory all = core.pilePage(Lane.Eth, 0, 10);
        assertEq(all.length, 5);
        assertEq(all[0], a[0]);
        assertEq(all[4], b[1]);
        uint256[] memory page = core.pilePage(Lane.Eth, a[1], 2);
        assertEq(page.length, 2);
        assertEq(page[0], a[2]);
        assertEq(page[1], b[0]);
        assertEq(core.pilePage(Lane.Eth, b[1], 2).length, 0);
        assertEq(core.pilePage(Lane.Eth, 0, 0).length, 0);

        (bool inPile, Lane lane, uint256 cost, uint64 at) = core.creditInfo(b[0]);
        assertTrue(inPile);
        assertEq(uint8(lane), 0);
        assertGt(cost, 0);
        assertEq(at, block.timestamp);
        (inPile,,, at) = core.creditInfo(12345678);
        assertFalse(inPile);
        assertEq(at, 0);

        assertEq(core.heldStatements().length, 0);
        assertEq(core.heldStatements().length, 0);
        (bool held,,,) = core.statementInfo(1);
        assertFalse(held);
    }

    /*//////////////////////////////////////////////////////////////
                               compose guards
    //////////////////////////////////////////////////////////////*/

    function test_compose_notReady() public {
        _setExitMode(2); // so composeExit reaches the page check instead of the mode gate
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
        vm.expectRevert(ICore.NotReady.selector);
        core.composeExit();

        uint256[] memory ids = _sellN(alice, 79);
        assertEq(ids.length, 79);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    function test_compose_controllerCannotNameBadPages() public {
        _setExitMode(2); // so composeExit reaches the page check instead of the mode gate
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256[] memory ids = _sellN(alice, 2);

        // an id that is in no pile
        scripted.setPage(Lane.Eth, true, _page(ids[0], 777_777), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, 777_777));
        core.compose();

        // a duplicate: the second occurrence is no longer in the pile
        scripted.setPage(Lane.Eth, true, _page(ids[0], ids[0]), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, ids[0]));
        core.compose();

        // a credit of the other lane
        scripted.setPage(Lane.Exit, true, _page(ids[0], ids[1]), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, ids[0]));
        core.composeExit();

        // id zero is the null sentinel and is never in a pile
        scripted.setPage(Lane.Eth, true, _page(0, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, 0));
        core.compose();

        // bad format
        scripted.setPage(Lane.Eth, true, _page(ids[0], ids[1]), 8);
        vm.expectRevert(ICore.BadFormat.selector);
        core.compose();

        // not ready and a reverting controller
        scripted.setPage(Lane.Eth, false, _page(ids[0], ids[1]), 0);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
        scripted.setRevertPage(true);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();

        // a reverting controller blocks nothing else
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileSize(Lane.Eth), 3);
    }

    /// the one compose of this suite with a scripted page: credits from the middle of the pile, in a different
    /// order than the pile, in format 7. the list stays intact around them
    function test_compose_pullsFromTheMiddleAndKeepsTheListIntact() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256[] memory ids = _sellN(alice, 85);
        assertEq(core.pileSize(Lane.Eth), 85);

        // leave the first, a few middle ones and the last in the pile.
        uint256[5] memory left = [uint256(0), 17, 40, 63, 84];
        uint256[80] memory page;
        uint256 n;
        for (uint256 i; i < 85; ++i) {
            bool stays;
            for (uint256 j; j < 5; ++j) {
                if (left[j] == i) stays = true;
            }
            if (!stays) page[n++] = ids[i];
        }
        assertEq(n, 80);
        (page[0], page[79]) = (page[79], page[0]);
        scripted.setPage(Lane.Eth, true, page, 7);
        uint256 supply = STATEMENTS.supply();
        vm.expectCall(address(STATEMENTS), abi.encodeWithSelector(STATEMENTS.compose.selector, page, uint8(7)));
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supply + 1);

        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pilePage(Lane.Eth, 0, 1)[0], ids[0]);
        uint256[] memory rest = core.pilePage(Lane.Eth, 0, 10);
        assertEq(rest.length, 5);
        for (uint256 j; j < 5; ++j) {
            assertEq(rest[j], ids[left[j]]);
        }
        assertEq(core.pilePage(Lane.Eth, ids[84], 1).length, 0);

        // a new arrival lands behind the old tail.
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pilePage(Lane.Eth, ids[84], 1)[0], more[0]);
        assertEq(core.pileSize(Lane.Eth), 6);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         doors that need no module
    //////////////////////////////////////////////////////////////*/

    /// the statement doors with no statement: `sellTo` is the controller's, `exitStatement` needs a module
    function test_statementDoorsRefuseAnUnknownStatement() public {
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo(1, alice);
        vm.prank(address(ctl));
        vm.expectRevert(ICore.NotForSale.selector);
        core.sellTo(1, alice);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(1);
        (bool held,,,) = core.statementInfo(1);
        assertFalse(held);
        assertEq(core.ethPot(), 0);
        assertEq(core.ethToBuyback(), 0);
    }

    /// with exitMode at its launch value 0 the exit token bid and composeExit are closed; the redemption door reverts
    /// NoExitModule once mode is on but no module is set
    function test_exitDoorsClosedAtLaunch() public {
        vm.prank(alice);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.sellForExitToken(_one(1));
        vm.prank(alice);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.sellForExitToken(_one(1), 0);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.composeExit();
        // exitStatement reverts NoExitModule whatever the mode while no module is set
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(1);
        core.skim();
    }

    function test_buyback_guards() public {
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
        // eth held without being booked into the buyback pot is not for sale to the buyback
        vm.deal(address(core), 1 ether);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(ICore.OnlyPoolManager.selector);
        core.unlockCallback("");
    }

    function test_onERC721Received_senders() public {
        vm.expectRevert(ICore.BadSender.selector);
        core.onERC721Received(address(0), address(0), 1, "");
        vm.prank(address(STATEMENTS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
        vm.prank(address(CREDITS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
    }

    /*//////////////////////////////////////////////////////////////
                         rate properties under fuzz
    //////////////////////////////////////////////////////////////*/

    /// invariant 6: the rate never rises in an interval where the pot was unfunded, and it never climbs past what the
    /// pot affords, from the launch settings or from a fast climb
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_rateProperties(
        uint256[6] memory amounts,
        uint256[6] memory waits,
        bool[6] memory sells,
        uint256 mode
    ) public {
        if (mode % 2 == 1) {
            Settings memory s = core.settings();
            s.climbPerMinBps = 1_000;
            s.recoveryClimbPerMinBps = 1_000;
            s.ceilBps = 30_000;
            _setSettings(s);
        }
        uint256[] memory ids = _credits(alice, 6);
        for (uint256 i; i < 6; ++i) {
            Settings memory st = core.settings();
            uint256 r0 = core.ethRate();
            _warp(bound(waits[i], 0, 120 hours));
            uint256 r1 = core.ethRate();
            // the read is at most the price state and at most the clamp of the pot. it can fall with time as the
            // remembered peak decays and pulls the ceiling anchor down toward the last fill rate (decision 74), so no
            // lower bound on the read across a warp holds
            assertLe(r1, core.ethPrice(), "the read is at most the price state");
            assertLe(r1, r0.max(BidModel.clamp(st, core.ethPot())), "never above the clamp");

            uint256 amount = bound(amounts[i], 0, 0.05 ether);
            if (amount != 0) _fund(amount);
            if (sells[i]) {
                vm.prank(alice);
                try core.sellForEth(_one(ids[i])) {} catch {}
            }
            _solvent();
        }
    }
}

/// everything that follows a real compose. the stand in exit module is set in `setUp`, the compose itself goes through
/// the real controller and the real Statements contract, once per test
contract CoreComposedTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
    }

    function _held() internal view returns (uint256[] memory) {
        return core.heldStatements();
    }

    /// @dev composes a second statement on top of the state of `_composeOnce`, through whichever controller is set
    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), sid);
    }

    /*//////////////////////////////////////////////////////////////
                                 compose
    //////////////////////////////////////////////////////////////*/

    function test_compose_statementIdCostBasisAndPiles() public {
        Composed memory c = _composeOnce();
        uint256[] memory ids = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = c.ids[i];
        }
        assertEq(c.sid, c.supplyBefore + 1);
        assertEq(STATEMENTS.supply(), c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the core holds it");
        assertEq(STATEMENTS.creditsOf(c.sid), 80);

        (bool held, Lane lane, uint256 cost, uint64 composedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, c.cost, "cost basis is the sum of the credits' cost bases");
        assertEq(composedAt, c.at);

        assertEq(core.pileSize(Lane.Eth), 0);
        assertEq(core.pilePage(Lane.Eth, 0, 1).length, 0);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,,) = core.creditInfo(ids[i]);
            assertFalse(inPile);
        }
        assertEq(CREDITS.balanceOf(address(core)), 0, "the credits were burned into the statement");
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], c.sid);
        assertEq(core.ethPot(), c.potBefore);
        _solvent();
    }

    /// at the launch settings the cost basis of a statement is the sum of the prices paid
    function test_compose_costBasisIsThePricesPaid() public {
        Composed memory c = _composeOnce();
        // every credit was sold at the rate of its fill, at most 20 percent over the opening rate
        assertLe(c.cost, 80 * OPEN_RATE * 12 / 10, "at most 80 credits, a rising rate");
        assertGt(c.cost, 80 * OPEN_RATE * 3 / 4, "and not far under");
    }

    /// at the launch values of `callerFee` and `callerMaxBaseFee` (zero) a compose moves no eth out of the Core: the
    /// Core balance and `ethPot` are unchanged, at any basefee and with the buyback payment settings at their ceilings
    function test_compose_movesNoEthOut() public {
        Composed memory c = _composeOnce();
        uint256 snap = preComposeSnap;
        uint256 supply = c.supplyBefore;
        uint256 gasPrice = 5 gwei;
        Settings memory s = core.settings();
        s.keeperFee = 0.005 ether;
        s.keeperMaxBaseFee = 100 gwei;

        vm.revertToState(snap);
        _setSettings(s);
        vm.fee(gasPrice);
        vm.txGasPrice(gasPrice);
        uint256 coreBefore = address(core).balance;
        uint256 potBefore = core.ethPot();
        uint256 callerBefore = keeper.balance;
        vm.prank(keeper);
        core.compose();
        assertEq(address(core).balance, coreBefore, "the core balance is unchanged");
        assertEq(core.ethPot(), potBefore, "the eth pot is unchanged");
        assertEq(keeper.balance, callerBefore, "the caller receives nothing");
        (,, uint256 cost,) = core.statementInfo(supply + 1);
        assertEq(cost, c.cost, "the cost basis is the credits only");
    }

    /*//////////////////////////////////////////////////////////////
                              exit path
    //////////////////////////////////////////////////////////////*/

    function test_exit_guards() public {
        Composed memory c = _composeOnce();
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(c.sid + 100);
        // an eth lane statement is not eligible until its asking price falls to its cost
        vm.expectRevert(ICore.NotEligible.selector);
        core.exitStatement(c.sid);
        _makeEligible(c.sid);
        core.exitStatement(c.sid);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(c.sid);
    }

    /// an eth lane redemption books the whole received amount into the bid pot
    function test_exit_ethLaneAllToTheBidPot() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        uint256 out = core.ratingOf(c.sid) * UNIT;
        uint256 pot = core.xPot();
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module keeps the statement");
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.xPot() - pot, out, "all received to the bid pot");
        assertEq(_held().length, 0);
        assertFalse(_isHeld(c.sid));
    }

    function test_exit_moduleThatUnderpaysReverts() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        mod.setPayBps(10_000 - core.settings().exitSlippageBps - 1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);
        mod.setPayBps(5000);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left");
        assertTrue(_isHeld(c.sid));
        // a payment within the slippage floor passes
        mod.setPayBps(10_000 - core.settings().exitSlippageBps);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod));
    }

    /// the unit is fixed when the module is set. a module that reports a lower unit later is held to the stored one, and
    /// one that pays by a higher unit is simply paid
    function test_exit_unitIsFixedAtSetTime() public {
        Composed memory c = _composeOnce();
        assertEq(core.unitPerPoint(), UNIT);
        _makeEligible(c.sid);
        mod.setUnitPerPoint(0);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);
        mod.setUnitPerPoint(3 * UNIT);
        uint256 out = core.ratingOf(c.sid) * 3 * UNIT;
        core.exitStatement(c.sid);
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.unitPerPoint(), UNIT, "the stored unit did not follow the module");
    }

    /*//////////////////////////////////////////////////////////////
                              exit token bid
    //////////////////////////////////////////////////////////////*/

    /// the per point bid pays each credit its score times the unit less the margin
    function test_xBid_paysScoreTimesUnit() public {
        _fillExitBuyback();
        xt.mint(address(core), 1e22);
        core.skim();
        uint256[] memory ids = _credits(alice, 2);
        uint256 net = 10_000 - core.settings().exitBidMarginBps;
        uint256 expect;
        for (uint256 i; i < 2; ++i) {
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(ids[i]), CREDITS.timestampOf(ids[i]));
            expect += score * UNIT * net / 10_000;
        }
        uint256 before = xt.balanceOf(alice);
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(alice) - before, expect, "paid score times the unit less the margin");
        _solvent();
    }

    function test_xBid_guards() public {
        _fillExitBuyback();
        xt.mint(address(core), 1e22);
        core.skim();
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForExitToken(none);
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForExitToken(_one(0));
        vm.prank(keeper);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForExitToken(ids);
        stdstore.target(address(core)).sig("xPot()").checked_write(uint256(1));
        vm.prank(alice);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForExitToken(ids);
    }

    /// the bid and composeExit are closed unless exitMode is 2
    function test_xBid_needsModeTwo() public {
        _fillExitBuyback();
        xt.mint(address(core), 1e22);
        core.skim();
        _setExitMode(1);
        uint256[] memory ids = _credits(alice, 1);
        vm.prank(alice);
        vm.expectRevert(ICore.ExitModeOff.selector);
        core.sellForExitToken(ids);
    }

    /// exit token that arrives outside an exit is booked only by `skim`, into the bid pot
    function test_xFees_skimBooksPlainTransfers() public {
        _fillExitBuyback();
        uint256 pot = core.xPot();
        core.skim();
        assertEq(core.xPot(), pot, "nothing above the pot");
        xt.mint(address(core), 3e18);
        assertEq(core.xPot(), pot);
        core.skim();
        assertEq(core.xPot(), pot + 3e18);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         exit lane compose and exit
    //////////////////////////////////////////////////////////////*/

    function test_exitLane_composeThenImmediateExit() public {
        _fillExitBuyback();
        xt.mint(address(core), 1e23);
        core.skim();

        uint256[] memory ids = _credits(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80);
        uint256 sumExit;
        for (uint256 i; i < 80; ++i) {
            (,, uint256 paidIn,) = core.creditInfo(ids[i]);
            sumExit += paidIn;
        }

        uint256 potBefore = core.ethPot();
        uint256 balBefore = keeper.balance;
        uint256 sidX = STATEMENTS.supply() + 1;
        vm.prank(keeper);
        core.composeExit();
        uint256 paid = keeper.balance - balBefore;

        assertEq(STATEMENTS.ownerOf(sidX), address(core), "held by the core");
        (bool held, Lane lane, uint256 cost,) = core.statementInfo(sidX);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Exit));
        assertEq(cost, sumExit, "exit token cost basis");
        assertEq(core.pileSize(Lane.Exit), 0);
        assertEq(core.ethPot(), potBefore);
        assertEq(paid, 0, "the compose pays the caller nothing");
        vm.prank(address(ctl));
        vm.expectRevert(ICore.NotForSale.selector);
        core.sellTo(sidX, alice);

        // the exit lane exits at once and everything returns to the bid pot
        uint256 xPotBefore = core.xPot();
        uint256 out = core.ratingOf(sidX) * UNIT;
        core.exitStatement(sidX);
        assertEq(core.xPot(), xPotBefore + out);
        assertEq(STATEMENTS.ownerOf(sidX), address(mod));
        _solvent();
    }
}
