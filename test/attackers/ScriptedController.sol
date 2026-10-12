// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Lane, IController} from "../../src/interfaces/Interfaces.sol";

/// settable controller for unit tests. it can also revert `nextPage`.
contract ScriptedController is IController {
    mapping(Lane => bool) public pageReady;
    mapping(Lane => uint256[80]) internal _pageIds;
    mapping(Lane => uint8) public pageFormat;
    bool public revertPage;
    /// the eligibility answer the core reads for a phase 2 redemption of an eth lane statement
    bool public atCostFlag;

    /// sets the eligibility answer.
    function setAtCost(bool on) external {
        atCostFlag = on;
    }

    function atCost(uint256) external view returns (bool) {
        return atCostFlag;
    }

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

    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (revertPage) revert();
        return (pageReady[lane], _pageIds[lane], pageFormat[lane]);
    }
}
