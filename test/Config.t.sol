// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {
    LaunchConfig,
    V2_CODEHASH_HOOK,
    V2_CODEHASH_FACTORY,
    V2_CODEHASH_LOCKER,
    V2_CODEHASH_ESCROW,
    V2_CODEHASH_MEV_MODULE,
    V2_CODEHASH_TOKEN_DEPLOYER,
    V2_CODEHASH_ALLOWLIST,
    V2_CODEHASH_FEE_CONTROLLER,
    V2_CODEHASH_BURN_ROUTER,
    OWNER_DELEGATION_CODE,
    OWNER_DELEGATE,
    OWNER_DELEGATE_CODEHASH
} from "../script/LaunchConfig.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";

/// @notice the config file, the placeholder guard, the preflight and the postflight on the pinned fork
contract ConfigTest is Fixture {
    /// @dev SETTINGS_CHANGED of the operator, a flag here so parallel tests never share an environment variable
    bool internal changedFlag;

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    bool internal coinFlag;

    function _coinChanged() internal view override returns (bool) {
        return coinFlag;
    }

    function _same(LaunchConfig memory a, LaunchConfig memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// the json file is the default config plus the launch inputs the owner supplied (owner, creator, name, the creator
    /// payee) and the salt, keccak256 of "CC", and the live v2 stack of script/config/v2-mainnet.json
    function test_jsonEqualsDefaultConfig() public view {
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        LaunchConfig memory d = defaultConfig();
        V2Stack.Stack memory live = V2Stack.live();
        d.stack.hook = live.hook;
        d.stack.factory = live.factory;
        d.stack.locker = live.locker;
        d.stack.escrow = live.escrow;
        d.mevModule = live.mev;
        d.owner = v2.owner;
        d.creator = v2.owner;
        d.creatorPayee = v2.owner;
        d.name = "CC";
        d.salt = keccak256("CC");
        // image and description are launch day inputs (FLOW decision 54): the file may hold them filled or empty
        d.image = f.image;
        d.description = f.description;
        assertLe(bytes(f.image).length, MAX_IMAGE_BYTES, "image above the coin cap");
        assertLe(bytes(f.description).length, MAX_DESCRIPTION_BYTES, "description above the coin cap");
        assertEq(abi.encode(f.stack), abi.encode(d.stack));
        assertTrue(_same(f, d), "script/config/mainnet.json drifted from the default config");
        assertEq(f.owner, v2.owner);
        assertEq(f.creator, v2.owner);
        assertEq(f.name, "CC");
        assertEq(f.symbol, "CC");
        assertEq(f.salt, keccak256("CC"));
        assertEq(f.rateStart, 8.9e15);
        assertEq(f.supply, 1_000_000_000e18);
        assertEq(abi.encode(f.settings), abi.encode(Mainnet.defaultSettings()), "settings block is the launch values");
        // the launch values of docs/DECISIONS.md 10.1 and 10.6
        assertEq(f.baselineSkimBps, 690);
        assertEq(f.bountyBps, 9_638);
        assertEq(f.lpFeePips, 0);
        assertEq(f.maxReferralBps, 0);
        assertEq(f.sniperStartBps, 9_000);
        assertEq(f.sniperSeconds, 1800);
        assertTrue(f.restricted);
        assertEq(f.allowed.length, 0);
        assertEq(f.payeePpm, 112_778);
        // the stack addresses of the shipped file are the record of the live stack, the factory owner is the config owner
        assertEq(unsetFields(f).length, 0, "the shipped file leaves nothing unset");
        assertEq(live.owner, f.owner, "the factory owner of the record is the config owner");
        assertEq(live.owner, FACTORY.owner(), "and the owner on chain");
    }

    function requireExt(LaunchConfig memory c) external pure {
        _requireConfig(c);
    }

    /// the launch fee split derived from the v2 hook math (`ArtCoinsHookV2._split`), per 1 ether of volume. all rates in bps
    /// of volume. baseline skim 690 bps (6.9 points), skim = V * 690 / 10_000 = 0.069 ether.
    /// bounty leg = skim * bountyBps / 10_000, protocol leg = skim - bounty leg (steady state, no referral).
    /// protocol target 0.25 points = 25 bps = 0.0025 ether. the protocol share of the skim is (10_000 - bountyBps) / 10_000:
    /// 9_638 gives 690 * 362 / 10_000 = 24.978 bps (0.24978 points, 0.00022 below the target), 9_637 gives 690 * 363 /
    /// 10_000 = 25.047 bps (0.00047 above it). 9_638 is the nearest, and the factory needs minProtocolSkimShareBps at most
    /// 10_000 - 9_638 = 362 (`BPS - bountyBps - minProtocolSkimShareBps >= 0` in `_validateFee`).
    /// router inflow = bounty leg = 0.069 * 9_638 / 10_000 = 0.0665022 ether (665.022 bps). payee target 0.75 points =
    /// 75 bps = 0.0075 ether, payeePpm = 75 / 665.022 * 1e6 = 112_778.2, rounded down to 112_778.
    /// the engine receives the rest of the router inflow
    function test_feeSplitDerivation() public pure {
        LaunchConfig memory d = defaultConfig();
        uint256 v = 1 ether;
        uint256 skim = v * d.baselineSkimBps / 10_000;
        assertEq(skim, 0.069 ether);
        uint256 router = skim * d.bountyBps / 10_000;
        uint256 protocol = skim - router;
        assertEq(router, 66_502_200_000_000_000, "router inflow 6.65022 points");
        assertEq(protocol, 2_497_800_000_000_000, "protocol leg 0.24978 points");
        assertEq(10_000 - uint256(d.bountyBps), 362, "the factory minProtocolSkimShareBps the bounty needs");
        // the neighbouring bounty values are further from the 0.25 point target (0.0025 ether)
        uint256 target = 0.0025 ether;
        uint256 protocolAt9637 = skim - skim * 9_637 / 10_000; // 2.5047e15, above the target
        assertLt(target - protocol, protocolAt9637 - target, "9_638 is the nearest to 0.25 points");
        // payee: the largest ppm whose share of the router inflow does not exceed 0.75 points (0.0075 ether)
        uint256 payeeTarget = 0.0075 ether;
        uint256 payee = router * d.payeePpm / 1e6;
        assertLe(payee, payeeTarget);
        assertGt(router * (uint256(d.payeePpm) + 1) / 1e6, payeeTarget, "112_778 is the largest ppm under 0.75 points");
        assertEq(payee, 7_499_985_111_600_000, "payee 0.7499985 points");
        assertEq(router - payee, 59_002_214_888_400_000, "engine 5.9002215 points");
    }

    /// the deploy refuses to run while any placeholder is unset or the rate is out of bounds
    function test_deployRefusesPlaceholders() public {
        LaunchConfig memory c = defaultConfig();
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "owner"));
        this.requireExt(c);
        c.owner = owner;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "creator"));
        this.requireExt(c);
        c.creator = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "name"));
        this.requireExt(c);
        c.name = "Name";
        c.symbol = "";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "symbol"));
        this.requireExt(c);
        c.symbol = "SYM";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "salt"));
        this.requireExt(c);
        c.salt = FIXTURE_SALT;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "router.creatorPayee"));
        this.requireExt(c);
        c.creatorPayee = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.hook"));
        this.requireExt(c);
        c.stack = lc.stack;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.mevModule"));
        this.requireExt(c);
        c.mevModule = lc.mevModule;
        this.requireExt(c);
        c.rateStart = 1e13 - 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
        c.rateStart = 1e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
    }

    /// the shipped file is complete and passes the guard, and the refusal is proven by blanking each field of it
    function test_shippedFileBlankedIsRefused() public {
        LaunchConfig memory c = _shipped();
        this.requireExt(c);
        c.stack.hook = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.hook"));
        this.requireExt(c);
        c = _shipped();
        c.mevModule = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.mevModule"));
        this.requireExt(c);
        c = _shipped();
        c.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "owner"));
        this.requireExt(c);
        c = _shipped();
        c.creator = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "creator"));
        this.requireExt(c);
        c = _shipped();
        c.name = "";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "name"));
        this.requireExt(c);
        c = _shipped();
        c.salt = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "salt"));
        this.requireExt(c);
        c = _shipped();
        c.creatorPayee = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "router.creatorPayee"));
        this.requireExt(c);
    }

    function _shipped() internal view returns (LaunchConfig memory c) {
        c = loadConfig(DEFAULT_CONFIG_FILE);
    }

    /// @dev the owner is the factory owner and the deployer. it holds the fee and the gas
    function _funded() internal returns (address d2) {
        d2 = owner;
        vm.deal(d2, 5 ether);
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
        // a failure prints the whole table, so the detail of every row is in the log
        if (bytes(list).length != 0) _print("rows");
    }

    function _warnClean(string memory name) internal view returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return rows[i].ok;
        }
        revert("row missing");
    }

    function _rowDetail(string memory name) internal view returns (string memory) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return rows[i].detail;
        }
        revert("row missing");
    }

    function test_preflightPasses() public {
        address d2 = _funded();
        _pre(lc, d2);
        assertEq(_failedNames(), "");
        _print("preflight");
        // every launch input has a row: the count is part of the report
        assertEq(rows.length, 120, "preflight rows: docs/RUNBOOK.md step 4");
    }

    /// each pinned code hash has a row. appending one byte of code to a contract fails exactly its row
    function test_preflightPinsTheLiveCodeHashes() public {
        address d2 = _funded();
        address[9] memory at = [
            lc.stack.hook, lc.stack.factory, lc.stack.locker, lc.stack.escrow, lc.mevModule, v2.tokenDeployer,
            v2.allowlist, v2.controller, v2.burnRouter
        ];
        bytes32[9] memory want = [
            V2_CODEHASH_HOOK, V2_CODEHASH_FACTORY, V2_CODEHASH_LOCKER, V2_CODEHASH_ESCROW, V2_CODEHASH_MEV_MODULE,
            V2_CODEHASH_TOKEN_DEPLOYER, V2_CODEHASH_ALLOWLIST, V2_CODEHASH_FEE_CONTROLLER, V2_CODEHASH_BURN_ROUTER
        ];
        string[9] memory name = [
            "hook", "factory", "locker", "escrow", "mev module", "token deployer", "extension allowlist",
            "protocol fee controller", "burn router"
        ];
        for (uint256 i; i < 9; ++i) {
            assertEq(at[i].codehash, want[i], name[i]);
            uint256 snap = vm.snapshotState();
            vm.etch(at[i], abi.encodePacked(at[i].code, hex"00"));
            _pre(lc, d2);
            assertEq(_failedNames(), string.concat("code hash: ", name[i], " is the live v2 contract"), name[i]);
            vm.revertToState(snap);
        }
        _pre(lc, d2);
        assertEq(_failedNames(), "", "unchanged code passes");
    }

    /// the deprecated gate row: a stranger launch reverts Deprecated(). with the factory public the row is an info line
    function test_preflightDeprecatedGateRow() public {
        address d2 = _funded();
        string memory row = "factory: deprecated, the owner launches and any other caller reverts Deprecated()";
        _pre(lc, d2);
        assertTrue(bytes(_rowDetail(row)).length > 10, "row present while deprecated");
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        LaunchConfig memory c = lc;
        c.allowOpenFactory = true;
        _pre(c, d2);
        vm.expectRevert(bytes("row missing"));
        this.rowDetailExt(row);
        assertEq(_failedNames(), "", "an open factory passes with the override");
    }

    function rowDetailExt(string memory name) external view returns (string memory) {
        return _rowDetail(name);
    }

    /// every id of `CreditIds` is owned by the CreditStrategy at the fork block, and the three listed ids too
    function test_creditIdsAreHeldByTheStrategy() public view {
        for (uint256 i; i < 640; ++i) {
            assertEq(CREDITS.ownerOf(CreditIds.at(i)), STRATEGY, "credit id moved");
        }
        assertEq(CREDITS.ownerOf(LISTED_A), STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_C), STRATEGY);
    }

    function test_preflightSimulatesTheLaunchAndLeavesNoTrace() public {
        address d2 = _funded();
        uint256 nonce = vm.getNonce(d2);
        uint256 bal = d2.balance;
        _pre(lc, d2);
        assertEq(vm.getNonce(d2), nonce, "the simulation is reverted");
        assertEq(d2.balance, bal);
        assertTrue(bytes(_rowDetail("factory: deployTokenAsOwner accepts the config (simulated)")).length > 10);
    }

    /// owner and creator may be one address, a warning and never a failure. a stack address as owner or creator fails
    function test_warnOwnerIsTheCreator() public {
        address d2 = _funded();
        string memory w = "warn: owner differs from creator";
        _pre(lc, d2);
        assertTrue(_warnClean(w), "clean when they differ");
        LaunchConfig memory c = lc;
        c.creator = c.owner;
        _pre(c, d2);
        assertFalse(_warnClean(w), "the warning fires");
        assertEq(_failedNames(), "", "owner = creator passes");
        c = lc;
        c.creator = c.stack.hook;
        _pre(c, d2);
        assertEq(_failedNames(), "rule: owner, creator and payees are not dead or stack addresses, factory: deployTokenAsOwner accepts the config (simulated)");
        c = lc;
        c.creatorPayee = c.stack.escrow;
        _pre(c, d2);
        assertEq(
            _failedNames(),
            "rule: owner, creator and payees are not dead or stack addresses, payee: the launch payee accepts 0.001 eth with a 100000 gas call (simulated)"
        );
    }

    /// the launch payee takes 0.001 eth with a 100,000 gas call: a payee that reverts, or one that burns more gas, fails
    function test_preflightPayeeAcceptsEth() public {
        address d2 = _funded();
        string memory row = "payee: the launch payee accepts 0.001 eth with a 100000 gas call (simulated)";
        _pre(lc, d2);
        assertTrue(_warnClean(row), "the launch payee accepts eth");
        LaunchConfig memory c = lc;
        c.creatorPayee = makeAddr("reverting payee");
        vm.etch(c.creatorPayee, hex"60006000fd");
        _pre(c, d2);
        assertEq(_failedNames(), row, "a reverting payee fails");
        c.creatorPayee = makeAddr("gas burning payee");
        vm.etch(c.creatorPayee, hex"5b600056");
        _pre(c, d2);
        assertEq(_failedNames(), row, "a payee that burns the gas fails");
        c.creatorPayee = makeAddr("plain account payee");
        _pre(c, d2);
        assertEq(_failedNames(), "", "an account without code accepts eth");
    }

    function test_preflightFailures() public {
        // the default config: unset placeholders, a deployer that is not the factory owner
        address d2 = _user("second deployer");
        vm.deal(d2, 5 ether);
        LaunchConfig memory c = defaultConfig();
        _pre(c, d2);
        (string memory list, uint256 n) = _failed();
        assertGe(n, 8, list);
        // a poor deployer, an out of bounds rate and a wrong hook
        c = lc;
        c.rateStart = 5;
        c.stack.hook = address(0xBEEF);
        _pre(c, _user("poor deployer"));
        (list, n) = _failed();
        assertGe(n, 8, list);
        // the predicted addresses are already taken: rewind the fixture owner to the nonce it deployed at. the coin is
        // taken by the same salt of the same config, and the launch cannot be simulated
        (bool found, uint256 coreNonce) = _coreNonce(address(core), owner);
        assertTrue(found);
        vm.resetNonce(owner);
        vm.setNonce(owner, uint64(coreNonce - 2));
        vm.deal(owner, 5 ether);
        _pre(lc, owner);
        assertEq(
            _failedNames(),
            "factory: deployTokenAsOwner accepts the config (simulated), predicted router is empty, predicted controller is empty, predicted core is empty, predicted coin is empty"
        );
    }

    // ------------------------------------------------------------------ the owner commands the launch needs on v2

    function test_preflightProtocolSkimFloorAgainstTheBounty() public {
        address d2 = _funded();
        vm.prank(owner);
        FACTORY.setMinProtocolSkimShareBps(1_500);
        _pre(lc, d2);
        assertEq(
            _failedNames(),
            "factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)"
        );
        assertEq(
            _rowDetail("factory: min protocol skim share leaves room for the bounty"),
            "factory minProtocolSkimShareBps is 1500, above the 362 the bounty 9638 leaves. the factory owner runs setMinProtocolSkimShareBps(362) first"
        );
        // the floor of the launch bounty 9638 is 362
        vm.prank(owner);
        FACTORY.setMinProtocolSkimShareBps(363);
        _pre(lc, d2);
        assertEq(
            _failedNames(),
            "factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)"
        );
        vm.prank(owner);
        FACTORY.setMinProtocolSkimShareBps(362);
        _pre(lc, d2);
        assertEq(_failedNames(), "");
    }

    function test_preflightTheFactoryMustBeDeprecatedAndOwnedByTheDeployer() public {
        address d2 = _funded();
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: deprecated, only the owner can launch");
        LaunchConfig memory c = lc;
        c.allowOpenFactory = true;
        _pre(c, d2);
        assertEq(_failedNames(), "", "the override opens exactly that rule");
        vm.prank(owner);
        FACTORY.setDeprecated(true);
        address other = _user("other signer");
        vm.deal(other, 5 ether);
        _pre(lc, other);
        (string memory list,) = _failed();
        assertEq(list, "factory: owner is the deployer, factory: deployTokenAsOwner accepts the config (simulated)");
    }

    function test_preflightEnabledStack() public {
        address d2 = _funded();
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: hook enabled, factory: deployTokenAsOwner accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, true);
        FACTORY.setLocker(lc.stack.locker, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: locker enabled, factory: deployTokenAsOwner accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setLocker(lc.stack.locker, true);
        FACTORY.setMevModule(lc.mevModule, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: mev module enabled, factory: deployTokenAsOwner accepts the config (simulated)");
    }

    function test_postflightChecksTheLens() public {
        address lensAt = lensAddress(address(core));
        assertEq(lensAt, address(lens), "the lens sits at the CREATE2 address of the Core");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "the lens of the deploy passes");
        // a lens that points at another router or Core fails its row
        vm.mockCall(lensAt, abi.encodeWithSignature("ROUTER()"), abi.encode(address(0x1234)));
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "lens: router is the Core fee source");
        vm.clearMockedCalls();
        vm.mockCall(lensAt, abi.encodeWithSignature("CORE()"), abi.encode(address(0x1234)));
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "lens: core");
        vm.clearMockedCalls();
        // a missing lens fails the code row only
        bytes memory code = lensAt.code;
        vm.etch(lensAt, "");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "code: lens");
        // another bytecode at the derived address fails the size row
        vm.etch(lensAt, hex"6000");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "lens: code size is the compiled CoreLens");
        vm.etch(lensAt, code);
        // the rows need no deployer
        postflightAs(lc, address(core), address(0));
        assertEq(_failedNames(), "");
    }

    function test_postflightPassesOnTheFixture() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        // the same after trading started: the exact supply and rate rows turn tolerant, nothing fails
        _skipSniperWindow();
        _buyCoin(funder, 1 ether);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        _print("postflight");
        assertGe(rows.length, 85, "postflight rows");
    }

    /// V2R-5: the postflight compares the runtime code of the Core and of the controller with the compiled artifacts
    /// (immutables and the library address masked). one changed byte in either fails exactly its row
    function test_FIXED_postflightComparesTheCoreAndControllerRuntime() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        string memory coreRow = "core: runtime code is the compiled Core (immutables and the library address masked)";
        string memory ctlRow = "controller: runtime code is the compiled ControllerV1 (immutables masked)";
        assertTrue(_warnClean(coreRow) && _warnClean(ctlRow), "both rows pass on the fixture");

        bytes memory c = address(core).code;
        c[c.length - 1] = bytes1(uint8(c[c.length - 1]) ^ 1);
        vm.etch(address(core), c);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), coreRow);
        c[c.length - 1] = bytes1(uint8(c[c.length - 1]) ^ 1);
        vm.etch(address(core), c);

        bytes memory k = address(ctl).code;
        k[k.length - 1] = bytes1(uint8(k[k.length - 1]) ^ 1);
        vm.etch(address(ctl), k);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), ctlRow);
    }

    /// the coin's image and description are read back and compared with the config. the admin changing them fails the
    /// rows until the operator names the change (COIN_CHANGED=1), then they are warnings
    function test_FIXED_postflightReadsTheCoinImageAndDescription() public {
        string memory imageRow = "coin: image equals the config";
        string memory descRow = "coin: description equals the config";
        string memory row = string.concat(imageRow, ", ", descRow);
        assertEq(coin.imageUrl(), lc.image, "the launch set the image");
        assertEq(coin.description(), lc.description, "the launch set the description");
        postflightAs(lc, address(core), owner);
        assertTrue(_warnClean(imageRow) && _warnClean(descRow), "as launched");
        // a config that names other values than the coin holds fails exactly its row
        LaunchConfig memory c = lc;
        c.image = "ipfs://other";
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), imageRow);
        c = lc;
        c.description = "other";
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), descRow);
        vm.startPrank(owner);
        (bool ok1,) = address(coin).call(abi.encodeWithSignature("updateImage(string)", "ipfs://img"));
        (bool ok2,) = address(coin).call(abi.encodeWithSignature("updateDescription(string)", "{}"));
        vm.stopPrank();
        assertTrue(ok1 && ok2, "the admin updates the coin");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), row);
        assertFalse(_warnClean(imageRow));
        assertFalse(_warnClean(descRow));
        coinFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        assertFalse(_warnClean("warn: coin: image equals the config"));
        assertFalse(_warnClean("warn: coin: description equals the config"));
    }

    /// preflight: both fields inside the coin caps (2048 and 4096 bytes), filled (not empty or spaces only) and free of `placeholder` in any letter case and not `todo` or `tbd` as the whole value (a failure on chain id 1, a warning elsewhere)
    function test_preflightImageAndDescription() public {
        address d2 = _funded();
        string memory cap = "rule: image at most 2048 bytes, description at most 4096 bytes";
        string memory filled = "rule: image and description are filled and are not placeholders";
        // the factory enforces the same caps, so its simulated launch fails with the rule row
        string memory both = string.concat(cap, ", factory: deployTokenAsOwner accepts the config (simulated)");
        _pre(lc, d2);
        assertTrue(_warnClean(cap) && _warnClean(filled), "filled and inside the caps");

        // chain id 1: an empty value or a marker fails the row
        LaunchConfig memory c = lc;
        c.image = "";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "an empty image fails");
        c = lc;
        c.description = "";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "an empty description fails");
        c.image = "";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "both empty fails");
        assertTrue(_warnClean(cap));
        c = lc;
        c.image = "ipfs://PLACEHOLDER-cc-image";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a placeholder image fails");
        c = lc;
        c.description = "a PLACEHOLDER description";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a placeholder description fails");
        // spaces only counts as empty
        c = lc;
        c.image = " ";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a single space image fails");
        c = lc;
        c.description = "   ";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a spaces only description fails");
        // `placeholder` matches inside a value in any letter case, `todo` and `tbd` match the whole trimmed value
        string[6] memory marked = ["ipfs://placeholder", "ipfs://PlaceHolder-1", "TODO", " todo ", "tbd", "TBD"];
        for (uint256 i; i < marked.length; ++i) {
            c = lc;
            c.image = marked[i];
            _pre(c, d2);
            assertEq(_failedNames(), filled, string.concat("a marked image fails: ", marked[i]));
            c = lc;
            c.description = marked[i];
            _pre(c, d2);
            assertEq(_failedNames(), filled, string.concat("a marked description fails: ", marked[i]));
        }
        // real looking values pass, with spaces inside the text
        c = lc;
        c.image = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        c.description = "Credits engine coin. The pot buys credits at the bid.";
        _pre(c, d2);
        assertEq(_failedNames(), "", "real looking values pass");
        // a cid or a description that holds the letters of a short marker passes
        c = lc;
        c.image = "ipfs://bafybeitbdtodoabcdefghijklmnopqrstuvwxyz234567abcdefghij";
        c.description = "todo list of the engine: tbd later";
        _pre(c, d2);
        assertEq(_failedNames(), "", "short markers inside a value pass");

        // the same rule, checked directly through the shared helper (the full preflight above exercises it end to end).
        // a value that trims to nothing by a tab, a newline or NBSP counts as empty
        string memory okDesc = "Credits engine coin.";
        string memory okImage = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        string[3] memory whitespace = ["\n", "\t", unicode" "];
        for (uint256 i; i < whitespace.length; ++i) {
            assertFalse(metadataRowPasses(whitespace[i], okDesc), "a whitespace only image fails");
            assertFalse(metadataRowPasses(okImage, whitespace[i]), "a whitespace only description fails");
        }
        // the image must carry a scheme with content past it: a bare scheme or a value without one fails
        string[4] memory badScheme =
            ["bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", "ipfs://", "https://", "ar://"];
        for (uint256 i; i < badScheme.length; ++i) {
            assertFalse(metadataRowPasses(badScheme[i], okDesc), string.concat("an image without a scheme and content fails: ", badScheme[i]));
        }
        // an ipfs, https or ar image with content, and a plain description, pass; a scheme on the description is not required
        assertTrue(metadataRowPasses(okImage, okDesc), "an ipfs image passes");
        assertTrue(metadataRowPasses("https://example.com/cc.png", okDesc), "an https image passes");
        assertTrue(metadataRowPasses("ar://abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI", okDesc), "an ar image passes");
        // the scheme is matched on the raw bytes that go on chain: an upper case scheme or surrounding whitespace fails,
        // an onchain data uri passes, http is refused
        assertFalse(metadataRowPasses("IPFS://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", okDesc), "an upper case scheme fails");
        assertFalse(metadataRowPasses("  ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", okDesc), "leading whitespace before the scheme fails");
        assertFalse(metadataRowPasses("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi  ", okDesc), "trailing whitespace fails");
        assertTrue(metadataRowPasses("data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", okDesc), "a data uri passes");
        assertFalse(metadataRowPasses("http://example.com/cc.png", okDesc), "an http image fails");

        // another chain id: the row warns and never fails (the chain id row fails there)
        vm.chainId(11155111);
        c = lc;
        c.image = "";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "an empty image warns off mainnet");
        assertTrue(bytes(_failedNames()).length != 0, "the chain id row fails");
        c = lc;
        c.description = "PLACEHOLDER";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "a placeholder warns off mainnet");
        c = lc;
        c.image = " ";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "a blank image warns off mainnet");
        c = lc;
        c.description = "todo";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "a todo warns off mainnet");
        c = lc;
        c.image = "TBD";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "a tbd warns off mainnet");
        (string memory list,) = _failed();
        assertFalse(vm.contains(list, filled), "the row is not a failure off mainnet");
        vm.chainId(1);

        c = lc;
        // the image fills the cap with a scheme and content past it, the description fills its cap with plain text
        c.image = string.concat("ipfs://", _bytesOf(MAX_IMAGE_BYTES - 7));
        c.description = _bytesOf(MAX_DESCRIPTION_BYTES);
        _pre(c, d2);
        assertEq(_failedNames(), "", "both at the cap pass");
        c.image = string.concat("ipfs://", _bytesOf(MAX_IMAGE_BYTES + 1 - 7));
        _pre(c, d2);
        assertEq(_failedNames(), both, "an image above the cap fails");
        c.image = lc.image;
        c.description = _bytesOf(MAX_DESCRIPTION_BYTES + 1);
        _pre(c, d2);
        assertEq(_failedNames(), both, "a description above the cap fails");
    }

    function _bytesOf(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    /// the config parser reads `image` and `description` as strings
    function test_jsonParsesImageAndDescription() public view {
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        j = vm.replace(j, '"image": ""', '"image": "ipfs://cid/cc.png"');
        j = vm.replace(j, '"description": ""', '"description": "the CC coin"');
        LaunchConfig memory c = parseConfig(j);
        assertEq(c.image, "ipfs://cid/cc.png");
        assertEq(c.description, "the CC coin");
    }

    function test_configSupplyMatchesCoinSupply() public view {
        assertEq(COIN_SUPPLY, lc.supply);
    }

    /// the verification arguments built from the config and the first controller are the arguments the core was built with
    function test_coreConstructorArgsReadBack() public view {
        (address first, bool found) = firstController(address(core), owner);
        assertTrue(found);
        assertEq(first, address(ctl), "the first controller is found from the deployer nonce");
        assertEq(
            coreConstructorArgs(core, lc, first),
            abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings, lc.credit),
            "etherscan constructor args"
        );
    }

    function test_postflightCatchesEveryMismatch() public {
        LaunchConfig memory c = lc;
        c.rateStart = lc.rateStart + 1;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: RATE_START");

        c = lc;
        c.owner = creator;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: owner, coin: admin is the config owner, router: owner is the config owner");

        c = lc;
        c.bountyBps = 8000;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "hook: skim config equals the config");

        c = lc;
        c.stack.escrow = address(0xE5C);
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: escrow, code: stack addresses, factory: deploymentInfo names the coin, hook, locker, mev module, escrow and pool of the config, coin: allowlist holds the locker, the escrow and the config entries, coin: the locker and the escrow are pinned");

        postflightAs(lc, address(0xBEEF), owner);
        assertEq(_failedNames(), "code: core");
    }

    /// the two json files collapsed into one: the settings block is inside the hash, and so is the stack
    function test_hashCoversSettingsAndStack() public view {
        bytes32 h = configHash(lc);
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            assertTrue(configHash(c) != h, "a settings field is outside the hash");
        }
        LaunchConfig memory a = lc;
        a.stack.hook = address(0xA11CE);
        assertTrue(configHash(a) != h, "the stack is outside the hash");
        a = lc;
        a.image = string.concat(lc.image, "x");
        assertTrue(configHash(a) != h, "the image is outside the hash");
        a = lc;
        a.description = string.concat(lc.description, "x");
        assertTrue(configHash(a) != h, "the description is outside the hash");
    }

    // ------------------------------------------------------------------ settings

    /// the bounds of the preflight rows and of the deploy guard are the Core's: every field, both edges
    function test_settingsBoundsEveryFieldBothEdges() public view {
        uint256[23] memory lo = SettingsFields.lo();
        uint256[23] memory hi = SettingsFields.hi();
        bytes32[23] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // the top itself (the fields bound by another field start from a free partner)
            // feeToBuybackBps at its top needs feeToRedeemBurnBps at zero to keep the sum at 10_000
            if (i == 21) s.feeToRedeemBurnBps = 0;
            // climbPerMinBps at its top needs recoveryClimbPerMinBps raised to stay at or above it
            if (i == 2) s.recoveryClimbPerMinBps = 1_000;
            SettingsFields.set(s, i, hi[i]);
            assertEq(SettingsBounds.firstViolation(s), bytes32(0), "the top edge is inside");
            s = Mainnet.defaultSettings();
            if (i == 21) s.feeToRedeemBurnBps = 0;
            SettingsFields.set(s, i, hi[i] + 1);
            assertEq(SettingsBounds.firstViolation(s), names[i], "above the top");
            // below the bottom, for the fields that have one
            if (lo[i] == 0) continue;
            s = Mainnet.defaultSettings();
            SettingsFields.set(s, i, lo[i] - 1);
            assertEq(SettingsBounds.firstViolation(s), names[i], "below the bottom");
        }
    }

    /// preflight names the failing settings row, the deploy guard refuses, postflight reads each field back
    function test_settingsRowsAndGuard() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.settings.saleFloorBps = 999;
        _pre(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.feeToBuybackBps = 9_500;
        c.settings.feeToRedeemBurnBps = 1_000;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.dropFloorBps = 4_999;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        // the sale settings of the controller have their own row and guard
        c = lc;
        c.sale.floorBps = 10_001;
        _pre(c, d2);
        assertEq(_failedNames(), "sale settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "sale"));
        this.requireExt(c);
    }

    function test_postflightReadsBackEverySetting() public {
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            postflightAs(c, address(core), owner);
            assertEq(_failedNames(), "core: settings equal the config", "a settings field slipped the readback");
        }
    }

    /// after the owner changed the settings, postflight fails until the operator says so with SETTINGS_CHANGED=1
    function test_postflightAfterTheOwnerChangedTheSettings() public {
        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        _setSettings(s);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "core: settings equal the config");
        changedFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "SETTINGS_CHANGED turns the row into a warning");
    }

    /// sales are open after a launch. paused sales fail the row until the operator says the owner changed the state since launch
    function test_postflightWhileSalesArePaused() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        assertTrue(_warnClean("core: not paused"), "the row exists and passes on a fresh launch");
        vm.prank(owner);
        core.setPaused(true);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "core: not paused");
        assertEq(_rowDetail("core: not paused"), "paused");
        changedFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "SETTINGS_CHANGED turns the row into a warning");
        assertFalse(_warnClean("warn: core is not paused"), "the warning row reports the pause");
    }

    /// NEXT 26: the owner account is an EIP 7702 delegation to Calibur with an empty key registry. each of the three
    /// rows fails alone for its own change of state
    function test_preflightPinsTheOwnerDelegation() public {
        address d2 = _funded();
        string memory codeRow = "owner: code is the pinned EIP 7702 delegation";
        string memory hashRow = "owner: delegate code hash is the pinned Calibur";
        string memory keyRow = "owner: no registered keys";
        assertEq(lc.owner.code, OWNER_DELEGATION_CODE, "the fork owner holds the pinned delegation");
        assertEq(OWNER_DELEGATE.codehash, OWNER_DELEGATE_CODEHASH, "the fork delegate holds the pinned code");
        _pre(lc, d2);
        assertEq(_failedNames(), "");
        assertTrue(_warnClean(codeRow) && _warnClean(hashRow) && _warnClean(keyRow), "the three rows exist and pass");
        // the delegate code changes by one byte
        uint256 snap = vm.snapshotState();
        vm.etch(OWNER_DELEGATE, abi.encodePacked(OWNER_DELEGATE.code, hex"00"));
        _pre(lc, d2);
        assertEq(_failedNames(), hashRow);
        vm.revertToState(snap);
        // a key is registered on the owner
        vm.mockCall(lc.owner, abi.encodeWithSignature("keyCount()"), abi.encode(uint256(1)));
        _pre(lc, d2);
        assertEq(_failedNames(), keyRow);
        assertEq(_rowDetail(keyRow), "keyCount 1");
        vm.clearMockedCalls();
        // the owner delegates to another address: the code row fails, and the key registry of that address is empty
        vm.etch(lc.owner, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        _pre(lc, d2);
        assertEq(_failedNames(), string.concat(codeRow, ", ", keyRow));
        vm.revertToState(snap);
        // the owner is a plain account
        vm.etch(lc.owner, "");
        _pre(lc, d2);
        assertEq(_failedNames(), string.concat(codeRow, ", ", keyRow));
    }

    /// FLOW decisions 46 and 69: preflight fails unless `settings.rateCap` is 3 times `rateStart`. the Core and the deploy guard
    /// accept other ratios, so only this row stops a `rateStart` edit that leaves the old cap
    function test_preflightRateCapIsThreeTimesRateStart() public {
        string memory row = "rateCap is 3 times rateStart";
        address d2 = _funded();
        LaunchConfig memory shipped = _shipped();
        assertEq(shipped.settings.rateCap, 3 * shipped.rateStart, "the shipped file holds the ratio");
        assertEq(shipped.settings.rateCap, 2.67e16, "decision 69 opening cap");
        // the fixture opens at 1.732e15 under the launch cap: the row passes once the start is a third of the cap
        LaunchConfig memory c = lc;
        c.rateStart = c.settings.rateCap / 3;
        preflight(c, d2);
        assertTrue(_warnClean(row), "3 times passes the row");
        assertEq(_failedNames(), "");
        // rateStart changed, rateCap unchanged: the bounds row still passes, only the ratio row fails
        c.rateStart = c.rateStart / 2;
        assertTrue(rateInBounds(c), "inside the rate bounds");
        preflight(c, d2);
        assertEq(_failedNames(), row);
        assertEq(
            _rowDetail(row),
            string.concat(
                "rateStart ", vm.toString(c.rateStart), " rateCap ", vm.toString(c.settings.rateCap), " ratio x10000 60000"
            )
        );
        // rateCap changed, rateStart unchanged
        c.rateStart = lc.settings.rateCap / 3;
        c.settings.rateCap += 1;
        preflight(c, d2);
        assertEq(_failedNames(), row);
    }

    /// the rate bounds rows fail on their own: a 3 times pair keeps the ratio row passing while rateStart or rateCap is
    /// out of its bounds. rateStart bounds are 1e13 to 1e18 and the settings accept the same range for rateCap, so a
    /// 3 times pair has a rateStart inside its bounds only up to 3.33e17
    function test_preflightRateBoundsFailWithoutTheRatioRow() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        // rateStart 1e13 - 1 is below the minimum, 3 times it is inside the settings bounds for rateCap
        c.rateStart = 1e13 - 1;
        c.settings.rateCap = uint64(3 * c.rateStart);
        preflight(c, d2);
        assertEq(_failedNames(), "rateStart in bounds and at most rateCap");
        assertTrue(_warnClean("rateCap is 3 times rateStart"), "the ratio row passes");
        // rateStart 3.4e17 is inside its bounds, 3 times it is 1.02e18, above the settings bound for rateCap
        c.rateStart = 3.4e17;
        c.settings.rateCap = uint64(3 * c.rateStart);
        assertTrue(rateInBounds(c), "rateStart bounds row passes");
        preflight(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        assertTrue(_warnClean("rateCap is 3 times rateStart"), "the ratio row passes");
    }

    /// @dev preflight of a config whose opening bid is the fixture's: the fixture opens at 1.732e15 under the launch cap, a
    /// ratio of about 51, so the start is read as a third of the cap while the row is not under test. a start that a test
    /// sets itself is passed through
    function _pre(LaunchConfig memory c, address who) internal {
        uint256 start = c.rateStart;
        if (start == lc.rateStart) c.rateStart = c.settings.rateCap / 3;
        preflight(c, who);
        c.rateStart = start;
    }
}
