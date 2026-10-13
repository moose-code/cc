// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, ICreditScore, ICredits, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {BidModel} from "./utils/BidModel.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";

/// the full system on a fork: the live artcoins stack, the live credits stack, the real core. fees come from real
/// swaps in the real pool. the exact fee split is pinned in Fees.t.sol, here only what the doors do with the pot
contract LifecycleSwapsTest is Fixture {
    address internal trader;

    function setUp() public override {
        super.setUp();
        trader = _user("trader");
        _skipSniperWindow();
    }

    /// real swaps are what feeds the pot, and nothing else moves it
    function test_swaps_feedThePot() public {
        assertEq(core.ethPot(), 0);
        uint256 coinOut = _buyCoin(trader, 100 ether);
        assertGt(coinOut, 0);
        uint256 pot = core.ethPot();
        assertGt(pot, 0, "a buy feeds the pot");
        assertGt(core.ethRedeemBurn(), 0, "feeToRedeemBurnBps routes a share to the reserve");
        assertEq(core.ethToBuyback(), 0, "swap fees never touch the buyback pot");
        assertGe(
            address(core).balance,
            pot + core.ethToBuyback() + core.ethRedeemBurn(),
            "the booked pots never exceed the balance"
        );

        _sellCoin(trader, coinOut / 2);
        assertGt(core.ethPot(), pot, "a sell feeds the pot too");
        assertEq(address(core).balance, core.ethPot() + core.ethRedeemBurn(), "the pot and reserve are the balance");
        assertEq(coin.totalSupply(), 1_000_000_000e18, "swaps burn nothing");
        _solvent();
    }

    /// the rate does not climb while the pot cannot afford one credit, and does not climb retroactively
    function test_swaps_priceStateWaitsForTheClamp() public {
        _skipSniperWindow();
        assertEq(core.rateAtCheckpoint(), core.RATE_START());
        assertEq(core.ethRate(), 0, "an empty pot reads zero");

        // one credit costs 1.732e15 wei at the start rate. a small buy leaves less than one credit in the pot
        _buyCoin(trader, 0.01 ether);
        assertLt(core.ethPot(), 1.7e15);
        _warp(200 hours);
        assertEq(core.ethRate(), core.ethPot(), "a small pot reads the clamp");

        // the pot grows
        _buyCoin(trader, 0.2 ether);
        assertLe(core.ethRate(), core.RATE_START(), "no retroactive climb");
        assertEq(core.rateAtCheckpoint(), core.RATE_START(), "the price state waited at the opening rate");
        // a pot that affords a credit above the opening rate lets the climb start
        _buyCoin(trader, 10 ether);
        _warp(10 hours);
        assertGt(core.ethRate(), core.RATE_START());

        // the climb stops at the clamp of the pot or at the rate cap, whichever is lower
        _warp(2000 hours);
        uint256 clamp = core.ethPot();
        assertEq(core.ethRate(), clamp < core.settings().rateCap ? clamp : core.settings().rateCap);
    }

    /// the balance side doors are shut while the balance module slot is empty and balanceMode is 0
    function test_phase1_balanceDoorsAreClosed() public {
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(1);
        vm.expectRevert(ICore.BalanceModeOff.selector);
        core.sellForBalance(_one(1));
        // the statement sale door belongs to the controller and needs no module
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo(1, address(0xB1D));
        assertEq(core.balanceToken(), address(0));
        assertEq(core.balanceModule(), address(0));
    }
}

/// credit doors against a pot filled by real fees.
contract LifecycleDoorsTest is Fixture {
    using FixedPointMathLib for uint256;

    HostileTarget internal hostile;

    function setUp() public override {
        super.setUp();
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        hostile = new HostileTarget();
        _allow(address(hostile));
        _fundPot(20 ether);
    }

    /// @dev the rate after one credit bought at `r`, where `start` is the rate of the first fill of the same minute
    function _dropped(uint256 r, uint256 start) internal view returns (uint256) {
        return BidModel.dropOnce(core.settings(), r, start);
    }

    /// sellForEth pays the climbed ceiling out of a pot that real swaps filled, drops the rate per credit, and the
    /// next real swap adds to the same pot.
    function test_sellForEth_againstThePotRealFeesFilled() public {
        uint256[] memory ids = _credits(seller, 3);
        _warp(30 hours);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();
        assertGt(rate, core.RATE_START(), "funded, so the rate climbed");

        uint256[3] memory prices;
        uint256 total;
        uint256 r = rate;
        uint256 p = pot;
        for (uint256 i; i < 3; ++i) {
            prices[i] = r;
            total += prices[i];
            r = _dropped(r, rate);
            p -= prices[i];
        }

        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);

        assertEq(seller.balance - before, total, "paid the sum of the ceilings");
        assertEq(core.ethPot(), pot - total);
        assertEq(core.rateAtCheckpoint(), r, "dropped once per credit");
        assertLt(r, rate);
        assertEq(core.lastFillTime(), block.timestamp);
        assertEq(core.pileSize(), 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), address(core));
            (bool inPile, uint256 cost,) = core.creditInfo(ids[i]);
            assertTrue(inPile);
            assertEq(cost, prices[i]);
        }
        _solvent();

        // a real buy afterwards adds to the same pot
        _buyCoin(funder, 10 ether);
        assertGt(core.ethPot(), pot - total);
        assertEq(
            address(core).balance,
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(),
            "everything held is booked"
        );
        _solvent();
    }

    /// the buyer cannot be front run into a worse price: minOut reverts when the total falls short.
    function test_sellForEth_minOutProtectsTheSeller() public {
        uint256[] memory ids = _credits(seller, 2);
        _warp(10 hours);
        uint256 first = core.ethRate();
        uint256 sum = first + _dropped(core.ethRate(), core.ethRate());
        vm.prank(seller);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForEth(ids, sum + 1);
        vm.prank(seller);
        core.sellForEth(ids, sum);
        assertEq(seller.balance, sum);
    }

    struct Snapshot {
        uint256 ethPot;
        uint256 ethToBuyback;
        uint256 balance;
        uint256 rate;
        uint64 checkpointTime;
        uint64 lastFillTime;
        uint256 pile;
        uint256 saleA;
        uint256 saleB;
        address ownerA;
        address ownerB;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.ethPot = core.ethPot();
        s.ethToBuyback = core.ethToBuyback();
        s.balance = address(core).balance;
        s.rate = core.rateAtCheckpoint();
        s.checkpointTime = core.checkpointTime();
        s.lastFillTime = core.lastFillTime();
        s.pile = core.pileSize();
        s.saleA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        s.saleB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        s.ownerA = CREDITS.ownerOf(LISTED_A);
        s.ownerB = CREDITS.ownerOf(LISTED_B);
    }

    function _assertUnchanged(Snapshot memory s) internal view {
        assertEq(keccak256(abi.encode(_snapshot())), keccak256(abi.encode(s)), "state moved");
    }

    function _buyData(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _checkListingBuy(uint256 id, uint256 price, bool gapBinds) internal {
        uint256 ceiling = core.ethRate();
        uint256 rate = core.ethRate();
        uint256 pot = core.ethPot();
        uint256 balance = address(core).balance;
        vm.fee(1 gwei);
        assertEq(ceiling - price < _maxListingPay(), gapBinds, "which bound applies");
        uint256 keeper0 = keeper.balance;

        vm.prank(keeper);
        core.buyListing(price, _buyData(id), id, STRATEGY);

        uint256 paid = keeper.balance - keeper0;
        _assertListingPay(paid, ceiling - price);
        if (gapBinds) assertEq(paid, ceiling - price, "the payment is the gap");
        else assertLt(paid, ceiling - price, "the payment is gas plus the fee");
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(ICreditStrategy(STRATEGY).nftForSale(id), 0, "the strategy sold it");
        assertEq(core.ethPot(), pot - price - paid);
        assertEq(address(core).balance, balance - price - paid);
        assertEq(core.rateAtCheckpoint(), _dropped(rate, rate));
        assertEq(core.lastFillTime(), block.timestamp);
        (bool inPile, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        assertEq(cost, price + paid, "cost basis includes the payment");
        _solvent();
    }

    /// a real CreditStrategy listing bought with the real pot, right where the ceiling first clears the price.
    function test_buyListing_realStrategy_gapBoundPayment() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        assertGt(price, core.ethRate(), "the start rate is far below the listing");
        vm.prank(keeper);
        vm.expectRevert(ICore.AboveCeiling.selector);
        core.buyListing(price, _buyData(LISTED_A), LISTED_A, STRATEGY);

        _warpUntilCeiling(LISTED_A, price);
        _checkListingBuy(LISTED_A, price, true);
    }

    /// far above the price the payment is gas at the base fee plus the keeper fee.
    function test_buyListing_realStrategy_gasBoundPayment() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        _warp(30 hours);
        _checkListingBuy(LISTED_A, price, false);
    }

    /// a CreditStrategy call that fails reverts only that buy, and the state is exactly what it was.
    function test_buyListing_failingStrategyCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _warpUntilCeiling(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        Snapshot memory s0 = _snapshot();

        // wrong value, the strategy refuses
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA - 1, _buyData(LISTED_A), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // wrong calldata for the value
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // the call works but delivers another credit than the one asked for
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // a credit the strategy holds but does not list
        uint256 unlisted = CreditIds.at(5);
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(1, _buyData(unlisted), unlisted, STRATEGY);
        _assertUnchanged(s0);

        // another listing still goes through, and the first one stays for sale
        vm.prank(keeper);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(CREDITS.ownerOf(LISTED_A), STRATEGY);
        assertEq(ICreditStrategy(STRATEGY).nftForSale(LISTED_A), priceA);

        // the core never buys a credit it already owns
        vm.prank(keeper);
        vm.expectRevert(ICore.AlreadyOwned.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    /// a target that takes the eth and returns no credit reverts, and nothing moves.
    function test_buyListing_hostileTargetReverts() public {
        Snapshot memory s0 = _snapshot();
        uint256 hostile0 = address(hostile).balance;

        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
        assertEq(address(hostile).balance, hostile0, "the eth came back with the revert");

        // not on the list at all
        address stranger = address(new HostileTarget());
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, stranger);

        // removal is immediate
        vm.prank(owner);
        core.removeTarget(address(hostile));
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
    }

    /// the system's own contracts can never become targets, even by the owner.
    function test_buyListing_forbiddenTargetsCannotBeAdded() public {
        address[9] memory forbidden = [
            lc.stack.hook,
            address(coin),
            address(PM),
            address(core),
            Mainnet.CREDITS,
            Mainnet.STATEMENTS,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(forbidden[i]);
            assertFalse(core.allowedTarget(forbidden[i]));
        }
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, lc.stack.hook);
    }
}

/// compose, the sale through the controller and the real buyback against the real pool
contract LifecycleComposeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal alice;
    address internal bob;
    address internal buybacker;

    function setUp() public override {
        super.setUp();
        alice = _user("alice");
        bob = _user("bob");
        buybacker = _user("buybacker");
        _skipSniperWindow();
    }

    /// a funded pot, then 90 hours so the rate climbs to about 21 times the start. a credit then costs about
    /// 0.036 eth and a page of 80 about 2.9 eth
    function _prepare() internal {
        _fundPot(20 ether);
        _warp(90 hours);
    }

    // ------------------------------------------------------------------ compose

    /// compose through ControllerV1: the 80 oldest credits, format 0, the id is the new supply, the cost basis
    /// and the statement is held by the core at an asking price of 150 percent of its cost
    function test_compose_throughControllerV1() public {
        _prepare();
        uint256[] memory sold = _fillEthPile(85);
        assertEq(core.pileSize(), 85);
        Composed memory c = _composeOnce();

        for (uint256 i; i < 80; ++i) {
            assertEq(c.ids[i], sold[i], "the 80 oldest, in pile order");
        }
        assertEq(c.sid, STATEMENTS.supply(), "the statement id equals the supply");
        assertEq(c.sid, c.supplyBefore + 1);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the core holds it for sale");
        assertEq(STATEMENTS.creditsOf(c.sid), 80);

        // cost basis is the sum of the credits' cost bases, and the asking price is 150 percent of it (the opening ask)
        (bool held, uint256 basis, uint64 composedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(basis, c.cost);
        assertEq(composedAt, c.at);
        assertEq(ctl.priceOf(c.sid), basis * 15_000 / 10_000, "150 percent of cost");
        uint256[] memory heldIds = core.heldStatements();
        assertEq(heldIds.length, 1);
        assertEq(heldIds[0], c.sid);

        // the five newest credits are still in the pile and in the core, the 80 are gone into the statement
        assertEq(core.pileSize(), 5);
        assertEq(core.pilePage(0, 1)[0], sold[80]);
        assertEq(CREDITS.balanceOf(address(core)), 5);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,) = core.creditInfo(c.ids[i]);
            assertFalse(inPile);
        }

        // a compose pays the caller nothing and leaves the pot as it was
        assertEq(keeper.balance, 0);
        assertEq(core.ethPot(), c.potBefore);
        _solvent();

        // the same page at a basefee far above any cap has the same cost basis
        vm.revertToState(preComposeSnap);
        composeBasefee = 1000 gwei;
        Composed memory high = _composeOnce();
        assertEq(high.sid, c.sid);
        assertEq(high.cost, c.cost);
        (, uint256 basis2,) = core.statementInfo(high.sid);
        assertEq(basis2, c.cost);
        assertEq(ctl.priceOf(high.sid), basis2 * 15_000 / 10_000, "the asking price follows the basis");
        assertEq(keeper.balance, 0);

        // the controller cannot be asked again, there is no full page left
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    /// an unsold statement stays held, for as long as it takes: its asking price falls to the floor and stays there
    function test_compose_unsoldStatementStaysHeldAtTheFloor() public {
        _prepare();
        Composed memory c = _composeOnce();
        (, uint256 basis,) = core.statementInfo(c.sid);
        uint256 pot = core.ethPot();
        _warp(60 days);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        assertEq(core.heldStatements().length, 1);
        assertEq(core.ethPot(), pot, "an unsold statement costs nothing and books nothing");
        assertEq(ctl.priceOf(c.sid), basis * 10_000 / 10_000, "the asking price is at the floor");
        // two months later a buyer still gets it at the floor
        _buy(alice, c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), alice);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    // ------------------------------------------------------------------ sale and buyback

    struct Before {
        uint256 pool;
        uint256 slice;
        uint256 supply;
        uint256 pot;
        uint256 balance;
        uint256 caller;
        uint256 pmCoin;
        uint256 dead;
    }

    /// what the last `_buybackAndCheck` returned to the pot: the largest payment less the payment
    uint256 internal lastResidue;

    /// one real buyback with its effects checked against the real pool. the skim on the swap returns to the pot
    function _buybackAndCheck(address caller) internal returns (uint256) {
        Settings memory s = core.settings();
        Before memory b;
        b.pool = core.ethToBuyback();
        b.slice = b.pool.min(s.buybackSlice);
        b.supply = coin.totalSupply();
        b.pot = core.ethPot();
        b.balance = address(core).balance;
        b.caller = caller.balance;
        b.pmCoin = coin.balanceOf(address(PM));
        b.dead = coin.balanceOf(DEAD);

        vm.fee(1 gwei);
        vm.recordLogs();
        vm.prank(caller);
        core.buyback();
        (uint256 spent, uint256 paid) = _buybackEvent(vm.getRecordedLogs());

        uint256 burned = b.supply - coin.totalSupply();
        assertGt(burned, 0, "real burn: the total supply fell");
        assertEq(b.pmCoin - coin.balanceOf(address(PM)), burned, "the coin came out of the pool and was burned");
        assertEq(coin.balanceOf(address(core)), 0, "the core never holds the coin");
        assertEq(coin.balanceOf(DEAD), b.dead, "burned, not parked");
        assertEq(caller.balance - b.caller, paid, "the caller got the payment");
        // the fee is scaled by the budget spent over the largest budget the setting allows
        assertGe(paid, s.keeperFee * spent / (s.buybackSlice - (600_000 * 1 gwei + s.keeperFee)), "the payment holds the scaled fee");
        assertEq(core.ethToBuyback(), b.pool - spent - paid, "the pot fell by the spend and the payment");
        assertLe(spent + paid, b.slice, "the slice bounds both");
        // the largest payment at the 1 gwei base fee is 600,000 gas plus the keeper fee. the swap spends the whole budget
        uint256 maxPay = 600_000 * 1 gwei + s.keeperFee;
        assertEq(spent, b.slice - maxPay, "the swap spends the whole budget");
        lastResidue = maxPay - paid;
        assertEq(core.ethToBuyback(), b.pool - b.slice + lastResidue, "the unused payment returned to the pot");
        _flush();
        assertGt(core.ethPot(), b.pot, "the skim of the swap came back into the pot");
        assertEq(core.lastBuybackBlock(), block.number);
        assertLe(address(core).balance, b.balance, "the swap spent eth net of what came back");
        _solvent();
        return b.slice;
    }

    /// a buyer takes the statement at the asking price, the core books the split at once, the buyback burns
    function test_sale_buyBookBuyback() public {
        _prepare();
        Composed memory c = _composeOnce();
        (, uint256 basis,) = core.statementInfo(c.sid);
        uint256 step = ctl.priceOf(c.sid);
        assertEq(step, basis * 15_000 / 10_000);

        uint256 pot0 = core.ethPot();
        uint256 back0 = core.ethToBuyback();
        assertEq(_buy(bob, c.sid), step);
        assertEq(STATEMENTS.ownerOf(c.sid), bob, "the buyer holds the statement");
        assertEq(core.heldStatements().length, 0);

        // the split: half to the buyback, half to the pot
        assertEq(core.ethToBuyback() - back0, step / 2);
        assertEq(core.ethPot() - pot0, step - step / 2);
        _solvent();

        // the buyback burns what the share buys: one slice of 1 eth (the upper bound of the slice, the launch value is
        // 0.5 eth), then the delay of 25 blocks, then the rest
        Settings memory sl = core.settings();
        sl.buybackSlice = 1 ether;
        _setSettings(sl);
        assertGt(core.ethToBuyback(), 1 ether, "a page sells for more than two slices of the share");
        vm.roll(block.number + 1);
        assertEq(_buybackAndCheck(buybacker), 1 ether);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 24);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        uint256 left = core.ethToBuyback();
        assertGe(left, step / 2 - 1 ether, "the pool is the share less the first slice");
        assertEq(left - (step / 2 - 1 ether), lastResidue, "plus the unused payment margin");
        while (left > 1 ether) {
            assertEq(_buybackAndCheck(buybacker), 1 ether, "a full slice");
            left = core.ethToBuyback();
            vm.roll(block.number + 25);
        }
        assertEq(_buybackAndCheck(buybacker), left, "the last slice is what is left");
        assertEq(core.ethToBuyback(), lastResidue, "only the unused payment margin is left");
        vm.roll(block.number + 25);
        vm.expectRevert(ICore.SliceTooSmall.selector);
        core.buyback();
    }

    /// the owner lowers the slice, so one sale is bought back over several calls, with the delay between them
    function test_sale_multiSliceBuybackAfterTheOwnerLowersTheSlice() public {
        _prepare();
        Settings memory s = core.settings();
        s.buybackSlice = 0.02 ether;
        s.buybackDelay = 3;
        _setSettings(s);
        (, uint256 price) = _sellStatement(alice);
        assertGt(core.ethToBuyback(), 2 * 0.02 ether);
        assertEq(core.ethToBuyback(), price / 2);
        assertEq(_buybackAndCheck(buybacker), 0.02 ether);

        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 2);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        _buybackAndCheck(buybacker);

        // drained until the pot does not exceed the largest payment (1 gwei: 600,000 gas plus the fee, 0.0011 ether)
        for (uint256 i; i < 30 && core.ethToBuyback() > 0.0011 ether; ++i) {
            vm.roll(block.number + 3);
            uint256 rest = core.ethToBuyback();
            assertEq(_buybackAndCheck(buybacker), rest.min(0.02 ether));
        }
        assertLe(core.ethToBuyback(), 0.0011 ether, "only the unused payment margin is left");
        vm.roll(block.number + 3);
        vm.expectRevert(ICore.SliceTooSmall.selector);
        core.buyback();
    }
}

/// the balance side with the stand in balance module and balance token: redemption of unsold statements, the
/// split, the coin buyback against the real coin, and the balance token bid into the single pile
contract LifecyclePhase2Test is Fixture {
    using FixedPointMathLib for uint256;

    address internal taker;
    address internal xseller;
    address internal alice;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        alice = _user("alice");
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _setBalancePool();
        _skipSniperWindow();
        _fundPot(20 ether);
        _warp(90 hours);
    }

    /// the per point bid pays each credit its score times the unit less the margin
    function _bid(uint256 id) internal view returns (uint256) {
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        return score * UNIT * (10_000 - core.settings().balanceBidMarginBps) / 10_000;
    }

    /// a statement is eligible once its asking price falls to its cost, and the redemption books the whole received
    /// amount into the bid pot
    function _redeemTheStatement() internal returns (Composed memory c, uint256 required) {
        assertEq(core.balanceToken(), address(xt));
        assertEq(core.balanceModule(), address(mod));
        c = _composeOnce();
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(c.sid);
        _makeEligible(c.sid);

        required = core.ratingOf(c.sid) * UNIT;
        uint256 pot = core.balancePot();
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module has the statement");
        assertEq(xt.balanceOf(address(core)) - pot, required);
        assertEq(core.balancePot() - pot, required, "all to the bid pot");
        (bool held,,) = core.statementInfo(c.sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    /// a sold statement can never be redeemed
    function test_phase2_aSaleFirstMakesTheRedemptionRevert() public {
        Composed memory c = _composeOnce();
        _buy(alice, c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), alice);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(c.sid);
        assertEq(core.balancePot(), 0, "no balance token came in");
        _solvent();
    }

    /// the balance token bid pays for credits into the single pile, compose builds a statement from them, and the
    /// statement redeems once its curve reaches cost with everything back to balancePot, so the pot compounds
    function test_phase2_bidComposeBalanceAndCompound() public {
        _redeemTheStatement();
        // top the bid pot up the way balance token fees would arrive: plain balance token booked by skim
        xt.mint(address(core), 1e22);
        core.skim();
        _solvent();

        uint256[] memory ids = _credits(xseller, 80);
        uint256 balancePotBefore = core.balancePot();
        uint256 total;
        for (uint256 i; i < 80; ++i) {
            total += _bid(ids[i]);
        }
        assertLt(total, balancePotBefore, "the pot carries the whole page");

        vm.prank(xseller);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(xseller), total, "paid in the balance token, by each credit's score");
        assertEq(core.balancePot(), balancePotBefore - total);
        assertEq(core.pileSize(), 80);
        // the credit cost basis is in eth (the higher of the balance tokens valued in wei and the eth bid), positive
        uint256 basisSum;
        for (uint256 i; i < 80; ++i) {
            (bool inPile, uint256 cost,) = core.creditInfo(ids[i]);
            assertTrue(inPile);
            assertGt(cost, 0, "an eth cost basis was recorded");
            basisSum += cost;
            assertEq(CREDITS.ownerOf(ids[i]), address(core));
        }
        _solvent();

        // compose the pile. the caller receives nothing, the eth pot is unchanged, the basis is the sum of eth costs
        uint256 supply0 = STATEMENTS.supply();
        uint256 ethPot0 = core.ethPot();
        uint256 keeper0 = keeper.balance;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply0 + 1;
        {
            assertEq(STATEMENTS.supply(), sid);
            assertEq(STATEMENTS.ownerOf(sid), address(core), "held by the core");
            assertEq(core.pileSize(), 0);
            (bool held, uint256 basis,) = core.statementInfo(sid);
            assertTrue(held);
            assertEq(basis, basisSum, "the basis is the sum of the credits' eth cost bases");
            assertEq(keeper.balance, keeper0);
            assertEq(core.ethPot(), ethPot0);
            // the statement sells for eth on the curve, so it is not eligible to redeem yet
            vm.expectRevert(ICore.NotEligible.selector);
            core.redeemStatement(sid);
        }

        // once the curve reaches cost the statement redeems, everything to balancePot
        _makeEligible(sid);
        uint256 required = core.ratingOf(sid) * UNIT;
        uint256 balancePot1 = core.balancePot();
        core.redeemStatement(sid);
        assertEq(core.balancePot(), balancePot1 + required, "all of it back to balancePot");
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
        // compounding: the pot ends above where it stood before the bids were paid
        assertEq(core.balancePot(), balancePotBefore - total + required);
        assertGt(core.balancePot(), balancePotBefore, "compounded");
        assertGt(required, total);
        _solvent();
    }

    /// a module that underpays reverts the redemption and changes nothing, however little it is short
    function test_phase2_hostileBalanceModuleUnderpaysReverts() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        bytes32 before = keccak256(abi.encode(core.balancePot(), xt.balanceOf(address(core))));

        // one basis point under the slippage floor
        mod.setPayBps(10_000 - core.settings().redeemSlippageBps - 1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left the core");
        (bool held,,) = core.statementInfo(c.sid);
        assertTrue(held);

        // all of it withheld
        mod.setPayBps(0);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(c.sid);

        // a module that lowers the unit it pays by after it was set; the core holds the unit from set time
        mod.setPayBps(10_000);
        mod.setUnitPerPoint(1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(c.sid);

        assertEq(keccak256(abi.encode(core.balancePot(), xt.balanceOf(address(core)))), before);
        // the statement is still good: a buyer could take it right now
        uint256 snap = vm.snapshotState();
        _buy(alice, c.sid);
        vm.revertToState(snap);

        // an honest module goes through afterwards
        mod.setUnitPerPoint(UNIT);
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod));
        _solvent();
    }
}

/// the whole loop twice on the real stack, with solvency and a falling coin supply checked after every step
contract LifecycleNarrativeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal taker;
    address internal xseller;
    address internal alice;
    address internal bob;
    address internal buybacker;

    uint256 internal lastSupply;
    uint256 internal steps;
    uint256 internal burnedByBuyback;
    uint256 internal burnedByAuction;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        alice = _user("alice");
        bob = _user("bob");
        buybacker = _user("buybacker");
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _setBalancePool();
        _skipSniperWindow();
        lastSupply = coin.totalSupply();
    }

    /// solvency and a coin supply that never rises, after every step
    function _check() internal {
        _solvent();
        uint256 supply = coin.totalSupply();
        assertLe(supply, lastSupply, "the coin supply only falls");
        lastSupply = supply;
        ++steps;
    }

    /// credits sold through the eth door at the rate: every credit is paid the same price, which falls with each credit
    function _sellAtTheRate(uint256 n) internal {
        uint256[] memory ids = _credits(seller, n);
        uint256 each = core.ethRate();
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        // every credit of the batch is paid the rate at its own point of the falling rate, never above the first
        assertLe(seller.balance - before, each * n);
        assertGt(seller.balance - before, each * n * 8 / 10);
        _check();
    }

    function _composeNow() internal returns (uint256 sid, uint64 at) {
        uint256 size = core.pileSize();
        if (size < 80) _fillEthPile(80 - size);
        _check();
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
        assertEq(STATEMENTS.supply(), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "held by the core");
        (, uint256 cost,) = core.statementInfo(sid);
        assertEq(ctl.priceOf(sid), cost * ctl.startBps() / 10_000, "at the start price of the controller");
        at = uint64(block.timestamp);
        _check();
    }

    function _buyListing(uint256 id) internal {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(id);
        _warpUntilCeiling(id, price);
        vm.prank(keeper);
        core.buyListing(price, abi.encodeCall(ICreditStrategy.sellTargetNFT, (id)), id, STRATEGY);
        assertEq(CREDITS.ownerOf(id), address(core));
        _check();
    }

    /// a buyer takes the statement through the controller, the core books the sale, the split is exact
    function _sale(uint256 sid) internal {
        uint256 pot0 = core.ethPot();
        uint256 back0 = core.ethToBuyback();
        uint256 price = _buy(bob, sid);
        assertEq(STATEMENTS.ownerOf(sid), bob);
        assertEq(core.ethToBuyback() - back0, price / 2);
        assertEq(core.ethPot() - pot0, price - price / 2);
        _check();
    }

    function _buybacks() internal {
        // a pot that does not exceed the largest payment (0.0065 ether at the launch values) is left for the next sale
        for (uint256 i; i < 3 && core.ethToBuyback() > 0.01 ether; ++i) {
            vm.roll(block.number + 25);
            uint256 supply0 = coin.totalSupply();
            vm.prank(buybacker);
            core.buyback();
            assertLt(coin.totalSupply(), supply0, "every buyback burns");
            burnedByBuyback += supply0 - coin.totalSupply();
            _check();
        }
    }

    /// the statement nobody bought: still held after the sale of the other, redeemed once its price falls to its cost
    function _redeem(uint256 sid, uint64) internal {
        assertTrue(_isHeld(sid), "no buyer, so still held");
        _makeEligible(sid);
        uint256 required = core.ratingOf(sid) * UNIT;
        uint256 pot0 = core.balancePot();
        core.redeemStatement(sid);
        assertEq(core.balancePot() - pot0, required, "all to the bid pot");
        _check();
    }

    function _bidForCredits() internal {
        uint256[] memory ids = _credits(xseller, 3);
        vm.prank(xseller);
        core.sellForBalance(ids);
        assertGt(xt.balanceOf(xseller), 0);
        _check();
    }

    function test_narrative_theWholeLoopTwice() public {
        uint256[2] memory listed = [LISTED_A, LISTED_B];
        for (uint256 round; round < 2; ++round) {
            // fees from real swaps
            _fundPot(20 ether);
            _check();
            uint256 pot0 = core.ethPot();
            _buyCoin(funder, 5 ether);
            assertGt(core.ethPot(), pot0, "a real swap fed the pot");
            _check();
            // the long waits of the first round let the limit climb to what the pot can carry (a flat credit would cost
            // eth, not milli eth). the owner puts it back to the opening price of the launch
            if (round == 1) {
                uint256 opening = core.RATE_START();
                // the long idle waits let the bid climb well above the opening price (the pot's clamp is lower than
                // before the per redemption reserve took a share of fees, so the climb reaches a few times the opening,
                // not ten times)
                assertGt(core.ethRate(), 2 * opening);
                vm.prank(owner);
                core.setRate(opening);
                _check();
            }
            // buys at the flat limit through both doors: the bid, then the strategy listing
            _sellAtTheRate(10);
            _buyListing(listed[round]);
            // two statements, both held: one gets a buyer, one gets none
            (uint256 sold,) = _composeNow();
            (uint256 aged, uint64 agedAt) = _composeNow();
            assertEq(core.heldStatements().length, 2);
            _sale(sold);
            assertTrue(_isHeld(aged));
            _buybacks();
            _redeem(aged, agedAt);
            _bidForCredits();
            assertEq(core.heldStatements().length, 0);
        }
        assertGt(burnedByBuyback, 0);
        assertLt(coin.totalSupply(), 1_000_000_000e18, "the supply fell over the loops");
        assertEq(coin.balanceOf(address(core)), 0);
        assertGt(steps, 25);
    }
}

/// the owner adapts the system live: the drop per credit, the sale floor and the sale split change in the
/// middle of a run. held statements follow the new numbers at once, and old and new statements behave alike
contract LifecycleOwnerAdaptsTest is Fixture {
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public override {
        super.setUp();
        alice = _user("alice");
        bob = _user("bob");
        carol = _user("carol");
        _skipSniperWindow();
    }

    function _composeFresh() internal returns (uint256 sid, uint256 cost) {
        uint256 size = core.pileSize();
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
        (, cost,) = core.statementInfo(sid);
        _solvent();
    }

    function test_narrative_theOwnerAdaptsTheSystemLive() public {
        _fundPot(20 ether);
        _warp(90 hours);

        // old numbers: a drop of 0.5 percent, a 75 percent floor and a 150 percent ask, an even split of the sale
        Settings memory old = core.settings();
        assertEq(old.dropPerCreditBps, 50);
        assertEq(old.saleFloorBps, 10_000);
        assertEq(old.saleToBuybackBps, 5_000);

        // two statements held under the old numbers
        (uint256 s1, uint256 cost1) = _composeFresh();
        (uint256 s2, uint256 cost2) = _composeFresh();
        assertEq(ctl.priceOf(s1), cost1 * 15_000 / 10_000);
        assertEq(ctl.priceOf(s2), cost2 * 15_000 / 10_000);

        // the owner changes three numbers in one call, effective at once
        Settings memory s = core.settings();
        s.dropPerCreditBps = 100;
        s.saleFloorBps = 20_000;
        s.saleToBuybackBps = 8_000;
        vm.expectEmit(address(core));
        emit ICore.SettingsSet(s);
        _setSettings(s);
        _solvent();

        // the next fill drops the rate by the new number
        uint256[] memory fresh = _credits(seller, 2);
        {
            uint256 quote = core.ethRate();
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(fresh[0]));
            assertEq(seller.balance - before, quote, "paid by the new numbers");
            assertLe(core.rateAtCheckpoint(), quote, "dropped by the new number or held at the minute floor");
        }

        // the held statements follow the new floor at once, nobody reprices anything
        assertEq(ctl.priceOf(s1), cost1 * 20_000 / 10_000, "the old statement now asks 200 percent of its cost");
        assertEq(ctl.priceOf(s2), cost2 * 20_000 / 10_000, "the old statement now asks 200 percent of its cost");

        // a statement composed after the change asks the new floor, from the credits bought on both numbers
        (uint256 s3, uint256 cost3) = _composeFresh();
        assertEq(ctl.priceOf(s3), cost3 * 20_000 / 10_000);
        assertEq(core.heldStatements().length, 3);

        // sales under the new split: 80 percent of every sale, old statements included
        {
            uint256 pot0 = core.ethPot();
            uint256 back0 = core.ethToBuyback();
            uint256 price1 = _buy(alice, s1);
            uint256 price2 = _buy(bob, s2);
            uint256 price3 = _buy(carol, s3);
            assertEq(STATEMENTS.ownerOf(s1), alice);
            assertEq(STATEMENTS.ownerOf(s2), bob);
            assertEq(STATEMENTS.ownerOf(s3), carol);
            assertEq(price1, cost1 * 20_000 / 10_000);
            uint256 total = price1 + price2 + price3;
            assertEq(core.ethToBuyback() - back0, price1 * 8_000 / 10_000 + price2 * 8_000 / 10_000 + price3 * 8_000 / 10_000, "80 percent to the buyback");
            assertEq(core.ethPot() - pot0, total - (price1 * 8_000 / 10_000 + price2 * 8_000 / 10_000 + price3 * 8_000 / 10_000), "the rest to the pot");
        }
        assertEq(core.heldStatements().length, 0);
        _solvent();

        // and the buyback burns the larger share
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 25);
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supply);
        _solvent();
    }
}
