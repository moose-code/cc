// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// `rescueNft` of the Core: an ERC721 token leaves only when the Core's books do not hold it. real Credits, Statements
/// and a real ERC721 of the fork
contract RescueTest is Fixture {
    /// a live ERC721 collection on the fork (BAYC)
    address internal constant FOREIGN = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal dest = address(0xD357);
    address internal stranger = address(0x5757);

    event NftRescued(address indexed token, uint256 indexed id, address indexed to);

    function _rescue(address token, uint256 id, address to) internal {
        vm.prank(owner);
        core.rescueNft(token, id, to);
    }

    function _expectRescueRevert(address token, uint256 id, bytes4 sel) internal {
        vm.expectRevert(sel);
        vm.prank(owner);
        core.rescueNft(token, id, dest);
    }

    // promise: INTEGRATION InPile on rescueNft
    function test_REVERT_aCreditInAPileStays() public {
        uint256[] memory ids = _fillEthPile(3);
        (bool inPile,,) = core.creditInfo(ids[1]);
        assertTrue(inPile, "setup: the credit is in the pile");
        _expectRescueRevert(address(CREDITS), ids[1], ICore.InPile.selector);
        assertEq(CREDITS.ownerOf(ids[1]), address(core), "the credit moved");
        assertEq(core.pileSize(), 3, "the pile changed");
    }

    // promise: SPEC 1 NFTs leave the books only through rescueNft
    function test_OK_aCreditSentStraightToTheCoreLeaves() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertFalse(inPile, "a straight transfer is not in a pile");
        vm.expectEmit(true, true, true, true, address(core));
        emit NftRescued(address(CREDITS), ids[0], dest);
        _rescue(address(CREDITS), ids[0], dest);
        assertEq(CREDITS.ownerOf(ids[0]), dest, "the credit did not reach the destination");
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
        (bool sent,) = FOREIGN.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, address(core), 1));
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
