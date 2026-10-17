// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ICoinRenderer} from "./interfaces/ICoinRenderer.sol";
import {IArtCoinsTokenV2} from "./interfaces/ArtCoinsV2.sol";

/// @notice the coin's metadata renderer. a fork of CoinRenderer whose image is the fixed animated CC logo, not the
///         pile. the three CMY squares step clockwise round a four-corner track, one step every 1.6s, over a 6.4s loop.
/// @dev    same ICoinRenderer surface as CoinRenderer: the launch names this contract in the token config, the
///         constructor takes `owner` to keep the CREATE2 address Core independent, and `setCore` binds the Core once.
///         the image reads no chain state, so `core` is bound only to satisfy the renderer surface. `contractURI`
///         reads name, symbol and description from the token.
contract LogoCoinRenderer is ICoinRenderer {
    address public immutable owner;
    ICore public core;

    /// the animated CC logo. three 58 unit CMY squares, slots TL(6,6) TR(36,6) BR(36,36) BL(6,36); the square bbox
    /// runs 6 to 94. the viewBox is -38 -38 176 176 so the bbox leaves a 44 unit margin on every side, 25 percent of
    /// the box, matching the credit artwork's 80 of 320 inset. square i rests in slot (i + step) % 4; step advances
    /// every 1.6s with a 0.7s cubic-bezier(.6,0,.3,1) move and holds between. values and splines run move then hold
    /// per step so the 6.4s loop returns to the rest frame. multiply blend darkens the overlaps on the white ground.
    string private constant IMAGE =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-38 -38 176 176"><rect x="-38" y="-38" width="176" height="176" fill="#ffffff"/>'
        '<rect width="58" height="58" fill="#00a3e0" style="mix-blend-mode:multiply">'
        '<animate attributeName="x" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="6;6;36;36;36;36;6;6;6"/>'
        '<animate attributeName="y" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="6;6;6;6;36;36;36;36;6"/></rect>'
        '<rect width="58" height="58" fill="#e5007e" style="mix-blend-mode:multiply">'
        '<animate attributeName="x" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="36;36;36;36;6;6;6;6;36"/>'
        '<animate attributeName="y" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="6;6;36;36;36;36;6;6;6"/></rect>'
        '<rect width="58" height="58" fill="#ffd400" style="mix-blend-mode:multiply">'
        '<animate attributeName="x" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="36;36;6;6;6;6;36;36;36"/>'
        '<animate attributeName="y" dur="6.4s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.140625;0.25;0.390625;0.5;0.640625;0.75;0.890625;1" keySplines="0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1;0 0 1 1;0.6 0 0.3 1" values="36;36;36;36;6;6;6;6;36"/></rect></svg>';

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
            Base64.encode(bytes(IMAGE)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// the animated CC logo, the fixed image for every coin this renderer serves
    function image() public pure returns (string memory) {
        return IMAGE;
    }
}
