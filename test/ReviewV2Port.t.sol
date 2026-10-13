// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {FeeBase} from "./Fees.t.sol";
import {Fixture} from "./utils/Fixture.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";

/// independent review of the v2 port (REVIEW-v2port.md, git history before packet 0). `test_FINDING_*` asserts a real defect as it behaves
/// today. `test_FIXED_*` proves a finding is closed, `test_ACCEPTED_*` pins a behavior the owner accepted, `test_OK_*`
/// confirms a property that holds. real contracts on the pinned fork, attacker contracts only where a third party needs code

/// a seller side contract that flushes the fee router when Seaport pays it, i.e. inside the Core's measured call. it first
/// sends `topUp` of its own eth to the router, the way a swap inside the call would leave bounty eth there (the Core has
/// already pulled what the router held before the call). `swallow` true catches the failure (the sale goes through),
/// false lets it fail the payment
contract FlushingPayee {
    IFeeRouter public immutable ROUTER;
    bool public armed;
    bool public swallow = true;
    bool public flushOk;
    bool public tried;
    uint256 public topUp;

    constructor(address router_) {
        ROUTER = IFeeRouter(payable(router_));
    }

    function arm(bool swallow_, uint256 topUp_) external {
        armed = true;
        topUp = topUp_;
        swallow = swallow_;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        tried = true;
        if (topUp != 0) {
            (bool sent,) = address(ROUTER).call{value: topUp}("");
            require(sent, "top up");
        }
        if (swallow) {
            try ROUTER.flush() {
                flushOk = true;
            } catch {}
        } else {
            ROUTER.flush();
            flushOk = true;
        }
    }
}

/// F1. a stranger flushes the fee router in the middle of `buyListing`. the router balance is the engine's own queued fee
/// eth, so the attacker pays nothing for it, unlike a swap or an escrow claim (the cases the existing tests cover)
contract ReviewSeaportFlushTest is SeaportBase {
    using FixedPointMathLib for uint256;

    uint256 internal constant TARGET_RATE = 1e15;

    function setUp() public override {
        super.setUp();
        Settings memory cs = core.settings();
        cs.rateCap = uint64(TARGET_RATE);
        cs.ceilBps = 30_000;
        cs.idleLoosenBps = 2_000;
        _setSettings(cs);
        _fundPot(30 ether);
        for (uint256 i; i < 900 && core.ethRate() < TARGET_RATE; ++i) {
            _warp(1 hours);
        }
        assertGe(core.ethRate(), TARGET_RATE);
    }

    /// the bounty eth of a real buy of `buyEth` (the hook pushed it, nobody flushed). it is taken out of the router, so
    /// the pull at the start of the door finds the router empty, and returned for the attacker to push back mid call
    function _queueFees(uint256 buyEth) internal returns (uint256 held) {
        autoFlush = false;
        _buyCoin(funder, buyEth);
        autoFlush = true;
        held = address(feeRouter).balance;
        vm.deal(address(feeRouter), 0);
    }

    /// the maker lists at exactly the ceiling (no gap, so no payment is due) with a one wei second recipient that is
    /// the attacker contract. returns the data for the door
    function _order(uint256 id, uint256 price, FlushingPayee atk) internal returns (bytes memory) {
        OrderComponents memory c = _open(id, price - 1, 1);
        c.consideration[1].recipient = payable(address(atk));
        return _basicData(c);
    }

    /// V2R-1 fixed: the Core refuses the fee source while it measures. the flush fails whole, the attacker's top up
    /// waits in the router, the cost basis is the price and no payment is made on a purchase at the ceiling
    function test_FIXED_strangerFlushInsideBuyListingRevertsAndTheCostIsExact() public {
        uint256 held = _queueFees(1.5 ether);
        uint256 id = _list();
        uint256 price = core.ethRate();
        assertGt(held, 0.05 ether);
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        vm.deal(address(atk), held);
        atk.arm(true, held);
        bytes memory data = _order(id, price, atk);

        uint256 pot0 = core.ethPot();
        uint256 bal0 = address(core).balance;
        uint256 maker0 = maker.balance;
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);

        assertTrue(atk.tried(), "the attacker tried the flush");
        assertFalse(atk.flushOk(), "the flush inside the measured call reverted");
        assertEq(address(feeRouter).balance, held, "the attacker top up waits in the router, untouched");
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(maker.balance - maker0, price - 1, "no payment at the ceiling");
        assertEq(booked, price, "the cost basis is the price paid");
        assertEq(core.ethPot(), pot0 - price, "the pot paid the exact cost");
        assertEq(address(core).balance, bal0 - price, "the Core gained nothing mid call");
        assertEq(
            address(core).balance,
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(),
            "pots stay consistent"
        );
        // the self dealing door never beats the sell door
        assertLe(maker.balance - maker0 + 1, price, "the door does not beat the sell door");
    }

    /// the router holds fees when the door starts and the attacker also tops it up and flushes mid call. the door pulls
    /// the held fees first. the mid call flush fails whole, and the measured cost and the cost basis stay exact
    function test_FIXED_aLoadedRouterIsPulledAndAMidCallFlushCannotMoveTheCost() public {
        uint256 held = _queueFees(1.5 ether);
        // the fees go back into the router: the door finds them there
        vm.deal(address(feeRouter), held);
        uint256 id = _list();
        uint256 price = core.ethRate();
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        vm.deal(address(atk), held);
        atk.arm(true, held);
        bytes memory data = _order(id, price, atk);

        uint256 engine = held - (feeRouter.splitOn() ? held * 112_778 / 1e6 : 0);
        uint256 pot0 = core.ethPot();
        vm.recordLogs();
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        (uint256 cost, uint256 buyPaid) = _listingBought(vm.getRecordedLogs());

        assertTrue(atk.tried(), "the attacker tried the flush");
        assertFalse(atk.flushOk(), "the flush inside the measured call reverted");
        assertEq(address(feeRouter).balance, held, "only the attacker top up waits in the router");
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(cost, price, "the measured cost is the price");
        assertEq(booked, price + buyPaid, "the cost basis is the price plus the buy payment");
        uint256 toRedeemBurn = engine * core.settings().feeToRedeemBurnBps / 10_000;
        assertEq(
            core.ethPot(),
            pot0 + engine - toRedeemBurn - price - buyPaid,
            "the pot took the held fees and paid the cost"
        );
        assertEq(
            address(core).balance,
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(),
            "pots stay consistent"
        );
    }

    function _listingBought(Vm.Log[] memory logs) internal pure returns (uint256 cost, uint256 paid) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.ListingBought.selector) {
                (cost, paid,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    /// a flush that is not caught fails the payment, so the whole `buyListing` reverts
    function test_FIXED_anUncaughtMidCallFlushFailsTheWholePurchase() public {
        uint256 held = _queueFees(1.5 ether);
        uint256 id = _list();
        uint256 price = core.ethRate();
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        vm.deal(address(atk), held);
        atk.arm(false, held);
        bytes memory data = _order(id, price, atk);
        vm.prank(maker);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        assertEq(address(feeRouter).balance, 0, "the push inside the call reverted with it");
        assertEq(address(atk).balance, held, "the attacker kept its eth");
    }

    /// the top up that waited in the router is booked by a normal flush right after, with the owner's fee split:
    /// the mid call attempt only delayed it
    function test_FIXED_aFlushRightAfterTheMeasuredCallBooksTheFeesWithTheSplit() public {
        Settings memory cs = core.settings();
        cs.feeToRedeemBurnBps = 5_000;
        _setSettings(cs);
        uint256 held = _queueFees(1.5 ether);
        uint256 id = _list();
        uint256 price = core.ethRate();
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        vm.deal(address(atk), held);
        atk.arm(true, held);
        bytes memory data = _order(id, price, atk);
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        assertFalse(atk.flushOk());

        uint256 bb0 = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        uint256 burn0 = core.ethRedeemBurn();
        uint256 shared = feeRouter.splitOn() ? held * 112_778 / 1e6 : 0;
        uint256 delivered = _flush();
        assertEq(delivered, held - shared, "the engine part of the held fees arrived, exactly");
        assertEq(core.ethToBuyback() - bb0, 0, "nothing to the buyback pot");
        uint256 toRedeemBurn = delivered * 5_000 / 10_000;
        assertEq(core.ethRedeemBurn() - burn0, toRedeemBurn, "half to the reserve");
        assertEq(core.ethPot() - pot0, delivered - toRedeemBurn, "the rest to the pot");
        assertEq(
            address(core).balance,
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(),
            "booked once, nothing left over"
        );
        assertEq(address(feeRouter).balance, 0);
    }

    /// a legitimate keeper flush is never blocked for long: it fails only inside someone else's measured call, the
    /// flag is gone when that call ends (success or revert), and the very next flush works, round after round
    function test_FIXED_aKeeperFlushIsNeverBlockedOutsideAMeasuredCall() public {
        for (uint256 round; round < 3; ++round) {
            uint256 held = _queueFees(1 ether);
            uint256 id = _list();
            uint256 price = core.ethRate();
            FlushingPayee atk = new FlushingPayee(address(feeRouter));
            vm.deal(address(atk), held);
            atk.arm(round != 1, held);
            bytes memory data = _order(id, price, atk);
            vm.prank(maker);
            if (round == 1) vm.expectRevert(ICore.CallFailed.selector);
            core.buyListing(price, data, id, Mainnet.SEAPORT);
            if (round == 1) {
                // the call reverted whole and took the push with it: a later swap leaves the bounty again
                assertEq(address(feeRouter).balance, 0);
                vm.deal(address(feeRouter), held);
            }
            assertEq(address(feeRouter).balance, held, "waiting");
            // same transaction, right after the door (success or revert): the flush goes through
            uint256 pot0 = core.ethPot();
            uint256 delivered = _flush();
            assertGt(delivered, 0, "the keeper flush is not blocked");
            Settings memory cs = core.settings();
            uint256 toPot = delivered - delivered * cs.feeToRedeemBurnBps / 10_000;
            assertEq(core.ethPot() - pot0, toPot, "booked");
            assertEq(address(feeRouter).balance, 0);
            _warp(1 hours);
        }
    }

    function test_OK_theSameOrderWithAnEmptyRouterPaysNothing() public {
        uint256 id = _list();
        uint256 price = core.ethRate();
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        atk.arm(true, 0);
        bytes memory data = _order(id, price, atk);
        assertEq(address(feeRouter).balance, 0);
        uint256 maker0 = maker.balance;
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(maker.balance - maker0, price - 1, "no payment at the ceiling");
        assertEq(booked, price, "the cost basis is the price");
    }
}

/// F2. the buyback has no min out. FLOW 10.1 and ARCHITECTURE item 17 say a sandwich of a slice loses money after both
/// skims. at the v2 skim of 6.9 points that failed at the old 5 eth bound (V2R-2). the bound is now 2 eth
contract ReviewSandwichTest is FeeBase {
    function _sandwich(uint256 slice, uint256 mult) internal returns (int256 net) {
        uint256 snap = vm.snapshotState();
        vm.deal(address(core), address(core).balance + slice);
        vm.store(address(core), bytes32(uint256(7)), bytes32(slice));
        assertEq(core.ethToBuyback(), slice, "slot 7 is ethToBuyback");
        _forceSlice(slice);
        vm.roll(block.number + 100);
        address mev = _user("mev");
        uint256 front = slice * mult;
        uint256 got = _buyCoin(mev, front);
        vm.prank(keeper);
        core.buyback();
        uint256 back = _sellCoin(mev, got);
        net = int256(back) - int256(front);
        vm.revertToState(snap);
    }

    /// writes `buybackSlice` (bits 0 to 127 of the second settings word) and `buybackDelay` 1 (bits 176 to 191 of the
    /// first word) straight into storage, so a slice above the bound can be simulated
    function _forceSlice(uint256 slice) internal {
        bytes32 at0 = bytes32(uint256(keccak256("credits.core.settings.v1")));
        bytes32 at1 = bytes32(uint256(at0) + 1);
        uint256 w = uint256(vm.load(address(core), at1));
        uint256 m128 = type(uint128).max;
        w = (w & ~m128) | slice;
        vm.store(address(core), at1, bytes32(w));
        // buybackDelay: bits 176 to 191 of the first settings word, after nine uint16 fields and `peakHalfLife`
        uint256 w0 = uint256(vm.load(address(core), at0));
        w0 = (w0 & ~(uint256(type(uint16).max) << 176)) | (uint256(1) << 176);
        vm.store(address(core), at0, bytes32(w0));
        assertEq(core.settings().buybackSlice, slice, "slice written");
        assertEq(core.settings().buybackDelay, 1, "delay written");
    }

    function _best(uint256 slice) internal returns (int256 best) {
        uint256[6] memory m = [uint256(1), 2, 3, 4, 6, 8];
        best = type(int256).min;
        for (uint256 i; i < 6; ++i) {
            int256 r = _sandwich(slice, m[i]);
            emit log_named_int(string.concat(vm.toString(slice / 1 ether), " eth slice, front x", vm.toString(m[i])), r);
            if (r > best) best = r;
        }
    }

    /// V2R-2 fixed: the bound is 1 eth (FLOW decision 51), and a sandwich of a slice at the bound loses for every front run size
    function test_FIXED_sandwichOfTheSliceAtTheBoundLosesAtTheLaunchSkim() public {
        _skipToSplitStart();
        Settings memory s = core.settings();
        s.buybackSlice = 1 ether + 1;
        vm.prank(core.owner());
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackSlice")));
        core.setSettings(s);
        assertLt(_best(0.5 ether), 0, "the 0.5 eth launch slice loses");
        assertLt(_best(1 ether), 0, "the 1 eth slice at the bound loses");
    }

    /// why the bound is not higher: a 3 eth slice (inside the old 5 eth bound) profited at the same state
    function test_OK_aThreeEthSliceWouldHaveProfited() public {
        _skipToSplitStart();
        assertGt(_best(3 ether), 0, "3 eth slice profits, so it stays out of bounds");
    }
}


/// a payee that does real work on receipt (a splitter: three cold storage writes, about 70k gas)
contract HeavyPayee {
    uint256 public a;
    uint256 public b;
    uint256 public got;

    receive() external payable {
        got += msg.value;
        a = 1;
        b = 1;
    }
}

/// F3. anyone chooses the gas of `flush`
contract ReviewRouterGasTest is FeeBase {
    HeavyPayee internal heavy;

    function setUp() public override {
        super.setUp();
        heavy = new HeavyPayee();
        _skipToSplitStart();
        autoFlush = false;
        _buyCoin(trader, 3 ether);
        _flush(); // the first flush at the start turns the split on
        assertTrue(feeRouter.splitOn());
        address[] memory who = new address[](1);
        who[0] = address(heavy);
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 112_778;
        vm.prank(owner);
        feeRouter.setPayees(who, ppm);
    }

    function _tryFlush(uint256 g) internal returns (bool ok) {
        vm.prank(flusher);
        (ok,) = address(feeRouter).call{gas: g}(abi.encodeCall(IFeeRouter.flush, ()));
    }

    function test_OK_aNormalFlushPaysTheHeavyPayeeDirectly() public {
        _buyCoin(trader, 3 ether);
        assertTrue(_tryFlush(1_000_000));
        assertGt(heavy.got(), 0, "paid within the 100k cap");
        assertEq(feeRouter.owed(address(heavy)), 0);
    }

    /// the flusher picks the gas limit. starving the payee call burns the 63/64 it was given, which leaves too little
    /// for the engine call, so the flush reverts as a whole: there is no gas limit at which the flush passes and the payee
    /// is credited instead of paid
    function test_OK_noGasLimitDivertsAPayeeIntoOwedWhileTheFlushPasses() public {
        _buyCoin(trader, 3 ether);
        uint256 snap = vm.snapshotState();
        uint256 passes;
        for (uint256 g = 100_000; g <= 400_000; g += 2_500) {
            if (_tryFlush(g)) {
                ++passes;
                assertEq(feeRouter.owed(address(heavy)), 0, "a passing flush paid the payee");
                assertGt(heavy.got(), 0);
            } else {
                assertEq(heavy.got(), 0, "a reverted flush paid nothing");
            }
            vm.revertToState(snap);
        }
        assertGt(passes, 0);
    }
}

/// calls a Core door and flushes the router once from its own `receive`, i.e. from inside the payout the door makes last
contract FlushOnPayout {
    IFeeRouter public immutable ROUTER;
    bool public armed;

    constructor(address router_) {
        ROUTER = IFeeRouter(payable(router_));
    }

    function go(address target, bytes calldata data) external {
        armed = true;
        (bool ok, bytes memory why) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(why, 0x20), mload(why))
            }
        }
    }

    function approveAll(address nft, address op) external {
        (bool ok,) = nft.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        require(ok);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            ROUTER.flush();
        }
    }
}

/// F4. a stranger flushes the router from inside the payout of every door that pays the caller. the doors pay last, so
/// the booking lands on final state and the books stay exact
contract ReviewFlushInPayoutTest is FeeBase {
    FlushOnPayout internal atk;

    function setUp() public override {
        super.setUp();
        atk = new FlushOnPayout(address(feeRouter));
        _stock();
        autoFlush = false;
    }

    function _queue() internal returns (uint256 held) {
        _buyCoin(trader, 4 ether);
        held = address(feeRouter).balance;
        assertGt(held, 0.1 ether);
    }

    function _consistent() internal view {
        assertEq(
            address(core).balance, core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), "every wei is booked"
        );
        assertEq(address(feeRouter).balance, 0, "the router was flushed");
    }

    function test_OK_flushInsideTheCompose() public {
        autoFlush = true;
        _composeOnce(); // fills the pile and composes once; the state before is kept
        vm.revertToState(preComposeSnap);
        autoFlush = false;
        vm.fee(composeBasefee);
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeCall(ICore.compose, ()));
        assertEq(address(atk).balance, a0, "the compose pays the caller nothing");
        assertEq(core.ethPot(), pot0 + _toPot(toEngine), "pot = old + the booked fees");
        _consistent();
    }

    function test_OK_flushInsideTheBuybackTip() public {
        _fillEthBuyback();
        vm.roll(block.number + 30);
        _queue();
        uint256 bb0 = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        atk.go(address(core), abi.encodeCall(ICore.buyback, ()));
        assertLt(core.ethToBuyback(), bb0, "the slice left the buyback pot");
        assertGt(core.ethPot(), pot0, "the flushed fees were booked on top");
        _consistent();
    }

    function test_OK_flushInsideTheSellForEthPayout() public {
        autoFlush = true;
        _fundPot(3 ether);
        autoFlush = false;
        uint256[] memory ids = _credits(address(atk), 1);
        atk.approveAll(address(CREDITS), address(core));
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeWithSignature("sellForEth(uint256[])", ids));
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 price = address(atk).balance - a0;
        assertGt(price, 0);
        assertEq(core.ethPot(), pot0 - price + _toPot(toEngine), "pot = old - price + the booked fees");
        _consistent();
    }
}

/// pushes eth with the 2,300 gas stipend only (call with zero gas and a value), like the v2 hook does
contract StipendPusher {
    function push(address to) external payable returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(0, to, callvalue(), 0, 0, 0, 0)
        }
    }
}

/// sends its balance to `to` by selfdestruct, which no `receive` can refuse
contract Forcer {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

/// F6. the stipend push, forced eth, who can launch, who the Core books
contract ReviewFeePathTest is FeeBase {
    function test_OK_stipendPushReachesTheRouterTheCoreAndEveryStackSender() public {
        StipendPusher p = new StipendPusher();
        assertTrue(p.push{value: 1}(address(feeRouter)), "router receive fits the stipend");
        assertTrue(p.push{value: 1}(address(core)), "the Core receive fits the stipend for a non source sender");
        assertEq(core.ethPot(), 0, "and books nothing");
        assertEq(address(feeRouter).balance, 1);
    }

    function test_OK_forcedEthInTheRouterAndTheCoreIsBookedExactlyOnce() public {
        _skipToSplitStart();
        Forcer a = new Forcer{value: 2 ether}();
        a.boom(payable(address(feeRouter)));
        Forcer b = new Forcer{value: 1 ether}();
        b.boom(payable(address(core)));
        uint256 held = address(feeRouter).balance;
        assertGe(held, 2 ether);
        assertLe(held, 2 ether + 10, "2 eth plus launch dust");
        (, uint256 toEngine) = _routerSplit(held);
        _flush(); // the first flush at the split start: everything to the engine
        uint256 toPot = _toPot(toEngine);
        assertEq(core.ethPot(), toPot, "the forced router eth was booked as fees");
        assertEq(core.ethRedeemBurn(), _toRedeemBurn(toEngine), "and the redeem burn share to its reserve");
        assertEq(address(core).balance, toEngine + 1 ether, "the forced Core eth is not booked yet");
        core.skim();
        assertEq(core.ethPot(), toPot + 1 ether);
        core.skim();
        assertEq(core.ethPot(), toPot + 1 ether, "a second skim books nothing");
        _solvent();
    }

    function test_OK_onlyTheFactoryOwnerCanLaunchAndTheFactoryIsDeprecated() public {
        assertTrue(FACTORY.deprecated());
        address stranger = _user("stranger");
        vm.deal(stranger, 1 ether);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(owner, creator, "S", "S", keccak256("s"));
        uint256 fee = FACTORY.deployFee();
        vm.prank(stranger);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, 2000);
        vm.prank(stranger);
        vm.expectRevert();
        FACTORY.deployToken{value: fee}(cfg);
    }
}
