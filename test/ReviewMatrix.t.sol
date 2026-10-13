// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReviewHarness} from "./utils/ReviewHarness.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsHookV2} from "../src/interfaces/ArtCoinsV2.sol";

/// @notice the config mutation matrix, part one: the stack, the launch fields, the rate and the people. every mutation
/// says which outcome it must have, `runOne` runs it in its own call frame
contract ReviewMatrixConfigTest is ReviewHarness {
    uint256 internal constant N_STACK = 15;

    function _mutStack(uint256 i) internal view returns (Mut memory m) {
        address other = Mainnet.PERMIT2; // a contract that is not part of the stack
        if (i == 0) {
            m = _m("hook = a contract that is not the hook", Class.Pre);
            m.c.stack.hook = other;
        } else if (i == 1) {
            m = _m("hook = an EOA", Class.Pre);
            m.c.stack.hook = address(0xE0A1);
        } else if (i == 2) {
            m = _m("locker = the escrow", Class.Pre);
            m.c.stack.locker = m.c.stack.escrow;
        } else if (i == 3) {
            m = _m("poolManager = a contract that is not v4", Class.Pre);
            m.c.stack.poolManager = other;
        } else if (i == 4) {
            m = _m("escrow = a contract that is not the escrow", Class.Pre);
            m.c.stack.escrow = other;
        } else if (i == 5) {
            m = _m("factory = a contract that is not the factory", Class.Pre);
            m.c.stack.factory = other;
        } else if (i == 6) {
            m = _m("tickSpacing 60", Class.Pre);
            m.c.stack.tickSpacing = 60;
        } else if (i == 7) {
            m = _m("tickSpacing 400", Class.Pre);
            m.c.stack.tickSpacing = 400;
        } else if (i == 8) {
            m = _m("poolFee 3000 instead of the dynamic flag", Class.Pre);
            m.c.stack.poolFee = 3000;
        } else if (i == 9) {
            m = _m("tickSpacing 0", Class.Pre);
            m.c.stack.tickSpacing = 0;
        } else if (i == 10) {
            m = _m("mevModule = a contract that is not the module", Class.Pre);
            m.c.mevModule = other;
        } else if (i == 11) {
            m = _m("hook = the zero address", Class.Pre);
            m.c.stack.hook = address(0);
        } else if (i == 12) {
            m = _m("poolManager = the zero address", Class.Pre);
            m.c.stack.poolManager = address(0);
        } else if (i == 13) {
            m = _m("factory = the zero address", Class.Pre);
            m.c.stack.factory = address(0);
        } else {
            m = _m("locker = the zero address", Class.Pre);
            m.c.stack.locker = address(0);
        }
    }

    // ------------------------------------------------------------------ group B: the launch fields

    uint256 internal constant N_LAUNCH = 74;

    function _mutLaunch(uint256 i) internal view returns (Mut memory m) {
        if (i < 20) return _launchA(i);
        if (i < 40) return _launchB(i - 20);
        return _launchC(i - 40);
    }

    function _launchA(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("restricted off", Class.Pre);
            m.c.restricted = false;
        } else if (i == 1) {
            m = _m("one extra allowlist entry (the creator)", Class.Pre);
            m.c.allowed = new address[](1);
            m.c.allowed[0] = creator;
        } else if (i == 2) {
            m = _m("the router on the allowlist", Class.Pre);
            m.c.allowed = new address[](1);
            m.c.allowed[0] = address(uint160(uint256(keccak256("review.router.stand in"))));
        } else if (i == 3) {
            m = _m("bountyBps 9999", Class.Pre);
            m.c.bountyBps = 9999;
        } else if (i == 4) {
            m = _m("bountyBps 10000", Class.Pre);
            m.c.bountyBps = 10_000;
        } else if (i == 5) {
            m = _m("startTick +1 spacing (-174800)", Class.Pre);
            m.c.startTick = -174_800;
        } else if (i == 6) {
            m = _m("startTick -1 spacing (-175200)", Class.Pre);
            m.c.startTick = -175_200;
        } else if (i == 7) {
            m = _m("startTick sign flipped (+175000)", Class.Pre);
            m.c.startTick = 175_000;
        } else if (i == 8) {
            m = _m("startTick not a multiple of spacing (-175001)", Class.Pre);
            m.c.startTick = -175_001;
        } else if (i == 9) {
            m = _m("positionLower -175001", Class.Pre);
            m.c.positionLower = -175_001;
        } else if (i == 10) {
            m = _m("positionUpper 887201", Class.Pre);
            m.c.positionUpper = 887_201;
        } else if (i == 11) {
            m = _m("positionUpper 887400 beyond max tick", Class.Pre);
            m.c.positionUpper = 887_400;
        } else if (i == 12) {
            m = _m("positionUpper 600000 aligned but narrower", Class.Pre);
            m.c.positionUpper = 600_000;
        } else if (i == 13) {
            m = _m("positionLower -170000, start tick below range", Class.Pre);
            m.c.positionLower = -170_000;
        } else if (i == 14) {
            m = _m("salt zero", Class.Pre);
            m.c.salt = bytes32(0);
        } else if (i == 15) {
            m = _m("supply 1e27 + 1", Class.Pre);
            m.c.supply = 1_000_000_000e18 + 1;
        } else if (i == 16) {
            m = _m("supply 1e28", Class.Pre);
            m.c.supply = 10_000_000_000e18;
        } else if (i == 17) {
            m = _m("supply 0", Class.Pre);
            m.c.supply = 0;
        } else if (i == 18) {
            m = _m("name empty", Class.Pre);
            m.c.name = "";
        } else {
            m = _m("symbol empty", Class.Pre);
            m.c.symbol = "";
        }
    }

    function _launchB(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("sniperSeconds 0", Class.Pre);
            m.c.sniperSeconds = 0;
        } else if (i == 1) {
            m = _m("sniperStartBps 500 below the baseline", Class.Pre);
            m.c.sniperStartBps = 500;
        } else if (i == 2) {
            m = _m("maxReferralBps 1000", Class.Pre);
            m.c.maxReferralBps = 1000;
        } else if (i == 3) {
            m = _m("lpFeePips 5000", Class.Pre);
            m.c.lpFeePips = 5000;
        } else if (i == 4) {
            m = _m("lpFeePips 3000 (the v4 default tier)", Class.Pre);
            m.c.lpFeePips = 3000;
        } else if (i == 5) {
            m = _m("baselineSkimBps 6000", Class.Pre);
            m.c.baselineSkimBps = 6_000;
        } else if (i == 6) {
            m = _m("baselineSkimBps 1000 (the v1 value)", Class.Pre);
            m.c.baselineSkimBps = 1_000;
        } else if (i == 7) {
            m = _m("sniperSeconds 86400", Class.Pre);
            m.c.sniperSeconds = 86_400;
        } else if (i == 8) {
            m = _m("bountyBps 0", Class.Pre);
            m.c.bountyBps = 0;
        } else if (i == 9) {
            m = _m("bountyBps 9500 (the v1 value)", Class.Pre);
            m.c.bountyBps = 9500;
        } else if (i == 10) {
            m = _m("protocolBps 0 (no protocol locker slot)", Class.Pre);
            m.c.protocolBps = 0;
        } else if (i == 11) {
            m = _m("protocolBps 3000", Class.Pre);
            m.c.protocolBps = 3000;
        } else if (i == 12) {
            m = _m("protocolBps 10000", Class.Pre);
            m.c.protocolBps = 10_000;
        } else if (i == 13) {
            m = _m("sniperStartBps 9001 above the module limit", Class.Pre);
            m.c.sniperStartBps = 9_001;
        } else if (i == 14) {
            m = _m("sniperStartBps 690 equal to the baseline", Class.Pre);
            m.c.sniperStartBps = 690;
        } else if (i == 15) {
            m = _m("sniperSeconds 300", Class.Pre);
            m.c.sniperSeconds = 300;
        } else if (i == 16) {
            m = _m("sniperSeconds 3601", Class.Pre);
            m.c.sniperSeconds = 3601;
        } else if (i == 17) {
            m = _m("sniperStartBps 2000 (below the rule)", Class.Pre);
            m.c.sniperStartBps = 2_000;
        } else if (i == 18) {
            m = _m("bountyBps 9999 with the override flag on", Class.Pre);
            (m.c.bountyBps, m.c.allowBounty) = (9999, true);
        } else {
            m = _m("bountyBps 10000 with the override flag on", Class.Pre);
            (m.c.bountyBps, m.c.allowBounty) = (10_000, true);
        }
    }

    function _launchC(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("startTick and positionLower both -170000 (another start price)", Class.Hash);
            (m.c.startTick, m.c.positionLower) = (-170_000, -170_000);
        } else if (i == 1) {
            m = _m("bountyBps 8000 with the override flag on", Class.Hash);
            (m.c.bountyBps, m.c.allowBounty) = (8000, true);
        } else if (i == 2) {
            m = _m("bountyBps 9000 with the override flag on", Class.Hash);
            (m.c.bountyBps, m.c.allowBounty) = (9000, true);
        } else if (i == 3) {
            m = _m("sniperSeconds 3600 (valid, wrong)", Class.Hash);
            m.c.sniperSeconds = 3600;
        } else if (i == 4) {
            m = _m("sniperSeconds 900 (valid, wrong)", Class.Hash);
            m.c.sniperSeconds = 900;
        } else if (i == 5) {
            m = _m("sniperSeconds 600 (the lowest edge)", Class.Hash);
            m.c.sniperSeconds = 600;
        } else if (i == 6) {
            m = _m("sniperStartBps 5000 (valid, wrong)", Class.Hash);
            m.c.sniperStartBps = 5_000;
        } else if (i == 7) {
            m = _m("name changed", Class.Hash);
            m.c.name = "Review Coin Two";
        } else if (i == 8) {
            m = _m("symbol changed", Class.Hash);
            m.c.symbol = "REV2";
        } else if (i == 9) {
            m = _m("salt changed (any nonzero value is accepted)", Class.Hash);
            m.c.salt = keccak256("another salt");
        } else if (i == 10) {
            m = _m("overrides.openFactory on while the factory is deprecated", Class.Hash);
            m.c.allowOpenFactory = true;
        } else if (i == 11) {
            m = _m("router payee = another address", Class.Hash);
            m.c.creatorPayee = address(uint160(uint256(keccak256("review.other.payee"))));
        } else if (i == 12) {
            m = _m("router payee ppm 100000 (valid, wrong)", Class.Hash);
            m.c.payeePpm = 100_000;
        } else if (i == 13) {
            m = _m("router payee ppm 112777 (off by one)", Class.Hash);
            m.c.payeePpm = 112_777;
        } else if (i == 14) {
            m = _m("router payee ppm 200000 (the top edge)", Class.Hash);
            m.c.payeePpm = 200_000;
        } else if (i == 15) {
            m = _m("router payee ppm 200001 (above the router limit)", Class.Pre);
            m.c.payeePpm = 200_001;
        } else if (i == 16) {
            m = _m("router payee ppm 0", Class.Pre);
            m.c.payeePpm = 0;
        } else if (i == 17) {
            m = _m("router payee = the zero address", Class.Pre);
            m.c.creatorPayee = address(0);
        } else if (i == 18) {
            m = _m("router payee = the escrow", Class.Pre);
            m.c.creatorPayee = m.c.stack.escrow;
        } else if (i == 19) {
            m = _m("router payee = the hook", Class.Pre);
            m.c.creatorPayee = m.c.stack.hook;
        } else if (i == 20) {
            m = _m("router payee = the dead address", Class.Pre);
            m.c.creatorPayee = Mainnet.DEAD;
        } else if (i == 21) {
            m = _m("sale: anchorHalfLife 1209600 (valid, wrong)", Class.Hash);
            m.c.sale.anchorHalfLife = 1_209_600;
        } else if (i == 22) {
            m = _m("sale: markupBps 12000 (valid, wrong)", Class.Hash);
            m.c.sale.markupBps = 12_000;
        } else if (i == 23) {
            m = _m("sale: startCapBps 150000 (valid, wrong)", Class.Hash);
            m.c.sale.startCapBps = 150_000;
        } else if (i == 24) {
            m = _m("sale: fastDecayBpsPerHour 200 (valid, wrong)", Class.Hash);
            m.c.sale.fastDecayBpsPerHour = 200;
        } else if (i == 25) {
            m = _m("sale: kneeBps 8000 (valid, wrong)", Class.Hash);
            m.c.sale.kneeBps = 8000;
        } else if (i == 26) {
            m = _m("sale: markupBps 40001", Class.Pre);
            m.c.sale.markupBps = 40_001;
        } else if (i == 27) {
            m = _m("sale: markupBps 9999", Class.Pre);
            m.c.sale.markupBps = 9_999;
        } else if (i == 28) {
            m = _m("sale: startCapBps 200001", Class.Pre);
            m.c.sale.startCapBps = 200_001;
        } else if (i == 29) {
            m = _m("sale: fastDecayBpsPerHour 0", Class.Pre);
            m.c.sale.fastDecayBpsPerHour = 0;
        } else if (i == 30) {
            m = _m("sale: kneeBps 999", Class.Pre);
            m.c.sale.kneeBps = 999;
        } else if (i == 31) {
            m = _m("sale: startCapBps below markupBps", Class.Pre);
            m.c.sale.startCapBps = m.c.sale.markupBps - 1;
        } else if (i == 32) {
            m = _m("credit: royaltyBps 1001", Class.Pre);
            m.c.credit.royaltyBps = 1_001;
        } else {
            m = _m("credit: royaltyBps 500 (valid, wrong)", Class.Hash);
            m.c.credit.royaltyBps = 500;
        }
    }

    // ------------------------------------------------------------------ group D: rate and people

    uint256 internal constant N_MISC = 37;

    function _mutMisc(uint256 i) internal returns (Mut memory m) {
        if (i < 9) return _miscRate(i);
        if (i < 21) return _peopleA(i - 9);
        return _peopleB(i - 21);
    }

    function _miscRate(uint256 i) private view returns (Mut memory m) {
        // rows 0 to 3 keep rateCap at 3 times rateStart, so the ratio row passes and the rate bounds rows are the only
        // ones that can stop them. `pre` names the exact failed rows
        if (i == 0) {
            // cap 3e13 - 3 is inside the settings bounds: only the rateStart bound fails
            m = _m("rateStart 1e13 - 1 below min (rateCap 3e13 - 3, 3x)", Class.Pre);
            m.c.rateStart = 1e13 - 1;
            m.c.settings.rateCap = 3e13 - 3;
            m.pre = ROW_RATE_BOUNDS;
        } else if (i == 1) {
            // cap 3.6e18 is also above the settings bound
            m = _m("rateStart 1.2e18 above max (rateCap 3.6e18, 3x)", Class.Pre);
            m.c.rateStart = 1.2e18;
            m.c.settings.rateCap = 3.6e18;
            m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_SETTINGS_BOUNDS);
        } else if (i == 2) {
            // 3 * 0 == 0, and a rateCap of 0 is also below the settings bound
            m = _m("rateStart 0 (rateCap 0, 3x)", Class.Pre);
            m.c.rateStart = 0;
            m.c.settings.rateCap = 0;
            m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_SETTINGS_BOUNDS);
        } else if (i == 3) {
            // cap 4.5e18 is also above the settings bound
            m = _m("rateStart 1.5e18 (1.5x above max, rateCap 4.5e18, 3x)", Class.Pre);
            m.c.rateStart = 1.5e18;
            m.c.settings.rateCap = 4.5e18;
            m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_SETTINGS_BOUNDS);
        } else if (i == 4) {
            m = _m("rateStart 1e14 (in bounds, not the signed value)", Class.Hash);
            m.c.rateStart = 1e14;
            m.c.settings.rateCap = 3e14;
        } else if (i == 5) {
            m = _m("rateStart 4e16 (about 5x the launch day value, rateCap 1.2e17, in bounds)", Class.Hash);
            m.c.rateStart = 4e16;
            m.c.settings.rateCap = 1.2e17;
        } else if (i == 6) {
            m = _m("rateStart 1e13 (the lowest edge, rateCap 3e13)", Class.Hash);
            m.c.rateStart = 1e13;
            m.c.settings.rateCap = 3e13;
        } else if (i == 8) {
            // rateStart above rateCap, both inside their bounds: the start-at-most-cap clause of the bounds row fails,
            // and 1e14 is not 3 times 2e14, so the ratio row fails with it
            m = _m("rateStart 2e14 above rateCap 1e14", Class.Pre);
            m.c.rateStart = 2e14;
            m.c.settings.rateCap = 1e14;
            m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_RATE_RATIO);
        } else {
            m = _m("rateStart 1e18 (the highest edge, rateCap 1e18 is not 3 times)", Class.Pre);
            m.c.rateStart = 1e18;
            m.c.settings.rateCap = 1e18;
            m.pre = ROW_RATE_RATIO;
        }
    }

    function _peopleA(uint256 i) private returns (Mut memory m) {
        if (i == 0) {
            m = _m("owner and creator swapped (the owner is no longer the factory owner)", Class.Pre);
            (m.c.owner, m.c.creator) = (creator, owner);
        } else if (i == 1) {
            m = _m("owner = creator (not the factory owner)", Class.Pre);
            m.c.owner = creator;
        } else if (i == 2) {
            m = _m("creator = the owner (one party, two roles, a warning)", Class.Hash);
            m.c.creator = owner;
        } else if (i == 3) {
            m = _m("creator = the deployer (the same address)", Class.Hash);
            m.c.creator = deployer;
        } else if (i == 4) {
            m = _m("owner = a contract that is not part of the stack (Permit2)", Class.Pre);
            m.c.owner = Mainnet.PERMIT2;
        } else if (i == 5) {
            m = _m("owner = the hook", Class.Pre);
            m.c.owner = m.c.stack.hook;
        } else if (i == 6) {
            m = _m("owner = the dead address", Class.Pre);
            m.c.owner = Mainnet.DEAD;
        } else if (i == 7) {
            m = _m("owner = the artcoins factory", Class.Pre);
            m.c.owner = m.c.stack.factory;
        } else if (i == 8) {
            m = _m("creator = the artcoins factory", Class.Pre);
            m.c.creator = m.c.stack.factory;
        } else if (i == 9) {
            m = _m("creator = the dead address", Class.Pre);
            m.c.creator = Mainnet.DEAD;
        } else if (i == 10) {
            m = _m("owner = the zero address", Class.Pre);
            m.c.owner = address(0);
        } else {
            m = _m("creator = the zero address", Class.Pre);
            m.c.creator = address(0);
        }
    }

    /// @dev deployer swaps: the signer is not the one named. the config is the signed one, so the hash does not move and
    /// only the checks can stop the run
    function _peopleB(uint256 i) private returns (Mut memory m) {
        address other = makeAddr("review.other.signer");
        vm.deal(other, 5 ether);
        if (i == 0) {
            m = _m("deployer swap: another signer than the factory owner, owner of the config unchanged", Class.Pre);
            m.who = other;
        } else if (i == 1) {
            m = _m("deployer swap with owner = the new signer (not the factory owner)", Class.Pre);
            (m.who, m.c.owner) = (other, other);
        } else if (i == 2) {
            m = _m("deployer swap with creator = the new signer", Class.Pre);
            (m.who, m.c.creator) = (other, other);
        } else if (i == 3) {
            m = _m("deployer = the config creator, not the factory owner", Class.Pre);
            m.who = creator;
            vm.deal(creator, 5 ether);
        } else if (i == 4) {
            m = _m("owner = the mev module", Class.Pre);
            m.c.owner = m.c.mevModule;
        } else if (i == 5) {
            m = _m("owner = the pool manager", Class.Pre);
            m.c.owner = m.c.stack.poolManager;
        } else if (i == 6) {
            m = _m("creator = the pool manager", Class.Pre);
            m.c.creator = m.c.stack.poolManager;
        } else if (i == 7) {
            m = _m("creator = the hook", Class.Pre);
            m.c.creator = m.c.stack.hook;
        } else if (i == 8) {
            m = _m("creator = the escrow", Class.Pre);
            m.c.creator = m.c.stack.escrow;
        } else if (i == 9) {
            m = _m("creator = the locker", Class.Pre);
            m.c.creator = m.c.stack.locker;
        } else if (i == 10) {
            m = _m("creator = the factory", Class.Pre);
            m.c.creator = m.c.stack.factory;
        } else {
            m = _m("creator = the mev module", Class.Pre);
            m.c.creator = m.c.mevModule;
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

    function test_matrix_launchA() public {
        _matrix(1, 0, 40);
    }

    function test_matrix_launchB() public {
        _matrix(1, 40, 60);
    }

    /// @dev split from launchB: with the runtime code rows of the postflight (V2R-5) the second half no longer fits one
    /// test under the 2^30 gas limit
    function test_matrix_launchC() public {
        _matrix(1, 60, N_LAUNCH);
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

/// @notice the config mutation matrix, part two: every field of the settings, above the top, below the bottom, a plausible
/// wrong value and both edges
contract ReviewMatrixSettingsTest is ReviewHarness {
    uint256 internal constant N_SETTINGS = 115;

    /// @dev a plausible value that is not the launch value, inside the bounds, for each field
    function _wrong() internal pure returns (uint256[23] memory) {
        return [
            uint256(100),
            9000,
            100,
            15_000,
            100,
            5000,
            8000,
            500,
            2000,
            43_200,
            50,
            1,
            1,
            500,
            5000,
            5000,
            0.2 ether,
            0.001 ether,
            20 gwei,
            40_000_000_000_000_000,
            0.002 ether,
            50 gwei,
            2000
        ];
    }

    function _trim(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 j; j < n; ++j) {
            out[j] = b[j];
        }
        return string(out);
    }

    /// @dev kinds: 0 above the top, 1 below the bottom, 2 a plausible wrong value, 3 the top edge, 4 the bottom edge.
    /// an empty label means the field has no such case
    function _mutSettings(uint256 k) internal view returns (Mut memory m) {
        uint256 f = k % 23;
        uint256 kind = k / 23;
        uint256[23] memory lo = SettingsFields.lo();
        uint256[23] memory hi = SettingsFields.hi();
        string memory nm = _trim(SettingsFields.names()[f]);
        // rateCap is field 19. a rateCap other than 3 times the launch rateStart is stopped by its own preflight row
        m = _m("", kind <= 1 || f == 19 ? Class.Pre : Class.Hash);
        if (f == 19 && kind >= 2) m.pre = ROW_RATE_RATIO;
        Settings memory s = m.c.settings;
        // the two switches (fields 11 and 12) take 0 or 1: nothing is above their top
        if (kind == 0 && (f == 11 || f == 12)) return m;
        if (kind == 0) {
            if (f == 19) {
                // rateStart 3.3e17 + 1 is in bounds and 3 times it is the rateCap: only the settings bound fails
                m.c.rateStart = hi[f] / 3 + 1;
                s.rateCap = uint64(3 * m.c.rateStart);
                m.pre = ROW_SETTINGS_BOUNDS;
            } else {
                SettingsFields.set(s, f, hi[f] + 1);
            }
            m.label = string.concat(
                "settings.", nm, " ", vm.toString(f == 19 ? uint256(s.rateCap) : hi[f] + 1), " above the top"
            );
        } else if (kind == 1) {
            if (lo[f] == 0) return m;
            if (f == 19) {
                // 3 times a rateStart of 1e13 / 3 - 1 is a rateCap under 1e13: the rateStart bound and the settings bound
                // fail together, the ratio row passes
                m.c.rateStart = lo[f] / 3 - 1;
                s.rateCap = uint64(3 * m.c.rateStart);
                m.pre = string.concat(ROW_RATE_BOUNDS, ", ", ROW_SETTINGS_BOUNDS);
            } else {
                SettingsFields.set(s, f, lo[f] - 1);
            }
            m.label = string.concat(
                "settings.", nm, f == 19 ? string.concat(" ", vm.toString(uint256(s.rateCap))) : " one", " below the bottom"
            );
        } else if (kind == 2) {
            SettingsFields.set(s, f, _wrong()[f]);
            m.label = string.concat("settings.", nm, " ", vm.toString(_wrong()[f]), " (valid, wrong)");
        } else if (kind == 3) {
            SettingsFields.set(s, f, hi[f]);
            // climbPerMinBps at its top needs recoveryClimbPerMinBps at least as high to stay inside the bounds
            if (f == 2) s.recoveryClimbPerMinBps = 1_000;
            m.label = string.concat("settings.", nm, " ", vm.toString(hi[f]), " the top edge");
        } else {
            if (lo[f] == 0) return m;
            // the lowest rate cap that still holds the launch rate
            if (f == 19) s.rateCap = uint64(base.rateStart);
            // recoveryClimbPerMinBps is bounded below by climbPerMinBps, not by its own table low
            else if (f == 7) SettingsFields.set(s, 7, s.climbPerMinBps);
            else SettingsFields.set(s, f, lo[f]);
            // the smallest slice needs the cheapest buyback payment
            if (f == 16) (s.keeperFee, s.keeperMaxBaseFee) = (0, 1 gwei);
            m.label = string.concat("settings.", nm, " the bottom edge");
        }
        // an edge that is the launch value is no mutation
        if (keccak256(abi.encode(s)) == keccak256(abi.encode(base.settings))) m.label = "";
    }

    function _mut(uint256, uint256 i) internal view override returns (Mut memory) {
        return _mutSettings(i);
    }

    /// the settings group in parts: every field above the top and below the bottom, a plausible wrong value for every
    /// field, then the edges that must still be accepted
    function test_matrix_settingsViolations() public {
        _matrix(2, 0, 46);
    }

    function test_matrix_settingsWrongValues() public {
        _matrix(2, 46, 69);
    }

    function test_matrix_settingsTopEdges() public {
        _matrix(2, 69, 92);
    }

    function test_matrix_settingsBottomEdges() public {
        _matrix(2, 92, N_SETTINGS);
    }
}

/// @notice the matrix, part three: the chain state differs from the one that was signed off (factory, owner commands,
/// library, balances, predicted addresses)
contract ReviewMatrixStateTest is ReviewHarness {
    uint256 internal constant N_STATE = 32;

    /// @dev applies state mutation `i` on the current fork state and returns its label and expected class
    function _state(uint256 i) internal override returns (string memory l, Class w) {
        vm.startPrank(deployer);
                if (i == 0) {
            (l, w) = ("factory not deprecated (open)", Class.Pre);
            FACTORY.setDeprecated(false);
        } else if (i == 1) {
            (l, w) = ("factory ownership moved to someone else", Class.Pre);
            IOwn(address(FACTORY)).transferOwnership(creator);
            vm.stopPrank();
            vm.prank(creator);
            IOwn(address(FACTORY)).acceptOwnership();
            vm.startPrank(deployer);
        } else if (i == 2) {
            (l, w) = ("deployer balance 0.05 eth (below the 0.069 fee)", Class.Pre);
            vm.deal(deployer, 0.05 ether);
        } else if (i == 3) {
            (l, w) = ("deployer balance 0.07 eth (the fee, no gas at 1 gwei)", Class.Pre);
            vm.deal(deployer, 0.07 ether);
            vm.fee(1 gwei);
        } else if (i == 4) {
            (l, w) = ("the predicted coin address has code (salt reuse, a copycat)", Class.Pre);
            vm.etch(predictCoin(base, deployer, _routerAt()), hex"00");
        } else if (i == 5) {
            (l, w) = ("the predicted controller address has code", Class.Pre);
            vm.etch(_controllerAt(), hex"00");
        } else if (i == 6) {
            (l, w) = ("the predicted core address has code", Class.Pre);
            vm.etch(_coreAt(), hex"00");
        } else if (i == 7) {
            (l, w) = ("the predicted router address has code", Class.Pre);
            vm.etch(_routerAt(), hex"00");
        } else if (i == 8) {
            (l, w) = ("the linked library has no code", Class.Revert);
            vm.etch(_linked(), "");
        } else if (i == 9) {
            (l, w) = ("different code at the linked library (a STOP)", Class.Revert);
            (lateEtchAt, lateEtchCode) = (_linked(), hex"00");
        } else if (i == 10) {
            (l, w) = ("the linked library plus one trailing byte", Class.Post);
            (lateEtchAt, lateEtchCode) = (_linked(), bytes.concat(_linked().code, hex"00"));
        } else {
            (l, w) = _state2(i);
        }
        vm.stopPrank();
    }

    /// @dev the owner commands on the v2 factory and the hook that change what a launch is
    function _state2(uint256 i) private returns (string memory l, Class w) {
        if (i == 11) {
            (l, w) = ("factory min protocol skim share 1000 (the owner command setMinProtocolSkimShareBps(362) not run)", Class.Pre);
            FACTORY.setMinProtocolSkimShareBps(1000);
        } else if (i == 12) {
            (l, w) = ("factory min protocol skim share 363 (one above the 362 the bounty 9638 leaves)", Class.Pre);
            FACTORY.setMinProtocolSkimShareBps(363);
        } else if (i == 13) {
            (l, w) = ("factory min protocol skim share 1500 (bounty 9638 no longer fits)", Class.Pre);
            FACTORY.setMinProtocolSkimShareBps(1500);
        } else if (i == 14) {
            (l, w) = ("hook disabled on the factory", Class.Pre);
            FACTORY.setHook(v2.hook, false);
        } else if (i == 15) {
            (l, w) = ("locker disabled on the factory", Class.Pre);
            FACTORY.setLocker(v2.locker, false);
        } else if (i == 16) {
            (l, w) = ("mev module disabled on the factory", Class.Pre);
            FACTORY.setMevModule(v2.mev, false);
        } else if (i == 17) {
            (l, w) = ("locker launcher flag for the factory removed", Class.Pre);
            (bool okL,) = v2.locker.call(abi.encodeWithSignature("setLauncher(address,bool)", v2.factory, false));
            require(okL, "locker setLauncher");
        } else if (i == 18) {
            (l, w) = ("factory default allowlist holds an account (it would join the coin allowlist)", Class.Pre);
            address[] memory a = new address[](1);
            a[0] = creator;
            FACTORY.setDefaultAllowed(a);
        } else if (i == 19) {
            (l, w) = ("factory team fee recipient unset (the deploy fee has no recipient)", Class.Pre);
            FACTORY.setTeamFeeRecipient(address(0));
        } else if (i == 20) {
            (l, w) = ("the fee escrow has no code", Class.Pre);
            vm.etch(v2.escrow, "");
        } else if (i == 21) {
            (l, w) = ("hook launcher flag for the factory removed", Class.Pre);
            IArtCoinsHookV2(v2.hook).setLauncher(v2.factory, false);
        } else if (i == 22) {
            (l, w) = ("factory token deployer cleared by a wrong code (not settable to zero), deployer code etched away", Class.Pre);
            vm.etch(FACTORY.tokenDeployer(), "");
        } else if (i == 23) {
            (l, w) = ("the deployer has no eth at all", Class.Pre);
            vm.deal(deployer, 0);
        } else if (i == 24) {
            (l, w) = ("chain id 5 (a testnet)", Class.Pre);
            vm.chainId(5);
        } else if (i == 25) {
            (l, w) = ("hook code etched away", Class.Pre);
            vm.etch(v2.hook, "");
        } else if (i == 26) {
            (l, w) = ("the pool manager has no code", Class.Pre);
            vm.etch(Mainnet.POOL_MANAGER, "");
        } else if (i == 27) {
            (l, w) = ("the Credits contract has no code", Class.Pre);
            vm.etch(Mainnet.CREDITS, "");
        } else if (i == 28) {
            (l, w) = ("deploy fee raised to 0.5 eth (a factory value outside the signed config; the pinned fee rule)", Class.Pre);
            FACTORY.setDeployFee(0.5 ether);
        } else if (i == 29) {
            (l, w) = ("locker constantsHash differs from the hook's", Class.Pre);
            vm.mockCall(v2.locker, abi.encodeWithSignature("constantsHash()"), abi.encode(keccak256("another constants hash")));
        } else if (i == 30) {
            (l, w) = ("hook and the stack report a constantsHash other than the vendored artifacts'", Class.Pre);
            bytes memory other = abi.encode(keccak256("another constants hash"));
            address[5] memory all = [v2.hook, v2.locker, v2.escrow, v2.mev, v2.factory];
            for (uint256 k; k < all.length; ++k) {
                vm.mockCall(all[k], abi.encodeWithSignature("constantsHash()"), other);
            }
        } else {
            (l, w) = ("factory team fee recipient is not the config owner (deploy fee above zero)", Class.Pre);
            FACTORY.setTeamFeeRecipient(creator);
        }
    }

    function test_matrix_chainStateA() public {
        _matrix(4, 0, 11);
    }

    function test_matrix_chainStateB() public {
        _matrix(4, 11, N_STATE);
        // the baseline launches clean: the signed config deploys with every check passing and the signed hash
        bytes32 signed = configHash(base);
        assertTrue(this.runBaseline(signed) == Class.Slip, "the baseline launches clean");
    }

    function runBaseline(bytes32 signed) external returns (Class) {
        return _run("baseline", base, signed, deployer, "");
    }
}

interface IOwn {
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
