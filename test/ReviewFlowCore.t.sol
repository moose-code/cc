// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoreLib} from "../src/interfaces/ICoreLib.sol";
import {
    Settings,
    Mainnet,
    IStatements,
    RATE_START_MIN_WEI,
    RATE_START_MAX_WEI
} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";

/// @notice independent review of the flow rework, settings and the library split (REVIEW-flow-core.md, git history before packet 0).
/// every test_POC_ test passes and shows the bad outcome on the fork
contract ReviewFlowCoreTest is Fixture {
    /// @dev what one credit costs on the open market at the pin, used only to price what an accomplice paid
    uint256 internal constant MARKET = 0.0089 ether;

    /// FC-1 (accepted by the owner): the owner sets the price the engine pays, so an accomplice seller can be overpaid.
    /// the pot is the only limit: with the rate at the launch `rateCap` the credits of one transaction take the whole
    /// pot, as many as the pot pays, the last at the clamp
    function test_ACCEPTED_ownerCanOverpayAnAccompliceSeller() public {
        _skipSniperWindow();
        _fundPot(1 ether);
        uint256 pot = core.ethPot();
        vm.warp(block.timestamp + 2 hours);
        uint256 launchCap = core.settings().rateCap;
        vm.prank(owner);
        core.setRate(launchCap);
        uint256 got;
        uint256 n;
        for (uint256 j; j < 300; ++j) {
            uint256[] memory one = _credits(seller, 1);
            uint256 p = core.ethRate();
            if (p == 0) break;
            uint256 b = seller.balance;
            vm.prank(seller);
            core.sellForEth(one);
            got += seller.balance - b;
            ++n;
        }
        emit log_named_uint("pot before (wei)", pot);
        emit log_named_uint("paid to the accomplice (wei)", got);
        emit log_named_uint("market value of the credits (wei)", n * MARKET);
        assertEq(got, pot, "the whole pot in one block");
        assertGt(got, n * MARKET * 3 / 2, "paid well above the market");
        _solvent();
    }

    function _expectBad(Settings memory s, bytes32 field) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, field));
        core.setSettings(s);
    }

    /// FC-2 (fixed by bounds): saleFloorBps starts at 1_000. at the floor a buyer pays 10 percent of cost once the
    /// asking price has decayed to it
    function test_FIXED_saleFloorBound() public {
        _skipSniperWindow();
        _fillEthPile(80);
        Settings memory s = core.settings();
        s.saleFloorBps = 999;
        _expectBad(s, "saleFloorBps");
        s.saleFloorBps = 1_000;
        _setSettings(s);
        // the controller asks the floor too once its price has decayed
        vm.startPrank(owner);
        ctl.setFloorBps(1_000);
        ctl.setFastDecayBpsPerHour(10_000);
        ctl.setSlowDecayBpsPerHour(10_000);
        vm.stopPrank();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        (, uint256 cost,) = core.statementInfo(sid);
        _warp(2 hours);
        assertEq(ctl.priceOf(sid), cost * 1_000 / 10_000, "the ask at the floor is 10 percent of cost");
        address buyer = _user("buyer");
        assertEq(_buy(buyer, sid), cost * 1_000 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    /// held: a constructor against a library address with no code reverts (the delegatecall has a code check)
    function test_constructorRefusesAnEmptyLibraryAddress() public {
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0), "library found");
        // control: the same construction works while the library has code
        ICore ok = Prod.newCore(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
        assertEq(ok.settings().dropPerCreditBps, lc.settings.dropPerCreditBps, "control builds");
        vm.etch(lib, "");
        bool built;
        try this.buildCore() returns (ICore c2) {
            built = true;
            emit log("constructed against an empty library");
            emit log_named_uint("dropPerCreditBps stored", c2.settings().dropPerCreditBps);
        } catch {
            emit log("constructor reverted");
        }
        assertFalse(built, "an empty library address must stop the constructor");
    }

    /// @dev an external wrapper so `try` can catch a constructor revert of the artifact deploy
    function buildCore() external returns (ICore) {
        return Prod.newCore(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
    }

    function _allMin() internal pure returns (Settings memory m) {
        m.dropPerCreditBps = 1;
        m.dropFloorBps = 5_000;
        m.climbPerMinBps = 1;
        m.ceilBps = 10_000;
        m.idleLoosenBps = 1;
        m.saleFloorBps = 1_000;
        m.peakHalfLife = 600;
        m.recoveryClimbPerMinBps = 1;
        m.rateCap = uint64(RATE_START_MIN_WEI);
        m.buybackSlice = 0.01 ether;
        m.buybackDelay = 1;
        m.keeperMaxBaseFee = 1 gwei;
    }

    /// every field at the top of its bound, except feeToRedeemBurnBps which must leave room under the 10_000 fee sum
    function _allMax() internal pure returns (Settings memory m) {
        m = Settings(
            1_000, // dropPerCreditBps
            10_000, // dropFloorBps
            1_000, // climbPerMinBps
            30_000, // ceilBps
            2_000, // idleLoosenBps
            40_000, // saleFloorBps
            10_000, // saleToBuybackBps
            1_000, // recoveryClimbPerMinBps
            5_000, // recoveryGapBps
            604_800, // peakHalfLife
            7_200, // buybackDelay
            2, // exitMode
            1_000, // exitSlippageBps
            9_000, // exitBidMarginBps
            10_000, // redeemBurnBps
            1 ether, // buybackSlice
            0.005 ether, // keeperFee
            100 gwei, // keeperMaxBaseFee
            uint64(RATE_START_MAX_WEI), // rateCap
            0.005 ether, // callerFee
            100 gwei, // callerMaxBaseFee
            10_000, // feeToBuybackBps
            0 // feeToRedeemBurnBps (the sum with feeToBuybackBps is at most 10_000)
        );
    }

    /// the library is never usable directly, and the packed words round trip at both ends of every bound
    function test_libraryDirectCallsRevertAndPackingRoundTrips() public {
        address lib = findLibrary(address(core).code);
        (bool ok,) = lib.call(abi.encodeWithSelector(bytes4(keccak256("setSettings(Settings)")), _allMax()));
        assertFalse(ok, "setSettings direct");
        (ok,) = lib.call(
            abi.encodeWithSelector(
                ICoreLib.swapIn.selector, Mainnet.POOL_MANAGER, address(coin), uint24(0), int24(200), address(0), 1
            )
        );
        assertFalse(ok, "swapIn direct");
        assertEq(lib.code.length > 0, true);
        Settings[2] memory two = [_allMin(), _allMax()];
        for (uint256 i; i < 2; ++i) {
            _setSettings(two[i]);
            assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(two[i])), "round trip");
            // the three raw words hold exactly the values and nothing else
            bytes32 slot = 0xb5805f89ef62cd999f965a45fb6f4c11141caa04e5c4acba9c2552ef76902804;
            uint256 w0 = uint256(vm.load(address(core), slot));
            assertEq(w0 >> 248, 0, "slot 0 top bits clear");
            assertEq(uint16(w0 >> 80), two[i].saleFloorBps, "the sale floor sits at bits 80 to 95");
            assertEq(uint16(w0 >> 96), two[i].saleToBuybackBps, "the sale buyback share sits at bits 96 to 111");
            assertEq(uint32(w0 >> 144), two[i].peakHalfLife, "the peak half life sits at bits 144 to 175");
            assertEq(uint8(w0 >> 192), two[i].exitMode, "the exit mode sits at bits 192 to 199");
            assertEq(uint16(w0 >> 232), two[i].redeemBurnBps, "the redeem burn share sits at bits 232 to 247");
            uint256 w1 = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
            assertEq(w1 >> 240, 0, "slot 1 top bits clear");
            assertEq(uint128(w1), two[i].buybackSlice, "the buyback slice sits at bits 0 to 127");
            assertEq(uint64(w1 >> 128), two[i].keeperFee, "the keeper fee sits at bits 128 to 191");
            assertEq(uint48(w1 >> 192), two[i].keeperMaxBaseFee, "the keeper base fee ceiling sits at bits 192 to 239");
            uint256 w2 = uint256(vm.load(address(core), bytes32(uint256(slot) + 2)));
            assertEq(w2 >> 208, 0, "slot 2 top bits clear");
            assertEq(uint64(w2), two[i].rateCap, "the rate cap sits at bits 0 to 63");
            assertEq(uint64(w2 >> 64), two[i].callerFee, "the caller fee sits at bits 64 to 127");
            assertEq(uint48(w2 >> 128), two[i].callerMaxBaseFee, "the caller base fee ceiling sits at bits 128 to 175");
            assertEq(uint16(w2 >> 176), two[i].feeToBuybackBps, "the fee buyback share sits at bits 176 to 191");
            assertEq(uint16(w2 >> 192), two[i].feeToRedeemBurnBps, "the fee redeem burn share sits at bits 192 to 207");
        }
    }

    function _hostileMix() internal pure returns (Settings memory m) {
        m = _allMax();
        m.exitMode = 2;
        m.exitSlippageBps = 0;
        m.exitBidMarginBps = 0;
        m.saleFloorBps = 3_000;
    }

    /// no combination at either end of the bounds stops the hook from paying the core, whatever the gap
    function test_extremeSettingsNeverBrickReceive() public {
        _skipSniperWindow();
        Settings[3] memory three = [_allMin(), _allMax(), _hostileMix()];
        for (uint256 i; i < 3; ++i) {
            _setSettings(three[i]);
            for (uint256 g; g < 3; ++g) {
                vm.warp(block.timestamp + (g == 0 ? 1 hours : (g == 1 ? 40 days : 3_650 days)));
                uint256 pot = core.ethPot() + core.ethToBuyback();
                _buyCoin(funder, 2 ether);
                assertGt(core.ethPot() + core.ethToBuyback(), pot, "the hook's push was booked");
                core.ethRate();
                _solvent();
            }
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForEth(ids) {} catch {}
        }
    }

    /// the exit side at the extremes of the bounds: the bid pot stays backed and no setting stops a redemption or a bid
    function test_extremeSettingsPhase2() public {
        _skipSniperWindow();
        _enterPhase2();
        _fillExitBuyback();
        assertGt(core.xPot(), 0);
        Settings[3] memory three = [_allMin(), _allMax(), _hostileMix()];
        for (uint256 i; i < 3; ++i) {
            // _allMin and _allMax leave exitMode 0 or 2; force the bid on so the extremes exercise it
            Settings memory s = three[i];
            s.exitMode = 2;
            _setSettings(s);
            vm.warp(block.timestamp + (i == 0 ? 1 hours : 100 days));
            core.skim();
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForExitToken(ids) {} catch {}
            _solvent();
        }
    }

    function _idle(uint256 potEth) internal returns (uint256 hrs, uint256 price, uint256 pot) {
        _skipSniperWindow();
        _fundPot(potEth);
        pot = core.ethPot();
        uint256[] memory ids = _credits(seller, 1);
        uint256 last;
        for (; hrs < 24 * 40; ++hrs) {
            price = core.ethRate();
            if (price == last) break;
            last = price;
            vm.warp(block.timestamp + 1 hours);
        }
        // a single seller takes one credit at the clamp
        uint256 b = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        price = seller.balance - b;
    }

    /// FC-5 (fixed with the `rateCap` setting): flat mode, no seller at all. the limit climbs only up to the rate cap,
    /// so what one seller can take stays at the cap price however long the market is dead
    function test_FIXED_idleClimbStopsAtTheRateCap() public {
        uint256[3] memory pots = [uint256(1 ether), 5 ether, 20 ether];
        uint256 capPrice = uint256(core.settings().rateCap);
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 hrs, uint256 took, uint256 pot) = _idle(pots[i]);
            emit log_named_uint("pot (wei)", pot);
            emit log_named_uint("hours until the limit stops climbing", hrs);
            emit log_named_uint("one seller took (wei)", took);
            emit log_named_uint("cap price of one credit (wei)", capPrice);
            assertEq(core.ethRate() <= core.settings().rateCap, true, "the rate never passes the cap");
            assertLe(took, capPrice, "one credit never pays more than the cap price");
            assertLe(took, pot, "never above the pot");
            vm.revertToState(snap);
        }
    }

    /// the rate cap is a hard ceiling: setRate refuses above it, the cap is bounded like the rate, a lower cap pulls
    /// the rate down at the checkpoint, and a higher cap lets the climb go on
    function test_FIXED_rateCapIsAHardCeiling() public {
        // a pot of 100 eth leaves the clamp above every rate in this test
        vm.deal(address(core), address(core).balance + 100 ether);
        core.skim();
        Settings memory s = core.settings();
        assertEq(s.rateCap, 26_700_000_000_000_000, "launch value");
        vm.prank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(uint256(s.rateCap) + 1);
        vm.prank(owner);
        core.setRate(s.rateCap);
        assertEq(core.ethRate(), s.rateCap);
        // bounds of the cap itself
        s.rateCap = uint64(RATE_START_MIN_WEI - 1);
        _expectBad(s, "rateCap");
        s.rateCap = uint64(RATE_START_MAX_WEI + 1);
        _expectBad(s, "rateCap");
        // lowering the cap below the live rate pulls the rate down to it
        s.rateCap = 5e13;
        _setSettings(s);
        assertEq(core.ethRate(), 5e13, "the rate follows the cap down");
        // the next checkpoint stores the bounded rate
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        assertEq(core.rateAtCheckpoint(), 5e13);
        // a rate cap above the rate does not touch the rate
        s.rateCap = 2e14;
        _setSettings(s);
        assertEq(core.ethRate(), 5e13);
        vm.prank(owner);
        core.setRate(2e14);
        assertEq(core.ethRate(), 2e14);
    }

    /// the climb clamps at the cap even with a large pot
    function test_FIXED_climbClampsAtTheRateCap() public {
        _skipSniperWindow();
        _fundPot(50 ether);
        _warp(60 days);
        assertEq(core.ethRate(), core.settings().rateCap, "clamped by the cap, not by the pot");
        Settings memory s = core.settings();
        s.rateCap = 2 * s.rateCap;
        _setSettings(s);
        _warp(60 days);
        assertEq(core.ethRate(), s.rateCap, "a higher cap lets the climb continue to it");
    }

    /// FC-3 (fixed by bounds, tightened by V2R-2): the buyback slice tops out at 1 eth. a sandwich around a slice at the
    /// cap loses money for the attacker after both skims at the 6.9 point v2 skim, for every front run size tried
    /// (the 100 eth slice that paid 46 eth is not reachable, and a 3 eth slice already profited)
    function test_FIXED_buybackSliceCapStopsTheSandwich() public {
        _skipSniperWindow();
        Settings memory big = core.settings();
        big.buybackSlice = 1 ether + 1;
        _expectBad(big, "buybackSlice");
        uint256[2] memory slices = [uint256(0.5 ether), 1 ether];
        uint256[6] memory mult = [uint256(1), 2, 3, 4, 6, 8];
        for (uint256 i; i < 2; ++i) {
            for (uint256 k; k < 6; ++k) {
                uint256 snap = vm.snapshotState();
                vm.deal(address(core), address(core).balance + slices[i]);
                vm.store(address(core), bytes32(uint256(7)), bytes32(slices[i]));
                Settings memory s = core.settings();
                s.buybackSlice = uint128(slices[i]);
                s.buybackDelay = 1;
                _setSettings(s);
                vm.roll(block.number + 100);
                address mev = _user("mev");
                uint256 front = slices[i] * mult[k];
                uint256 got = _buyCoin(mev, front);
                vm.prank(keeper);
                core.buyback();
                uint256 back = _sellCoin(mev, got);
                emit log_named_uint("slice", slices[i]);
                emit log_named_uint("front run", front);
                emit log_named_int("attacker net (wei)", int256(back) - int256(front));
                assertLt(back, front, "the sandwich loses money at or below the cap");
                vm.revertToState(snap);
            }
        }
    }

    /// a word with bits above the field width is refused by the library, never truncated into bounds
    function test_dirtyCalldataWordsAreRefused() public {
        Settings memory base = core.settings();
        bytes memory good = abi.encodeCall(ICore.setSettings, (base));
        assertEq(good.length, 4 + 23 * 32);
        for (uint256 i; i < 23; ++i) {
            bytes memory bad = bytes.concat(good);
            uint256 off = 32 + 4 + i * 32;
            uint256 w;
            assembly ("memory-safe") {
                w := mload(add(bad, off))
            }
            // a 1 far above any field width keeps the low bits equal to the live (in bounds) value
            uint256 dirty = w | (uint256(1) << 200);
            assembly ("memory-safe") {
                mstore(add(bad, off), dirty)
            }
            vm.prank(owner);
            (bool ok,) = address(core).call(bad);
            assertFalse(ok, "dirty word accepted");
        }
        // the clean call works, and extra trailing bytes are ignored
        vm.prank(owner);
        (bool ok2,) = address(core).call(bytes.concat(good, hex"deadbeef"));
        assertTrue(ok2);
        // not the owner
        (bool ok3,) = address(core).call(good);
        assertFalse(ok3);
    }

    /// gas of the hook's push into receive() after idle gaps, at launch settings and at the fastest climb and loosening
    function test_receiveGasByGap() public {
        _skipSniperWindow();
        _fundPot(5 ether);
        address hook = core.FEE_SOURCE();
        uint256[4] memory gaps = [uint256(1 hours), 5 days, 400 days, 36_500 days];
        for (uint256 j; j < 2; ++j) {
            if (j == 1) {
                Settings memory s = core.settings();
                s.climbPerMinBps = 1_000;
                s.recoveryClimbPerMinBps = 1_000;
                s.idleLoosenBps = 2_000;
                s.ceilBps = 30_000;
                _setSettings(s);
            }
            for (uint256 i; i < 4; ++i) {
                uint256 snap = vm.snapshotState();
                vm.warp(block.timestamp + gaps[i]);
                vm.deal(hook, 1 ether);
                vm.prank(hook);
                uint256 g = gasleft();
                (bool ok,) = address(core).call{value: 0.01 ether}("");
                g -= gasleft();
                assertTrue(ok);
                emit log_named_uint(j == 0 ? "launch settings, gap" : "fastest climb and loosening, gap", gaps[i]);
                emit log_named_uint("gas", g);
                vm.revertToState(snap);
            }
        }
    }

    /// the real cost of ControllerV1.nextPage for a full page, which sizes the fixed gas cap of the core's read
    function test_measure_controllerV1PageGas() public {
        _fillEthPile(80);
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage();
        uint256 used = g - gasleft();
        assertTrue(ready);
        emit log_named_uint("ControllerV1.nextPage gas, full page, cold", used);
        // the core's read of nextPage is capped at 500,000 gas (PAGE_GAS). the first read of a full page in a transaction
        // costs about 242,000 gas (cold storage), so the cap is at least twice the cold cost of a full page
        assertLt(used * 2, 500_000, "the gas cap of the core's read is at least twice the cold read of a full page");
        g = gasleft();
        ctl.nextPage();
        emit log_named_uint("ControllerV1.nextPage gas, full page, warm", g - gasleft());
    }

    /// FC-4 (fixed): the read of the controller's `nextPage` is cut at `PAGE_GAS` (500,000). a controller that burns
    /// gas there makes the compose revert `NotReady` and the gas of the call stays bounded by the cut
    function test_FIXED_gasBurningControllerCannotFarmTheComposeReimbursement() public {
        _skipSniperWindow();
        _fundPot(3 ether);
        _fillEthPile(80);
        assertEq(core.pileSize(), 80);

        // 20M gas of burning is far past the cut: the read fails and the page is not ready
        BurnController bc = new BurnController(address(core), 20_000_000);
        _setController(address(bc));
        vm.fee(20 gwei);
        vm.prank(keeper);
        uint256 g = gasleft();
        vm.expectRevert(ICore.NotReady.selector);
        core.compose{gas: 30_000_000}();
        g -= gasleft();
        assertLt(g, 1_000_000, "the read is cut at 500,000 and the rest of the call is small");

        // burning 200,000 is answered: with the cold page read of about 242,000 gas it stays under the cut
        bc = new BurnController(address(core), 200_000);
        _setController(address(bc));
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose{gas: 30_000_000}();
        assertEq(STATEMENTS.supply(), supply + 1, "the page under the cut composes");
    }

    /// held: the exit bid at a zero margin pays exactly what the module pays back for the same credits, so selling
    /// credits for exit token and exiting them leaves the exit pot whole
    function test_exitBidAtParIsAWash() public {
        _skipSniperWindow();
        _enterPhase2();
        _setExitPool();
        _fundPot(3 ether);
        Settings memory s = core.settings();
        s.exitBidMarginBps = 0;
        // slippage at or below the bid margin: a zero margin needs zero slippage
        s.exitSlippageBps = 0;
        _setSettings(s);
        xt.mint(address(core), 1e22);
        core.skim();
        uint256 xBefore = core.xPot();
        uint256[] memory ids = _credits(seller, 80);
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 paid = xBefore - core.xPot();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _makeEligible(sid);
        core.exitStatement(sid);
        emit log_named_uint("paid to the seller (exit token)", paid);
        emit log_named_uint("exit pot before", xBefore);
        emit log_named_uint("exit pot after the exit", core.xPot());
        assertEq(core.xPot(), xBefore, "the pot is whole");
    }
}

/// a controller that answers like ControllerV1 but burns gas first (a staticcall can do that and nothing else)
contract BurnController {
    ICore internal immutable CORE;
    uint256 internal immutable BURN;

    constructor(address core_, uint256 burn_) {
        CORE = ICore(payable(core_));
        BURN = burn_;
    }

    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        uint256 stop = gasleft() - BURN;
        uint256 h;
        while (gasleft() > stop) {
            h = uint256(keccak256(abi.encode(h)));
        }
        if (h == 1) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(0, 80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }

    function atFloor(uint256) external pure returns (bool) {
        return false;
    }
}
