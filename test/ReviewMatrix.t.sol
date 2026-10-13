// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReviewHarness} from "./utils/ReviewHarness.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice the mutation matrix: the signed config or the chain state changes one thing at a time and the run must end in
/// one of four ways, never in a launch that passes every check with the signed hash. preflight fails the row of the
/// rule the change breaks (one mutation for every row a mutation can fail), the deploy reverts, the postflight reverts
/// the deploy, or the config hash differs from the signed one (a valid but different config). `runOne` runs a mutation in
/// its own call frame
contract ReviewMatrixConfigTest is ReviewHarness {
    uint256 internal constant N_STACK = 6;

    function _mutStack(uint256 i) internal view returns (Mut memory m) {
        address other = Mainnet.PERMIT2; // a contract that is not part of the stack
        if (i == 0) {
            m = _m("hook = a contract that is not the hook", Class.Pre);
            m.c.stack.hook = other;
        } else if (i == 1) {
            m = _m("locker = the escrow", Class.Pre);
            m.c.stack.locker = m.c.stack.escrow;
        } else if (i == 2) {
            m = _m("poolFee 3000 instead of the dynamic flag", Class.Pre);
            m.c.stack.poolFee = 3000;
        } else if (i == 3) {
            m = _m("tickSpacing 0", Class.Pre);
            m.c.stack.tickSpacing = 0;
        } else if (i == 4) {
            m = _m("mevModule = a contract that is not the module", Class.Pre);
            m.c.mevModule = other;
        } else {
            m = _m("factory = the zero address", Class.Pre);
            m.c.stack.factory = address(0);
        }
    }

    uint256 internal constant N_LAUNCH = 17;

    function _mutLaunch(uint256 i) internal view returns (Mut memory m) {
        if (i == 0) {
            m = _m("restricted off", Class.Pre);
            m.c.restricted = false;
        } else if (i == 1) {
            m = _m("startTick -1 spacing (-175200)", Class.Pre);
            m.c.startTick = -175_200;
        } else if (i == 2) {
            m = _m("supply 1e27 + 1", Class.Pre);
            m.c.supply = 1_000_000_000e18 + 1;
        } else if (i == 3) {
            m = _m("lpFeePips 5000", Class.Pre);
            m.c.lpFeePips = 5000;
        } else if (i == 4) {
            m = _m("baselineSkimBps 1000 (the v1 value)", Class.Pre);
            m.c.baselineSkimBps = 1_000;
        } else if (i == 5) {
            m = _m("bountyBps 0", Class.Pre);
            m.c.bountyBps = 0;
        } else if (i == 6) {
            m = _m("protocolBps 0 (no protocol locker slot)", Class.Pre);
            m.c.protocolBps = 0;
        } else if (i == 7) {
            m = _m("sniperStartBps 690 equal to the baseline", Class.Pre);
            m.c.sniperStartBps = 690;
        } else if (i == 8) {
            m = _m("sniperSeconds 300", Class.Pre);
            m.c.sniperSeconds = 300;
        } else if (i == 9) {
            m = _m("startTick and positionLower both -170000 (another start price)", Class.Hash);
            (m.c.startTick, m.c.positionLower) = (-170_000, -170_000);
        } else if (i == 10) {
            m = _m("name changed", Class.Hash);
            m.c.name = "Review Coin Two";
        } else if (i == 11) {
            m = _m("payee ppm 200001 (above the limit)", Class.Pre);
            m.c.settings.payeePpm = 200_001;
        } else if (i == 12) {
            m = _m("payee = the escrow", Class.Pre);
            m.c.payee = m.c.stack.escrow;
        } else if (i == 13) {
            m = _m("sale: markupBps 12000 (valid, wrong)", Class.Hash);
            m.c.sale.markupBps = 12_000;
        } else if (i == 14) {
            m = _m("sale: markupBps 40001", Class.Pre);
            m.c.sale.markupBps = 40_001;
        } else if (i == 15) {
            m = _m("credit: royaltyBps 1001", Class.Pre);
            m.c.credit.royaltyBps = 1_001;
        } else {
            m = _m("settings.dropPerCreditBps 100 (valid, wrong)", Class.Hash);
            m.c.settings.dropPerCreditBps = 100;
        }
    }

    uint256 internal constant N_MISC = 4;

    function _mutMisc(uint256 i) internal returns (Mut memory m) {
        address other = makeAddr("review.other.signer");
        vm.deal(other, 5 ether);
        if (i == 0) {
            m = _m("rateStart 1e14 (in bounds, not the signed value)", Class.Hash);
            m.c.rateStart = 1e14;
            m.c.settings.rateCap = 3e14;
        } else if (i == 1) {
            // rateStart above rateCap, both inside their bounds: the start-at-most-cap clause of the bounds row fails,
            // and 1e14 is not 3 times 2e14, so the ratio row fails with it
            m = _m("rateStart 2e14 above rateCap 1e14", Class.Pre);
            m.c.rateStart = 2e14;
            m.c.settings.rateCap = 1e14;
            m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_RATE_RATIO);
        } else if (i == 2) {
            m = _m("owner = the hook", Class.Pre);
            m.c.owner = m.c.stack.hook;
        } else {
            m = _m("deployer swap: another signer than the factory owner, owner of the config unchanged", Class.Pre);
            m.who = other;
        }
    }

    function _mut(uint256 g, uint256 i) internal view virtual override returns (Mut memory) {
        if (g == 0) return _mutStack(i);
        if (g == 1) return _mutLaunch(i);
        revert("see runOne");
    }

    function test_matrix_stack() public {
        _matrix(0, 0, N_STACK);
    }

    function test_matrix_launch() public {
        _matrix(1, 0, N_LAUNCH);
    }

    function test_matrix_ratePeople() public {
        bytes32 signed = configHash(base);
        uint256[5] memory counts;
        for (uint256 i; i < N_MISC; ++i) {
            Mut memory m = _mutMisc(i);
            Class k = _run(m.label, m.c, signed, m.who == address(0) ? deployer : m.who, m.pre);
            _count(k, m.want, m.label, counts);
        }
        _report(counts);
    }
}

/// @notice the matrix, part two: the chain state differs from the one that was signed off (factory, balances, the Core
/// address, the library, the stack code)
contract ReviewMatrixStateTest is ReviewHarness {
    uint256 internal constant N_STATE = 11;

    /// @dev applies state mutation `i` on the current fork state and returns its label and expected class
    function _state(uint256 i) internal override returns (string memory l, Class w) {
        vm.startPrank(deployer);
        if (i == 0) {
            (l, w) = ("factory not deprecated (open)", Class.Pre);
            FACTORY.setDeprecated(false);
        } else if (i == 1) {
            (l, w) = ("deployer balance 0.05 eth (below the 0.069 fee)", Class.Pre);
            vm.deal(deployer, 0.05 ether);
        } else if (i == 2) {
            (l, w) = ("the predicted core address has code", Class.Pre);
            vm.etch(_coreAt(), hex"00");
        } else if (i == 3) {
            (l, w) = ("the linked library has no code", Class.Revert);
            vm.etch(_linked(), "");
        } else if (i == 4) {
            (l, w) = ("different code at the linked library (a STOP)", Class.Revert);
            (lateEtchAt, lateEtchCode) = (_linked(), hex"00");
        } else if (i == 5) {
            (l, w) = ("the linked library plus one trailing byte", Class.Post);
            (lateEtchAt, lateEtchCode, lateEtchAppend) = (_linked(), hex"00", true);
        } else if (i == 6) {
            (l, w) = ("factory min protocol skim share 1000 (the owner command setMinProtocolSkimShareBps(362) not run)", Class.Pre);
            FACTORY.setMinProtocolSkimShareBps(1000);
        } else if (i == 7) {
            (l, w) = ("the fee escrow has no code", Class.Pre);
            vm.etch(v2.escrow, "");
        } else if (i == 8) {
            (l, w) = ("chain id 5 (a testnet)", Class.Pre);
            vm.chainId(5);
        } else if (i == 9) {
            (l, w) = ("the pool manager has no code", Class.Pre);
            vm.etch(Mainnet.POOL_MANAGER, "");
        } else {
            (l, w) = ("the Credits contract has no code", Class.Pre);
            vm.etch(Mainnet.CREDITS, "");
        }
        vm.stopPrank();
    }

    function test_matrix_chainState() public {
        _matrix(4, 0, N_STATE);
        // the baseline launches clean: the signed config deploys with every check passing and the signed hash
        bytes32 signed = configHash(base);
        assertTrue(this.runBaseline(signed) == Class.Slip, "the baseline launches clean");
    }

    function runBaseline(bytes32 signed) external returns (Class) {
        return _run("baseline", base, signed, deployer, "");
    }
}
