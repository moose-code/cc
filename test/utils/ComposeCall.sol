// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// the `compose()` member of the Core's overloaded `compose`, so a call builds its calldata from a typed selector
interface IComposeNoArgs {
    function compose() external;
}

library ComposeCall {
    /// calldata for `compose()`
    function noArgs() internal pure returns (bytes memory) {
        return abi.encodeCall(IComposeNoArgs.compose, ());
    }
}
