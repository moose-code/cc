// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IProRataRedemptionPolicy} from "../src/interfaces/IProRataRedemptionPolicy.sol";
import {Settings, IBalanceModule, ICreditScore, ICredits, Mainnet} from "../src/interfaces/Interfaces.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice the read only rows of the phase 2 stack (docs/reviews/PHASE2-PLAN-fd85ba5-2026-10-20.md section 8): the
/// build pins, the live code, the treasury bindings and state, the ControllerV2 state and the Core side. shared by
/// `Phase2Readback` (any time, against mainnet) and `Phase2Deploy` (on the simulated or sent deployment). a row that
/// proves identity (hash, Core binding, coin, owner, policy) or the hazard state is a check and fails the run; every
/// state value is an information row, because the same table serves every activation stage
abstract contract Phase2Checks is LaunchChecks {
    /// @dev the policy the treasury is deployed with (plan section 4.2)
    string internal constant POLICY_VERSION = "pro-rata-v1";

    /// @notice every phase 2 row. `controllerV2` zero skips the controller rows
    /// @dev the working gain per 100 BALANCE funded points at the posted payout, the purchase royalty (a share of the
    /// payout) and the claim earmark, bps of the rating. a Credit the engine acquires with ETH and inventory it already
    /// holds carry a different cost, so this is the BALANCE funded margin only. a non positive margin fails the run
    /// while working payments are on, unless ACCEPT_NONPOSITIVE_MARGIN=1 records the owner's approval
    /// @dev the real token's `unreleasedSupply()`, "n/a" on a token without it (the standin)
    function _unreleased(address token) private view returns (string memory) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("unreleasedSupply()"));
        if (!ok || ret.length < 32) return "n/a";
        return vm.toString(abi.decode(ret, (uint256)));
    }

    function _marginRow(ICore core, IPhase2BalanceTreasury t) private {
        Settings memory s = core.settings();
        uint256 payout = 10_000 - s.balanceDiscountBps;
        uint256 royalty = payout * s.buyToArtistBps / 10_000;
        uint256 earmark = t.conversionToClaimBps();
        int256 margin = int256(10_000) - int256(payout) - int256(royalty) - int256(earmark);
        string memory text = string.concat(
            "payout ",
            vm.toString(payout),
            " royalty ",
            vm.toString(royalty),
            " earmark ",
            vm.toString(earmark),
            " margin bps ",
            margin < 0 ? string.concat("-", vm.toString(uint256(-margin))) : vm.toString(uint256(margin))
        );
        bool accepted = _acceptNonPositiveMargin();
        _check(
            "margin: working gain per 100 BALANCE funded points is positive while working payments are on (ACCEPT_NONPOSITIVE_MARGIN=1 records approval)",
            margin > 0 || !t.workingPaymentsEnabled() || accepted,
            text
        );
    }

    /// @dev the owner's recorded approval of a non positive margin (`ACCEPT_NONPOSITIVE_MARGIN=1`). a test overrides it
    function _acceptNonPositiveMargin() internal view virtual returns (bool) {
        return vm.envOr("ACCEPT_NONPOSITIVE_MARGIN", uint256(0)) == 1;
    }

    function phase2Readback(address core, address treasury, address controllerV2) internal {
        _phase2Pins();
        bool ok = _phase2Treasury(ICore(payable(core)), treasury);
        if (ok) _phase2Policy(IPhase2BalanceTreasury(treasury).redemptionPolicy());
        if (controllerV2 != address(0)) _phase2Controller(core, controllerV2);
        _phase2Core(ICore(payable(core)), treasury, controllerV2);
    }

    /// @dev out/ equals the pinned build, so a later "live code equals out/" row is a check against the pin
    function _phase2Pins() private {
        _pin("ControllerV2", BUILD_HASH_CONTROLLER_V2);
        _pin("Phase2BalanceTreasury", BUILD_HASH_PHASE2_TREASURY);
        _pin("ProRataRedemptionPolicy", BUILD_HASH_PRO_RATA_POLICY);
    }

    function _pin(string memory name, bytes32 want) private {
        bytes32 got = artifactHash(name);
        _check(
            string.concat("build: ", name, " out/ runtime hash equals the pinned build"),
            got == want,
            string.concat("out/ ", vm.toString(got))
        );
    }

    /// @dev the identity rows of the treasury, then its state. returns false when the code is not the artifact, in which
    /// case no further read is attempted on it
    function _phase2Treasury(ICore core, address at) private returns (bool ok) {
        ok = runtimeMatchesArtifact(at, "Phase2BalanceTreasury");
        _check("treasury: runtime code is the compiled Phase2BalanceTreasury (immutables masked)", ok, vm.toString(at));
        if (!ok) return false;
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(at);
        _eq("treasury: core is the Core", t.core(), address(core));
        _eq("treasury: ccToken is the Core coin", t.ccToken(), core.COIN());
        _eq("treasury: owner is the Core owner", t.owner(), core.owner());
        address selectedToken = core.balanceToken();
        _check(
            "treasury: balanceToken is the Core's balance token, or none is selected yet",
            selectedToken == address(0) || selectedToken == t.balanceToken(),
            string.concat("treasury ", vm.toString(t.balanceToken()), " core ", vm.toString(selectedToken))
        );
        _check(
            "treasury: predecessor is none or a contract",
            t.predecessor() == address(0) || t.predecessor().code.length != 0,
            vm.toString(t.predecessor())
        );
        _check("treasury: unitPerPoint is 1e14", t.unitPerPoint() == 1e14, vm.toString(t.unitPerPoint()));
        _treasuryState(core, t);
    }

    function _treasuryState(ICore core, IPhase2BalanceTreasury t) private {
        _info(
            "treasury: switches conversion / workingPayments / ccRedemption",
            string.concat(
                vm.toString(t.conversionEnabled()),
                " / ",
                vm.toString(t.workingPaymentsEnabled()),
                " / ",
                vm.toString(t.ccRedemptionEnabled())
            )
        );
        _info("treasury: claimReserve", vm.toString(t.claimReserve()));
        _info("treasury: totalOwed", vm.toString(t.totalOwed()));
        _info("treasury: custody / working / freeWorking", _three(t.custody(), t.working(), t.freeWorking()));
        _info("treasury: minimumWorkingBalance", vm.toString(t.minimumWorkingBalance()));
        _info(
            "treasury: conversionToClaimBps / redemptionFeeBps",
            string.concat(
                vm.toString(uint256(t.conversionToClaimBps())), " / ", vm.toString(uint256(t.redemptionFeeBps()))
            )
        );
        _marginRow(core, t);
        _info(
            "token: unreleasedSupply (the real token's release cap; a conversion above it reverts)",
            _unreleased(t.balanceToken())
        );
        _info("treasury: configEpoch", vm.toString(uint256(t.configEpoch())));
        _info("treasury: migrated", vm.toString(t.migrated()));
        _info("treasury: selected", vm.toString(t.selected()));
        _info(
            "treasury: conversionReady / transfersReady",
            string.concat(vm.toString(t.conversionReady()), " / ", vm.toString(t.transfersReady()))
        );
        _info("treasury: available", vm.toString(t.available()));
        _check("treasury: solvent (custody covers claimReserve and totalOwed)", t.solvent(), "solvent()");
    }

    function _three(uint256 a, uint256 b, uint256 c) private pure returns (string memory) {
        return string.concat(vm.toString(a), " / ", vm.toString(b), " / ", vm.toString(c));
    }

    /// @dev the policy the treasury points at: the compiled ProRataRedemptionPolicy with the expected version
    function _phase2Policy(address at) private {
        bool ok = runtimeMatchesArtifact(at, "ProRataRedemptionPolicy");
        _check("policy: runtime code is the compiled ProRataRedemptionPolicy", ok, vm.toString(at));
        if (!ok) return;
        IProRataRedemptionPolicy p = IProRataRedemptionPolicy(at);
        _eq("policy: VERSION", p.VERSION(), POLICY_VERSION);
        _check("policy: isRedemptionPolicy", p.isRedemptionPolicy(), "isRedemptionPolicy()");
    }

    function _phase2Controller(address core, address at) private {
        bool ok = runtimeMatchesArtifact(at, "ControllerV2");
        _check("controllerV2: runtime code is the compiled ControllerV2 (immutables masked)", ok, vm.toString(at));
        if (!ok) return;
        IControllerV2 c = IControllerV2(at);
        _eq("controllerV2: CORE is the Core", c.CORE(), core);
        _info("controllerV2: statementSalesEnabled", vm.toString(c.statementSalesEnabled()));
        _info(
            "controllerV2: statementSaleMultiplierBps / statementRedeemDelaySeconds",
            string.concat(
                vm.toString(uint256(c.statementSaleMultiplierBps())),
                " / ",
                vm.toString(uint256(c.statementRedeemDelaySeconds()))
            )
        );
        _info(
            "controllerV2: credit saleOn / window / spreadBps / startBps",
            string.concat(
                vm.toString(c.creditSaleOn()),
                " / ",
                vm.toString(uint256(c.creditWindow())),
                " / ",
                vm.toString(uint256(c.creditSpreadBps())),
                " / ",
                vm.toString(uint256(c.creditStartBps()))
            )
        );
        _info("controllerV2: balancePoolKeySet", vm.toString(c.balancePoolKeySet()));
        _controllerQuote(c);
    }

    function _controllerQuote(IControllerV2 c) private {
        (uint32 rate, uint16 step, uint16 tol, uint32 maxStale, uint32 minSeconds, uint128 minLiquidity) = c.quote();
        _info(
            "controllerV2: quote rate / step / tol / maxStale / minSeconds / minLiquidity",
            string.concat(_three(rate, step, tol), " / ", _three(maxStale, minSeconds, minLiquidity))
        );
    }

    /// @dev the Core side: pointers, locks, the settings fields of the phase 2 patch and the stage C switches, the legacy
    /// pots and the hazard row
    function _phase2Core(ICore core, address treasury, address controllerV2) private {
        address module = core.balanceModule();
        _info(
            "core: balanceModule",
            string.concat(vm.toString(module), module == treasury ? " (the treasury)" : " (not the treasury)")
        );
        _info("core: balanceToken", vm.toString(core.balanceToken()));
        _tokenPin(treasury);
        address ctl = core.controller();
        _info(
            "core: controller",
            string.concat(vm.toString(ctl), ctl == controllerV2 ? " (ControllerV2)" : " (not the ControllerV2 given)")
        );
        _info(
            "core: locks adapters / balanceModule / controller / successor",
            string.concat(
                vm.toString(core.adaptersLocked()),
                " / ",
                vm.toString(core.balanceModuleLocked()),
                " / ",
                vm.toString(core.controllerLocked()),
                " / ",
                vm.toString(core.successorLocked())
            )
        );
        _info("core: paused / retired", string.concat(vm.toString(core.paused()), " / ", vm.toString(core.retired())));
        Settings memory s = core.settings();
        _info(
            "core: settings saleToBuybackBps / feeToRedeemBurnBps / redeemBurnBps",
            _three(s.saleToBuybackBps, s.feeToRedeemBurnBps, s.redeemBurnBps)
        );
        _info(
            "core: settings redeemOn / balanceBidOn / valueModeOn / spendCapBps",
            string.concat(
                vm.toString(s.redeemOn),
                " / ",
                vm.toString(s.balanceBidOn),
                " / ",
                vm.toString(s.valueModeOn),
                " / ",
                vm.toString(uint256(s.spendCapBps))
            )
        );
        _info("core: creditCostToPotBps", vm.toString(uint256(core.creditCostToPotBps())));
        address artist = core.artist();
        _info(
            "core: artist (the split of decision 255 once wired) / its runtime code hash",
            string.concat(vm.toString(artist), " / ", vm.toString(artist.codehash))
        );
        _info(
            "core: settings buyToArtistBps / saleToArtistBps / saleToOperatorBps",
            _three(s.buyToArtistBps, s.saleToArtistBps, s.saleToOperatorBps)
        );
        _payouts(core, ctl, s);
        _info(
            "core: legacy pots ethToBuyback / ethRedeemBurn (wei)",
            string.concat(vm.toString(core.ethToBuyback()), " / ", vm.toString(core.ethRedeemBurn()))
        );
        _hazard(s, ctl, controllerV2);
    }

    /// @dev the executable BALANCE payout of representative pile Credits against the posted rate, and which constraint
    /// binds: the value mode clamp (`balanceClampFor`, the eth bid for the score at the protected sale price, which
    /// `rateCap` bounds), the module's `available()` (working funds and the floor), or the posted rate. `PAYOUT_CREDIT_IDS`
    /// names the Credits (comma separated), else the first five of the pile. while the balance bid is on, a sampled
    /// payout under 95 percent of the posted rate fails the run unless `ACCEPT_PAYOUT_SHORTFALL=1` records the owner's
    /// approval; raising `rateCap` to restore the rate also raises the eth acquisition prices and is never done here
    function _payouts(ICore core, address ctl, Settings memory s) private {
        address module = core.balanceModule();
        if (module == address(0) || module.code.length == 0) {
            _info("payout: no balance module selected, no executable payout to sample", "");
            return;
        }
        uint256[] memory ids = _payoutIds(core);
        if (ids.length == 0) {
            _info("payout: the pile is empty and PAYOUT_CREDIT_IDS is unset, nothing to sample", "");
            return;
        }
        uint256 unit = IBalanceModule(module).unitPerPoint();
        uint256 rate = core.balanceRate();
        bool shortfall;
        for (uint256 i; i < ids.length; ++i) {
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE)
                .scoreOf(ICredits(Mainnet.CREDITS).seedOf(ids[i]), ICredits(Mainnet.CREDITS).timestampOf(ids[i]));
            uint256 posted = score * unit * rate / 10_000;
            uint256 executable = core.balanceBidOf(ids[i]);
            (uint256 clamp, bool clampOk) = _clamp(ctl, score, posted);
            string memory binding = !s.balanceBidOn
                ? "balanceBidOn off"
                : (s.valueModeOn && clampOk && clamp < posted)
                    ? "value clamp: ethPrice over the protected sale price (rateCap bounds it)"
                    : executable == 0 ? "available(): working funds or the floor" : "posted rate";
            _info(
                string.concat("payout: credit ", vm.toString(ids[i])),
                string.concat(
                    "score ",
                    vm.toString(score),
                    " posted ",
                    vm.toString(posted),
                    " executable ",
                    vm.toString(executable),
                    " binding: ",
                    binding
                )
            );
            if (s.balanceBidOn && executable < posted * 95 / 100) shortfall = true;
        }
        _check(
            "payout: every sampled executable payout is within 5 percent of the posted rate while the bid is on, or ACCEPT_PAYOUT_SHORTFALL=1 records the owner's approval",
            !shortfall || vm.envOr("ACCEPT_PAYOUT_SHORTFALL", false),
            shortfall ? "a sampled payout is materially under the posted rate" : "no shortfall"
        );
    }

    function _payoutIds(ICore core) private view returns (uint256[] memory ids) {
        uint256[] memory given = vm.envOr("PAYOUT_CREDIT_IDS", ",", new uint256[](0));
        if (given.length != 0) return given;
        uint256 n = core.pileSize();
        if (n > 5) n = 5;
        if (n == 0) return ids;
        return core.pilePage(0, n);
    }

    /// @dev the controller's `balanceClampFor` through a staticcall that reports a failure as not ok
    function _clamp(address ctl, uint256 score, uint256 posted) private view returns (uint256 paid, bool ok) {
        (bool success, bytes memory ret) =
            ctl.staticcall(abi.encodeCall(IControllerV1.balanceClampFor, (score, posted)));
        if (!success || ret.length < 64) return (0, false);
        (paid, ok) = abi.decode(ret, (uint256, bool));
    }

    /// @dev the treasury's immutable balance token against the pinned runtime (`BALANCE_TOKEN_CODEHASH`); an info row
    /// without a pin, because three getters never authenticate a token
    function _tokenPin(address treasury) private {
        if (treasury.code.length == 0) return;
        address token = IPhase2BalanceTreasury(treasury).balanceToken();
        bytes32 pinned = vm.envOr("BALANCE_TOKEN_CODEHASH", bytes32(0));
        if (pinned == bytes32(0)) {
            _info(
                "treasury: balance token runtime code hash (unpinned, set BALANCE_TOKEN_CODEHASH to check)",
                vm.toString(token.codehash)
            );
            return;
        }
        _check(
            "treasury: balance token runtime code hash equals BALANCE_TOKEN_CODEHASH",
            token.codehash == pinned,
            string.concat("live ", vm.toString(token.codehash), " pinned ", vm.toString(pinned))
        );
    }

    /// @dev the hazard state of docs/RUNBOOK.md (activation order): the balance bid on, value mode off and a balance pool
    /// key set on the live controller or on the ControllerV2 given. read through staticcalls that report a failure as
    /// "no key", so a controller without the getter cannot abort the table
    function _hazard(Settings memory s, address live, address controllerV2) private {
        (, bool liveKey) = _bool(live, abi.encodeCall(IControllerV1.balancePoolKeySet, ()));
        bool v2Key;
        if (controllerV2 != address(0)) {
            (, v2Key) = _bool(controllerV2, abi.encodeCall(IControllerV2.balancePoolKeySet, ()));
        }
        bool hazard = s.balanceBidOn && !s.valueModeOn && (liveKey || v2Key);
        _check(
            "hazard: balanceBidOn with valueModeOn off and a balance pool key set opens a round trip (docs/RUNBOOK.md)",
            !hazard,
            string.concat(
                "balanceBidOn ",
                vm.toString(s.balanceBidOn),
                " valueModeOn ",
                vm.toString(s.valueModeOn),
                " poolKeySet live ",
                vm.toString(liveKey),
                " v2 ",
                vm.toString(v2Key)
            )
        );
    }
}

/// @notice read only check of the phase 2 contracts against the pinned build and the live Core. safe to run against
/// mainnet at any time, at any activation stage.
/// `CORE=0x... TREASURY=0x... CONTROLLER_V2=0x... forge script script/Phase2Readback.s.sol --rpc-url $MAINNET_RPC_URL`
/// (CONTROLLER_V2 is optional). prints the table and reverts when a hash does not match the pin, the treasury is bound
/// to another Core, coin or owner, the policy is not the pinned pro rata policy, or the hazard state holds
contract Phase2Readback is Script, Phase2Checks {
    function run() external {
        phase2Readback(vm.envAddress("CORE"), vm.envAddress("TREASURY"), vm.envOr("CONTROLLER_V2", address(0)));
        _print("phase 2 readback");
        _require();
    }
}
