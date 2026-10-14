// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, ICreditScore, Stack, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {CreditIds} from "./utils/CreditIds.sol";

/// shared helpers of the core unit suites. everything runs on the real stack of the Fixture: the live coin, hook,
/// pool, Credits, Statements, CreditStrategy and Seaport. a test that needs an exact pot donates
/// eth through `fund()`, which adds it to the pot whole
abstract contract CoreBase is Fixture {
    using stdStorage for StdStorage;

    /// @dev the account that sells credits in these suites
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = seller;
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
    /// the opening bid is a deploy input bounded to [1e13, 1e18] wei per credit
    function test_rateStartBounds() public {
        Settings memory s = lc.settings;
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(ctl), lc.payee, lc.stack, 1e13 - 1, s);
        vm.expectRevert(ICore.BadRate.selector);
        this.mk(owner, address(ctl), lc.payee, lc.stack, 1e18 + 1, s);
        ICore lo = this.mk(owner, address(ctl), lc.payee, lc.stack, 1e13, s);
        s.rateCap = 1e18;
        ICore hi = this.mk(owner, address(ctl), lc.payee, lc.stack, 1e18, s);
        assertEq(lo.RATE_START(), 1e13);
        assertEq(lo.rateAtCheckpoint(), 1e13);
        assertEq(hi.RATE_START(), 1e18);
        assertEq(hi.rateAtCheckpoint(), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                           fee intake and fund
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 4 fee intake: book, fund and UseFund (inv 10)
    /// eth the hook pushes after a real swap is booked at the next book. a plain send from anyone else reverts and `fund`
    /// adds to the pot whole
    function test_bookCountsHookEth_fundAddsTheRest() public {
        _skipSniperWindow();
        // the whole fee receipt goes to the pot here, so the pot equals the full bounty leg
        Settings memory s0 = core.settings();
        s0.feeToRedeemBurnBps = 0;
        _setSettings(s0);
        _buyCoin(funder, 1 ether);
        uint256 pot = core.ethPot();
        assertEq(pot, 0.0665022 ether, "6.65022 points of a 1 eth buy");
        assertEq(address(core).balance, pot);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(core).call{value: 2 ether}("");
        assertFalse(ok, "a plain send reverts");
        assertEq(core.ethPot(), pot);
        assertEq(address(core).balance, pot);

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
        uint256 price = core.bidOf(id);

        vm.prank(alice);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForEth(_one(id), price + 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id), price);
        assertEq(alice.balance - before, price);
    }

    // promise: INTEGRATION ZeroAmount and PotTooSmall
    /// an empty pot reads a rate of 0: a sale reverts `ZeroAmount` and a purchase reverts `PotTooSmall`. a pot of 1 wei
    /// reads 1 wei: a sale pays it and a purchase of 2 wei reverts `PotTooSmall`
    function test_tinyPotSellsItsWeiAndBuysNothing() public {
        uint256[] memory ids = _credits(alice, 2);
        // refScore set to the sold credit's score, so a 1 wei pot reads a 1 wei bid for it (score / refScore is 1)
        _refScoreToCredit(ids[0]);
        bytes memory data = abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A));
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(1, data, LISTED_A, Mainnet.CREDIT_STRATEGY);
        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
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
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(_one(ids[1]));
    }

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

        vm.prank(alice);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForEth(ids);

        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(ICore.NotOwner.selector);
        core.sellForEth(ids);

        // not approved
        address bob = _user("bob");
        uint256 id = CreditIds.at(500);
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

    /// funds the pot and warps hour by hour until the ceiling clears the listing price of id.
    function _fundAndClimb(uint256 id, uint256 price) internal {
        _fund(10 ether);
        _warpUntilCeiling(id, price);
    }

    // promise: INTEGRATION AboveBid
    function test_buyListing_aboveCeilingReverts() public {
        _fund(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertGt(price, core.ethRate(), "start rate is far below the listing");
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
        uint256 ceiling = core.ethRate();
        r.gap = ceiling - cost;
        uint256 pot = core.ethPot();
        uint256 before = keeper.balance;
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(adapter, id, params);
        r.used = g - gasleft();
        r.paid = keeper.balance - before;
        _assertListingPay(r.paid, r.gap);
        assertEq(core.ethPot(), pot - cost - r.paid, "the pot pays the cost and the payment");
        (, uint256 basis,) = core.creditInfo(id);
        assertEq(basis, cost + r.paid, "the cost basis is the cost plus the payment");
        assertLe(basis, ceiling, "the engine pays at most its bid");
        _solvent();
    }

    // promise: SPEC 1 keeper doors pay counted gas plus keeperFee
    /// the payment is the gas counted at the base fee plus the whole keeper fee, on the real strategy path. the counted
    /// gas covers the gas used and the transaction base cost, and scales with the base fee
    function test_buyListing_paysCountedGasAtTheBaseFeePlusTheFee() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        // refScore set to the listed credit's score, so its bid is the full rate with room for the keeper payment
        _refScoreToCredit(LISTED_A);
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        uint256 snap = vm.snapshotState();
        PayRun memory a = _payRun(strategyAdapter, "", LISTED_A, price, 1 gwei, 1 gwei);
        uint256 fee = core.settings().keeperFee;
        assertEq(fee, 0.0005 ether);
        assertGt(a.gap, a.paid, "the gap does not bind");
        assertEq((a.paid - fee) % 1 gwei, 0, "whole gas units");
        uint256 counted = (a.paid - fee) / 1 gwei;
        assertGe(counted, a.used + 21_000, "the counted gas covers the gas used and the transaction base cost");
        assertLe(counted, a.used + 120_000, "and carries no more than the work after the count");
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
            uint256 id = CreditIds.at(545 + i);
            // refScore set to this credit's score, so its bid is the full rate and the gap and fee math is the flat case
            _refScoreToCredit(id);
            uint256 ceiling = core.bidOf(id);
            ListingTarget t = _listingTarget(id);
            uint256 snap = vm.snapshotState();
            PayRun memory r =
                _payRun(rawAdapter, _raw(address(t), ceiling - gaps[i], abi.encodeCall(ListingTarget.fill, (id, 0))), id, ceiling - gaps[i], 1 gwei, 1 gwei);
            assertEq(r.paid, gaps[i], "the payment is the gap");
            (, uint256 basis,) = core.creditInfo(id);
            assertEq(basis, ceiling, "cost plus payment is the bid");
            vm.revertToState(snap);
        }
    }

    // promise: INTEGRATION CallFailed
    function test_buyListing_failedCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _fundAndClimb(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();

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
        assertEq(core.pileSize(), 0);

        // an unrelated buy still goes through.
        vm.prank(keeper);
        _buyRaw(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(core.pileSize(), 1);

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
        _warpUntilCeiling(LISTED_A, price);
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(price * 4 + 1, _listing(LISTED_A), LISTED_A, STRATEGY);

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
        uint256 before = address(core).balance;
        uint256 hostileBefore = address(hostile).balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        _buyRaw(1 gwei, "", LISTED_A, address(hostile));
        assertEq(address(core).balance, before, "core balance");
        assertEq(address(hostile).balance, hostileBefore, "the eth went nowhere");
        assertEq(core.ethPot(), 10 ether, "pot");
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
        uint256 id = CreditIds.at(630);
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
            uint256 id = CreditIds.at(600 + m);
            ProbeTarget p = _probe(id, m);
            vm.deal(address(p), 1 ether);
            uint256 value = (core.ethRate() / 2).min(core.ethPot() / 20);
            vm.prank(keeper);
            try core.buyListing(
                rawAdapter, id, _raw(address(p), value, abi.encodeCall(ProbeTarget.fill, (id, CreditIds.at(620 + m))))
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

    // promise: INTEGRATION NotReady
    function test_compose_notReady() public {
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();

        uint256[] memory ids = _sellN(alice, 79);
        assertEq(ids.length, 79);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    // promise: INTEGRATION NotInPile, NotHeld, BadStatement on compose
    function test_compose_controllerCannotNameBadPages() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
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
        assertEq(core.pileSize(), 3);
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
        uint256[] memory ids = _sellN(alice, 85);
        assertEq(core.pileSize(), 85);

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

        assertEq(core.pileSize(), 5);
        assertEq(core.pilePage(0, 1)[0], ids[0]);
        uint256[] memory rest = core.pilePage(0, 10);
        assertEq(rest.length, 5);
        for (uint256 j; j < 5; ++j) {
            assertEq(rest[j], ids[left[j]]);
        }
        assertEq(core.pilePage(ids[84], 1).length, 0);

        // a new arrival lands behind the old tail.
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pilePage(ids[84], 1)[0], more[0]);
        assertEq(core.pileSize(), 6);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         doors that need no module
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION NotForSale, NotHeld
    /// the statement doors with no statement: `sellTo` is the controller's, `redeemStatement` needs a module
    function test_statementDoorsRefuseAnUnknownStatement() public {
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo(1, alice);
        vm.prank(address(ctl));
        vm.expectRevert(ICore.NotForSale.selector);
        core.sellTo(1, alice);
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(1);
        (bool held,,) = core.statementInfo(1);
        assertFalse(held);
        assertEq(core.ethPot(), 0);
        assertEq(core.ethToBuyback(), 0);
    }

    // promise: SPEC 1 redeemOn and balanceBidOn are false at launch (RedeemOff, BalanceBidOff)
    /// with both switches at their launch value false the balance token bid is closed; the redemption door reverts
    /// NoBalanceModule while no module is set
    function test_balanceDoorsClosedAtLaunch() public {
        vm.prank(alice);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(_one(1));
        vm.prank(alice);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(_one(1), 0);
        // redeemStatement reverts NoBalanceModule whatever the switch while no module is set
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(1);
        core.bookBalance();
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

/// everything that follows a real compose. the stand in balance module is set in `setUp`, the compose itself goes through
/// the real controller and the real Statements contract, once per test
contract CoreComposedTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
    }

    function _held() internal view returns (uint256[] memory) {
        return core.heldStatements();
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

        assertEq(core.pileSize(), 0);
        assertEq(core.pilePage(0, 1).length, 0);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,) = core.creditInfo(ids[i]);
            assertFalse(inPile);
        }
        assertEq(CREDITS.balanceOf(address(core)), 0, "the credits were burned into the statement");
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], c.sid);
        assertEq(core.ethPot(), c.potBefore);
        _solvent();
    }

    // promise: SPEC 1 compose is unpaid at launch
    /// at the launch values of `callerFee` and `callerMaxBaseFee` (zero) a compose moves no eth out of the Core: the
    /// Core balance and `ethPot` are unchanged, at any basefee and with the buyback payment settings at their ceilings
    function test_compose_movesNoEthOut() public {
        Composed memory c = _composeOnce();
        uint256 snap = preComposeSnap;
        uint256 supply = c.supplyBefore;
        uint256 gasPrice = 5 gwei;
        Settings memory s = core.settings();
        s.keeperFee = 0.005 ether;
        s.keeperMaxBaseFee = 100 gwei;

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

    // promise: SPEC 9 a redemption books its eth into the pots
    /// an eth lane redemption books the whole received amount into the bid pot
    function test_redeem_ethLaneAllToTheBidPot() public {
        Composed memory c = _composeOnce();
        _makeEligible(c.sid);
        uint256 out = core.ratingOf(c.sid) * UNIT;
        uint256 pot = core.balancePot();
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module keeps the statement");
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.balancePot() - pot, out, "all received to the bid pot");
        assertEq(_held().length, 0);
        assertFalse(_isHeld(c.sid));
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
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(c.sid);
        mod.setPayBps(10_000);
        uint256 out = core.ratingOf(c.sid) * 3 * UNIT;
        core.redeemStatement(c.sid);
        assertEq(xt.balanceOf(address(core)), out);
    }

    /*//////////////////////////////////////////////////////////////
                              balance token bid
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 1 the balance token bid pays score times unit less the margin
    /// the per point bid pays each credit its score times the unit less the margin
    function test_xBid_paysScoreTimesUnit() public {
        _fillBalanceBuyback();
        _setBalancePool();
        xt.mint(address(core), 1e22);
        core.bookBalance();
        uint256[] memory ids = _credits(alice, 2);
        uint256 net = 10_000 - core.settings().balanceBidMarginBps;
        uint256 expect;
        for (uint256 i; i < 2; ++i) {
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(ids[i]), CREDITS.timestampOf(ids[i]));
            expect += score * UNIT * net / 10_000;
        }
        uint256 before = xt.balanceOf(alice);
        vm.prank(alice);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(alice) - before, expect, "paid score times the unit less the margin");
        _solvent();
    }

    // promise: INTEGRATION BadModule, BadQuote, Empty on sellForBalance
    function test_xBid_guards() public {
        _fillBalanceBuyback();
        xt.mint(address(core), 1e22);
        core.bookBalance();
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
        stdstore.target(address(core)).sig("balancePot()").checked_write(uint256(1));
        vm.prank(alice);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 bookBalance books balance token into balancePot (inv 5)
    /// balance token that arrives outside a redemption is booked only by `bookBalance`, into the bid pot
    function test_xFees_bookBalanceBooksPlainTransfers() public {
        _fillBalanceBuyback();
        uint256 pot = core.balancePot();
        core.bookBalance();
        assertEq(core.balancePot(), pot, "nothing above the pot");
        xt.mint(address(core), 3e18);
        assertEq(core.balancePot(), pot);
        core.bookBalance();
        assertEq(core.balancePot(), pot + 3e18);
        _solvent();
    }

}
