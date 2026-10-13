// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// prices one listing of a credit for `Core.buyListing`. an adapter reads the venue's own data and returns the one call
/// the Core makes. the Core approves adapters one by one (`addAdapter`).
interface IListingAdapter {
    /// @notice prices one listing of credit `id` from the venue's own data. reverts when the listing is not a plain
    /// sale of exactly credit `id` for native eth to the seller and allowlisted fee recipients.
    /// @param id the credit
    /// @param params the venue specific listing data
    /// @return target the contract the Core calls
    /// @return value the exact eth the Core sends with the call
    /// @return data the calldata of the call
    function price(uint256 id, bytes calldata params)
        external
        view
        returns (address target, uint256 value, bytes memory data);
}
