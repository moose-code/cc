// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";

/// the v2 hook pays the bounty of the pool fee to the Core: these attackers swap in the real pool in the middle of a Core
/// call, so the hook pushes eth into `receive()` during the call. the Core books that eth at its next door
/// a listing target that swaps in the real pool in the middle of the core's `buyListing` call, so the skim hook pushes
/// eth into the core's `receive()` during the call. it then delivers its credit
contract SwapMidListing {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);

    TestSwapRouter public immutable router;
    address public immutable core;
    PoolKey internal key;
    uint256 public creditId;
    uint256 public swapEth;

    constructor(TestSwapRouter router_, address core_, PoolKey memory key_) {
        router = router_;
        core = core_;
        key = key_;
    }

    function arm(uint256 creditId_, uint256 swapEth_) external {
        creditId = creditId_;
        swapEth = swapEth_;
    }

    fallback() external payable {
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        CREDITS.transferFrom(address(this), core, creditId);
    }

    receive() external payable {}
}

interface IBuy {
    function grossPriceOf(uint256 sid) external view returns (uint256);
    function buy(uint256 sid) external payable;
}

/// one transaction that swaps in the real pool (the skim hook pushes into the core's `receive`), buys statement `sid`
/// through the controller, and swaps again, so the hook pushes into `receive` before and after the sale is booked
contract SwapAroundBuy {
    TestSwapRouter public immutable router;
    IBuy public immutable ctl;
    PoolKey internal key;

    constructor(TestSwapRouter router_, address ctl_, PoolKey memory key_) {
        router = router_;
        ctl = IBuy(ctl_);
        key = key_;
    }

    function run(uint256 swapEth, uint256 sid) external payable {
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        ctl.buy{value: ctl.grossPriceOf(sid)}(sid);
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
