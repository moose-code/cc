// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// `State` in src/lib/CoreLib.sol holds every field of the Core, which declares it once at slot 0, and the library reads
/// the same struct. every field with a public getter is compared with the raw storage word of its slot, the pile, the
/// mappings and the held list by the slot arithmetic the compiler uses. the pile is a
/// `Pile` struct stored inline (head, tail, size at slots 13, 14, 15), so the mappings and the held list follow it
contract CoreLayoutTest is Fixture {
    uint256 internal constant S_PILE = 12;
    uint256 internal constant S_CREDITS = 15;
    uint256 internal constant S_STATEMENTS = 16;
    uint256 internal constant S_HELD = 17;
    uint256 internal constant S_COMPOSER = 20;

    /// the bytes `[offset, offset + size)` of storage slot `slot` of the core
    function _field(uint256 slot, uint256 offset, uint256 size) internal view returns (uint256) {
        uint256 word = uint256(vm.load(address(core), bytes32(slot)));
        if (size == 32) return word;
        return (word >> (offset * 8)) & ((1 << (size * 8)) - 1);
    }

    function _mapSlot(uint256 key, uint256 base) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, base)));
    }

    // promise: SPEC 1 the Core state is one State struct at slot 0
    function test_OK_scalarFieldsSitWhereTheMirrorSays() public {
        MigrationSink sink = new MigrationSink();
        _enterPhase2();
        _fundPot(3 ether);
        uint256[] memory sold = _credits(seller, 3);
        vm.prank(seller);
        core.sellForEth(sold);
        // the reserve holds fee eth, so its word is compared nonzero
        vm.store(address(core), bytes32(uint256(8)), bytes32(uint256(1 ether)));
        vm.startPrank(owner);
        core.addAdapter(address(0xA110C));
        vm.stopPrank();
        assertTrue(core.allowedAdapter(address(0xA110C)), "setup: the adapter is approved");
        assertEq(
            uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110C), uint256(3))))), 1, "allowedAdapter"
        );
        assertEq(
            uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110D), uint256(3))))), 0, "unset adapter"
        );
        vm.prank(owner);
        core.transferOwnership(address(0xBEEF));
        vm.startPrank(owner);
        core.lockController();
        core.lockBalanceModule();
        core.lockAdapters();
        core.setSuccessor(address(sink));
        core.lockSuccessor();
        vm.stopPrank();

        assertEq(_field(0, 0, 20), uint256(uint160(core.controller())), "controller");
        assertEq(_field(0, 20, 1), core.controllerLocked() ? 1 : 0, "controllerLocked");
        assertEq(_field(0, 21, 1), core.balanceModuleLocked() ? 1 : 0, "balanceModuleLocked");
        assertEq(_field(0, 22, 1), core.adaptersLocked() ? 1 : 0, "adaptersLocked");
        assertEq(_field(1, 0, 20), uint256(uint160(core.balanceModule())), "balanceModule");
        assertEq(_field(2, 0, 20), uint256(uint160(core.balanceToken())), "balanceToken");
        assertEq(_field(4, 0, 20), uint256(uint160(core.owner())), "owner");
        assertEq(_field(5, 0, 20), uint256(uint160(core.pendingOwner())), "pendingOwner");
        assertEq(_field(6, 0, 32), core.ethPot(), "ethPot");
        assertEq(_field(7, 0, 32), core.ethToBuyback(), "ethToBuyback");
        assertEq(_field(8, 0, 32), core.ethRedeemBurn(), "ethRedeemBurn");
        assertEq(core.ethRedeemBurn(), 1 ether, "ethRedeemBurn value");
        // balancePot is gone (the module holds the balance token), so rateAtCheckpoint moves up to slot 9
        assertEq(_field(9, 0, 32), core.rateAtCheckpoint(), "rateAtCheckpoint");
        assertEq(_field(10, 0, 8), core.checkpointTime(), "checkpointTime");
        assertEq(_field(10, 8, 8), core.lastFillTime(), "lastFillTime");
        assertEq(_field(11, 0, 32), core.lastBuybackBlock(), "lastBuybackBlock");
        assertEq(_field(18, 0, 20), uint256(uint160(core.successor())), "successor");
        assertEq(_field(18, 20, 1), core.successorLocked() ? 1 : 0, "successorLocked");
        assertEq(core.successor(), address(sink), "successor value");
        assertTrue(core.successorLocked(), "successorLocked value");
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.adaptersLocked(), "locks");
        // the standalone settings pack after retired: creditCostToPotBps and chosenComposeOn finish slot 18 (offsets
        // 22 and 24), minCcToChoose (uint96, 12 bytes) cannot straddle so it starts slot 19
        vm.startPrank(owner);
        core.setCreditCostToPotBps(6_000);
        core.setChosenComposeOn(true);
        core.setMinCcToChoose(123);
        vm.stopPrank();
        assertEq(_field(18, 22, 2), core.creditCostToPotBps(), "creditCostToPotBps");
        assertEq(_field(18, 22, 2), 6_000, "creditCostToPotBps value");
        assertEq(_field(18, 24, 1), core.chosenComposeOn() ? 1 : 0, "chosenComposeOn");
        assertEq(_field(19, 0, 12), core.minCcToChoose(), "minCcToChoose");
        assertEq(core.minCcToChoose(), 123, "minCcToChoose value");
        // the pause clock follows minCcToChoose in slot 19: paused (1 byte), pausedSince and pausedTotal (5 bytes each)
        vm.prank(owner);
        core.setPaused(true);
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 777);
        assertEq(_field(19, 12, 1), 1, "paused");
        assertEq(_field(19, 13, 5), pausedAt, "pausedSince");
        assertEq(_field(19, 13, 5), core.pausedSince(), "pausedSince getter");
        assertEq(_field(19, 18, 5), 0, "pausedTotal while the first pause is open");
        vm.prank(owner);
        core.setPaused(false);
        assertEq(_field(19, 12, 1), 0, "resumed");
        assertEq(_field(19, 13, 5), 0, "pausedSince is cleared");
        assertEq(_field(19, 18, 5), 777, "pausedTotal");
        assertEq(_field(19, 18, 5), core.pausedTotal(), "pausedTotal getter");
        assertEq(_field(19, 12, 1), core.paused() ? 1 : 0, "paused getter");
        // composerOf is a mapping and takes slot 20. payee (20 bytes) starts slot 21, artist (20 bytes) slot 22 with
        // payeeOn (1 byte) packed at offset 20 of slot 22
        assertEq(_field(21, 0, 20), uint256(uint160(core.payee())), "payee");
        assertEq(core.payee(), lc.payee, "payee value");
        assertEq(_field(22, 0, 20), uint256(uint160(core.artist())), "artist");
        assertEq(core.artist(), lc.artist, "artist value");
        assertEq(_field(22, 20, 1), core.payeeOn() ? 1 : 0, "payeeOn");
        // the first migrate sets retired. the call moves the pots, so it comes after the pot words are compared
        assertEq(_field(18, 21, 1), 0, "retired is false before a migrate");
        assertFalse(core.retired(), "retired value before");
        vm.prank(owner);
        core.migrate(0);
        assertEq(_field(18, 21, 1), 1, "retired");
        assertTrue(core.retired(), "retired value");
    }

    // promise: SPEC 1 the balance bid instance is appended after the eth anchor
    /// `State.balance` (the balance bid Rate) follows `anchor` (slots 28 to 31): rateAtCheckpoint at 32,
    /// checkpointTime and lastFillTime packed at 33, its anchor (lastFillRate, minuteStartRate, minuteBucket and
    /// peakTime, peakRate) at 34 to 37. at launch the instance is reset to the floor 10_000 - balanceBidMarginBps, which
    /// the stored rate keeps until a balance fill or a margin change
    function test_OK_balanceInstanceSitsAfterTheAnchor() public view {
        uint256 floor = 10_000 - core.settings().balanceBidMarginBps;
        assertEq(_field(32, 0, 32), floor, "balance.rateAtCheckpoint is the floor at launch");
        assertEq(_field(34, 0, 32), floor, "balance.anchor.lastFillRate is the floor");
        assertEq(_field(35, 0, 32), floor, "balance.anchor.minuteStartRate is the floor");
        assertEq(_field(37, 0, 32), floor, "balance.anchor.peakRate is the floor");
    }

    // promise: SPEC 1 the Core state is one State struct at slot 0
    function test_OK_pilesCreditsAndStatementsSitWhereTheMirrorSays() public {
        uint256[] memory ids = _fillEthPile(5);
        // pile: head, tail, size inline at slots 13, 14, 15
        assertEq(uint256(vm.load(address(core), bytes32(S_PILE))), core.pilePage(0, 1)[0], "pile head");
        assertEq(uint256(vm.load(address(core), bytes32(S_PILE + 1))), ids[4], "pile tail");
        assertEq(uint256(vm.load(address(core), bytes32(S_PILE + 2))), core.pileSize(), "pile size");
        // credit: cost, prev, next, then acquiredAt | inPile
        for (uint256 i; i < 5; ++i) {
            uint256 base = _mapSlot(ids[i], S_CREDITS);
            (bool inPile, uint256 cost, uint64 at) = core.creditInfo(ids[i]);
            assertEq(uint256(vm.load(address(core), bytes32(base))), cost, "credit cost");
            assertEq(uint256(vm.load(address(core), bytes32(base + 1))), i == 0 ? 0 : ids[i - 1], "credit prev");
            assertEq(uint256(vm.load(address(core), bytes32(base + 2))), i == 4 ? 0 : ids[i + 1], "credit next");
            uint256 word = uint256(vm.load(address(core), bytes32(base + 3)));
            assertEq(word & type(uint64).max, at, "credit acquiredAt");
            assertEq((word >> 64) & 0xff, inPile ? 1 : 0, "credit inPile");
        }
        // statement: cost, then composedAt | slot | rating | held | pauseMark; the held list at S_HELD. a pause of 100
        // seconds before the compose gives the record a nonzero pauseMark
        vm.prank(owner);
        core.setPaused(true);
        vm.warp(block.timestamp + 100);
        vm.prank(owner);
        core.setPaused(false);
        Composed memory c = _composeOnce();
        (bool held, uint256 cost, uint64 composedAt) = core.statementInfo(c.sid);
        uint256 sbase = _mapSlot(c.sid, S_STATEMENTS);
        assertEq(uint256(vm.load(address(core), bytes32(sbase))), cost, "statement cost");
        uint256 sword = uint256(vm.load(address(core), bytes32(sbase + 1)));
        assertEq(sword & type(uint64).max, composedAt, "statement composedAt");
        uint256[] memory held_ = core.heldStatements();
        uint256 at;
        for (uint256 i; i < held_.length; ++i) {
            if (held_[i] == c.sid) at = i;
        }
        assertEq((sword >> 64) & type(uint64).max, at, "statement slot");
        assertEq((sword >> 128) & type(uint32).max, core.ratingOf(c.sid), "statement rating");
        assertEq((sword >> 160) & 0xff, held ? 1 : 0, "statement held");
        assertEq((sword >> 168) & type(uint40).max, 100, "statement pauseMark");
        assertEq((sword >> 168) & type(uint40).max, core.pausedTotal(), "statement pauseMark is pausedTotal at compose");
        assertEq(sword >> 208, 0, "no field above pauseMark");
        assertEq(uint256(vm.load(address(core), bytes32(S_HELD))), core.heldStatements().length, "held length");
        // composerOf: the compose caller, one word per statement, at the last declared slot
        assertEq(
            uint256(vm.load(address(core), bytes32(_mapSlot(c.sid, S_COMPOSER)))), uint256(uint160(keeper)), "composer"
        );
        assertEq(core.composerOf(c.sid), keeper, "composerOf");
        assertEq(
            uint256(vm.load(address(core), bytes32(uint256(keccak256(abi.encode(S_HELD)))))), c.sid, "first held id"
        );
        // a second statement sits at index 1 of the held list, so a wrong offset of `slot` cannot read as zero
        _fillEthPile(80);
        uint256 second = STATEMENTS.supply() + 1;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sword2 = uint256(vm.load(address(core), bytes32(_mapSlot(second, S_STATEMENTS) + 1)));
        assertEq(core.heldStatements()[1], second, "the second statement is second in the list");
        assertEq((sword2 >> 64) & type(uint64).max, 1, "statement slot of the second statement");
    }
}
