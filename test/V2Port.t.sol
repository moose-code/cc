// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsLpLockerV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ClaimMidRedeem} from "./attackers/V2Port.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";

interface IEscrowStore {
    function storeFeesNative(address feeOwner) external payable;
}

/// the fee path of the v2 port: the hook pushing straight to the Core, escrow credits and the places the v2 hook can
/// put eth. every number is from the real v2 hook and pool on the fork
contract V2PortFeeTest is FeeBase {
    using FixedPointMathLib for uint256;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        s.feeToRedeemBurnBps = 0; // isolate the buyback share from the redeem burn share
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

    /// 1 eth buy in steady state at each split. 6.9 points of skim (0.069 eth) split by bountyBps 9_638: the Core gets
    /// 0.069 * 9_638 / 10_000 = 0.0665022 eth (6.65022 points), the protocol recipient 0.069 less 0.0665022 = 0.0024978 eth
    /// (0.24978 points). of the Core's 66_502_200_000_000_000 wei: payee 75_185 ppm =
    /// 4_999_967_907_000_000 (0.4999968 points), engine the rest = 61_502_232_093_000_000 (6.15 points). the engine part
    /// splits between the pot and the buyback by the share setting
    function test_exactNumbersAtEachSplit() public {
        _stock();
        uint256[3] memory bps = [uint256(0), 5_000, 10_000];
        uint256[3] memory toBb = [uint256(0), 30_751_116_046_500_000, 61_502_232_093_000_000];
        for (uint256 i; i < 3; ++i) {
            _share(uint16(bps[i]));
            uint256 payee0 = lc.payee.balance;
            uint256 owed0 = core.payeeOwed();
            uint256 pot0 = core.ethPot();
            uint256 bb0 = core.ethToBuyback();
            Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
            assertEq(f.skimVolume, 0.931 ether, "volume net of the skim");
            assertEq(f.skimBounty, 0.0665022 ether, "6.65022 points to the Core");
            assertEq(f.skimProtocol, 0.0024978 ether, "0.24978 points to the protocol recipient");
            assertEq(f.bountyRise, 0.0665022 ether);
            assertEq(f.toPayee, 4_999_967_907_000_000, "the single payee");
            assertEq(core.payeeOwed() - owed0, 4_999_967_907_000_000);
            assertEq(lc.payee.balance, payee0, "the book pays the payee nothing, it claims");
            assertEq(core.ethToBuyback() - bb0, toBb[i]);
            assertEq(core.ethPot() - pot0, 61_502_232_093_000_000 - toBb[i], "5.9002215 points to the engine");
            assertEq(address(core).balance, _tracked(), "every wei is booked");
            _solvent();
        }
    }

    /// eth that the hook or the escrow sends to the Core waits for the next book, which splits it by the share setting
    /// like any fee income
    function test_hookAndEscrowEthWaitsForTheBookAndIsSplit() public {
        _share(10_000);
        address[2] memory from = [v2.hook, v2.escrow];
        for (uint256 i; i < 2; ++i) {
            vm.deal(from[i], 1 ether);
            vm.prank(from[i]);
            (bool ok,) = address(core).call{value: 1 ether}("");
            assertTrue(ok);
        }
        assertEq(core.ethPot(), 0);
        assertEq(core.ethToBuyback(), 0);
        assertEq(address(core).balance, 2 ether);
        vm.expectEmit(address(core));
        emit ICore.FeesAdded(2 ether);
        core.book();
        assertEq(core.ethPot(), 0, "the share is all to the buyback");
        assertEq(core.ethToBuyback(), 2 ether);
        _solvent();
    }

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
        assertEq(core.ethToBuyback(), 0, "none to the buyback, whatever the share");
        assertEq(core.payeeOwed(), 0);
        _solvent();
    }

    /// a claim made by a stranger straight on the escrow is fee income at the next book, split like the rest
    function test_aStrayEscrowClaimIsFeeIncomeAtTheNextBook() public {
        _share(5_000);
        _creditCore(0.3 ether);
        vm.prank(_user("stranger"));
        ESCROW.claim(address(core), address(0));
        assertEq(core.ethPot(), 0, "not booked by the claim");
        core.book();
        assertEq(core.ethToBuyback(), 0.15 ether);
        assertEq(core.ethPot(), 0.15 ether);
        _solvent();
    }

    /// `collectEscrow` with nothing to claim reverts with the escrow's error and books nothing
    function test_collectEscrowWithNothingOwedReverts() public {
        vm.expectRevert();
        core.collectEscrow();
        assertEq(core.ethPot(), 0);
        assertEq(address(core).balance, 0);
    }

    /// the same during `redeemStatement`: the pot only falls by the gas repay, the claimed eth is left unbooked for the next book
    function test_claimMidRedeemKeepsThePotsConsistent() public {
        _stock();
        MockBalanceToken token = new MockBalanceToken("Balance Token", "XT");
        ClaimMidRedeem m = new ClaimMidRedeem(token, UNIT, v2.escrow, address(core));
        _setBalanceModule(address(m));
        _setBalanceMode(2);
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        _creditCore(0.2 ether);
        uint256 pot = core.ethPot();
        uint256 gas0 = address(this).balance;
        core.redeemStatement(c.sid);
        assertEq(core.ethPot(), pot - (address(this).balance - gas0), "only the gas repay left the pot");
        assertEq(address(core).balance - _tracked(), 0.2 ether, "the claim is unbooked");
        _solvent();
        core.book();
        assertEq(address(core).balance, _tracked());
    }

    /// lpFee is 0 at launch: the locker has nothing to pay and no reward slot reaches the Core
    function test_noLpIncomeAtLpFeeZero() public {
        _stock();
        for (uint256 i; i < 3; ++i) {
            _buyCoin(trader, 2 ether);
        }
        IArtCoinsLpLockerV2 locker = IArtCoinsLpLockerV2(v2.locker);
        address[] memory rec = locker.rewardRecipients(address(coin));
        uint16[] memory bps = locker.rewardBps(address(coin));
        assertEq(rec.length, 2, "the project slot and the factory protocol slot");
        assertEq(rec[0], creator, "the project slot is the creator address");
        assertEq(bps[0], 8_000);
        assertEq(bps[1], 2_000, "the protocol slot is the factory default");
        assertTrue(rec[1] != address(core), "no slot reaches the engine");
        uint256 core0 = address(core).balance;
        uint256 creator0 = creator.balance;
        uint256 coin0 = coin.balanceOf(creator);
        locker.collectRewards(address(coin));
        assertEq(address(core).balance, core0);
        assertEq(creator.balance, creator0, "no lp fee eth accrued");
        assertEq(coin.balanceOf(creator), coin0, "no lp fee coin accrued");
    }
}
