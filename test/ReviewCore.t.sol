// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";

/// regressions and attack tests for REVIEW-core.md (git history before packet 0), on the real stack. the balance token buyback is the dutch
/// auction inside the core (unchanged by the flow rework, its half life and slice are settings now), so its attacks
/// are written against that: nobody gets balance token for less coin than the
/// quote, nothing but the clock lowers the price, a fill never takes more than `xToBuyback`, and every fill restarts
/// the price at max(2 * clearing, previous start / 4)
contract ReviewCoreTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal rseller;
    address internal taker;
    address internal attacker;

    function setUp() public virtual override {
        super.setUp();
        rseller = _user("rseller");
        taker = _user("taker");
        attacker = _user("attacker");
    }

    // ------------------------------------------------------------------ R3 unitPerPoint is read live

    /// R3: the core reads the unit from the module in each redemption. a module that lowers its unit is redeemed at the
    /// unit it reports, and a payout below that unit's minimum still reverts and leaves the statement
    /// accepted: docs/SPEC.md section 14 item 29. the owner's module decides the unit; a dust module is the owner's own door
    function test_ACCEPTED_loweredUnitSetsTheMinimumOfTheRedemption() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);

        uint256 rating = core.ratingOf(c.sid);
        mod.setUnitPerPoint(1);
        mod.setPayBps(10_000 - core.settings().redeemSlippageBps - 1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left");
        assertTrue(_isHeld(c.sid));
        mod.setPayBps(10_000);
        core.redeemStatement(c.sid);
        assertEq(xt.balanceOf(address(core)), rating * 1, "paid by the unit the module reports");
        _solvent();
    }

    /// R3: the bid pays by the unit the module reports now
    /// accepted: docs/SPEC.md section 14 item 29. the owner's module decides the unit; an overpaying module is the owner's own door
    function test_ACCEPTED_raisedUnitRaisesTheBid() public {
        _enterPhase2();
        _setBalancePool();
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        core.redeemStatement(c.sid);
        uint256 pot = core.balancePot();
        assertGt(pot, 0);

        uint256[] memory ids = _credits(rseller, 1);
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(ids[0]), CREDITS.timestampOf(ids[0]));
        uint256 live = score * UNIT * 100 * (10_000 - core.settings().balanceBidMarginBps) / 10_000;
        mod.setUnitPerPoint(UNIT * 100);
        vm.prank(rseller);
        core.sellForBalance(ids);

        assertEq(xt.balanceOf(rseller), live, "paid by the live unit");
        _solvent();
    }

    /// the core approved Statements for all its credits. a third party cannot use that approval.
    function test_held_thirdPartyCannotComposeCoreCredits() public {
        _fillEthPile(80);
        uint256[80] memory ids;
        uint256[] memory page = core.pilePage(0, 80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.startPrank(attacker);
        vm.expectRevert();
        STATEMENTS.compose(ids, 0);
        (bool ok,) = address(STATEMENTS)
            .call(abi.encodeWithSignature("compose(uint256[80],uint8,address)", ids, uint8(0), attacker));
        assertFalse(ok, "the three argument compose pulled core credits");
        vm.stopPrank();
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    /// ten years without a checkpoint, funded. the climb stops at the funded threshold and the read is cheap.
    function test_held_tenYearGapRateRead() public {
        _skipSniperWindow();
        _fundPot(5 ether);
        uint256 pot = core.ethPot();
        vm.warp(block.timestamp + 3650 days);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        g -= gasleft();
        uint256 clamp = pot;
        uint256 cap = core.settings().rateCap;
        assertEq(r, clamp < cap ? clamp : cap, "clamped at the clamp or the rate cap");
        assertLt(g, 400_000, "gas of the read");
        emit log_named_uint("gas of a ten year read", g);
        // a checkpointing call after the gap still works
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        core.skim();
        assertEq(core.ethPot(), pot + 1 ether);
    }
}
