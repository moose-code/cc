// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";

/// @notice the inventory gate is gone (docs/FLOW.md decision 2): the engine never stops buying because statements are
/// unsold. what is left of its suite is the rate property that never depended on the gate (the rate does not rise
/// across an interval that was unfunded at its start) under a random walk over the doors, the clock, the fees, the
/// statement sales and the settings, and a proof that held and unsold statements change nothing about the bid
contract GateTest is Fixture {
    using FixedPointMathLib for uint256;

    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), sid);
    }

    function _sellOne() internal {
        uint256[] memory ids = _credits(seller, 1);
        _fundPot(core.ethPot() + 0.2 ether);
        vm.prank(seller);
        core.sellForEth(ids);
    }

    /// two statements sit unsold in the core and nothing closes: the bid is open, the climb runs on from the dropped
    /// rate after a fill, a statement sale changes none of it, and the pot is never gated on inventory
    function test_unsoldStatementsNeverStopTheBidOrTheClimb() public {
        _skipSniperWindow();
        _liftRateCap();
        uint256 s1 = _composeNext();
        uint256 s2 = _composeNext();
        assertEq(core.heldStatements().length, 2);
        assertTrue(_isHeld(s1));
        assertTrue(_isHeld(s2));
        // the bid is open at two held statements, however long they sit
        _warp(30 days);
        _sellOne();
        assertEq(core.heldStatements().length, 2, "still unsold");
        // the climb is clamped by the pot, so give the pot room for ten more minutes of it. a v2 buy
        // lands about 5.87 points in the pot, not the 9.5 of v1, so the one sale above left less of it
        _fundPot(core.ethPot() + 5 ether);
        uint256 r0 = core.rateAtCheckpoint();
        uint256 t0 = core.checkpointTime();
        _warp(10 minutes);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 want =
            r0.mulWad(uint256(FixedPointMathLib.powWad(1.005e18, int256((block.timestamp - t0) * 1e18 / 1 minutes))));
        // the read is the climb, lowered to the clamp: the price of one credit that the pot affords
        uint256 clamp = core.ethPot();
        if (want > clamp) want = clamp;
        // the 30 day gap lifts the ceiling (20 percent per 10 idle minutes) to the rate cap, which bounds the read too
        uint256 cap = core.settings().rateCap;
        if (want > cap) want = cap;
        assertApproxEqRel(core.ethRate(), want, 1e12, "0.5 percent a minute right after a fill, ten minutes");
        assertGt(core.ethRate(), 0, "the bid is open");
        // one of them sells through the controller: nothing about the bid changes, and the other keeps waiting
        uint256 rateBefore = core.ethRate();
        _buy(funder, s1);
        assertGe(
            core.ethRate(), rateBefore, "booking the proceeds raises the pot and so the clamp, never the price state"
        );
        _sellOne();
        assertTrue(_isHeld(s2));
        _solvent();
    }
}

/// @notice a random walk over the doors, the clock, the fees, the statement sales and the owner's settings. every
/// step checks that the rate never rose across an interval that was unfunded at its start, and that the books stay
/// solvent
contract GateFuzzTest is Fixture {
    function setUp() public override {
        super.setUp();
        _skipSniperWindow();
        _fillEthPile(80);
    }

    function _settingsWalk(uint256 seed) internal {
        Settings memory s = core.settings();
        uint256 pick = seed >> 8;
        // forge-lint: disable-start(unsafe-typecast)
        if (pick % 2 == 0) {
            s.dropPerCreditBps = uint16(1 + (seed >> 16) % 1_000);
            s.dropFloorBps = uint16(5_000 + (seed >> 32) % 5_001);
        } else {
            s.climbPerMinBps = uint16(1 + (seed >> 16) % 1_000);
            s.ceilBps = uint16(10_000 + (seed >> 32) % 20_001);
            s.idleLoosenBps = uint16(1 + (seed >> 48) % 2_000);
            if (s.climbPerMinBps > s.recoveryClimbPerMinBps) s.recoveryClimbPerMinBps = s.climbPerMinBps;
        }
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    function _sellAStatement(uint256 seed) internal {
        uint256[] memory h = core.heldStatements();
        if (h.length == 0) return;
        _buy(funder, h[(seed >> 8) % h.length]);
    }

    function _try(uint256 op, uint256 seed) internal {
        if (op == 3) {
            _buyCoin(funder, 0.05 ether + seed % 0.5 ether);
        } else if (op == 4) {
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForEth(ids) {} catch {}
        } else if (op == 5) {
            vm.fee(composeBasefee);
            vm.prank(keeper);
            try core.compose() {} catch {}
        } else if (op == 6) {
            _sellAStatement(seed);
        } else if (op == 7) {
            vm.deal(funder, funder.balance + 0.02 ether);
            vm.prank(funder);
            (bool ok,) = address(core).call{value: 0.02 ether}("");
            assertTrue(ok);
            core.skim();
        } else {
            _settingsWalk(seed);
        }
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_priceStateNeverRisesAcrossAnIntervalUnderTheClamp(uint256 seed) public {
        for (uint256 i; i < 14; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 9;
            uint256 r0 = core.rateAtCheckpoint();
            bool starved = core.ethPot() < r0;
            if (op < 3) _warp(bound(seed >> 8, 1 minutes, 3 days));
            else _try(op, seed);
            if (starved) {
                assertLe(core.rateAtCheckpoint(), r0, "the price state rose across an interval that began under the clamp");
            }
            _solvent();
        }
    }
}
