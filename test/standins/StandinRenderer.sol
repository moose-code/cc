// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";

interface IStandinToken {
    function name() external view returns (string memory);
}

/// implements `contractURI(address token)`, the one view the v2 art coin calls from `tokenURI()` and `contractURI()`.
/// mode 0 returns a json data uri that holds the token name, mode 1 reverts, mode 2 returns an empty string
contract StandinRenderer {
    uint8 public immutable mode;

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function contractURI(address token) external view returns (string memory) {
        if (mode == 1) revert("renderer down");
        if (mode == 2) return "";
        return string.concat(
            "data:application/json;base64,", Base64.encode(bytes(string.concat('{"name":"', IStandinToken(token).name(), '"}')))
        );
    }
}
