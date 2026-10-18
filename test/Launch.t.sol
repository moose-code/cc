// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsHookV2, IArtCoinsMevSkimV2} from "../src/interfaces/ArtCoinsV2.sol";

/// the launch of the coin through the v2 factory as its owner and everything it must read back as
contract LaunchTest is Fixture {
    IArtCoinsHookV2 internal HOOK;

    function setUp() public override {
        super.setUp();
        HOOK = IArtCoinsHookV2(lc.stack.hook);
    }

    // the Core computed the coin address the factory deployed, from the sender and the whole config
    // promise: the Core computed the coin address the factory deployed, from the sender and the whole config
    function test_predictedCoinEqualsDeployed() public view {
        assertEq(core.COIN(), address(coin));
        assertEq(predictCoin(owner, "Fixture Coin", "FIXT", FIXTURE_SALT), address(coin));
        assertTrue(predictCoin(creator, "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(owner, "Fixture Coin", "FIXT", bytes32(0)) != address(coin));
    }

    // the launch read straight from the v2 contracts: the whole supply is the one pool position, the skim config pays the
    // Core, and the anti sniper schedule ends at the baseline
    // promise: launch read back
    function test_launchReadBack() public {
        uint256 dust = coin.balanceOf(lc.stack.locker);
        assertLt(dust, 1e6, "rounding dust only");
        assertApproxEqAbs(coin.balanceOf(address(PM)) + dust, 1_000_000_000e18, 1e6);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(coin.canonicalPoolId(), poolId);
        assertEq(address(core.controller()), address(ctl));

        IArtCoinsHookV2.SkimConfig memory k = HOOK.skimConfig(poolId);
        assertEq(k.baselineSkimBps, 690);
        assertEq(k.bountyBps, 9_000);
        assertEq(k.bountyRecipient, address(core), "the bounty goes to the Core");
        IArtCoinsMevSkimV2 mev = IArtCoinsMevSkimV2(lc.mevModule);
        IArtCoinsMevSkimV2.SkimSchedule memory sched = mev.schedule(poolId);
        assertEq(sched.startingSkimBps, 9_000);
        assertEq(sched.endSkimBps, 690, "the baseline is the end value");
        assertEq(sched.windowSeconds, 1800);
        _skipSniperWindow();
        (uint24 now_, bool active) = mev.currentSkimBps(poolId);
        assertEq(now_, 690);
        assertFalse(active);
    }

    // promise: SPEC 1 decision 176: the first fill earns no climb from an unbooked hook fed pot
    /// a cold launch: one buy feeds a thin pot, left unbooked, no setRate and no pre funding. ten minutes later the bid
    /// remains at the opening rate despite the pending hook income, and the first ever sellForEth pays the
    /// bid quoted in the same block, stamping lastFillTime, the anchor, the peak and the spend budget
    function test_firstFillDoesNotClimbOnUnbookedHookIncome() public {
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertEq(core.RATE_START(), OPEN_RATE, "the opening rate the first fill starts from");
        _skipSniperWindow();
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id); // score is refScore, so the bid is the full rate

        autoBook = false;
        _buyCoin(funder, 1 ether);
        assertEq(core.ethPot(), 0, "the fee income waits unbooked, no door and no setRate");
        assertGt(address(core).balance, 0, "the hook fed the pot");
        _warp(10 minutes);
        uint256 rate = core.ethRate();
        uint256 quote = core.bidOf(id);
        assertEq(rate, OPEN_RATE, "unbooked hook income earned no climb");

        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 paid = seller.balance - before;
        assertEq(paid, quote, "the first fill paid the bid quoted in the same block");
        assertEq(core.lastFillTime(), block.timestamp, "the fill stamped lastFillTime");
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, rate, "the anchor is the rate paid");
        assertEq(start, rate, "and the start of the minute");
        assertEq(bucket, block.timestamp / 60, "the minute bucket of the fill");
        (uint256 peakRate, uint256 peakTime) = _peak();
        assertGe(peakRate, rate, "the remembered peak is at least the rate paid");
        assertEq(peakTime, block.timestamp, "the peak time is the fill");
        // the spend budget snapshots the post book pot of the first spend; at launch spendCapBps 10_000 is the whole pot
        (uint64 spendBucket, uint128 budget,) = core.spendState();
        Settings memory s = core.settings();
        // the fill spent the payout and its artist royalty (decision 163)
        uint256 spent = paid + paid * s.buyToArtistBps / 10_000;
        assertEq(uint256(budget), (core.ethPot() + spent) * s.spendCapBps / 10_000, "the budget is the post book pot");
        assertEq(spendBucket, block.timestamp / s.bucketSeconds, "the spend bucket of the fill");
    }

    // with the referral cap at zero a swap that names a referrer succeeds
    // promise: with the referral cap at zero a swap that names a referrer succeeds
    function test_referralWithTheCapAtZeroDoesNotRevert() public {
        _skipSniperWindow();
        address buyer = _user("buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        router.swapWithData{value: 1 ether}(launchKey, true, -1 ether, buyer, _referralData(_user("ref"), 250));
        assertGt(coin.balanceOf(buyer), 0);
    }

    // the anti sniper skim pays the Core far above the baseline in the first block and the baseline after the window
    // promise: the anti sniper skim pays the Core far above the baseline in the first block and the baseline after the window
    function test_theAntiSniperSkimStartsHighAndFallsToTheBaseline() public {
        IArtCoinsHookV2.SkimConfig memory k = HOOK.skimConfig(poolId);
        autoBook = false; // leave the skim unbooked so it can be read
        address t = _user("launch trader");
        vm.deal(t, 100 ether);
        uint256 bal = address(core).balance;
        _buyCoin(t, 1 ether);
        uint256 early = address(core).balance - bal;
        assertGt(early, 0.7 ether, "the window skim is far above the baseline");
        _skipSniperWindow();
        bal = address(core).balance;
        _buyCoin(t, 1 ether);
        uint256 late = address(core).balance - bal;
        assertApproxEqRel(late, uint256(1 ether) * k.baselineSkimBps * k.bountyBps / 10_000 / 10_000, 0.01e18);
    }
}
