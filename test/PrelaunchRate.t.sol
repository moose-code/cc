// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SystemResumer} from "../script/SystemResumer.sol";
import {Deployed} from "../script/SystemDeployer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Postflight} from "../script/Postflight.s.sol";

contract PostflightRecordProbe is Postflight {
    uint256 internal approvedRate;

    function decode(LaunchConfig memory c, address core, string memory j) external view returns (uint256, bytes32) {
        return _decodeApprovedRateRecord(c, core, j);
    }

    function setApprovedRate(uint256 rate) external {
        approvedRate = rate;
    }

    function _approvedOpeningRate(LaunchConfig memory c) internal view override returns (uint256) {
        return approvedRate == 0 ? c.rateStart : approvedRate;
    }

    function verify(LaunchConfig memory c, address core, address deployer) external {
        postflightAs(c, core, deployer);
        _require();
    }
}

/// Checks the deferred Core's price reset and resume checks on the live v2 factory fork.
/// this is a deploy-mechanics test of a fresh system, not the live Core: it resumes a new deferred Core on a
/// pre-launch fork, so it never reads or mutates the live Core.
contract PrelaunchRateTest is Test, SystemResumer, ProdDeployer {
    address internal deployer;
    address internal creator;
    LaunchConfig internal base;
    IArtCoinsFactoryV2 internal factory;
    uint256 internal approvedRate;
    bool internal signoffGood;

    function setUp() public {
        // a deploy-mechanics test of a fresh system must fork before the live Core and its libraries existed. the
        // default pins the pre-launch block Rehearsal uses; never the head, which the RPC cache cannot serve for free
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(26208025));
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        // libraryAddress() and opsLibraryAddress() are the deterministic CREATE2 addresses that on a post-launch fork
        // hold the live CoreLib and ops library linked into the live Core. etching empty code there would wipe the live
        // Core's linked code for the rest of the run, so refuse unless the fork is before the deploy block
        // (deployments/1.json deployBlock), where those addresses are empty and the reset is a safe no-op
        require(
            block.number < 26229330, "PrelaunchRate must fork a pre-launch block: see deployments/1.json deployBlock"
        );
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
        vm.etch(opsLibraryAddress(), "");
        vm.resetNonce(opsLibraryAddress());
        V2Stack.Stack memory v2 = V2Stack.attach();
        deployer = v2.owner;
        creator = makeAddr("price.creator");
        factory = IArtCoinsFactoryV2(v2.factory);
        vm.deal(deployer, 5 ether);
        base = defaultConfig();
        base.owner = deployer;
        base.creator = creator;
        base.artist = creator;
        base.payee = makeAddr("price.payee");
        base.name = "Price Coin";
        base.symbol = "PRC";
        base.image = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        base.description = "Price Coin test description";
        base.salt = keccak256("prelaunch price");
        base.stack.hook = v2.hook;
        base.stack.factory = v2.factory;
        base.stack.locker = v2.locker;
        base.stack.escrow = v2.escrow;
        base.mevModule = v2.mev;
        signoffGood = true;
    }

    function _defer() internal returns (Deployed memory d) {
        vm.prank(deployer);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(ok, "CoreLib deployed");
        vm.prank(deployer);
        (ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreOpsLib.sol:CoreOpsLib")));
        assertTrue(ok, "CoreOpsLib deployed");
        vm.startPrank(deployer);
        d = deploySystemUntilLaunch(deployer, base);
        vm.stopPrank();
    }

    function _approve(uint256 rate) internal {
        approvedRate = rate;
        signoffGood = true;
    }

    function _approvedOpeningRate(LaunchConfig memory c) internal view override returns (uint256) {
        if (!signoffGood) revert PrelaunchRateSignoff(_openingRateHash(c, approvedRate), bytes32(0));
        return approvedRate == 0 ? c.rateStart : approvedRate;
    }

    function guardsExt(address core) external {
        resumeChecks(deployer, base, core);
        launchOnlyChecks(deployer, base, core, factory.tokenDeployer());
    }

    // promise: recovery after Core creation requires the signed opening rate before a coin launch
    function test_resumeRequiresOpeningRateSignoff() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        uint256 rate = 20_000_000_000_000_000;
        vm.prank(deployer);
        k.setOpeningRate(rate);
        approvedRate = rate;
        signoffGood = false;
        vm.expectPartialRevert(PrelaunchRateSignoff.selector);
        this.guardsExt(d.core);
        signoffGood = true;
        this.guardsExt(d.core);
        vm.prank(deployer);
        k.setRate(rate - 1);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "opening price state"));
        this.guardsExt(d.core);
        assertEq(d.coin.code.length, 0, "a failed guard never launches the coin");
    }

    // promise: the saved rate and hash bind postflight to the same config, chain and Core
    function test_savedOpeningRateRecordBindsConfigAndCore() public {
        Deployed memory d = _defer();
        uint256 rate = 20_000_000_000_000_000;
        vm.prank(deployer);
        ICore(payable(d.core)).setOpeningRate(rate);
        _approve(rate);
        vm.startPrank(deployer);
        resumeSend(deployer, base);
        vm.stopPrank();
        bytes32 hash = _openingRateHash(base, rate);
        string memory j = string.concat(
            '{"core":"', vm.toString(d.core), '","chainId":1,"configHash":"', vm.toString(configHash(base)),
            '","openingRate":"', vm.toString(rate), '","openingRateHash":"', vm.toString(hash), '"}'
        );
        PostflightRecordProbe probe = new PostflightRecordProbe();
        (uint256 savedRate, bytes32 savedHash) = probe.decode(base, d.core, j);
        assertEq(savedRate, rate);
        assertEq(savedHash, hash);
        probe.setApprovedRate(savedRate);
        probe.verify(base, d.core, deployer);
        string memory badHash = string.concat(
            '{"core":"', vm.toString(d.core), '","chainId":1,"configHash":"', vm.toString(configHash(base)),
            '","openingRate":"', vm.toString(rate + 1), '","openingRateHash":"', vm.toString(hash), '"}'
        );
        vm.expectRevert(abi.encodeWithSelector(Postflight.RecordMismatch.selector, bytes32("openingRateHash")));
        probe.decode(base, d.core, badHash);
    }

    // promise: an owner reset after an idle day changes the reference, hard cap and live clock, and launch closes it
    function test_resetThenLaunch() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        uint256 rate = 20_000_000_000_000_000;
        vm.warp(block.timestamp + 1 days);
        vm.prank(deployer);
        k.setOpeningRate(rate);
        assertEq(k.RATE_START(), rate);
        assertEq(k.settings().rateCap, 3 * rate);
        assertEq(k.rateAtCheckpoint(), rate);
        assertEq(k.ethPrice(), rate, "pre-reset idle time earns no climb");
        assertEq(d.coin.code.length, 0);
        _approve(rate);
        this.guardsExt(d.core);
        vm.startPrank(deployer);
        Deployed memory launched = resumeSend(deployer, base);
        vm.stopPrank();
        assertEq(launched.core, d.core);
        assertEq(launched.coin, d.coin);
        assertGt(d.coin.code.length, 0);
        postflightAs(base, d.core, deployer);
        (string memory failures,) = _failed();
        assertEq(failures, "", "postflight");
        vm.prank(deployer);
        vm.expectRevert(bytes4(keccak256("OpeningRateClosed()")));
        k.setOpeningRate(base.rateStart);
    }

    // promise: only the owner may reset, and rates whose 3x cap cannot fit the setting are rejected atomically
    function test_authorityAndBounds() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        vm.prank(creator);
        vm.expectRevert(bytes4(keccak256("OnlyOwner()")));
        k.setOpeningRate(base.rateStart);
        vm.startPrank(deployer);
        vm.expectRevert(bytes4(keccak256("BadRate()")));
        k.setOpeningRate(0);
        vm.expectRevert(bytes4(keccak256("BadRate()")));
        k.setOpeningRate(type(uint64).max / 3 + 1);
        vm.stopPrank();
        assertEq(k.RATE_START(), base.rateStart);
        assertEq(k.settings().rateCap, base.settings.rateCap);
    }

    // promise: a funded Core can reset upward and downward without carrying prior idle climb into either new rate
    function test_fundedResetsInBothDirections() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        vm.prank(deployer);
        k.fund{value: 1 ether}();
        vm.warp(block.timestamp + 2 hours);
        assertGt(k.ethPrice(), base.rateStart, "funded climb occurred");
        uint256 high = 20_000_000_000_000_000;
        vm.prank(deployer);
        k.setOpeningRate(high);
        assertEq(k.ethPrice(), high, "upward reset is immediate");
        assertEq(k.settings().rateCap, 3 * high);
        vm.warp(block.timestamp + 2 hours);
        assertGt(k.ethPrice(), high, "new funded climb occurred");
        uint256 low = 3_000_000_000_000_000;
        vm.prank(deployer);
        k.setOpeningRate(low);
        assertEq(k.ethPrice(), low, "downward reset is immediate");
        assertEq(k.RATE_START(), low);
        assertEq(k.settings().rateCap, 3 * low);
    }

    // promise: launch-only rejects a different signed price, missing signoff, a live-rate edit and unrelated settings
    function test_launchGuardsRejectTampering() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        uint256 rate = 20_000_000_000_000_000;
        vm.prank(deployer);
        k.setOpeningRate(rate);
        _approve(rate - 1);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "opening rate"));
        this.guardsExt(d.core);
        signoffGood = false;
        vm.expectPartialRevert(PrelaunchRateSignoff.selector);
        this.guardsExt(d.core);
        _approve(rate);
        this.guardsExt(d.core);

        vm.prank(deployer);
        k.setRate(rate - 1);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "opening price state"));
        this.guardsExt(d.core);
        vm.prank(deployer);
        k.setOpeningRate(rate);
        Settings memory changed = k.settings();
        changed.payeePpm += 1;
        vm.prank(deployer);
        k.setSettings(changed);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "core settings"));
        this.guardsExt(d.core);
    }

    // promise: a deferred Core cannot launch with a changed live price state under the original config signoff.
    function test_defaultOpeningRateRequiresOriginalPriceState() public {
        Deployed memory d = _defer();
        ICore k = ICore(payable(d.core));
        vm.prank(deployer);
        k.setRate(3_000_000_000_000_000);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "opening price state"));
        this.guardsExt(d.core);
        vm.prank(deployer);
        k.setOpeningRate(base.rateStart);
        this.guardsExt(d.core);
        vm.prank(deployer);
        k.fund{value: 1 ether}();
        vm.warp(block.timestamp + 1 minutes);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "opening live price"));
        this.guardsExt(d.core);
        vm.prank(deployer);
        k.setOpeningRate(base.rateStart);
        this.guardsExt(d.core);
    }
}
