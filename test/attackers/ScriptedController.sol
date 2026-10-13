// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IController} from "../../src/interfaces/Interfaces.sol";

/// settable controller for unit tests. it can also revert `nextPage`.
contract ScriptedController is IController {
    bool public pageReady;
    uint256[80] internal _pageIds;
    uint8 public pageFormat;
    bool public revertPage;
    /// the eligibility answer the core reads for a phase 2 redemption
    bool public atCostFlag;
    /// the answer of `valueWei`, and whether the call reverts (an unset pool key)
    uint256 public valueWeiAnswer;
    bool public valueWeiReverts = true;

    /// sets the eligibility answer.
    function setAtCost(bool on) external {
        atCostFlag = on;
    }

    function atCost(uint256) external view returns (bool) {
        return atCostFlag;
    }

    /// sets the exit token value answer and clears the revert flag.
    function setValueWei(uint256 v) external {
        valueWeiAnswer = v;
        valueWeiReverts = false;
    }

    /// makes `valueWei` revert, as an unset pool key does.
    function setValueWeiReverts(bool on) external {
        valueWeiReverts = on;
    }

    function valueWei(uint256) external view returns (uint256) {
        if (valueWeiReverts) revert NoExitPrice();
        return valueWeiAnswer;
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

    error NoExitPrice();
}
