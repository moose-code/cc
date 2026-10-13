// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IArtCoinsHookV2, IArtCoinsMevSkimV2} from "../src/interfaces/ArtCoinsV2.sol";

/// the launch of the coin through the v2 factory as its owner and everything it must read back as
contract LaunchTest is Fixture {
    IArtCoinsHookV2 internal HOOK;

    function setUp() public override {
        super.setUp();
        HOOK = IArtCoinsHookV2(lc.stack.hook);
    }

    // the Core computed the coin address the factory deployed, from the sender and the whole config
    function test_predictedCoinEqualsDeployed() public view {
        assertEq(core.COIN(), address(coin));
        assertEq(predictCoin(owner, "Fixture Coin", "FIXT", FIXTURE_SALT), address(coin));
        assertTrue(predictCoin(creator, "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(owner, "Fixture Coin", "FIXT", bytes32(0)) != address(coin));
    }

    // the launch read straight from the v2 contracts: the whole supply is the one pool position, the skim config pays the
    // Core, and the anti sniper schedule ends at the baseline
    function test_launchReadBack() public {
        uint256 dust = coin.balanceOf(lc.stack.locker);
        assertLt(dust, 1e6, "rounding dust only");
        assertApproxEqAbs(coin.balanceOf(address(PM)) + dust, 1_000_000_000e18, 1e6);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(coin.canonicalPoolId(), poolId);
        assertEq(address(core.controller()), address(ctl));

        IArtCoinsHookV2.SkimConfig memory k = HOOK.skimConfig(poolId);
        assertEq(k.baselineSkimBps, 690);
        assertEq(k.bountyBps, 9_638);
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

    // with the referral cap at zero a swap that names a referrer succeeds
    function test_referralWithTheCapAtZeroDoesNotRevert() public {
        _skipSniperWindow();
        address buyer = _user("buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        router.swapWithData{value: 1 ether}(launchKey, true, -1 ether, buyer, _referralData(_user("ref"), 250));
        assertGt(coin.balanceOf(buyer), 0);
    }

    // the anti sniper skim pays the Core far above the baseline in the first block and the baseline after the window
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
