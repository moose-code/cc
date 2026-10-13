// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IListingAdapter} from "../interfaces/IListingAdapter.sol";
import {ICreditStrategy, Mainnet} from "../interfaces/Interfaces.sol";

/// prices a credit that the CreditStrategy sells. the price is the strategy's `nftForSale(id)` and the call is
/// `sellTargetNFT(id)`. read only.
contract CreditStrategyAdapter is IListingAdapter {
    /// `nftForSale(id)` is 0
    error NotForSale();

    address public constant STRATEGY = Mainnet.CREDIT_STRATEGY;

    /// `params` is ignored
    function price(uint256 id, bytes calldata)
        external
        view
        returns (address target, uint256 value, bytes memory data)
    {
        value = ICreditStrategy(STRATEGY).nftForSale(id);
        if (value == 0) revert NotForSale();
        return (STRATEGY, value, abi.encodeCall(ICreditStrategy.sellTargetNFT, (id)));
    }
}
