// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IArtCoinsHookV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {Prod} from "./utils/Prod.sol";

/// refuses every eth transfer
contract RefusingRecipient {
    receive() external payable {
        revert("no");
    }
}

/// burns all gas it is given
contract GasBurnerRecipient {
    uint256 public sink;

    receive() external payable {
        for (uint256 i; i < type(uint256).max; ++i) {
            sink = i;
        }
    }
}

/// moving the fee stream to a new engine: a second Core bound to the same coin and stack, and the coin admin repointing
/// the bounty recipient of the pool with the hook's `setBountyRecipient`. real v2 stack, real pool
contract V2PortMigrationTest is FeeBase {
    ICore internal core2;
    IControllerV1 internal ctl2;

    /// @dev the second engine, deployed by a fresh account the way the first was: controller, then Core. it is built for
    /// the launched coin, and the pool pays the first Core until the coin admin repoints it. the coin allowlist does not
    /// list it
    function _deployCore2() internal {
        address dep = _user("second deployer");
        uint64 n = vm.getNonce(dep);
        address ctlAt = vm.computeCreateAddress(dep, n);
        address coreAt = vm.computeCreateAddress(dep, n + 1);
        vm.startPrank(dep);
        ctl2 = Prod.newController(coreAt, lc.sale);
        core2 = _successorCore(address(ctl2), lc.rateStart, lc.settings);
        vm.stopPrank();
        assertEq(address(ctl2), ctlAt);
        assertEq(address(core2), coreAt);
        assertEq(core2.COIN(), address(coin));
    }

    /// the part of an inflow `toEngine` the second Core books to its pot: the redeem burn share goes to its reserve
    function _toPot2(uint256 toEngine) internal view returns (uint256) {
        return toEngine - toEngine * core2.settings().feeToRedeemBurnBps / 10_000;
    }

    /// @dev the coin admin points the pool's bounty recipient at `to`
    function _repoint(address to) internal {
        vm.prank(owner);
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(to));
        assertEq(address(IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId).bountyRecipient), to);
    }

    /// repointing: fees flow to the new Core and book there, the old Core books nothing more and keeps working on what it
    /// holds, and the pool never moved what the old Core already had
    function test_repointMovesTheFeesAndTheOldCoreKeepsWorking() public {
        _stock();
        _fillEthPile(80);
        _deployCore2();
        uint256 pot1 = core.ethPot();
        uint256 bal1 = address(core).balance;
        assertGt(pot1, 0);
        _repoint(address(core2));

        autoBook = false;
        _buyCoin(trader, 1 ether);
        assertEq(address(core2).balance, 0.0665022 ether, "the bounty leg reached the new Core");
        core2.book();
        // the first book of the new Core latches its payee share and shares nothing
        Settings memory s = core2.settings();
        uint256 toPot = 0.0665022 ether - uint256(0.0665022 ether) * s.feeToRedeemBurnBps / 10_000;
        assertEq(core2.ethPot(), toPot, "the new Core booked the fees");
        assertTrue(core2.payeeOn());
        assertEq(core.ethPot(), pot1, "the old Core books nothing more");
        assertEq(address(core).balance, bal1, "and received nothing");

        // the second book shares
        _buyCoin(trader, 1 ether);
        core2.book();
        assertEq(core2.payeeOwed(), uint256(0.0665022 ether) * s.payeePpm / 1_000_000);

        // the old Core still composes and sells with what it holds
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _buy(trader, sid);
        _solvent();
        assertEq(address(core).balance, _tracked(), "the old Core's books are exact");
        assertEq(address(core2).balance, core2.ethPot() + core2.ethToBuyback() + core2.ethRedeemBurn() + core2.payeeOwed());
    }

    /// the new Core is not on the coin allowlist and still buys back: the hook grants exactly the allowance the take
    /// needs. nobody can send it coin, which is the point of not listing it
    function test_newCoreWithoutAllowlistBuysBack() public {
        _stock();
        _deployCore2();
        _repoint(address(core2));
        Settings memory s = core2.settings();
        s.feeToRedeemBurnBps = 10_000;
        vm.prank(owner);
        core2.setSettings(s);
        assertFalse(coin.isAllowed(address(core2)));
        autoBook = false;
        _buyCoin(trader, 5 ether);
        core2.book();
        // the fee eth sits in the redeem burn reserve; the owner moves it to the buyback pot
        vm.prank(owner);
        core2.releaseRedeemBurn(type(uint256).max);
        assertGt(core2.ethToBuyback(), 0);
        vm.prank(trader);
        vm.expectRevert();
        coin.transfer(address(core2), 1e18);

        uint256 supply0 = coin.totalSupply();
        uint256 bb0 = core2.ethToBuyback();
        vm.prank(keeper);
        core2.buyback();
        assertLt(coin.totalSupply(), supply0, "bought and burned");
        assertLt(core2.ethToBuyback(), bb0);
        assertEq(coin.balanceOf(address(core2)), 0);
        assertEq(coin.transferAllowance(), 0, "the take consumed the whole allowance");
        assertLe(
            core2.ethPot() + core2.ethToBuyback() + core2.ethRedeemBurn() + core2.payeeOwed(), address(core2).balance
        );
    }

    /// the retired Core keeps booking the fees that reach it until the coin admin repoints the pool: the pot of the
    /// old Core migrates through `fund` and the stream follows the repoint
    function test_migrateMovesThePotThroughFundAndTheStreamFollowsTheRepoint() public {
        _stock();
        _fillEthPile(80);
        _deployCore2();
        vm.startPrank(owner);
        core.setSuccessor(address(core2));
        vm.stopPrank();
        uint256 pot1 = core.ethPot();
        assertGt(pot1, 0);
        vm.prank(owner);
        core.migrate(10);
        assertEq(core.ethPot(), 0, "the pot left the old Core");
        assertEq(core2.ethPot(), pot1, "and reached the new one whole through fund");
        // the pool still pays the retired Core: it books the fees it receives
        autoBook = false;
        _buyCoin(trader, 1 ether);
        core.book();
        assertGt(core.ethPot(), 0, "the retired Core books fees that reach it");
        _repoint(address(core2));
        uint256 pot2 = core2.ethPot();
        _buyCoin(trader, 1 ether);
        core2.book();
        assertGt(core2.ethPot(), pot2, "the new Core books the stream after the repoint");
        _solvent();
    }

    /// `lockRecipients` freezes the bounty recipient: the stream keeps flowing to the Core set at that time and nobody can
    /// repoint it
    function test_lockRecipientsFreezesTheStream() public {
        _stock();
        _deployCore2();
        _repoint(address(core2));
        vm.prank(owner);
        coin.lockRecipients();
        vm.prank(owner);
        vm.expectRevert();
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(address(core)));
        autoBook = false;
        _buyCoin(trader, 1 ether);
        uint256 pot1 = core.ethPot();
        core2.book();
        assertGt(core2.ethPot(), 0);
        assertEq(core.ethPot(), pot1);
    }

    /// a bounty recipient that refuses eth: every swap still works (the hook pushes with the stipend and credits the
    /// escrow when the push fails), and the Core is repointed afterwards
    function test_refusingRecipientNeverBlocksSwaps() public {
        _stock();
        RefusingRecipient bad = new RefusingRecipient();
        _repoint(address(bad));
        autoBook = false;
        uint256 owed0 = ESCROW.balances(address(bad), address(0));
        for (uint256 i; i < 3; ++i) {
            _buyCoin(trader, 1 ether);
            _sellCoin(trader, coin.balanceOf(trader) / 10);
        }
        assertGt(ESCROW.balances(address(bad), address(0)), owed0 + 0.18 ether, "the escrow holds the bounty legs");
        assertEq(address(bad).balance, 0, "the recipient received nothing");
        _repoint(address(core));
        uint256 pot0 = core.ethPot();
        _buyCoin(trader, 1 ether);
        core.book();
        assertGt(core.ethPot(), pot0, "the Core books the stream again");
        _solvent();
    }

    /// a recipient that burns all the gas it is given cannot make a swap fail either
    function test_gasBurningRecipientNeverBlocksSwaps() public {
        _stock();
        GasBurnerRecipient bad = new GasBurnerRecipient();
        _repoint(address(bad));
        autoBook = false;
        uint256 owed0 = ESCROW.balances(address(bad), address(0));
        _buyCoin(trader, 1 ether);
        _sellCoin(trader, coin.balanceOf(trader) / 3);
        assertGt(ESCROW.balances(address(bad), address(0)), owed0, "the escrow holds the bounty legs");
    }
}
