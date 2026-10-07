// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Lane, Settings} from "../../src/interfaces/Interfaces.sol";

contract FloorRaiseRaceAudit is Fixture {
    function test_FINDING_A01_repriceSnapshotMissesAStatementComposedBeforeTheFloorRaise() public {
        _fillEthPile(80);

        // SetSettings gathers these ids before it broadcasts the settings change.
        uint256[] memory toReprice = core.heldStatements();
        assertEq(toReprice.length, 0);
        assertEq(core.pileSize(Lane.Eth), 80);

        // Anyone can create a listing after the read, including before an atomic owner batch.
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        Live memory listing = _live(sid);
        (,, uint256 cost,) = core.statementInfo(sid);
        assertEq(listing.reserve, cost * 11_000 / 10_000);

        Settings memory raised = core.settings();
        raised.saleFloorBps = 20_000;
        _setSettings(raised);
        for (uint256 i; i < toReprice.length; ++i) {
            core.repriceStatement(toReprice[i]);
        }
        assertLt(listing.reserve, cost * raised.saleFloorBps / 10_000);

        // The real house still accepts the old reserve, then delivers the statement.
        _bid(seller, sid, listing.reserve);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), seller);
        assertEq(_collectSales(), listing.reserve);
    }
}
