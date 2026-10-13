// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IListingAdapter} from "../../src/interfaces/IListingAdapter.sol";

/// test adapter whose `price` fails in the way selected by `mode`: 0 reverts, 1 answers with one word, 2 answers with
/// 10,000 bytes of data, 3 burns all its gas, 4 writes storage, 5 answers with a forbidden target (`target`)
contract FaultyAdapter is IListingAdapter {
    uint256 public mode;
    address public target;
    uint256 public sink;

    function setMode(uint256 m, address target_) external {
        mode = m;
        target = target_;
    }

    function price(uint256, bytes calldata) external view returns (address, uint256, bytes memory) {
        uint256 m = mode;
        if (m == 0) revert("faulty");
        if (m == 1) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (m == 2) return (address(0xBEEF), 1, new bytes(10_000));
        if (m == 3) {
            while (true) {}
        }
        if (m == 4) {
            // a state change under a static call reverts
            (bool ok,) = address(this).staticcall(abi.encodeCall(this.write, ()));
            require(ok, "static write");
        }
        return (target, 1, "");
    }

    function write() external {
        sink = 1;
    }
}
