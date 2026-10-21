// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ValueBase} from "./ValueMode.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IStandingBidPolicy} from "../src/interfaces/IStandingBidPolicy.sol";
import {CreditSale, Quote} from "../src/interfaces/Interfaces.sol";
import {Report} from "../script/Report.sol";
import {StandingBid} from "../script/StandingBid.s.sol";
import {Phase2Readback} from "../script/Phase2Readback.s.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev the stage D script with its environment replaced by arguments
contract StandingBidProbe is StandingBid {
    /// the preview rows (reverting on a failed one) without any step
    function previewOnly(Inputs memory i) external returns (Preview memory) {
        return preview(i);
    }

    /// the preview, then the step as the treasury owner with its readback rows, state kept. returns the failed names
    function applyAsOwner(Inputs memory i) external returns (Result memory r, string memory failed) {
        Preview memory p = preview(i);
        vm.startPrank(p.owner);
        r = activate(i, p);
        vm.stopPrank();
        (failed,) = _failed();
        _reset();
    }

    /// the script's own run without a send: the simulation on a snapshot, reverted
    function simulate(Inputs memory i) external returns (Result memory) {
        return runStandingBid(i, false);
    }

    function spotOf(address core) external view returns (uint256) {
        return _liveSpot(ICore(payable(core)));
    }
}

/// @dev the readback rows on given addresses, returning the failed names instead of reverting
contract ReadbackProbe is Phase2Readback {
    function read(address core, address treasury, address controllerV2) external returns (string memory failed) {
        _reset();
        phase2Readback(core, treasury, controllerV2);
        (failed,) = _failed();
    }
}

/// @notice the stage D script on the pinned fork: the fixture of test/StandingBidPolicy.t.sol before the policy is
/// seeded or installed (a selected phase 2 treasury on the standin token with the pro rata policy, ControllerV2 priced
/// on the standin pool, a priced coin pool), driven step by step through the script's internal functions
contract StandingBidScriptsTest is ValueBase {
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    /// a quarter of the fixture's 1 token claim reserve, the most the budget step accepts without the owner's waiver
    uint128 private constant BUDGET = 0.25 ether;
    string private constant HAZARD =
        "hazard: CC redemption on with a usable bid and no budget (the bid is on paper only) or a budget and an unusable bid (the floor only)";

    Phase2BalanceTokenStandin internal tok;
    PoolKey internal tokKey;
    IPhase2BalanceTreasury internal t;
    IControllerV2 internal c2;
    address internal proRata;
    address internal holder;
    StandingBidProbe internal probe;
    ReadbackProbe internal readback;

    function setUp() public override {
        super.setUp();
        tok = new Phase2BalanceTokenStandin();
        tok.open();
        tokKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tok)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(tokKey, SP);
        tok.mint(address(this), 1e24);
        tok.approve(address(lp), type(uint256).max);
        tok.approve(address(router), type(uint256).max);
        vm.deal(address(this), address(this).balance + 2_000 ether);
        lp.modify{value: 2_000 ether}(tokKey, -TICK_FULL, TICK_FULL, int256(uint256(POOL_LIQ)));
        proRata = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = IPhase2BalanceTreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), address(tok), proRata, address(0))
            )
        );
        _setBalanceModule(address(t));
        tok.mint(address(t), 300 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, true);
        t.allocateToClaims(1 ether);
        vm.stopPrank();
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: ctl.creditSpreadBps(),
            startBps: ctl.creditStartBps()
        });
        Quote memory none;
        c2 = IControllerV2(
            vm.deployCode(
                "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(15_000), uint32(3_600))
            )
        );
        _setController(address(c2));
        (uint160 sp,,,) = PM.getSlot0(tokKey.toId());
        vm.startPrank(owner);
        c2.setBalancePoolKey(
            IControllerV2.PoolKey({
                currency0: IControllerV2.Currency.wrap(address(0)),
                currency1: IControllerV2.Currency.wrap(address(tok)),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            _spotOf(sp)
        );
        c2.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_000,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 0,
                minLiquidity: 1
            })
        );
        vm.stopPrank();
        // the fixture's coin pool has no active liquidity before its first swap
        holder = _user("holder");
        _buyCoin(holder, 1 ether);
        probe = new StandingBidProbe();
        readback = new ReadbackProbe();
    }

    /// the script's defaults with the required liquidity threshold
    function _quote() internal pure returns (Quote memory) {
        return Quote({
            referenceRateBpsPerHour: 200,
            referenceStepBps: 100,
            tolBps: 0,
            referenceMaxStale: 86_400,
            referenceMinSeconds: 600,
            minLiquidity: 1
        });
    }

    function _inputs(StandingBid.Step step, address policy) internal view returns (StandingBid.Inputs memory i) {
        i.treasury = address(t);
        i.policy = policy;
        i.premiumBps = 100;
        i.quote = _quote();
        i.budgetPerDay = BUDGET;
        i.budgetMax = BUDGET;
        i.step = step;
    }

    /// the step as the owner through the probe; every readback row of the step must pass
    function _step(StandingBid.Step step, address policy) internal returns (address) {
        (StandingBid.Result memory r, string memory failed) = probe.applyAsOwner(_inputs(step, policy));
        assertEq(failed, "", "the step's readback passes");
        return r.policy;
    }

    /// the five sends in order, the budget accrued for half a day so it covers the sample burn
    function _activate() internal returns (address policy) {
        policy = _step(StandingBid.Step.Deploy, address(0));
        _step(StandingBid.Step.Configure, policy);
        _step(StandingBid.Step.Install, policy);
        _step(StandingBid.Step.Budget, address(0));
        vm.warp(block.timestamp + 12 hours);
        _step(StandingBid.Step.Enable, address(0));
    }

    // promise: RUNBOOK stage D the five steps in order: deploy creates a policy bound to the treasury, configure seeds the reference and sets the quote and the premium, install swaps the policy and turns CC redemption off, budget sets the accruing budget, enable turns redemption on and the quote of a burn is the bid when the budget covers it and the share before
    function test_stepsActivateTheBidInOrder() public {
        uint64 epoch = t.configEpoch();
        address policy = _step(StandingBid.Step.Deploy, address(0));
        IStandingBidPolicy p = IStandingBidPolicy(policy);
        assertEq(p.TREASURY(), address(t));
        assertEq(p.CORE(), address(core));
        assertEq(p.owner(), owner);
        assertEq(p.premiumBps(), 100);
        assertEq(t.redemptionPolicy(), proRata, "deploy changes nothing on the treasury");
        (, bool usable) = p.bidPerCC();
        assertFalse(usable, "unusable until configured");
        _step(StandingBid.Step.Configure, policy);
        (uint256 spot,) = p.ccSpot();
        assertEq(p.referencePrice(), spot);
        (uint32 rate, uint16 step, uint16 tol, uint32 maxStale, uint32 minSeconds, uint128 minLiq) = p.bidQuote();
        assertEq(rate, 200);
        assertEq(step, 100);
        assertEq(tol, 0);
        assertEq(maxStale, 86_400);
        assertEq(minSeconds, 600);
        assertEq(minLiq, 1);
        (uint256 perCC, bool ok) = p.bidPerCC();
        assertTrue(ok && perCC != 0, "the bid is usable after configure");
        assertEq(t.redemptionPolicy(), proRata, "configure changes nothing on the treasury");
        _step(StandingBid.Step.Install, policy);
        assertEq(t.redemptionPolicy(), policy);
        assertFalse(t.ccRedemptionEnabled(), "install turns CC redemption off");
        assertGt(t.configEpoch(), epoch);
        // enable before any budget: the quote is the proportional share, the step's readback names it
        _step(StandingBid.Step.Enable, address(0));
        assertTrue(t.ccRedemptionEnabled());
        (uint256 share,,) = t.redemptionTerms(1e18);
        (uint256 q,,,, bool exec) = t.quoteRedemption(1e18);
        assertEq(q, share, "no budget, the share");
        assertTrue(exec);
        _step(StandingBid.Step.Budget, address(0));
        assertEq(t.bidBudgetPerDay(), BUDGET);
        assertEq(t.bidBudgetMax(), BUDGET);
        assertEq(t.bidBudgetAvailable(), 0, "nothing accrued yet");
        vm.warp(block.timestamp + 12 hours);
        assertEq(t.bidBudgetAvailable(), BUDGET / 2);
        _step(StandingBid.Step.Enable, address(0));
        assertTrue(t.conversionEnabled() && t.workingPaymentsEnabled(), "the first two switches are kept");
        (uint256 bid,) = p.bidFor(1e18);
        assertGt(bid, share, "the fixture's bid is above the share");
        assertLe(bid, t.bidBudgetAvailable(), "the budget covers the sample burn");
        (q,,,, exec) = t.quoteRedemption(1e18);
        assertEq(q, bid, "the quote is the bid");
        assertTrue(exec);
    }

    // promise: a send restates the preview's plan hash: SEND=1 with another hash is refused, the printed hash passes, and STEP=all never sends
    function test_planHashGateRefusesAWrongHash() public {
        vm.setEnv("TREASURY", vm.toString(address(t)));
        vm.setEnv("STEP", "deploy");
        vm.setEnv("BID_QUOTE_MIN_LIQUIDITY", "1");
        vm.setEnv("SEND", "1");
        bytes32 wrong = keccak256("another plan");
        vm.setEnv("STANDING_BID_PLAN_HASH", vm.toString(wrong));
        StandingBid.Inputs memory i = _inputs(StandingBid.Step.Deploy, address(0));
        i.budgetPerDay = 0;
        i.budgetMax = 0;
        bytes32 want = probe.planHash(i, probe.spotOf(address(core)));
        vm.expectRevert(abi.encodeWithSelector(StandingBid.PlanHashMismatch.selector, want, wrong));
        probe.run();
        vm.setEnv("STANDING_BID_PLAN_HASH", vm.toString(want));
        StandingBid.Result memory r = probe.run();
        assertTrue(r.policy.code.length != 0, "the restated hash sends the deploy");
        assertEq(IStandingBidPolicy(r.policy).TREASURY(), address(t));
        vm.setEnv("STEP", "all");
        vm.expectRevert(StandingBid.AllIsPreviewOnly.selector);
        probe.run();
        vm.setEnv("SEND", "0");
        vm.setEnv("STANDING_BID_PLAN_HASH", vm.toString(bytes32(0)));
    }

    // promise: the preview refuses a quote the policy would: a zero minLiquidity, a tolBps over 100 and a rate over 1,000 bps per hour
    function test_quoteInputsAreRefused() public {
        address policy = _step(StandingBid.Step.Deploy, address(0));
        StandingBid.Inputs memory i = _inputs(StandingBid.Step.Configure, policy);
        i.quote.minLiquidity = 0;
        vm.expectRevert(abi.encodeWithSelector(StandingBid.BadInput.selector, bytes32("minLiquidity")));
        probe.previewOnly(i);
        i = _inputs(StandingBid.Step.Configure, policy);
        i.quote.tolBps = 450;
        vm.expectRevert(abi.encodeWithSelector(StandingBid.BadInput.selector, bytes32("tolBps")));
        probe.previewOnly(i);
        i = _inputs(StandingBid.Step.Configure, policy);
        i.quote.referenceRateBpsPerHour = 1_001;
        vm.expectRevert(abi.encodeWithSelector(StandingBid.BadInput.selector, bytes32("referenceRateBpsPerHour")));
        probe.previewOnly(i);
        // the policy itself refuses the old tolerance
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandingBidPolicy.BadSetting.selector, bytes32("tolBps")));
        IStandingBidPolicy(policy)
            .setQuote(
                Quote({
                    referenceRateBpsPerHour: 200,
                    referenceStepBps: 100,
                    tolBps: 450,
                    referenceMaxStale: 86_400,
                    referenceMinSeconds: 600,
                    minLiquidity: 1
                })
            );
    }

    // promise: the budget step refuses a maximum above a quarter of the claim reserve unless ALLOW_LARGE_BID_BUDGET records the owner's choice, and refuses a zero budget
    function test_budgetSizingRule() public {
        address policy = _step(StandingBid.Step.Deploy, address(0));
        StandingBid.Inputs memory i = _inputs(StandingBid.Step.Budget, policy);
        i.budgetMax = BUDGET + 1;
        i.budgetPerDay = BUDGET;
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector,
                "budget: max at most a quarter of the claim reserve, or ALLOW_LARGE_BID_BUDGET=1 records the owner's approval"
            )
        );
        probe.previewOnly(i);
        i.allowLargeBudget = true;
        probe.previewOnly(i);
        i = _inputs(StandingBid.Step.Budget, policy);
        i.budgetMax = 0;
        i.budgetPerDay = 0;
        vm.expectRevert(abi.encodeWithSelector(StandingBid.BadInput.selector, bytes32("budgetMax")));
        probe.previewOnly(i);
    }

    // promise: deploy without POLICY refuses a treasury whose policy already is a standing bid, and the owner steps refuse a treasury without one when no POLICY is given
    function test_policyResolution() public {
        address policy = _step(StandingBid.Step.Deploy, address(0));
        // the treasury still runs the pro rata policy, so an owner step without POLICY has none to act on
        vm.expectRevert(StandingBid.PolicyRequired.selector);
        probe.previewOnly(_inputs(StandingBid.Step.Configure, address(0)));
        _step(StandingBid.Step.Configure, policy);
        _step(StandingBid.Step.Install, policy);
        vm.expectRevert(abi.encodeWithSelector(StandingBid.AlreadyStandingBid.selector, policy));
        probe.previewOnly(_inputs(StandingBid.Step.Deploy, address(0)));
        // the installed standing bid is the policy of the later steps
        StandingBid.Preview memory p = probe.previewOnly(_inputs(StandingBid.Step.Budget, address(0)));
        assertEq(p.policy, policy);
    }

    // promise: a preview of STEP=all simulates every step and sends nothing: the treasury's policy, switches, budget and epoch are as before
    function test_previewOfAllSendsNothing() public {
        uint64 epoch = t.configEpoch();
        StandingBid.Result memory r = probe.simulate(_inputs(StandingBid.Step.All, address(0)));
        assertTrue(r.policy != address(0), "the simulation created a policy");
        assertEq(r.policy.code.length, 0, "the creation was reverted with the snapshot");
        assertEq(t.redemptionPolicy(), proRata);
        assertTrue(t.ccRedemptionEnabled(), "the switch is as the fixture set it");
        assertEq(t.bidBudgetMax(), 0);
        assertEq(t.bidBudgetPerDay(), 0);
        assertEq(t.configEpoch(), epoch);
    }

    // promise: the readback's bid rows pass on the configured stack, and its hazard row names a budget with an unusable bid (the floor only) and a usable bid without a budget (the bid is on paper only)
    function test_readbackRowsPassAndTheHazardTrips() public {
        address policy = _activate();
        // the balance bid off, so the stage C hazard row of the readback does not apply to this fixture
        _setSwitches(true, false);
        assertEq(readback.read(address(core), address(t), address(c2)), "", "every row passes");
        Quote memory thin = _quote();
        thin.minLiquidity = type(uint128).max;
        vm.prank(owner);
        IStandingBidPolicy(policy).setQuote(thin);
        (, bool usable) = IStandingBidPolicy(policy).bidPerCC();
        assertFalse(usable);
        assertGt(t.bidBudgetAvailable(), 0);
        assertEq(readback.read(address(core), address(t), address(c2)), HAZARD, "the floor only");
        vm.prank(owner);
        IStandingBidPolicy(policy).setQuote(_quote());
        vm.prank(owner);
        t.setBidBudget(0, 0);
        assertEq(t.bidBudgetAvailable(), 0);
        assertEq(readback.read(address(core), address(t), address(c2)), HAZARD, "the bid on paper only");
        vm.prank(owner);
        t.setSwitches(true, true, false);
        assertEq(readback.read(address(core), address(t), address(c2)), "", "no hazard while redemption is off");
    }
}
