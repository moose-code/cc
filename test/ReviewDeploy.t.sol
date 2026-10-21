// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {console} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ReviewHarness} from "./utils/ReviewHarness.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Mainnet, Stack, Settings} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsMevSkimV2,
    IArtCoinsTokenV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {SystemDeployer, Deployed} from "../script/SystemDeployer.sol";
import {LaunchConfig, ConfigReader} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

/// @notice the deploy package on the pinned fork: both library rows, the Core before `setController`, the readbacks of the
/// position and the sniper schedule, the Core constructor rules, the config parser and the sign off hash. the mutation
/// matrix is in test/ReviewMatrix.t.sol. forks mainnet at FORK_BLOCK.
/// this is a deploy-mechanics test of a fresh system, not the live Core: it exercises the deploy package on a
/// pre-launch fork, so it never reads or mutates the live Core.
contract ReviewDeployTest is ReviewHarness {
    // promise: each library row accepts absence and its compiled copy, then rejects altered code
    function test_preflightLibraryRow() public {
        string[2] memory names = ["CoreLib", "CoreOpsLib"];
        address[2] memory libs = [libraryAddress(), opsLibraryAddress()];
        for (uint256 i; i < names.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.etch(libs[i], "");
            vm.resetNonce(libs[i]);
            string memory row = string.concat("library: ", names[i], " at its create2 address is the compiled code or absent");
            assertEq(this.runPre(base, deployer), "", "absent passes");
            (,, string memory detail) = _row(row);
            assertTrue(vm.contains(detail, "not deployed"));
            vm.prank(deployer);
            (bool sent,) = CREATE2_DEPLOYER.call(
                abi.encodePacked(bytes32(0), vm.getCode(string.concat(names[i], ".sol:", names[i])))
            );
            assertTrue(sent);
            assertEq(this.runPre(base, deployer), "", "the compiled copy passes");
            vm.etch(libs[i], hex"00");
            assertEq(this.runPre(base, deployer), row);
            vm.revertToState(snap);
        }
    }

    // a Core without a controller refuses every door that reads or answers to the controller
    // promise: a Core without a controller refuses every door that reads or answers to the controller
    function test_aCoreWithoutAControllerRefusesItsControllerDoors() public {
        _etchLibrary();
        vm.prank(deployer);
        ICore core = ICore(payable(_newCore(base, deployer)));
        assertEq(core.controller(), address(0));
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
        vm.prank(makeAddr("review.stranger"));
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellCreditTo(1, makeAddr("review.buyer"));
    }

    // promise: a deferred Core owner can reset the opening rate and its 3x cap without carrying prior idle climb
    function test_prelaunchOpeningRateResetAndBounds() public {
        _etchLibrary();
        vm.prank(deployer);
        ICore core = ICore(payable(_newCore(base, deployer)));
        vm.prank(deployer);
        core.fund{value: 1 ether}();
        vm.warp(block.timestamp + 2 hours);
        assertGt(core.ethPrice(), base.rateStart, "the funded rate climbed before reset");
        vm.prank(deployer);
        core.setOpeningRate(2e16);
        assertEq(core.RATE_START(), 2e16);
        assertEq(core.settings().rateCap, 6e16);
        assertEq(core.ethPrice(), 2e16, "the reset starts a new rate clock");
        vm.prank(deployer);
        core.setOpeningRate(3e15);
        assertEq(core.RATE_START(), 3e15);
        assertEq(core.settings().rateCap, 9e15);
        assertEq(core.ethPrice(), 3e15, "a downward reset takes effect at once");
        vm.prank(creator);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setOpeningRate(base.rateStart);
        vm.startPrank(deployer);
        vm.expectRevert(ICore.BadRate.selector);
        core.setOpeningRate(0);
        vm.expectRevert(ICore.BadRate.selector);
        core.setOpeningRate(type(uint64).max / 3 + 1);
        vm.stopPrank();
        assertEq(core.RATE_START(), 3e15, "bad edits leave the previous opening rate");
    }

    // promise: the opening rate can only change before the predicted coin has code
    function test_prelaunchOpeningRateClosesWhenCoinExists() public {
        _etchLibrary();
        vm.prank(deployer);
        ICore core = ICore(payable(_newCore(base, deployer)));
        assertEq(core.COIN().code.length, 0, "the predicted coin is not deployed");
        vm.etch(core.COIN(), hex"00");
        vm.prank(deployer);
        vm.expectRevert(ICore.OpeningRateClosed.selector);
        core.setOpeningRate(base.rateStart);
    }

    function _etchLibrary() internal {
        address[2] memory libs = [libraryAddress(), opsLibraryAddress()];
        string[2] memory names = ["CoreLib", "CoreOpsLib"];
        for (uint256 i; i < libs.length; ++i) {
            vm.etch(libs[i], "");
            vm.resetNonce(libs[i]);
            vm.prank(deployer);
            (bool sent,) = CREATE2_DEPLOYER.call(
                abi.encodePacked(bytes32(0), vm.getCode(string.concat(names[i], ".sol:", names[i])))
            );
            assertTrue(sent);
        }
    }

    // ------------------------------------------------------------------ readbacks of the first review, still true

    /// the postflight reads the position back from the position manager, so a launch whose position is not the
    /// config's fails even when every config rule was bypassed
    // promise: postflight reads the position back
    function test_postflightReadsThePositionBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.startTick = c.positionLower = -170_000;
        postflightAs(c, d.core, address(0));
        assertEq(
            _failedNames(),
            "position: ticks equal the config (mirrored, the coin is currency1), pool: start tick equals the config while nothing was bought"
        );
        c = base;
        c.positionUpper = 600_000;
        postflightAs(c, d.core, address(0));
        assertEq(_failedNames(), "position: ticks equal the config (mirrored, the coin is currency1)");
        // after the first trade the start tick itself is gone, the position rows still hold
        vm.warp(block.timestamp + base.sniperSeconds + 1);
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
    }

    /// the sniper parameters are read back from the mev module schedule: start, end (the baseline), window, start time
    // promise: the sniper parameters are read back from the mev module schedule: start, end (the baseline), window, start time
    function test_postflightReadsTheSniperParamsBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        (uint24 now_,) = IArtCoinsMevSkimV2(base.mevModule).currentSkimBps(d.poolId);
        assertEq(now_, 6_900, "readable at the launch block");
        vm.warp(block.timestamp + 900);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        string memory row = "mev: schedule equals the config (start, end at the baseline, window, start time)";
        LaunchConfig memory c = base;
        c.sniperStartBps = 8_000;
        postflightAs(c, d.core, address(0));
        assertEq(_failedNames(), row);
        c = base;
        c.sniperSeconds = 3000;
        postflightAs(c, d.core, address(0));
        assertEq(_failedNames(), string.concat("core: settings.sniperSeconds equals the launch mev window, ", row));
        c = base;
        c.baselineSkimBps = 500;
        postflightAs(c, d.core, address(0));
        assertEq(_failedNames(), string.concat("hook: skim config equals the config, ", row));
        vm.warp(block.timestamp + 901);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "", "window over, the schedule is frozen");
    }

    /// the constructor refuses a stack member without code, the coin is exempt (it does not exist yet). the auction
    /// factory is one of them: without code, and as a contract that is not a factory
    // promise: the constructor refuses a stack member without code, the coin is exempt (it does not exist yet)
    function test_coreRejectsAStackWithoutCode() public {
        Settings memory s = Mainnet.defaultSettings();
        Stack memory st = base.stack;
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(base, owner, address(0));
        Prod.newCore(owner, cfg, owner, address(0), base.payee, st, 4e13, s);
        Stack memory bad = st;
        bad.hook = makeAddr("hook");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.hook));
        Prod.newCore(owner, cfg, owner, address(0), base.payee, bad, 4e13, s);
        bad = st;
        bad.escrow = makeAddr("escrow");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.escrow));
        Prod.newCore(owner, cfg, owner, address(0), base.payee, bad, 4e13, s);
        // a zero payee is refused
        vm.expectRevert(ICore.ZeroAddress.selector);
        Prod.newCore(owner, cfg, owner, address(0), address(0), st, 4e13, s);
        // a hook in the launch config other than the stack hook is refused
        IArtCoinsFactoryV2.DeploymentConfigV2 memory other = cfg;
        other.pool.hook = makeAddr("other hook");
        vm.expectRevert(ICore.BadStack.selector);
        Prod.newCore(owner, other, owner, address(0), base.payee, st, 4e13, s);
    }

    /// the constructor computes the coin from the factory prediction with the Core as bounty recipient, and a successor
    /// Core takes a recorded coin as it is
    // promise: core coin is predicted or recorded
    function test_coreCoinIsPredictedOrRecorded() public {
        Settings memory s = Mainnet.defaultSettings();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(base, owner, address(0));
        ICore c = Prod.newCore(owner, cfg, owner, address(0), base.payee, base.stack, 4e13, s);
        assertEq(c.COIN(), predictCoin(base, owner, address(c)), "the coin is the prediction for the Core as recipient");
        assertEq(c.settings().sniperSeconds, base.sniperSeconds);
        assertEq(c.payee(), base.payee);
        // a coin the factory did not record is refused for a successor
        vm.expectRevert(ICore.BadStack.selector);
        Prod.newCoreOf(makeAddr("unrecorded coin"), owner, cfg, address(0), base.payee, base.stack, 4e13, s);
    }

    function parse(string memory j) external view returns (LaunchConfig memory) {
        return parseConfig(j);
    }

    function load(string memory file) external view returns (LaunchConfig memory) {
        return loadConfig(file);
    }

    /// a json number that does not fit its field is rejected, never cut
    // promise: a json number that does not fit its field is rejected, never cut
    function test_jsonNumbersAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, ".stack.tickSpacing"));
        this.load("test/data/ReviewTruncated.json");
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        assertEq(this.parse(j).bountyBps, 9000, "the untouched file parses");
        string[11] memory from = [
            '"bountyBps": 9000',
            '"payeePpm": 0',
            '"baselineSkimBps": 690',
            '"sniperSeconds": 4140',
            '"startTick": -175000',
            '"positionUpper": 887200',
            '"poolFee": 8388608',
            '"dropPer100PointsBps": 115',
            '"peakHalfLife": 21600',
            '"dropFloorBps": 1',
            '"buybackSlice": 500000000000000000'
        ];
        string[11] memory to = [
            '"bountyBps": 65536',
            '"payeePpm": 16777216',
            '"baselineSkimBps": 16777216',
            '"sniperSeconds": 4294967296',
            '"startTick": -8388609',
            '"positionUpper": 8388608',
            '"poolFee": 16777216',
            '"dropPer100PointsBps": 65536',
            '"peakHalfLife": 4294967296',
            '"dropFloorBps": 65536',
            '"buybackSlice": 340282366920938463463374607431768211456'
        ];
        string[11] memory keys = [
            ".launch.bountyBps",
            ".settings.payeePpm",
            ".launch.baselineSkimBps",
            ".settings.sniperSeconds",
            ".launch.startTick",
            ".launch.positionUpper",
            ".stack.poolFee",
            ".settings.dropPer100PointsBps",
            ".settings.peakHalfLife",
            ".settings.dropFloorBps",
            ".settings.buybackSlice"
        ];
        for (uint256 i; i < from.length; ++i) {
            assertTrue(vm.contains(j, from[i]), from[i]);
            vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, keys[i]));
            this.parse(vm.replace(j, from[i], to[i]));
        }
        // the largest value that fits is accepted
        assertEq(this.parse(vm.replace(j, from[0], '"bountyBps": 65535')).bountyBps, 65_535);
        assertEq(this.parse(vm.replace(j, from[4], '"startTick": -8388608')).startTick, -8_388_608);
        // a key that is missing or misspelled is an error, not a zero
        vm.expectRevert();
        this.parse(vm.replace(j, '"feeToRedeemBurnBps"', '"feeToRedeemBurnBpz"'));
        vm.expectRevert();
        this.parse(vm.replace(j, '"payee"', '"payeee"'));
        // the overrides are optional and default to false
        LaunchConfig memory c = this.parse(vm.replace(j, '"overrides"', '"unused"'));
        assertFalse(c.allowBounty || c.allowOpenFactory);
        c = this.parse(vm.replace(j, '"bounty": false', '"bounty": true'));
        assertTrue(c.allowBounty);
    }

    function requireHash(LaunchConfig memory c, bytes32 h) external view {
        _requireConfigHash(c, h);
    }

    /// the default config plus the launch inputs of script/config/mainnet.json (the live v2 stack, owner, creator, payee,
    /// artist, name, salt)
    function _shipped() internal view returns (LaunchConfig memory s) {
        s = defaultConfig();
        s.stack.hook = v2.hook;
        s.stack.factory = v2.factory;
        s.stack.locker = v2.locker;
        s.stack.escrow = v2.escrow;
        s.mevModule = v2.mev;
        s.owner = v2.owner;
        s.creator = v2.owner;
        s.artist = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a;
        s.payee = v2.owner;
        s.name = "CC";
        s.salt = keccak256("CC");
        // launch day inputs (FLOW decision 54): empty or filled in the file
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        s.image = f.image;
        s.description = f.description;
    }

    function _hashRow() internal view returns (string memory) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256("signoff: CONFIG_HASH")) return rows[i].detail;
        }
        revert("no hash row");
    }

    /// the one value the operator signs. preflight and postflight print the same hash, Deploy needs it and every change
    /// of the config changes it
    // promise: the one value the operator signs
    function test_configHashIsTheSignOffValue() public {
        bytes32 h = configHash(base);
        this.runPre(base, deployer);
        assertEq(_hashRow(), vm.toString(h), "preflight prints it");
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_hashRow(), vm.toString(h), "postflight prints the same value");
        this.requireHash(base, h);
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, bytes32(0), h));
        this.requireHash(base, bytes32(0));
        LaunchConfig memory c = base;
        c.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, h, configHash(c)));
        this.requireHash(c, h);
        // the hash does not depend on the machine: same content from a file and from the struct
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(configHash(f), configHash(_shipped()));
    }
}

/// @notice the funded rule and the climb clamp, fuzzed on standalone cores with any rateStart in bounds, plus the
/// sign off table rows that need a live pool to check.
/// this is a deploy-mechanics test of a fresh system, not the live Core: it builds standalone cores, so it never reads
/// or mutates the live Core.
contract ReviewFundedTest is Fixture {
    function _newCore(uint256 rate) internal returns (ICore c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        IControllerV1 ctl2 = Prod.newController(predicted, Mainnet.defaultSale());
        Settings memory s = Mainnet.defaultSettings();
        // any opening rate in the bounds needs a rate cap at or above it
        s.rateCap = uint64(1e18);
        s.spendCapBps = 10_000; // This fuzz case isolates the funded price rule.
        c = _make(rate, address(ctl2), s);
        assertEq(address(c), predicted);
    }

    /// @dev fee income at `c`: the hook pushes eth into the Core, the only address besides the escrow that `receive`
    /// accepts, and the book counts it
    function _fees(ICore c, uint256 amt) internal {
        address hook = lc.stack.hook;
        vm.deal(hook, hook.balance + amt);
        vm.prank(hook);
        (bool ok,) = address(c).call{value: amt}("");
        assertTrue(ok);
        c.book();
    }

    function _make(uint256 rate, address controller, Settings memory s) internal returns (ICore) {
        return _launchCore(controller, lc.stack, rate, s);
    }

    /// the pot less the reserve, the clamp of the read
    function _room(ICore c) internal view returns (uint256) {
        uint256 pot = c.ethPot();
        uint256 res = c.reserve();
        return pot > res ? pot - res : 0;
    }

    function _check(ICore c) internal view {
        // the bid's room is the pot less the reserve over 1 + buyToArtistBps / 10_000, so a credit at the read is payable
        // with its artist royalty (decision 163)
        uint256 room = _room(c) * 10_000 / (10_000 + c.settings().buyToArtistBps);
        uint256 stored = c.rateAtCheckpoint();
        uint256 r = c.ethRate();
        assertLe(r, room, "the pot less the reserve affords a credit and its royalty at the live rate");
        // the price state never climbs while the room cannot afford a credit, and the read is the clamp
        if (room < stored) {
            assertEq(r, room, "the read is the clamp while unaffordable");
        }
    }

    /// forge-config: default.fuzz.runs = 400
    // promise: fuzz funded rule and clamp
    function testFuzz_fundedRuleAndClamp(uint256 rateSeed, uint256[10] memory ops) public {
        uint256 rate = bound(rateSeed, 1e13, 1e18);
        ICore c = _newCore(rate);
        address who = makeAddr("fuzz.seller");
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 4;
            uint256 arg = ops[i] >> 8;
            if (op == 0) {
                _fees(c, bound(arg, 1e9, 20 ether));
            } else if (op == 1) {
                uint256 r0 = c.ethRate();
                uint256 room = _room(c);
                vm.warp(block.timestamp + bound(arg, 1, 400 hours));
                uint256 r1 = c.ethRate();
                assertGe(r1, r0, "the read fell without a fill");
                assertLe(r1, r0 > room ? r0 : room, "climbed above the clamp");
            } else if (op == 2) {
                uint256 id = _nextCredit();
                vm.prank(Mainnet.CREDIT_STRATEGY);
                CREDITS.transferFrom(Mainnet.CREDIT_STRATEGY, who, id);
                vm.startPrank(who);
                CREDITS.setApprovalForAll(address(c), true);
                uint256[] memory ids = new uint256[](1);
                ids[0] = id;
                try c.sellForEth(ids) {}
                catch (bytes memory why) {
                    bytes4 sel = bytes4(why);
                    assertTrue(
                        sel == ICore.PotTooSmall.selector || sel == ICore.ZeroAmount.selector, "unexpected revert"
                    );
                }
                vm.stopPrank();
            } else {
                c.book();
            }
            _check(c);
        }
    }

    /// the bounds of rateStart, at and beside both edges
    // promise: the bounds of rateStart, at and beside both edges
    function test_rateStartBounds() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        Stack memory st = lc.stack;
        vm.expectRevert(ICore.BadRate.selector);
        _launchCore(predicted, st, 0, Mainnet.defaultSettings());
        vm.expectRevert(ICore.BadRate.selector);
        _launchCore(predicted, st, uint256(type(uint64).max) + 1, Mainnet.defaultSettings());
        // The opening rate may not sit above the configured rate cap.
        vm.expectRevert(ICore.BadRate.selector);
        _launchCore(predicted, st, uint256(Mainnet.defaultSettings().rateCap) + 1, Mainnet.defaultSettings());
        Settings memory top = Mainnet.defaultSettings();
        top.rateCap = type(uint64).max;
        ICore lo = _launchCore(predicted, st, 1, top);
        ICore hi = _launchCore(address(1), st, type(uint64).max, top);
        assertEq(lo.rateAtCheckpoint(), 1);
        assertEq(hi.rateAtCheckpoint(), type(uint64).max);
        // the pot at which the clamp equals the rate: one credit at the rate
        _fees(lo, 0);
        assertEq(lo.ethRate(), 0);
        _fees(lo, 1);
        assertEq(lo.ethRate(), 1);
        _fees(hi, uint256(type(uint64).max) - 1);
        assertEq(hi.ethRate(), uint256(type(uint64).max) - 1);
        _fees(hi, 1);
        assertEq(hi.ethRate(), type(uint64).max);
    }
}
