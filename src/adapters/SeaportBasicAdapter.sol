// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IListingAdapter} from "../interfaces/IListingAdapter.sol";
import {Mainnet} from "../interfaces/Interfaces.sol";
import {BasicOrderParameters, BasicOrderType, ISeaport} from "../interfaces/ISeaport.sol";

interface ICoreOwner {
    function owner() external view returns (address);
    function adaptersLocked() external view returns (bool);
}

/// prices a Seaport 1.6 basic order (`fulfillBasicOrder_efficient_6GL6yc`) that sells one credit for native eth.
/// `params` is `abi.encode(BasicOrderParameters)`. the order must be an open route (`ETH_TO_ERC721_FULL_OPEN` or
/// `ETH_TO_ERC721_PARTIAL_OPEN`), which ignore the order's zone. the eth goes to the order's offerer and to the additional
/// recipients, each of which is the offerer or an allowlisted address. `value` is the sum of every payout. the allowlist is set at
/// construction and by the owner of the Core. read only.
contract SeaportBasicAdapter is IListingAdapter {
    error WrongToken();
    error WrongId();
    error WrongAmount();
    error NotNative();
    error ZeroPrice();
    error RestrictedOrder();
    error RecipientNotAllowed(address recipient);
    error OnlyCoreOwner();
    error Locked();

    event RecipientSet(address indexed recipient, bool allowed);

    address public constant SEAPORT = Mainnet.SEAPORT;
    address public constant CREDITS = Mainnet.CREDITS;
    /// the Core whose owner manages the allowlist
    address public immutable CORE;

    mapping(address => bool) public allowedRecipient;

    constructor(address core, address[] memory recipients) {
        CORE = core;
        for (uint256 i; i < recipients.length; ++i) {
            allowedRecipient[recipients[i]] = true;
            emit RecipientSet(recipients[i], true);
        }
    }

    /// allows or removes a recipient of additional payouts. owner of the Core only. once the Core's adapters are locked,
    /// adding a recipient reverts and removing stays allowed
    function setAllowedRecipient(address recipient, bool allowed) external {
        if (msg.sender != ICoreOwner(CORE).owner()) revert OnlyCoreOwner();
        if (allowed && ICoreOwner(CORE).adaptersLocked()) revert Locked();
        allowedRecipient[recipient] = allowed;
        emit RecipientSet(recipient, allowed);
    }

    function price(uint256 id, bytes calldata params)
        external
        view
        returns (address target, uint256 value, bytes memory data)
    {
        BasicOrderParameters memory p = abi.decode(params, (BasicOrderParameters));
        if (p.offerToken != CREDITS) revert WrongToken();
        if (p.offerIdentifier != id) revert WrongId();
        if (p.offerAmount != 1) revert WrongAmount();
        if (p.considerationToken != address(0)) revert NotNative();
        if (p.considerationAmount == 0) revert ZeroPrice();
        if (p.basicOrderType > BasicOrderType.ETH_TO_ERC721_PARTIAL_OPEN) revert RestrictedOrder();
        value = p.considerationAmount;
        for (uint256 i; i < p.additionalRecipients.length; ++i) {
            address recipient = p.additionalRecipients[i].recipient;
            if (recipient != p.offerer && !allowedRecipient[recipient]) revert RecipientNotAllowed(recipient);
            value += p.additionalRecipients[i].amount;
        }
        return (SEAPORT, value, abi.encodeCall(ISeaport.fulfillBasicOrder_efficient_6GL6yc, (p)));
    }
}
