// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Mainnet, Stack, BUYBACK_GAS} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {SettingsFields} from "../script/SettingsFields.sol";

/// @notice the flow rework (docs/DECISIONS.md) on the real stack: settings, the flat bid, statement sales through the
/// controller, the balance side redemption, and the hard rule that the owner can never move assets out under any settings
contract FlowTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant N = 26;

    // ------------------------------------------------------------------ helpers

    /// @dev adds eth to the buying pot through the real `fund` door
    function _potTo(uint256 eth) internal {
        uint256 have = core.ethPot();
        if (have >= eth) return;
        vm.deal(address(this), address(this).balance + (eth - have));
        core.fund{value: eth - have}();
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
            // recoveryClimbPerMinBps (field 7) is bounded below by climbPerMinBps (field 2)
            if (i == 7 && s.climbPerMinBps > a) a = s.climbPerMinBps;
            _set(s, i, a + (b > a ? x % (b - a + 1) : 0));
        }
        // the slice is at least twice the largest buyback payment (field 16 is `buybackSlice`)
        uint256 minSlice = 2 * (BUYBACK_GAS * s.keeperMaxBaseFee + s.keeperFee);
        if (s.buybackSlice < minSlice) _set(s, 16, minSlice);
        // redeemSlippageBps (field 13) is bounded above by balanceBidMarginBps (field 14), set later in the loop
        if (s.redeemSlippageBps > s.balanceBidMarginBps) _set(s, 13, s.balanceBidMarginBps);
    }

    // ------------------------------------------------------------------ settings: values, bounds, access

    // promise: SPEC 2 settings at launch
    function test_settings_launchValues() public view {
        assertEq(_hash(core.settings()), _hash(Mainnet.defaultSettings()), "launch values");
        Settings memory s = core.settings();
        assertEq(s.dropPerCreditBps, 50);
        assertEq(s.dropFloorBps, 5_000);
        assertEq(s.climbPerMinBps, 50);
        assertEq(s.ceilBps, 11_000);
        assertEq(s.idleLoosenBps, 200);
        assertEq(s.saleFloorBps, 10_000);
        assertEq(s.saleToBuybackBps, 2_500);
        assertEq(s.buybackSlice, 0.5 ether);
        assertEq(s.buybackDelay, 25);
        assertEq(s.keeperFee, 0.0003 ether);
        assertEq(s.keeperMaxBaseFee, 5 gwei);
        assertTrue(s.redeemOn);
        assertFalse(s.balanceBidOn);
        assertEq(s.redeemSlippageBps, 200);
        assertEq(s.balanceBidMarginBps, 9_000);
        assertEq(s.redeemBurnBps, 2_000);
        assertEq(s.rateCap, 26_700_000_000_000_000);
        assertEq(s.feeToRedeemBurnBps, 1_000);
        assertEq(s.callerFee, 0);
        assertEq(s.callerMaxBaseFee, 0);
    }

    // promise: SPEC 2 every setting reads back as written
    /// @dev write then read of random valid settings
    function testFuzz_settings_roundTrip(uint256 seed) public {
        Settings memory s = _valid(seed);
        vm.expectEmit(address(core));
        emit ICore.SettingsSet(s);
        _owner(s);
        assertEq(_hash(core.settings()), _hash(s), "round trip");
    }

    // promise: INTEGRATION BadSetting: bounds are inclusive
    function test_settings_everyBoundEdgeIsAccepted() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            for (uint256 k; k < 2; ++k) {
                Settings memory s = Mainnet.defaultSettings();
                uint256 v = k == 0 ? lo[i] : hi[i];
                // the fields bounded by another field
                // the lowest recoveryClimbPerMinBps the config affords is climbPerMinBps
                if (i == 7 && k == 0) v = s.climbPerMinBps;
                // climbPerMinBps at its top needs recoveryClimbPerMinBps raised to stay at or above it
                if (i == 2 && k == 1) s.recoveryClimbPerMinBps = 1_000;
                // the smallest slice needs the cheapest buyback payment: 2 * (600,000 gas * 1 gwei + 0) is 0.0012 ether
                if (i == 16 && k == 0) (s.keeperFee, s.keeperMaxBaseFee) = (0, 1 gwei);
                // balanceBidMarginBps at its bottom (0) needs redeemSlippageBps lowered to it, which it bounds
                if (i == 14 && k == 0) s.redeemSlippageBps = 0;
                _set(s, i, v);
                _owner(s);
                assertEq(_get(core.settings(), i), v, "edge stored");
            }
        }
    }

    // promise: INTEGRATION BadSetting
    function test_settings_everyBoundViolationReverts() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        bytes32[26] memory names = _names();
        for (uint256 i; i < N; ++i) {
            // the two switches take 0 or 1, nothing is out of bounds
            if (i == 11 || i == 12) continue;
            Settings memory s = Mainnet.defaultSettings();
            // above the top
            _set(s, i, hi[i] + 1);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
            // below the bottom (fields whose bottom is zero have none)
            if (lo[i] == 0) continue;
            s = Mainnet.defaultSettings();
            _set(s, i, lo[i] - 1);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
        }
    }

    // promise: INTEGRATION SliceTooSmall: the slice bound follows the payment bound
    /// `buybackSlice` is at least twice the largest buyback payment, `BUYBACK_GAS * keeperMaxBaseFee + keeperFee`
    function test_settings_buybackSliceCoversTwiceTheLargestPayment() public {
        Settings memory s = Mainnet.defaultSettings();
        bytes memory bad = abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackSlice"));
        // the launch payment is 600,000 gas at 5 gwei plus 0.0003 ether: twice that is 0.0066 ether, under the 0.01 ether
        // lower bound of the slice, so the lower bound governs
        s.buybackSlice = 0.01 ether - 1;
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
        s.buybackSlice = 0.01 ether;
        _owner(s);
        assertEq(core.settings().buybackSlice, 0.01 ether);
        // a dearer payment raises the line, and a cheaper one lowers it
        s.keeperFee = 0.005 ether;
        s.keeperMaxBaseFee = 100 gwei;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.buybackSlice = uint128(2 * (BUYBACK_GAS * 100 gwei + 0.005 ether) - 1);
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
        s.buybackSlice += 1;
        _owner(s);
        s.keeperFee = 0;
        s.keeperMaxBaseFee = 1 gwei;
        s.buybackSlice = 0.01 ether;
        _owner(s);
        // the edge at another base fee ceiling
        s.keeperMaxBaseFee = 17 gwei;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.buybackSlice = uint128(2 * BUYBACK_GAS * 17 gwei - 1);
        vm.prank(owner);
        vm.expectRevert(bad);
        core.setSettings(s);
    }

    // promise: INTEGRATION BadRate; SPEC 1 setRate restores the bid at once
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

    // ------------------------------------------------------------------ a settings change checkpoints

    // ------------------------------------------------------------------ the price of a credit

    function _sellOne(uint256 id) internal returns (uint256 paid) {
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        paid = seller.balance - before;
    }

    // ------------------------------------------------------------------ compose holds the statement

    // promise: INTEGRATION Composed event carries the 80 ids and the cost
    /// the `Composed` log: `sid` and `caller` are indexed, the data is `(ids[80], format, cost, price)` with the cost the sum
    /// of the 80 bases of the page, `ids` the 80 composed credits and `price` the controller's `priceOf(sid)` after the compose
    function test_compose_emitsComposedWithTheSumOfTheBases() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(0, 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (, uint256 base,) = core.creditInfo(page[i]);
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
            (uint256[80] memory ids, uint8 format, uint256 cost, uint256 price) =
                abi.decode(logs[i].data, (uint256[80], uint8, uint256, uint256));
            for (uint256 j; j < 80; ++j) {
                assertEq(ids[j], page[j], "the 80 composed ids");
            }
            assertEq(format, defaultFormat(page[0]), "the derived format");
            assertEq(cost, sum, "cost is the sum of the 80 bases");
            assertGt(price, 0, "a listing price");
            assertEq(price, ctl.priceOf(STATEMENTS.supply()), "price is the controller's priceOf(sid) at the compose");
            assertEq(logs[i].data.length, (80 + 3) * 32, "ids, format, cost and price");
        }
        assertEq(seen, 1, "one Composed");
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
        uint256 artistBefore = core.artist().balance;
        uint256 payeeBefore = core.payee().balance;
        uint256 toArtist = price * s.saleToArtistBps / 10_000;
        uint256 toOperator = price * s.saleToOperatorBps / 10_000;
        uint256 rest = price - toArtist - toOperator;
        uint256 toBuyback = rest * bps / 10_000;
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, alice, price, toBuyback, toArtist, toOperator);
        assertEq(_buy(alice, sid), price);
        assertEq(STATEMENTS.ownerOf(sid), alice);
        assertEq(address(core).balance, balance + rest, "the rest stays in the core after the cuts");
        assertEq(core.ethToBuyback(), buyback + toBuyback, "buyback share");
        assertEq(core.ethPot(), pot + rest - toBuyback, "pot share");
        assertEq(core.artist().balance, artistBefore + toArtist, "artist cut pushed");
        assertEq(core.payee().balance, payeeBefore + toOperator, "operator cut pushed");
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    // promise: SPEC 1 sale proceeds split between ethPot and the buyback pot with no remainder (inv 18)
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_sale_anySplitIsExact(uint256 bps) public {
        _saleSplit(bound(bps, 0, 10_000));
    }

    // promise: SPEC 1 half of every sale burns coin
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

    // ------------------------------------------------------------------ the book never double counts sale proceeds

    function _booked() internal view returns (uint256) {
        return _tracked();
    }

    // ------------------------------------------------------------------ the balance side redemption

    // promise: SPEC 1 redeemBurnBps of the reserve moves to the buyback on each redemption
    /// each eth lane redemption moves redeemBurnBps of the reserve into the coin buyback
    function test_redeem_redeemReleasesTheReserveToTheBuyback() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        // fund the reserve directly and back it with real eth so the pots stay solvent (slot 8 is ethRedeemBurn,
        // test/CoreLayout.t.sol pins it)
        uint256 old = core.ethRedeemBurn();
        uint256 reserve = old + 1 ether;
        vm.deal(address(core), address(core).balance + 1 ether);
        vm.store(address(core), bytes32(uint256(8)), bytes32(reserve));
        assertEq(core.ethRedeemBurn(), reserve);
        uint256 buyback = core.ethToBuyback();
        uint256 released = reserve * core.settings().redeemBurnBps / 10_000;
        assertGt(released, 0, "there is something to release");
        core.redeemStatement(c.sid);
        assertEq(core.ethRedeemBurn(), reserve - released, "the reserve fell by redeemBurnBps");
        assertEq(core.ethToBuyback(), buyback + released, "the release reached the coin buyback");
        _solvent();
    }

    // ------------------------------------------------------------------ the constructor

    function _newCore(Settings memory s, address escrow) internal returns (ICore) {
        Stack memory st = lc.stack;
        st.escrow = escrow;
        return _launchCore(address(ctl), st, OPEN_RATE, s);
    }

    // promise: INTEGRATION BadSetting, BadStack on the constructor
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

    // ------------------------------------------------------------------ hard rule 8

}
