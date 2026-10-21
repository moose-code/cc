// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// `rescueNft` of the Core: an ERC721 token leaves only when the Core's books do not hold it. the live Core, Credits,
/// Statements and a real ERC721 of the fork. the successor of the migration case is a fresh Core (not yet deployed);
/// the source Core is the live one (brief owner rule)
contract RescueTest is LiveFixture {
    /// a live ERC721 collection on the fork (BAYC)
    address internal constant FOREIGN = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal dest = address(0xD357);
    address internal stranger = address(0x5757);

    event NftRescued(address indexed token, uint256 indexed id, address indexed to);

    function setUp() public override {
        super.setUp();
        // the migration case builds a fresh successor of the live coin through the inherited helper, which reads `lc`
        _initLiveConfig();
    }

    function _rescue(address token, uint256 id, address to) internal {
        vm.prank(owner);
        core.rescueNft(token, id, to);
    }

    function _expectRescueRevert(address token, uint256 id, bytes4 sel) internal {
        vm.expectRevert(sel);
        vm.prank(owner);
        core.rescueNft(token, id, dest);
    }

    // promise: INTEGRATION NoCreditRescue on rescueNft
    function test_REVERT_aCreditInAPileStays() public {
        uint256[] memory ids = _fillEthPile(3);
        uint256 pileBefore = core.pileSize();
        (bool inPile,,) = core.creditInfo(ids[1]);
        assertTrue(inPile, "setup: the credit is in the pile");
        _expectRescueRevert(address(CREDITS), ids[1], ICore.NoCreditRescue.selector);
        assertEq(CREDITS.ownerOf(ids[1]), address(core), "the credit moved");
        // the live pile may already hold credits; the failed rescue leaves the pile unchanged, whatever its size
        assertEq(core.pileSize(), pileBefore, "the pile changed");
    }

    // promise: SPEC 11 credits leave the Core at the owner's call only through migrate
    function test_REVERT_aCreditSentStraightToTheCoreStays() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertFalse(inPile, "a straight transfer is not in a pile");
        _expectRescueRevert(address(CREDITS), ids[0], ICore.NoCreditRescue.selector);
        assertEq(CREDITS.ownerOf(ids[0]), address(core), "the credit moved");
    }

    // promise: SPEC 11 credits leave the Core at the owner's call only through migrate: the successor's owner cannot
    // rescue a migrated credit before adopt
    function test_REVERT_aMigratedCreditIsNotRescuableOnTheSuccessor() public {
        uint256[] memory ids = _fillEthPile(3);
        ICore next = _successorCore(address(ctl), core.RATE_START(), _settings());
        vm.startPrank(owner);
        core.setSuccessor(address(next));
        core.lockSuccessor();
        // the live pile may hold credits older than the three just added, so migrate the whole pile to guarantee the
        // test's credit reaches the successor
        core.migrate(core.pileSize());
        vm.stopPrank();
        (bool inPile,,) = next.creditInfo(ids[0]);
        assertFalse(inPile, "setup: the migrated credit is untracked on the successor");
        vm.expectRevert(ICore.NoCreditRescue.selector);
        vm.prank(owner);
        next.rescueNft(address(CREDITS), ids[0], owner);
        assertEq(CREDITS.ownerOf(ids[0]), address(next), "the credit left the successor");
    }

    // promise: INTEGRATION Held on rescueNft
    function test_REVERT_aHeldStatementStays() public {
        Composed memory c = _composeOnce();
        (bool held,,) = core.statementInfo(c.sid);
        assertTrue(held, "setup: the statement is held");
        _expectRescueRevert(address(STATEMENTS), c.sid, ICore.Held.selector);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement moved");
    }

    // promise: SPEC 1 NFTs leave the books only through rescueNft
    function test_OK_aForeignErc721Leaves() public {
        (bool ok, bytes memory out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(1)));
        assertTrue(ok && out.length == 32, "setup: the collection answers on the fork");
        address holder = abi.decode(out, (address));
        vm.prank(holder);
        (bool sent,) =
            FOREIGN.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, address(core), 1));
        assertTrue(sent, "setup: the token reached the core");
        _rescue(FOREIGN, 1, dest);
        (, out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(1)));
        assertEq(abi.decode(out, (address)), dest, "the token did not reach the destination");
    }

    // promise: INTEGRATION NotHolder on rescueNft
    function test_REVERT_aTokenTheCoreDoesNotHold() public {
        (bool ok, bytes memory out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(2)));
        assertTrue(ok && abi.decode(out, (address)) != address(core), "setup");
        _expectRescueRevert(FOREIGN, 2, ICore.NotHolder.selector);
    }

    // promise: INTEGRATION OnlyOwner on rescueNft
    function test_REVERT_notTheOwner() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.expectRevert(ICore.OnlyOwner.selector);
        vm.prank(stranger);
        core.rescueNft(address(CREDITS), ids[0], stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        vm.prank(seller);
        core.rescueNft(address(CREDITS), ids[0], seller);
        assertEq(CREDITS.ownerOf(ids[0]), address(core), "the credit moved");
    }

    // promise: INTEGRATION ZeroAddress on rescueNft
    function test_REVERT_theZeroDestination() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.expectRevert(ICore.ZeroAddress.selector);
        vm.prank(owner);
        core.rescueNft(address(CREDITS), ids[0], address(0));
    }
}
