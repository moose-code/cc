// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";

/// the flat balance bid (decision 164): the balance route pays `score * unitPerPoint * (10_000 - balanceDiscountBps) /
/// 10_000` per credit, posted, with no climb while idle and no drop on a fill. the only bound is the module's
/// `available()`, which the payouts plus the artist royalties (decision 163) must not pass. the discount is an owner
/// setting, editable after deployment, effective for the next fill
contract BalanceFlatTest is Fixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("flat.user");
        _enterPhase2();
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    function _posted() internal view returns (uint256) {
        return 10_000 - core.settings().balanceDiscountBps;
    }

    function _payout(uint256 id) internal view returns (uint256) {
        return _score(id) * UNIT * _posted() / 10_000;
    }

    function _royalty(uint256 pay) internal view returns (uint256) {
        return pay * core.settings().buyToArtistBps / 10_000;
    }

    function _setDiscount(uint16 bps) internal {
        Settings memory s = core.settings();
        s.balanceDiscountBps = bps;
        _setSettings(s);
    }

    // promise: SPEC 9 the balance rate is the posted 10_000 - balanceDiscountBps, 9_000 at launch, and balanceBidOf is
    // score * unit * that / 10_000
    function test_postedRateAndPayout() public {
        assertEq(core.settings().balanceDiscountBps, 1_000, "launch discount");
        assertEq(core.balanceRate(), 9_000, "the posted rate at launch");
        uint256[] memory ids = _credits(user, 1);
        assertEq(core.balanceBidOf(ids[0]), _payout(ids[0]), "balanceBidOf is the posted payout");
        assertEq(core.balanceBidForScore(_score(ids[0])), _payout(ids[0]), "balanceBidForScore agrees");
    }

    // promise: SPEC 9 a fill pays the seller the posted payout, the artist buyToArtistBps of it in balance token, and
    // the module's holding falls by both
    function test_fillPaysSellerAndArtistFromTheModule() public {
        uint256[] memory ids = _credits(user, 1);
        uint256 pay = _payout(ids[0]);
        uint256 royalty = _royalty(pay);
        assertGt(royalty, 0, "the launch royalty is nonzero");
        address artist = core.artist();
        uint256 userBefore = xt.balanceOf(user);
        uint256 artistBefore = xt.balanceOf(artist);
        uint256 moduleBefore = _moduleHolding();
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - userBefore, pay, "the seller receives the posted payout whole");
        assertEq(xt.balanceOf(artist) - artistBefore, royalty, "the artist receives the royalty in balance token");
        assertEq(moduleBefore - _moduleHolding(), pay + royalty, "the module paid both");
        assertEq(xt.balanceOf(address(core)), 0, "the core holds no balance token");
        (bool inPile, uint256 cost,) = core.creditInfo(ids[0]);
        assertTrue(inPile, "the credit entered the pile");
        assertGt(cost, 0, "with an eth cost basis");
    }

    // promise: a whole-module artist payment failure rolls back the seller payment and Credit transfer
    function test_wholeArtistPayFailureRollsBackTheSale() public {
        address hostile = _user("flat.hostileArtist");
        _setArtist(hostile);
        xt.setBanned(hostile);
        uint256[] memory ids = _credits(user, 1);
        uint256 pay = _payout(ids[0]);
        uint256 royalty = _royalty(pay);
        assertGt(royalty, 0, "the launch royalty is nonzero");
        uint256 userBefore = xt.balanceOf(user);
        uint256 moduleBefore = _moduleHolding();
        vm.prank(user);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user), userBefore, "the seller payment rolled back");
        assertEq(xt.balanceOf(hostile), 0, "the blacklisted artist received nothing");
        assertEq(_moduleHolding(), moduleBefore, "the module reserve is unchanged");
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertFalse(inPile, "the credit did not enter the pile");
        assertEq(CREDITS.ownerOf(ids[0]), user, "the seller kept the Credit");
    }

    // promise: SPEC 9 the posted rate does not climb while idle and does not drop on a fill: a day idle and a batch
    // leave balanceRate and the per credit payout unchanged
    function test_noClimbNoDrop() public {
        uint256 r0 = core.balanceRate();
        _warp(1 days);
        assertEq(core.balanceRate(), r0, "no climb after a day idle");
        uint256[] memory ids = _credits(user, 6);
        uint256 last = _payout(ids[5]);
        uint256[] memory five = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = ids[i];
        }
        vm.prank(user);
        core.sellForBalance(five);
        assertEq(core.balanceRate(), r0, "no drop after a five credit batch");
        assertEq(core.balanceBidOf(ids[5]), last, "the next credit's payout is unchanged");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(_one(ids[5]));
        assertEq(xt.balanceOf(user) - before, last, "and it pays that payout");
        _warp(30 days);
        assertEq(core.balanceRate(), r0, "still no climb");
    }

    // promise: SPEC 3 balanceDiscountBps is editable through setSettings with no lock, effective at once: 0 pays par,
    // 9_999 pays 1 bps of par, and 10_000 is refused so the payout is never zero
    function test_discountIsEditableAndBounded() public {
        uint256[] memory ids = _credits(user, 3);
        _setDiscount(0);
        assertEq(core.balanceRate(), 10_000, "no discount reads par");
        uint256 par = _score(ids[0]) * UNIT;
        assertEq(core.balanceBidOf(ids[0]), par, "pays par");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(_one(ids[0]));
        assertEq(xt.balanceOf(user) - before, par, "the next fill pays the new rate");

        _setDiscount(9_999);
        assertEq(core.balanceRate(), 1, "the largest discount reads 1 bps of par");
        assertEq(core.balanceBidOf(ids[1]), _score(ids[1]) * UNIT / 10_000, "and pays it");
        before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(_one(ids[1]));
        assertEq(xt.balanceOf(user) - before, _score(ids[1]) * UNIT / 10_000, "paid at once");

        Settings memory s = core.settings();
        s.balanceDiscountBps = 10_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("balanceDiscountBps")));
        core.setSettings(s);
        _setDiscount(2_500);
        assertEq(core.balanceRate(), 7_500, "a later edit lands");
        assertEq(core.balanceBidOf(ids[2]), _score(ids[2]) * UNIT * 7_500 / 10_000);
    }

    // promise: SPEC 9 the view reads 0 when the module cannot pay the payout plus its royalty, and the fill reverts
    // PotTooSmall there; one wei more and both run (decision 159, C05 kept)
    function test_viewZeroAndFillRefusedWhenTheModuleCannotPayBoth() public {
        uint256[] memory ids = _credits(user, 1);
        uint256 pay = _payout(ids[0]);
        uint256 royalty = _royalty(pay);
        mod.setAvailable(pay + royalty - 1);
        assertEq(core.balanceBidOf(ids[0]), 0, "the view never advertises a payout the fill refuses");
        vm.prank(user);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
        mod.setAvailable(pay + royalty);
        assertEq(core.balanceBidOf(ids[0]), pay, "exactly enough: the view reads the payout");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, pay, "and the fill runs");
    }

    // promise: SPEC 9 a batch is bounded by available() alone: the payouts plus the royalties of the whole batch must
    // fit, else the whole batch reverts PotTooSmall and nothing moves
    function test_batchBoundedByAvailable() public {
        uint256[] memory ids = _credits(user, 3);
        uint256 two;
        for (uint256 i; i < 2; ++i) {
            uint256 pay = _payout(ids[i]);
            two += pay + _royalty(pay);
        }
        mod.setAvailable(two);
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user), before, "nothing paid on the refused batch");
        assertEq(CREDITS.ownerOf(ids[0]), user, "nothing moved");
        uint256[] memory first = new uint256[](2);
        first[0] = ids[0];
        first[1] = ids[1];
        vm.prank(user);
        core.sellForBalance(first);
        assertEq(xt.balanceOf(user) - before, _payout(ids[0]) + _payout(ids[1]), "the fitting batch runs");
    }

    // promise: SPEC 9 a tiny available refuses the batch with PotTooSmall, never a panic, and the view reads 0
    function test_tinyAvailableRefuses() public {
        mod.setAvailable(8_000_001);
        uint256[] memory ids = _credits(user, 3);
        assertEq(core.balanceBidOf(ids[0]), 0);
        vm.prank(user);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForBalance(ids);
    }

    // promise: SPEC 9 a balance fill never moves the eth bid outside value mode, and an eth fill never moves the posted
    // balance rate
    function test_routesAreIndependent() public {
        _fundPot(1 ether);
        uint256[] memory ids = _credits(user, 2);
        uint256 eth0 = core.ethRate();
        uint256 price0 = core.ethPrice();
        vm.prank(user);
        core.sellForBalance(_one(ids[0]));
        assertEq(core.ethRate(), eth0, "a balance fill leaves the eth bid");
        assertEq(core.ethPrice(), price0, "and the eth price state");
        uint256 posted = core.balanceRate();
        vm.prank(user);
        core.sellForEth(_one(ids[1]));
        assertEq(core.balanceRate(), posted, "an eth fill leaves the posted balance rate");
    }

    // promise: SPEC 9 the bid turning on, off and on again, and a module set, never change the posted rate or payout
    function test_switchesAndModuleSetLeaveThePostedRate() public {
        uint256[] memory ids = _credits(user, 1);
        uint256 pay = _payout(ids[0]);
        _setSwitches(true, false);
        assertEq(core.balanceRate(), 9_000, "posted with the bid off");
        _setSwitches(true, true);
        assertEq(core.balanceRate(), 9_000, "posted with the bid on");
        _setBalanceModule(address(mod));
        assertEq(core.balanceRate(), 9_000, "posted after a module set");
        assertEq(core.balanceBidOf(ids[0]), pay);
        _warp(1 hours);
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, pay);
    }

    // promise: SPEC 9 balanceRate reads the posted rate and balanceBidOf reads 0 while the module's unit read fails
    function test_failingUnitReadsZeroPayout() public {
        uint256[] memory ids = _credits(user, 1);
        mod.setRevertUnit(true);
        assertEq(core.balanceRate(), 9_000, "the posted rate needs no module read");
        assertEq(core.balanceBidOf(ids[0]), 0, "no payout without a unit");
        vm.prank(user);
        vm.expectRevert(ICore.BadModule.selector);
        core.sellForBalance(ids);
    }
}

/// the posted rate before any module is set: the rate reads, the payout is 0, the door refuses
contract BalanceFlatNoModuleTest is Fixture {
    // promise: SPEC 9 with no module balanceRate reads the posted rate, balanceBidOf reads 0 and the door reverts
    function test_noModule() public {
        assertEq(core.balanceModule(), address(0));
        assertEq(core.balanceRate(), 9_000, "posted with no module");
        uint256[] memory ids = _credits(seller, 1);
        assertEq(core.balanceBidOf(ids[0]), 0, "no payout with no module");
        vm.prank(seller);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(ids);
    }
}
