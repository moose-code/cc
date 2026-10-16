// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// minimal erc721 surface for `rescueNft` tests: `ownerOf` reports a fixed holder other than the caller.
contract MockNft {
    function ownerOf(uint256) external pure returns (address) {
        return address(0xdead);
    }
}
