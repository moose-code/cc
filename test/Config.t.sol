// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Mainnet, Settings, ICreditStrategy} from "../src/interfaces/Interfaces.sol";
import {ISeaportBasicAdapter} from "../src/interfaces/ISeaportBasicAdapter.sol";
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
import {StandinRenderer} from "./standins/StandinRenderer.sol";

/// @notice the live-state and settings-bounds checks of the config suite, bound to the live system on the fork. the
/// named listings read the live CreditStrategy inventory at the pin, and the two bounds cases exercise the Core's own
/// SettingsBounds guard. none assumes a fresh launch, so none needs the fresh deploy
contract ConfigTest is LiveFixture {
    // promise: TEST FIXTURE the three named listings are held and priced by the CreditStrategy at the fork block
    /// the suites buy `LISTED_A`, `LISTED_B` and `LISTED_C` from the strategy by id; a listing that sold or left makes the
    /// ids need a refresh
    function test_namedListingsAreHeldAndPriced() public view {
        uint256[3] memory listed = [LISTED_A, LISTED_B, LISTED_C];
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(listed[i]), STRATEGY, "a named listing left the strategy");
            assertGt(ICreditStrategy(STRATEGY).nftForSale(listed[i]), 0, "a named listing is not for sale");
        }
    }

    /// the preflight and deploy guard use the Core's field bounds; dependent BALANCE bounds have separate cases
    // promise: each independently viable field edge is accepted and every representable out-of-range edge is refused
    function test_settingsBoundsFieldsAndViableEdges() public view {
        uint256[39] memory lo = SettingsFields.lo();
        uint256[39] memory hi = SettingsFields.hi();
        bytes32[39] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            for (uint256 edge; edge < 2; ++edge) {
                Settings memory s = Mainnet.defaultSettings();
                uint256 v = edge == 0 ? lo[i] : hi[i];
                if (i == 2) s.recoveryClimbPerMinBps = type(uint16).max;
                if (i == 7 && edge == 0) s.climbPerMinBps = 1;
                if (i == 16) (s.keeperFee, s.keeperMaxBaseFee) = (0, 0);
                if (i == 17 || i == 18) s.buybackSlice = type(uint128).max;
                if (i == 26) s.saleToOperatorBps = 0;
                if (i == 27) s.saleToArtistBps = 0;
                if (i == 13 && edge == 1) continue; // zero redemption proceeds cannot cover a nonzero BALANCE bid
                if (i == 37 && edge == 1) s.balanceDiscountBps = 1_100;
                if (i == 38 && edge == 0) (s.buyToArtistBps, s.redeemSlippageBps) = (0, 0);
                SettingsFields.set(s, i, v);
                assertEq(SettingsBounds.firstViolation(s), bytes32(0), "inclusive bound accepted");
            }
            if (i == 11 || i == 12) continue;
            Settings memory s = Mainnet.defaultSettings();
            SettingsFields.set(s, i, hi[i] + 1);
            if (SettingsFields.get(s, i) == hi[i] + 1) {
                if (i == 26) s.saleToOperatorBps = 0;
                if (i == 27) s.saleToArtistBps = 0;
                bytes32 field = i == 26 ? bytes32("saleToOperatorBps") : names[i];
                assertEq(SettingsBounds.firstViolation(s), field, "above the bound");
            }
            if (lo[i] == 0) continue;
            s = Mainnet.defaultSettings();
            SettingsFields.set(s, i, lo[i] - 1);
            assertEq(SettingsBounds.firstViolation(s), names[i], "below the bound");
        }
    }

    // promise: a BALANCE purchase cannot cost more with its artist royalty than the smallest accepted redemption
    function test_balanceDiscountCoversRoyaltyAndRedemptionShortfall() public pure {
        Settings memory s = Mainnet.defaultSettings();
        s.balanceDiscountBps = 439;
        assertEq(
            SettingsBounds.firstViolation(s),
            bytes32("balanceDiscountBps"),
            "439 bps misses 250 royalty and 200 shortfall"
        );
        s.balanceDiscountBps = 440;
        assertEq(SettingsBounds.firstViolation(s), bytes32(0), "440 bps covers the launch royalty and shortfall");
        s.buyToArtistBps = 1_000;
        s.balanceDiscountBps = 1_090;
        assertEq(
            SettingsBounds.firstViolation(s), bytes32("balanceDiscountBps"), "higher royalty raises the discount floor"
        );
        s.balanceDiscountBps = 1_091;
        assertEq(SettingsBounds.firstViolation(s), bytes32(0), "the exact higher-royalty boundary passes");
        s.buyToArtistBps = 0;
        s.redeemSlippageBps = 0;
        s.balanceDiscountBps = 0;
        assertEq(SettingsBounds.firstViolation(s), bytes32(0), "zero royalty and shortfall allow par");
        s.redeemSlippageBps = 10_000;
        s.balanceDiscountBps = 9_999;
        assertEq(SettingsBounds.firstViolation(s), bytes32("balanceDiscountBps"), "zero proceeds cannot cover a bid");
    }
}

/// @notice the launch config, the placeholder guard, the preflight and the postflight on the pinned fork. every test
/// here verifies a FRESH deploy against its own config and the shipped json (predictCoin, deploySystem, configHash,
/// buildConfig, the renderer and the stack wiring at deploy), which the already-live Core cannot reproduce, so they
/// stay on the fresh Fixture
contract ConfigDeployTest is Fixture {
    string internal constant LAUNCH_DESCRIPTION =
        "$CC trades fill the pot. the pot buys Credits, priced by rating. every 80 become a statement, which sells to refill the pot.";

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
    /// payee, the artist) and the salt, keccak256 of "CC", and the live v2 stack of script/config/v2-mainnet.json
    // promise: json equals default config
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
        d.artist = f.artist;
        d.payee = v2.owner;
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
        assertEq(f.artist, 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a, "the launch artist address (decision 123)");
        assertEq(f.name, "CC");
        assertEq(f.symbol, "CC");
        assertEq(f.description, LAUNCH_DESCRIPTION, "launch coin description");
        assertEq(f.salt, keccak256("CC"));
        assertEq(f.rateStart, 5_600_000_000_000_000);
        assertEq(f.supply, 1_000_000_000e18);
        Settings memory expectedSettings = Mainnet.defaultSettings();
        expectedSettings.rateCap = 16_800_000_000_000_000;
        assertEq(abi.encode(f.settings), abi.encode(expectedSettings), "settings block is the launch values");
        // the launch values of docs/DECISIONS.md 10.1 and 10.6, the fee split of decision 186
        assertEq(f.baselineSkimBps, 690);
        assertEq(f.bountyBps, 9_000);
        assertEq(f.sniperStartBps, 6_900);
        assertEq(f.sniperSeconds, 4140);
        assertTrue(f.restricted);
        assertEq(f.allowed.length, 0);
        assertEq(f.settings.payeePpm, 0);
        // the owner's launch values of decision 119
        assertTrue(f.credit.saleOn);
        assertEq(f.settings.saleToBuybackBps, 2_500);
        assertEq(f.settings.swapFeeCc, 10_000e18);
        assertEq(f.settings.keeperFee, 0.0003 ether);
        assertEq(f.settings.keeperMaxBaseFee, 5 gwei);
        assertTrue(f.settings.redeemOn);
        assertEq(f.settings.balanceBidMarginBps, 1_000);
        assertEq(SettingsFields.N, 39);
        assertEq(abi.encode(f.settings).length, 39 * 32);
        assertEq(f.settings.spendCapBps, 10_000);
        assertEq(f.settings.bucketSeconds, 60);
        assertEq(f.settings.balanceBidCapBps, 10_000);
        assertEq(f.settings.idleStepSeconds, 600);
        assertEq(f.settings.sniperSeconds, 4140);
        assertEq(f.settings.reserveWei, 0.1 ether);
        assertEq(f.settings.returnLockSeconds, 21_600);
        assertEq(f.credit.spreadBps, 1_000);
        assertFalse(f.settings.valueModeOn);
        assertEq(abi.encode(f.quote), abi.encode(Mainnet.defaultQuote()), "the quote block is the launch quote");
        assertEq(f.quote.tolBps, 100);
        assertEq(f.quote.referenceMaxStale, 0);
        assertEq(f.sale.anchorMoveBps, 0);
        assertEq(f.payee, v2.owner);
        // the stack addresses of the shipped file are the record of the live stack, the factory owner is the config owner
        assertEq(unsetFields(f).length, 0, "the shipped file leaves nothing unset");
        assertEq(live.owner, f.owner, "the factory owner of the record is the config owner");
        assertEq(live.owner, FACTORY.owner(), "and the owner on chain");
    }

    function requireExt(LaunchConfig memory c) external pure {
        _requireConfig(c);
    }

    /// the launch fee split derived from the v2 hook math (`ArtCoinsHookV2._split`), per 1 ether of volume. all rates in bps
    /// of volume (decision 186). baseline skim 690 bps, skim = V * 690 / 10_000 = 0.069 ether.
    /// bounty leg = skim * bountyBps / 10_000, protocol leg = skim - bounty leg (steady state, no referral).
    /// the protocol keeps 10 percent of the skim: bountyBps 9_000 gives 690 * 1000 / 10_000 = 69 bps (0.69 percent), the
    /// protocol share is 10_000 - bountyBps of the baseline skim, no factory floor sets it on master. Core inflow =
    /// bounty leg = 0.069 * 9_000 / 10_000 = 0.0621 ether (621 bps, 6.21 percent). payeePpm is 0
    /// at launch, so the engine keeps the whole Core inflow
    // promise: the launch fee split derived from the v2 hook math (`ArtCoinsHookV2._split`), per 1 ether of volume
    function test_feeSplitDerivation() public pure {
        LaunchConfig memory d = defaultConfig();
        uint256 v = 1 ether;
        uint256 skim = v * d.baselineSkimBps / 10_000;
        assertEq(skim, 0.069 ether);
        uint256 inflow = skim * d.bountyBps / 10_000;
        uint256 protocol = skim - inflow;
        assertEq(inflow, 62_100_000_000_000_000, "Core inflow 6.21 percent");
        assertEq(protocol, 6_900_000_000_000_000, "protocol leg 0.69 percent");
        assertEq(10_000 - uint256(d.bountyBps), 1000, "the protocol share of the baseline skim");
        // the payee share is 0 at launch, so the engine keeps the whole Core inflow
        assertEq(d.settings.payeePpm, 0, "payeePpm 0 at launch");
        uint256 payee = inflow * d.settings.payeePpm / 1e6;
        assertEq(payee, 0, "no payee share at launch");
        assertEq(inflow - payee, 62_100_000_000_000_000, "engine 6.21 percent");
    }

    /// the deploy refuses to run while any placeholder is unset or the rate is out of bounds
    // promise: the deploy refuses to run while any placeholder is unset or the rate is out of bounds
    function test_deployRefusesPlaceholders() public {
        LaunchConfig memory c = defaultConfig();
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "owner"));
        this.requireExt(c);
        c.owner = owner;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "creator"));
        this.requireExt(c);
        c.creator = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "artist"));
        this.requireExt(c);
        c.artist = creator;
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
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "payee.address"));
        this.requireExt(c);
        c.payee = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.hook"));
        this.requireExt(c);
        c.stack = lc.stack;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.mevModule"));
        this.requireExt(c);
        c.mevModule = lc.mevModule;
        this.requireExt(c);
        c.rateStart = 0;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
        c.rateStart = uint256(type(uint64).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
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

    // promise: preflight passes
    function test_preflightPasses() public {
        address d2 = _funded();
        _pre(lc, d2);
        assertEq(_failedNames(), "");
    }

    /// each pinned code hash has a row. appending one byte of code to a contract fails exactly its row
    // promise: each pinned code hash has a row
    function test_preflightPinsTheLiveCodeHashes() public {
        address d2 = _funded();
        address[9] memory at = [
            lc.stack.hook,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            lc.mevModule,
            v2.tokenDeployer,
            v2.allowlist,
            v2.controller,
            v2.burnRouter
        ];
        bytes32[9] memory want = [
            V2_CODEHASH_HOOK,
            V2_CODEHASH_FACTORY,
            V2_CODEHASH_LOCKER,
            V2_CODEHASH_ESCROW,
            V2_CODEHASH_MEV_MODULE,
            V2_CODEHASH_TOKEN_DEPLOYER,
            V2_CODEHASH_ALLOWLIST,
            V2_CODEHASH_FEE_CONTROLLER,
            V2_CODEHASH_BURN_ROUTER
        ];
        string[9] memory name = [
            "hook",
            "factory",
            "locker",
            "escrow",
            "mev module",
            "token deployer",
            "extension allowlist",
            "protocol fee controller",
            "burn router"
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

    // promise: preflight simulates the launch and leaves no trace
    function test_preflightSimulatesTheLaunchAndLeavesNoTrace() public {
        address d2 = _funded();
        uint256 nonce = vm.getNonce(d2);
        uint256 bal = d2.balance;
        _pre(lc, d2);
        assertEq(vm.getNonce(d2), nonce, "the simulation is reverted");
        assertEq(d2.balance, bal);
        assertTrue(bytes(_rowDetail("factory: deployToken accepts the config (simulated)")).length > 10);
    }

    /// owner and creator may be one address, a warning and never a failure. a stack address as owner or creator fails
    // promise: owner and creator may be one address, a warning and never a failure
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
        // creator is not a pool recipient on master, so a stack creator fails only the people rule, not the launch
        assertEq(_failedNames(), "rule: owner, creator and payee are not dead or stack addresses");
        c = lc;
        c.payee = c.stack.escrow;
        _pre(c, d2);
        // the payee share and the operator cut are forced pushes (decision 123), so the preflight no longer probes the
        // payee for an eth call; only the dead-or-stack-address rule fails for a stack payee
        assertEq(_failedNames(), "rule: owner, creator and payee are not dead or stack addresses");
    }

    // promise: preflight seaport recipients
    function test_preflightSeaportRecipients() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        address ok = makeAddr("seaport recipient");
        c.seaportRecipients = new address[](2);
        c.seaportRecipients[0] = ok;
        c.seaportRecipients[1] = makeAddr("second seaport recipient");
        _pre(c, d2);
        assertEq(_failedNames(), "", "two distinct plain recipients pass");
        c.seaportRecipients = new address[](0);
        _pre(c, d2);
        assertEq(_failedNames(), "seaport recipients: at least one");
        c.seaportRecipients = new address[](1);
        _pre(c, d2);
        assertEq(_failedNames(), "seaport recipients: none is the zero address");
        c.seaportRecipients = new address[](2);
        c.seaportRecipients[0] = ok;
        c.seaportRecipients[1] = ok;
        _pre(c, d2);
        assertEq(_failedNames(), "seaport recipients: no duplicates");
        address[3] memory system = [c.owner, c.payee, c.stack.factory];
        for (uint256 i; i < system.length; ++i) {
            c.seaportRecipients = new address[](1);
            c.seaportRecipients[0] = system[i];
            _pre(c, d2);
            assertEq(
                _failedNames(), "seaport recipients: none is the Core, controller, owner, payee or a stack address"
            );
        }
        // the Core address depends on the opening rate and the salt `_pre` substitutes
        c.rateStart = c.settings.rateCap / 3;
        c.seaportRecipients = new address[](1);
        bytes32 salt = c.salt;
        c.salt = keccak256(abi.encode(salt, "preflight"));
        c.seaportRecipients[0] = coreAddress(c, d2);
        c.salt = salt;
        _pre(c, d2);
        assertEq(
            _failedNames(),
            "seaport recipients: none is the Core, controller, owner, payee or a stack address",
            "the predicted Core"
        );
    }

    // ------------------------------------------------------------------ the owner commands the launch needs on v2

    // promise: preflight the factory must be deprecated and owned by the deployer
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
        assertEq(list, "factory: owner is the deployer, factory: deployToken accepts the config (simulated)");
    }

    // promise: preflight enabled stack
    function test_preflightEnabledStack() public {
        address d2 = _funded();
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: hook enabled, factory: deployToken accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, true);
        FACTORY.setLocker(lc.stack.locker, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: locker enabled, factory: deployToken accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setLocker(lc.stack.locker, true);
        FACTORY.setMevModule(lc.mevModule, false);
        vm.stopPrank();
        _pre(lc, d2);
        assertEq(_failedNames(), "factory: mev module enabled, factory: deployToken accepts the config (simulated)");
    }

    // promise: postflight checks the adapters
    function test_postflightChecksTheAdapters() public {
        assertEq(seaportAdapter, seaportAdapterAddress(address(core), lc.seaportRecipients), "CREATE2 address");
        assertEq(strategyAdapter, strategyAdapterAddress(), "CREATE2 address");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "the adapters of the deploy pass");

        // an adapter the owner removed
        vm.prank(owner);
        core.removeAdapter(strategyAdapter);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "adapters: both are allowed in the Core");
        vm.prank(owner);
        core.addAdapter(strategyAdapter);

        // an allowlist that differs from the config
        vm.prank(owner);
        ISeaportBasicAdapter(seaportAdapter).setAllowedRecipient(Mainnet.OPENSEA_FEE_COLLECTOR, false);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "adapters: seaport recipients are the config allowlist");
        vm.prank(owner);
        ISeaportBasicAdapter(seaportAdapter).setAllowedRecipient(Mainnet.OPENSEA_FEE_COLLECTOR, true);

        // other bytecode at the CREATE2 address of the strategy adapter
        bytes memory code = strategyAdapter.code;
        vm.etch(strategyAdapter, hex"6000");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "adapters: runtime code is the compiled adapters (immutables masked)");
        vm.etch(strategyAdapter, code);

        // a missing adapter fails the code row, and the lock is a launch state row
        vm.etch(strategyAdapter, "");
        postflightAs(lc, address(core), owner);
        assertEq(
            _failedNames(),
            "code: strategy adapter, adapters: runtime code is the compiled adapters (immutables masked)"
        );
        vm.etch(strategyAdapter, code);
        vm.prank(owner);
        core.lockAdapters();
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "core: no locks, no balance module");
    }

    // promise: postflight passes on the fixture
    function test_postflightPassesOnTheFixture() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        // the same after trading started: the exact supply and rate rows turn tolerant, nothing fails
        _skipSniperWindow();
        _buyCoin(funder, 1 ether);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
    }

    /// V2R-5: the postflight compares the runtime code of the Core and of the controller with the compiled artifacts
    /// (immutables and the library address masked). one changed byte in either fails exactly its row
    // promise: postflight compares the core and controller runtime
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
    // promise: the coin's image and description are read back and compared with the config
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
        postflightAs(c, address(core), address(0));
        assertEq(_failedNames(), imageRow);
        c = lc;
        c.description = "other";
        postflightAs(c, address(core), address(0));
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

    /// the coin's renderer is the CoinRenderer of the config, bound to the Core, and `tokenURI()` answers. an admin
    /// replacement fails the renderer row until the operator names the change (COIN_CHANGED=1); a renderer that reverts
    /// fails the tokenURI row; a renderer bound to another address fails its Core row while the fixed logo still renders
    // promise: the postflight reads the coin renderer, its Core and the coin's tokenURI
    function test_FIXED_postflightReadsTheCoinRenderer() public {
        string memory rendererRow = "coin: metadata renderer is the CoinRenderer of the config";
        string memory uriRow = "coin: tokenURI returns a json data uri";
        string memory coreRow = "renderer: core is the Core";
        assertEq(coin.metadataRenderer(), rendererAddress(lc), "named by the launch");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "as launched");

        // the Core slot of the renderer is storage slot 0 (the owner is immutable)
        vm.store(rendererAddress(lc), bytes32(0), bytes32(uint256(uint160(address(0xBEEF)))));
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), coreRow, "a renderer bound to another address");
        vm.store(rendererAddress(lc), bytes32(0), bytes32(uint256(uint160(address(core)))));

        _setRenderer(address(new StandinRenderer(0)));
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), rendererRow, "a renderer the config does not name");
        _setRenderer(address(new StandinRenderer(1)));
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), string.concat(rendererRow, ", ", uriRow), "a reverting renderer");
        coinFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        assertFalse(_warnClean(string.concat("warn: ", uriRow)));
    }

    function _setRenderer(address r) internal {
        vm.prank(owner);
        (bool ok,) = address(coin).call(abi.encodeWithSignature("setMetadataRenderer(address)", r));
        assertTrue(ok, "the admin sets the renderer");
    }

    /// the token config names the CoinRenderer of the config: its address is a function of the owner and the salt,
    /// and the config holds no renderer field
    // promise: the token config names the CoinRenderer of the config
    function test_buildConfigNamesTheCoinRenderer() public view {
        assertEq(buildConfig(lc, lc.owner, address(0)).token.renderer, rendererAddress(lc));
        LaunchConfig memory c = lc;
        c.salt = keccak256("another salt");
        assertTrue(rendererAddress(c) != rendererAddress(lc), "another salt, another renderer");
        assertEq(buildConfig(c, c.owner, address(0)).token.renderer, rendererAddress(c));
        c = lc;
        c.rateStart += 1;
        assertEq(rendererAddress(c), rendererAddress(lc), "other fields do not move it");
    }

    /// a renderer with code at the predicted address fails the prediction row. a config with another salt predicts an empty
    /// address and passes, and the simulated launch finds the renderer code at the address the token config names
    // promise: preflight expects the predicted renderer address empty
    function test_preflightPredictedRendererIsEmpty() public {
        string memory row = "predicted renderer is empty";
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.rateStart = c.settings.rateCap / 3;
        preflight(c, d2);
        assertEq(_failedNames(), row, "the fixture deployed the renderer of this owner and salt");
        c.salt = keccak256("fresh salt");
        preflight(c, d2);
        assertEq(_failedNames(), "", "a fresh salt predicts an empty renderer and the simulated launch passes");
    }

    // preflight: image and description inside the coin caps (2048 and 4096 bytes), empty or filled, free of `placeholder` in any
    // letter case, not `todo` or `tbd` as the whole value, and the image carries a scheme (a failure on chain id 1, a
    // warning elsewhere). the rule is `metadataRowPasses`, shared with the rehearsal
    // promise: preflight image and description
    function test_preflightImageAndDescription() public {
        address d2 = _funded();
        string memory cap = "rule: image at most 2048 bytes, description at most 4096 bytes";
        string memory filled = METADATA_ROW;
        string memory both = string.concat(cap, ", factory: deployToken accepts the config (simulated)");
        _pre(lc, d2);
        assertTrue(_warnClean(cap) && _warnClean(filled), "filled and inside the caps");

        // chain id 1: an empty value or a marker fails the row
        LaunchConfig memory c = lc;
        c.image = "";
        _pre(c, d2);
        assertEq(_failedNames(), "", "an empty image passes: the coin renderer draws the image");
        c.image = " ";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a whitespace image fails");
        c = lc;
        c = lc;
        c.description = "a PLACEHOLDER description";
        _pre(c, d2);
        assertEq(_failedNames(), filled, "a placeholder description fails");

        // the rule through the shared helper
        string memory okDesc = "Credits engine coin.";
        string memory okImage = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        assertTrue(metadataRowPasses(okImage, okDesc));
        assertTrue(metadataRowPasses("", okDesc), "an empty image passes");
        assertTrue(metadataRowPasses(okImage, ""), "an empty description passes");
        assertTrue(metadataRowPasses("", ""), "both empty pass");
        string[7] memory blank = [" ", "   ", "\n", "\t", unicode" ", "TODO", " tbd "];
        for (uint256 i; i < blank.length; ++i) {
            assertFalse(metadataRowPasses(blank[i], okDesc), string.concat("image: ", blank[i]));
            assertFalse(metadataRowPasses(okImage, blank[i]), string.concat("description: ", blank[i]));
        }
        string[3] memory marked = ["ipfs://placeholder", "ipfs://PlaceHolder-1", "a PLACEHOLDER description"];
        for (uint256 i; i < marked.length; ++i) {
            assertFalse(metadataRowPasses(marked[i], okDesc), marked[i]);
            assertFalse(metadataRowPasses(okImage, marked[i]), marked[i]);
        }
        // a cid or a description that holds the letters of a short marker passes
        assertTrue(
            metadataRowPasses(
                "ipfs://bafybeitbdtodoabcdefghijklmnopqrstuvwxyz234567abcdefghij", "todo list of the engine: tbd later"
            )
        );
        // the image must carry a scheme with content past it, matched on the raw bytes that go on chain
        string[8] memory badScheme = [
            "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
            "ipfs://",
            "https://",
            "ar://",
            "IPFS://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
            "  ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi  ",
            "http://example.com/cc.png"
        ];
        for (uint256 i; i < badScheme.length; ++i) {
            assertFalse(metadataRowPasses(badScheme[i], okDesc), badScheme[i]);
        }
        assertTrue(metadataRowPasses("https://example.com/cc.png", okDesc));
        assertTrue(metadataRowPasses("ar://abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI", okDesc));
        assertTrue(metadataRowPasses("data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", okDesc));

        // another chain id: the row warns and never fails (the chain id row fails there)
        vm.chainId(11155111);
        c = lc;
        c.image = "ipfs://PLACEHOLDER";
        _pre(c, d2);
        assertFalse(_warnClean(filled), "a placeholder image warns off mainnet");
        (string memory list,) = _failed();
        assertFalse(vm.contains(list, filled), "the row is not a failure off mainnet");
        vm.chainId(1);

        // the caps: the factory enforces the same ones, so its simulated launch fails with the cap row
        c = lc;
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
    // promise: the config parser reads `image` and `description` as strings
    function test_jsonParsesImageAndDescription() public view {
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        j = vm.replace(j, '"image": ""', '"image": "ipfs://cid/cc.png"');
        j = vm.replace(j, string.concat('"description": "', LAUNCH_DESCRIPTION, '"'), '"description": "the CC coin"');
        LaunchConfig memory c = parseConfig(j);
        assertEq(c.image, "ipfs://cid/cc.png");
        assertEq(c.description, "the CC coin");
    }

    // promise: the readbacks name the affected rows, and the Core address still binds the constructor config
    function test_postflightCatchesEveryMismatch() public {
        string memory id = "core: address is the CREATE2 address of the config and the deployer";
        LaunchConfig memory c = lc;
        c.rateStart = lc.rateStart + 1;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), string.concat("core: opening rate equals the approved value, ", id));

        c = lc;
        c.owner = creator;
        postflightAs(c, address(core), address(0));
        assertEq(
            _failedNames(),
            "core: owner, coin: admin is the config owner, coin: metadata renderer is the CoinRenderer of the config"
        );

        c = lc;
        c.bountyBps = 8000;
        postflightAs(c, address(core), address(0));
        assertEq(_failedNames(), "hook: skim config equals the config");

        c = lc;
        c.stack.escrow = address(0xE5C);
        postflightAs(c, address(core), address(0));
        // the escrow is not on the coin allowlist on master, so only the Core immutable and the factory record fail
        assertEq(
            _failedNames(),
            "core: stack equals the config, factory: deploymentInfo names the coin, hook, locker, mev module, escrow and pool of the config"
        );

        postflightAs(lc, address(0xBEEF), owner);
        assertEq(_failedNames(), "code: core");
    }

    /// the two json files collapsed into one: the settings block is inside the hash, and so is the stack
    // promise: the two json files collapsed into one: the settings block is inside the hash, and so is the stack
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

    /// preflight names the failing settings row, the deploy guard refuses, postflight reads each field back
    // promise: preflight names the failing settings row, the deploy guard refuses, postflight reads each field back
    function test_settingsRowsAndGuard() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.settings.bucketSeconds = 0;
        _pre(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.feeToRedeemBurnBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.dropFloorBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        // the sale settings of the controller have their own row and guard
        c = lc;
        c.sale.decayHours = 0;
        _pre(c, d2);
        assertEq(_failedNames(), "sale settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "sale"));
        this.requireExt(c);
    }

    // promise: postflight reads back every setting without exhausting one test's memory on accumulated check logs
    function test_postflightReadsBackEverySettingFirstHalf() public {
        _checkSettingsReadback(0, SettingsFields.N / 2);
    }

    // promise: postflight reads back every setting without exhausting one test's memory on accumulated check logs
    function test_postflightReadsBackEverySettingSecondHalf() public {
        _checkSettingsReadback(SettingsFields.N / 2, SettingsFields.N);
    }

    function _checkSettingsReadback(uint256 begin, uint256 end) private {
        for (uint256 i = begin; i < end; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            postflightAs(c, address(core), address(0));
            assertEq(
                _failedNames(),
                "core: settings equal the approved launch values",
                "a settings field slipped the readback"
            );
        }
    }

    /// after the owner changed the settings, postflight fails until the operator says so with SETTINGS_CHANGED=1
    // promise: after the owner changed the settings, postflight fails until the operator says so with SETTINGS_CHANGED=1
    function test_postflightAfterTheOwnerChangedTheSettings() public {
        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        _setSettings(s);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "core: settings equal the approved launch values");
        changedFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "SETTINGS_CHANGED turns the row into a warning");
    }

    /// NEXT 26: the owner account is an EIP 7702 delegation to Calibur with an empty key registry. each of the three
    /// rows fails alone for its own change of state
    // promise: NEXT 26: the owner account is an EIP 7702 delegation to Calibur with an empty key registry
    function test_preflightPinsTheOwnerDelegation() public {
        // the pins are the mainnet owner's Calibur delegation. the master stack fork owner is an anvil account with no
        // delegation, so the preflight reports the owner as an info row and these pins have no fork coverage
        if (keccak256(bytes(vm.envOr("STACK", string("")))) == keccak256("master")) vm.skip(true);
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

    // promise: resuming a partial deploy rechecks the current owner delegation, delegate code and key registry
    function test_resumePreflightPinsTheOwnerDelegation() public {
        if (keccak256(bytes(vm.envOr("STACK", string("")))) == keccak256("master")) vm.skip(true);
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.rateStart = c.settings.rateCap / 3;
        c.salt = keccak256(abi.encode(c.salt, "resume preflight"));
        string memory codeRow = "owner: code is the pinned EIP 7702 delegation";
        string memory hashRow = "owner: delegate code hash is the pinned Calibur";
        string memory keyRow = "owner: no registered keys";

        preflightResume(c, d2);
        assertEq(_failedNames(), "", "an unchanged owner permits recovery");
        assertTrue(_warnClean(codeRow) && _warnClean(hashRow) && _warnClean(keyRow), "all owner rows run");

        uint256 snap = vm.snapshotState();
        vm.etch(c.owner, "");
        preflightResume(c, d2);
        assertEq(_failedNames(), string.concat(codeRow, ", ", keyRow), "lost delegation blocks recovery");
        vm.revertToState(snap);

        vm.etch(OWNER_DELEGATE, abi.encodePacked(OWNER_DELEGATE.code, hex"00"));
        preflightResume(c, d2);
        assertEq(_failedNames(), hashRow, "changed delegate code blocks recovery");
        vm.revertToState(snap);

        vm.mockCall(c.owner, abi.encodeWithSignature("keyCount()"), abi.encode(uint256(1)));
        preflightResume(c, d2);
        assertEq(_failedNames(), keyRow, "a registered key blocks recovery");
        vm.clearMockedCalls();
    }

    /// the Core payee window and the pool launch skim window are separate values that must start equal
    // promise: preflight fails unless settings.sniperSeconds equals launch.sniperSeconds
    function test_preflightSniperSecondsMatchTheCoreSetting() public {
        string memory row = "rule: settings.sniperSeconds equals launch.sniperSeconds";
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.salt = keccak256("preflight");
        c.rateStart = c.settings.rateCap / 3;
        preflight(c, d2);
        assertTrue(_warnClean(row), "equal values pass the row");
        c.settings.sniperSeconds = c.sniperSeconds + 1;
        preflight(c, d2);
        assertEq(_failedNames(), row);
    }

    // promise: decision 214 pins the 69 percent anti sniper start and 4140 second window at launch
    function test_preflightPinsAntiSniperSchedule() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.salt = keccak256("preflight-sniper");
        c.rateStart = c.settings.rateCap / 3;
        c.sniperStartBps = 6_800;
        preflight(c, d2);
        assertEq(_failedNames(), "rule: sniper start bps is 6900");

        c.sniperStartBps = 6_900;
        c.sniperSeconds = 3_000;
        c.settings.sniperSeconds = 3_000;
        preflight(c, d2);
        assertEq(_failedNames(), "rule: sniper seconds is 4140");
    }

    /// FLOW decisions 46 and 69: preflight fails unless `settings.rateCap` is 3 times `rateStart`. the Core and the deploy guard
    /// accept other ratios, so only this row stops a `rateStart` edit that leaves the old cap
    // promise: FLOW decisions 46 and 69: preflight fails unless `settings.rateCap` is 3 times `rateStart`
    function test_preflightRateCapIsThreeTimesRateStart() public {
        string memory row = "rateCap is 3 times rateStart";
        address d2 = _funded();
        LaunchConfig memory shipped = _shipped();
        assertEq(shipped.settings.rateCap, 3 * shipped.rateStart, "the shipped file holds the ratio");
        assertEq(shipped.settings.rateCap, 16_800_000_000_000_000, "launch opening cap");
        // the fixture opens at 1.732e15 under the launch cap: the row passes once the start is a third of the cap
        LaunchConfig memory c = lc;
        c.salt = keccak256("preflight");
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
                "rateStart ",
                vm.toString(c.rateStart),
                " rateCap ",
                vm.toString(c.settings.rateCap),
                " ratio x10000 60000"
            )
        );
        // rateCap changed, rateStart unchanged
        c.rateStart = lc.settings.rateCap / 3;
        c.settings.rateCap += 1;
        preflight(c, d2);
        assertEq(_failedNames(), row);
    }

    // promise: preflight rejects zero rateStart and accepts the full uint64 rate range
    function test_preflightRateBoundsRejectZeroAndAcceptTypedExtrema() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.salt = keccak256("preflight");
        c.rateStart = 0;
        c.settings.rateCap = 1;
        preflight(c, d2);
        assertFalse(_warnClean("rateStart in bounds and at most rateCap"), "zero rateStart fails the rate row");
        c.rateStart = uint256(type(uint64).max) + 1;
        c.settings.rateCap = type(uint64).max;
        assertFalse(rateInBounds(c), "rateStart cannot exceed its storage width");
        c.rateStart = 1;
        c.settings.rateCap = 3;
        assertTrue(rateInBounds(c), "one wei rateStart is valid");
        c.rateStart = type(uint64).max;
        c.settings.rateCap = type(uint64).max;
        assertTrue(rateInBounds(c), "uint64 max rateStart is valid");
    }

    /// @dev preflight of a config whose opening bid is the fixture's: the fixture opens at 1.732e15 under the launch cap, a
    /// ratio of about 51, so the start is read as a third of the cap while the row is not under test. a start that a test
    /// sets itself is passed through
    function _pre(LaunchConfig memory c, address who) internal {
        uint256 start = c.rateStart;
        bytes32 salt = c.salt;
        if (start == lc.rateStart) c.rateStart = c.settings.rateCap / 3;
        // the fixture deployed the renderer of `lc.salt`: another salt gives the predicted renderer an empty address
        c.salt = keccak256(abi.encode(salt, "preflight"));
        preflight(c, who);
        c.rateStart = start;
        c.salt = salt;
    }
}
