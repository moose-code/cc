// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";

/// the v2 hook pays the pool fee to the fee router, not to the core: these attackers flush the router right after each
/// swap, which is the call that lands the eth in the core's `receive()`. `flushes` counts the tries, `flushFailed` the
/// ones that reverted
abstract contract Flushes {
    IFeeRouter public feeRouter;
    uint256 public flushes;
    uint256 public flushFailed;

    function setFeeRouter(address r) external {
        feeRouter = IFeeRouter(payable(r));
    }

    function _flush() internal {
        if (address(feeRouter) == address(0)) return;
        ++flushes;
        try feeRouter.flush() {} catch {
            ++flushFailed;
        }
    }
}

/// a listing target that swaps in the real pool in the middle of the core's `buyListing` call, so the skim hook pushes
/// eth into the core's `receive()` during the call. it then delivers its credit
contract SwapMidListing is Flushes {
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
        _flush();
        CREDITS.transferFrom(address(this), core, creditId);
    }

    receive() external payable {}
}

interface IBuy {
    function priceOf(uint256 sid) external view returns (uint256);
    function buy(uint256 sid) external payable;
}

/// one transaction that swaps in the real pool (the skim hook pushes into the core's `receive`), buys statement `sid`
/// through the controller, and swaps again, so the hook pushes into `receive` before and after the sale is booked
contract SwapAroundBuy is Flushes {
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
        _flush();
        ctl.buy{value: ctl.priceOf(sid)}(sid);
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        _flush();
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
