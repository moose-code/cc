// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Settings, Mainnet, Stack, BUYBACK_GAS} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {SettingsFields} from "../script/SettingsFields.sol";

/// @notice the flow rework (docs/FLOW.md) on the real stack: settings, the flat bid, statement sales through the
/// controller, the phase 2 exit, and the hard rule that the owner can never move assets out under any settings
contract FlowTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant N = 26;

    // ------------------------------------------------------------------ helpers

    /// @dev books `eth` into the buying pot through the real `skim` door (a donation of eth to the core)
    function _potTo(uint256 eth) internal {
        uint256 have = core.ethPot();
        if (have >= eth) return;
        vm.deal(address(core), address(core).balance + (eth - have));
        core.skim();
    }

    function _owner(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    function _hash(Settings memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /// @dev the field tables are the ones of the scripts (`SettingsFields`), 26 fields in declaration order
    function _get(Settings memory s, uint256 i) internal pure returns (uint256) {
        return SettingsFields.get(s, i);
    }

    function _set(Settings memory s, uint256 i, uint256 v) internal pure {
        SettingsFields.set(s, i, v);
    }

    function _lo() internal pure returns (uint256[26] memory) {
        return SettingsFields.lo();
    }

    function _hi() internal pure returns (uint256[26] memory) {
        return SettingsFields.hi();
    }

    function _names() internal pure returns (bytes32[26] memory) {
        return SettingsFields.names();
    }

    /// @dev a valid settings struct derived from a seed, inside every bound and the two orderings
    function _valid(uint256 seed) internal pure returns (Settings memory s) {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = lo[i];
            uint256 b = hi[i];
            if (i == 16) b = s.xRateCap;
            _set(s, i, a + (b > a ? x % (b - a + 1) : 0));
        }
        // the slice is at least twice the largest buyback payment (field 11 is `buybackSlice`)
        uint256 minSlice = 2 * (BUYBACK_GAS * s.buybackMaxBaseFee + s.keeperFee);
        if (s.buybackSlice < minSlice) _set(s, 11, minSlice);
    }

    // ------------------------------------------------------------------ settings: values, bounds, access

    function test_settings_launchValues() public view {
        assertEq(_hash(core.settings()), _hash(Mainnet.defaultSettings()), "launch values");
        Settings memory s = core.settings();
        assertEq(s.dropPerCreditBps, 50);
        assertEq(s.dropFloorBps, 5_000);
        assertEq(s.climbPerMinBps, 50);
        assertEq(s.ceilBps, 11_000);
        assertEq(s.idleLoosenBps, 200);
        assertEq(s.tipSavingsBps, 2_500);
        assertEq(s.tipCapBps, 400);
        assertEq(s.saleFloorBps, 7_500);
        assertEq(s.exitAfter, 105 hours);
        assertEq(s.saleToBuybackBps, 5_000);
        assertEq(s.exitToBuybackBps, 5_000);
        assertEq(s.buybackSlice, 0.5 ether);
        assertEq(s.buybackDelay, 25);
        assertEq(s.keeperFee, 0.0005 ether);
        assertEq(s.buybackMaxBaseFee, 10 gwei);
        assertEq(s.xRateCap, 9_700);
        assertEq(s.xRateFloor, 3_000);
        assertEq(s.xRateClimbPerHour, 100);
        assertEq(s.xRateDropPerCredit, 20);
        assertEq(s.xAuctionHalfLife, 6 hours);
        assertEq(s.exitSliceCredits, 20);
        assertEq(s.rateCap, 26_700_000_000_000_000);
        assertEq(s.exitLaneToBuybackBps, 0);
        assertEq(s.feeToBuybackBps, 0);
        assertEq(s.callerFee, 0);
        assertEq(s.callerMaxBaseFee, 0);
    }

    /// @dev write then read of random valid settings: the packed layout the library unpacks matches the compiler's
    function testFuzz_settings_roundTrip(uint256 seed) public {
        Settings memory s = _valid(seed);
        vm.expectEmit(address(core));
        emit ICore.SettingsSet(s);
        _owner(s);
        assertEq(_hash(core.settings()), _hash(s), "round trip");
    }

    function test_settings_everyBoundEdgeIsAccepted() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            for (uint256 k; k < 2; ++k) {
                Settings memory s = Mainnet.defaultSettings();
                uint256 v = k == 0 ? lo[i] : hi[i];
                // the two fields bounded by another field
                if (i == 15 && k == 0) s.xRateFloor = 0;
                if (i == 16 && k == 1) v = s.xRateCap;
                // the smallest slice needs the cheapest buyback payment: 2 * (600,000 gas * 1 gwei + 0) is 0.0012 ether
                if (i == 11 && k == 0) (s.keeperFee, s.buybackMaxBaseFee) = (0, 1 gwei);
                _set(s, i, v);
                _owner(s);
                assertEq(_get(core.settings(), i), v, "edge stored");
            }
        }
    }

    function test_settings_everyBoundViolationReverts() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        bytes32[26] memory names = _names();
        for (uint256 i; i < N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // above the top
            _set(s, i, hi[i] + 1);
            // an xRateFloor above the cap names the floor
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
            // below the bottom (fields whose bottom is zero have none)
            if (lo[i] == 0 && i != 16) continue;
            s = Mainnet.defaultSettings();
            if (i == 16) {
                // the floor is bounded by the cap, so a cap below the floor is the violation, and it names the floor
                _set(s, 15, s.xRateFloor - 1);
                names[i] = "xRateFloor";
            } else {
                _set(s, i, lo[i] - 1);
            }
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
        }
    }

    function test_settings_buybackPaymentBounds() public {
        Settings memory s = Mainnet.defaultSettings();
        s.keeperFee = 0.005 ether;
        s.buybackMaxBaseFee = 100 gwei;
        _owner(s);
        s.buybackMaxBaseFee = 1 gwei;
        _owner(s);
        s.keeperFee = 0.005 ether + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("keeperFee")));
        core.setSettings(s);
        s.keeperFee = 0;
        s.buybackMaxBaseFee = 1 gwei - 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackMaxBaseFee")));
        core.setSettings(s);
        s.buybackMaxBaseFee = 100 gwei + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackMaxBaseFee")));
        core.setSettings(s);
    }

    /// `buybackSlice` is at least twice the largest buyback payment, `BUYBACK_GAS * buybackMaxBaseFee + keeperFee`
    function test_settings_buybackSliceCoversTwiceTheLargestPayment() public {
        Settings memory s = Mainnet.defaultSettings();
        bytes memory bad = abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackSlice"));
        // the launch payment is 600,000 gas at 10 gwei plus 0.0005 ether: twice that is 0.013 ether
        s.buybackSlice = 0.013 ether - 1;
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
        s.buybackSlice = 0.013 ether;
        _owner(s);
        assertEq(core.settings().buybackSlice, 0.013 ether);
        // a dearer payment raises the line, and a cheaper one lowers it
        s.keeperFee = 0.005 ether;
        s.buybackMaxBaseFee = 100 gwei;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.buybackSlice = uint128(2 * (BUYBACK_GAS * 100 gwei + 0.005 ether) - 1);
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
        s.buybackSlice += 1;
        _owner(s);
        s.keeperFee = 0;
        s.buybackMaxBaseFee = 1 gwei;
        s.buybackSlice = 0.01 ether;
        _owner(s);
        // the edge at another base fee ceiling
        s.buybackMaxBaseFee = 17 gwei;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.buybackSlice = uint128(2 * BUYBACK_GAS * 17 gwei - 1);
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
    }

    function test_settings_failedWriteChangesNothing() public {
        bytes32 before = _hash(core.settings());
        Settings memory s = Mainnet.defaultSettings();
        s.saleFloorBps = 999;
        vm.prank(owner);
        vm.expectRevert();
        core.setSettings(s);
        assertEq(_hash(core.settings()), before);
    }

    function test_setters_onlyOwner() public {
        address[4] memory nobody = [address(this), address(ctl), deployer, creator];
        Settings memory s = Mainnet.defaultSettings();
        for (uint256 i; i < nobody.length; ++i) {
            vm.startPrank(nobody[i]);
            vm.expectRevert(ICore.OnlyOwner.selector);
            core.setSettings(s);
            vm.expectRevert(ICore.OnlyOwner.selector);
            core.setRate(OPEN_RATE);
            vm.stopPrank();
        }
    }

    function test_setRate_boundsEventAndReset() public {
        uint256 cap = core.settings().rateCap;
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(1e13 - 1);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(cap + 1);
        vm.expectEmit(address(core));
        emit ICore.RateSet(2e13);
        core.setRate(2e13);
        assertEq(core.rateAtCheckpoint(), 2e13);
        assertEq(core.checkpointTime(), block.timestamp);
        core.setRate(1e13);
        core.setRate(cap);
        vm.stopPrank();
        // the top of the rate bounds needs the rate cap raised to it, and nothing passes the bounds
        Settings memory s = core.settings();
        s.rateCap = 1e18;
        _owner(s);
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(1e18 + 1);
        core.setRate(1e18);
        vm.stopPrank();
    }

    function test_setRate_readStaysAtTheClampOfThePot() public {
        _potTo(1e14);
        uint256 clamp = 1e14;
        Settings memory cs = core.settings();
        cs.rateCap = 1e18;
        _owner(cs);
        vm.prank(owner);
        core.setRate(1e18);
        assertEq(core.rateAtCheckpoint(), 1e18);
        assertEq(core.ethRate(), clamp, "a pot of 1e14 reads its clamp under a stored rate of 1e18");
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        assertEq(core.rateAtCheckpoint(), OPEN_RATE);
        assertEq(core.ethRate(), clamp, "and under the opening rate");
    }

    // ------------------------------------------------------------------ a settings change checkpoints

    /// @dev the eth rate after `mins` minutes of climb at `bps` per minute from `r`, the formula of the Core
    function _climbed(uint256 r, uint256 bps, uint256 mins) internal pure returns (uint256) {
        return r.mulWad(uint256(FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256(mins * 1e18))));
    }

    function test_checkpoint_ethRateKeepsOldClimb() public {
        _potTo(20 ether);
        assertEq(core.ethRate(), OPEN_RATE);
        _warp(10 minutes);
        uint256 old = _climbed(OPEN_RATE, 50, 10);
        assertEq(core.ethRate(), old, "10 minutes at 50 bps");
        Settings memory s = core.settings();
        s.climbPerMinBps = 200;
        _owner(s);
        // nothing is credited at the new numbers for the 10 minutes already gone
        assertEq(core.rateAtCheckpoint(), old, "stored at the old climb");
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(core.ethRate(), old);
        _warp(3 minutes);
        assertEq(core.ethRate(), _climbed(old, 200, 3), "3 minutes at 200 bps");
        // without the checkpoint the whole 13 minutes would have been priced at the new climb
        assertTrue(core.ethRate() != _climbed(OPEN_RATE, 200, 13));
    }

    function test_checkpoint_slowestClimbCreditsOnlyAfterTheChange() public {
        _potTo(20 ether);
        _warp(10 minutes);
        uint256 old = _climbed(OPEN_RATE, 50, 10);
        Settings memory s = core.settings();
        s.climbPerMinBps = 1;
        _owner(s);
        assertEq(core.rateAtCheckpoint(), old, "stored at the old climb");
        _warp(60 minutes);
        assertEq(core.ethRate(), _climbed(old, 1, 60), "an hour at 1 bps, the lowest climb");
    }

    function test_checkpoint_clampFollowsTheNewNumbers() public {
        _potTo(1e14);
        _warp(5 hours);
        // a pot of 1e14 affords less than one credit at the opening rate: the read is the clamp
        uint256 held = 1e14;
        assertEq(core.ethRate(), held, "bounded by the clamp");
        Settings memory s = core.settings();
        s.climbPerMinBps = 1_000;
        _owner(s);
        _warp(100 hours);
        assertEq(core.ethRate(), held, "the clamp is the pot under the new numbers");
        assertEq(core.rateAtCheckpoint(), OPEN_RATE, "the price state the change stored");
    }

    function test_checkpoint_exitRateKeepsOldClimb() public {
        _enterPhase2();
        xt.mint(address(core), 1e18);
        core.skim();
        assertEq(core.xRate(), 6_000);
        _warp(5 hours);
        assertEq(core.xRate(), 6_500);
        Settings memory s = core.settings();
        s.xRateClimbPerHour = 300;
        _owner(s);
        assertEq(core.xRate(), 6_500, "stored at the old climb");
        _warp(2 hours);
        assertEq(core.xRate(), 7_100, "2 hours at 300 bps");
    }

    function test_checkpoint_exitRateIsHeldInsideTheNewBand() public {
        Settings memory s = core.settings();
        s.xRateCap = 5_000;
        _owner(s);
        assertEq(core.xRate(), 5_000, "cap below the rate");
        s = core.settings();
        s.xRateCap = 9_700;
        s.xRateFloor = 5_500;
        _owner(s);
        assertEq(core.xRate(), 5_500, "floor above the rate");
    }

    function test_checkpoint_exitAuctionKeepsItsPriceWhenTheHalfLifeChanges() public {
        _enterPhase2();
        xt.mint(address(core), 0);
        uint256 got = _fillExitBuyback();
        assertGt(got, 0);
        _warp(9 hours);
        uint256 price = core.exitAuctionPrice();
        Settings memory s = core.settings();
        s.xAuctionHalfLife = 1 hours;
        _owner(s);
        assertEq(core.exitAuctionPrice(), price, "same price at the moment of the change");
        _warp(1 hours);
        assertApproxEqAbs(core.exitAuctionPrice(), price / 2, price / 1e6, "now halves every hour");
    }

    // ------------------------------------------------------------------ the price of a credit

    function _sellOne(uint256 id) internal returns (uint256 paid) {
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        paid = seller.balance - before;
    }

    /// every credit is paid the rate, whatever it is
    function test_price_everyCreditPaysTheRate() public {
        _potTo(1 ether);
        uint256[] memory ids = _credits(seller, 3);
        assertEq(core.ethRate(), OPEN_RATE);
        uint256 expect = core.ethRate();
        assertEq(_sellOne(ids[0]), expect, "paid the rate");
        expect = core.ethRate();
        assertEq(_sellOne(ids[1]), expect, "the next credit is paid the dropped rate");
        assertEq(expect, OPEN_RATE * 9_950 / 10_000);
    }

    // ------------------------------------------------------------------ compose holds the statement

    function test_compose_holdsTheStatementAndRecordsTheComposeTime() public {
        Composed memory c = _composeOnce();
        (bool held, Lane lane, uint256 cost, uint64 composedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint256(lane), uint256(Lane.Eth));
        assertEq(cost, c.cost, "cost basis is the sum of the credits' cost bases");
        assertEq(composedAt, c.at);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the core holds the statement");
        assertEq(ctl.priceOf(c.sid), cost * 15_000 / 10_000, "150 percent of cost");
        assertEq(core.heldStatements().length, 1);
        assertEq(core.heldStatements()[0], c.sid);
    }

    function test_compose_askingPriceReadsTheSettingsLive() public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        Settings memory s = core.settings();
        s.saleFloorBps = 20_000;
        _owner(s);
        assertEq(ctl.priceOf(c.sid), cost * 20_000 / 10_000, "the hard floor lifts the ask of the held statement");
    }

    /// the `Composed` log: `sid` and `caller` are indexed, the data is `(lane, format, cost)` with the cost the sum of the
    /// 80 bases of the page
    function test_compose_emitsComposedWithTheSumOfTheBases() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (,, uint256 base,) = core.creditInfo(page[i]);
            sum += base;
        }
        vm.fee(composeBasefee);
        vm.recordLogs();
        vm.prank(keeper);
        core.compose();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.Composed.selector) continue;
            ++seen;
            assertEq(logs[i].topics.length, 3, "sid and caller are indexed");
            assertEq(uint256(logs[i].topics[1]), STATEMENTS.supply(), "sid");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), keeper, "caller");
            (uint8 lane, uint8 format, uint256 cost) = abi.decode(logs[i].data, (uint8, uint8, uint256));
            assertEq(lane, uint8(Lane.Eth));
            assertEq(format, 0);
            assertEq(cost, sum, "cost is the sum of the 80 bases");
            assertEq(logs[i].data.length, 96, "lane, format and cost only");
        }
        assertEq(seen, 1, "one Composed");
    }

    function test_compose_exitLaneStatementIsHeldAndNotForSale() public {
        _enterPhase2();
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        (bool held, Lane lane,, uint64 composedAt) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint256(lane), uint256(Lane.Exit));
        assertEq(composedAt, block.timestamp);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "held by the core");
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(sid);
    }

    /// the removed auction surface answers with an empty revert (no function, no fallback), where a live function
    /// would revert with its own error
    function test_noAuctionSurfaceRemains() public {
        string[8] memory sigs = [
            "collectSales()",
            "syncStatement(uint256)",
            "repriceStatement(uint256)",
            "statementStatus(uint256)",
            "HOUSE()",
            "AUCTION_FACTORY()",
            "buyOnly()",
            "statementPrice(uint256,uint256,uint64)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            bytes memory data = abi.encodeWithSignature(sigs[i], uint256(1), uint256(1), uint64(1));
            (bool ok, bytes memory why) = address(core).call(data);
            assertFalse(ok, sigs[i]);
            assertEq(why.length, 0, sigs[i]);
            if (i < 6) continue;
            (ok, why) = address(ctl).call(data);
            assertFalse(ok, sigs[i]);
            assertEq(why.length, 0, sigs[i]);
        }
        (bool ok2,) = address(ctl).call(abi.encodeWithSignature("setBuyOnly(bool)", true));
        assertFalse(ok2);
    }

    // ------------------------------------------------------------------ selling through the controller

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function _saleSplit(uint256 bps) internal {
        Settings memory s = core.settings();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.saleToBuybackBps = uint16(bps);
        _owner(s);
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.priceOf(sid);
        uint256 balance = address(core).balance;
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 toBuyback = price * bps / 10_000;
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, alice, price, toBuyback);
        assertEq(_buy(alice, sid), price);
        assertEq(STATEMENTS.ownerOf(sid), alice);
        assertEq(address(core).balance, balance + price, "the payment is in the core");
        assertEq(core.ethToBuyback(), buyback + toBuyback, "buyback share");
        assertEq(core.ethPot(), pot + price - toBuyback, "pot share");
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    function test_sale_splitHalf() public {
        _saleSplit(5_000);
    }

    function test_sale_splitAllToThePot() public {
        _saleSplit(0);
    }

    function test_sale_splitAllToTheBuyback() public {
        _saleSplit(10_000);
    }

    function test_sale_splitOddShareRoundsDownToTheBuyback() public {
        _saleSplit(3_333);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_sale_anySplitIsExact(uint256 bps) public {
        _saleSplit(bound(bps, 0, 10_000));
    }

    function test_sale_booksTheSplitOfTheSaleTime() public {
        (, uint256 price) = _sellStatement(alice);
        uint256 buyback = core.ethToBuyback();
        assertEq(buyback, price * 5_000 / 10_000);
        Settings memory s = core.settings();
        s.saleToBuybackBps = 2_000;
        _owner(s);
        assertEq(core.ethToBuyback(), buyback, "a later change books nothing again");
    }

    function test_buyback_burnsWhatTheSaleBooked() public {
        _sellStatement(alice);
        assertGt(core.ethToBuyback(), 0);
        uint256 supply = coin.totalSupply();
        _warp(1);
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supply, "coin was bought and burned");
        assertGt(keeper.balance, 0, "the keeper payment");
        _solvent();
    }

    // ------------------------------------------------------------------ skim never double books sale proceeds

    function _booked() internal view returns (uint256) {
        return core.ethPot() + core.ethToBuyback();
    }

    function test_skim_findsNothingAfterASale() public {
        uint256 sid = _composeOnce().sid;
        core.skim();
        uint256 booked = _booked();
        uint256 price = _buy(alice, sid);
        assertEq(_booked(), booked + price, "booked once by the sale");
        vm.expectEmit(address(core));
        emit ICore.Skimmed(0, 0);
        core.skim();
        assertEq(_booked(), booked + price, "and not again by skim");
        _solvent();
    }

    function test_skim_afterASaleWithADonationBooksOnlyTheDonation() public {
        (, uint256 price) = _sellStatement(alice);
        uint256 booked = _booked();
        // an unrelated donation sits unbooked in the core
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(core).balance - _booked(), 1 ether, "the donation is unbooked");
        vm.expectEmit(address(core));
        emit ICore.Skimmed(1 ether, 0);
        core.skim();
        assertEq(_booked(), booked + 1 ether);
        core.skim();
        assertEq(_booked(), booked + 1 ether, "nothing left to book");
        assertGt(price, 0);
        _solvent();
    }

    // ------------------------------------------------------------------ phase 2 exit

    function _exitSplit(uint256 bps) internal {
        Settings memory s = core.settings();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.exitToBuybackBps = uint16(bps);
        _owner(s);
        _enterPhase2();
        Composed memory c = _composeOnce();
        (,,, uint64 composedAt) = core.statementInfo(c.sid);
        vm.warp(composedAt + 105 hours - 1);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(composedAt + 105 hours);
        uint256 rating = STATEMENTS.creditsOf(c.sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 pot = core.xPot();
        vm.expectEmit(address(core));
        emit ICore.StatementExited(c.sid, Lane.Eth, rating * UNIT);
        vm.prank(bob);
        core.exitStatement(c.sid);
        uint256 got = xt.balanceOf(address(core)) - before;
        assertEq(got, rating * UNIT, "the module paid rating times the unit");
        assertEq(core.xToBuyback(), got * bps / 10_000, "buyback share of the exit token");
        assertEq(core.xPot() - pot, got - got * bps / 10_000, "bid share of the exit token");
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "in the module");
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    function test_exit_afterExitAfterExitsSplitHalf() public {
        _exitSplit(5_000);
    }

    function test_exit_splitAllToTheBid() public {
        _exitSplit(0);
    }

    function test_exit_splitAllToTheBuyback() public {
        _exitSplit(10_000);
    }

    function test_exit_splitOddShare() public {
        _exitSplit(3_333);
    }

    function test_exit_exitAfterIsASetting() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        Settings memory s = core.settings();
        s.exitAfter = 365 days;
        _owner(s);
        vm.warp(block.timestamp + 100 days);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        s.exitAfter = 1 hours;
        _owner(s);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_exit_needsTheModule() public {
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(sid);
    }

    function test_exit_aSoldStatementIsNotExited() public {
        _enterPhase2();
        (uint256 sid,) = _sellStatement(alice);
        _warp(105 hours);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), alice);
    }

    function test_exit_exitLaneIsUnchanged() public {
        _enterPhase2();
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        uint256 rating = STATEMENTS.creditsOf(sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 buyback = core.xToBuyback();
        // at once, no wait
        core.exitStatement(sid);
        assertEq(xt.balanceOf(address(core)) - before, rating * UNIT);
        assertEq(core.xToBuyback(), buyback, "an exit lane exit adds nothing to the buyback");
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    // ------------------------------------------------------------------ the constructor

    function _newCore(Settings memory s, address escrow) internal returns (ICore) {
        Stack memory st = lc.stack;
        st.escrow = escrow;
        return Prod.newCore(owner, address(coin), address(ctl), st, OPEN_RATE, s);
    }

    function test_constructor_storesTheSettings() public {
        ICore c2 = _newCore(Mainnet.defaultSettings(), lc.stack.escrow);
        assertEq(_hash(c2.settings()), _hash(Mainnet.defaultSettings()));
        assertEq(STATEMENTS.balanceOf(address(c2)), 0);
    }

    function test_constructor_refusesBadInputs() public {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 0;
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("dropPerCreditBps")));
        this.newCoreExternal(s, lc.stack.escrow);
        // the opening rate (OPEN_RATE) may not sit above the rate cap
        Settings memory capped = Mainnet.defaultSettings();
        // forge-lint: disable-next-line(unsafe-typecast)
        capped.rateCap = uint64(OPEN_RATE - 1);
        vm.expectRevert(ICore.BadRate.selector);
        this.newCoreExternal(capped, lc.stack.escrow);
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.newCoreExternal(Mainnet.defaultSettings(), address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, address(0xBEEF)));
        this.newCoreExternal(Mainnet.defaultSettings(), address(0xBEEF));
    }

    function newCoreExternal(Settings memory s, address escrow) external returns (ICore) {
        return _newCore(s, escrow);
    }

    // ------------------------------------------------------------------ the rate never reverts, however long the gap

    function _longGap(uint256 climbPerMin, uint256 ceilBps, uint256 loosen, uint256 gap) internal {
        Settings memory s = core.settings();
        s.climbPerMinBps = uint16(climbPerMin);
        s.ceilBps = uint16(ceilBps);
        s.idleLoosenBps = uint16(loosen);
        _owner(s);
        _potTo(1 ether);
        _warp(gap);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        assertLt(g - gasleft(), 400_000, "bounded work");
        assertLe(r, uint256(1 ether), "clamped at the pot");
        vm.deal(core.FEE_SOURCE(), 1 ether);
        uint256 pot = core.ethPot();
        vm.prank(core.FEE_SOURCE());
        (bool ok,) = address(core).call{value: 1e15}("");
        assertTrue(ok, "receive does not revert");
        assertEq(core.ethPot(), pot + 1e15, "booked");
    }

    function test_rate_fastestLoosenAndClimbOverTwentyYears() public {
        _longGap(1_000, 30_000, 2_000, 20 * 365 days);
    }

    function test_rate_slowestClimbOverACentury() public {
        _longGap(1, 10_000, 1, 100 * 365 days);
    }

    function test_rate_fastestClimbOverACentury() public {
        _longGap(1_000, 30_000, 2_000, 100 * 365 days);
    }

    // ------------------------------------------------------------------ hard rule 8

    /// @dev what an account holds of everything the core could hand out
    function _holdings(address who) internal view returns (uint256[5] memory h) {
        h[0] = who.balance;
        h[1] = coin.balanceOf(who);
        h[2] = CREDITS.balanceOf(who);
        h[3] = STATEMENTS.balanceOf(who);
        h[4] = address(xt) == address(0) ? 0 : xt.balanceOf(who);
    }

    function _noGain(address who, uint256[5] memory base, string memory what) internal view {
        uint256[5] memory now_ = _holdings(who);
        for (uint256 i; i < 5; ++i) {
            assertLe(now_[i], base[i], what);
        }
    }

    /// @dev a random sequence of owner calls under random valid settings, mixed with public doors and time. the
    /// owner and the controller never end up holding more eth, coin, credits, statements or exit token than they
    /// began with, an owner call never changes what the core holds, and eth leaves the core only by a sale of a credit
    /// (paid to the seller, exactly the quoted ceiling) or by the buyback (at most one slice). the exit is a paid door
    /// (it pays its caller from the pot), so it is called by a neutral keeper that is not watched,
    /// and what that keeper receives is at most the gas cap at the capped base fee plus the fee
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rule8_noSettingsOrOwnerCallMovesAssetsOut(uint256 seed) public {
        if (seed % 2 == 1) _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _potTo(1 ether);
        ScriptedController hostile = new ScriptedController();
        _setController(address(hostile));
        uint256[] memory ids = _credits(seller, 6);
        address[3] memory watched = [owner, address(hostile), address(ctl)];
        uint256[5][3] memory base;
        for (uint256 i; i < 3; ++i) {
            base[i] = _holdings(watched[i]);
        }
        uint256 next;
        for (uint256 step; step < 12; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, "step", step)));
            uint256 coreEth = address(core).balance;
            uint256 kind = r % 9;
            if (kind <= 4) {
                _ownerCall(kind, r);
                assertEq(address(core).balance, coreEth, "an owner call never moves the core's eth");
            } else if (kind == 5) {
                next = _publicDoor(sid, r, next);
            } else if (kind == 6) {
                _warp(1 hours + (r >> 8) % 3 days);
            } else if (kind == 7) {
                _sellMaybe(ids[(r >> 8) % 6]);
            } else {
                _exitAsKeeper(sid);
            }
            for (uint256 i; i < 3; ++i) {
                _noGain(watched[i], base[i], "owner or controller gained");
            }
            _solvent();
        }
    }

    /// @dev a neutral keeper exits the statement. the paid door pays it at most `EXIT_GAS` at `callerMaxBaseFee` plus
    /// `callerFee`
    function _exitAsKeeper(uint256 sid) internal {
        address exitKeeper = makeAddr("exitKeeper");
        Settings memory st = core.settings();
        uint256 cap = 1_500_000 * uint256(st.callerMaxBaseFee) + st.callerFee;
        uint256 before = exitKeeper.balance;
        vm.prank(exitKeeper);
        try core.exitStatement(sid) {} catch {}
        assertLe(exitKeeper.balance - before, cap, "the exit payment stays within the cap");
    }

    /// @dev the owner who calls the paid exit door is paid like any keeper: exactly the pot debit, within the cap
    function test_rule8_ownerAsRedeemCallerGetsOnlyTheCappedPayment() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        Settings memory st = core.settings();
        st.callerFee = 0.0005 ether;
        st.callerMaxBaseFee = 10 gwei;
        _setSettings(st);
        _potTo(1 ether);
        (,,, uint64 composedAt) = core.statementInfo(c.sid);
        vm.warp(composedAt + 105 hours);
        uint256 cap = 1_500_000 * uint256(st.callerMaxBaseFee) + st.callerFee;
        uint256 pot = core.ethPot();
        uint256 coreEth = address(core).balance;
        uint256[5] memory base = _holdings(owner);
        vm.fee(composeBasefee);
        vm.prank(owner);
        core.exitStatement(c.sid);
        uint256 gain = owner.balance - base[0];
        assertGt(gain, 0, "the paid door repays its caller");
        assertEq(gain, pot - core.ethPot(), "exactly the pot debit");
        assertEq(gain, coreEth - address(core).balance, "exactly what left the core");
        assertLe(gain, cap, "within the cap");
        assertEq(coin.balanceOf(owner), base[1]);
        assertEq(CREDITS.balanceOf(owner), base[2]);
        assertEq(STATEMENTS.balanceOf(owner), base[3]);
        assertEq(xt.balanceOf(owner), base[4]);
    }

    function _ownerCall(uint256 kind, uint256 r) internal {
        vm.startPrank(owner);
        if (kind == 0) {
            core.setSettings(_valid(r));
        } else if (kind == 1) {
            core.setRate(bound(r >> 8, 1e13, core.settings().rateCap));
        } else if (kind == 2) {
            Settings memory s = core.settings();
            _storeXRate(bound(r >> 8, s.xRateFloor, s.xRateCap));
        } else if (kind == 3) {
            address t = address(uint160(r >> 8));
            try core.addTarget(t) {} catch {}
            core.removeTarget(t);
        } else {
            core.removeTarget(Mainnet.SEAPORT);
        }
        vm.stopPrank();
    }

    /// @dev permissionless doors called by the owner or a stranger. the buyback may spend at most one slice. an owner
    /// who acts as a keeper is paid like anyone, which is why the owner does not call the paid doors here
    function _publicDoor(uint256, uint256 r, uint256) internal returns (uint256) {
        uint256 pick = (r >> 8) % 2;
        // the buyback pays its caller, so the owner is not the keeper in this run
        address who = pick != 1 && r % 2 == 0 ? owner : bob;
        uint256 before = address(core).balance;
        uint256 slice =
            core.ethToBuyback() < core.settings().buybackSlice ? core.ethToBuyback() : core.settings().buybackSlice;
        vm.startPrank(who);
        if (pick == 0) {
            try core.skim() {} catch {}
        } else {
            try core.buyback() {} catch {}
        }
        vm.stopPrank();
        if (address(core).balance < before) {
            assertEq(pick, 1, "only the buyback spends eth here");
            assertLe(before - address(core).balance, slice, "at most one slice");
        }
        return 0;
    }

    /// @dev the seller sells a credit. whatever the settings, the core pays the quoted ceiling. the door flushes the fee
    /// router first and the Core books that eth, so the router is flushed before the balance is read
    function _sellMaybe(uint256 id) internal {
        if (CREDITS.ownerOf(id) != seller) return;
        _flush();
        uint256 quote = core.ethRate();
        uint256 coreBefore = address(core).balance;
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        try core.sellForEth(_one(id)) {
            assertEq(sellerBefore + quote, seller.balance, "paid the quote");
            assertEq(coreBefore - quote, address(core).balance, "the core paid exactly that");
        } catch {}
    }
}
