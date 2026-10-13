// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";

/// `CoreState` in src/lib/CoreLib.sol mirrors the state variables of the Core in declaration order, and the library
/// reaches the Core's storage through it. every field with a public getter is compared with the raw storage word the
/// mirror assumes, the pile, the mappings and the held list by the slot arithmetic the compiler uses. the pile is a
/// `Pile` struct stored inline (head, tail, size at slots 13, 14, 15), so the mappings and the held list follow it
contract CoreLayoutTest is Fixture {
    uint256 internal constant S_PILE = 13;
    uint256 internal constant S_CREDITS = 16;
    uint256 internal constant S_STATEMENTS = 17;
    uint256 internal constant S_HELD = 18;
    uint256 internal constant S_COMPOSER = 21;

    /// the bytes `[offset, offset + size)` of storage slot `slot` of the core
    function _field(uint256 slot, uint256 offset, uint256 size) internal view returns (uint256) {
        uint256 word = uint256(vm.load(address(core), bytes32(slot)));
        if (size == 32) return word;
        return (word >> (offset * 8)) & ((1 << (size * 8)) - 1);
    }

    function _mapSlot(uint256 key, uint256 base) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, base)));
    }

    function test_OK_scalarFieldsSitWhereTheMirrorSays() public {
        _enterPhase2();
        _fundPot(3 ether);
        uint256[] memory sold = _credits(seller, 3);
        vm.prank(seller);
        core.sellForEth(sold);
        // a large balance token balance is booked into the balance pot and the reserve holds fee eth, so both nonzero words
        // are compared
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.store(address(core), bytes32(uint256(8)), bytes32(uint256(1 ether)));
        vm.startPrank(owner);
        core.addTarget(address(0xA110C));
        vm.stopPrank();
        assertTrue(core.allowedTarget(address(0xA110C)), "setup: the target is allowed");
        assertEq(uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110C), uint256(3))))), 1, "allowedTarget");
        assertEq(uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110D), uint256(3))))), 0, "unset target");
        vm.prank(owner);
        core.transferOwnership(address(0xBEEF));
        vm.startPrank(owner);
        core.lockController();
        core.lockBalanceModule();
        core.lockTargets();
        core.setSuccessor(address(this));
        core.lockSuccessor();
        vm.stopPrank();

        assertEq(_field(0, 0, 20), uint256(uint160(core.controller())), "controller");
        assertEq(_field(0, 20, 1), core.controllerLocked() ? 1 : 0, "controllerLocked");
        assertEq(_field(0, 21, 1), core.balanceModuleLocked() ? 1 : 0, "balanceModuleLocked");
        assertEq(_field(0, 22, 1), core.targetsLocked() ? 1 : 0, "targetsLocked");
        assertEq(_field(1, 0, 20), uint256(uint160(core.balanceModule())), "balanceModule");
        assertEq(_field(2, 0, 20), uint256(uint160(core.balanceToken())), "balanceToken");
        assertEq(_field(4, 0, 20), uint256(uint160(core.owner())), "owner");
        assertEq(_field(5, 0, 20), uint256(uint160(core.pendingOwner())), "pendingOwner");
        assertEq(_field(6, 0, 32), core.ethPot(), "ethPot");
        assertEq(_field(7, 0, 32), core.ethToBuyback(), "ethToBuyback");
        assertEq(_field(8, 0, 32), core.ethRedeemBurn(), "ethRedeemBurn");
        assertEq(core.ethRedeemBurn(), 1 ether, "ethRedeemBurn value");
        assertEq(_field(9, 0, 32), core.balancePot(), "balancePot");
        assertEq(_field(10, 0, 32), core.rateAtCheckpoint(), "rateAtCheckpoint");
        assertEq(_field(11, 0, 8), core.checkpointTime(), "checkpointTime");
        assertEq(_field(11, 8, 8), core.lastFillTime(), "lastFillTime");
        assertEq(_field(12, 0, 32), core.lastBuybackBlock(), "lastBuybackBlock");
        assertEq(_field(19, 0, 20), uint256(uint160(core.successor())), "successor");
        assertEq(_field(19, 20, 1), core.successorLocked() ? 1 : 0, "successorLocked");
        assertEq(core.successor(), address(this), "successor value");
        assertTrue(core.successorLocked(), "successorLocked value");
        assertTrue(core.controllerLocked() && core.balanceModuleLocked() && core.targetsLocked(), "locks");
        // the standalone settings pack after retired: creditCostToPotBps and chosenComposeOn finish slot 19 (offsets
        // 22 and 24), minCcToChoose (uint96, 12 bytes) cannot straddle so it starts slot 20
        vm.startPrank(owner);
        core.setCreditCostToPotBps(6_000);
        core.setChosenComposeOn(true);
        core.setMinCcToChoose(123);
        vm.stopPrank();
        assertEq(_field(19, 22, 2), core.creditCostToPotBps(), "creditCostToPotBps");
        assertEq(_field(19, 22, 2), 6_000, "creditCostToPotBps value");
        assertEq(_field(19, 24, 1), core.chosenComposeOn() ? 1 : 0, "chosenComposeOn");
        assertEq(_field(20, 0, 12), core.minCcToChoose(), "minCcToChoose");
        assertEq(core.minCcToChoose(), 123, "minCcToChoose value");
        // the pause clock follows minCcToChoose in slot 20: paused (1 byte), pausedSince and pausedTotal (5 bytes each)
        vm.prank(owner);
        core.setPaused(true);
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 777);
        assertEq(_field(20, 12, 1), 1, "paused");
        assertEq(_field(20, 13, 5), pausedAt, "pausedSince");
        assertEq(_field(20, 13, 5), core.pausedSince(), "pausedSince getter");
        assertEq(_field(20, 18, 5), 0, "pausedTotal while the first pause is open");
        vm.prank(owner);
        core.setPaused(false);
        assertEq(_field(20, 12, 1), 0, "resumed");
        assertEq(_field(20, 13, 5), 0, "pausedSince is cleared");
        assertEq(_field(20, 18, 5), 777, "pausedTotal");
        assertEq(_field(20, 18, 5), core.pausedTotal(), "pausedTotal getter");
        assertEq(_field(20, 12, 1), core.paused() ? 1 : 0, "paused getter");
        // the first migrate sets retired. the call moves the pots, so it comes after the pot words are compared
        assertEq(_field(19, 21, 1), 0, "retired is false before a migrate");
        assertFalse(core.retired(), "retired value before");
        vm.prank(owner);
        core.migrate(0);
        assertEq(_field(19, 21, 1), 1, "retired");
        assertTrue(core.retired(), "retired value");
    }

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
        assertEq(uint256(vm.load(address(core), bytes32(_mapSlot(c.sid, S_COMPOSER)))), uint256(uint160(keeper)), "composer");
        assertEq(core.composerOf(c.sid), keeper, "composerOf");
        assertEq(
            uint256(vm.load(address(core), bytes32(uint256(keccak256(abi.encode(S_HELD)))))),
            c.sid,
            "first held id"
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
