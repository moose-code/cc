// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IListingAdapter} from "../../src/interfaces/IListingAdapter.sol";

/// test adapter that answers with the call it is given: `params` is `abi.encode(target, value, data)`. it prices any
/// call, so a test can aim `buyListing` at an attacker contract or a venue stand-in. it reports the target as the
/// offerer, so the Core's return lock reads the target. the Core still applies its own guards (forbidden targets, the
/// bid, the pot, one credit arrived)
contract RawListingAdapter is IListingAdapter {
    function price(uint256, bytes calldata params)
        external
        pure
        returns (address target, uint256 value, bytes memory data, address offerer)
    {
        (target, value, data) = abi.decode(params, (address, uint256, bytes));
        offerer = target;
    }
}
