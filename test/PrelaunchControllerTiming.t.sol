// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Postflight} from "../script/Postflight.s.sol";
import {PostflightChecks} from "../script/PostflightChecks.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Sale, Credit, CreditSale, Quote} from "../src/interfaces/Interfaces.sol";

contract ControllerTimingProbe is Postflight {
    function config() external pure returns (LaunchConfig memory) {
        return defaultConfig();
    }

    function hashConfig(LaunchConfig memory c) external pure returns (bytes32) {
        return configHash(c);
    }

    function timing(LaunchConfig memory c) external view returns (uint256, uint256) {
        return _approvedControllerTiming(c);
    }

    function timingHash(LaunchConfig memory c, uint256 decay, uint256 window) external pure returns (bytes32) {
        return _controllerTimingHash(c, decay, window);
    }

    function identity(LaunchConfig memory c, address deployer) external returns (bytes32, address, address, bytes32) {
        address core = coreAddress(c, deployer);
        return (configHash(c), core, controllerAddress(core, c), keccak256(coreConstructorArgs(c, deployer)));
    }

    function checkedTiming(LaunchConfig memory c, address deployer) external returns (uint256 decay, uint256 window) {
        bytes32 hash = configHash(c);
        bytes32 args = keccak256(coreConstructorArgs(c, deployer));
        address core = coreAddress(c, deployer);
        address controller = controllerAddress(core, c);
        (decay, window) = _approvedControllerTiming(c);
        require(
            configHash(c) == hash && keccak256(coreConstructorArgs(c, deployer)) == args, "constructor config mutated"
        );
        require(coreAddress(c, deployer) == core && controllerAddress(core, c) == controller, "derived address mutated");
    }

    function recover(LaunchConfig memory c, address core, string memory j) external {
        _decodeApprovedRateRecord(c, core, j);
        _useApprovedControllerTimingRecord(c, j);
    }

    function decode(LaunchConfig memory c, address core, string memory j)
        external
        view
        returns (bool, uint256, uint256, bytes32)
    {
        _decodeApprovedRateRecord(c, core, j);
        return _decodeApprovedControllerTimingRecord(c, j);
    }

    function fragment(LaunchConfig memory c) external view returns (string memory) {
        return _controllerTimingRecord(c);
    }

    function sale(LaunchConfig memory c, address controller) external returns (string memory, uint256) {
        _reset();
        _postSale(c, controller);
        return _failed();
    }
}

/// Local guard checks use the real compiled Controller ABI without a fork or a launch lifecycle.
contract PrelaunchControllerTimingTest is Test {
    ControllerTimingProbe internal probe;
    LaunchConfig internal c;
    address internal constant CORE = address(0xBEEF);

    function setUp() public {
        probe = new ControllerTimingProbe();
        c = probe.config();
        _clear();
        vm.setEnv("SETTINGS_CHANGED", "0");
    }
    modifier cleanTimingEnv() {
        _clear();
        _;
        _clear();
    }

    // promise: all timing guard cases are isolated from process-wide environment changes and run without a fork.
    function test_controllerTimingGuardCases() public {
        _case_defaultAndLegacyRecord();
        _case_approvedTimingPreservesConstructorIdentity();
        _case_rejectPartialEnvironmentTuples();
        _case_hashAndBoundsRejectZeroCreditWindow();
        _case_recordRecoveryAndIdentity();
        _case_recordPartialHashBoundsAndEnvironmentConflict();
        _case_onlyTwoControllerFieldsMayDiffer();
    }

    function _clear() internal {
        vm.setEnv("PRELAUNCH_DECAY_HOURS", "");
        vm.setEnv("PRELAUNCH_CREDIT_WINDOW", "");
        vm.setEnv("PRELAUNCH_CONTROLLER_TIMING_HASH", "");
    }

    function _approve(uint256 decay, uint256 window) internal {
        vm.setEnv("PRELAUNCH_DECAY_HOURS", vm.toString(decay));
        vm.setEnv("PRELAUNCH_CREDIT_WINDOW", vm.toString(window));
        vm.setEnv("PRELAUNCH_CONTROLLER_TIMING_HASH", vm.toString(probe.timingHash(c, decay, window)));
    }

    function _record(string memory fields) internal view returns (string memory) {
        return string.concat(
            '{"core":"',
            vm.toString(CORE),
            '","chainId":',
            vm.toString(block.chainid),
            ',"configHash":"',
            vm.toString(probe.hashConfig(c)),
            '","openingRate":"',
            vm.toString(c.rateStart),
            '","openingRateHash":"',
            vm.toString(bytes32(0)),
            '"',
            fields,
            "}"
        );
    }

    function _fields(uint256 decay, uint256 window, bytes32 hash) internal pure returns (string memory) {
        return string.concat(
            ',"controllerDecayHours":"',
            vm.toString(decay),
            '","controllerCreditWindow":"',
            vm.toString(window),
            '","controllerTimingHash":"',
            vm.toString(hash),
            '"'
        );
    }

    function _controller() internal returns (IControllerV1 ctl) {
        Sale memory sale = abi.decode(abi.encode(c.sale), (Sale));
        Credit memory credit = abi.decode(abi.encode(c.credit), (Credit));
        sale.decayHours = 1;
        credit.window = 3600;
        ctl = IControllerV1(vm.deployCode("ControllerV1.sol:ControllerV1", abi.encode(CORE, sale, credit, c.quote)));
        vm.mockCall(CORE, abi.encodeWithSignature("owner()"), abi.encode(address(this)));
        vm.mockCall(CORE, abi.encodeWithSignature("settings()"), abi.encode(c.settings));
    }

    function _assertPass(IControllerV1 ctl) internal {
        (string memory failed, uint256 count) = probe.sale(c, address(ctl));
        assertEq(count, 0, failed);
    }

    function _assertFail(IControllerV1 ctl, string memory row) internal {
        (string memory failed, uint256 count) = probe.sale(c, address(ctl));
        assertGt(count, 0);
        assertTrue(vm.contains(failed, row), failed);
    }

    // promise: no timing approval preserves constructor expectations and old record output exactly.
    function _case_defaultAndLegacyRecord() internal cleanTimingEnv {
        (uint256 decay, uint256 window) = probe.timing(c);
        assertEq(decay, 4);
        assertEq(window, 14400);
        assertEq(probe.fragment(c), "");
        (bool present,,,) = probe.decode(c, CORE, _record(""));
        assertFalse(present);
        probe.recover(c, CORE, _record(""));
        (decay, window) = probe.timing(c);
        assertEq(decay, 4);
        assertEq(window, 14400);
    }

    // promise: the separately signed live timings never mutate the original config, constructor arguments or addresses.
    function _case_approvedTimingPreservesConstructorIdentity() internal cleanTimingEnv {
        (bytes32 hash, address core, address controller, bytes32 args) = probe.identity(c, address(123));
        _approve(1, 3600);
        (uint256 decay, uint256 window) = probe.checkedTiming(c, address(123));
        assertEq(decay, 1);
        assertEq(window, 3600);
        assertEq(
            probe.timingHash(c, 1, 3600),
            keccak256(abi.encode(keccak256("credits.prelaunchControllerTiming.v1"), hash, uint256(1), uint256(3600)))
        );
        (bytes32 afterHash, address afterCore, address afterController, bytes32 afterArgs) =
            probe.identity(c, address(123));
        assertEq(afterHash, hash);
        assertEq(afterCore, core);
        assertEq(afterController, controller);
        assertEq(afterArgs, args);
        assertEq(c.sale.decayHours, 4);
        assertEq(c.credit.window, 14400);
    }

    // promise: every partial environment tuple is rejected, including a hash with neither timing value.
    function _case_rejectPartialEnvironmentTuples() internal cleanTimingEnv {
        for (uint256 mask = 1; mask < 7; ++mask) {
            _clear();
            if (mask & 1 != 0) vm.setEnv("PRELAUNCH_DECAY_HOURS", "1");
            if (mask & 2 != 0) vm.setEnv("PRELAUNCH_CREDIT_WINDOW", "3600");
            if (mask & 4 != 0) {
                vm.setEnv("PRELAUNCH_CONTROLLER_TIMING_HASH", vm.toString(probe.timingHash(c, 1, 3600)));
            }
            vm.expectRevert(PostflightChecks.PrelaunchControllerTimingIncomplete.selector);
            probe.timing(c);
        }
    }

    // promise: timing signoff binds both scalars and the original config, within the separately approved numeric bounds.
    function _case_hashAndBoundsRejectZeroCreditWindow() internal cleanTimingEnv {
        _approve(1, 3600);
        vm.setEnv("PRELAUNCH_CONTROLLER_TIMING_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingSignoff.selector);
        probe.timing(c);
        _approve(1, 3600);
        LaunchConfig memory other = abi.decode(abi.encode(c), (LaunchConfig));
        other.sale.markupBps++;
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingSignoff.selector);
        probe.timing(other);
        _approve(0, 3600);
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingOutOfBounds.selector);
        probe.timing(c);
        _approve(uint256(type(uint16).max) + 1, 3600);
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingOutOfBounds.selector);
        probe.timing(c);
        _approve(1, uint256(type(uint32).max) + 1);
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingOutOfBounds.selector);
        probe.timing(c);
        _approve(type(uint16).max, type(uint32).max);
        (uint256 decay, uint256 window) = probe.timing(c);
        assertEq(decay, type(uint16).max);
        assertEq(window, type(uint32).max);
        _approve(1, 0);
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingOutOfBounds.selector);
        probe.timing(c);
    }

    // promise: timing records round-trip as decimal strings and recover the full approval tuple only after identity checks.
    function _case_recordRecoveryAndIdentity() internal cleanTimingEnv {
        _approve(1, 3600);
        string memory fields = probe.fragment(c);
        assertEq(vm.parseJsonString(string.concat('{"placeholder":0', fields, "}"), ".controllerCreditWindow"), "3600");
        string memory j = _record(fields);
        _clear();
        probe.recover(c, CORE, j);
        (uint256 decay, uint256 window) = probe.timing(c);
        assertEq(decay, 1);
        assertEq(window, 3600);
        probe.recover(c, CORE, j);
        vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("core")));
        probe.recover(c, address(1), j);
        string memory wrongChain = vm.replace(
            j,
            string.concat('"chainId":', vm.toString(block.chainid)),
            string.concat('"chainId":', vm.toString(block.chainid + 1))
        );
        vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("chainId")));
        probe.recover(c, CORE, wrongChain);
        LaunchConfig memory other = abi.decode(abi.encode(c), (LaunchConfig));
        other.rateStart++;
        vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("configHash")));
        probe.recover(other, CORE, j);
    }

    // promise: partial or corrupt records and conflicts with any explicit environment approval cannot be recovered.
    function _case_recordPartialHashBoundsAndEnvironmentConflict() internal cleanTimingEnv {
        for (uint256 mask = 1; mask < 7; ++mask) {
            string memory fields;
            if (mask & 1 != 0) fields = string.concat(fields, ',"controllerDecayHours":"1"');
            if (mask & 2 != 0) fields = string.concat(fields, ',"controllerCreditWindow":"3600"');
            if (mask & 4 != 0) {
                fields =
                    string.concat(fields, ',"controllerTimingHash":"', vm.toString(probe.timingHash(c, 1, 3600)), '"');
            }
            string memory partialRecord = _record(fields);
            vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("controllerTiming")));
            probe.decode(c, CORE, partialRecord);
        }
        string memory bad = _record(_fields(1, 3600, bytes32(0)));
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingSignoff.selector);
        probe.decode(c, CORE, bad);
        bad = _record(_fields(0, 3600, probe.timingHash(c, 0, 3600)));
        vm.expectPartialRevert(PostflightChecks.PrelaunchControllerTimingOutOfBounds.selector);
        probe.decode(c, CORE, bad);
        string memory j = _record(_fields(1, 3600, probe.timingHash(c, 1, 3600)));
        _approve(2, 3600);
        vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("controllerTiming")));
        probe.recover(c, CORE, j);
        _clear();
        vm.setEnv("PRELAUNCH_DECAY_HOURS", "1");
        vm.expectRevert(PostflightChecks.PrelaunchControllerTimingIncomplete.selector);
        probe.recover(c, CORE, j);
    }

    // promise: approving timing changes still rejects every unrelated Sale, Credit, anchor, age and quote mismatch.
    function _case_onlyTwoControllerFieldsMayDiffer() internal cleanTimingEnv {
        c.quote.referenceRateBpsPerHour = 1;
        c.quote.referenceStepBps = 1;
        c.quote.referenceMaxStale = 600;
        IControllerV1 ctl = _controller();
        _assertFail(ctl, "sale settings");
        _approve(1, 3600);
        _assertPass(ctl);
        bytes memory beforeSale = abi.encode(c.sale);
        for (uint256 field; field < 5; ++field) {
            Sale memory changed = abi.decode(beforeSale, (Sale));
            changed.decayHours = 1;
            if (field == 0) changed.markupBps++;
            if (field == 1) changed.startCapBps++;
            if (field == 2) changed.anchorHalfLife++;
            if (field == 3) changed.anchorMinCost++;
            if (field == 4) changed.anchorMoveBps++;
            ctl.setSale(changed);
            _assertFail(ctl, "sale settings");
        }
        Sale memory original = abi.decode(beforeSale, (Sale));
        original.decayHours = 1;
        ctl.setSale(original);
        CreditSale memory credit = CreditSale(c.credit.saleOn, 3600, c.credit.spreadBps, c.credit.startBps);
        CreditSale memory changedCredit = abi.decode(abi.encode(credit), (CreditSale));
        changedCredit.saleOn = !credit.saleOn;
        ctl.setCredit(changedCredit);
        _assertFail(ctl, "credit sale settings");
        changedCredit = CreditSale(credit.saleOn, credit.window, credit.spreadBps + 1, credit.startBps);
        ctl.setCredit(changedCredit);
        _assertFail(ctl, "credit sale settings");
        changedCredit = CreditSale(credit.saleOn, credit.window, credit.spreadBps, credit.startBps + 1);
        ctl.setCredit(changedCredit);
        _assertFail(ctl, "credit sale settings");
        ctl.setCredit(CreditSale(c.credit.saleOn, 3600, c.credit.spreadBps, c.credit.startBps));
        ctl.setAnchorBps(10_001);
        _assertFail(ctl, "anchor is 10_000");
        ctl.setAnchorBps(10_000);
        ctl.setAgeEligibilityOn(true);
        _assertFail(ctl, "age eligibility");
        ctl.setAgeEligibilityOn(false);
        bytes memory quote = abi.encode(c.quote);
        for (uint256 field; field < 6; ++field) {
            Quote memory changed = abi.decode(quote, (Quote));
            if (field == 0) changed.referenceRateBpsPerHour++;
            if (field == 1) changed.referenceStepBps++;
            if (field == 2) changed.tolBps++;
            if (field == 3) changed.referenceMaxStale++;
            if (field == 4) changed.referenceMinSeconds++;
            if (field == 5) changed.minLiquidity++;
            ctl.setQuote(changed);
            _assertFail(ctl, "reference price settings");
        }
        ctl.setQuote(c.quote);
        _assertPass(ctl);
    }
}
