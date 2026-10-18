// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IArtCoinsHookV2, IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Prod} from "./utils/Prod.sol";
import {LeftoverSpender} from "./attackers/V2Port.sol";

interface IEscrowStore {
    function storeFeesNative(address feeOwner) external payable;
}

/// the fee path of the v2 port: the hook pushing straight to the Core, escrow credits and the places the v2 hook can
/// put eth. every number is from the real v2 hook and pool on the fork
contract V2PortFeeTest is FeeBase {
    using FixedPointMathLib for uint256;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToRedeemBurnBps = bps;
        _setSettings(s);
    }

    /// @dev the hook (a real escrow depositor) credits `amount` to the Core, the way a partial fill refund of the Core's
    /// own buyback is stored (D58)
    function _creditCore(uint256 amount) internal {
        assertTrue(ESCROW.isDepositor(v2.hook), "the hook is a depositor");
        vm.deal(v2.hook, v2.hook.balance + amount);
        vm.prank(v2.hook);
        IEscrowStore(address(ESCROW)).storeFeesNative{value: amount}(address(core));
    }

    // promise: SPEC 4 collectEscrow claims the Core credit in the fee escrow into ethPot
    /// a refund credited to the Core in the escrow (the shape of a partial fill refund of its own buyback): anyone can
    /// claim it into the Core with `collectEscrow`, which adds it to the pot whole, whatever the share is. nobody can send
    /// it elsewhere. a partial fill itself cannot be made on the launch pool (it needs about 3e42 wei, over the int128
    /// range of a pool amount)
    function test_escrowCreditOfTheCoreIsCollectedIntoThePot() public {
        _share(5_000);
        _creditCore(0.3 ether);
        assertEq(ESCROW.balances(address(core), address(0)), 0.3 ether);
        assertFalse(ESCROW.selfClaimOnly(address(core)));
        address stranger = _user("stranger");
        vm.startPrank(stranger);
        vm.expectRevert();
        ESCROW.claimTo(address(core), address(0), payable(stranger));
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.EscrowCollected(0.3 ether);
        core.collectEscrow();
        vm.stopPrank();
        assertEq(ESCROW.balances(address(core), address(0)), 0);
        assertEq(address(core).balance, 0.3 ether, "paid to the Core");
        assertEq(core.ethPot(), 0.3 ether, "the whole claim is in the pot");
        assertEq(core.ethRedeemBurn(), 0, "none to the reserve, whatever the share");
        _solvent();
    }

    // promise: SPEC 4 a stranger's escrow claim of the Core credit lands in receive as fee income for the next book
    /// `ESCROW.claim(core, 0)` pays a credit of the Core to the Core itself and anyone may call it. the eth lands in
    /// `receive` unbooked, so `collectEscrow` finds nothing after it, and the next `book` splits it by the fee rules
    /// (payee share, redeem burn share, the rest to the pot) rather than booking it whole the way `collectEscrow` does.
    /// a cold fresh deploy inside the sniper window, so the book does not latch the payee and shares nothing
    function test_strangerEscrowClaimLandsAsIncomeForTheNextBook() public {
        _share(5_000);
        _creditCore(0.3 ether);
        assertEq(ESCROW.balances(address(core), address(0)), 0.3 ether);
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertFalse(core.payeeOn(), "inside the sniper window the payee share is not latched");

        address stranger = _user("escrow claimer");
        uint256 bal0 = address(core).balance;
        vm.prank(stranger);
        ESCROW.claim(address(core), address(0));
        assertEq(ESCROW.balances(address(core), address(0)), 0, "the stranger claimed the Core credit");
        assertEq(address(core).balance - bal0, 0.3 ether, "the claim pushed the eth to the Core, unbooked");
        assertEq(core.ethPot(), 0, "the push booked nothing on its own");
        assertEq(address(core).balance - _tracked(), 0.3 ether, "the claim waits above the pots");

        // collectEscrow now has nothing to claim
        vm.expectRevert();
        core.collectEscrow();

        // the next book splits the pushed claim by the fee rules, not whole to the pot
        uint256 pot0 = core.ethPot();
        uint256 rb0 = core.ethRedeemBurn();
        uint256 payee0 = core.payee().balance;
        core.book();
        uint256 toBurn = uint256(0.3 ether) * 5_000 / 10_000;
        assertEq(core.ethRedeemBurn() - rb0, toBurn, "the redeem burn share of the claim");
        assertEq(core.ethPot() - pot0, 0.3 ether - toBurn, "the rest of the claim to the pot");
        assertEq(core.payee().balance - payee0, 0, "the payee share is zero at launch");
        assertEq(address(core).balance, _tracked(), "every wei is booked");
        _solvent();
    }

    // promise: SPEC 4 collectEscrow reverts with the escrow error when nothing is owed
    /// `collectEscrow` with nothing to claim reverts with the escrow's error and books nothing
    function test_collectEscrowWithNothingOwedReverts() public {
        vm.expectRevert();
        core.collectEscrow();
        assertEq(core.ethPot(), 0);
        assertEq(address(core).balance, 0);
    }

    /// @dev a tick below the current price, so an exact input eth to coin swap stops at the limit and fills partially
    function _limitBelow() internal view returns (uint160) {
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(Mainnet.POOL_MANAGER), PoolId.wrap(poolId));
        return sp - sp / 100;
    }

    // promise: D126 a partial fill of an exact input swap refunds the over charged skim to the hookData refund address
    /// the shape of the Core's own buyback: an exact input eth to coin swap with a tight price limit fills partially,
    /// and the skim charged on the unfilled eth is credited to the refund address `hookData` carries, the way the Core's
    /// buyback names itself. the same SwapData struct encoding the buyback sends, with the Core as the refund address
    function test_partialFillRefundsToTheHookDataAddress() public {
        _skipSniperWindow();
        address refundTo = _user("refund.to");
        bytes memory hookData =
            abi.encode(PoolSwapData({mevModuleSwapData: abi.encode(refundTo), poolExtensionSwapData: ""}));
        uint256 ethIn = 200 ether;
        vm.deal(trader, ethIn);
        vm.prank(trader);
        router.swapWithLimit{value: ethIn}(launchKey, true, -int256(ethIn), _limitBelow(), trader, hookData);
        assertGt(ESCROW.balances(refundTo, address(0)), 0, "the over charged skim is credited to the refund address");
    }

    // promise: D126 a partial fill with no refund address reverts, which is why the buyback carries one
    /// without a refund address in `hookData` the same partial fill reverts: the engine's buyback carries the Core as
    /// the refund address so this never fires on its own swap
    function test_partialFillWithoutRefundAddressReverts() public {
        _skipSniperWindow();
        uint256 ethIn = 200 ether;
        uint160 limit = _limitBelow();
        vm.deal(trader, ethIn);
        vm.prank(trader);
        vm.expectRevert();
        router.swapWithLimit{value: ethIn}(launchKey, true, -int256(ethIn), limit, trader, "");
    }

}

/// refuses every eth transfer
contract RefusingRecipient {
    receive() external payable {
        revert("no");
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

    /// @dev the coin admin points the pool's bounty recipient at `to`
    function _repoint(address to) internal {
        vm.prank(owner);
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(to));
        assertEq(address(IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId).bountyRecipient), to);
    }

    // promise: SPEC 9 the pool bounty recipient moves to the successor with setBountyRecipient
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
        assertEq(address(core2).balance, 0.0621 ether, "the bounty leg reached the new Core");
        core2.book();
        // the first book of the new Core latches its payee share and shares nothing
        Settings memory s = core2.settings();
        uint256 toPot = 0.0621 ether - uint256(0.0621 ether) * s.feeToRedeemBurnBps / 10_000;
        assertEq(core2.ethPot(), toPot, "the new Core booked the fees");
        assertTrue(core2.payeeOn());
        assertEq(core.ethPot(), pot1, "the old Core books nothing more");
        assertEq(address(core).balance, bal1, "and received nothing");

        // the second book pushes the payee share (payeePpm is 0 at launch, so the push is zero)
        uint256 payeeBefore = core2.payee().balance;
        _buyCoin(trader, 1 ether);
        core2.book();
        assertEq(core2.payee().balance - payeeBefore, uint256(0.0621 ether) * s.payeePpm / 1_000_000);

        // the old Core still composes and sells with what it holds
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _buy(trader, sid);
        _solvent();
        assertEq(address(core).balance, _tracked(), "the old Core's books are exact");
        assertEq(address(core2).balance, core2.ethPot() + core2.ethToBuyback() + core2.ethRedeemBurn());
    }

    // promise: SPEC 1 the Core buys back without being on the coin allowlist
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
        assertLe(core2.ethPot() + core2.ethToBuyback() + core2.ethRedeemBurn(), address(core2).balance);
    }

    // promise: inv 10 a refusing bounty recipient never blocks swaps
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

}

/// master coin admin controls over the pool skim, and where the protocol leg lands. real coin, real pool, real hook
contract V2PortSkimTest is FeeBase {
    function setUp() public override {
        super.setUp();
        _skipSniperWindow();
    }

    // promise: D126 the coin admin lowers the baseline skim, which lowers the engine's fee per swap
    /// `lowerBaselineSkim` by the coin admin halves the baseline, so the Core's bounty leg per swap halves
    function test_lowerBaselineSkimLowersTheEngineFee() public {
        autoBook = false;
        uint256 b0 = address(core).balance;
        _buyCoin(trader, 1 ether);
        uint256 full = address(core).balance - b0;
        vm.prank(owner);
        IArtCoinsHookV2(lc.stack.hook).lowerBaselineSkim(poolId, 345);
        assertEq(IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId).baselineSkimBps, 345, "baseline halved");
        uint256 b1 = address(core).balance;
        _buyCoin(trader, 1 ether);
        uint256 half = address(core).balance - b1;
        assertLt(half, full, "the engine fee per swap dropped");
        assertApproxEqRel(half * 2, full, 0.05e18, "about half the bounty at half the baseline");
    }

    // promise: D126 the coin lock freezes lowerBaselineSkim
    /// once the coin admin locks the coin, `lowerBaselineSkim` reverts, so the engine's fee can no longer be lowered
    function test_lockFreezesLowerBaselineSkim() public {
        vm.prank(owner);
        coin.lock();
        assertTrue(coin.locked());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("CoinLocked()"));
        IArtCoinsHookV2(lc.stack.hook).lowerBaselineSkim(poolId, 500);
    }

    // promise: D126 and D186 the protocol leg lands at the protocol fee controller
    /// the protocol recipient of the pool is the ProtocolFeeControllerV2, and a 1 eth buy lands 0.0069 eth there
    /// (10 percent of the 690 bps baseline skim), pushed or credited to it in the escrow
    function test_protocolLegLandsAtTheController() public {
        address controller = v2.controller;
        assertEq(IArtCoinsFactoryV2(lc.stack.factory).protocolRecipient(), payable(controller), "factory recipient");
        assertEq(address(IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId).protocolRecipient), controller, "pool recipient");
        autoBook = false;
        uint256 bal0 = controller.balance;
        uint256 esc0 = ESCROW.balances(controller, address(0));
        _buyCoin(trader, 1 ether);
        uint256 landed = (controller.balance - bal0) + (ESCROW.balances(controller, address(0)) - esc0);
        assertApproxEqRel(landed, 0.0069 ether, 0.02e18, "protocol leg 0.69 percent of volume at the controller");
    }
}

/// the restricted v2 coin as the engine meets it: the Core, the router and every holder are off the allowlist (FLOW 29).
/// real coin, real pool, real hook
contract V2PortRestrictionTest is FeeBase {
    error TransferRestricted(address from, address to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _stock();
    }

    function _bought(uint256 pmBefore) internal view returns (uint256) {
        return pmBefore - coin.balanceOf(Mainnet.POOL_MANAGER);
    }

    // promise: SPEC 1 the Core buys back on a restricted coin
    /// the Core is off the allowlist: the take of the bought coin consumes the whole allowance the hook granted for the swap,
    /// so no allowance is left to spend in the same transaction. the Core ends the buyback holding no coin
    function test_buybackConsumesTheWholeAllowance() public {
        _fillEthBuyback();
        assertFalse(coin.isAllowed(address(core)), "the Core is not on the allowlist");
        LeftoverSpender s = new LeftoverSpender(address(coin), address(core), Mainnet.POOL_MANAGER);
        _buyCoin(address(s), 2 ether);
        uint256 held = coin.balanceOf(address(s));
        assertGt(held, 1_000e18);
        uint256 supply0 = coin.totalSupply();
        s.run(1_000e18);
        assertGt(supply0 - coin.totalSupply(), 0, "the buyback burned");
        assertEq(s.leftover(), 0, "the take consumed the whole allowance");
        assertFalse(s.spent(), "nothing was left to spend");
        assertEq(coin.balanceOf(address(s)), held, "the stranger's coin did not move");
        assertEq(coin.balanceOf(address(core)), 0, "the Core holds no coin after the buyback");
    }

    // promise: SPEC 1 the coin is restricted: a wallet cannot send coin to the Core
    /// a holder that is not on the allowlist cannot send coin to the Core: the Core is not on it either
    function test_aWalletCannotSendCoinToTheCore() public {
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(TransferRestricted.selector, trader, address(core), 1_000e18));
        coin.transfer(address(core), 1_000e18);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), bb);
        _solvent();
    }

    // promise: SPEC 1 the owner can remove the coin restriction (decision 83): coin sent to the Core is inert
    /// with the restriction turned off by the coin admin, plain transfers work, a transfer to the Core is inert in the same
    /// way, and the buyback behaves as before
    function test_unrestrictedTransferToTheCoreIsInert() public {
        vm.prank(owner);
        coin.unrestrict();
        assertFalse(coin.restricted());
        address friend = _user("friend");
        vm.prank(trader);
        coin.transfer(friend, 1e18);
        assertEq(coin.balanceOf(friend), 1e18);
        vm.prank(friend);
        coin.transfer(address(core), 1e18);
        _fillEthBuyback();
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        assertEq(supply0 - coin.totalSupply(), _bought(pm0));
        assertEq(coin.balanceOf(address(core)), 1e18, "the transferred coin stays");
        _solvent();
        vm.prank(owner);
        core.rescueCoin(friend, 1e18);
        assertEq(coin.balanceOf(address(core)), 0);
    }
}
