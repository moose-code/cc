// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";

/// one pile for every credit. the balance token bid records an eth cost basis of `floorRate * score / RATE_SCORE`
/// (decision 104), at least 1 wei, where the floor rate is the larger of the climbed price
/// state and the decayed peak. the record reads no pool price, so the pool key cannot move it and
/// the bid needs no pool key. every credit composes into the same statement. the three standalone settings have owner
/// setters, bounds and events
contract OnePileTest is LiveFixture {
    uint256 internal constant BPS = 10_000;

    /// funds the balance pot and the eth pot so the balance bid has a pot to pay from and the eth bid reads nonzero.
    /// `_enterPhase2` funds the live treasury LIVE_WORKING_FUND (10_000 ether) of working BALANCE, enough for the
    /// single and few credit balance fills; the compose suite funds more
    function _ready() internal {
        _enterPhase2();
        _fundPot(3 ether);
    }

    // ------------------------------------------------------------------ the balance bid's eth cost basis

    /// the credit score source the balance token bid reads: `scoreOf(seed, paidAt)` on the mainnet credit score contract
    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// the eth cost the sale records for `id`: `floorRate * score / RATE_SCORE`, at least 1 wei. the floor rate is read
    /// at the current block, which the sale does not move
    function _backstop(uint256 id) internal view returns (uint256 b) {
        b = FullMath.mulDiv(core.floorRate(), _score(id), RATE_SCORE);
        if (b == 0) b = 1;
    }

    // promise: SPEC 1 sellForBalance records the score scaled eth cost and reads no pool (decision 96)
    /// the recorded eth cost is the score-scaled backstop, with no pool key set. the live credit's real score is used
    /// (the live CreditScore is never mocked), so `want` is recomputed from it
    function test_sellForBalance_costIsScoreTimesPointRateWithoutAPoolKey() public {
        _ready();
        assertFalse(ctl.balancePoolKeySet(), "no pool key");
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        uint256 want = _backstop(id);
        vm.prank(seller);
        core.sellForBalance(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, want, "the recorded cost is the scaled backstop");
        // the recorded cost is the point rate times the score (`pointRate` rounds down once, the cost once)
        uint256 pointValue = _score(id) * ctl.pointRate();
        assertGe(cost, pointValue, "at least score times the point rate");
        assertLt(cost - pointValue, _score(id), "and above it by less than the rounding of the point rate");
    }

    // promise: SPEC 1 the balance bid prices on the fixed 100 point basis, not the controller
    /// the bid records the score-scaled cost on the fixed 100 point basis even when every controller read reverts, so a
    /// reverting or hostile controller cannot block or distort the bid
    function test_sellForBalance_usesFixedBasisNotTheController() public {
        _ready();
        uint256[] memory ids = _credits(seller, 1);
        uint256 want = _backstop(ids[0]);
        vm.mockCallRevert(address(ctl), bytes(""), bytes(""));
        vm.prank(seller);
        core.sellForBalance(ids);
        vm.clearMockedCalls();
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, want, "the recorded cost uses the fixed 100 point basis");
    }

    // promise: SPEC 1 the recorded cost reads no pool price (decision 96)
    /// with the live eth / BALANCE pool key set, the recorded cost still stays the backstop: it reads no pool price, so
    /// the pool key does not move it
    function test_sellForBalance_costUnaffectedByThePoolKey() public {
        _ready();
        _setLiveBalancePool();
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        uint256 want = _backstop(id);
        vm.prank(seller);
        core.sellForBalance(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, want, "the recorded cost is the backstop, regardless of the pool key");
    }

    // ------------------------------------------------------------------ one pile, one compose

    // promise: SPEC 1 one pile: credits from every door compose into one kind of statement
    /// credits bought through the eth bid and the balance bid share one pile and compose into one statement
    function test_compose_oneKindFromMixedCredits() public {
        _ready();
        // 40 balance fills each pay about score * unit * rate, up to ~16_000 ether in total; fund well above it
        _fundTreasuryWorking(20_000 ether);
        _setLiveBalancePool();
        // the live Core holds a standing pile; measure it, then add both kinds and check the pile grew by the 80 added
        uint256 base = core.pileSize();
        // 40 credits through the eth bid, then 40 through the balance bid, into the single pile
        _fillEthPile(40);
        uint256[] memory xIds = _credits(seller, 40);
        vm.prank(seller);
        core.sellForBalance(xIds);
        assertEq(core.pileSize(), base + 80, "one pile holds both kinds of credits");

        // the live controller runs with the credit sale on, so a page composes only once its oldest credits are past
        // the window; warp there, then one compose takes the oldest page of 80
        _warpComposeReady();
        uint256[] memory page = core.pilePage(0, 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (, uint256 c,) = core.creditInfo(page[i]);
            sum += c;
        }
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        (bool held, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held, "the statement is held");
        assertEq(cost, sum, "the cost basis is the sum of the composed page's eth cost bases");
        assertEq(core.pileSize(), base, "the compose removed exactly one page of 80");
        assertEq(STATEMENTS.ownerOf(sid), address(core));
    }

    // ------------------------------------------------------------------ the standalone settings

    // promise: SPEC 1 creditCostToPotBps owner setting
    /// on the live Core the setting holds its live value, so the test reads it and asserts the setter mechanics, the
    /// bound and OnlyOwner rather than a launch value
    function test_setter_creditCostToPotBps() public {
        uint256 live = core.creditCostToPotBps();
        assertLe(live, 10_000, "the live value is within the bound");
        vm.expectEmit(address(core));
        emit ICore.CreditCostToPotBpsSet(6_000);
        vm.prank(owner);
        core.setCreditCostToPotBps(6_000);
        assertEq(core.creditCostToPotBps(), 6_000);
        vm.prank(owner);
        core.setCreditCostToPotBps(10_000);
        assertEq(core.creditCostToPotBps(), 10_000, "the top of the bound");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("creditCostToPotBps")));
        core.setCreditCostToPotBps(10_001);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setCreditCostToPotBps(0);
    }

    // promise: SPEC 1 chosenComposeOn owner switch
    /// reads the live state and toggles to its opposite and back, asserting the setter, the event and OnlyOwner without
    /// pinning a launch value
    function test_setter_chosenComposeOn() public {
        bool live = core.chosenComposeOn();
        vm.expectEmit(address(core));
        emit ICore.ChosenComposeOnSet(!live);
        vm.prank(owner);
        core.setChosenComposeOn(!live);
        assertEq(core.chosenComposeOn(), !live);
        vm.prank(owner);
        core.setChosenComposeOn(live);
        assertEq(core.chosenComposeOn(), live);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setChosenComposeOn(true);
    }

    // promise: SPEC 1 minCcToChoose owner setting
    /// reads the live value and asserts the setter mechanics, the type top and OnlyOwner rather than a launch value
    function test_setter_minCcToChoose() public {
        uint256 live = core.minCcToChoose();
        assertLe(live, type(uint96).max, "the live value is within the type");
        vm.expectEmit(address(core));
        emit ICore.MinCcToChooseSet(123e18);
        vm.prank(owner);
        core.setMinCcToChoose(123e18);
        assertEq(core.minCcToChoose(), 123e18);
        vm.prank(owner);
        core.setMinCcToChoose(type(uint96).max);
        assertEq(core.minCcToChoose(), type(uint96).max, "the top of the type");
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setMinCcToChoose(1);
    }
}
