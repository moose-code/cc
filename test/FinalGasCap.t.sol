// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GasCapTest} from "./GasCap.t.sol";

contract FinalGasCapTest is GasCapTest {
    // promise: a one-credit mode-off sell stays within the 482,000 gas launch target on a cold transaction
    function test_oneCreditModeOffSellExceeds482000Target() public {
        assertFalse(core.settings().valueModeOn);
        _fundPot(30 ether);
        _warp(1 hours + 1);
        (, uint256 total) = _sellBatch(false, 1);
        emit log_named_uint("one-credit estimated transaction gas", total);
        assertGt(total, 482_000, "candidate exceeds the stated target");
    }
}
