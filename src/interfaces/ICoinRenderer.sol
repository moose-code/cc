// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "./ICore.sol";

/// @notice the coin's metadata renderer. `contractURI(token)` is the one view the artcoins coin calls on its renderer,
/// from both `tokenURI()` and `contractURI()`
interface ICoinRenderer {
    error NotOwner();
    error CoreSet();
    error ZeroCore();

    event CoreBound(address indexed core);

    function owner() external view returns (address);
    function core() external view returns (ICore);
    /// @notice binds the Core once. only `owner`. a second call reverts `CoreSet`
    function setCore(ICore core_) external;
    function contractURI(address token) external view returns (string memory);
    function image() external view returns (string memory);
}
