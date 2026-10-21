// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {CreatePushSplit} from "../script/CreatePushSplit.s.sol";
import {PushSplitCreator, SplitConfig, ISplitFactoryV2, ISplitWalletV2} from "../script/PushSplit.sol";

contract SplitToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "t";
    }

    function symbol() public pure override returns (string memory) {
        return "t";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// the decision 255 split against the real Splits v2.2 factories on a mainnet fork after the owner's form split
contract CreatePushSplitTest is Test {
    /// the pull split the splits.org form created at block 26,238,176
    address internal constant FORM_SPLIT = 0xE2324c8CdE4185de580d5369972b243bb6365C11;
    address internal constant ARTIST = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a;
    address internal constant OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    CreatePushSplit internal s;

    function setUp() public {
        // the form split exists from block 26,238,176; an RPC whose head is older (CI's pinned local fork) skips
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        uint256 at = vm.envOr("SPLIT_FORK_BLOCK", uint256(26_238_200));
        vm.skip(block.number < at);
        vm.rollFork(at);
        s = new CreatePushSplit();
    }

    // promise: the script's preview creates a split at the pinned push factory with the decision 255 shares, the Core
    // owner as controller and the hash the keeper restates, and its distribute pays both recipients directly in ETH
    // and in an ERC20 (the BALANCE leg), with the Core's 50,000 gas push accepted
    function test_createsPushSplitThatPaysRecipientsDirectly() public {
        PushSplitCreator.SplitPlan memory p = s.plan();
        assertEq(p.artist, ARTIST);
        assertEq(p.operator, OWNER);
        assertEq(p.controller, OWNER);
        s.run();
        // the preview is simulation; create the same split here to inspect it
        SplitConfig memory cfg = s.splitConfig(p.artist, p.operator);
        address split = ISplitFactoryV2(s.PUSH_FACTORY()).createSplit(cfg, p.controller, address(this));
        s.acceptSplit(split, p);
        assertEq(ISplitWalletV2(split).splitHash(), s.splitHashOf(cfg));
        SplitToken token = new SplitToken();
        token.mint(split, 1_000_000);
        ISplitWalletV2(split).distribute(cfg, address(token), address(this));
        assertEq(token.balanceOf(ARTIST), uint256(999_999) * 833_333 / 1_000_000);
        assertEq(token.balanceOf(OWNER), uint256(999_999) * 166_667 / 1_000_000);
        // the split keeps 1 unit plus the rounding dust of the two shares
        assertEq(token.balanceOf(split), 1_000_000 - token.balanceOf(ARTIST) - token.balanceOf(OWNER));
    }

    // promise: the split the splits.org form created is a pull split whose distribute credits the warehouse and pays
    // the recipients nothing, so the script's push probe refuses it and it must not become the Core's artist
    function test_formSplitIsPullAndFailsTheProbe() public {
        SplitConfig memory cfg = s.splitConfig(ARTIST, OWNER);
        assertEq(ISplitWalletV2(FORM_SPLIT).splitHash(), s.splitHashOf(cfg), "same shares as the form");
        vm.expectRevert(abi.encodeWithSelector(PushSplitCreator.NotPush.selector, FORM_SPLIT));
        s.probeSplitPush(FORM_SPLIT, cfg);
    }

    receive() external payable {}
}
