// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ICoinRenderer} from "./interfaces/ICoinRenderer.sol";
import {IArtCoinsTokenV2} from "./interfaces/ArtCoinsV2.sol";

/// the Balances artwork the BALANCE token creates: one wallet bound NFT per wallet that has received BALANCE, its
/// image the wallet's current BALANCE amount drawn in its CMYK ink. no administrator; the drawing code is immutable
interface IBalancesArtwork {
    /// zero for a wallet that has never received BALANCE
    function tokenIdOf(address wallet) external view returns (uint256);
    function svg(uint256 id) external view returns (string memory);
}

/// @notice the coin's metadata renderer for an owner swap after the LogoCoinRenderer launch: the image is the Balances
///         artwork held by the Core's balance module, the treasury's live BALANCE drawing.
/// @dev    the holder is read through `core.balanceModule()` on every call, so a treasury migration moves the image to
///         the successor's artwork. a module with no artwork (zero, or a successor that has not yet received BALANCE)
///         draws the launch LogoCoinRenderer's logo instead of reverting, so the coin's `tokenURI` never fails on it.
///         the constructor owner keeps the CREATE2 address independent of the Core; `setCore` binds the Core once.
///         the artwork's `svg` costs about 2,000,000 gas.
contract CoinRenderer is ICoinRenderer {
    IBalancesArtwork private constant ARTWORK = IBalancesArtwork(0x3F2BA6C00c386986686A429c52099AaCD51b7e38);
    /// the live LogoCoinRenderer; its `image()` is pure
    ICoinRenderer private constant LOGO = ICoinRenderer(0x0D2022F8D780884A1B46de156CBfc4f36423504c);

    address public immutable owner;
    ICore public core;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @inheritdoc ICoinRenderer
    function setCore(ICore core_) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(core) != address(0)) revert CoreSet();
        if (address(core_) == address(0)) revert ZeroCore();
        core = core_;
        emit CoreBound(address(core_));
    }

    /// the coin's metadata as a data URI: name, symbol and description read from `token`, the image `image()`
    function contractURI(address token) external view returns (string memory) {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        string memory json = string.concat(
            '{"name":',
            LibString.escapeJSON(t.name(), true),
            ',"symbol":',
            LibString.escapeJSON(t.symbol(), true),
            ',"description":',
            LibString.escapeJSON(t.description(), true),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image())),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// the balance module's Balances artwork, or the CC logo when the module holds none
    function image() public view returns (string memory) {
        if (address(core) == address(0)) revert ZeroCore();
        uint256 id = ARTWORK.tokenIdOf(core.balanceModule());
        return id == 0 ? LOGO.image() : ARTWORK.svg(id);
    }
}
