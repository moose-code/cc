// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Prod} from "./utils/Prod.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// a listing target that delivers the credit and then tries to adopt it inside the guarded call
contract AdoptingTarget {
    address public immutable core;
    bool public adoptOk;
    bytes public adoptOut;

    constructor(address core_) {
        core = core_;
    }

    function fill(uint256 id) external payable {
        (bool ok,) = Mainnet.CREDITS
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), msg.sender, id));
        require(ok, "deliver");
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        (adoptOk, adoptOut) = core.call(abi.encodeWithSignature("adopt(uint256[])", ids));
    }

    receive() external payable {}
}

/// `adopt` of the Core on the fork: the real Core, Credits, Statements and controller. credits are sent to the
/// Core outside its doors with a plain `transferFrom`
contract AdoptTest is Fixture {
    address internal stranger = address(0xAD0);

    /// `n` fresh credits transferred straight to the Core
    function _gift(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller);
            CREDITS.transferFrom(seller, address(core), ids[i]);
        }
    }

    /// the cost basis adopt records for `id`: the price state times its score over RATE_SCORE, at least 1 wei
    function _basis(uint256 id) internal view returns (uint256) {
        // the price state scaled by score plus the artist royalty the eth bid would pay, at least 1 wei (decision 163)
        uint256 pay = core.ethPrice() * _scoreOf(id) / RATE_SCORE;
        uint256 b = pay + pay * core.settings().buyToArtistBps / 10_000;
        return b == 0 ? 1 : b;
    }

    function _adopt(uint256[] memory ids) internal {
        vm.prank(stranger);
        core.adopt(ids);
    }

    // promise: SPEC 4 adopt puts a stray credit into the pile at the price state
    function test_OK_aCreditSentStraightToTheCoreIsAdoptedAtThePriceState() public {
        uint256[] memory ids = _gift(1);
        uint256 id = ids[0];
        (bool inPile, uint256 cost0,) = core.creditInfo(id);
        assertFalse(inPile);
        assertEq(cost0, 0, "no record");
        // the pot is empty: the read is clamped to zero while the price state is the opening rate
        assertEq(core.ethRate(), 0, "the clamped read is zero");
        assertEq(core.ethPrice(), core.RATE_START(), "the price state is the opening rate");
        uint256 want = _basis(id);
        assertGt(want, 0);
        assertEq(
            want,
            core.RATE_START() * _scoreOf(id) * (10_000 + core.settings().buyToArtistBps) / RATE_SCORE / 10_000,
            "the basis is the price state scaled by score / RATE_SCORE plus the artist royalty"
        );

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.CreditAdopted(id, want);
        _adopt(ids);

        (bool inPile1, uint256 cost, uint64 at) = core.creditInfo(id);
        assertTrue(inPile1, "in the pile");
        assertEq(cost, want, "cost basis");
        assertEq(at, block.timestamp, "acquiredAt");
        assertEq(core.pileSize(), 1);
        assertEq(core.pilePage(0, 1)[0], id);
        assertEq(CREDITS.ownerOf(id), address(core));
    }

    // promise: INTEGRATION InPile on adopt
    function test_REVERT_adoptTwiceInOneCallOrTwoCalls() public {
        uint256[] memory ids = _gift(1);
        _adopt(ids);
        vm.expectRevert(abi.encodeWithSignature("InPile()"));
        _adopt(ids);
        uint256[] memory twice = _gift(1);
        uint256[] memory both = new uint256[](2);
        both[0] = twice[0];
        both[1] = twice[0];
        vm.expectRevert(abi.encodeWithSignature("InPile()"));
        _adopt(both);
        assertEq(core.pileSize(), 1, "the failed call changed nothing");
    }

    // promise: INTEGRATION NotHolder on adopt
    function test_REVERT_aCreditTheCoreDoesNotHold() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.expectRevert(abi.encodeWithSignature("NotHolder()"));
        _adopt(ids);
        uint256[] memory gone = new uint256[](1);
        gone[0] = type(uint128).max;
        vm.expectRevert();
        _adopt(gone);
        assertEq(core.pileSize(), 0);
    }

    // promise: INTEGRATION Empty, ZeroId on adopt
    function test_REVERT_emptyAndZero() public {
        vm.expectRevert(abi.encodeWithSignature("Empty()"));
        _adopt(new uint256[](0));
        vm.expectRevert(abi.encodeWithSignature("ZeroId()"));
        _adopt(new uint256[](1));
    }

    // promise: SPEC 4 adopt is atomic over the list
    function test_REVERT_aBatchWithOneBadIdChangesNothing() public {
        uint256[] memory good = _gift(2);
        uint256[] memory foreign = _credits(seller, 1);
        uint256[] memory mixed = new uint256[](3);
        mixed[0] = good[0];
        mixed[1] = good[1];
        mixed[2] = foreign[0];
        vm.expectRevert(abi.encodeWithSignature("NotHolder()"));
        _adopt(mixed);
        assertEq(core.pileSize(), 0);
        (bool inPile,,) = core.creditInfo(good[0]);
        assertFalse(inPile);
    }

    /// the rate state and the pots, as one value to compare
    struct State {
        uint256 rate;
        uint256 price;
        uint256 stored;
        uint64 checkpointTime;
        uint64 fillTime;
        uint256 pot;
        uint256 buyback;
        uint256 balance;
        uint256 lastFill;
        uint256 minuteStart;
        uint256 bucket;
    }

    function _state() internal view returns (State memory s) {
        s.rate = core.ethRate();
        s.price = core.ethPrice();
        s.stored = core.rateAtCheckpoint();
        s.checkpointTime = core.checkpointTime();
        s.fillTime = core.lastFillTime();
        s.pot = core.ethPot();
        s.buyback = core.ethToBuyback();
        s.balance = address(core).balance;
        (s.lastFill, s.minuteStart, s.bucket) = _anchor();
    }

    // promise: inv 18 and decision 176 adopt moves no eth and checkpoints earned climb before changing the pile
    function test_OK_adoptCheckpointsRateWithoutMovingPots() public {
        _fundPot(2 ether);
        // one sale moves the rate state
        uint256[] memory sold = _credits(seller, 4);
        vm.prank(seller);
        core.sellForEth(sold);
        _warp(10 minutes);
        uint256[] memory ids = _gift(5);

        State memory a = _state();
        _adopt(ids);
        State memory b = _state();

        assertEq(b.rate, a.rate, "ethRate");
        assertEq(b.price, a.price, "ethPrice");
        assertEq(b.stored, a.price, "stored rate captures the earned climb");
        assertEq(b.checkpointTime, block.timestamp, "checkpoint is written before the pile changes");
        assertEq(b.fillTime, a.fillTime, "fill time");
        assertEq(b.pot, a.pot, "pot");
        assertEq(b.buyback, a.buyback, "buyback pot");
        assertEq(b.balance, a.balance, "no eth moves");
        assertEq(b.lastFill, a.lastFill, "ceiling anchor");
        assertEq(b.minuteStart, a.minuteStart, "minute floor");
        assertEq(b.bucket, a.bucket, "minute bucket");
        assertEq(core.pileSize(), 4 + 5, "the sold and the adopted credits are in the pile");
    }

    // promise: SPEC 1 one pile: adopted credits compose like any other
    function test_OK_aPageOfAdoptedCreditsComposesIntoAStatementWorthTheirBases() public {
        _fundPot(1 ether);
        uint256[] memory ids = _gift(80);
        _adopt(ids);
        assertEq(core.pileSize(), 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (, uint256 cost,) = core.creditInfo(ids[i]);
            sum += cost;
        }
        assertGt(sum, 0);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        (bool held, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(cost, sum, "statement cost is the sum of the bases");
        assertEq(core.pileSize(), 0);
        // the asking price is computed from that cost
        assertEq(ctl.priceOf(sid), cost * ctl.startBps() / 10_000, "asking price");
        assertGe(ctl.priceOf(sid), cost * core.settings().saleFloorBps / 10_000, "at or above the floor");
    }

    /// a successor Core with its own controller (the controller holds the address of its Core, so both addresses are
    /// computed from the next two nonces of this contract)
    function _successor() internal returns (ICore succ) {
        uint64 n = vm.getNonce(address(this));
        address coreAt = vm.computeCreateAddress(address(this), n + 1);
        IControllerV1 ctl2 = Prod.newController(coreAt, lc.sale);
        succ = _successorCore(address(ctl2), lc.rateStart, _settings());
        assertEq(address(succ), coreAt, "predicted successor address");
    }

    /// `adopt` on the successor for `ids`, from a stranger. returns the sum of the bases after checking each one
    function _adoptOnSuccessor(ICore succ, uint256[] memory ids) internal returns (uint256 sum) {
        // the successor prices the credits with its own price state: its opening rate
        uint256 price = succ.ethPrice();
        assertEq(price, lc.rateStart);
        vm.prank(stranger);
        succ.adopt(ids);
        assertEq(succ.pileSize(), ids.length, "the pile is restored");
        assertEq(succ.pilePage(0, 1)[0], ids[0], "in the order of the call");
        uint256 royaltyBps = succ.settings().buyToArtistBps;
        for (uint256 i; i < ids.length; ++i) {
            (bool p, uint256 cost,) = succ.creditInfo(ids[i]);
            assertTrue(p);
            uint256 pay = price * _scoreOf(ids[i]) / RATE_SCORE;
            uint256 want = pay + pay * royaltyBps / 10_000;
            if (want == 0) want = 1;
            assertEq(cost, want);
            sum += cost;
        }
    }

    // promise: SPEC 9 a successor builds its pile with adopt
    /// `migrate` moves the credits of the old Core to a second Core, and `adopt` on that Core puts them back into a
    /// pile that composes
    function test_OK_migrateThenAdoptOnTheSuccessorRestoresThePile() public {
        _fillEthPile(80);
        uint256[] memory ids = core.pilePage(0, 80);
        assertEq(ids.length, 80);
        ICore succ = _successor();

        vm.startPrank(owner);
        core.setSuccessor(address(succ));
        core.migrate(100);
        vm.stopPrank();
        assertEq(core.pileSize(), 0, "the old pile is empty");
        for (uint256 i; i < 80; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), address(succ), "moved to the successor");
        }
        (bool inPile,,) = succ.creditInfo(ids[0]);
        assertFalse(inPile, "the successor has no record yet");
        assertEq(succ.pileSize(), 0);

        uint256 sum = _adoptOnSuccessor(succ, ids);

        // the successor controller carries the launch credit sale: the newest adopted credit must be past its window
        _warp(Mainnet.defaultCredit().window + 1);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        succ.compose();
        (bool held, uint256 stCost,) = succ.statementInfo(supply + 1);
        assertTrue(held);
        assertEq(stCost, sum, "the pot of the successor is empty, so the cost is the sum of the bases");
        assertEq(succ.pileSize(), 0);
    }

    // promise: INTEGRATION Retired on adopt
    /// a credit that left through `migrate` keeps its old record with the pile flag cleared. the Core is retired by the
    /// migrate, so the credit cannot be adopted there again (a successor adopts it, see the test above)
    function test_REVERT_aMigratedCreditThatComesBackIsNotAdoptedByTheRetiredCore() public {
        uint256[] memory ids = _fillEthPile(3);
        (, uint256 oldCost,) = core.creditInfo(ids[0]);
        assertGt(oldCost, 0);
        address sink = address(0xA11CE);
        vm.etch(sink, hex"00");
        vm.startPrank(owner);
        core.setSuccessor(sink);
        core.migrate(10);
        vm.stopPrank();
        (bool inPile, uint256 stale,) = core.creditInfo(ids[0]);
        assertFalse(inPile);
        assertEq(stale, oldCost, "the record stays");
        vm.prank(sink);
        CREDITS.transferFrom(sink, address(core), ids[0]);
        _warp(1 days);
        vm.expectRevert(ICore.Retired.selector);
        core.adopt(_one(ids[0]));
        (bool p,,) = core.creditInfo(ids[0]);
        assertFalse(p, "a refused adopt booked the credit");
        assertEq(core.pileSize(), 0);
    }

    // promise: INTEGRATION Reentrancy on adopt
    /// inside a guarded call (a listing target mid buy) `adopt` is refused, so a credit being bought cannot be put in
    /// the pile twice
    function test_REVERT_adoptInsideAGuardedCall() public {
        _fundPot(1 ether);
        uint256 id = LISTED_A;
        AdoptingTarget t = new AdoptingTarget(address(core));
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
        uint256 value = core.ethRate() / 2;
        vm.prank(keeper);
        _buyRaw(value, abi.encodeCall(AdoptingTarget.fill, (id)), id, address(t));
        assertFalse(t.adoptOk(), "adopt inside the buy failed");
        assertEq(bytes4(t.adoptOut()), bytes4(0xab143c06), "Reentrancy()");
        assertEq(core.pileSize(), 1, "the credit is in the pile once");
        assertEq(core.pilePage(0, 1)[0], id);
        (bool p,,) = core.creditInfo(id);
        assertTrue(p);
    }

    // promise: SPEC 4 adopt books pending fee eth before it prices
    /// the fee income is booked before the price is read, like at every door that spends from the pot
    function test_OK_adoptBooksTheFeesFirst() public {
        autoBook = false;
        _buyCoin(funder, 3 ether);
        assertGt(address(core).balance - _tracked(), 0, "the core holds unbooked fees");
        uint256 pot = core.ethPot();
        uint256[] memory ids = _gift(1);
        vm.expectEmit(false, false, false, false, address(core));
        emit ICore.FeesAdded(0, 0);
        _adopt(ids);
        assertEq(address(core).balance, _tracked(), "the fees were booked");
        assertGt(core.ethPot(), pot, "the fees are in the pot");
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, _basis(ids[0]), "the basis is read after the book");
    }

    // promise: SPEC 4 an adopted credit enters at the price state scaled by score / RATE_SCORE plus the artist royalty (cost basis)
    function test_FUZZ_theBasisIsThePriceStateScaledByScore(uint256 wait, uint8 count) public {
        wait = bound(wait, 0, 30 days);
        count = uint8(bound(count, 1, 6));
        _fundPot(1 ether);
        _warp(wait);
        uint256[] memory ids = _gift(count);
        uint256 price = core.ethPrice();
        _adopt(ids);
        for (uint256 i; i < count; ++i) {
            (, uint256 cost,) = core.creditInfo(ids[i]);
            uint256 pay = price * _scoreOf(ids[i]) / RATE_SCORE;
            uint256 want = pay + pay * core.settings().buyToArtistBps / 10_000;
            if (want == 0) want = 1;
            assertEq(cost, want, "basis is the price state scaled by score / RATE_SCORE plus the artist royalty");
            assertGt(cost, 0);
        }
    }
}
