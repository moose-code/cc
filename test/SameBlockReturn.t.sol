// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";

/// a credit the engine sold through `sellCreditTo` in a block is refused at every intake door in the same block
/// (`SameBlockReturn`): `sellForEth`, `sellForBalance`, `buyListing`, and `swapCredit` as the incoming credit. the next
/// block the credit may be sold back
contract SameBlockReturnTest is Fixture {
    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = _user("sbr.buyer");
    }

    /// fills the eth pile with `n` credits, turns the credit sale on, and has `buyer` buy the first at its price in
    /// this block. returns the full pile ids; ids[0] is the bought credit, now owned by `buyer`
    function _buyFirst(uint256 n) internal returns (uint256[] memory ids) {
        ids = _fillEthPile(n);
        _setCreditSaleOn(true);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(buyer, buyer.balance + price);
        vm.prank(buyer);
        ctl.buyCredit{value: price}(ids[0]);
        vm.prank(buyer);
        CREDITS.setApprovalForAll(address(core), true);
    }

    // promise: SPEC 1 a credit sold this block is refused by sellForEth
    function test_sellForEthRefusesSameBlock() public {
        uint256 id = _buyFirst(1)[0];
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("SameBlockReturn(uint256)", id));
        core.sellForEth(_one(id));
    }

    // promise: SPEC 1 the refusal lifts the next block
    function test_sellForEthAllowedNextBlock() public {
        uint256 id = _buyFirst(1)[0];
        vm.roll(block.number + 1);
        vm.prank(buyer);
        core.sellForEth(_one(id));
    }

    // promise: SPEC 1 a credit sold this block is refused by buyListing
    function test_buyListingRefusesSameBlock() public {
        _approveAdapter(rawAdapter);
        uint256 id = _buyFirst(1)[0];
        vm.expectRevert(abi.encodeWithSignature("SameBlockReturn(uint256)", id));
        core.buyListing(rawAdapter, id, "");
    }

    // promise: SPEC 1 a credit sold this block is refused by swapCredit as the incoming credit
    function test_swapCreditRefusesSameBlock() public {
        uint256[] memory ids = _buyFirst(2); // ids[0] bought by buyer, ids[1] stays in the pile
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("SameBlockReturn(uint256)", ids[0]));
        core.swapCredit(ids[0], ids[1]);
    }

    // promise: SPEC 1 a credit sold this block is refused by sellForBalance
    function test_sellForBalanceRefusesSameBlock() public {
        _enterPhase2();
        uint256 id = _buyFirst(1)[0];
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("SameBlockReturn(uint256)", id));
        core.sellForBalance(_one(id));
    }
}
