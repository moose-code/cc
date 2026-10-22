// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IRedeemer, CcQuote, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Phase3} from "../script/Phase3.s.sol";
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
    IPhase2BalanceTreasury internal v1;
    address internal user;

    function setUp() public override {
        vm.setEnv("LIVE_FORK_BLOCK", vm.toString(PIN));
        super.setUp();
        v1 = IPhase2BalanceTreasury(core.balanceModule());
        script = new Phase3();
        d = script.deploy(address(core), script.params(), false);
        t = IBalanceTreasuryV2(d.treasury);
        v3 = IControllerV3(d.controller);
        user = _user("phase3 user");
    }

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
        vm.warp(block.timestamp + core.settings().returnLockSeconds + 1);
        script.enableBid(address(core), d, false);
        assertGt(t.bidBudget(), 0, "the sweep funded the bid");

        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(t), true);
        (uint256 q, uint256 toArtist) = t.quoteCredit(ids[0]);
        assertGt(q, 0, "the bid quotes a real credit");
        uint256 budget = t.bidBudget();
        uint256 held = _balanceOf(seller);
        uint256 splitHeld = _balanceOf(core.artist());
        vm.prank(seller);
        t.sellCredit(ids, q);
        assertEq(_balanceOf(seller) - held, q, "the seller got the quote");
        assertEq(_balanceOf(core.artist()) - splitHeld, toArtist, "the split got the royalty on top");
        assertEq(budget - t.bidBudget(), q + toArtist, "both came from the bid budget");
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
        CREDITS.setApprovalForAll(address(t), true);
        vm.expectRevert(abi.encodeWithSignature("ReturnLocked(uint256)", id));
        vm.prank(user);
        t.sellCredit(_one(id), 0);
    }

    function test_bidStaysBelowTheResaleFloorAfterTheCoreCapFalls() public {
        // promise: the v2 bid never prices above the controller's credit floor multiplier, also after the Core's balanceBidCapBps falls below the bid cap
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        assertEq(t.bidBpsNow(), 11_500, "the bid climbed to its cap");
        Settings memory cfg = core.settings();
        cfg.balanceBidCapBps = 10_000;
        _setSettings(cfg);
        uint256 floorMult = v3.floorMultBps();
        assertEq(floorMult, 11_000, "the resale floor multiplier fell under the bid cap");
        uint256 id = _credits(seller, 1)[0];
        (uint256 q,) = t.quoteCredit(id);
        assertGt(q, 0, "the bid still quotes");
        assertLe(q, _scoreOf(id) * 1e14 * (floorMult - 1) / 10_000, "priced under the resale floor multiplier");
    }

    function test_redeemersPayFromTheirBucketInsideTheirCaps() public {
        // promise: redeemer 1 burns CC and pays ccIn * B / S less the fee and reverts on a stale epoch; a test redeemer's vesting and deferred payouts never exceed its bucket or caps
        _migrate();
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(owner);
        t.setRedeemerOn(d.redeemer, true);
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
        t.registerRedeemer(address(r), 1_000 ether, 1_500 ether, 2_000 ether);
        t.allocate(address(r), 2_500 ether);
        t.setRedeemerOn(address(r), true);
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
        // promise: a scripted run of bid fills, conversions and redemptions leaves working funds at or above the cushion
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        vm.prank(owner);
        t.setRedeemerOn(d.redeemer, true);
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(t), true);
        _assertAboveCushion("after the migration");
        for (uint256 round; round < 2; ++round) {
            uint256[] memory ids = _credits(seller, 3);
            vm.prank(seller);
            t.sellCredit(ids, 0);
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
        // promise: V3 passes the band check at the live parameters with headroom, its idle loosening is bounded and returns to zero on a purchase, and every view the Core, keeper, indexer and web read answers
        _migrate();
        (, uint16 step, uint16 tol,,,) = v3.quote();
        uint256 margin = core.settings().balanceBidMarginBps;
        assertLt((10_000 + uint256(step)) * (10_000 + tol) * (10_000 - margin), 0.995e12, "at least 50 bps headroom");

        v3.syncFill();
        uint256 l0 = v3.idleLoosenBps();
        (uint256 vb0,) = v3.valuePerPoint(false);
        vm.warp(block.timestamp + 30 days);
        (,, uint16 cap) = v3.idle();
        assertEq(v3.idleLoosenBps(), cap, "the loosening stops at its cap");
        (uint256 vb1,) = v3.valuePerPoint(false);
        assertApproxEqRel(vb1 * (10_000 + l0), vb0 * (10_000 + uint256(cap)), 1e12, "the buy price carries the loosening");
        _ethFill(1);
        assertEq(v3.idleLoosenBps(), 0, "a purchase makes the tail unknown: no loosening");
        v3.syncFill();
        assertEq(v3.idleLoosenBps(), 0, "synced to the purchase: no loosening");

        uint256 id = core.pilePage(0, 1)[0];
        (bool ready,,) = v3.nextPage();
        ready;
        (, , uint64 acquiredAt) = core.creditInfo(id);
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
        assertEq(v3.floorMultBps(), 12_100, "floorMultBps");
        assertEq(v3.markupBps(), 11_000, "markupBps");
        assertEq(v3.decayHours(), 168, "decayHours");
        assertEq(v3.startCapBps(), 11_000, "startCapBps");
        assertEq(v3.anchorBps(), 10_000, "anchorBps");
        assertTrue(v3.ageEligibilityOn(), "ageEligibilityOn");
        assertGt(v3.pointRate(), 0, "pointRate");
        assertGt(v3.valueOf(10_000), 0, "valueOf");
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        core.refreshReference();

        uint256 ccSpot = _ccSpot();
        vm.startPrank(owner);
        v3.setCcPoolKey(
            IControllerV3.PoolKey({
                currency0: IControllerV3.Currency.wrap(address(0)),
                currency1: IControllerV3.Currency.wrap(address(coin)),
                fee: launchKey.fee,
                tickSpacing: launchKey.tickSpacing,
                hooks: address(launchKey.hooks)
            }),
            ccSpot
        );
        v3.setCcQuote(
            CcQuote({rateBpsPerHour: 1_000, stepBps: 500, maxStale: 1 days, minSeconds: 600, avgSeconds: 3_600, minLiquidity: 1})
        );
        vm.stopPrank();
        (uint256 ccRef, bool okcc) = v3.ccPrice();
        assertTrue(okcc && ccRef == ccSpot, "the CC reference seeds at the spot");
        vm.warp(block.timestamp + 2 days);
        (, okcc) = v3.ccPrice();
        assertFalse(okcc, "a stale CC reference pauses");
    }

    // ------------------------------------------------------------------ helpers

    function _bucket(address r) internal view returns (uint256 b) {
        b = t.redeemers(r).bucket;
    }

    function _epoch(address r) internal view returns (uint64 e) {
        e = t.redeemers(r).epoch;
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

    function _ccSpot() internal view returns (uint256) {
        (uint160 p,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolId.wrap(poolId));
        uint256 q = FixedPoint96.Q96;
        return (1e18 * q / p) * q / p;
    }
}
