// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// the slice of Seaport 1.6 that `SeaportBasicAdapter` reads and encodes. field order and names follow the deployed
/// contract, which fixes the selector and the abi encoding.

/// basic order routes from native eth to an ERC721. the restricted routes call the order's zone.
enum BasicOrderType {
    ETH_TO_ERC721_FULL_OPEN,
    ETH_TO_ERC721_PARTIAL_OPEN,
    ETH_TO_ERC721_FULL_RESTRICTED,
    ETH_TO_ERC721_PARTIAL_RESTRICTED
}

struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

struct BasicOrderParameters {
    address considerationToken;
    uint256 considerationIdentifier;
    uint256 considerationAmount;
    address payable offerer;
    address zone;
    address offerToken;
    uint256 offerIdentifier;
    uint256 offerAmount;
    BasicOrderType basicOrderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 offererConduitKey;
    bytes32 fulfillerConduitKey;
    uint256 totalOriginalAdditionalRecipients;
    AdditionalRecipient[] additionalRecipients;
    bytes signature;
}

interface ISeaport {
    function fulfillBasicOrder_efficient_6GL6yc(BasicOrderParameters calldata parameters)
        external
        payable
        returns (bool fulfilled);
}
