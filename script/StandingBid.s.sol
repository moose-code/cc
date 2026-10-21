// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IStandingBidPolicy} from "../src/interfaces/IStandingBidPolicy.sol";
import {Quote, POINT_UNIT} from "../src/interfaces/Interfaces.sol";
import {Phase2Checks} from "./Phase2Readback.s.sol";

/// @notice stage D of docs/RUNBOOK.md: the post launch activation of the standing bid (decision 258) on a live
/// Phase2BalanceTreasury, one owner transaction per run. `STEP` selects the run: `deploy` creates a StandingBidPolicy
/// bound to `TREASURY` from its via_ir artifact (any signer; `POLICY=0x...` reuses one instead); `configure` is the
/// owner's `seedReference(BID_EXPECTED_SPOT)`, `setQuote(BID_QUOTE_*)` and `setPremiumBps(BID_PREMIUM_BPS)` on the
/// policy; `install` is `setRedemptionPolicy(policy)` on the treasury, which turns CC redemption off; `budget` is
/// `setBidBudget(BID_BUDGET_PER_DAY, BID_BUDGET_MAX)`; `enable` is `setSwitches(conversion, workingPayments, true)`
/// with the first two kept as they are; `all` simulates every step in order and never sends. every run previews, then
/// simulates its step as the owner on a snapshot with the readback of that step, and prints a plan hash. a send is
/// `SEND=1 STANDING_BID_PLAN_HASH=<the printed hash> ... --broadcast --account ripe0x`; a hash that differs from the
/// preview's refuses the send. the hash covers the chain, the treasury, the policy and its settings, the budget, the
/// step and the live CC spot rounded to two digits, so what is sent is what was reviewed. `BID_QUOTE_*` defaults:
/// `referenceRateBpsPerHour` 200, `referenceStepBps` 100, `tolBps` 0, `referenceMaxStale` 86,400,
/// `referenceMinSeconds` 600; `BID_QUOTE_MIN_LIQUIDITY` is required (a zero is refused). with a zero tolerance the CC
/// leg prices at the lowest of the prior block sample, the live spot and the reference, so a pump reaches the bid only
/// through the rate, at most `referenceRateBpsPerHour` per hour. `BID_BUDGET_MAX` above a quarter of the claim reserve
/// needs `ALLOW_LARGE_BID_BUDGET=1`. the run ends with one `record: {json}` line.
/// `STEP=deploy TREASURY=0x... forge script script/StandingBid.s.sol --rpc-url $MAINNET_RPC_URL`
contract StandingBid is Script, Phase2Checks {
    using StateLibrary for IPoolManager;

    /// @dev `STEP` is not one of deploy, configure, install, budget, enable, all
    error BadStep(string given);
    /// @dev an environment integer wider than the field it sets; a silent narrowing would send other terms than entered
    error ValueTooWide(string key);
    /// @dev an input the step cannot run with: a zero `minLiquidity`, a zero budget, a per day amount above the maximum
    error BadInput(bytes32 field);
    /// @dev the step needs a policy: `POLICY` or a standing bid already installed on the treasury
    error PolicyRequired();
    /// @dev `deploy` without `POLICY` on a treasury whose policy already is a standing bid
    error AlreadyStandingBid(address policy);
    /// @dev `all` is a preview of every step; each step is sent on its own
    error AllIsPreviewOnly();
    /// @dev the hash given as `STANDING_BID_PLAN_HASH` is not the preview's
    error PlanHashMismatch(bytes32 want, bytes32 given);
    /// @dev the signer is not the treasury owner
    error NotOwner(address owner, address signer);
    /// @dev the creation returned no code
    error CreateFailed();

    string internal constant BID_VERSION = "standing-bid-v1";
    string internal constant ARTIFACT = "StandingBidPolicy";
    uint256 internal constant BPS = 10_000;
    /// @dev the policy's `MAX_PREMIUM_BPS`, `MAX_TOL_BPS` and `MAX_RATE_BPS_PER_HOUR`, restated so the preview refuses
    /// what the policy would
    uint16 internal constant MAX_PREMIUM_BPS = 500;
    uint16 internal constant MAX_TOL_BPS = 100;
    uint32 internal constant MAX_RATE_BPS_PER_HOUR = 1_000;
    /// @dev the most of the claim reserve a budget maximum may reach without `ALLOW_LARGE_BID_BUDGET=1`: a maximum at or
    /// above the reserve lets one burn take the whole reserve at the bid
    uint256 internal constant BUDGET_MAX_SHARE_DIVISOR = 4;
    /// @dev the sample burn of the enable readback, 1 CC
    uint256 internal constant SAMPLE_CC = 1e18;

    enum Step {
        Deploy,
        Configure,
        Install,
        Budget,
        Enable,
        All
    }

    struct Inputs {
        address treasury;
        /// the policy to configure, install or read; zero on `deploy` creates one
        address policy;
        uint16 premiumBps;
        Quote quote;
        /// wei per 1e18 CC the owner read; zero takes the live spot of the preview
        uint256 expectedSpot;
        /// balance base units
        uint128 budgetPerDay;
        uint128 budgetMax;
        /// `ALLOW_LARGE_BID_BUDGET=1`: a maximum above a quarter of the claim reserve is the owner's explicit choice
        bool allowLargeBudget;
        Step step;
    }

    struct Preview {
        address core;
        address owner;
        /// the policy the step acts on, zero when `deploy` creates it
        address policy;
        /// the live coin pool spot, wei per 1e18 CC, zero when the pool does not price
        uint256 spot;
        /// the seed the configure step sends
        uint256 expectedSpot;
        /// ControllerV2's protected balance price, wei per 1e18 base units, zero while unusable
        uint256 balancePrice;
        /// the bid per 1e18 CC the spot and the premium imply, the configure readback's expectation
        uint256 expectedPerCC;
        bool conversion;
        bool workingPayments;
        bytes32 planHash;
    }

    struct Result {
        address policy;
    }

    function run() external returns (Result memory) {
        Inputs memory i = _inputs();
        bool send = vm.envOr("SEND", uint256(0)) == 1;
        if (send) {
            if (i.step == Step.All) revert AllIsPreviewOnly();
            bytes32 want = planHash(i, _liveSpot(ICore(payable(IPhase2BalanceTreasury(i.treasury).core()))));
            bytes32 given = vm.envOr("STANDING_BID_PLAN_HASH", bytes32(0));
            if (given != want) revert PlanHashMismatch(want, given);
        }
        return runStandingBid(i, send);
    }

    /// @notice the hash a send must restate: the chain, the treasury, the policy inputs, the budget inputs, the step and
    /// the live spot rounded to two significant digits. the expected spot counts on the steps that seed with it
    function planHash(Inputs memory i, uint256 spot) public view returns (bytes32) {
        bool seeds = i.step == Step.Configure || i.step == Step.All;
        uint256 expected = seeds ? (i.expectedSpot == 0 ? spot : i.expectedSpot) : 0;
        return keccak256(
            abi.encode(
                block.chainid,
                i.treasury,
                i.policy,
                i.premiumBps,
                i.quote,
                expected,
                i.budgetPerDay,
                i.budgetMax,
                i.allowLargeBudget,
                i.step,
                roundedSpot(spot)
            )
        );
    }

    /// @notice `x` with every digit after the two leading ones zeroed
    function roundedSpot(uint256 x) public pure returns (uint256) {
        if (x == 0) return 0;
        uint256 m = 1;
        while (x / m >= 100) {
            m *= 10;
        }
        return x / m * m;
    }

    /// @notice the preview, the simulation of the step as the owner on a snapshot with its readback, then with `send`
    /// the same step broadcast and read back. a test calls it with its own inputs and `send` false
    function runStandingBid(Inputs memory i, bool send) internal returns (Result memory r) {
        Preview memory p = preview(i);
        uint256 snap = vm.snapshotState();
        vm.startPrank(p.owner);
        r = activate(i, p);
        vm.stopPrank();
        _print(string.concat("standing bid simulation: ", _stepName(i.step)));
        _require();
        _record(i, p, r);
        _reset();
        vm.revertToState(snap);
        if (!send) {
            console.log(
                "nothing sent. add SEND=1 STANDING_BID_PLAN_HASH=<the printed hash> and --broadcast as the owner to send"
            );
            return r;
        }
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        if (i.step != Step.Deploy && signer != p.owner) revert NotOwner(p.owner, signer);
        r = activate(i, p);
        vm.stopBroadcast();
        _print(string.concat("standing bid readback: ", _stepName(i.step)));
        _require();
        _record(i, p, r);
        console.log("sent. read it back with Phase2Readback (the bid rows)");
    }

    // ------------------------------------------------------------------ the preview

    /// @notice the rows that must hold before anything runs: the treasury, its owner and policy, the inputs of the step,
    /// the live spot and the balance leg. prints the table, the plan hash and the expected spot, and reverts on a failed
    /// row. the rows are cleared afterwards, so the readback table starts empty
    function preview(Inputs memory i) internal returns (Preview memory p) {
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _info("preview: step", _stepName(i.step));
        bool treasuryOk = runtimeMatchesArtifact(i.treasury, "Phase2BalanceTreasury");
        _check(
            "preview: treasury runtime code is the compiled Phase2BalanceTreasury", treasuryOk, vm.toString(i.treasury)
        );
        if (!treasuryOk) {
            _print("standing bid preview");
            _require();
        }
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
        p.core = t.core();
        p.owner = t.owner();
        p.conversion = t.conversionEnabled();
        p.workingPayments = t.workingPaymentsEnabled();
        _info("preview: treasury core / owner", string.concat(vm.toString(p.core), " / ", vm.toString(p.owner)));
        _info(
            "preview: treasury switches conversion / workingPayments / ccRedemption",
            string.concat(
                vm.toString(p.conversion),
                " / ",
                vm.toString(p.workingPayments),
                " / ",
                vm.toString(t.ccRedemptionEnabled())
            )
        );
        _info("preview: treasury claimReserve / bidBudgetAvailable", _two(t.claimReserve(), t.bidBudgetAvailable()));
        address installed = t.redemptionPolicy();
        bool installedIsBid = _isStandingBid(installed);
        _info(
            "preview: treasury redemptionPolicy / version",
            string.concat(vm.toString(installed), " / ", _version(installed))
        );
        p.policy = _policyOf(i, installed, installedIsBid);
        if (p.policy != address(0)) {
            _check(
                "preview: policy runtime code is the compiled StandingBidPolicy",
                runtimeMatchesArtifact(p.policy, ARTIFACT),
                vm.toString(p.policy)
            );
            (bool ok, address bound) = _addr(p.policy, abi.encodeCall(IStandingBidPolicy.TREASURY, ()));
            _check("preview: policy TREASURY is the treasury", ok && bound == i.treasury, vm.toString(bound));
        } else {
            _info("deploy: StandingBidPolicy(treasury)", vm.toString(i.treasury));
        }
        p.spot = _liveSpot(ICore(payable(p.core)));
        p.expectedSpot = i.expectedSpot == 0 ? p.spot : i.expectedSpot;
        p.balancePrice = _balanceLeg(ICore(payable(p.core)), t);
        _previewLegs(i, p);
        _previewInputs(i, p);
        p.planHash = planHash(i, p.spot);
        _info("preview: plan hash (STANDING_BID_PLAN_HASH of a send)", vm.toString(p.planHash));
        _print("standing bid preview");
        _require();
        _reset();
    }

    /// @dev the two legs: a check on the steps that seed or enable, an information row otherwise
    function _previewLegs(Inputs memory i, Preview memory p) private {
        bool seeds = i.step == Step.Configure || i.step == Step.All;
        string memory spot = string.concat(vm.toString(p.spot), " wei per 1e18 CC");
        if (seeds) _check("preview: the coin pool prices (live ccSpot)", p.spot != 0, spot);
        else _info("preview: live ccSpot", spot);
        string memory bal = string.concat(vm.toString(p.balancePrice), " wei per 1e18 base units");
        if (seeds) {
            _check("preview: ControllerV2 prices the balance token (protectedBalancePrice)", p.balancePrice != 0, bal);
        } else {
            _info("preview: protectedBalancePrice", bal);
        }
        if (seeds && p.spot != 0 && p.balancePrice != 0) {
            p.expectedPerCC = FixedPointMathLib.fullMulDiv(p.spot * (BPS + i.premiumBps), 1e18, p.balancePrice * BPS);
            _info("preview: bid per 1e18 CC the spot and the premium imply (base units)", vm.toString(p.expectedPerCC));
        }
    }

    /// @dev the inputs of the step, refused when the step cannot run with them
    function _previewInputs(Inputs memory i, Preview memory p) private {
        bool all = i.step == Step.All;
        if (i.step == Step.Configure || all) {
            if (i.quote.minLiquidity == 0) revert BadInput("minLiquidity");
            if (i.premiumBps > MAX_PREMIUM_BPS) revert BadInput("premiumBps");
            if (i.quote.tolBps > MAX_TOL_BPS) revert BadInput("tolBps");
            if (i.quote.referenceRateBpsPerHour > MAX_RATE_BPS_PER_HOUR) revert BadInput("referenceRateBpsPerHour");
            uint256 band = p.expectedSpot * 450 / BPS;
            _check(
                "preview: live spot within 4.5 percent of BID_EXPECTED_SPOT (restate it on the send)",
                p.spot != 0 && p.spot >= p.expectedSpot - band && p.spot <= p.expectedSpot + band,
                string.concat("expected ", vm.toString(p.expectedSpot), " live ", vm.toString(p.spot))
            );
            _info("configure: seedReference(expectedSpot)", vm.toString(p.expectedSpot));
            _info(
                "configure: setQuote(rate / step / tol / maxStale / minSeconds / minLiquidity)",
                string.concat(
                    _trio(i.quote.referenceRateBpsPerHour, i.quote.referenceStepBps, i.quote.tolBps),
                    " / ",
                    _trio(i.quote.referenceMaxStale, i.quote.referenceMinSeconds, i.quote.minLiquidity)
                )
            );
            _info("configure: setPremiumBps", vm.toString(uint256(i.premiumBps)));
        }
        if (i.step == Step.Install || all) _info("install: setRedemptionPolicy(policy), CC redemption turns off", "");
        if (i.step == Step.Budget || all) {
            if (i.budgetMax == 0) revert BadInput("budgetMax");
            if (i.budgetPerDay == 0) revert BadInput("budgetPerDay");
            if (i.budgetPerDay > i.budgetMax) revert BadInput("budgetPerDay");
            uint256 reserve = IPhase2BalanceTreasury(i.treasury).claimReserve();
            _info(
                "budget: setBidBudget(perDay, max) base units / claimReserve",
                _trio(i.budgetPerDay, i.budgetMax, reserve)
            );
            _check(
                "budget: max at most a quarter of the claim reserve, or ALLOW_LARGE_BID_BUDGET=1 records the owner's approval",
                i.budgetMax <= reserve / BUDGET_MAX_SHARE_DIVISOR || i.allowLargeBudget,
                string.concat(
                    "max ", vm.toString(i.budgetMax), " reserve / 4 ", vm.toString(reserve / BUDGET_MAX_SHARE_DIVISOR)
                )
            );
        }
        if (i.step == Step.Enable || all) {
            _info(
                "enable: setSwitches(conversion, workingPayments, true)",
                string.concat(vm.toString(p.conversion), ", ", vm.toString(p.workingPayments), ", true")
            );
        }
    }

    /// @dev the policy the step acts on: `POLICY`, else the standing bid installed on the treasury, else none. `deploy`
    /// without `POLICY` refuses a treasury that already runs a standing bid; the other steps need one
    function _policyOf(Inputs memory i, address installed, bool installedIsBid) private pure returns (address) {
        if (i.policy != address(0)) return i.policy;
        if (i.step == Step.Deploy || i.step == Step.All) {
            if (installedIsBid) revert AlreadyStandingBid(installed);
            return address(0);
        }
        if (!installedIsBid) revert PolicyRequired();
        return installed;
    }

    // ------------------------------------------------------------------ the steps

    /// @notice the step (every step for `all`) as the caller, each followed by its readback rows. the caller has opened a
    /// broadcast or a prank as the owner; `deploy` accepts any caller
    function activate(Inputs memory i, Preview memory p) internal returns (Result memory r) {
        r.policy = p.policy;
        bool all = i.step == Step.All;
        if (i.step == Step.Deploy || (all && r.policy == address(0))) {
            r.policy = _createPolicy(i.treasury);
            _readDeploy(i, p, r.policy);
        }
        IStandingBidPolicy policy = IStandingBidPolicy(r.policy);
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
        if (i.step == Step.Configure || all) {
            policy.seedReference(p.expectedSpot);
            policy.setQuote(i.quote);
            policy.setPremiumBps(i.premiumBps);
            _readConfigure(i, p, policy);
        }
        if (i.step == Step.Install || all) {
            uint64 epoch = t.configEpoch();
            t.setRedemptionPolicy(r.policy);
            _readInstall(t, r.policy, epoch);
        }
        if (i.step == Step.Budget || all) {
            t.setBidBudget(i.budgetPerDay, i.budgetMax);
            _readBudget(i, t);
        }
        if (i.step == Step.Enable || all) {
            t.setSwitches(p.conversion, p.workingPayments, true);
            _readEnable(p, t, IStandingBidPolicy(t.redemptionPolicy()));
        }
    }

    /// @dev creates the policy from its via_ir artifact through a plain CREATE, which `forge script` broadcasts as a
    /// deployment of the signer when a broadcast is open
    function _createPolicy(address treasury) private returns (address at) {
        bytes memory init =
            abi.encodePacked(vm.getCode(string.concat(ARTIFACT, ".sol:", ARTIFACT)), abi.encode(treasury));
        assembly {
            at := create(0, add(init, 0x20), mload(init))
        }
        if (at.code.length == 0) revert CreateFailed();
    }

    // ------------------------------------------------------------------ the readbacks

    function _readDeploy(Inputs memory i, Preview memory p, address at) private {
        IStandingBidPolicy policy = IStandingBidPolicy(at);
        _check(
            "deploy: policy runtime code is the compiled StandingBidPolicy",
            runtimeMatchesArtifact(at, ARTIFACT),
            vm.toString(at)
        );
        _eq("deploy: policy TREASURY is the treasury", policy.TREASURY(), i.treasury);
        _eq("deploy: policy CORE is the treasury's Core", policy.CORE(), p.core);
        _eq("deploy: policy owner is the treasury owner", policy.owner(), p.owner);
        _eq("deploy: policy VERSION", policy.VERSION(), BID_VERSION);
        _check("deploy: policy isRedemptionPolicy", policy.isRedemptionPolicy(), "isRedemptionPolicy()");
        _eq("deploy: policy premiumBps at deployment is 100", policy.premiumBps(), 100);
        (, bool usable) = policy.bidPerCC();
        _check("deploy: bid unusable until configured (every quote the floor)", !usable, "bidPerCC()");
    }

    function _readConfigure(Inputs memory i, Preview memory p, IStandingBidPolicy policy) private {
        uint256 ref = policy.referencePrice();
        _check(
            "configure: referencePrice is the seeded spot",
            ref != 0 && ref == p.spot,
            string.concat("reference ", vm.toString(ref), " spot ", vm.toString(p.spot))
        );
        _check(
            "configure: bidQuote equals the input",
            keccak256(abi.encode(_quoteOf(policy))) == keccak256(abi.encode(i.quote)),
            "bidQuote()"
        );
        _eq("configure: premiumBps equals the input", policy.premiumBps(), i.premiumBps);
        (uint256 perCC, bool usable) = policy.bidPerCC();
        _check("configure: bidPerCC is usable", usable, vm.toString(perCC));
        _check(
            "configure: bidPerCC within 10 percent of the preview's spot based expectation",
            usable && perCC >= p.expectedPerCC * 90 / 100 && perCC <= p.expectedPerCC * 110 / 100,
            string.concat("bidPerCC ", vm.toString(perCC), " expected ", vm.toString(p.expectedPerCC))
        );
    }

    function _readInstall(IPhase2BalanceTreasury t, address policy, uint64 before) private {
        _eq("install: treasury redemptionPolicy is the policy", t.redemptionPolicy(), policy);
        _check(
            "install: ccRedemptionEnabled is false (enable is its own send)",
            !t.ccRedemptionEnabled(),
            "setRedemptionPolicy turned it off"
        );
        _check(
            "install: configEpoch advanced",
            t.configEpoch() > before,
            string.concat("before ", vm.toString(uint256(before)), " after ", vm.toString(uint256(t.configEpoch())))
        );
    }

    function _readBudget(Inputs memory i, IPhase2BalanceTreasury t) private {
        _eq("budget: bidBudgetPerDay equals the input", t.bidBudgetPerDay(), i.budgetPerDay);
        _eq("budget: bidBudgetMax equals the input", t.bidBudgetMax(), i.budgetMax);
        uint256 carried = t.bidBudgetCarried();
        uint256 reserve = t.claimReserve();
        uint256 available = t.bidBudgetAvailable();
        _check(
            "budget: bidBudgetAvailable is the carried amount (at most the claim reserve)",
            available == (carried < reserve ? carried : reserve),
            string.concat(
                "available ",
                vm.toString(available),
                " carried ",
                vm.toString(carried),
                " reserve ",
                vm.toString(reserve)
            )
        );
        _info(
            "budget: accrues per day up to the maximum, never above the claim reserve",
            _two(i.budgetPerDay, i.budgetMax)
        );
    }

    /// @dev the sample burn of 1 CC: executable, and quoted at the policy's bid net of the fee when the budget covers it,
    /// else at the proportional share net of the fee
    function _readEnable(Preview memory p, IPhase2BalanceTreasury t, IStandingBidPolicy policy) private {
        _check("enable: ccRedemptionEnabled is true", t.ccRedemptionEnabled(), "setSwitches");
        _check(
            "enable: conversion and workingPayments kept as they were",
            t.conversionEnabled() == p.conversion && t.workingPaymentsEnabled() == p.workingPayments,
            string.concat(vm.toString(t.conversionEnabled()), " / ", vm.toString(t.workingPaymentsEnabled()))
        );
        (uint256 want, bool atBid, string memory detail) = _expectedQuote(t, policy);
        (uint256 out,,,, bool executable) = t.quoteRedemption(SAMPLE_CC);
        _check("enable: quoteRedemption(1e18 CC) is executable", executable, vm.toString(out));
        _check(
            atBid
                ? "enable: the quote is the policy's bid (the budget covers it)"
                : "enable: the quote is the proportional share (the bid unusable or above the budget)",
            out == want && out != 0,
            string.concat("quote ", vm.toString(out), " ", detail)
        );
    }

    /// @dev what `quoteRedemption(1e18)` must answer, computed from the policy's bid, the treasury's terms and its fee
    function _expectedQuote(IPhase2BalanceTreasury t, IStandingBidPolicy policy)
        private
        view
        returns (uint256 want, bool atBid, string memory detail)
    {
        (uint256 share, uint256 budget,) = t.redemptionTerms(SAMPLE_CC);
        (uint256 bid, bool usable) = policy.bidFor(SAMPLE_CC);
        uint256 fee = t.redemptionFeeBps();
        uint256 shareNet = share * (BPS - fee) / BPS;
        uint256 bidNet = bid * (BPS - fee) / BPS;
        atBid = usable && bidNet > shareNet && bidNet <= budget;
        want = atBid ? bidNet : shareNet;
        detail = string.concat(
            "bid ",
            vm.toString(bid),
            " share ",
            vm.toString(share),
            " budget ",
            vm.toString(budget),
            " fee bps ",
            vm.toString(fee)
        );
    }

    // ------------------------------------------------------------------ reads

    /// @dev the live coin pool spot, wei per 1e18 CC, from the Core's pool key; zero without an initialized pool
    function _liveSpot(ICore core) internal view returns (uint256) {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(core.COIN()),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        (uint160 sqrtPriceX96,,,) = IPoolManager(core.MANAGER()).getSlot0(k.toId());
        if (sqrtPriceX96 == 0) return 0;
        uint256 q = FixedPoint96.Q96;
        uint256 s = sqrtPriceX96;
        return (1e18 * q / s) * q / s;
    }

    /// @dev ControllerV2's protected sale price of the balance token, wei per 1e18 base units, the policy's balance leg;
    /// zero while the controller does not answer or its reference is unusable
    function _balanceLeg(ICore core, IPhase2BalanceTreasury t) internal view returns (uint256) {
        address controller = core.controller();
        if (controller.code.length == 0) return 0;
        (bool ok, bytes memory ret) = controller.staticcall(abi.encodeCall(IControllerV2.valuePerPoint, (true)));
        if (!ok || ret.length < 64) return 0;
        (uint256 value, bool usable) = abi.decode(ret, (uint256, bool));
        if (!usable || value == 0) return 0;
        return FixedPointMathLib.fullMulDiv(value, 1e18, POINT_UNIT * t.unitPerPoint());
    }

    function _isStandingBid(address policy) private view returns (bool) {
        return keccak256(bytes(_version(policy))) == keccak256(bytes(BID_VERSION));
    }

    /// @dev `VERSION()` of a policy, "none" for a policy without it
    function _version(address policy) private view returns (string memory) {
        if (policy.code.length == 0) return "none";
        (bool ok, bytes memory ret) = policy.staticcall(abi.encodeCall(IStandingBidPolicy.VERSION, ()));
        if (!ok || ret.length < 64) return "none";
        return abi.decode(ret, (string));
    }

    function _quoteOf(IStandingBidPolicy policy) private view returns (Quote memory q) {
        (
            q.referenceRateBpsPerHour,
            q.referenceStepBps,
            q.tolBps,
            q.referenceMaxStale,
            q.referenceMinSeconds,
            q.minLiquidity
        ) = policy.bidQuote();
    }

    // ------------------------------------------------------------------ the environment

    function _inputs() internal view returns (Inputs memory i) {
        i.treasury = vm.envAddress("TREASURY");
        i.policy = vm.envOr("POLICY", address(0));
        i.premiumBps = uint16(_envWidth("BID_PREMIUM_BPS", 100, type(uint16).max));
        i.quote = Quote({
            referenceRateBpsPerHour: uint32(_envWidth("BID_QUOTE_REFERENCE_RATE_BPS_PER_HOUR", 200, type(uint32).max)),
            referenceStepBps: uint16(_envWidth("BID_QUOTE_REFERENCE_STEP_BPS", 100, type(uint16).max)),
            tolBps: uint16(_envWidth("BID_QUOTE_TOL_BPS", 0, type(uint16).max)),
            referenceMaxStale: uint32(_envWidth("BID_QUOTE_REFERENCE_MAX_STALE", 86_400, type(uint32).max)),
            referenceMinSeconds: uint32(_envWidth("BID_QUOTE_REFERENCE_MIN_SECONDS", 600, type(uint32).max)),
            minLiquidity: uint128(_envWidth("BID_QUOTE_MIN_LIQUIDITY", 0, type(uint128).max))
        });
        i.expectedSpot = vm.envOr("BID_EXPECTED_SPOT", uint256(0));
        i.budgetPerDay = uint128(_envWidth("BID_BUDGET_PER_DAY", 0, type(uint128).max));
        i.budgetMax = uint128(_envWidth("BID_BUDGET_MAX", 0, type(uint128).max));
        i.allowLargeBudget = vm.envOr("ALLOW_LARGE_BID_BUDGET", uint256(0)) == 1;
        i.step = _step(vm.envString("STEP"));
    }

    function _envWidth(string memory key, uint256 dflt, uint256 max) private view returns (uint256 v) {
        v = vm.envOr(key, dflt);
        if (v > max) revert ValueTooWide(key);
    }

    function _step(string memory s) internal pure returns (Step) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("deploy")) return Step.Deploy;
        if (h == keccak256("configure")) return Step.Configure;
        if (h == keccak256("install")) return Step.Install;
        if (h == keccak256("budget")) return Step.Budget;
        if (h == keccak256("enable")) return Step.Enable;
        if (h == keccak256("all")) return Step.All;
        revert BadStep(s);
    }

    function _stepName(Step s) internal pure returns (string memory) {
        if (s == Step.Deploy) return "deploy";
        if (s == Step.Configure) return "configure";
        if (s == Step.Install) return "install";
        if (s == Step.Budget) return "budget";
        if (s == Step.Enable) return "enable";
        return "all";
    }

    // ------------------------------------------------------------------ the record

    /// @dev one `record: {json}` line: the step, the policy, its runtime code hash, the live settings and the budget
    function _record(Inputs memory i, Preview memory p, Result memory r) private view {
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(i.treasury);
        string memory head = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"block":',
            vm.toString(block.number),
            ',"step":"',
            _stepName(i.step),
            '","treasury":"',
            vm.toString(i.treasury),
            '","policy":"',
            vm.toString(r.policy),
            '","policyCodeHash":"',
            vm.toString(r.policy.codehash),
            '","policyVersion":"',
            _version(r.policy),
            '"'
        );
        console.log(string.concat("record: ", head, _recordSettings(p, r), _recordTreasury(t), "}"));
    }

    function _recordSettings(Preview memory p, Result memory r) private view returns (string memory) {
        IStandingBidPolicy policy = IStandingBidPolicy(r.policy);
        Quote memory q = _quoteOf(policy);
        return string.concat(
            ',"settings":{"premiumBps":',
            vm.toString(uint256(policy.premiumBps())),
            ',"quote":{"referenceRateBpsPerHour":',
            vm.toString(uint256(q.referenceRateBpsPerHour)),
            ',"referenceStepBps":',
            vm.toString(uint256(q.referenceStepBps)),
            ',"tolBps":',
            vm.toString(uint256(q.tolBps)),
            ',"referenceMaxStale":',
            vm.toString(uint256(q.referenceMaxStale)),
            ',"referenceMinSeconds":',
            vm.toString(uint256(q.referenceMinSeconds)),
            ',"minLiquidity":',
            vm.toString(uint256(q.minLiquidity)),
            '},"expectedSpot":',
            vm.toString(p.expectedSpot),
            ',"referencePrice":',
            vm.toString(policy.referencePrice()),
            "}"
        );
    }

    function _recordTreasury(IPhase2BalanceTreasury t) private view returns (string memory) {
        return string.concat(
            ',"budget":{"perDay":',
            vm.toString(uint256(t.bidBudgetPerDay())),
            ',"max":',
            vm.toString(uint256(t.bidBudgetMax())),
            ',"available":',
            vm.toString(t.bidBudgetAvailable()),
            '},"treasury":{"redemptionPolicy":"',
            vm.toString(t.redemptionPolicy()),
            '","ccRedemptionEnabled":',
            vm.toString(t.ccRedemptionEnabled()),
            ',"configEpoch":',
            vm.toString(uint256(t.configEpoch())),
            "}"
        );
    }

    function _two(uint256 a, uint256 b) private pure returns (string memory) {
        return string.concat(vm.toString(a), " / ", vm.toString(b));
    }

    function _trio(uint256 a, uint256 b, uint256 c) private pure returns (string memory) {
        return string.concat(vm.toString(a), " / ", vm.toString(b), " / ", vm.toString(c));
    }
}
