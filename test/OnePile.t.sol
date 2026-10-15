// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";

/// one pile for every credit. the balance token bid records an eth cost basis of `floorRate * score / refScore`
/// (decision 104), at least 1 wei, where the floor rate is the larger of the climbed price
/// state and the decayed peak. the record reads no pool price, so a pushed up or pushed down pool cannot move it and
/// the bid needs no pool key. every credit composes into the same statement. the three standalone settings have owner
/// setters, bounds and events
contract OnePileTest is Fixture {
    uint256 internal constant BPS = 10_000;
    /// a small sqrt price makes the balance token expensive in eth (a pushed up redemption value)
    uint160 internal constant LOW_SQRT = uint160(FixedPoint96.Q96 / 1000);
    /// a large sqrt price makes the balance token cheap in eth (a pushed down redemption value)
    uint160 internal constant HIGH_SQRT = uint160((uint256(1) << 96) * 1000);

    /// initializes the balance pool at `sp` and points the controller at it
    function _initPoolAt(uint160 sp) internal {
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(vk, sp);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
    }

    /// funds the balance pot and the eth pot so the balance bid has a pot to pay from and the eth bid reads nonzero
    function _ready() internal {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(mod), 1e24);
    }

    // ------------------------------------------------------------------ the balance bid's eth cost basis

    /// the credit score source the balance token bid reads: `scoreOf(seed, paidAt)` on the mainnet credit score contract
    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// the eth cost the sale records for `id`: `floorRate * score / refScore`, at least 1 wei. the floor rate is read at
    /// the current block, which the sale does not move
    function _backstop(uint256 id) internal view returns (uint256 b) {
        b = FullMath.mulDiv(core.floorRate(), _score(id), ctl.refScore());
        if (b == 0) b = 1;
    }

    // promise: SPEC 1 sellForBalance records the score scaled eth cost and reads no pool (decision 96)
    /// the recorded eth cost is the score-scaled backstop, with no pool key set
    function test_sellForBalance_costIsScoreTimesPointRateWithoutAPoolKey() public {
        _ready();
        assertFalse(ctl.balancePoolKeySet(), "no pool key");
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        // a quarter of the score, at the 800,000 lower bound of `refScore` when that is higher
        uint32 rs = uint32(_score(id) / 4);
        if (rs < 800_000) rs = 800_000;
        _setRefScore(rs);
        uint256 want = _backstop(id);
        vm.prank(seller);
        core.sellForBalance(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertGt(want, core.floorRate(), "the backstop scales above the floor rate for a rich credit");
        assertEq(cost, want, "the recorded cost is the scaled backstop");
        // the recorded cost is the point rate times the score (`pointRate` rounds down once, the cost once)
        uint256 pointValue = _score(id) * ctl.pointRate();
        assertGe(cost, pointValue, "at least score times the point rate");
        assertLt(cost - pointValue, _score(id), "and above it by less than the rounding of the point rate");
    }

    // promise: SPEC 1 the balance bid reads refScore from the Core setting, not the controller
    /// the bid records the score-scaled cost from the Core setting `refScore` even when the controller's `refScore()`
    /// read reverts, so a reverting or hostile controller cannot block or distort the bid
    function test_sellForBalance_usesCoreRefScoreNotTheController() public {
        _ready();
        uint256[] memory ids = _credits(seller, 1);
        uint256 want = _backstop(ids[0]);
        vm.mockCallRevert(address(ctl), abi.encodeWithSignature("refScore()"), "");
        vm.prank(seller);
        core.sellForBalance(ids);
        vm.clearMockedCalls();
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, want, "the recorded cost uses the Core setting refScore");
    }

    // promise: SPEC 1 the recorded cost reads no pool price (decision 96)
    /// a pushed up pool price (an expensive balance token) does not move the recorded cost: it stays the backstop
    function test_sellForBalance_costUnaffectedByAPushedUpPool() public {
        _ready();
        _initPoolAt(LOW_SQRT);
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        uint256 want = _backstop(id);
        vm.prank(seller);
        core.sellForBalance(ids);
        (, uint256 cost,) = core.creditInfo(id);
        assertEq(cost, want, "the recorded cost is the backstop, not the inflated pool value");
    }

    // ------------------------------------------------------------------ one pile, one compose

    // promise: SPEC 1 one pile: credits from every door compose into one kind of statement
    /// credits bought through the eth bid and the balance bid share one pile and compose into one statement
    function test_compose_oneKindFromMixedCredits() public {
        _ready();
        _setBalancePool();
        // 40 credits through the eth bid, then 40 through the balance bid, into the single pile
        _fillEthPile(40);
        uint256[] memory xIds = _credits(seller, 40);
        vm.prank(seller);
        core.sellForBalance(xIds);
        assertEq(core.pileSize(), 80, "one pile holds both kinds of credits");

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
        assertEq(cost, sum, "the cost basis is the sum of the mixed credits' eth cost bases");
        assertEq(core.pileSize(), 0, "the pile is emptied by the compose");
        assertEq(STATEMENTS.ownerOf(sid), address(core));
    }

    // ------------------------------------------------------------------ the standalone settings

    // promise: SPEC 1 creditCostToPotBps owner setting
    function test_setter_creditCostToPotBps() public {
        assertEq(core.creditCostToPotBps(), 8_000, "launch value");
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

    // promise: SPEC 1 chosenComposeOn owner switch, off at launch
    function test_setter_chosenComposeOn() public {
        assertFalse(core.chosenComposeOn(), "off at launch");
        vm.expectEmit(address(core));
        emit ICore.ChosenComposeOnSet(true);
        vm.prank(owner);
        core.setChosenComposeOn(true);
        assertTrue(core.chosenComposeOn());
        vm.prank(owner);
        core.setChosenComposeOn(false);
        assertFalse(core.chosenComposeOn());
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setChosenComposeOn(true);
    }

    // promise: SPEC 1 minCcToChoose owner setting
    function test_setter_minCcToChoose() public {
        assertEq(core.minCcToChoose(), 1e18, "1 coin at launch");
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
