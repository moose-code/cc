// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Sale} from "../src/interfaces/Interfaces.sol";

/// decision 124: the sale floor can never be above the sale start. setSettings bounds `saleFloorBps` at or below the
/// controller's `markupBps`; setSale refuses a `markupBps` below the core's `saleFloorBps`
contract SaleFloorStartTest is LiveFixture {
    function setUp() public override {
        super.setUp();
    }

    // promise: decision 124 setSettings refuses a saleFloorBps above the controller's markupBps
    function test_setSettingsRefusesFloorAboveStart() public {
        if (_liveStageB()) return; // stage B: markupBps and setSale are a ControllerV1-only surface
        Settings memory s = core.settings();
        s.saleFloorBps = uint16(uint256(ctl.markupBps()) + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("saleFloorBps")));
        core.setSettings(s);
    }

    // promise: decision 124 setSale refuses a markupBps below the core's saleFloorBps
    function test_setSaleRefusesStartBelowFloor() public {
        if (_liveStageB()) return; // stage B: setSale is a ControllerV1-only surface, dropped on ControllerV2
        // raise the start, then the floor to it, both legal
        Sale memory sale = _sale();
        sale.markupBps = 20_000;
        vm.prank(owner);
        ctl.setSale(sale);
        Settings memory s = core.settings();
        s.saleFloorBps = 18_000;
        _setSettings(s);
        // a start below the floor is refused
        sale.markupBps = 15_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("markupBps")));
        ctl.setSale(sale);
    }
}
