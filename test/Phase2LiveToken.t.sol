// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface ILiveBalance {
    function transfersOpenBlock() external view returns (uint256);
    function fundingPhase() external view returns (uint8);
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function ready() external view returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// the live BALANCE token on a fork of the current head: the gas of its ordinary transfers once its open block is
/// reached, measured for the Core's 600,000 gas artist bound and the treasury's payments. runs only with
/// LIVE_BALANCE_TOKEN set (the fork is at the head, not the pinned block)
contract Phase2LiveTokenTest is Test {
    ILiveBalance internal token;
    /// a real holder: the token's transfer rules carry its own per holder state, so a balance written by a cheat
    /// reverts (`EmptyInk`); LIVE_BALANCE_HOLDER names one, the default is an auction withdrawer seen in the logs
    address internal holder;
    address internal split = 0xE2324c8CdE4185de580d5369972b243bb6365C11;

    function setUp() public {
        address at = vm.envOr("LIVE_BALANCE_TOKEN", address(0));
        vm.skip(at == address(0));
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        token = ILiveBalance(at);
        holder = vm.envOr("LIVE_BALANCE_HOLDER", address(0x5F7a8fb8cc29e795ba19191Dd74D69A90cDADB88));
    }

    // promise: decision 260 the live token's transfers are open after its open block with retirement finalized and funding phase 3, and a real holder's transfer to an account, transfer to a contract and transferFrom each cost under 450,000 gas, inside the Core's 600,000 bound with room for the treasury's own work
    function test_liveTokenTransferGasUnderTheCoreBound() public {
        assertEq(token.totalRetired(), token.launchRetirement(), "retirement finalized");
        assertEq(token.fundingPhase(), 3, "funding phase 3");
        assertTrue(token.ready());
        uint256 open = token.transfersOpenBlock();
        if (block.number <= open) vm.roll(open + 1);
        assertGe(token.balanceOf(holder), 3 ether, "the holder has a real balance");
        vm.startPrank(holder);
        uint256 g = gasleft();
        token.transfer(address(0xB0B), 1 ether);
        uint256 toAccount = g - gasleft();
        g = gasleft();
        token.transfer(split, 1 ether);
        uint256 toContract = g - gasleft();
        token.approve(address(this), 1 ether);
        vm.stopPrank();
        g = gasleft();
        token.transferFrom(holder, address(this), 1 ether);
        uint256 fromApproved = g - gasleft();
        emit log_named_uint("transfer to an account, gas", toAccount);
        emit log_named_uint("transfer to a contract, gas", toContract);
        emit log_named_uint("transferFrom by an approved spender, gas", fromApproved);
        // measured at block 26,241,420: about 314,000 to a fresh account, 294,000 to a contract, 293,000 by an approved
        // spender; the treasury's `pay` adds its reads and the accrual, so the Core's 600,000 bound keeps about 250,000
        // of room
        assertLt(toAccount, 450_000);
        assertLt(toContract, 450_000);
        assertLt(fromApproved, 450_000);
        assertEq(token.balanceOf(address(0xB0B)), 1 ether);
        assertEq(token.balanceOf(split), 1 ether);
        assertEq(token.balanceOf(address(this)), 1 ether);
    }
}
