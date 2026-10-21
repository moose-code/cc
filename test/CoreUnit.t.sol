// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, Stack, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";

/// shared helpers of the core unit suites. everything runs against the LIVE system on a mainnet fork (LiveFixture):
/// the live Core, controller, coin, hook, pool, Credits, Statements, CreditStrategy and Seaport, read at setUp. a test
/// that needs more eth in the pot donates through `fund()`, which adds it to the pot whole
abstract contract CoreBase is LiveFixture {
    using stdStorage for StdStorage;

    /// @dev the account that sells credits in these suites
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = seller;
        // the forbidden target list and the fresh core deploy mechanics tests (`mk`) read `lc`; populate it from the
        // live system. a Core `mk` builds is a successor style deploy, which the brief allows for the constructor checks
        _initLiveConfig();
        // the `_buyRaw` tests drive the live Core through the test raw listing adapter; LiveFixture.setUp does not set it
        _approveRawAdapter();
    }

    /// @dev funds the core with `amount` of eth from a plain account through `fund`. the pot is exactly `amount`
    /// higher afterwards
    function _fund(uint256 amount) internal {
        vm.deal(funder, funder.balance + amount);
        vm.prank(funder);
        core.fund{value: amount}();
    }

    function _listing(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _page(uint256 first, uint256 fill) internal pure returns (uint256[80] memory ids) {
        for (uint256 i; i < 80; ++i) {
            ids[i] = fill;
        }
        ids[0] = first;
    }

    /// @dev puts `n` fresh credits of `who` in the eth pile through the sell door, with the pot topped up first
    function _sellN(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(who, n);
        _fund(20 ether);
        vm.prank(who);
        core.sellForEth(ids);
    }

    /// @dev builds a launch core with other constructor arguments. external, so a revert of the constructor can be
    /// expected
    function mk(address owner_, address ctl_, address payee_, Stack memory st, uint256 r, Settings memory s)
        external
        returns (ICore)
    {
        return Prod.newCore(owner_, buildConfig(lc, owner_, address(0)), owner_, ctl_, payee_, st, r, s);
    }
}

contract CoreUnitTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                              parameters
    //////////////////////////////////////////////////////////////*/

    function _stack5(Stack memory st, uint256 which, address to) internal pure returns (Stack memory bad) {
        bad = Stack(st.poolManager, st.hook, st.tickSpacing, st.poolFee, st.factory, st.locker, st.escrow);
        if (which == 0) bad.poolManager = to;
        if (which == 1) bad.hook = to;
        if (which == 2) bad.factory = to;
        if (which == 3) bad.locker = to;
        if (which == 4) bad.escrow = to;
    }

    // promise: INTEGRATION ZeroAddress on the constructor and on setController, BadStack on the constructor
    function test_constructorAndSetControllerRejectZero() public {
        Stack memory st = lc.stack;
        uint256 r = lc.rateStart;
        Settings memory s = lc.settings;
        address payee_ = lc.payee;
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.mk(address(0), address(ctl), payee_, st, r, s);
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.mk(owner, address(ctl), address(0), st, r, s);
        // every address of the stack is required
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(ICore.ZeroAddress.selector);
            this.mk(owner, address(ctl), payee_, _stack5(st, i, address(0)), r, s);
        }
        Stack memory flat = _stack5(st, 99, address(0));
        flat.tickSpacing = 0;
        vm.expectRevert(ICore.BadStack.selector);
        this.mk(owner, address(ctl), payee_, flat, r, s);
        flat.tickSpacing = 32_768;
        vm.expectRevert(ICore.BadStack.selector);
        this.mk(owner, address(ctl), payee_, flat, r, s);
        flat.tickSpacing = 32_767;
        this.mk(owner, address(ctl), payee_, flat, r, s);
    }

    // promise: INTEGRATION NoCode on the constructor
    /// every stack member must be a contract
    function test_constructorRequiresCodeAtTheStack() public {
        Stack memory st = lc.stack;
        uint256 r = lc.rateStart;
        Settings memory s = lc.settings;
        address nobody = makeAddr("no code");
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, nobody));
            this.mk(owner, address(ctl), lc.payee, _stack5(st, i, nobody), r, s);
        }
        // the coin has no code at construction time and that is fine
        ICore c = this.mk(owner, address(ctl), lc.payee, st, r, s);
        assertEq(c.COIN().code.length, 0);
    }

    // promise: INTEGRATION BadRate on the constructor
    /// the opening bid is a deploy input bounded to [1, uint64.max] wei per credit
    function test_rateStartBounds() public {
        Settings memory s = lc.settings;
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(ctl), lc.payee, lc.stack, 0, s);
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(ctl), lc.payee, lc.stack, uint256(type(uint64).max) + 1, s);
        ICore lo = this.mk(owner, address(ctl), lc.payee, lc.stack, 1, s);
        s.rateCap = type(uint64).max;
        ICore hi = this.mk(owner, address(ctl), lc.payee, lc.stack, type(uint64).max, s);
        assertEq(lo.RATE_START(), 1);
        assertEq(lo.rateAtCheckpoint(), 1);
        assertEq(hi.RATE_START(), type(uint64).max);
        assertEq(hi.rateAtCheckpoint(), type(uint64).max);
    }

    /*//////////////////////////////////////////////////////////////
                           fee intake and fund
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 4 fee intake: book, fund and UseFund (inv 10)
    /// eth the hook pushes after a real swap is booked at the next book. a plain send from anyone else reverts and `fund`
    /// adds to the pot whole
    function test_bookCountsHookEth_fundAddsTheRest() public {
        _skipSniperWindow();
        // the whole fee receipt goes to the pot here, with no redeem burn share taken out first
        Settings memory s0 = core.settings();
        s0.feeToRedeemBurnBps = 0;
        _setSettings(s0);
        // the live pot is non empty: assert the booked hook fee raised it, not an absolute wei amount
        uint256 potBefore = core.ethPot();
        _buyCoin(funder, 1 ether);
        uint256 pot = core.ethPot();
        assertGt(pot, potBefore, "the hook fee a real buy pushed is booked into the pot");
        _solvent();

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(core).call{value: 2 ether}("");
        assertFalse(ok, "a plain send reverts");
        assertEq(core.ethPot(), pot, "a refused send leaves the pot");

        vm.prank(alice);
        core.fund{value: 2 ether}();
        assertEq(core.ethPot(), pot + 2 ether, "fund adds to the pot whole");
        core.book();
        assertEq(core.ethPot(), pot + 2 ether, "nothing left to book");
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                               rate climb
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                              sell door
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION Slippage
    function test_sellForEth_minOut() public {
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        // the payout by the hand formula, not bidOf
        uint256 price = (core.ethRate() * _scoreOf(id)) / RATE_SCORE;
        assertTrue(_scoreOf(id) != RATE_SCORE, "the fork credit's score is not refScore");

        vm.prank(alice);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForEth(_one(id), price + 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id), price);
        assertEq(alice.balance - before, price);
    }

    // promise: INTEGRATION PotTooSmall and ZeroAmount
    // test_tinyPotSellsItsWeiAndBuysNothing moved to CoreControlledUnitTest (is Fixture): it needs the eth pot drained
    // to 0 and then to exactly 1 wei, and a credit whose score equals refScore (a 1 wei bid). the live pot is large and
    // non empty, reserveWei is a uint64 (at most ~18.4 ether) so the pot cannot be forced under the reserve, and the
    // live credit scores cannot be chosen, so this promise is only reachable on a freshly deployed Core

    // promise: INTEGRATION Empty, ZeroId, NotOwner, Retired on sellForEth
    function test_sellForEth_guards() public {
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);

        vm.prank(alice);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForEth(none);

        vm.prank(alice);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForEth(_one(0));

        // the live pot is funded, so the owner guard, not PotTooSmall, is what a non owner hits
        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForEth(ids);

        // not approved
        address bob = _user("bob");
        uint256 id = _heldCredit(0);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, bob, id);
        vm.prank(bob);
        vm.expectRevert();
        core.sellForEth(_one(id));
    }

    /*//////////////////////////////////////////////////////////////
                         controller is only read
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                           buyListing: real strategy
    //////////////////////////////////////////////////////////////*/

    /// funds the pot and warps hour by hour until the ceiling clears the listing price of id. the pot is large enough
    /// that it covers four pages at the rate cap, so the pot multiplier stays at its cap across the climb and the idle
    /// loosening does not slow as the rate rises (decision 128 variant d: pages counted at the current rate)
    function _fundAndClimb(uint256 id, uint256 price) internal {
        _fund(50 ether);
        _warpUntilCeiling(id, price);
    }

    // promise: INTEGRATION AboveBid
    function test_buyListing_aboveCeilingReverts() public {
        _fund(10 ether);
        // the subject is the AboveBid guard, not the rate. reach the state from the price side: post the raw listing one
        // wei above the credit's live scaled bid, so the buy reverts AboveBid at the live rate without pranking the rate
        uint256 price = core.bidOf(LISTED_A) + 1;
        vm.prank(keeper);
        vm.expectRevert(ICore.AboveBid.selector);
        _buyRaw(price, _listing(LISTED_A), LISTED_A, STRATEGY);
    }

    struct PayRun {
        uint256 paid;
        uint256 gap;
        uint256 used;
    }

    /// moves credit `id` from the strategy to a fresh `ListingTarget`
    function _listingTarget(uint256 id) internal returns (ListingTarget t) {
        t = new ListingTarget();
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
    }

    /// one `buyListing` of credit `id` through `adapter` with `params`, at base fee `bf` and gas price `gp`, where the
    /// adapter prices the listing at `cost`. checks the books: the keeper gets the payment, the pot pays the cost and the
    /// payment, the cost basis is both
    function _payRun(address adapter, bytes memory params, uint256 id, uint256 cost, uint256 bf, uint256 gp)
        internal
        returns (PayRun memory r)
    {
        vm.fee(bf);
        vm.txGasPrice(gp);
        // the per-credit bid: the rate scaled by the credit's score over refScore (the hand formula, not bidOf)
        uint256 ceiling = (core.ethRate() * _scoreOf(id)) / RATE_SCORE;
        r.gap = ceiling - cost;
        uint256 pot = core.ethPot();
        // the live buy to artist royalty leg (buyToArtistBps, zero in the old fixture) is paid from the pot on the buy
        // and folded into the cost basis; recomputed from the live settings rather than pranked to zero
        uint256 toArtist = cost * core.settings().buyToArtistBps / 10_000;
        uint256 before = keeper.balance;
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(adapter, id, params);
        r.used = g - gasleft();
        r.paid = keeper.balance - before;
        _assertListingPay(r.paid, r.gap);
        assertEq(
            core.ethPot(), pot - cost - toArtist - r.paid, "the pot pays the cost, the artist royalty and the payment"
        );
        (, uint256 basis,) = core.creditInfo(id);
        assertEq(basis, cost + toArtist + r.paid, "the cost basis is the cost, the artist royalty and the payment");
        assertLe(cost + r.paid, ceiling, "the engine's own spend is at most its bid");
        _solvent();
    }

    // promise: SPEC 6 buyListing caps value at the credit's scaled bid and the payment at that bid less value, at score != refScore
    function test_buyListing_capAndPaymentAtScoreNotRefScore() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertTrue(_scoreOf(LISTED_A) != RATE_SCORE, "the listed credit's score is not refScore");
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        // the credit's bid by the hand formula, not bidOf
        uint256 handBid = (core.ethRate() * _scoreOf(LISTED_A)) / RATE_SCORE;
        PayRun memory r = _payRun(strategyAdapter, "", LISTED_A, price, 1 gwei, 1 gwei);
        assertEq(r.gap, handBid - price, "the gap is the scaled bid less the listing price");
        (, uint256 basis,) = core.creditInfo(LISTED_A);
        assertLe(price + r.paid, handBid, "the engine's own spend is at most the scaled bid");
        // the basis is the listing plus the keeper payment plus the live artist royalty (zero in the old fixture)
        uint256 toArtist = price * core.settings().buyToArtistBps / 10_000;
        assertEq(basis, price + toArtist + r.paid, "and is the listing, the artist royalty and the keeper payment");
    }

    // promise: SPEC 1 keeper doors pay counted gas plus keeperFee
    /// the payment is the gas counted at the base fee plus the whole keeper fee, on the real strategy path. the counted
    /// gas covers the gas used and the transaction base cost, and scales with the base fee
    function test_buyListing_paysCountedGasAtTheBaseFeePlusTheFee() public {
        _assertListingGasPayment();
    }

    // promise: the first capped purchase reimburses gas for initial budget accounting as well as the listing
    function test_buyListing_countedGasCoversFirstCappedBucket() public {
        Settings memory s = core.settings();
        s.spendCapBps = 100;
        _setSettings(s);
        _assertListingGasPayment();
    }

    function _assertListingGasPayment() internal {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertGt(price, 0, "the strategy lists the credit at the live pin");
        // no CreditScore mock (addendum 3): the gas payment math is score independent, and _fundAndClimb lifts the bid
        // of the real credit above the listing so the gap does not bind
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        uint256 snap = vm.snapshotState();
        PayRun memory a = _payRun(strategyAdapter, "", LISTED_A, price, 1 gwei, 1 gwei);
        uint256 fee = core.settings().keeperFee;
        assertGt(a.gap, a.paid, "the gap does not bind");
        assertEq((a.paid - fee) % 1 gwei, 0, "whole gas units");
        uint256 counted = (a.paid - fee) / 1 gwei;
        assertGe(counted, a.used + 21_000, "the counted gas covers the gas used and the transaction base cost");
        // the Core counts a conservative gas figure that over-estimates the actual work (the same over-estimate exists
        // on the fresh fixture, under 120k). on the live strategy path the full pile makes the post-count work heavier,
        // so the over-estimate is about 128k; the bound carries that with margin
        assertLe(counted, a.used + 150_000, "and carries no more than the counted overestimate above the work");
        emit log_named_uint("buyListing strategy path: gas used", a.used);
        emit log_named_uint("buyListing strategy path: gas counted", counted);
        vm.revertToState(snap);
        PayRun memory b = _payRun(strategyAdapter, "", LISTED_A, price, 2 gwei, 2 gwei);
        assertEq(b.paid - fee, 2 * (a.paid - fee), "the gas part scales with the base fee");
    }

    // promise: SPEC 1 buyListing pays the caller at most the gap
    /// a gap smaller than the payment is the payment, so cost plus payment equals the bid. a zero gap pays nothing
    function test_buyListing_paymentIsCappedAtTheGap() public {
        _fund(10 ether);
        uint256[4] memory gaps = [uint256(0), 1, 1000, 0.0004 ether];
        for (uint256 i; i < gaps.length; ++i) {
            uint256 id = _heldCredit(1 + i);
            // no CreditScore mock (addendum 3): bidOf reads the credit's real score, and the gap capping is score
            // independent (the listing is priced at the real ceiling less the gap)
            uint256 ceiling = core.bidOf(id);
            ListingTarget t = _listingTarget(id);
            uint256 snap = vm.snapshotState();
            PayRun memory r = _payRun(
                rawAdapter,
                _raw(address(t), ceiling - gaps[i], abi.encodeCall(ListingTarget.fill, (id, 0))),
                id,
                ceiling - gaps[i],
                1 gwei,
                1 gwei
            );
            assertEq(r.paid, gaps[i], "the payment is the gap");
            (, uint256 basis,) = core.creditInfo(id);
            // cost plus payment is the bid; the basis also carries the live artist royalty (zero in the old fixture)
            uint256 toArtist = (ceiling - gaps[i]) * core.settings().buyToArtistBps / 10_000;
            assertEq(basis, ceiling + toArtist, "cost plus payment is the bid, plus the artist royalty");
            vm.revertToState(snap);
        }
    }

    // promise: INTEGRATION CallFailed
    function test_buyListing_failedCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _fundAndClimb(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        // the delivered-wrong-id leg pays priceB for LISTED_A, so LISTED_A's bid must also cover priceB at the live rate
        if (priceB > priceA) _warpUntilCeiling(LISTED_A, priceB);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();
        uint256 size0 = core.pileSize();

        // wrong value, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        _buyRaw(priceA - 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        // wrong calldata, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        _buyRaw(priceA, _listing(LISTED_B), LISTED_A, STRATEGY);

        // asked for one id but the call delivers another.
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        _buyRaw(priceB, _listing(LISTED_B), LISTED_A, STRATEGY);

        assertEq(core.ethPot(), pot);
        assertEq(core.ethRate(), rate);
        assertEq(core.pileSize(), size0, "the failed buys changed the pile by nothing");

        // an unrelated buy still goes through.
        vm.prank(keeper);
        _buyRaw(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(core.pileSize(), size0 + 1, "the successful buy added one to the pile");

        // the core never buys a credit it already owns.
        vm.prank(keeper);
        vm.expectRevert(ICore.AlreadyOwned.selector);
        _buyRaw(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    // promise: INTEGRATION AdapterNotAllowed, ForbiddenTarget
    /// an adapter the owner has not approved is refused, and every address the core itself refuses is not callable as the
    /// target of an approved adapter
    function test_buyListing_adapterAndTargetGuards() public {
        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(ICore.AdapterNotAllowed.selector);
        core.buyListing(address(0xABCD), LISTED_A, "");

        address[11] memory refused = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            lc.stack.hook,
            Mainnet.POOL_MANAGER,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            Mainnet.PERMIT2,
            Mainnet.UNIVERSAL_ROUTER
        ];
        vm.startPrank(keeper);
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            _buyRaw(1, "", LISTED_A, refused[i]);
        }
        vm.expectRevert(ICore.ZeroId.selector);
        _buyRaw(1, "", 0, STRATEGY);
        vm.expectRevert(ICore.ZeroAmount.selector);
        _buyRaw(0, "", LISTED_A, STRATEGY);
        vm.stopPrank();
    }

    // promise: INTEGRATION PotTooSmall
    /// the listing is real and the pot affords it: a value above the pot fails first with `PotTooSmall`, a value the
    /// pot holds buys
    function test_buyListing_potCheck() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fund(price * 4);
        // lift the credit's bid above the whole pot (the owner lifts the rate cap and the bid climbs, the Core's real
        // setter path) so a value above the pot's room but still within the bid reaches the `PotTooSmall` guard rather
        // than the `AboveBid` guard. the live pot is large and the live score need not exceed 100 points, so a fixed
        // multiple of the listing price would not clear the pot
        _warpUntilCeiling(LISTED_A, core.ethPot() + 1);
        uint256 room = core.ethPot() - core.reserve();
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(room + 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        vm.prank(keeper);
        _buyRaw(price, _listing(LISTED_A), LISTED_A, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                       buyListing: hostile targets
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION BadCost
    function test_buyListing_hostileTargetThatKeepsEthReverts() public {
        HostileTarget hostile = new HostileTarget();
        _fund(10 ether);
        uint256 potBefore = core.ethPot();
        uint256 before = address(core).balance;
        uint256 hostileBefore = address(hostile).balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        _buyRaw(1 gwei, "", LISTED_A, address(hostile));
        assertEq(address(core).balance, before, "core balance");
        assertEq(address(hostile).balance, hostileBefore, "the eth went nowhere");
        assertEq(core.ethPot(), potBefore, "pot unchanged");
    }

    function _probe(uint256 id, uint256 mode) internal returns (ProbeTarget p) {
        p = new ProbeTarget(address(core));
        p.setMode(mode);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(p), id);
    }

    // promise: INTEGRATION UseFund
    /// a target that refunds part of what it was paid sends eth to the core, which `receive` refuses: the buy reverts and
    /// nothing moves
    function test_buyListing_aRefundFromTheTargetRevertsTheBuy() public {
        uint256 id = _heldCredit(0);
        ProbeTarget p = _probe(id, 5);
        _fund(10 ether);
        uint256 value = core.bidOf(id) * 3 / 4;
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        _buyRaw(value, abi.encodeCall(ProbeTarget.fill, (id, 0)), id, address(p));
        assertEq(core.ethPot(), pot);
        assertEq(address(core).balance, bal);
        assertEq(CREDITS.ownerOf(id), address(p));
        _solvent();
    }

    // promise: INTEGRATION Reentrancy, NoCredit on buyListing
    /// reentry from the target into every guarded door fails, and a wrong or doubled delivery reverts the buy
    function test_buyListing_probeModes() public {
        _fund(10 ether);
        for (uint256 m; m <= 8; ++m) {
            uint256 id = _heldCredit(m);
            ProbeTarget p = _probe(id, m);
            // no CreditScore mock (addendum 3): size the honest payment to half the credit's real bid, so it is always
            // under the bid whatever the live score
            vm.deal(address(p), 1 ether);
            uint256 value = (core.bidOf(id) / 2).min(core.ethPot() / 20);
            vm.prank(keeper);
            try core.buyListing(
                rawAdapter, id, _raw(address(p), value, abi.encodeCall(ProbeTarget.fill, (id, _heldCredit(9 + m))))
            ) {
                assertTrue(p.honest(m), "a hostile mode succeeded");
            } catch {
                assertFalse(p.honest(m), "an honest mode failed");
            }
            assertEq(p.reentered(), 0, "a reentry got through");
            if (m == 7 || m == 8) assertGt(p.attempts(), 0, "the target did try");
            _solvent();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                owner
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION OnlyOwner
    function test_owner_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(ctl));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setBalanceModule(address(mod));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.addAdapter(address(0x1234));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.removeAdapter(strategyAdapter);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockController();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockBalanceModule();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockAdapters();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  views
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                               compose guards
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION NotReady is a controlled-pile promise (a page under 80): the live pile is full at the pin,
    // so it is proven on the fresh fixture in CoreControlledUnitTest.test_compose_notReady

    // promise: INTEGRATION NotInPile, NotHeld, BadStatement on compose
    /// the subject is the Core's defense against a misbehaving controller that names bad pages. the honest live
    /// controller never does, so a scripted controller double is selected on the live Core by owner prank, the same
    /// treatment the hostile balance module tests get (the controller is not a live contract for this subject). the
    /// live pile is non empty, so the counts below are relative to the pile at the pin
    function test_compose_controllerCannotNameBadPages() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256 size0 = core.pileSize();
        uint256[] memory ids = _sellN(alice, 2);

        // an id that is in no pile
        scripted.setPage(true, _page(ids[0], 777_777), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, 777_777));
        core.compose();

        // a duplicate: the second occurrence is no longer in the pile
        scripted.setPage(true, _page(ids[0], ids[0]), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, ids[0]));
        core.compose();

        // id zero is the null sentinel and is never in a pile
        scripted.setPage(true, _page(0, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, 0));
        core.compose();

        // a given format above 7
        scripted.setPage(true, _page(ids[0], ids[1]), 0);
        vm.expectRevert(ICore.BadFormat.selector);
        core.compose(8);

        // not ready and a reverting controller
        scripted.setPage(false, _page(ids[0], ids[1]), 0);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
        scripted.setRevertPage(true);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();

        // a reverting controller blocks nothing else
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileSize(), size0 + 3);
    }

    // promise: INTEGRATION Composed price is 0 when the controller's priceOf fails
    /// a controller whose `priceOf` reverts does not block a compose, and the event carries price 0. the same
    /// controller answering 777 puts 777 in the event
    function test_compose_priceOfRevertingControllerLogsZero() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256[] memory ids = _sellN(alice, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        scripted.setPage(true, page, 0);
        scripted.setPrice(777, false);
        uint256 sid = STATEMENTS.supply() + 1;
        uint256 snap = vm.snapshotState();
        assertEq(_composedPrice(), 777, "the controller's price");
        vm.revertToState(snap);
        scripted.setPrice(777, true);
        assertEq(_composedPrice(), 0, "a reverting priceOf logs 0");
        assertEq(STATEMENTS.supply(), sid, "the compose landed");
    }

    /// the `price` word of the `Composed` log of one `compose()`
    function _composedPrice() internal returns (uint256 price) {
        vm.recordLogs();
        core.compose();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.Composed.selector) continue;
            (,,, price) = abi.decode(logs[i].data, (uint256[80], uint8, uint256, uint256));
            return price;
        }
        revert("no Composed log");
    }

    // promise: inv 17 the pile links stay valid
    /// the one compose of this suite with a scripted page: credits from the middle of the pile, in a different
    /// order than the pile. the controller's format 7 is ignored and the statement takes the derived format. the list
    /// stays intact around them
    function test_compose_pullsFromTheMiddleAndKeepsTheListIntact() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256 size0 = core.pileSize();
        uint256[] memory ids = _sellN(alice, 85);
        assertEq(core.pileSize(), size0 + 85);

        // leave the first, a few middle ones and the last in the pile.
        uint256[5] memory left = [uint256(0), 17, 40, 63, 84];
        uint256[80] memory page;
        uint256 n;
        for (uint256 i; i < 85; ++i) {
            bool stays;
            for (uint256 j; j < 5; ++j) {
                if (left[j] == i) stays = true;
            }
            if (!stays) page[n++] = ids[i];
        }
        assertEq(n, 80);
        (page[0], page[79]) = (page[79], page[0]);
        scripted.setPage(true, page, 7);
        uint256 supply = STATEMENTS.supply();
        vm.expectCall(
            address(STATEMENTS), abi.encodeWithSelector(STATEMENTS.compose.selector, page, defaultFormat(page[0]))
        );
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supply + 1);

        // the 80 named credits left the pile; the five left behind sit after the pre existing live entries, in their
        // sell order (the FIFO append put the 85 behind the pre existing pile, so ids[0] follows the live tail). verify
        // the links by walking from ids[0] through the remaining four, and that ids[84] is the new tail
        assertEq(core.pileSize(), size0 + 5);
        (bool inPile0,,) = core.creditInfo(ids[0]);
        assertTrue(inPile0, "ids[0] stays in the pile");
        uint256[] memory chain = core.pilePage(ids[0], 4);
        assertEq(chain.length, 4);
        for (uint256 j = 1; j < 5; ++j) {
            assertEq(chain[j - 1], ids[left[j]], "the left behind credits keep their order");
        }
        assertEq(core.pilePage(ids[84], 1).length, 0, "ids[84] is the tail");

        // a new arrival lands behind the old tail.
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pilePage(ids[84], 1)[0], more[0]);
        assertEq(core.pileSize(), size0 + 6);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         doors that need no module
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION NotForSale, NotHeld
    /// the statement doors with no statement: `sellTo` is the controller's, `redeemStatement` needs a module
    function test_statementDoorsRefuseAnUnknownStatement() public {
        // an id the live Statements has never minted, so it is unknown to every door
        uint256 sid = STATEMENTS.supply() + 1_000_000;
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo(sid, alice);
        vm.prank(address(ctl));
        vm.expectRevert(ICore.NotForSale.selector);
        core.sellTo(sid, alice);
        // today the live Core has no balance module, so redeemStatement reverts NoBalanceModule before any held check.
        // stage B selects the treasury at setUp, so the module check no longer fires: skip that leg there
        if (core.balanceModule() == address(0)) {
            vm.expectRevert(ICore.NoBalanceModule.selector);
            core.redeemStatement(sid);
        }
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held);
    }

    // promise: SPEC 1 redeemOn and balanceBidOn are false at launch (RedeemOff, BalanceBidOff)
    /// today the live balance bid is closed (balanceBidOn false) and no module is set, so the balance bid reverts
    /// BalanceBidOff and the redemption door reverts NoBalanceModule. stage B turns the bid on and selects the
    /// treasury, so the launch closed state is gone: self-skip there (addendum 2 reads the live settings)
    function test_balanceDoorsClosedAtLaunch() public {
        if (_liveStageB()) return; // stage B opens the balance bid and selects a module
        assertFalse(core.settings().balanceBidOn, "today the live balance bid is closed");
        vm.prank(alice);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(_one(1));
        vm.prank(alice);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(_one(1), 0);
        // redeemStatement reverts NoBalanceModule while no module is set
        assertEq(core.balanceModule(), address(0), "today no balance module is set");
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(1);
    }

    // promise: INTEGRATION NothingToBuy, TooSoon, SliceTooSmall
    // test_buyback_guards moved to CoreControlledUnitTest (is Fixture): NothingToBuy needs an empty buyback pot, which
    // the live Core (with its standing buyback reserve fed by sales) does not have, and there is no setter to drain it

    // promise: INTEGRATION OnlyPoolManager
    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(ICore.OnlyPoolManager.selector);
        core.unlockCallback("");
    }

    // promise: INTEGRATION BadSender
    function test_onERC721Received_senders() public {
        vm.expectRevert(ICore.BadSender.selector);
        core.onERC721Received(address(0), address(0), 1, "");
        vm.prank(address(STATEMENTS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
        vm.prank(address(CREDITS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
    }

    /*//////////////////////////////////////////////////////////////
                         rate properties under fuzz
    //////////////////////////////////////////////////////////////*/
}

/// everything that follows a real compose. the live phase 2 treasury is selected in `setUp` (LiveFixture._enterPhase2),
/// the compose itself goes through the live controller and the live Statements contract, once per test
contract CoreComposedTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
    }

    /*//////////////////////////////////////////////////////////////
                                 compose
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 1 one pile: a statement records its cost and leaves the pile
    function test_compose_statementIdCostBasisAndPiles() public {
        Composed memory c = _composeOnce();
        uint256[] memory ids = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = c.ids[i];
        }
        assertEq(c.sid, c.supplyBefore + 1);
        assertEq(STATEMENTS.supply(), c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the core holds it");
        assertEq(STATEMENTS.creditsOf(c.sid), 80);

        (bool held, uint256 cost, uint64 composedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(cost, c.cost, "cost basis is the sum of the credits' cost bases");
        assertEq(composedAt, c.at);

        // the live pile and held list are non empty: assert the 80 composed credits left the pile and the new
        // statement is one the Core holds, rather than an empty pile or a single held statement
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,) = core.creditInfo(ids[i]);
            assertFalse(inPile);
        }
        assertTrue(_isHeld(c.sid), "the core holds the new statement");
        assertEq(core.ethPot(), c.potBefore - c.paid, "the pot pays the caller and nothing else");
        _solvent();
    }

    // promise: SPEC 1 both caller settings at zero pay nothing
    /// with `callerFee` and `callerMaxBaseFee` at zero a compose moves no eth out of the Core: the Core balance and
    /// `ethPot` are unchanged, at any basefee and with the buyback payment settings at their ceilings
    function test_compose_movesNoEthOut() public {
        Composed memory c = _composeOnce();
        uint256 snap = preComposeSnap;
        uint256 supply = c.supplyBefore;
        uint256 gasPrice = 5 gwei;
        Settings memory s = core.settings();
        s.keeperFee = 0.005 ether;
        s.keeperMaxBaseFee = 100 gwei;
        s.callerFee = 0;
        s.callerMaxBaseFee = 0;

        vm.revertToState(snap);
        _setSettings(s);
        vm.fee(gasPrice);
        vm.txGasPrice(gasPrice);
        uint256 coreBefore = address(core).balance;
        uint256 potBefore = core.ethPot();
        uint256 callerBefore = keeper.balance;
        vm.prank(keeper);
        core.compose();
        assertEq(address(core).balance, coreBefore, "the core balance is unchanged");
        assertEq(core.ethPot(), potBefore, "the eth pot is unchanged");
        assertEq(keeper.balance, callerBefore, "the caller receives nothing");
        (, uint256 cost,) = core.statementInfo(supply + 1);
        assertEq(cost, c.cost, "the cost basis is the credits only");
    }

    /*//////////////////////////////////////////////////////////////
                              redeem path
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION NotHeld, NotEligible, NoBalanceModule on redeemStatement
    function test_redeem_guards() public {
        Composed memory c = _composeOnce();
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(c.sid + 100);
        // an eth lane statement is not eligible until its asking price falls to its cost
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(c.sid);
        _makeEligible(c.sid);
        core.redeemStatement(c.sid);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(c.sid);
    }

    // promise: SPEC 9 a redemption keeps its balance token in the module, not the core
    /// an eth lane redemption mints the whole owed amount into the module; the core holds no balance token
    function test_redeem_ethLaneStaysInTheModule() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        uint256 held = _moduleCustody();
        core.redeemStatement(c.sid);
        // the live treasury converts by `withdraw`: the statement passes to the balance token and the balance tokens
        // stay in the treasury (the mock module kept the statement itself; the real token takes it in the conversion)
        assertEq(STATEMENTS.ownerOf(c.sid), liveBalanceToken, "the balance token takes the statement in the conversion");
        uint256 received = _moduleCustody() - held;
        // the live treasury withdraws the statement into balance token (the token's quote), all of it staying in the
        // module. the Core's own check is that the module gained at least the rating times the unit less redeem slippage
        uint256 minOwed = core.ratingOf(c.sid) * _moduleUnit() * (10_000 - core.settings().redeemSlippageBps) / 10_000;
        assertGe(received, minOwed, "the module gained at least the rating times the unit less slippage");
        assertEq(_balanceOf(address(core)), 0, "the core holds no balance token");
        assertFalse(_isHeld(c.sid));
    }

    // promise: INTEGRATION BadModule: the unit is read live (decision 103)
    // test_redeem_unitIsReadLive moved to CoreComposedMockTest: its subject is a module reporting a zero, reverting or
    // underpaying unit, which only the stand in module can produce

    /*//////////////////////////////////////////////////////////////
                              balance token bid
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 1 the balance token bid pays score times unit times the balance rate
    /// the per point bid pays a credit its score times the unit times the current balance rate, bps of par, and
    /// balanceBidOf reports that figure
    function test_xBid_paysScoreTimesUnit() public {
        // the live treasury is funded a working balance by _enterPhase2, so it can cover a single credit's bid; the
        // controller is pointed at the live eth/BALANCE pool to price the eth cost basis
        _setLiveBalancePool();
        uint256[] memory ids = _credits(alice, 1);
        uint256 rate = core.balanceRate();
        uint256 score = _scoreOf(ids[0]);
        uint256 expect = score * _moduleUnit() * rate / 10_000;
        assertEq(core.balanceBidOf(ids[0]), expect, "balanceBidOf is score times unit times the rate");
        uint256 before = _balanceOf(alice);
        vm.prank(alice);
        core.sellForBalance(ids);
        assertEq(_balanceOf(alice) - before, expect, "paid score times the unit times the rate");
        _solvent();
    }

    // promise: INTEGRATION BadModule, BadQuote, Empty on sellForBalance
    // test_xBid_guards moved to CoreComposedMockTest: the last leg (`available` of exactly 1 wei closes the bid with
    // PotTooSmall) needs a module that reports an arbitrary available, which only the stand in module can do

    // promise: SPEC 9 the module holds the balance token: a plain transfer to the module raises its available holding
    /// balance token that arrives at the module is part of its holding at once; the core holds none and has no book step
    function test_xFees_moduleHoldsTheBalanceToken() public {
        uint256 held = _moduleCustody();
        // a plain transfer of the live balance token into the treasury is part of its custody at once (unsolicited
        // transfers are working funds); the core holds none and has no book step for it
        _acquireBalance(address(treasury), 3e18);
        assertEq(_moduleCustody(), held + 3e18, "the module holding rose by the transfer");
        assertEq(_balanceOf(address(core)), 0, "the core holds no balance token");
    }
}

/// the balance module VALIDATION tests: their subject is a misbehaving module (a zero, reverting or underpaying unit,
/// an available of exactly 1 wei), which only the stand in MockBalanceModule can produce. the module is not a live
/// mainnet contract for this subject, so the owner rule allows a double; it is selected on the live Core by owner prank
/// through the base Fixture._enterPhase2 (the mock happy path with unbounded funding), the same treatment the live
/// suite's hostile controller tests get
contract CoreComposedMockTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function setUp() public virtual override {
        super.setUp();
        Fixture._enterPhase2();
    }

    // promise: INTEGRATION BadModule: the unit is read live (decision 103)
    /// the unit is read from the module in the call. a zero unit or a failed read reverts `BadModule`, and the minimum
    /// follows the unit the module reports now
    function test_redeem_unitIsReadLive() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        mod.setUnitPerPoint(0);
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(c.sid);
        mod.setRevertUnit(true);
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(c.sid);
        mod.setRevertUnit(false);
        // the module pays by the unit it reports now and the minimum is that unit's: a payout of half the live unit
        // is short, the full payout of the live unit passes
        mod.setUnitPerPoint(3 * UNIT);
        mod.setPayBps(5_000);
        vm.expectRevert(ICore.BadModule.selector);
        core.redeemStatement(c.sid);
        mod.setPayBps(10_000);
        uint256 out = core.ratingOf(c.sid) * 3 * UNIT;
        uint256 held = _moduleHolding();
        core.redeemStatement(c.sid);
        assertEq(_moduleHolding() - held, out, "the owed amount is minted into the module");
    }

    // promise: INTEGRATION BadModule, BadQuote, Empty on sellForBalance
    function test_xBid_guards() public {
        _fillBalanceBuyback();
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForBalance(none);
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForBalance(_one(0));
        vm.prank(keeper);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForBalance(ids);
        // the module commits only 1 wei: the clamp as bps of par is below the floor, so the bid closes (PotTooSmall)
        mod.setAvailable(1);
        vm.prank(alice);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
    }
}

/// controlled input unit tests kept on the fresh Fixture: each needs a Core state the live system cannot reach.
/// test_tinyPot needs the eth pot drained to 0 and then to exactly 1 wei, plus a credit whose score equals refScore
/// (a 1 wei bid): the live pot is large and non empty, reserveWei is a uint64 (at most ~18.4 ether) so the pot cannot
/// be forced under the reserve, and the live credit scores cannot be chosen. test_buyback_guards needs an empty
/// buyback pot, which the live Core (with its standing buyback reserve) does not have. they run against a freshly
/// deployed Core where the mock score and the empty pots are reachable
contract CoreControlledUnitTest is Fixture {
    /// the tiny pot promise reads the price alone: with no buy to artist cut the 1 wei pot clamps the eth bid to 1 wei
    /// (the clamp divides the pot less the reserve by 1 plus buyToArtistBps/BPS). the artist royalty is
    /// test/ArtistRoyalty.t.sol's
    function _settings() internal view override returns (Settings memory s) {
        s = super._settings();
        s.buyToArtistBps = 0;
    }

    /// @dev the account that sells credits in these suites
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = seller;
    }

    // promise: INTEGRATION PotTooSmall and ZeroAmount
    /// a pot at or under the reserve reads a rate of 0: a sale reverts `PotTooSmall` (decision 156) and a purchase
    /// reverts `PotTooSmall`. a pot of 1 wei reads 1 wei: a sale pays it and a purchase of 2 wei reverts `PotTooSmall`
    function test_tinyPotSellsItsWeiAndBuysNothing() public {
        uint256[] memory ids = _credits(alice, 2);
        // refScore set to the sold credit's score, so a 1 wei pot reads a 1 wei bid for it (score / refScore is 1)
        _unitScore(ids[0]);
        bytes memory data = abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A));
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(1, data, LISTED_A, Mainnet.CREDIT_STRATEGY);
        vm.prank(alice);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForEth(_one(ids[0]));

        vm.deal(address(core), 1);
        core.book();
        assertEq(core.ethPot(), 1);
        assertEq(core.ethRate(), 1);
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(2, data, LISTED_A, Mainnet.CREDIT_STRATEGY);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        assertEq(alice.balance - before, 1, "paid the wei");
        assertEq(core.ethPot(), 0);
        vm.prank(alice);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForEth(_one(ids[1]));
    }

    // promise: INTEGRATION NothingToBuy, TooSoon, SliceTooSmall
    function test_buyback_guards() public {
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
        // eth held without being booked into the buyback pot is not for sale to the buyback
        vm.deal(address(core), 1 ether);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
    }

    // promise: INTEGRATION NotReady
    /// a page under 80 cannot compose. the input is the pile size, controlled on the fresh fixture: the live pile is
    /// always full (82) at the pin, so this count-based guard is proven here with an empty then a 79 credit pile. the
    /// fresh fixture composes with the sale window off, so NotReady here is the count, not the window
    function test_compose_notReady() public {
        assertEq(core.pileSize(), 0, "the fresh fixture starts with an empty pile");
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();

        _fillEthPile(79);
        assertEq(core.pileSize(), 79);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }
}
