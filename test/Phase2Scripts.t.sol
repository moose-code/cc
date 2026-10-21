// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Report} from "../script/Report.sol";
import {Phase2Deploy} from "../script/Phase2Deploy.s.sol";
import {PushSplitCreator, ISplitFactoryV2, ISplitWalletV2, SplitConfig} from "../script/PushSplit.sol";
import {Phase2Readback} from "../script/Phase2Readback.s.sol";
import {Phase2Settings} from "../script/Phase2Settings.s.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";

/// @dev the deploy script with its environment replaced by arguments and `send` false
contract Phase2DeployProbe is Phase2Deploy {
    function deploy(Inputs memory i) external returns (Result memory) {
        return deployPhase2(i, false);
    }
}

/// @dev the readback rows on given addresses, returning the failed names instead of reverting
contract Phase2ReadbackProbe is Phase2Readback {
    bool internal acceptMargin_;

    function setAcceptMargin(bool v) external {
        acceptMargin_ = v;
    }

    function _acceptNonPositiveMargin() internal view override returns (bool) {
        return acceptMargin_;
    }

    function read(address core, address treasury, address controllerV2) external returns (string memory failed) {
        _reset();
        phase2Readback(core, treasury, controllerV2);
        (failed,) = _failed();
    }
}

/// @dev the settings script with its environment replaced by fields
contract Phase2SettingsProbe is Phase2Settings {
    address internal core_;
    address internal split_;
    string[] internal forced_;

    function configure(address core) external {
        core_ = core;
    }

    function setSplit(address split) external {
        split_ = split;
    }

    uint256 internal discount_ = 2_000;
    bool internal allowMargin_;

    function setDiscount(uint256 bps) external {
        discount_ = bps;
    }

    function setAllowMargin(bool v) external {
        allowMargin_ = v;
    }

    function _discountBps() internal view override returns (uint256) {
        return discount_;
    }

    function _allowNonPositiveMargin() internal view override returns (bool) {
        return allowMargin_;
    }

    function _split() internal view override returns (address) {
        return split_;
    }

    function force(string memory name) external {
        forced_.push(name);
    }

    function previewOn() external returns (Preview memory) {
        return preview(ICore(payable(core_)));
    }

    function applyAsOwner() external {
        ICore core = ICore(payable(core_));
        Preview memory p = preview(core);
        vm.startPrank(core.owner());
        applyPatch(core, p);
        vm.stopPrank();
    }

    function refuse() external view {
        _refuseOverrides();
    }

    function _core() internal view override returns (address) {
        return core_;
    }

    function _overrides() internal view override returns (string[] memory) {
        return forced_;
    }
}

/// @notice the phase 2 operator scripts on the pinned fork against the live Core, the live Statements and the live
/// BALANCE token: the stage A deploy and its readback, the readback refusals and the stage B settings patch. only the
/// treasury, policy, ControllerV2 and push split are created fresh. `test_deployRefusesAWrongBalanceToken` keeps the
/// stand in: it needs a token the treasury constructor would refuse, a gate the live token has already passed
contract Phase2ScriptsTest is LiveFixture {
    /// the Splits v2.2 pull factory, the one the splits.org form uses
    address internal constant PULL_FACTORY = 0x6B9118074aB15142d7524E8c4ea8f62A3Bdb98f1;
    Phase2DeployProbe internal deployProbe;
    Phase2ReadbackProbe internal readback;
    Phase2SettingsProbe internal settings;

    function setUp() public override {
        super.setUp();
        deployProbe = new Phase2DeployProbe();
        readback = new Phase2ReadbackProbe();
        settings = new Phase2SettingsProbe();
        settings.configure(address(core));
    }

    function _inputs() internal view returns (Phase2Deploy.Inputs memory) {
        return Phase2Deploy.Inputs({
            core: address(core),
            balanceToken: liveBalanceToken,
            statementSaleMultiplierBps: 15_000,
            statementRedeemDelaySeconds: 3_600,
            tokenCodehash: liveBalanceToken.codehash,
            allowUnpinnedToken: false,
            split: address(0),
            splitPlan: PushSplitCreator.SplitPlan({artist: core.artist(), operator: core.payee(), controller: owner})
        });
    }

    // promise: the deploy preview refuses an unpinned balance token unless the pin is waived explicitly, and refuses a pinned hash that does not match the live runtime
    function test_deployRequiresTheTokenRuntimePin() public {
        Phase2Deploy.Inputs memory i = _inputs();
        i.tokenCodehash = bytes32(0);
        vm.expectRevert();
        deployProbe.deploy(i);
        i.allowUnpinnedToken = true;
        deployProbe.deploy(i);
        i = _inputs();
        i.tokenCodehash = keccak256("another token");
        vm.expectRevert();
        deployProbe.deploy(i);
    }

    // promise: an environment integer above uint32 is refused instead of silently narrowed to other terms
    function test_deployRefusesNarrowedInputs() public {
        vm.setEnv("CORE", vm.toString(address(core)));
        vm.setEnv("BALANCE_TOKEN", vm.toString(liveBalanceToken));
        vm.setEnv("BALANCE_TOKEN_CODEHASH", vm.toString(liveBalanceToken.codehash));
        vm.setEnv("PHASE2_STATEMENT_MULTIPLIER_BPS", "4294977296");
        vm.expectRevert(abi.encodeWithSelector(Phase2Deploy.ValueTooWide.selector, "PHASE2_STATEMENT_MULTIPLIER_BPS"));
        deployProbe.run();
        vm.setEnv("PHASE2_STATEMENT_MULTIPLIER_BPS", "15000");
        vm.setEnv("PHASE2_STATEMENT_DELAY_SECONDS", "4294967297");
        vm.expectRevert(abi.encodeWithSelector(Phase2Deploy.ValueTooWide.selector, "PHASE2_STATEMENT_DELAY_SECONDS"));
        deployProbe.run();
        vm.setEnv("PHASE2_STATEMENT_DELAY_SECONDS", "3600");
        // a send needs the plan hash the preview printed
        vm.setEnv("SEND", "1");
        vm.expectRevert();
        deployProbe.run();
        vm.setEnv("SEND", "0");
    }

    // promise: PLAN section 8 stage A the deploy script creates the three contracts disabled, bound to the Core, with the live credit sale, and its readback passes; decision 255 the fourth creation is the push split with the Core's artist at 5/6, its payee at 1/6 and its owner as controller, not yet the Core's artist
    function test_deployCreatesTheDisabledStackAndReadbackPasses() public {
        Phase2Deploy.Inputs memory i = _inputs();
        Phase2Deploy.Result memory r = deployProbe.deploy(i);
        SplitConfig memory cfg = deployProbe.splitConfig(core.artist(), core.payee());
        assertEq(ISplitWalletV2(r.split).splitHash(), deployProbe.splitHashOf(cfg), "the split of decision 255");
        assertEq(ISplitWalletV2(r.split).owner(), owner, "the owner controls the split");
        assertTrue(core.artist() != r.split, "the split is not the artist before stage B");
        assertEq(i.splitPlan.artist, core.artist());
        assertTrue(core.artist() != core.payee(), "the split has distinct artist and operator recipients");
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(r.treasury);
        assertEq(t.core(), address(core));
        assertEq(t.ccToken(), core.COIN());
        assertEq(t.balanceToken(), liveBalanceToken);
        assertEq(t.predecessor(), address(0));
        assertEq(t.redemptionPolicy(), r.policy);
        assertEq(t.owner(), owner);
        assertFalse(t.conversionEnabled());
        assertFalse(t.workingPaymentsEnabled());
        assertFalse(t.ccRedemptionEnabled());
        assertEq(t.claimReserve(), 0);
        assertEq(t.available(), 0);
        assertFalse(t.conversionReady());
        assertFalse(t.selected());
        IControllerV2 c = IControllerV2(r.controllerV2);
        assertEq(c.CORE(), address(core));
        assertFalse(c.statementSalesEnabled());
        assertEq(c.statementSaleMultiplierBps(), 15_000);
        assertEq(c.statementRedeemDelaySeconds(), 3_600);
        assertEq(c.creditSaleOn(), ctl.creditSaleOn());
        assertEq(c.creditWindow(), ctl.creditWindow());
        assertEq(c.creditSpreadBps(), ctl.creditSpreadBps());
        assertEq(c.creditStartBps(), ctl.creditStartBps());
        assertFalse(c.balancePoolKeySet());
        assertEq(core.controller(), address(ctl), "the deploy changes nothing on the Core");
        assertEq(core.balanceModule(), address(0));
        // the live code equals out/, and out/ equals the pins of script/Checks.sol
        assertTrue(runtimeMatchesArtifact(r.policy, "ProRataRedemptionPolicy"));
        assertTrue(runtimeMatchesArtifact(r.treasury, "Phase2BalanceTreasury"));
        assertTrue(runtimeMatchesArtifact(r.controllerV2, "ControllerV2"));
        assertEq(artifactHash("ProRataRedemptionPolicy"), BUILD_HASH_PRO_RATA_POLICY);
        assertEq(artifactHash("Phase2BalanceTreasury"), BUILD_HASH_PHASE2_TREASURY);
        assertEq(artifactHash("ControllerV2"), BUILD_HASH_CONTROLLER_V2);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "the readback script passes");
        assertEq(readback.read(address(core), r.treasury, address(0)), "", "without the controller too");
    }

    // promise: decision 255 an existing split is accepted by the deploy only with the plan's hash and controller and a proven push: a pull split from the splits.org form and a split under another controller are refused, a push split with the plan's hash is accepted without a creation
    function test_deployAcceptsOnlyAMatchingPushSplit() public {
        Phase2Deploy.Inputs memory i = _inputs();
        SplitConfig memory cfg = deployProbe.splitConfig(core.artist(), core.payee());
        address pull = ISplitFactoryV2(PULL_FACTORY).createSplit(cfg, owner, address(this));
        i.split = pull;
        vm.expectRevert(abi.encodeWithSelector(PushSplitCreator.NotPush.selector, pull));
        deployProbe.deploy(i);
        address foreign = ISplitFactoryV2(deployProbe.PUSH_FACTORY()).createSplit(cfg, address(this), address(this));
        i.split = foreign;
        vm.expectRevert(abi.encodeWithSelector(PushSplitCreator.SplitMismatch.selector, foreign));
        deployProbe.deploy(i);
        address push = ISplitFactoryV2(deployProbe.PUSH_FACTORY()).createSplit(cfg, owner, address(this));
        i.split = push;
        Phase2Deploy.Result memory r = deployProbe.deploy(i);
        assertEq(r.split, push, "the given push split is the record's split");
        i = _inputs();
        i.splitPlan.operator = i.splitPlan.artist;
        vm.expectRevert(
            abi.encodeWithSelector(PushSplitCreator.BadRecipient.selector, core.artist(), core.artist(), owner)
        );
        deployProbe.deploy(i);
    }

    // promise: the readback samples executable payouts against the posted rate, names the binding constraint, and fails on a material shortfall unless the owner records approval
    function test_readbackSamplesExecutablePayoutsAndGatesAShortfall() public {
        // this test keeps the fixture's launch payout of 90 percent, which loses with the 10 percent earmark; the
        // margin row is accepted here so the payout rows are what the test reads (decision 259 covers the margin row)
        readback.setAcceptMargin(true);
        Phase2Deploy.Result memory r = deployProbe.deploy(_inputs());
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(r.treasury);
        _fillEthPile(3);
        _setBalanceModule(r.treasury);
        // the live token transfers are open at the pin; fund the treasury by a real holder transfer (the ink rule)
        _fundBalance(r.treasury, 5_000 ether);
        vm.prank(owner);
        t.setSwitches(true, true, false);
        _setSwitches(true, true);
        assertGt(core.balanceBidOf(core.pilePage(0, 1)[0]), 0, "the posted rate is executable");
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "no shortfall, the row passes");
        // the floor closes the bid: a sampled payout of zero is a material shortfall
        vm.prank(owner);
        t.setMinimumWorkingBalance(5_000 ether);
        assertEq(core.balanceBidOf(core.pilePage(0, 1)[0]), 0);
        string memory failed = readback.read(address(core), r.treasury, r.controllerV2);
        assertTrue(bytes(failed).length != 0, "the shortfall row fails the run");
        vm.setEnv("ACCEPT_PAYOUT_SHORTFALL", "1");
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "the owner's approval passes it");
        vm.setEnv("ACCEPT_PAYOUT_SHORTFALL", "0");
    }

    // promise: PLAN section 8 stage A the deploy preview refuses a balance token the treasury constructor would refuse, before any creation
    // kept on the stand in: it must inject a token with the wrong statements() source and the wrong decimals(), gates
    // the live token has already passed, so a mutable stand in is the only way to drive the two refusals
    function test_deployRefusesAWrongBalanceToken() public {
        Phase2BalanceTokenStandin token = new Phase2BalanceTokenStandin();
        token.configure(makeAddr("phase2.otherStatements"), 18);
        // the inputs read the Core's artist and payee, so they are built before the expectation
        Phase2Deploy.Inputs memory i = _inputs();
        i.balanceToken = address(token);
        i.tokenCodehash = address(token).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector, "preview: balance token statements() is the Statements contract"
            )
        );
        deployProbe.deploy(i);
        token = new Phase2BalanceTokenStandin();
        token.configure(token.statements(), 6);
        i = _inputs();
        i.balanceToken = address(token);
        i.tokenCodehash = address(token).codehash;
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: balance token decimals() is 18"));
        deployProbe.deploy(i);
    }

    // promise: decision 259 the settings preview prints the working gain per 100 BALANCE funded points and refuses a non positive margin unless ALLOW_NONPOSITIVE_MARGIN=1, and the readback's margin row fails only while working payments are on at a non positive margin unless ACCEPT_NONPOSITIVE_MARGIN=1
    function test_marginPreviewAndReadbackRow() public {
        // the fixture's launch settings: 90 percent payout and the launch royalty, a loss with the 10 percent earmark
        Settings memory launch = core.settings();
        uint256 payout = 10_000 - 1_000;
        int256 expected =
            int256(10_000) - int256(payout) - int256(payout * launch.buyToArtistBps / 10_000) - int256(1_000);
        assertLt(expected, 0, "the launch payout loses with the earmark");
        settings.setDiscount(1_000);
        vm.expectRevert(abi.encodeWithSelector(Phase2Settings.NonPositiveMargin.selector, expected));
        settings.previewOn();
        settings.setAllowMargin(true);
        settings.previewOn();
        settings.setAllowMargin(false);
        settings.setDiscount(2_000);
        Phase2Settings.Preview memory p = settings.previewOn();
        assertEq(p.next.balanceDiscountBps, 2_000);
        // the readback: the row is informational with working payments off, a failure with them on at the launch
        // payout, a pass once the 80 percent payout is set, and accepted with the owner's approval
        Phase2Deploy.Result memory r = deployProbe.deploy(_inputs());
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "switches off: informational");
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(r.treasury);
        vm.prank(owner);
        t.setSwitches(false, true, false);
        string memory failed = readback.read(address(core), r.treasury, r.controllerV2);
        assertTrue(bytes(failed).length != 0, "working payments on at a losing payout fails");
        readback.setAcceptMargin(true);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "accepted");
        readback.setAcceptMargin(false);
        Settings memory s = core.settings();
        s.balanceDiscountBps = 2_000;
        _setSettings(s);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "80 percent payout: positive margin");
    }

    // promise: PLAN section 8 the readback refuses a treasury bound to another Core and altered code, and names the hazard state
    function test_readbackRefusesForeignCoreAlteredCodeAndHazard() public {
        Phase2Deploy.Result memory r = deployProbe.deploy(_inputs());
        vm.mockCall(
            r.treasury, abi.encodeCall(IPhase2BalanceTreasury.core, ()), abi.encode(makeAddr("phase2.otherCore"))
        );
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "treasury: core is the Core");
        vm.clearMockedCalls();
        uint256 snap = vm.snapshotState();
        vm.etch(r.controllerV2, hex"00");
        assertEq(
            readback.read(address(core), r.treasury, r.controllerV2),
            "controllerV2: runtime code is the compiled ControllerV2 (immutables masked)"
        );
        vm.revertToState(snap);
        // the hazard: balance bid on, value mode off and a pool key set on the live controller
        _setSwitches(true, true);
        assertEq(readback.read(address(core), r.treasury, r.controllerV2), "", "no pool key, no hazard");
        vm.mockCall(address(ctl), abi.encodeCall(IControllerV1.balancePoolKeySet, ()), abi.encode(true));
        assertEq(
            readback.read(address(core), r.treasury, r.controllerV2),
            "hazard: balanceBidOn with valueModeOn off and a balance pool key set opens a round trip (docs/RUNBOOK.md)"
        );
    }

    // promise: decision 262 without a split the settings script changes exactly balanceDiscountBps, keeps the three buy and burn shares and creditCostToPotBps at their live values, and refuses the stage C switches
    function test_settingsPatchChangesOnlyThePayoutAndKeepsTheBurns() public {
        // the fixture launches with feeToRedeemBurnBps 0; mainnet carries 1,000, so set it first to see it kept
        Settings memory live = core.settings();
        live.feeToRedeemBurnBps = 1_000;
        _setSettings(live);
        live = core.settings();
        assertEq(live.feeToRedeemBurnBps, 1_000);
        uint16 costBefore = core.creditCostToPotBps();
        Phase2Settings.Preview memory p = settings.previewOn();
        uint256 changed;
        for (uint256 i; i < SettingsFields.N; ++i) {
            if (SettingsFields.get(p.live, i) != SettingsFields.get(p.next, i)) ++changed;
        }
        assertEq(changed, 1, "only the payout changes");
        assertEq(p.next.saleToBuybackBps, live.saleToBuybackBps);
        assertEq(p.next.feeToRedeemBurnBps, 1_000);
        assertEq(p.next.redeemBurnBps, live.redeemBurnBps);
        assertEq(p.next.balanceDiscountBps, 2_000, "the posted payout is 80 percent of rating");
        assertEq(keccak256(abi.encode(p.live)), keccak256(abi.encode(live)), "the live struct is read as is");
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(live)), "the preview sends nothing");
        settings.applyAsOwner();
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(p.next)));
        assertEq(core.creditCostToPotBps(), costBefore, "the credit cost share is kept");
        settings.force("balanceBidOn");
        vm.expectRevert(abi.encodeWithSelector(Phase2Settings.StageCField.selector, "balanceBidOn"));
        settings.refuse();
    }

    // promise: decision 255 with a split address the patch makes the split the artist and every artist flow 3 percent with the sale operator cut folded in, split first, then the settings; with decision 262 those four and the payout are the only fields that change
    function test_settingsPatchWiresTheSplitAsArtist() public {
        // any contract with code and a payable receive stands in for the split; this test contract has both
        address split = address(this);
        address artist0 = core.artist();
        settings.setSplit(split);
        Phase2Settings.Preview memory p = settings.previewOn();
        assertEq(p.split, split);
        assertTrue(p.artistChanged);
        bytes32[39] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            bytes32 n = names[i];
            if (
                n == "balanceDiscountBps" || n == "buyToArtistBps" || n == "saleToArtistBps" || n == "saleToOperatorBps"
            ) continue;
            assertEq(SettingsFields.get(p.live, i), SettingsFields.get(p.next, i), "every other field is kept");
        }
        assertEq(p.next.buyToArtistBps, 300);
        assertEq(p.next.saleToArtistBps, 300);
        assertEq(p.next.saleToOperatorBps, 0);
        assertEq(p.next.balanceDiscountBps, 2_000);
        assertEq(core.artist(), artist0, "the preview sends nothing");
        settings.applyAsOwner();
        assertEq(core.artist(), split);
        assertEq(core.settings().buyToArtistBps, 300);
        assertEq(core.settings().saleToArtistBps, 300);
        assertEq(core.settings().saleToOperatorBps, 0);
        // the purchase royalty now reaches the split in both currencies: an eth purchase pushes it there
        uint256[] memory ids = _credits(seller, 1);
        _fundPot(5 ether);
        uint256 before = split.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertGt(split.balance, before, "the eth royalty reached the split");
        // a split with no code is refused
        settings.setSplit(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Phase2Settings.BadSplit.selector, address(0xBAD)));
        settings.previewOn();
    }
}
