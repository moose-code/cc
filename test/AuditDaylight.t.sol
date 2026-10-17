// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";

/// a contract with code but none of the controller views, so the `setController` probe staticcall reverts
contract NoProbe {}

/// a controller stand in whose bounded bool reads answer with a dirty word (2). it answers the `setController` probe
contract DirtyBoolController {
    function nextPage() external pure returns (bool ready, uint256[80] memory ids, uint8 format) {}

    function atFloor(uint256) external pure returns (uint256) {
        return 2;
    }

    function pastWindow(uint64) external pure returns (uint256) {
        return 2;
    }
}

/// the daylight audit security findings on 8d16ffe: the balance bid does not climb without a usable module (M1), the
/// controller setter requires a probed contract and the lock refuses an unset controller (M2), and a dirty bool from the
/// controller reads as false instead of reverting (L1)
contract AuditDaylightTest is Fixture {
    function setUp() public override {
        super.setUp();
    }

    function _posted() internal view returns (uint256) {
        return 10_000 - core.settings().balanceDiscountBps;
    }

    function _enableBid() internal {
        Settings memory s = core.settings();
        s.balanceBidOn = true;
        _setSettings(s);
    }

    function _module() internal returns (MockBalanceModule m) {
        MockBalanceToken t = new MockBalanceToken("Balance Token", "XT");
        m = new MockBalanceModule(address(t), UNIT);
        t.mint(address(m), 1e24);
    }

    // promise: M1 the balance rate is the posted 10_000 - balanceDiscountBps whatever the module state and whatever time
    // passes: no climb while idle, no module read (decision 164)
    function test_balanceRateIsPostedWithoutModule() public {
        _enableBid();
        assertEq(core.balanceRate(), _posted(), "no module: the rate is the posted discount");
        _warp(30 minutes);
        assertEq(core.balanceRate(), _posted(), "no module: the posted rate did not climb");
        _setBalanceModule(address(_module()));
        assertEq(core.balanceRate(), _posted(), "a module set leaves the posted rate unchanged");
    }

    // promise: M1 the posted balance rate is unchanged by a failing unit read: it never reads the module or the instance
    function test_balanceRatePostedThroughUnitFailure() public {
        MockBalanceModule m = _module();
        _setBalanceModule(address(m));
        _enableBid();
        assertEq(core.balanceRate(), _posted(), "a fresh module: the rate is the posted discount");
        m.setRevertUnit(true);
        assertEq(core.balanceRate(), _posted(), "failed unit read: the posted rate is unchanged");
        _warp(30 minutes);
        assertEq(core.balanceRate(), _posted(), "failed unit read: the posted rate did not climb");
        _setSettings(core.settings());
        m.setRevertUnit(false);
        assertEq(core.balanceRate(), _posted(), "after the unit read recovers the posted rate is unchanged");
    }

    // promise: M2 setController refuses an EOA
    function test_setControllerRejectsEoa() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, address(0xE0A)));
        core.setController(address(0xE0A));
    }

    // promise: M2 setController refuses a contract that does not answer the nextPage probe
    function test_setControllerRejectsContractWithoutProbe() public {
        address np = address(new NoProbe());
        vm.prank(owner);
        vm.expectRevert(ICore.BadController.selector);
        core.setController(np);
    }

    // promise: M2 lockController reverts while no controller is set
    function test_lockControllerRevertsWithoutController() public {
        ICore bare = _launchCore(address(0), lc.stack, OPEN_RATE, _settings());
        assertEq(bare.controller(), address(0), "the bare core has no controller");
        vm.prank(owner);
        vm.expectRevert(ICore.BadController.selector);
        bare.lockController();
    }

    // promise: L1 a controller bool read that answers with a word outside {0, 1} reads as false instead of reverting the
    // abi.decode, so redemption eligibility falls back to not eligible
    function test_dirtyBoolControllerReadsFalse() public {
        MockBalanceModule m = _module();
        _setBalanceModule(address(m));
        Settings memory s = core.settings();
        s.redeemOn = true;
        _setSettings(s);
        uint256 sid = _composeOnce().sid;
        _setController(address(new DirtyBoolController()));
        vm.expectRevert(ICore.NotEligible.selector);
        core.redeemStatement(sid);
    }
}
