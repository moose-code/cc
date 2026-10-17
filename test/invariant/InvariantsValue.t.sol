// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {ICredits, ICreditScore, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";
import {ValueBase} from "../ValueMode.t.sol";

/// @notice the actors of the value mode suite: they sell credits into the eth and the balance bid, buy pile credits and
/// statements from the controller, move the pool spot, call `refreshReference()` and let time pass. every action records what
/// the invariants need: the payment against the bid read just before, the payment against the room, the core's eth
/// outflow against the payment, a statement sale against its hard floor, and a credit bought from the engine and sold
/// straight back against the spread
contract ValueHandler is Test {
    ICore internal immutable core;
    IControllerV1 internal immutable ctl;
    MockBalanceToken internal immutable xt;
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    /// the pool manager word of the balance pool's slot 0, and its sqrt price at the start
    bytes32 internal immutable slot0;
    uint160 internal immutable sp0;
    uint256 internal immutable unit;

    address[] public actors;
    /// the credits each actor holds, by actor index
    mapping(uint256 => uint256[]) internal held;

    /// a credit an actor bought from the engine: what it paid and the spot epoch of the buy
    struct Bought {
        uint256 paid;
        uint256 epoch;
        bool open;
    }

    mapping(uint256 => Bought) public bought;
    /// bumped by every spot move; a round trip inside one epoch faces no price move
    uint256 public epoch;

    /// ghost counters: each is a broken promise, zero while the invariants hold
    uint256 public g1; // eth left the core other than as the seller's payment
    uint256 public g2; // a credit paid above the bid read just before
    uint256 public g3; // a statement sold below the hard floor
    uint256 public g7; // a payment above the pot less the reserve
    uint256 public gBalance; // a balance payout above score * unit * cap
    uint256 public gTrip; // a round trip inside one spot epoch that lost less than the spread
    uint256 public gRefusal; // a refusal with an unexpected selector

    mapping(bytes32 => uint256) public calls;
    /// successful fills and checked round trips, so a run that only refused shows up
    uint256 public ethFills;
    uint256 public balanceFills;
    uint256 public creditBuys;
    uint256 public tripsChecked;

    constructor(ICore core_, IControllerV1 ctl_, MockBalanceToken xt_, bytes32 slot0_, uint160 sp0_, uint256 unit_) {
        core = core_;
        ctl = ctl_;
        xt = xt_;
        slot0 = slot0_;
        sp0 = sp0_;
        unit = unit_;
    }

    function addActor(address a, uint256[] memory ids) external {
        actors.push(a);
        uint256 k = actors.length - 1;
        for (uint256 i; i < ids.length; ++i) {
            held[k].push(ids[i]);
        }
        vm.prank(a);
        CREDITS.setApprovalForAll(address(core), true);
    }

    function _actor(uint256 seed) internal view returns (uint256 k, address a) {
        k = seed % actors.length;
        a = actors[k];
    }

    /// takes the credit at `seed` out of actor `k`'s list, or 0 when it holds none
    function _take(uint256 k, uint256 seed) internal returns (uint256 id) {
        uint256 n = held[k].length;
        if (n == 0) return 0;
        uint256 i = seed % n;
        id = held[k][i];
        held[k][i] = held[k][n - 1];
        held[k].pop();
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    function _spot() internal view returns (uint256 spot) {
        (spot,) = ctl.spotPrice();
    }

    function _room() internal view returns (uint256) {
        uint256 pot = core.ethPot();
        uint256 res = core.reserve();
        return pot > res ? pot - res : 0;
    }

    function _expected(bytes memory why, bytes4 a, bytes4 b, bytes4 c) internal {
        bytes4 s = bytes4(why);
        if (s != a && s != b && s != c) ++gRefusal;
    }

    /// the round trip of a credit bought from the engine: inside one spot epoch what came back, valued at the spot for
    /// the balance token, is at most the price over (10,000 + spreadBps), within a wei of the price's rounding
    function _trip(uint256 id, uint256 back) internal {
        Bought memory b = bought[id];
        if (!b.open) return;
        delete bought[id];
        if (b.epoch != epoch) return;
        ++tripsChecked;
        if (back * (10_000 + ctl.creditSpreadBps()) > (b.paid + 1) * 10_000) ++gTrip;
    }

    function sellEth(uint256 seed) external {
        ++calls["sellEth"];
        (uint256 k, address a) = _actor(seed);
        uint256 id = _take(k, seed >> 8);
        if (id == 0) return;
        core.book();
        uint256 room = _room();
        uint256 bid;
        try core.bidOf(id) returns (uint256 b) {
            bid = b;
        } catch {}
        uint256 coreBefore = address(core).balance;
        uint256 before = a.balance;
        vm.prank(a);
        try core.sellForEth(_one(id)) {
            uint256 paid = a.balance - before;
            if (paid > bid) ++g2;
            if (paid > room) ++g7;
            if (coreBefore - address(core).balance != paid) ++g1;
            ++ethFills;
            _trip(id, paid);
        } catch (bytes memory why) {
            held[k].push(id);
            _expected(why, ICore.NoQuote.selector, ICore.PotTooSmall.selector, ICore.ReturnLocked.selector);
        }
    }

    function sellBalance(uint256 seed) external {
        ++calls["sellBalance"];
        (uint256 k, address a) = _actor(seed);
        uint256 id = _take(k, seed >> 8);
        if (id == 0) return;
        uint256 cap = core.settings().balanceBidCapBps;
        uint256 before = xt.balanceOf(a);
        uint256 coreBefore = address(core).balance;
        vm.prank(a);
        try core.sellForBalance(_one(id)) {
            uint256 got = xt.balanceOf(a) - before;
            if (got > _score(id) * unit * cap / 10_000) ++gBalance;
            if (address(core).balance < coreBefore) ++g1;
            ++balanceFills;
            _trip(id, got * _spot() / 1e18);
        } catch (bytes memory why) {
            held[k].push(id);
            _expected(why, ICore.PotTooSmall.selector, ICore.ReturnLocked.selector, ICore.ReturnLocked.selector);
        }
    }

    function buyCredit(uint256 seed) external {
        ++calls["buyCredit"];
        uint256 n = core.pileSize();
        if (n == 0) return;
        uint256[] memory page = core.pilePage(0, n < 40 ? n : 40);
        uint256 id = page[seed % page.length];
        (uint256 k, address a) = _actor(seed >> 8);
        ctl.refreshReference();
        uint256 price;
        try ctl.creditPrice(id) returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        vm.deal(a, a.balance + price);
        uint256 before = a.balance;
        vm.prank(a);
        try ctl.buyCredit{value: price}(id) {
            bought[id] = Bought({paid: before - a.balance, epoch: epoch, open: true});
            held[k].push(id);
            ++creditBuys;
        } catch (bytes memory why) {
            _expected(why, IControllerV1.NoQuote.selector, ICore.NoQuote.selector, IControllerV1.NotForSale.selector);
        }
    }

    function buyStatement(uint256 seed) external {
        ++calls["buyStatement"];
        uint256[] memory sids = core.heldStatements();
        if (sids.length == 0) return;
        uint256 sid = sids[seed % sids.length];
        (, address a) = _actor(seed >> 8);
        uint256 price;
        try ctl.priceOf(sid) returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 hardFloor = cost * core.settings().saleFloorBps / 10_000;
        vm.deal(a, a.balance + price);
        uint256 before = a.balance;
        vm.prank(a);
        try ctl.buy{value: price}(sid) {
            if (before - a.balance < hardFloor) ++g3;
        } catch (bytes memory why) {
            _expected(why, IControllerV1.NoQuote.selector, ICore.NoQuote.selector, IControllerV1.NotForSale.selector);
        }
    }

    /// moves the pool spot to between half and twice its start, a new epoch
    function moveSpot(uint256 seed) external {
        ++calls["moveSpot"];
        uint256 f = 5_000 + seed % 15_001; // bps of the start sqrt price, so 0.25x to 4x the start spot
        uint160 sp = uint160(uint256(sp0) * f / 10_000);
        bytes32 word = vm.load(address(Mainnet.POOL_MANAGER), slot0);
        uint256 rest = uint256(word) & ~uint256(type(uint160).max);
        vm.store(address(Mainnet.POOL_MANAGER), slot0, bytes32(rest | uint256(sp)));
        ++epoch;
    }

    function refreshReference() external {
        ++calls["refreshReference"];
        ctl.refreshReference();
    }

    function warp(uint256 seed) external {
        ++calls["warp"];
        vm.warp(block.timestamp + 60 + seed % 3 hours);
        vm.roll(block.number + 1 + seed % 900);
    }
}

/// @notice the value mode invariants (decision 148, SPEC-value-pricing-153 section 10): invariants 1, 2, 3, 7, 16 and 19
/// restated for an eth bid priced off the shared balance instance times the controller's protected value, and the
/// round trip closed by the spread in either currency. the run starts in value mode at the switch values with a usable
/// quote, a composed statement held, the return lock at 0 so round trips run inside one spot epoch, and four actors
/// holding real credits
contract InvariantsValue is ValueBase {
    ValueHandler internal h;

    function setUp() public override {
        super.setUp();
        // the quote of `ValueBase`: a referenceMaxStale of a day, so the handler's warps of at most three hours leave it usable
        // between refreshes, and a run of warps without one halts the eth routes, which the refusals allow
        _composeOnce();
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _fundPot(30 ether);
        bytes32 slot0 = keccak256(abi.encodePacked(key.toId(), bytes32(uint256(6))));
        h = new ValueHandler(core, ctl, xt, slot0, SP, UNIT);
        for (uint256 i; i < 4; ++i) {
            address a = _user(string.concat("value.actor", vm.toString(i)));
            h.addActor(a, _credits(a, 15));
        }
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = ValueHandler.sellEth.selector;
        sel[1] = ValueHandler.sellBalance.selector;
        sel[2] = ValueHandler.buyCredit.selector;
        sel[3] = ValueHandler.buyStatement.selector;
        sel[4] = ValueHandler.moveSpot.selector;
        sel[5] = ValueHandler.refreshReference.selector;
        sel[6] = ValueHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// the handler's routes work at the start state: eth and balance fills land, a credit bought from the engine is sold
    /// back in the next block through each door, and both round trips are checked against the spread
    // promise: the value mode handler exercises every route it checks
    function test_handlerExercisesTheRoutes() public {
        h.sellEth(0);
        h.sellBalance(1);
        h.buyCredit(0);
        h.warp(0);
        h.sellEth(0); // actor 0 holds the bought credit and its own credits; repeat until the bought one is sold
        for (uint256 i = 1; i < 20 && h.tripsChecked() == 0; ++i) {
            h.sellEth(i << 8);
        }
        h.buyCredit(1 | (1 << 8)); // the second pile credit, to actor 1
        h.warp(0);
        for (uint256 i; i < 20 && h.tripsChecked() < 2; ++i) {
            h.sellBalance(1 | (i << 8));
        }
        assertGt(h.ethFills(), 0, "no eth fill");
        assertGt(h.balanceFills(), 0, "no balance fill");
        assertEq(h.creditBuys(), 2, "the credit buys");
        assertEq(h.tripsChecked(), 2, "a round trip through each door");
        assertEq(h.gTrip() + h.g1() + h.g2() + h.g7() + h.gBalance() + h.gRefusal(), 0, "no broken promise");
    }

    /// 1. eth leaves the core in value mode only as the seller's payment of an eth fill, and never on a balance fill
    // promise: 01 eth only leaves by allowed paths, in value mode
    function invariant_v01_ethOnlyLeavesAsThePayment() public view {
        assertEq(h.g1(), 0, "eth left the core other than as the seller's payment");
        assertLe(core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), address(core).balance, "the pots exceed the balance");
    }

    /// 2. no credit is paid above the bid read just before, and a balance payout never passes score * unit * cap
    // promise: 02 no credit above the read, in value mode
    function invariant_v02_noCreditAboveTheRead() public view {
        assertEq(h.g2(), 0, "a credit was paid above its bid");
        assertEq(h.gBalance(), 0, "a balance payout passed score * unit * cap");
    }

    /// 3. no statement is sold below the hard floor, cost * saleFloorBps
    // promise: 03 no statement sold below the hard floor, in value mode
    function invariant_v03_noStatementBelowTheHardFloor() public view {
        assertEq(h.g3(), 0, "a statement sold below the hard floor");
    }

    /// 7. no eth fill pays above the pot less the reserve
    // promise: 07 no spend above the pot, in value mode
    function invariant_v07_noSpendAboveTheRoom() public view {
        assertEq(h.g7(), 0, "a fill paid above the pot less the reserve");
    }

    /// 16. while the quote is usable, a credit whose bid the pot less the reserve covers can be sold into the eth bid
    // promise: 16 the bid never closes, in value mode
    function invariant_v16_theBidNeverCloses() public {
        (, bool ok) = ctl.valuePerPoint(false);
        if (!ok) return;
        uint256 snap = vm.snapshotState();
        core.book();
        address a = h.actors(0);
        uint256[] memory ids = _credits(a, 1);
        uint256 res = core.reserve();
        uint256 room = core.ethPot() > res ? core.ethPot() - res : 0;
        bool covered = core.bidOf(ids[0]) <= room && core.bidOf(ids[0]) != 0;
        vm.prank(a);
        (bool sold, bytes memory why) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        vm.revertToState(snap);
        if (covered) assertTrue(sold, string.concat("the eth bid refused a covered credit, selector ", vm.toString(bytes4(why))));
    }

    /// 19. the read in value mode: at most rateCap and the room with the pending income, the shared instance between its
    /// floor and the cap, and with no pending income exactly the shared rate times the buy value lowered to the room
    // promise: 19 the read is within its bounds, in value mode
    function invariant_v19_readBounds() public view {
        Settings memory s = core.settings();
        uint256 bal = core.balanceRate();
        assertGe(bal, 10_000 - s.balanceBidMarginBps, "the shared instance is under its floor");
        assertLe(bal, s.balanceBidCapBps, "the shared instance is over the cap");
        (uint256 v, bool ok) = ctl.valuePerPoint(false);
        if (!ok) return;
        uint256 rate = core.ethRate();
        assertLe(rate, s.rateCap, "the read is above rateCap");
        uint256 pot = core.ethPot();
        uint256 res = core.reserve();
        uint256 pending = address(core).balance - pot - core.ethToBuyback() - core.ethRedeemBurn();
        assertLe(rate, pot + pending > res ? pot + pending - res : 0, "the read is above the room with the pending income");
        if (pending == 0) {
            uint256 price = bal * v * 100 / 10_000;
            if (price > s.rateCap) price = s.rateCap;
            uint256 room = pot > res ? pot - res : 0;
            assertEq(rate, price < room ? price : room, "the read is not the shared rate times the buy value lowered to the room");
        }
    }

    /// a credit bought from the engine and sold straight back, in either currency, loses at least the spread while the
    /// spot holds, and every refusal carries an expected selector
    // promise: SPEC 10 round trips lose the spread, in value mode
    function invariant_v20_roundTripsLoseTheSpread() public view {
        assertEq(h.gTrip(), 0, "a round trip lost less than the spread");
        assertEq(h.gRefusal(), 0, "a refusal carried an unexpected selector");
    }
}
