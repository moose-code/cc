// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, IStatements, Mainnet} from "../src/interfaces/Interfaces.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// @notice `swapCredit` (decision 118): a holder replaces a pile credit with one of equal or higher score for a
/// `swapFeeCc` coin fee. scores are mocked on the credit score contract so the score rule is exact, not fork dependent
contract CreditSwapTest is Fixture {
    address internal who;

    function setUp() public override {
        super.setUp();
        who = _user("swapper");
        // the mechanics tests isolate the swap from the fee; the fee tests set their own swapFeeCc
        _setSwapFeeCc(0);
    }

    /// @dev forces `scoreOf(seed, paidAt)` of credit `id` to `v`, the value every door and `swapCredit` read
    function _mockScore(uint256 id, uint256 v) internal {
        vm.mockCall(
            Mainnet.CREDIT_SCORE,
            abi.encodeWithSelector(ICreditScore.scoreOf.selector, CREDITS.seedOf(id), CREDITS.timestampOf(id)),
            abi.encode(v)
        );
    }

    /// @dev a one credit pile and a fresh credit `who` owns and approved, with mocked scores `sOut` and `sIn`
    function _pair(uint256 sOut, uint256 sIn) internal returns (uint256 outId, uint256 inId) {
        outId = _fillEthPile(1)[0];
        inId = _credits(who, 1)[0];
        _mockScore(outId, sOut);
        _mockScore(inId, sIn);
    }

    // promise: SPEC 6 swapCredit, incoming credit inherits the pile node (position, cost, acquisition time)
    function test_slotInheritance() public {
        (uint256 outId, uint256 inId) = _pair(100, 100);
        (, uint256 cost, uint64 acq) = core.creditInfo(outId);
        uint256 size = core.pileSize();

        vm.prank(who);
        core.swapCredit(inId, outId);

        (bool inPileIn, uint256 costIn, uint64 acqIn) = core.creditInfo(inId);
        (bool inPileOut,,) = core.creditInfo(outId);
        assertTrue(inPileIn, "the incoming credit is in the pile");
        assertFalse(inPileOut, "the outgoing credit left the pile");
        assertEq(costIn, cost, "the incoming credit inherits the cost basis");
        assertEq(acqIn, acq, "the incoming credit inherits the acquisition time");
        assertEq(core.pileSize(), size, "the pile size is unchanged");
        assertEq(core.pilePage(0, 1)[0], inId, "the incoming credit holds the outgoing one's position");
        assertEq(CREDITS.ownerOf(inId), address(core), "the core holds the incoming credit");
        assertEq(CREDITS.ownerOf(outId), who, "the caller holds the outgoing credit");
    }

    // promise: SPEC 6 score(inId) > score(outId) is allowed
    function test_scoreRule_higherAllowed() public {
        (uint256 outId, uint256 inId) = _pair(100, 101);
        vm.prank(who);
        core.swapCredit(inId, outId);
        assertEq(core.pilePage(0, 1)[0], inId, "a higher score swaps in");
    }

    // promise: SPEC 6 score(inId) == score(outId) is allowed
    function test_scoreRule_equalAllowed() public {
        (uint256 outId, uint256 inId) = _pair(777, 777);
        vm.prank(who);
        core.swapCredit(inId, outId);
        assertEq(core.pilePage(0, 1)[0], inId, "an equal score swaps in");
    }

    // promise: SPEC 6 score(inId) < score(outId) reverts ScoreTooLow
    function test_scoreRule_lowerReverts() public {
        (uint256 outId, uint256 inId) = _pair(100, 99);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(ICore.ScoreTooLow.selector, inId, outId));
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 the fee is pulled from the caller and burned on the coin
    function test_feeBurned() public {
        uint96 fee = 1e18;
        _setSwapFeeCc(fee);
        (uint256 outId, uint256 inId) = _pair(100, 100);
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

    // promise: SPEC 6 a zero fee skips the coin transfer
    function test_feeZeroSkipsTransfer() public {
        _setSwapFeeCc(0);
        (uint256 outId, uint256 inId) = _pair(100, 100);
        uint256 supply = coin.totalSupply();
        assertEq(coin.balanceOf(who), 0, "the caller holds no coin and has approved none");

        vm.prank(who);
        core.swapCredit(inId, outId);

        assertEq(coin.totalSupply(), supply, "a zero fee burns nothing");
        assertEq(core.pilePage(0, 1)[0], inId, "the swap still runs");
    }

    // promise: SPEC 6 swapCredit reverts while paused
    function test_pausedReverts() public {
        (uint256 outId, uint256 inId) = _pair(100, 100);
        vm.prank(owner);
        core.setPaused(true);
        vm.prank(who);
        vm.expectRevert(ICore.Paused.selector);
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 swapCredit reverts after migrate retires the core
    function test_retiredReverts() public {
        (uint256 outId, uint256 inId) = _pair(100, 100);
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
        uint256[] memory ids = _fillEthPile(2);
        _mockScore(ids[0], 100);
        _mockScore(ids[1], 100);
        vm.prank(who);
        vm.expectRevert(ICore.InPile.selector);
        core.swapCredit(ids[1], ids[0]);
    }

    // promise: SPEC 6 a caller who does not own the incoming credit reverts NotOwner
    function test_notOwnerReverts() public {
        (uint256 outId, uint256 inId) = _pair(100, 100);
        address other = _user("other");
        vm.prank(other);
        vm.expectRevert(ICore.NotOwner.selector);
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 an outgoing id not in the pile reverts NotInPile
    function test_notInPileReverts() public {
        _fillEthPile(1);
        uint256 inId = _credits(who, 1)[0];
        uint256 outId = _credits(who, 1)[0]; // owned, never sold into the pile
        _mockScore(inId, 100);
        _mockScore(outId, 100);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, outId));
        core.swapCredit(inId, outId);
    }

    // promise: SPEC 6 a zero incoming id reverts ZeroId
    function test_zeroInIdReverts() public {
        uint256 outId = _fillEthPile(1)[0];
        vm.prank(who);
        vm.expectRevert(ICore.ZeroId.selector);
        core.swapCredit(0, outId);
    }

    // promise: SPEC 6 compose reads the swapped-in credit in the outgoing credit's slot
    function test_composeUsesSwappedInCredit() public {
        uint256[] memory page = _fillEthPile(80);
        uint256 outId = page[0];
        uint256 inId = _credits(who, 1)[0];
        _mockScore(outId, 100);
        _mockScore(inId, 100);

        vm.prank(who);
        core.swapCredit(inId, outId);

        uint256[80] memory expected;
        expected[0] = inId;
        for (uint256 i = 1; i < 80; ++i) expected[i] = page[i];

        vm.fee(composeBasefee);
        vm.expectCall(
            address(STATEMENTS), abi.encodeWithSelector(IStatements.compose.selector, expected, defaultFormat(inId))
        );
        vm.prank(keeper);
        core.compose();
    }
}
