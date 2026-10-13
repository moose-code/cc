// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// decision 113: statement formats. `compose()` derives the format from `prevrandao` and the first page id,
/// `compose(format)` takes it from the caller, and `setHeldFormat` restyles a held statement for a holder of at least
/// `minCcToChoose` coin. the format is read back from the live Statements contract
contract FormatsTest is Fixture {
    address internal holder;

    function setUp() public override {
        super.setUp();
        holder = _user("holder");
    }

    /// composes the oldest 80 pile credits through `compose()` and returns the new statement id
    function _composeDefault() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
    }

    /// a held statement and a holder of more than `minCcToChoose` coin
    function _heldAndFunded() internal returns (uint256 sid) {
        _fillEthPile(80);
        sid = _composeDefault();
        assertEq(core.minCcToChoose(), 1e18, "the launch minimum is 1 coin");
        _buyCoin(holder, 0.5 ether);
        assertGe(coin.balanceOf(holder), 1e18, "the holder holds at least 1 coin");
    }

    // ------------------------------------------------------------------ compose

    function test_compose_defaultFormatFollowsPrevrandaoAndHeadId() public {
        _fillEthPile(80);
        uint256 head = core.pilePage(0, 1)[0];
        uint256 snap = vm.snapshotState();
        uint256 sid = STATEMENTS.supply() + 1;
        bytes32[3] memory seeds = [bytes32(uint256(1)), bytes32(uint256(2)), keccak256("formats")];
        for (uint256 i; i < seeds.length; ++i) {
            vm.prevrandao(seeds[i]);
            uint8 want = defaultFormat(head);
            assertLt(want, 8, "inside 0 to 7");
            _composeDefault();
            assertEq(STATEMENTS.formatOf(sid), want, "the format is the keccak of prevrandao and the head id, mod 8");
            vm.revertToState(snap);
        }
    }

    function test_compose_defaultFormatIsDeterministic() public {
        _fillEthPile(80);
        uint256 snap = vm.snapshotState();
        uint256 sid = STATEMENTS.supply() + 1;
        vm.prevrandao(bytes32(uint256(77)));
        _composeDefault();
        uint8 first = STATEMENTS.formatOf(sid);
        vm.revertToState(snap);
        vm.prevrandao(bytes32(uint256(77)));
        _composeDefault();
        assertEq(STATEMENTS.formatOf(sid), first, "same prevrandao and head, same format");
    }

    function test_compose_defaultFormatReachesMoreThanOneValue() public {
        _fillEthPile(80);
        uint256 head = core.pilePage(0, 1)[0];
        bool[8] memory seen;
        uint256 distinct;
        for (uint256 i = 1; i <= 64; ++i) {
            vm.prevrandao(bytes32(i));
            uint8 f = defaultFormat(head);
            if (!seen[f]) {
                seen[f] = true;
                distinct++;
            }
        }
        assertGt(distinct, 4, "the derivation spreads over the formats");
    }

    function test_compose_givenFormat() public {
        _fillEthPile(80);
        uint256 snap = vm.snapshotState();
        uint256 sid = STATEMENTS.supply() + 1;
        for (uint8 f; f <= 7; f += 5) {
            vm.fee(composeBasefee);
            vm.prank(keeper);
            core.compose(f);
            assertEq(STATEMENTS.formatOf(sid), f, "the given format");
            assertTrue(_isHeld(sid), "held");
            assertEq(core.composerOf(sid), keeper, "composer");
            vm.revertToState(snap);
        }
    }

    function test_REVERT_compose_badFormat() public {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.expectRevert(ICore.BadFormat.selector);
        vm.prank(keeper);
        core.compose(8);
    }

    function test_REVERT_compose_givenFormatNotReady() public {
        vm.expectRevert(ICore.NotReady.selector);
        vm.prank(keeper);
        core.compose(3);
    }

    // ------------------------------------------------------------------ setHeldFormat

    function test_setHeldFormat_holderSetsAndReadsBack() public {
        uint256 sid = _heldAndFunded();
        for (uint8 f; f <= 7; ++f) {
            vm.expectEmit(address(core));
            emit ICore.HeldFormatSet(sid, f, holder);
            vm.prank(holder);
            core.setHeldFormat(sid, f);
            assertEq(STATEMENTS.formatOf(sid), f, "formatOf reads back");
        }
        assertTrue(_isHeld(sid), "the statement is still held");
        assertEq(STATEMENTS.ownerOf(sid), address(core), "and still owned by the core");
    }

    function test_setHeldFormat_oneCoinPasses() public {
        uint256 sid = _heldAndFunded();
        uint256 bal = coin.balanceOf(holder);
        vm.prank(owner);
        core.setMinCcToChoose(uint96(bal));
        vm.prank(holder);
        core.setHeldFormat(sid, 6);
        assertEq(STATEMENTS.formatOf(sid), 6, "a balance equal to the minimum passes");
    }

    function test_REVERT_setHeldFormat_belowMinCc() public {
        uint256 sid = _heldAndFunded();
        uint256 before = STATEMENTS.formatOf(sid);
        uint96 above = uint96(coin.balanceOf(holder) + 1);
        vm.prank(owner);
        core.setMinCcToChoose(above);
        uint8 other = before == 2 ? 3 : 2;
        vm.expectRevert(ICore.BelowMinCc.selector);
        vm.prank(holder);
        core.setHeldFormat(sid, other);
        assertEq(STATEMENTS.formatOf(sid), before, "unchanged");
    }

    function test_REVERT_setHeldFormat_noCoin() public {
        _fillEthPile(80);
        uint256 sid = _composeDefault();
        address nobody = _user("nobody");
        vm.expectRevert(ICore.BelowMinCc.selector);
        vm.prank(nobody);
        core.setHeldFormat(sid, 1);
    }

    function test_REVERT_setHeldFormat_soldStatement() public {
        uint256 sid = _heldAndFunded();
        _buy(holder, sid);
        assertFalse(_isHeld(sid), "sold");
        vm.expectRevert(ICore.NotForSale.selector);
        vm.prank(holder);
        core.setHeldFormat(sid, 1);
    }

    function test_REVERT_setHeldFormat_neverComposed() public {
        _buyCoin(holder, 0.5 ether);
        uint256 next = STATEMENTS.supply() + 1;
        vm.expectRevert(ICore.NotForSale.selector);
        vm.prank(holder);
        core.setHeldFormat(next, 1);
    }

    function test_REVERT_setHeldFormat_badFormat() public {
        uint256 sid = _heldAndFunded();
        vm.expectRevert(ICore.BadFormat.selector);
        vm.prank(holder);
        core.setHeldFormat(sid, 8);
    }

    function test_setHeldFormat_zeroMinimumOpensItToAnyone() public {
        _fillEthPile(80);
        uint256 sid = _composeDefault();
        vm.prank(owner);
        core.setMinCcToChoose(0);
        address nobody = _user("nobody");
        vm.prank(nobody);
        core.setHeldFormat(sid, 4);
        assertEq(STATEMENTS.formatOf(sid), 4, "no coin needed at a zero minimum");
    }
}
