// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IStatements, Mainnet, RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// @notice `swapCredit`: a holder replaces a pile credit with one of equal or higher score for a `swapFeeCc` coin
/// fee. the live CreditScore is never mocked (owner rule): real strategy credits chosen for their real scores drive
/// the score rule. the outgoing credit is sold into the live pile; the incoming credit is owned and approved by the
/// swapper
contract CreditSwapTest is LiveFixture {
    address internal who;

    // real strategy credits at the pin, scores from the CreditScore contract (RATE_SCORE = 1e6):
    // an equal-score pair, both score 851850, for the score(in) == score(out) cases and the score-independent
    // mechanics cases
    uint256 internal constant EQ_OUT = 45094; // score 851850
    uint256 internal constant EQ_IN = 45684; // score 851850
    // a high and a low credit for the strict-order cases
    uint256 internal constant HIGH_ID = 32676; // score 7695845
    uint256 internal constant LOW_ID = 12968; // score 808824

    function setUp() public override {
        super.setUp();
        who = _user("swapper");
        // the mechanics tests isolate the swap from the fee; the fee tests set their own swapFeeCc
        _setSwapFeeCc(0);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev moves a specific strategy credit `id` to `to` and approves the core for it. verifies the strategy still
    /// holds `id` at the pin, so a credit that left the strategy fails loudly instead of silently picking another
    function _take(address to, uint256 id) private {
        assertEq(CREDITS.ownerOf(id), STRATEGY, "credit is not strategy-held at the pin");
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, to, id);
        vm.prank(to);
        CREDITS.setApprovalForAll(address(core), true);
    }

    /// @dev sells the specific credit `id` into the eth pile, as `_fillEthPile` does for arbitrary credits: restates a
    /// loosened rate to the opening rate, funds the pot above the credit's scaled bid plus royalty, then sells
    function _pileOne(uint256 id) private {
        _take(seller, id);
        uint256 opening = core.RATE_START();
        if (core.rateAtCheckpoint() > opening) {
            vm.prank(owner);
            core.setRate(opening);
        }
        uint256 room = _unclampedPot();
        if (core.ethPot() < room) _fundPot(room);
        uint256 pay = core.ethRate() * _scoreOf(id) / RATE_SCORE;
        uint256 need = pay + pay * core.settings().buyToArtistBps / 10_000;
        if (core.ethPot() < need * 6) _fundPot(need * 6);
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    /// @dev the pile position of `id`, oldest first. the live pile already holds a full page, so a swapped credit no
    /// longer sits at position 0 as it did on the fresh fixture; a test records the outgoing credit's position and
    /// reads the same position after the swap
    function _pileIndexOf(uint256 id) private view returns (uint256) {
        uint256[] memory page = core.pilePage(0, core.pileSize());
        for (uint256 i; i < page.length; ++i) {
            if (page[i] == id) return i;
        }
        revert("id not in pile");
    }

    /// @dev the credit id at pile position `idx`, oldest first
    function _pileAt(uint256 idx) private view returns (uint256) {
        return core.pilePage(0, idx + 1)[idx];
    }

    /// @dev the outgoing credit sold into the pile and the incoming credit owned and approved by `who`
    function _pair(uint256 outId, uint256 inId) internal returns (uint256, uint256) {
        _pileOne(outId);
        _take(who, inId);
        return (outId, inId);
    }

    // ------------------------------------------------------------------ tests

    // promise: SPEC 6 swapCredit, incoming credit inherits the pile node (position, cost, acquisition time)
    function test_slotInheritance() public {
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        (, uint256 cost, uint64 acq) = core.creditInfo(outId);
        uint256 size = core.pileSize();
        uint256 idx = _pileIndexOf(outId);

        vm.prank(who);
        core.swapCredit(inId, outId);

        (bool inPileIn, uint256 costIn, uint64 acqIn) = core.creditInfo(inId);
        (bool inPileOut,,) = core.creditInfo(outId);
        assertTrue(inPileIn, "the incoming credit is in the pile");
        assertFalse(inPileOut, "the outgoing credit left the pile");
        assertEq(costIn, cost, "the incoming credit inherits the cost basis");
        assertEq(acqIn, acq, "the incoming credit inherits the acquisition time");
        assertEq(core.pileSize(), size, "the pile size is unchanged");
        assertEq(_pileAt(idx), inId, "the incoming credit holds the outgoing one's position");
        assertEq(CREDITS.ownerOf(inId), address(core), "the core holds the incoming credit");
        assertEq(CREDITS.ownerOf(outId), who, "the caller holds the outgoing credit");
    }

    // promise: SPEC 6 score(inId) > score(outId) is allowed
    function test_scoreRule_higherAllowed() public {
        (uint256 outId, uint256 inId) = _pair(LOW_ID, HIGH_ID);
        uint256 idx = _pileIndexOf(outId);
        vm.prank(who);
        core.swapCredit(inId, outId);
        assertEq(_pileAt(idx), inId, "a higher score swaps in");
    }

    // promise: SPEC 6 score(inId) == score(outId) is allowed
    function test_scoreRule_equalAllowed() public {
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        assertEq(_scoreOf(inId), _scoreOf(outId), "the chosen pair has equal real scores");
        uint256 idx = _pileIndexOf(outId);
        vm.prank(who);
        core.swapCredit(inId, outId);
        assertEq(_pileAt(idx), inId, "an equal score swaps in");
    }

    // promise: SPEC 6 score(inId) < score(outId) reverts ScoreTooLow
    function test_scoreRule_lowerReverts() public {
        (uint256 outId, uint256 inId) = _pair(HIGH_ID, LOW_ID);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(ICore.ScoreTooLow.selector, inId, outId));
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 the fee is pulled from the caller and burned on the coin
    function test_feeBurned() public {
        uint96 fee = 1e18;
        _setSwapFeeCc(fee);
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        _buyCoin(who, 1 ether);
        uint256 held = coin.balanceOf(who);
        assertGe(held, fee, "the caller holds enough coin for the fee");
        uint256 supply = coin.totalSupply();
        uint256 coreHeld = coin.balanceOf(address(core));

        vm.prank(who);
        coin.approve(address(core), fee);
        vm.prank(who);
        core.swapCredit(inId, outId);

        assertEq(coin.balanceOf(who), held - fee, "the fee leaves the caller");
        assertEq(coin.totalSupply(), supply - fee, "the fee is burned");
        assertEq(coin.balanceOf(address(core)), coreHeld, "the core keeps no coin");
    }

    // promise: SPEC 6 swapCredit at the launch fee of 10,000 CC pulls and burns the whole fee
    /// the launch value of swapFeeCc (script/config/mainnet.json), left as shipped rather than zeroed: a swap pulls
    /// 10,000 CC from the caller and burns it on the coin. setting swapFeeCc is this test's own subject, so pranking
    /// it is allowed (addendum 2)
    function test_feeAtTheLaunchValueOfTenThousandCc() public {
        uint96 launchFee = 10_000e18;
        assertEq(Mainnet.defaultSettings().swapFeeCc, launchFee, "the launch swap fee");
        _setSwapFeeCc(launchFee);
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        _buyCoin(who, 20 ether);
        uint256 held = coin.balanceOf(who);
        assertGe(held, launchFee, "the caller holds the launch fee in coin");
        uint256 supply = coin.totalSupply();
        uint256 coreHeld = coin.balanceOf(address(core));
        uint256 idx = _pileIndexOf(outId);

        vm.prank(who);
        coin.approve(address(core), launchFee);
        vm.prank(who);
        core.swapCredit(inId, outId);

        assertEq(coin.balanceOf(who), held - launchFee, "the launch fee left the caller");
        assertEq(coin.totalSupply(), supply - launchFee, "the launch fee was burned");
        assertEq(coin.balanceOf(address(core)), coreHeld, "the core keeps no coin");
        assertEq(_pileAt(idx), inId, "the swap still runs at the launch fee");
    }

    // promise: SPEC 6 a zero fee skips the coin transfer
    function test_feeZeroBurnsNothing() public {
        _setSwapFeeCc(0);
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        uint256 supply = coin.totalSupply();
        uint256 idx = _pileIndexOf(outId);
        assertEq(coin.balanceOf(who), 0, "the caller holds no coin and has approved none");

        vm.prank(who);
        core.swapCredit(inId, outId);

        assertEq(coin.totalSupply(), supply, "a zero fee burns nothing");
        assertEq(_pileAt(idx), inId, "the swap still runs");
    }

    // promise: SPEC 6 swapCredit reverts while paused
    function test_pausedReverts() public {
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        vm.prank(owner);
        core.setPaused(true);
        vm.prank(who);
        vm.expectRevert(ICore.Paused.selector);
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 swapCredit reverts after migrate retires the core
    function test_retiredReverts() public {
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        MigrationSink sink = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.prank(owner);
        core.migrate(10);
        assertTrue(core.retired(), "the core is retired");
        vm.prank(who);
        vm.expectRevert(ICore.Retired.selector);
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 an incoming credit already in the pile reverts InPile
    function test_pileCreditAsInIdReverts() public {
        _pileOne(EQ_OUT);
        _pileOne(EQ_IN);
        vm.prank(who);
        vm.expectRevert(ICore.InPile.selector);
        core.swapCredit(EQ_IN, EQ_OUT);
    }

    // promise: SPEC 6 a caller who does not own the incoming credit reverts NotOwner
    function test_notOwnerReverts() public {
        (uint256 outId, uint256 inId) = _pair(EQ_OUT, EQ_IN);
        address other = _user("other");
        vm.prank(other);
        vm.expectRevert(ICore.NotOwner.selector);
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 an outgoing id not in the pile reverts NotInPile
    function test_notInPileReverts() public {
        _take(who, EQ_IN); // incoming credit, owned by the caller
        _take(who, EQ_OUT); // outgoing credit, owned but never sold into the pile
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, EQ_OUT));
        core.swapCredit(EQ_IN, EQ_OUT);
    }

    // promise: SPEC 6 a zero incoming id reverts ZeroId
    function test_zeroInIdReverts() public {
        _pileOne(EQ_OUT);
        vm.prank(who);
        vm.expectRevert(ICore.ZeroId.selector);
        core.swapCredit(0, EQ_OUT);
    }

    // promise: SPEC 6 compose reads the swapped-in credit in the outgoing credit's slot
    function test_composeUsesSwappedInCredit() public {
        // the live pile already holds a full page, so compose composes its 80 oldest credits. pick an outgoing credit
        // from that page whose real score the high-score incoming credit can match, swap it in, and assert compose
        // reads the swapped-in id in that slot
        uint256[] memory page = core.pilePage(0, 80);
        uint256 inId = HIGH_ID;
        uint256 inScore = _scoreOf(inId);
        uint256 k = type(uint256).max;
        for (uint256 i; i < page.length; ++i) {
            if (_scoreOf(page[i]) <= inScore) {
                k = i;
                break;
            }
        }
        require(k != type(uint256).max, "no page credit with a matchable score at the pin");
        uint256 outId = page[k];
        _take(who, inId);

        // the live credit sale is on, so compose refuses in-window pile credits: warp past the window
        _warp(ctl.creditWindow() + 1);

        vm.prank(who);
        core.swapCredit(inId, outId);

        uint256[80] memory expected;
        for (uint256 i; i < 80; ++i) {
            expected[i] = page[i];
        }
        expected[k] = inId;

        vm.fee(composeBasefee);
        vm.expectCall(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.compose.selector, expected, defaultFormat(expected[0]))
        );
        vm.prank(keeper);
        core.compose();
    }
}
