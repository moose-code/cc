// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";

contract PostflightInputsAudit is Fixture {
    function test_FINDING_A02_postflightVerificationArgsChangeAfterSettingsChange() public {
        bytes32 deployedArgs = keccak256(coreConstructorArgs(core, lc.owner));
        Settings memory changed = core.settings();
        changed.saleFloorBps = 8_000;
        _setSettings(changed);

        // Constructor arguments are fixed, but Postflight prints settings read from live storage.
        bytes32 printedLater = keccak256(coreConstructorArgs(core, lc.owner));
        assertNotEq(printedLater, deployedArgs);
        assertEq(
            printedLater, keccak256(abi.encode(lc.owner, address(coin), address(ctl), lc.stack, lc.rateStart, changed))
        );
    }
}
