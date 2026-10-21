// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {CreditSale, Quote, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Phase2Checks} from "./Phase2Readback.s.sol";

/// @notice the balance token reads the deploy preview checks (plan section 5 item 4, the treasury constructor)
interface IBalanceTokenPreview {
    function statements() external view returns (address);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice stage A of docs/reviews/PHASE2-PLAN-fd85ba5-2026-10-20.md section 8: the disabled deployment of
/// ProRataRedemptionPolicy, Phase2BalanceTreasury(core, balanceToken, policy, no predecessor) and
/// ControllerV2(core, the live credit sale of the current controller, a zero quote, multiplier, delay). nothing on the
/// Core changes. the three contracts are created from their via_ir artifacts in `out/`, so this script compiles on the
/// default profile and the readback compares the created code against the pinned build.
/// `CORE=0x... BALANCE_TOKEN=0x... forge script script/Phase2Deploy.s.sol --rpc-url $MAINNET_RPC_URL`
/// simulates and prints "no send". add `SEND=1 --broadcast` with a signer (any account, the contracts read authority
/// from the Core owner) to send. `PHASE2_STATEMENT_MULTIPLIER_BPS` (default 15000, decision 256) and
/// `PHASE2_STATEMENT_DELAY_SECONDS` (default 3600) are the ControllerV2 statement policy. the preview refuses a balance
/// token that does not answer the treasury constructor's checks before anything is created. the run ends with one
/// `record: {json}` line for deployments/1-phase2.json
contract Phase2Deploy is Script, Phase2Checks {
    /// @dev a creation returned no code
    error CreateFailed(string name);

    uint32 internal constant DEFAULT_STATEMENT_MULTIPLIER_BPS = 15_000;
    uint32 internal constant DEFAULT_STATEMENT_DELAY_SECONDS = 3_600;

    struct Inputs {
        address core;
        address balanceToken;
        uint32 statementSaleMultiplierBps;
        uint32 statementRedeemDelaySeconds;
        /// the expected runtime code hash of the balance token (`BALANCE_TOKEN_CODEHASH`), zero only with
        /// `ALLOW_UNPINNED_BALANCE_TOKEN=1`: three getters cannot authenticate a token, its verified runtime can
        bytes32 tokenCodehash;
        bool allowUnpinnedToken;
    }

    /// @dev an environment integer that must fit a uint32; a silent narrowing would deploy other terms than entered
    function _envUint32(string memory key, uint256 dflt) private view returns (uint32) {
        uint256 v = vm.envOr(key, dflt);
        if (v > type(uint32).max) revert ValueTooWide(key);
        return uint32(v);
    }

    error ValueTooWide(string key);
    error PlanHashMismatch(bytes32 want, bytes32 given);

    struct Result {
        address policy;
        address treasury;
        address controllerV2;
        CreditSale credit;
    }

    function run() external returns (Result memory) {
        Inputs memory i = Inputs({
            core: vm.envAddress("CORE"),
            balanceToken: vm.envAddress("BALANCE_TOKEN"),
            statementSaleMultiplierBps: _envUint32("PHASE2_STATEMENT_MULTIPLIER_BPS", DEFAULT_STATEMENT_MULTIPLIER_BPS),
            statementRedeemDelaySeconds: _envUint32("PHASE2_STATEMENT_DELAY_SECONDS", DEFAULT_STATEMENT_DELAY_SECONDS),
            tokenCodehash: vm.envOr("BALANCE_TOKEN_CODEHASH", bytes32(0)),
            allowUnpinnedToken: vm.envOr("ALLOW_UNPINNED_BALANCE_TOKEN", uint256(0)) == 1
        });
        bool send = vm.envOr("SEND", uint256(0)) == 1;
        // a send needs the plan hash the preview printed, so what is sent is what was reviewed (the CONFIG_HASH
        // pattern of script/Deploy.s.sol)
        if (send) {
            bytes32 want = planHash(i, _liveCredit(i.core));
            bytes32 given = vm.envOr("PHASE2_PLAN_HASH", bytes32(0));
            if (given != want) revert PlanHashMismatch(want, given);
        }
        return deployPhase2(i, send);
    }

    /// @notice the hash of everything the deployment depends on: the Core, the token and its runtime code, the policy
    /// terms and the live credit sale settings. printed by the preview, required as `PHASE2_PLAN_HASH` by a send
    function planHash(Inputs memory i, CreditSale memory credit) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                i.core,
                i.balanceToken,
                i.balanceToken.codehash,
                i.statementSaleMultiplierBps,
                i.statementRedeemDelaySeconds,
                credit
            )
        );
    }

    /// @notice the preview, the three creations (broadcast only with `send`), the readback and the record line. a test
    /// calls it with its own inputs and `send` false
    function deployPhase2(Inputs memory i, bool send) internal returns (Result memory r) {
        r.credit = _liveCredit(i.core);
        _preview(i, r.credit);
        _info("preview: plan hash (PHASE2_PLAN_HASH of a send)", vm.toString(planHash(i, r.credit)));
        _print("phase 2 deploy preview");
        _require();
        _reset();
        if (send) vm.startBroadcast();
        else console.log("no send: SEND is not 1, the three creations are simulated only");
        r.policy = _create("ProRataRedemptionPolicy", "");
        r.treasury = _create("Phase2BalanceTreasury", abi.encode(i.core, i.balanceToken, r.policy, address(0)));
        Quote memory none;
        r.controllerV2 = _create(
            "ControllerV2",
            abi.encode(i.core, r.credit, none, i.statementSaleMultiplierBps, i.statementRedeemDelaySeconds)
        );
        if (send) vm.stopBroadcast();
        phase2Readback(i.core, r.treasury, r.controllerV2);
        _disabled(i, r);
        _print(send ? "phase 2 deploy readback" : "phase 2 deploy readback of the simulation");
        _require();
        _record(i, r);
    }

    /// @dev the credit sale the current controller runs, carried over unchanged (plan section 4.3)
    function _liveCredit(address core) internal view returns (CreditSale memory c) {
        IControllerV1 live = IControllerV1(ICore(payable(core)).controller());
        c = CreditSale({
            saleOn: live.creditSaleOn(),
            window: live.creditWindow(),
            spreadBps: live.creditSpreadBps(),
            startBps: live.creditStartBps()
        });
    }

    /// @dev the rows the treasury constructor would refuse, read as staticcalls so a wrong address is a failed row and
    /// not a raw revert, then the constructor arguments of each creation
    function _preview(Inputs memory i, CreditSale memory credit) private {
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _code("preview: Core has code", i.core);
        _previewCoin(i.core);
        _code("preview: balance token has code", i.balanceToken);
        _previewToken(i.balanceToken);
        _previewTokenIdentity(i);
        _check(
            "preview: statement multiplier at least 10000 bps and delay nonzero",
            i.statementSaleMultiplierBps >= 10_000 && i.statementRedeemDelaySeconds != 0,
            _policyText(i)
        );
        _info("deploy 1: ProRataRedemptionPolicy()", "no constructor arguments");
        _info(
            "deploy 2: Phase2BalanceTreasury(core, balanceToken, policy, predecessor)",
            string.concat(vm.toString(i.core), ", ", vm.toString(i.balanceToken), ", <deploy 1>, 0x0")
        );
        _info(
            "deploy 3: ControllerV2(core, credit, quote, multiplierBps, delaySeconds)",
            string.concat(vm.toString(i.core), ", credit ", _creditText(credit), ", quote zero, ", _policyText(i))
        );
    }

    function _previewCoin(address core) private {
        (bool ok, address coin) = _addr(core, abi.encodeCall(ICore.COIN, ()));
        _check("preview: Core coin has code", ok && coin.code.length != 0, vm.toString(coin));
    }

    /// @dev the balance token's runtime identity: three getters cannot authenticate it, its verified runtime code hash
    /// can. the pin is required unless the operator waives it explicitly (a standin on a fork)
    function _previewTokenIdentity(Inputs memory i) private {
        bytes32 live = i.balanceToken.codehash;
        if (i.tokenCodehash == bytes32(0)) {
            _check(
                "preview: balance token runtime pinned (BALANCE_TOKEN_CODEHASH) or the pin waived (ALLOW_UNPINNED_BALANCE_TOKEN=1)",
                i.allowUnpinnedToken,
                string.concat("live codehash ", vm.toString(live))
            );
            return;
        }
        _check(
            "preview: balance token runtime code hash equals BALANCE_TOKEN_CODEHASH",
            live == i.tokenCodehash,
            string.concat("live ", vm.toString(live), " pinned ", vm.toString(i.tokenCodehash))
        );
    }

    /// @dev the three answers the treasury constructor requires of the balance token
    function _previewToken(address token) private {
        (bool okS, address statements) = _addr(token, abi.encodeCall(IBalanceTokenPreview.statements, ()));
        _check(
            "preview: balance token statements() is the Statements contract",
            okS && statements == Mainnet.STATEMENTS,
            vm.toString(statements)
        );
        (bool okU, uint256 unit) = _word(token, abi.encodeCall(IBalanceTokenPreview.SCORE_TO_TOKEN, ()));
        _check("preview: balance token SCORE_TO_TOKEN() is 1e14", okU && unit == 1e14, vm.toString(unit));
        (bool okD, uint256 dec) = _word(token, abi.encodeCall(IBalanceTokenPreview.decimals, ()));
        _check("preview: balance token decimals() is 18", okD && dec == 18, vm.toString(dec));
    }

    function _policyText(Inputs memory i) private pure returns (string memory) {
        return string.concat(
            vm.toString(uint256(i.statementSaleMultiplierBps)),
            ", ",
            vm.toString(uint256(i.statementRedeemDelaySeconds))
        );
    }

    function _creditText(CreditSale memory c) private pure returns (string memory) {
        return string.concat(
            "(saleOn ",
            vm.toString(c.saleOn),
            ", window ",
            vm.toString(uint256(c.window)),
            ", spreadBps ",
            vm.toString(uint256(c.spreadBps)),
            ", startBps ",
            vm.toString(uint256(c.startBps)),
            ")"
        );
    }

    /// @dev creates artifact `name` with `args` through a plain CREATE, which `forge script` broadcasts as a deployment
    /// of the signer when a broadcast is open
    function _create(string memory name, bytes memory args) private returns (address at) {
        bytes memory init = abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args);
        assembly {
            at := create(0, add(init, 0x20), mload(init))
        }
        if (at.code.length == 0) revert CreateFailed(name);
    }

    /// @dev the stage A rows: disabled, empty, not selected, and the constructor arguments read back
    function _disabled(Inputs memory i, Result memory r) private {
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(r.treasury);
        _check(
            "stage A: every treasury switch is off",
            !t.conversionEnabled() && !t.workingPaymentsEnabled() && !t.ccRedemptionEnabled(),
            "setSwitches not called"
        );
        _eq("stage A: claimReserve is 0", t.claimReserve(), 0);
        _eq("stage A: available is 0", t.available(), 0);
        _check("stage A: conversionReady is false", !t.conversionReady(), "conversionReady()");
        _check("stage A: treasury is not selected", !t.selected(), "setBalanceModule not called");
        _eq("stage A: treasury balanceToken is the input", t.balanceToken(), i.balanceToken);
        _eq("stage A: treasury predecessor is none", t.predecessor(), address(0));
        _eq("stage A: treasury policy is deploy 1", t.redemptionPolicy(), r.policy);
        IControllerV2 c = IControllerV2(r.controllerV2);
        _check("stage A: statementSalesEnabled is false", !c.statementSalesEnabled(), "setStatementSales not called");
        _eq(
            "stage A: statementSaleMultiplierBps is the input",
            c.statementSaleMultiplierBps(),
            i.statementSaleMultiplierBps
        );
        _eq(
            "stage A: statementRedeemDelaySeconds is the input",
            c.statementRedeemDelaySeconds(),
            i.statementRedeemDelaySeconds
        );
        _check(
            "stage A: ControllerV2 credit sale equals the live controller's",
            c.creditSaleOn() == r.credit.saleOn && c.creditWindow() == r.credit.window
                && c.creditSpreadBps() == r.credit.spreadBps && c.creditStartBps() == r.credit.startBps,
            _creditText(r.credit)
        );
        _check(
            "stage A: ControllerV2 balance pool key is not set", !c.balancePoolKeySet(), "setBalancePoolKey not called"
        );
        _check(
            "stage A: Core controller is still the live controller",
            ICore(payable(i.core)).controller() != r.controllerV2,
            "setController not called"
        );
    }

    /// @dev one `record: {json}` line: addresses, constructor arguments, the live runtime code hashes and the masked
    /// build pins, the policy version and the activation flags, all false at stage A
    function _record(Inputs memory i, Result memory r) private view {
        string memory head = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"block":',
            vm.toString(block.number),
            ',"core":"',
            vm.toString(i.core),
            '","balanceToken":"',
            vm.toString(i.balanceToken)
        );
        head = string.concat(
            head,
            '","policy":"',
            vm.toString(r.policy),
            '","treasury":"',
            vm.toString(r.treasury),
            '","controllerV2":"',
            vm.toString(r.controllerV2),
            '"'
        );
        console.log(string.concat("record: ", head, _recordArgs(i, r), _recordHashes(r), _recordFlags()));
    }

    function _recordArgs(Inputs memory i, Result memory r) private pure returns (string memory) {
        string memory treasury = string.concat(
            '"treasury":{"core":"',
            vm.toString(i.core),
            '","balanceToken":"',
            vm.toString(i.balanceToken),
            '","policy":"',
            vm.toString(r.policy),
            '","predecessor":"',
            vm.toString(address(0)),
            '"}'
        );
        string memory controller = string.concat(
            '"controllerV2":{"core":"',
            vm.toString(i.core),
            '","credit":{"saleOn":',
            vm.toString(r.credit.saleOn),
            ',"window":',
            vm.toString(uint256(r.credit.window)),
            ',"spreadBps":',
            vm.toString(uint256(r.credit.spreadBps)),
            ',"startBps":',
            vm.toString(uint256(r.credit.startBps)),
            '},"quote":{"referenceRateBpsPerHour":0,"referenceStepBps":0,"tolBps":0,"referenceMaxStale":0,"referenceMinSeconds":0,"minLiquidity":0},"statementSaleMultiplierBps":',
            vm.toString(uint256(i.statementSaleMultiplierBps)),
            ',"statementRedeemDelaySeconds":',
            vm.toString(uint256(i.statementRedeemDelaySeconds)),
            "}"
        );
        return string.concat(',"constructorArgs":{"policy":{},', treasury, ",", controller, "}");
    }

    function _recordHashes(Result memory r) private view returns (string memory) {
        return string.concat(
            ',"codeHashes":{"policy":"',
            vm.toString(r.policy.codehash),
            '","treasury":"',
            vm.toString(r.treasury.codehash),
            '","controllerV2":"',
            vm.toString(r.controllerV2.codehash),
            '"},"buildHashes":{"policy":"',
            vm.toString(BUILD_HASH_PRO_RATA_POLICY),
            '","treasury":"',
            vm.toString(BUILD_HASH_PHASE2_TREASURY),
            '","controllerV2":"',
            vm.toString(BUILD_HASH_CONTROLLER_V2),
            '"}'
        );
    }

    function _recordFlags() private pure returns (string memory) {
        return string.concat(
            ',"policyVersion":"',
            POLICY_VERSION,
            '","activation":{"balanceModuleSet":false,"controllerSet":false,"conversionEnabled":false,"workingPaymentsEnabled":false,"ccRedemptionEnabled":false,"statementSalesEnabled":false,"balancePoolKeySet":false}}'
        );
    }
}
