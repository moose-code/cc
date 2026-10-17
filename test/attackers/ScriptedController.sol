// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IController} from "../../src/interfaces/Interfaces.sol";

/// settable controller for unit tests. it can also revert `nextPage`.
contract ScriptedController is IController {
    bool public pageReady;
    uint256[80] internal _pageIds;
    uint8 public pageFormat;
    bool public revertPage;
    /// the eligibility answer the core reads for the balance side redemption
    bool public atFloorFlag;
    /// the window answer the core reads for a chosen compose, and whether the call reverts
    bool public pastWindowFlag = true;
    bool public pastWindowReverts;

    /// sets the eligibility answer.
    function setAtFloor(bool on) external {
        atFloorFlag = on;
    }

    function atFloor(uint256) external view returns (bool) {
        return atFloorFlag;
    }

    /// sets the window answer.
    function setPastWindow(bool on) external {
        pastWindowFlag = on;
    }

    /// makes `pastWindow` revert.
    function setPastWindowReverts(bool on) external {
        pastWindowReverts = on;
    }

    function pastWindow(uint64) external view returns (bool) {
        if (pastWindowReverts) revert();
        return pastWindowFlag;
    }

    /// the asking price answer, and whether the call reverts
    uint256 public price;
    bool public priceReverts;

    function setPrice(uint256 p, bool reverts) external {
        price = p;
        priceReverts = reverts;
    }

    function priceOf(uint256) external view returns (uint256) {
        if (priceReverts) revert();
        return price;
    }

    /// no quote: a scripted controller is outside value mode, so the Core never prices off it
    function valuePerPoint(bool) external pure returns (uint256, bool) {
        return (0, false);
    }

    /// no reference to refresh
    function refreshReference() external pure returns (bool) {
        return false;
    }

    /// sets the page answer.
    function setPage(bool ready, uint256[80] calldata ids, uint8 format) external {
        pageReady = ready;
        _pageIds = ids;
        pageFormat = format;
    }

    /// makes nextPage revert.
    function setRevertPage(bool on) external {
        revertPage = on;
    }

    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (revertPage) revert();
        return (pageReady, _pageIds, pageFormat);
    }
}
