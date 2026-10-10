// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Lane, IController} from "../../src/interfaces/Interfaces.sol";

/// settable controller for unit tests. it can also revert, burn gas or answer with a short word.
contract ScriptedController is IController {
    mapping(Lane => bool) public pageReady;
    mapping(Lane => uint256[80]) internal _pageIds;
    mapping(Lane => uint8) public pageFormat;
    bool public revertPage;

    /// the asking price in bps of cost the controller answers with, and how it can misbehave
    uint256 public priceBps = 11_000;
    bool public revertPrice;
    bool public burnPrice;
    bool public shortPrice;

    /// sets the page answer for a lane.
    function setPage(Lane lane, bool ready, uint256[80] calldata ids, uint8 format) external {
        pageReady[lane] = ready;
        _pageIds[lane] = ids;
        pageFormat[lane] = format;
    }

    /// makes nextPage revert.
    function setRevertPage(bool on) external {
        revertPage = on;
    }

    /// sets the answer of `statementPrice`, in bps of the cost.
    function setPriceBps(uint256 bps) external {
        priceBps = bps;
    }

    /// makes statementPrice revert.
    function setRevertPrice(bool on) external {
        revertPrice = on;
    }

    /// makes statementPrice spin until it runs out of gas.
    function setBurnPrice(bool on) external {
        burnPrice = on;
    }

    /// makes statementPrice answer with fewer than 32 bytes.
    function setShortPrice(bool on) external {
        shortPrice = on;
    }

    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (revertPage) revert();
        return (pageReady[lane], _pageIds[lane], pageFormat[lane]);
    }

    function statementPrice(uint256, uint256 cost, uint64) external view returns (uint256) {
        if (revertPrice) revert();
        if (burnPrice) {
            uint256 i;
            while (true) {
                ++i;
            }
        }
        if (shortPrice) {
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
        return cost * priceBps / 10_000;
    }
}
