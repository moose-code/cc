// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// a controller whose `priceOf` fails, to exercise the bounded read in the core's compose path. `pastWindow` returns
/// true so a chosen compose reaches the price read. `burns` true runs an unbounded loop that exceeds the core's read
/// gas cap, `burns` false reverts. either way the core reads the price as 0 and composes.
contract BadPriceController {
    error NoPrice();

    bool public immutable burns;

    constructor(bool burns_) {
        burns = burns_;
    }

    function pastWindow(uint64) external pure returns (bool) {
        return true;
    }

    function priceOf(uint256) external view returns (uint256 p) {
        if (burns) {
            for (uint256 i; i < 10_000_000; ++i) {
                p = p + i;
            }
            return p;
        }
        revert NoPrice();
    }
}
