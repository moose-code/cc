// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IRedeemer, CcQuote, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Phase3, IEnsRegistry, IEnsResolver} from "../script/Phase3.s.sol";
import {IMarketRedeemer} from "../src/interfaces/IMarketRedeemer.sol";
import {ICreditBid} from "../src/interfaces/ICreditBid.sol";
import {IdleLoosening, BalanceBid} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

interface IPhase3Coin {
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// a fork-only redeemer whose answer the test sets: it exercises the vesting and deferred modes and the treasury's
/// bucket and cap refusals, which the pro-rata redeemer never reaches
contract FixedRedeemer is IRedeemer {
    uint256 internal amount;
    uint8 internal mode;
    uint32 internal duration;

    function set(uint256 a, uint8 m, uint32 d) external {
        (amount, mode, duration) = (a, m, d);
    }

    function quote(address, uint256, uint256, uint256, bytes calldata) external view returns (uint256, uint8, uint32) {
        return (amount, mode, duration);
    }
}

/// a spender that draws on command: the shape of any later module (a new bid rule, say)
contract DrawingSpender {
    function pull(address treasury, address to, uint256 amount, bool accrue) external {
        IBalanceTreasuryV2(treasury).draw(to, amount, accrue);
    }
}

/// phase 3 acceptance (docs/specs/PHASE3.md) on a fork of the head against the live Core, ControllerV2, v1 treasury,
/// BALANCE token and coin, driven through the owner script `script/Phase3.s.sol`
contract Phase3Test is LiveFixture {
    using StateLibrary for IPoolManager;

    /// the spec's pin: block 26,250,700 or later
    uint256 internal constant PIN = 26_251_200;

    Phase3 internal script;
    Phase3.Deployed internal d;
    IBalanceTreasuryV2 internal t;
    IControllerV3 internal v3;
    ICreditBid internal bidm;
    IPhase2BalanceTreasury internal v1;
    address internal user;

    function _liveForkBlock() internal pure override returns (uint256) {
        return PIN;
    }

    function setUp() public override {
        super.setUp();
        v1 = IPhase2BalanceTreasury(core.balanceModule());
        script = new Phase3();
        d = script.deploy(address(core), script.params(), false);
        t = IBalanceTreasuryV2(d.treasury);
        v3 = IControllerV3(d.controller);
        bidm = ICreditBid(d.bid);
        user = _user("phase3 user");
    }

    /// the owner's migrate run; the Core's cap stays as it is (the cap send was dropped, decision 296)
    function _migrate() internal {
        script.migrate(address(core), d, script.params(), false);
        ctl = IControllerV1(address(v3));
    }

    function test_migrationMovesEverythingAndTheCoreRunsAgainstV2() public {
        // promise: the migration moves all BALANCE and the claim reserve to v2, and the Core's exchange and Statement conversion work against v2
        uint256 custody1 = v1.custody();
        uint256 claims1 = v1.claimReserve();
        uint256 owed1 = v1.totalOwed();
        _migrate();
        assertEq(v1.custody(), owed1, "v1 keeps only its debt");
        assertEq(t.custody(), custody1 - owed1, "every other BALANCE is in v2");
        assertEq(_bucket(d.redeemer), claims1, "the claim reserve is the pro-rata bucket");

        uint256[] memory ids = _credits(seller, 1);
        uint256 pay = core.balanceBidOf(ids[0]);
        assertGt(pay, 0, "the Core's exchange quotes against v2");
        uint256 held = _balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(_balanceOf(seller) - held, pay, "the Core's exchange paid from v2");

        uint256 sid = _compose();
        vm.warp(block.timestamp + 7 days);
        uint256 rating = core.ratingOf(sid);
        uint256 before = t.custody();
        uint256 bucketBefore = _bucket(d.redeemer);
        core.redeemStatement(sid);
        uint256 got = t.custody() - before;
        assertGe(got, rating * 1e14, "the conversion returned at least par into v2");
        assertEq(_bucket(d.redeemer) - bucketBefore, got / 10, "10 percent fed the pro-rata bucket");
    }

    function test_bidBuysAdoptsAndRefusesTheResaleLoop() public {
        // promise: a real Credit sold to sellCredit is adopted, composed and converted with BALANCE back in v2, and a credit the engine resold inside the return lock is refused
        _migrate();
        // the bid is a newly registered spender: it draws nothing for a day, which also covers the return lock
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        assertEq(bidm.bidBudget(), script.params().bidBudget, "the bid step funded the bid from the surplus");

        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(bidm), true);
        (uint256 q, uint256 toArtist) = bidm.quoteCredit(ids[0]);
        assertGt(q, 0, "the bid quotes a real credit");
        uint256 budget = bidm.bidBudget();
        uint256 held = _balanceOf(seller);
        uint256 splitHeld = _balanceOf(core.artist());
        vm.prank(seller);
        bidm.sellCredit(ids, q);
        assertEq(_balanceOf(seller) - held, q, "the seller got the quote");
        assertEq(_balanceOf(core.artist()) - splitHeld, toArtist, "the split got the royalty on top");
        assertEq(budget - bidm.bidBudget(), q + toArtist, "both came from the bid bucket");
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertTrue(inPile, "the credit was adopted");

        uint256 sid = _compose();
        vm.warp(block.timestamp + 7 days);
        uint256 before = t.custody();
        core.redeemStatement(sid);
        assertGe(t.custody() - before, core.ratingOf(sid) * 1e14, "its Statement converted into v2");

        uint256 id = _ethFill(1)[0];
        vm.warp(block.timestamp + 1);
        uint256 price = v3.creditPrice(id);
        vm.deal(user, price);
        vm.prank(user);
        v3.buyCredit{value: price}(id);
        vm.prank(user);
        CREDITS.setApprovalForAll(address(bidm), true);
        vm.expectRevert(abi.encodeWithSignature("ReturnLocked(uint256)", id));
        vm.prank(user);
        bidm.sellCredit(_one(id), 0);
    }

    function test_bidCanPayAboveParUnderTheFloorMultiplier() public {
        // promise: the owner may set the v2 bid's cap above par (decision 296) and a fill then pays above par, while a cap at or above the controller's credit floor multiplier is refused
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        assertEq(bidm.bidBpsNow(), 9_500, "the shipped band is a flat 95 percent of par");
        BalanceBid memory b = script.params().bid;
        b.floorBps = 11_000;
        b.capBps = 11_000;
        b.overEthBps = 5_000;
        vm.prank(owner);
        bidm.setBid(b);
        assertEq(bidm.bidBpsNow(), 11_000, "the owner set the bid above par");
        assertLt(bidm.bidBpsNow(), v3.floorMultBps(), "under the resale floor multiplier");
        uint256 id = _credits(seller, 1)[0];
        (uint256 q,) = bidm.quoteCredit(id);
        assertEq(q, _scoreOf(id) * 1e14 * 11_000 / 10_000, "a fill pays 110 percent of par");
        b.capBps = uint16(v3.floorMultBps());
        vm.expectRevert(abi.encodeWithSignature("BadSetting(bytes32)", bytes32("bidCap")));
        vm.prank(owner);
        bidm.setBid(b);
    }

    function test_redeemersPayFromTheirBucketInsideTheirCaps() public {
        // promise: redeemer 1 burns CC and pays ccIn * B / S less the fee and reverts on a stale epoch; a test redeemer's vesting and deferred payouts never exceed its bucket or caps
        _migrate();
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(owner);
        t.setSpenderOn(d.redeemer, true);
        uint64 epoch = _epoch(d.redeemer);
        vm.expectRevert(abi.encodeWithSignature("RedemptionOff()"));
        vm.prank(user);
        t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch, "");
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch + 1, "");

        uint256 b = _bucket(d.redeemer);
        uint256 s = IPhase3Coin(address(coin)).totalSupply();
        uint256 held = _balanceOf(user);
        vm.prank(user);
        (uint256 paid,) = t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch, "");
        assertEq(paid, (cc / 4) * b / s, "ccIn * B / S at a zero fee");
        assertEq(_balanceOf(user) - held, paid, "paid at once to the recipient");
        assertEq(IPhase3Coin(address(coin)).totalSupply(), s - cc / 4, "the CC was burned");

        FixedRedeemer r = new FixedRedeemer();
        vm.startPrank(owner);
        t.registerSpender(address(r), 1_000 ether, 1_500 ether, 2_000 ether);
        t.allocate(address(r), 2_500 ether);
        t.setSpenderOn(address(r), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        epoch = _epoch(address(r));
        uint256 unit = cc / 16;

        r.set(1_000 ether, 1, 100);
        uint256 committed = t.totalCommitted();
        (, uint256 vestId) = _redeem(address(r), unit, epoch);
        assertEq(t.totalCommitted() - committed, 1_000 ether, "the vesting payout is reserved in full");
        vm.warp(block.timestamp + 50);
        assertEq(t.release(vestId), 500 ether, "half vested at half time");
        r.set(500 ether, 2, 100);
        (, uint256 deferId) = _redeem(address(r), unit, epoch);
        vm.expectRevert(abi.encodeWithSignature("NothingDue()"));
        t.release(deferId);
        vm.warp(block.timestamp + 100);
        assertEq(t.release(vestId), 500 ether, "the rest of the vesting");
        assertEq(t.release(deferId), 500 ether, "the deferred payout at its time");
        assertEq(_balanceOf(user) - held - paid, 1_500 ether, "every committed payout reached the recipient");

        r.set(1, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        _redeem(address(r), unit, epoch); // the period cap of 1,500 is used
        vm.warp(block.timestamp + 1 days);
        r.set(1_000 ether + 1, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBucket()"));
        _redeem(address(r), unit, epoch); // 1,000 left in the bucket
        r.set(501 ether, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        _redeem(address(r), unit, epoch); // the lifetime cap of 2,000 has 500 left
        r.set(500 ether, 0, 0);
        _redeem(address(r), unit, epoch);
        assertEq(_bucket(address(r)), 500 ether, "only its own bucket paid");
    }

    function test_breakEvenRunKeepsWorkingAboveTheCushion() public {
        // promise: a scripted run of bid fills, conversions and redemptions leaves working funds at or above the cushion and the treasury solvent; the cushion bounds what leaves working funds, not the loop's profit (the artist royalty and the conversion contribution are costs the cushion does not stop), so this is a solvency and allocation check, not break even
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        vm.prank(owner);
        t.setSpenderOn(d.redeemer, true);
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(bidm), true);
        _assertAboveCushion("after the migration");
        for (uint256 round; round < 2; ++round) {
            uint256[] memory ids = _credits(seller, 3);
            vm.prank(seller);
            bidm.sellCredit(ids, 0);
            _assertAboveCushion("after bid fills");
            uint256 sid = _compose();
            vm.warp(block.timestamp + 7 days);
            core.redeemStatement(sid);
            _assertAboveCushion("after a conversion");
            t.sweep();
            _assertAboveCushion("after a sweep");
            _redeem(d.redeemer, cc / 4, _epoch(d.redeemer));
            _assertAboveCushion("after a redemption");
        }
        assertTrue(t.solvent(), "custody covers every earmark");
    }

    function test_controllerV3BandLooseningAndViews() public {
        // promise: V3 passes the band check at the live parameters with headroom, its idle loosening ships at zero and once enabled is bounded and returns to zero on a purchase, and every view the Core, keeper, indexer and web read answers
        _migrate();
        (uint256 ccRef, bool okcc) = v3.ccPrice();
        assertTrue(v3.ccPoolKeySet() && okcc && ccRef != 0, "the migrate run set the CC reference");
        (, uint16 step, uint16 tol,,,) = v3.quote();
        uint256 margin = core.settings().balanceBidMarginBps;
        assertLt((10_000 + uint256(step)) * (10_000 + tol) * (10_000 - margin), 0.995e12, "at least 50 bps headroom at the pinned margin");
        assertLt((10_000 + uint256(step)) * (10_000 + tol) * (10_000 - 500), 0.995e12, "and at the live margin 500 of decision C12, the 95 percent exchange");
        _checkLoosening();
        _checkViews();
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        core.refreshReference();
        (, okcc) = v3.ccPrice();
        assertFalse(okcc, "a stale CC reference pauses");
    }

    /// shipped at cap 0; once the owner sets a cap the loosening stops at it, carries into the buy price and returns to
    /// zero on a purchase
    function _checkLoosening() internal {
        vm.warp(block.timestamp + 30 days);
        assertEq(v3.idleLoosenBps(), 0, "shipped at cap 0: no loosening above value");
        vm.prank(owner);
        v3.setIdleLoosening(IdleLoosening({stepSeconds: 600, bps: 50, capBps: 700}));
        v3.syncFill();
        uint256 l0 = v3.idleLoosenBps();
        (uint256 vb0,) = v3.valuePerPoint(false);
        vm.warp(block.timestamp + 30 days);
        assertEq(v3.idleLoosenBps(), 700, "the loosening stops at its cap");
        (uint256 vb1,) = v3.valuePerPoint(false);
        assertApproxEqRel(vb1 * (10_000 + l0), vb0 * 10_700, 1e12, "the buy price carries the loosening");
        _ethFill(1);
        assertEq(v3.idleLoosenBps(), 0, "a purchase makes the tail unknown: no loosening");
        v3.syncFill();
        assertEq(v3.idleLoosenBps(), 0, "synced to the purchase: no loosening");
    }

    /// every controller view the Core, keeper, indexer and web read
    function _checkViews() internal {
        uint256 id = core.pilePage(0, 1)[0];
        v3.nextPage();
        (,, uint64 acquiredAt) = core.creditInfo(id);
        v3.pastWindow(acquiredAt);
        assertGt(v3.creditPrice(id), 0, "creditPrice");
        (uint256 vb, bool okb) = v3.valuePerPoint(false);
        assertTrue(okb && vb != 0, "valuePerPoint(false)");
        (, bool okc) = v3.balanceClampFor(1_000_000, 1e20);
        assertTrue(okc, "balanceClampFor");
        assertGt(core.ethRate(), 0, "the Core's eth bid reads V3");
        assertGt(core.balanceBidOf(id), 0, "the Core's balance bid reads V3");
        (uint256 spot, bool oks) = v3.spotPrice();
        assertTrue(oks && spot != 0 && v3.referencePrice() != 0 && v3.referenceTime() != 0, "the reference");
        assertTrue(v3.balancePoolKeySet() && v3.creditSaleOn() && v3.statementSalesEnabled(), "flags");
        assertEq(v3.creditSpreadBps(), script.params().creditSpreadBps, "the deploy set the spread, whatever V2 held");
        assertEq(v3.floorMultBps(), (10_000 + uint256(script.params().creditSpreadBps)) * core.settings().balanceBidCapBps / 10_000, "floorMultBps from the spread and the Core's cap");
        uint256 sid = _compose();
        (, uint256 sCost,) = core.statementInfo(sid);
        assertGt(v3.priceOf(sid), 0, "priceOf a held Statement");
        assertGe(v3.priceOf(sid), sCost * core.settings().saleFloorBps / 10_000, "the Statement ask is at least the Core's floor");
        assertFalse(v3.atFloor(sid), "a fresh Statement is not at its floor");
        assertEq(v3.markupBps(), 11_000, "markupBps");
        assertEq(v3.decayHours(), 1, "decayHours");
        assertEq(v3.startCapBps(), 11_000, "startCapBps");
        assertEq(v3.anchorBps(), 10_000, "anchorBps");
        assertTrue(v3.ageEligibilityOn(), "ageEligibilityOn");
        assertGt(v3.pointRate(), 0, "pointRate");
        assertGt(v3.valueOf(10_000), 0, "valueOf");
    }

    // ------------------------------------------------------------------ spenders and the exit

    function test_aNewRuleIsASpenderTheTreasuryCages() public {
        // promise: a module registered as a spender draws only from its own bucket, only while on and active, inside its caps, never from working funds, the cushion, another bucket or the debt; an unregistered contract draws nothing
        _migrate();
        DrawingSpender m = new DrawingSpender();
        vm.expectRevert(abi.encodeWithSignature("SpenderOff()"));
        m.pull(address(t), user, 1 ether, false);
        vm.startPrank(owner);
        t.registerSpender(address(m), 1_000 ether, 1_500 ether, type(uint128).max);
        t.allocate(address(m), 2_000 ether);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSignature("SpenderOff()"));
        m.pull(address(t), user, 1 ether, false);
        vm.prank(owner);
        t.setSpenderOn(address(m), true);
        vm.expectRevert(abi.encodeWithSignature("SpenderOff()"));
        m.pull(address(t), user, 1 ether, false);
        vm.warp(block.timestamp + 1 days);
        assertEq(t.drawable(address(m)), 1_000 ether, "one call at most perCall");
        uint256 working = t.working();
        uint256 held = _balanceOf(user);
        m.pull(address(t), user, 1_000 ether, false);
        assertEq(_balanceOf(user) - held, 1_000 ether, "paid exactly");
        assertEq(t.working(), working, "working funds untouched");
        assertEq(_bucket(address(m)), 1_000 ether, "only its bucket fell");
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        m.pull(address(t), user, 600 ether, false); // 1,500 per period, 1,000 used
        m.pull(address(t), user, 500 ether, false);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBucket()"));
        m.pull(address(t), user, 501 ether, false); // 500 left; the pro-rata and market buckets are not its to draw
        vm.expectRevert(abi.encodeWithSignature("InvalidRecipient()"));
        m.pull(address(t), address(t), 1 ether, false);
        vm.prank(owner);
        t.setPaused(true);
        vm.expectRevert(abi.encodeWithSignature("Paused()"));
        m.pull(address(t), user, 1 ether, false);
        vm.prank(owner);
        t.setPaused(false);
        vm.prank(owner);
        t.setSpenderOn(address(m), false);
        vm.expectRevert(abi.encodeWithSignature("SpenderOff()"));
        m.pull(address(t), user, 1 ether, false);
        assertTrue(t.solvent(), "solvent throughout");
    }

    function test_theBidIsOnlyASpenderOfTheTreasury() public {
        // promise: the bid module holds no BALANCE and no rule of the treasury's: its budget is its bucket, switching the spender off stops it, and a second bid module can be registered beside it without touching the treasury
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        assertEq(_balanceOf(address(bidm)), 0, "the module holds nothing");
        assertEq(bidm.bidBudget(), _bucket(d.bid), "its budget is its bucket");
        assertTrue(bidm.bidEnabled(), "on through the spender switch");
        vm.prank(owner);
        t.setSpenderOn(d.bid, false);
        assertFalse(bidm.bidEnabled(), "off through the spender switch");
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(bidm), true);
        vm.expectRevert(abi.encodeWithSignature("BidOff()"));
        vm.prank(seller);
        bidm.sellCredit(ids, 0);
        // the next pricing rule: a second module, registered beside the first; the treasury does not change
        ICreditBid next = ICreditBid(_deployArtifact("CreditBid", abi.encode(address(t))));
        vm.startPrank(owner);
        t.registerSpender(address(next), 20_000 ether, 60_000 ether, type(uint128).max);
        t.unallocate(d.bid, _bucket(d.bid));
        t.allocate(address(next), 5_000 ether);
        next.setBid(script.params().bid);
        t.setSpenderOn(address(next), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(next), true);
        (uint256 q,) = next.quoteCredit(ids[0]);
        assertGt(q, 0, "the second module quotes");
        uint256 held = _balanceOf(seller);
        vm.prank(seller);
        next.sellCredit(ids, q);
        assertEq(_balanceOf(seller) - held, q, "the second module fills from its own bucket");
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertTrue(inPile, "and adopts into the pile");
    }

    function test_theLastResortMigrationMovesCustodyToASuccessor() public {
        // promise: a v2 treasury can hand its custody and pro-rata bucket to a successor through the v1 handshake once every switch and spender is off and every other bucket is returned, leaving only its debt and committed payouts behind; it refuses while a spender is on or a bucket is still funded, and refuses every switch after
        _migrate();
        IBalanceTreasuryV2 v3t = IBalanceTreasuryV2(
            _deployArtifact("BalanceTreasuryV2", abi.encode(address(core), t.balanceToken(), d.redeemer, uint128(50_000 ether), address(t)))
        );
        vm.startPrank(owner);
        t.allocate(d.market, 1_000 ether);
        t.setSwitches(false, false);
        core.setBalanceModule(address(v3t));
        vm.expectRevert(abi.encodeWithSignature("InsufficientBucket()"));
        t.migrateTo(address(v3t)); // the market bucket is still funded
        t.unallocate(d.market, _bucket(d.market));
        t.setSpenderOn(d.redeemer, true);
        vm.expectRevert(abi.encodeWithSignature("SwitchesOn()"));
        t.migrateTo(address(v3t));
        t.setSpenderOn(d.redeemer, false);
        uint256 custody = t.custody();
        uint256 claims = _bucket(d.redeemer);
        uint256 debt = t.totalOwed() + t.totalCommitted();
        uint256 moved = t.migrateTo(address(v3t));
        vm.stopPrank();
        assertEq(moved, custody - debt, "custody less the debt moved");
        assertEq(t.custody(), debt, "v2 keeps only its debt");
        assertEq(v3t.custody(), moved, "the successor holds the rest");
        assertEq(v3t.spenders(d.redeemer).bucket, claims, "the pro-rata bucket landed in the successor");
        assertTrue(t.migrated() && t.solvent() && v3t.solvent(), "both solvent, v2 migrated");
        vm.expectRevert(abi.encodeWithSignature("Migrated()"));
        vm.prank(owner);
        t.setSwitches(true, true);
        vm.expectRevert(abi.encodeWithSignature("Migrated()"));
        vm.prank(owner);
        t.setSpenderOn(d.redeemer, true);
        vm.prank(owner);
        v3t.setSwitches(true, true);
        assertEq(v3t.available(), v3t.working(), "the successor answers the Core");
    }

    function test_ensStepPointsTheVaultNameAtV2() public {
        // promise: the ens step moves vault.creditcycle.eth from v1 to v2 through the owner's setAddr and refuses before v2 is the module
        vm.expectRevert();
        script.ens(address(core), d, false);
        _migrate();
        IEnsResolver res = IEnsResolver(IEnsRegistry(script.ENS_REGISTRY()).resolver(script.VAULT_NODE()));
        assertEq(res.addr(script.VAULT_NODE()), address(v1), "the name points at v1 today");
        script.ens(address(core), d, false);
        assertEq(res.addr(script.VAULT_NODE()), address(t), "the name points at v2");
    }

    function test_sweepSplitsTheWholeSurplusOnceByProportion() public {
        // promise: with no share set (the launch, decision 295) the migrate run's sweep leaves the surplus as working funds and every spender bucket empty; once shares are set a sweep moves the whole surplus into the buckets in proportion to the shares, so a second sweep finds nothing, and a partial share total does not drain working funds over repeated calls
        _migrate();
        uint256 s = t.surplus();
        assertGt(s, 0, "the surplus stays working funds");
        assertEq(_bucket(d.bid) + _bucket(d.market), 0, "no spender bucket funded at launch");
        assertEq(t.available(), t.working(), "the Core's exchange can pay all of it");
        assertEq(t.sweep(), 0, "no share set: the sweep moves nothing");
        vm.prank(owner);
        t.setSpenderShare(d.bid, 2_500);
        uint256 bidBucket = _bucket(d.bid);
        assertEq(t.sweep(), s, "a 25 percent share alone takes the whole surplus");
        assertEq(_bucket(d.bid) - bidBucket, s, "all of it to the one shared bucket");
        assertEq(t.sweep(), 0, "and a repeat moves nothing: no compounding drain");
        assertGe(t.working(), t.cushion(), "the cushion is untouched");
    }

    function test_quoteCreditNeverQuotesWhatTheFillCannotSettle() public {
        // promise: quoteCredit answers zero when the seller payout and the artist royalty together exceed the bid's period room, and the fill reverts rather than paying the seller without the royalty
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        uint256 id = _credits(seller, 1)[0];
        (uint256 q, uint256 toArtist) = bidm.quoteCredit(id);
        assertGt(q, 0, "quotes at the launch caps");
        vm.prank(owner);
        t.setSpenderCaps(d.bid, uint128(q + toArtist), uint128(q + toArtist / 2), type(uint128).max);
        (uint256 q2,) = bidm.quoteCredit(id);
        assertEq(q2, 0, "a period room short of both draws quotes zero");
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(bidm), true);
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        vm.prank(seller);
        bidm.sellCredit(_one(id), 0);
        assertEq(CREDITS.ownerOf(id), seller, "the credit never left: the whole fill rolled back");
    }

    // ------------------------------------------------------------------ market floor reference

    function test_marketFloorLiftsSmallCreditsToTheCollectionBidPlusSpread() public {
        // promise: a pile credit whose points price under the posted collection bid asks the bid plus the spread instead, a credit above it is unchanged, and the migrate run posts the floor fresh
        _migrate();
        Phase3.Params memory p = script.params();
        (address poster, uint16 spread,,, uint32 maxStale) = v3.marketFloor();
        assertEq(poster, p.floor.poster, "the poster of the params");
        assertEq(spread, p.floor.spreadBps, "the spread of the params");
        assertEq(maxStale, p.floor.maxStale, "the staleness of the params");
        (uint256 ask0, bool fresh0) = v3.marketFloorAsk();
        assertTrue(fresh0, "posted fresh by the migrate run");
        assertEq(ask0, p.floorWei * (10_000 + p.floor.spreadBps) / 10_000, "ask = posted floor plus the spread");

        uint256 id = _ethFill(1)[0];
        vm.warp(block.timestamp + v3.creditWindow() + 1);
        uint256 byPoints = _pointsPrice(id);
        vm.prank(owner);
        v3.postMarketFloor(1);
        assertEq(v3.creditPrice(id), byPoints, "a floor under the points price changes nothing");
        vm.prank(owner);
        v3.postMarketFloor(byPoints * 2);
        (uint256 ask,) = v3.marketFloorAsk();
        assertEq(v3.creditPrice(id), ask, "a floor above the points price binds at the bid plus the spread");
        assertGt(ask, byPoints, "the lifted ask is above the points price");

        uint256 before = core.ethPot() + core.ethToBuyback();
        vm.deal(user, ask);
        vm.prank(user);
        v3.buyCredit{value: ask}(id);
        assertEq(CREDITS.ownerOf(id), user, "the buyer holds the credit");
        assertGt(core.ethPot() + core.ethToBuyback() - before, byPoints, "the engine took more than the points price");
    }

    function test_marketFloorPosterIsClampedAndPacedAndTheOwnerIsNot() public {
        // promise: the poster raises the floor freely, lowers it at most stepBps per post (rounded up, so it never reaches zero by rounding) and posts at most once per minSeconds; anyone else is refused; the owner posts any floor at any time; only the first post is unclamped
        _migrate();
        Phase3.Params memory p = script.params();
        uint256 last = v3.marketFloorWei();
        vm.expectRevert(IControllerV3.OnlyPoster.selector);
        vm.prank(user);
        v3.postMarketFloor(last);
        vm.expectRevert(IControllerV3.TooSoon.selector);
        vm.prank(p.floor.poster);
        v3.postMarketFloor(last);
        vm.warp(block.timestamp + p.floor.minSeconds);
        vm.prank(p.floor.poster);
        v3.postMarketFloor(last * 3);
        assertEq(v3.marketFloorWei(), last * 3, "a rise is taken whole: a lagged floor gives credits away");
        last = v3.marketFloorWei();
        vm.warp(block.timestamp + p.floor.minSeconds);
        vm.prank(p.floor.poster);
        v3.postMarketFloor(1);
        assertEq(v3.marketFloorWei(), (last * (10_000 - p.floor.stepBps) + 9_999) / 10_000, "a drop is clamped to one step, rounded up");
        vm.prank(owner);
        v3.postMarketFloor(1);
        vm.warp(block.timestamp + p.floor.minSeconds);
        vm.prank(p.floor.poster);
        v3.postMarketFloor(0);
        assertEq(v3.marketFloorWei(), 1, "from 1 wei the poster cannot reach zero");
        vm.warp(block.timestamp + p.floor.minSeconds);
        vm.prank(p.floor.poster);
        v3.postMarketFloor(last * 3);
        assertEq(v3.marketFloorWei(), last * 3, "and a zero floor never reopens the first post exemption, only a rise is free");
        vm.prank(owner);
        v3.postMarketFloor(last);
        assertEq(v3.marketFloorWei(), last, "the owner is neither clamped nor paced");
        vm.expectRevert(abi.encodeWithSelector(IControllerV3.BadSetting.selector, bytes32("floorStepBps")));
        vm.prank(owner);
        v3.setMarketFloor(IControllerV3.MarketFloor({poster: p.floor.poster, spreadBps: 300, stepBps: 0, minSeconds: 600, maxStale: 6 hours}));
        vm.expectRevert(abi.encodeWithSelector(IControllerV3.BadSetting.selector, bytes32("floorStepBps")));
        vm.prank(owner);
        v3.setMarketFloor(IControllerV3.MarketFloor({poster: p.floor.poster, spreadBps: 300, stepBps: 10_000, minSeconds: 600, maxStale: 6 hours}));
    }

    function test_marketFloorStaleOnlyRefusesTheCreditsItBinds() public {
        // promise: past maxStale a credit the floor lifts is not for sale (StaleFloor) while a credit priced above the floor by points still sells; maxStale 0 switches the term off
        _migrate();
        Phase3.Params memory p = script.params();
        uint256 id = _ethFill(1)[0];
        vm.warp(block.timestamp + v3.creditWindow() + 1);
        uint256 byPoints = _pointsPrice(id);
        vm.prank(owner);
        v3.postMarketFloor(byPoints * 2);
        vm.warp(block.timestamp + p.floor.maxStale + 1);
        (, bool fresh) = v3.marketFloorAsk();
        assertFalse(fresh, "stale past maxStale");
        vm.expectRevert(IControllerV3.StaleFloor.selector);
        v3.creditPrice(id);
        vm.deal(user, byPoints * 3);
        vm.expectRevert(IControllerV3.StaleFloor.selector);
        vm.prank(user);
        v3.buyCredit{value: byPoints * 3}(id);
        vm.prank(owner);
        v3.postMarketFloor(1);
        vm.warp(block.timestamp + p.floor.maxStale + 1);
        assertEq(v3.creditPrice(id), byPoints, "a stale floor that does not bind is ignored");
        vm.prank(owner);
        v3.postMarketFloor(byPoints * 2);
        vm.prank(owner);
        v3.setMarketFloor(IControllerV3.MarketFloor({poster: p.floor.poster, spreadBps: 300, stepBps: 1_000, minSeconds: 600, maxStale: 0}));
        assertEq(v3.creditPrice(id), byPoints, "maxStale 0 switches the term off");
        (uint256 ask, bool fresh2) = v3.marketFloorAsk();
        assertTrue(ask == 0 && fresh2, "off: no ask, never stale");
    }

    /// the credit sale floor of `id` by points alone: valueOf(score) times floorMultBps, at least saleFloorBps of cost
    function _pointsPrice(uint256 id) internal view returns (uint256 floor) {
        (, uint256 cost,) = core.creditInfo(id);
        floor = v3.valueOf(_scoreOf(id)) * v3.floorMultBps() / 10_000;
        uint256 coreFloor = cost * core.settings().saleFloorBps / 10_000;
        if (floor < coreFloor) floor = coreFloor;
    }

    // ------------------------------------------------------------------ redeemer 2 (MarketRedeemer)

    function test_marketRedeemerPaysTheProtectedRatePlusPremium() public {
        // promise: redeemer 2 burns CC and pays at once ccIn * min(CC reference, CC spot) / max(BALANCE reference, BALANCE spot) * 1.05 from its own bucket
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        (uint256 pCc, uint256 pBal, bool ok) = m.prices();
        assertTrue(ok, "priced");
        assertEq(pCc, _lowestCc(), "the CC side is the lowest of reference, prior block sample and spot");
        assertEq(pBal, _highestBalance(), "the BALANCE side is the highest of reference, prior block sample and spot");
        uint256 want = cc * 10_500 * pCc / (pBal * 10_000);
        uint256 bucket = _bucket(d.market);
        uint256 supply = IPhase3Coin(address(coin)).totalSupply();
        uint256 held = _balanceOf(user);
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, want, "the protected rate plus 500 bps");
        assertEq(_balanceOf(user) - held, paid, "paid at once");
        assertEq(bucket - _bucket(d.market), paid, "from redeemer 2's bucket");
        assertEq(IPhase3Coin(address(coin)).totalSupply(), supply - cc, "the CC was burned");
    }

    function test_marketRedeemerOneBlockPumpCannotRaiseThePayout() public {
        // promise: pumping the CC pool up or the BALANCE pool down within a block never raises redeemer 2's payout above its reference bounds
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        (uint256 before,) = m.preview(cc);
        assertGt(before, 0, "priced before the pumps");
        uint256 ccSpot0 = _ccSpot();
        (uint256 balSpot0,) = v3.spotPrice();
        address pumper = _user("pumper");
        _buyCoin(pumper, 5 ether);
        (uint256 afterCc,) = m.preview(cc);
        assertGt(_ccSpot(), ccSpot0 * 11 / 10, "the CC pool rose more than 10 percent");
        assertLe(afterCc, before, "a CC pump does not raise the payout");
        _fundBalance(pumper, 30_000 ether);
        PoolKey memory k = _v3BalanceKey();
        vm.startPrank(pumper);
        IPhase3Coin(liveBalanceToken).approve(address(router), type(uint256).max);
        router.swap(k, false, -int256(30_000 ether), pumper);
        vm.stopPrank();
        (uint256 balSpot1,) = v3.spotPrice();
        assertLt(balSpot1, balSpot0 * 97 / 100, "the BALANCE pool fell more than 3 percent");
        v3.refreshCcReference();
        (uint256 afterBoth,) = m.preview(cc);
        assertLe(afterBoth, before, "a BALANCE dump and a same block refresh do not raise the payout");
        (uint256 paid,) = _redeemMarket(cc);
        assertLe(paid, before, "the burn pays no more than before the pumps");
    }

    function test_marketRedeemerLaggingReferenceCannotBeMetByAPump() public {
        // promise: after a CC fall the reference lags above the price, but a refresh records the fallen spot, so pumping the live spot back to the lagging reference in a later block does not raise redeemer 2's payout above the fallen price
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        address whale = _user("whale");
        uint256 whaleCc = _buyCoin(whale, 10 ether);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            assertTrue(v3.refreshCcReference(), "the reference follows the rise");
        }
        _sellCoin(whale, whaleCc);
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshCcReference(), "a refresh after the fall");
        (uint256 ccRef, bool ok) = v3.ccPrice();
        uint256 fallen = _ccSpot();
        assertTrue(ok, "the reference is usable");
        assertGt(ccRef, fallen * 120 / 100, "the reference lags more than 20 percent above the fallen price");

        vm.roll(block.number + 1);
        _buyCoin(_user("attacker"), 10 ether);
        assertGt(_ccSpot(), ccRef, "the live spot is pumped past the lagging reference");
        assertEq(v3.ccPriorSample(), fallen, "the prior block sample is the fallen spot");
        (uint256 pCc, uint256 pBal,) = m.prices();
        assertEq(pCc, fallen, "CC is priced at the fallen spot, not the lagging reference");
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, cc * 10_500 * fallen / (pBal * 10_000), "paid at the fallen price plus the premium");
    }

    function test_marketRedeemerLaggingBalanceReferenceCannotBeMetByADump() public {
        // promise: after a BALANCE rise the BALANCE reference lags below the price, but a refresh records the risen spot, so dumping the live spot back below the lagging reference in a later block does not price BALANCE under the risen price
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        address riser = _user("riser");
        PoolKey memory k = _v3BalanceKey();
        vm.deal(riser, 20 ether);
        vm.prank(riser);
        router.swap{value: 20 ether}(k, true, -int256(20 ether), riser);
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshReference(), "a refresh after the rise");
        (uint256 risen,) = v3.spotPrice();
        uint256 balRef = v3.referencePrice();
        assertLt(balRef * 105 / 100, risen, "the reference lags more than 5 percent below the risen price");

        vm.roll(block.number + 1);
        uint256 bal = _balanceOf(riser);
        vm.startPrank(riser);
        IPhase3Coin(liveBalanceToken).approve(address(router), type(uint256).max);
        router.swap(k, false, -int256(bal), riser);
        vm.stopPrank();
        (uint256 live,) = v3.spotPrice();
        assertLt(live, balRef, "the live spot is dumped below the lagging reference");
        assertEq(v3.balancePriorSample(), risen, "the prior block sample is the risen spot");
        (uint256 pCc, uint256 pBal,) = m.prices();
        assertEq(pBal, risen, "BALANCE is priced at the risen spot, not the lagging reference");
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, cc * 10_500 * pCc / (risen * 10_000), "paid at the risen BALANCE price");
    }

    function test_marketRedeemerBucketAndDailyCap() public {
        // promise: redeemer 2 cannot pay past its bucket, its per call cap or its per day cap
        IMarketRedeemer m = _marketOn();
        _userCc(1 ether);
        uint256 per = _ccFor(m, 1_000 ether);
        _redeemMarketReverts(per * 51 / 10, 0, abi.encodeWithSignature("OverCap()")); // 5,100 over the 5,000 per call
        for (uint256 i; i < 4; ++i) {
            _redeemMarket(per * 49 / 10); // 4,900 each, 19,600 of the 20,000 per day
        }
        _redeemMarketReverts(per / 2, 0, abi.encodeWithSignature("OverCap()")); // 500 more passes the day
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        v3.refreshCcReference();
        uint256 bucket = _bucket(d.market);
        vm.startPrank(owner);
        t.setSpenderOn(d.market, false);
        t.unallocate(d.market, bucket - 1_000 ether);
        t.setSpenderOn(d.market, true);
        vm.stopPrank();
        per = _ccFor(m, 1_000 ether);
        _redeemMarketReverts(per * 11 / 10, 0, abi.encodeWithSignature("InsufficientBucket()")); // 1,100, 1,000 left
        _redeemMarket(per * 9 / 10);
        assertLt(_bucket(d.market), 1_000 ether, "only the bucket paid");
    }

    function test_marketRedeemerRefusesAStaleEpochOrPrice() public {
        // promise: redeemer 2 reverts on a stale treasury epoch, a stale premium epoch, a premium above its bound and a stale CC reference
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        uint64 epoch = _epoch(d.market);
        uint64 premiumEpoch = m.configEpoch();
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.market, cc, user, 0, block.timestamp, epoch + 1, abi.encode(premiumEpoch));
        vm.prank(owner);
        m.setPremiumBps(800);
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.market, cc, user, 0, block.timestamp, epoch, abi.encode(premiumEpoch));
        vm.expectRevert(abi.encodeWithSignature("BadPremium()"));
        vm.prank(owner);
        m.setPremiumBps(1_501);
        (uint256 q,) = m.preview(cc);
        _redeemMarketReverts(cc, q + 1, abi.encodeWithSignature("Slippage()"));
        vm.warp(block.timestamp + 2 hours);
        _redeemMarketReverts(cc, 0, abi.encodeWithSignature("Unpriced()"));
    }

    // ------------------------------------------------------------------ helpers

    /// a plain create of production artifact `name`, the way the script deploys: tests reach the production contracts
    /// only through their artifacts and interfaces
    function _deployArtifact(string memory name, bytes memory args) internal returns (address at) {
        bytes memory init = abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args);
        assembly {
            at := create(0, add(init, 0x20), mload(init))
        }
        require(at.code.length != 0, "create failed");
    }

    function _bucket(address r) internal view returns (uint256 b) {
        b = t.spenders(r).bucket;
    }

    function _epoch(address r) internal view returns (uint64 e) {
        e = t.spenders(r).epoch;
    }

    function _redeem(address r, uint256 ccIn, uint64 epoch) internal returns (uint256 amount, uint256 claimId) {
        vm.prank(user);
        (amount, claimId) = t.redeemCC(r, ccIn, user, 0, block.timestamp, epoch, "");
    }

    function _assertAboveCushion(string memory when) internal view {
        assertGe(t.working(), t.cushion(), when);
    }

    /// real credits sold into the Core's eth bid, the pot funded first
    function _ethFill(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        _fundPot(5 ether);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
    }

    /// fills the pile to a page through the eth bid, ages it past the credit window and composes. returns the Statement
    function _compose() internal returns (uint256 sid) {
        uint256 size = core.pileSize();
        if (size < 80) _ethFill(80 - size);
        _warpPageReady();
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held, "the Core holds the new Statement");
    }

    /// the migrated state with redeemer 2 past its start delay, its CC reference fresh, switched on, and the user's
    /// coin approved to the treasury
    function _marketOn() internal returns (IMarketRedeemer m) {
        _migrate();
        m = IMarketRedeemer(d.market);
        assertEq(_bucket(d.market), 0, "launched unfunded");
        vm.prank(owner);
        t.allocate(d.market, 50_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshCcReference(), "the CC reference refreshed");
        vm.prank(owner);
        t.setSpenderOn(d.market, true);
    }

    /// CC bought by the user for `eth`, approved to the treasury for `burnFrom`
    function _userCc(uint256 eth) internal returns (uint256 cc) {
        cc = _buyCoin(user, eth);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
    }

    function _redeemMarket(uint256 ccIn) internal returns (uint256 amount, uint256 claimId) {
        (uint64 e, bytes memory data) = _marketArgs();
        vm.prank(user);
        (amount, claimId) = t.redeemCC(d.market, ccIn, user, 0, block.timestamp, e, data);
    }

    /// a redemption through redeemer 2 that must revert with `err`. the arguments are read before the cheatcodes, so
    /// the prank and the expectation reach the redemption itself
    function _redeemMarketReverts(uint256 ccIn, uint256 minOut, bytes memory err) internal {
        (uint64 e, bytes memory data) = _marketArgs();
        vm.expectRevert(err);
        vm.prank(user);
        t.redeemCC(d.market, ccIn, user, minOut, block.timestamp, e, data);
    }

    /// the treasury epoch of redeemer 2 and its premium epoch as `data`
    function _marketArgs() internal view returns (uint64 e, bytes memory data) {
        e = _epoch(d.market);
        data = abi.encode(IMarketRedeemer(d.market).configEpoch());
    }

    /// the CC that redeemer 2 pays `amount` for now
    function _ccFor(IMarketRedeemer m, uint256 amount) internal view returns (uint256) {
        (uint256 a,) = m.preview(1e24);
        return 1e24 * amount / a;
    }

    function _v3BalanceKey() internal view returns (PoolKey memory k) {
        (IControllerV3.Currency c0, IControllerV3.Currency c1, uint24 fee, int24 spacing, address hooks) =
            v3.balancePoolKey();
        k = PoolKey({
            currency0: Currency.wrap(IControllerV3.Currency.unwrap(c0)),
            currency1: Currency.wrap(IControllerV3.Currency.unwrap(c1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }

    function _lowestCc() internal view returns (uint256 low) {
        (uint256 ccRef,) = v3.ccPrice();
        low = _ccSpot();
        if (ccRef < low) low = ccRef;
        uint256 sample = v3.ccPriorSample();
        if (sample < low) low = sample;
    }

    function _highestBalance() internal view returns (uint256 high) {
        (high,) = v3.spotPrice();
        uint256 balRef = v3.referencePrice();
        if (balRef > high) high = balRef;
        uint256 sample = v3.balancePriorSample();
        if (sample > high) high = sample;
    }

    function _ccSpot() internal view returns (uint256) {
        (uint160 p,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolId.wrap(poolId));
        uint256 q = FixedPoint96.Q96;
        return (1e18 * q / p) * q / p;
    }
}
