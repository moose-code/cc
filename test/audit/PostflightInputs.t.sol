// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";
import {ScriptedController} from "../attackers/ScriptedController.sol";

/// @notice audit finding A02: the constructor arguments postflight prints for etherscan verification are a function of
/// the signed launch config and the deployer, never of live storage (`controller()`, `settings()`, `owner()`), which the
/// owner can change
contract PostflightInputsTest is Fixture {
    // the Core is the CREATE2 address of the config and the deployer, and stays so after the owner changed the settings,
    // the controller and the owner role
    function test_FIXED_A02_verifyInputsDoNotChangeAfterSettingsOrControllerChange() public {
        bytes memory args = coreConstructorArgs(lc, owner);
        assertEq(coreAddress(lc, owner), address(core));

        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        s.buybackSlice = 1 ether;
        _setSettings(s);
        _setController(address(new ScriptedController()));
        address next = _user("next owner");
        vm.prank(owner);
        core.transferOwnership(next);
        vm.prank(next);
        core.acceptOwnership();

        assertEq(coreConstructorArgs(lc, owner), args, "the printed constructor arguments did not change");
        assertEq(coreAddress(lc, owner), address(core));
        // the print itself runs against the changed core
        printVerifyInputs(core, lc, owner);
    }
}
