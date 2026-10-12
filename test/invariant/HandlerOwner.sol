// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Lane, Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI, BUYBACK_GAS} from "../../src/interfaces/Interfaces.sol";
import {BidModel} from "../utils/BidModel.sol";
import {HandlerBase} from "./HandlerBase.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {MigrationSink} from "../standins/MigrationSink.sol";
import {CountingEngine, RefusingEngine} from "../attackers/FlushEngines.sol";

/// @notice the owner as an adversarial actor. the owner calls `setSettings` with random valid settings across the
/// whole allowed bounds, extreme corners included, `setRate` anywhere in its bounds, and invalid
/// settings, rates and callers that must revert. the bounds are written out again here, independently of the
/// library under test. after every owner call the settings are what was set, the rate is what it should be, and the
/// core's eth, pots and exit token did not move: the owner has no path to the assets.
abstract contract HandlerOwner is HandlerBase {
    /// owner calls that went through, and the ones the model expected to revert and did
    uint256 public gOwnerCalls;
    uint256 public gOwnerRefused;

    /*//////////////////////////////////////////////////////////////
                              GENERATOR
    //////////////////////////////////////////////////////////////*/

    /// a value in [lo, hi]: one of the two edges, the current value, uniform, or log uniform from the low edge
    function _f(uint256 seed, uint256 lo, uint256 hi, uint256 cur) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        uint256 k = seed % 6;
        if (k == 0) return lo;
        if (k == 1) return hi;
        if (k == 2) return cur < lo ? lo : (cur > hi ? hi : cur);
        if (k == 3) return lo + (seed >> 8) % (hi - lo + 1);
        return lo + _logBound(seed >> 8, 1, hi - lo + 1) - 1;
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// random valid settings over the whole bounds, from `seed`. `corner` picks an extreme to force on top
    function _genSettings(uint256 seed, uint256 corner, Settings memory c) internal pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPerCreditBps = uint16(_f(_r(seed, 2), 1, 1_000, c.dropPerCreditBps));
        s.dropFloorBps = uint16(_f(_r(seed, 3), 5_000, 10_000, c.dropFloorBps));
        s.climbPerMinBps = uint16(_f(_r(seed, 4), 1, 1_000, c.climbPerMinBps));
        s.ceilBps = uint16(_f(_r(seed, 5), 10_000, 30_000, c.ceilBps));
        s.idleLoosenBps = uint16(_f(_r(seed, 29), 1, 2_000, c.idleLoosenBps));
        s.saleFloorBps = uint16(_f(_r(seed, 12), 1_000, 40_000, c.saleFloorBps));
        s.exitAfter = uint32(_f(_r(seed, 14), 1 hours, 365 days, c.exitAfter));
        s.saleToBuybackBps = uint16(_f(_r(seed, 15), 0, 10_000, c.saleToBuybackBps));
        s.exitToBuybackBps = uint16(_f(_r(seed, 16), 0, 10_000, c.exitToBuybackBps));
        s.buybackSlice = uint128(_f(_r(seed, 17), 0.01 ether, 1 ether, c.buybackSlice));
        s.buybackDelay = uint16(_f(_r(seed, 18), 1, 7_200, c.buybackDelay));
        s.keeperFee = uint64(_f(_r(seed, 19), 0, 0.005 ether, c.keeperFee));
        s.keeperMaxBaseFee = uint48(_f(_r(seed, 30), 1 gwei, 100 gwei, c.keeperMaxBaseFee));
        s.xRateCap = uint16(_f(_r(seed, 20), 0, 10_000, c.xRateCap));
        s.xRateFloor = uint16(_f(_r(seed, 21), 0, s.xRateCap, c.xRateFloor));
        s.xRateClimbPerHour = uint16(_f(_r(seed, 22), 0, 1_000, c.xRateClimbPerHour));
        s.xRateDropPerCredit = uint16(_f(_r(seed, 23), 0, 1_000, c.xRateDropPerCredit));
        s.xAuctionHalfLife = uint32(_f(_r(seed, 24), 10 minutes, 30 days, c.xAuctionHalfLife));
        s.exitSliceCredits = uint16(_f(_r(seed, 25), 1, 1_000, c.exitSliceCredits));
        s.rateCap = uint64(_f(_r(seed, 26), RATE_START_MIN_WEI, RATE_START_MAX_WEI, c.rateCap));
        s.exitLaneToBuybackBps = uint16(_f(_r(seed, 27), 0, 10_000, c.exitLaneToBuybackBps));
        s.feeToBuybackBps = uint16(_f(_r(seed, 28), 0, 10_000, c.feeToBuybackBps));
        s.callerFee = uint64(_f(_r(seed, 10), 0, 0.005 ether, c.callerFee));
        s.callerMaxBaseFee = uint48(_f(_r(seed, 11), 0, 100 gwei, c.callerMaxBaseFee));
        _corner(s, corner);
        // recoveryClimbPerMinBps is at least the final climbPerMinBps, set after the corners so it stays valid
        s.recoveryClimbPerMinBps = uint16(_f(_r(seed, 31), s.climbPerMinBps, 1_000, c.recoveryClimbPerMinBps));
        s.peakHalfLife = uint32(_f(_r(seed, 32), 600, 604_800, c.peakHalfLife));
        s.recoveryGapBps = uint16(_f(_r(seed, 33), 0, 5_000, c.recoveryGapBps));
        // the slice stays at or above twice the largest buyback payment
        uint256 minSlice = 2 * (BUYBACK_GAS * s.keeperMaxBaseFee + s.keeperFee);
        if (s.buybackSlice < minSlice) s.buybackSlice = uint128(minSlice);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// the extreme corners the brief names, forced on top of the random settings
    function _corner(Settings memory s, uint256 k) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        k = k % 20;
        if (k == 1) {
            s.rateCap = uint64(RATE_START_MAX_WEI);
        } else if (k == 2) {
            s.dropPerCreditBps = 1;
            s.dropFloorBps = 10_000;
        } else if (k == 3) {
            s.climbPerMinBps = 1;
        } else if (k == 4) {
            s.saleFloorBps = 1_000;
        } else if (k == 5) {
            s.saleFloorBps = 40_000;
        } else if (k == 6) {
            s.saleToBuybackBps = 0;
        } else if (k == 7) {
            s.saleToBuybackBps = 10_000;
        } else if (k == 8) {
            s.idleLoosenBps = 1;
        } else if (k == 9) {
            s.dropPerCreditBps = 1_000;
            s.dropFloorBps = 5_000;
        } else if (k == 10) {
            // the smallest slice: the cheapest payment allows it
            s.buybackSlice = 0.01 ether;
            s.keeperFee = 0;
            s.keeperMaxBaseFee = 1 gwei;
        } else if (k == 11) {
            s.buybackSlice = 1 ether;
        } else if (k == 12) {
            s.exitAfter = 1 hours;
        } else if (k == 13) {
            s.xRateCap = 0;
            s.xRateFloor = 0;
        } else if (k == 14) {
            // every caller payment and keeper reward at zero
            s.callerFee = 0;
            s.callerMaxBaseFee = 0;
            s.keeperFee = 0;
        } else if (k == 15) {
            // every caller payment and keeper reward at its ceiling
            s.callerFee = 0.005 ether;
            s.callerMaxBaseFee = 100 gwei;
            s.keeperFee = 0.005 ether;
            s.keeperMaxBaseFee = 100 gwei;
        } else if (k == 16) {
            // the shortest clocks and the most aggressive climb
            s.climbPerMinBps = 1_000;
            s.ceilBps = 30_000;
            s.idleLoosenBps = 2_000;
            s.xAuctionHalfLife = 10 minutes;
        } else if (k == 17) {
            // the lowest rate cap: it pulls the eth rate down to it at the checkpoint
            s.rateCap = uint64(RATE_START_MIN_WEI);
        } else if (k == 18) {
            // every exit goes to the bid pot, and every exit lane exit goes to the buyback
            s.exitToBuybackBps = 0;
            s.exitLaneToBuybackBps = 10_000;
        } else if (k == 19) {
            s.exitToBuybackBps = 10_000;
            s.exitLaneToBuybackBps = 10_000;
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /*//////////////////////////////////////////////////////////////
                              SET SETTINGS
    //////////////////////////////////////////////////////////////*/

    struct OPre {
        uint256 bal;
        uint256 pot;
        uint256 toBuyback;
        uint256 rate;
        uint256 price;
        uint256 xRate;
        uint256 xPrice;
        uint256 xPot;
        uint256 xToBuyback;
        uint256 xBal;
    }

    function _opre() internal view returns (OPre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.toBuyback = core.ethToBuyback();
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.xRate = core.xRate();
        p.xPrice = core.exitAuctionPrice();
        p.xPot = core.xPot();
        p.xToBuyback = core.xToBuyback();
        p.xBal = _xBal(address(core));
    }

    /// what no owner call may touch: the core's eth, its pots and its exit token
    function _opost(OPre memory p, string memory what) internal {
        _eth(p.bal, 0, 0, what);
        _x(p.xBal, 0, 0, what);
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.toBuyback) _flag(V_OWNER, "an owner call moved a pot");
        if (core.xPot() != p.xPot || core.xToBuyback() != p.xToBuyback) {
            _flag(V_OWNER, "an owner call moved an exit pot");
        }
        gOwnerCalls++;
    }

    /// the owner changes the settings to random valid ones, effective at once. nothing may revert. afterwards the
    /// settings are what was set, the stored eth rate is exactly what it was (the call checkpoints it, it never jumps),
    /// the exit rate is only held inside the new band, the exit auction price is continuous, and the pots and balances
    /// did not move
    /// the owner sets exactly `ns` and the ghost follows. not in the fuzz selector list: the smoke tests use it
    function setSettingsExact(Settings memory ns) external {
        vm.prank(owner);
        core.setSettings(ns);
        gSettingsHash = keccak256(abi.encode(core.settings()));
    }

    function setSettings(uint256 seed, uint256 corner) external checked {
        uint8 a = A_SET_SETTINGS;
        Settings memory cur = core.settings();
        Settings memory ns = _genSettings(seed, corner, cur);
        if (_firstViolation(ns) != 0) {
            _flag(V_SETTINGS, "the handler generated invalid settings");
            return _skip(a);
        }
        OPre memory p = _opre();
        _att(a);
        vm.prank(owner);
        try core.setSettings(ns) {
            _ok(a);
            gSettingsHash = keccak256(abi.encode(ns));
            if (keccak256(abi.encode(core.settings())) != gSettingsHash) {
                _flag(V_SETTINGS, "the settings read back differ from the ones set");
            }
            _afterSettings(ns, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setSettings");
            _unexpected(a, why);
        }
    }

    function _afterSettings(Settings memory ns, OPre memory p) internal {
        _opost(p, "setSettings");
        // invariant 6 across a settings call: the call checkpoints under the old settings, so it stores the price state it
        // found. the read under the new settings is that price state, bounded by the new ceiling and rate cap and, while
        // funded, lowered to the new clamp
        {
            uint256 stored = core.rateAtCheckpoint();
            uint256 want = BidModel.read(ns, core.ethPot(), _priceNow(ns));
            if (stored != p.price) _flag(V_RATE_BOUND, "a settings call moved the stored eth rate");
            if (core.ethRate() != want) _flag(V_RATE_BOUND, "a settings call moved the eth rate");
        }
        if (phase2()) _xFundedCheck();
        // the exit rate is held inside the new band and nothing else
        uint256 want = p.xRate > ns.xRateCap ? ns.xRateCap : p.xRate;
        if (want < ns.xRateFloor) want = ns.xRateFloor;
        if (core.xRate() != want) _flag(V_SETTINGS, "the exit rate is not held inside the new band");
        // the exit auction keeps its price whatever happens to the half life. a price that decayed to zero is
        // re anchored at one when the half life changes (the core keeps the start price at one at least)
        uint256 price = core.exitAuctionPrice();
        if (price != p.xPrice && !(p.xPrice == 0 && price == 1)) {
            _flag(V_AUCTION, "a settings call moved the exit auction price");
        }
    }

    /// the bounds of docs/FLOW.md section 2, written out again. the name of the first field out of bounds, or zero
    function _firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.dropPerCreditBps < 1 || s.dropPerCreditBps > 1_000) return "dropPerCreditBps";
        if (s.dropFloorBps < 5_000 || s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1 || s.climbPerMinBps > 1_000) return "climbPerMinBps";
        if (s.ceilBps < 10_000 || s.ceilBps > 30_000) return "ceilBps";
        if (s.idleLoosenBps < 1 || s.idleLoosenBps > 2_000) return "idleLoosenBps";
        if (s.saleFloorBps < 1_000 || s.saleFloorBps > 40_000) return "saleFloorBps";
        if (s.exitAfter < 1 hours || s.exitAfter > 365 days) return "exitAfter";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (s.exitToBuybackBps > 10_000) return "exitToBuybackBps";
        if (s.peakHalfLife < 600 || s.peakHalfLife > 604_800) return "peakHalfLife";
        if (s.recoveryClimbPerMinBps < s.climbPerMinBps || s.recoveryClimbPerMinBps > 1_000) {
            return "recoveryClimbPerMinBps";
        }
        if (s.recoveryGapBps > 5_000) return "recoveryGapBps";
        if (s.buybackSlice < 0.01 ether || s.buybackSlice > 1 ether) return "buybackSlice";
        if (s.buybackDelay < 1 || s.buybackDelay > 7_200) return "buybackDelay";
        if (s.keeperFee > 0.005 ether) return "keeperFee";
        if (s.keeperMaxBaseFee < 1 gwei || s.keeperMaxBaseFee > 100 gwei) return "keeperMaxBaseFee";
        if (s.buybackSlice < 2 * (BUYBACK_GAS * s.keeperMaxBaseFee + s.keeperFee)) return "buybackSlice";
        if (s.xRateCap > 10_000) return "xRateCap";
        if (s.xRateFloor > s.xRateCap) return "xRateFloor";
        if (s.xRateClimbPerHour > 1_000) return "xRateClimbPerHour";
        if (s.xRateDropPerCredit > 1_000) return "xRateDropPerCredit";
        if (s.xAuctionHalfLife < 10 minutes || s.xAuctionHalfLife > 30 days) return "xAuctionHalfLife";
        if (s.exitSliceCredits < 1 || s.exitSliceCredits > 1_000) return "exitSliceCredits";
        if (s.rateCap < RATE_START_MIN_WEI || s.rateCap > RATE_START_MAX_WEI) return "rateCap";
        if (s.exitLaneToBuybackBps > 10_000) return "exitLaneToBuybackBps";
        if (s.feeToBuybackBps > 10_000) return "feeToBuybackBps";
        if (s.callerFee > 0.005 ether) return "callerFee";
        if (s.callerMaxBaseFee > 100 gwei) return "callerMaxBaseFee";
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// breaks exactly one field of valid settings, `which` picks it. returns the name the library must report
    function _break(Settings memory s, uint256 which) internal pure returns (bytes32 name) {
        // forge-lint: disable-start(unsafe-typecast)
        which = which % 45;
        if (which == 0) {
            (s.dropPerCreditBps, name) = (1_001, "dropPerCreditBps");
        } else if (which == 1) {
            (s.dropPerCreditBps, name) = (0, "dropPerCreditBps");
        } else if (which == 2) {
            (s.dropFloorBps, name) = (4_999, "dropFloorBps");
        } else if (which == 3) {
            (s.dropFloorBps, name) = (10_001, "dropFloorBps");
        } else if (which == 4) {
            (s.climbPerMinBps, name) = (0, "climbPerMinBps");
        } else if (which == 5) {
            (s.climbPerMinBps, name) = (1_001, "climbPerMinBps");
        } else if (which == 6) {
            (s.keeperFee, name) = (0.005 ether + 1, "keeperFee");
        } else if (which == 7) {
            (s.xRateCap, name) = (10_001, "xRateCap");
        } else if (which == 8) {
            (s.callerFee, name) = (0.005 ether + 1, "callerFee");
        } else if (which == 9) {
            (s.callerMaxBaseFee, name) = (100 gwei + 1, "callerMaxBaseFee");
        } else if (which == 10) {
            (s.saleFloorBps, name) = (999, "saleFloorBps");
        } else if (which == 11) {
            (s.saleFloorBps, name) = (40_001, "saleFloorBps");
        } else if (which == 12) {
            (s.exitAfter, name) = (0, "exitAfter");
        } else if (which == 13) {
            (s.saleFloorBps, name) = (0, "saleFloorBps");
        } else if (which == 14) {
            (s.exitAfter, name) = (uint32(365 days) + 1, "exitAfter");
        } else if (which == 15) {
            (s.saleToBuybackBps, name) = (10_001, "saleToBuybackBps");
        } else if (which == 16) {
            (s.exitToBuybackBps, name) = (10_001, "exitToBuybackBps");
        } else if (which == 17) {
            (s.buybackSlice, name) = (0.01 ether - 1, "buybackSlice");
        } else if (which == 18) {
            (s.buybackSlice, name) = (1 ether + 1, "buybackSlice");
        } else if (which == 19) {
            (s.buybackDelay, name) = (0, "buybackDelay");
        } else if (which == 20) {
            (s.buybackDelay, name) = (7_201, "buybackDelay");
        } else if (which == 21) {
            (s.keeperFee, name) = (0.005 ether + 1, "keeperFee");
        } else if (which == 22) {
            (s.xRateCap, name) = (10_001, "xRateCap");
        } else if (which == 23) {
            (s.xRateCap, s.xRateFloor, name) = (5_000, 5_001, "xRateFloor");
        } else if (which == 24) {
            (s.xRateClimbPerHour, name) = (1_001, "xRateClimbPerHour");
        } else if (which == 25) {
            (s.xRateDropPerCredit, name) = (1_001, "xRateDropPerCredit");
        } else if (which == 26) {
            (s.xAuctionHalfLife, name) = (10 minutes - 1, "xAuctionHalfLife");
        } else if (which == 27) {
            (s.xAuctionHalfLife, name) = (uint32(30 days) + 1, "xAuctionHalfLife");
        } else if (which == 28) {
            (s.exitSliceCredits, name) = (0, "exitSliceCredits");
        } else if (which == 29) {
            (s.exitSliceCredits, name) = (1_001, "exitSliceCredits");
        } else if (which == 30) {
            (s.ceilBps, name) = (9_999, "ceilBps");
        } else if (which == 31) {
            (s.exitAfter, name) = (1 hours - 1, "exitAfter");
        } else if (which == 32) {
            (s.rateCap, name) = (1e13 - 1, "rateCap");
        } else if (which == 33) {
            (s.rateCap, name) = (1e18 + 1, "rateCap");
        } else if (which == 34) {
            (s.exitLaneToBuybackBps, name) = (10_001, "exitLaneToBuybackBps");
        } else if (which == 35) {
            (s.feeToBuybackBps, name) = (10_001, "feeToBuybackBps");
        } else if (which == 36) {
            (s.ceilBps, name) = (30_001, "ceilBps");
        } else if (which == 37) {
            (s.idleLoosenBps, name) = (2_001, "idleLoosenBps");
        } else if (which == 38) {
            (s.idleLoosenBps, name) = (0, "idleLoosenBps");
        } else if (which == 39) {
            (s.keeperMaxBaseFee, name) = (1 gwei - 1, "keeperMaxBaseFee");
        } else if (which == 40) {
            (s.keeperMaxBaseFee, name) = (100 gwei + 1, "keeperMaxBaseFee");
        } else if (which == 41) {
            (s.peakHalfLife, name) = (599, "peakHalfLife");
        } else if (which == 42) {
            (s.peakHalfLife, name) = (604_801, "peakHalfLife");
        } else if (which == 43) {
            // below climbPerMinBps, which a valid struct keeps at least 1, so zero always violates
            (s.recoveryClimbPerMinBps, name) = (0, "recoveryClimbPerMinBps");
        } else {
            (s.recoveryGapBps, name) = (5_001, "recoveryGapBps");
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// invalid settings from the owner must revert with BadSetting naming the field, and a valid or invalid set from
    /// anyone else with OnlyOwner. whichever, nothing at all changes
    function setSettingsInvalid(uint256 seed, uint256 which) external checked {
        uint8 a = A_SET_INVALID;
        Settings memory ns = core.settings();
        bytes32 name = _break(ns, which);
        if (_firstViolation(ns) != name) {
            _flag(V_SETTINGS, "the handler's invalid settings are not invalid in the named field");
            return _skip(a);
        }
        bool stranger = seed % 5 == 0;
        // some of the strangers send valid settings, which must be refused just the same
        if (stranger && seed % 2 == 0) ns = core.settings();
        address who = stranger ? _actor(seed >> 8) : owner;
        OPre memory p = _opre();
        _att(a);
        vm.prank(who);
        try core.setSettings(ns) {
            _ok(a);
            _flag(V_SETTINGS, stranger ? "a stranger changed the settings" : "invalid settings were accepted");
            gSettingsHash = keccak256(abi.encode(core.settings()));
        } catch (bytes memory why) {
            _ok(a);
            gOwnerRefused++;
            _failed(p.bal, p.pot, p.rate, "setSettingsInvalid");
            _opost(p, "setSettingsInvalid");
            if (stranger) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            } else if (bytes4(why) != ICore.BadSetting.selector || why.length != 36) {
                _unexpected(a, why);
            } else {
                bytes32 field;
                assembly {
                    field := mload(add(why, 36))
                }
                if (field != name) _unexpected(a, why);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SET RATE, SET XRATE
    //////////////////////////////////////////////////////////////*/

    /// the owner resets the eth rate anywhere in its bounds, edges included, or tries one outside them (BadRate), or a
    /// stranger tries (OnlyOwner). a good call is the one way the stored rate may jump: it lands on exactly the rate
    /// asked for, with no climb credited, the funded flag recomputed, and the pots and balances untouched
    function setRate(uint256 seed, uint256 mode) external checked {
        uint8 a = A_SET_RATE;
        uint256 m = mode % 10;
        uint256 cap = core.settings().rateCap;
        uint256 rate;
        if (m == 0) rate = RATE_START_MIN_WEI;
        else if (m == 1) rate = cap;
        else if (m == 2) rate = core.ethRate();
        else if (m == 3) rate = RATE_START_MIN_WEI - 1;
        else if (m == 4) rate = RATE_START_MAX_WEI + 1;
        else if (m == 5) rate = seed % 3 == 0 ? 0 : type(uint256).max;
        else if (m == 6) rate = cap + 1;
        else rate = _logBound(seed, RATE_START_MIN_WEI, cap);
        bool stranger = mode % 13 == 5;
        bool good = rate >= RATE_START_MIN_WEI && rate <= RATE_START_MAX_WEI && rate <= cap;
        OPre memory p = _opre();
        _att(a);
        vm.prank(stranger ? _actor(seed) : owner);
        try core.setRate(rate) {
            _ok(a);
            if (stranger || !good) _flag(V_SETTINGS, "setRate accepted a stranger or a rate out of bounds");
            _opost(p, "setRate");
            Settings memory cs = core.settings();
            (uint256 anchor,,) = _anchorState();
            (uint256 peakRate, uint256 peakTime) = _peakState();
            uint256 want = BidModel.read(cs, core.ethPot(), _priceNow(cs));
            if (core.ethRate() != want || core.rateAtCheckpoint() != rate || anchor != rate) {
                _flag(V_RATE_BOUND, "setRate did not land on the rate and the anchor");
            }
            if (peakRate != rate || peakTime != block.timestamp) {
                _flag(V_RATE_BOUND, "setRate did not restate the remembered peak");
            }
            if (core.checkpointTime() != block.timestamp) {
                _flag(V_RATE_BOUND, "setRate did not restart the climb clock");
            }
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setRate");
            if (good && !stranger) _unexpected(a, why);
            else if (bytes4(why) != (stranger ? ICore.OnlyOwner.selector : ICore.BadRate.selector)) _unexpected(a, why);
            else _ok(a);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE REST OF THE OWNER
    //////////////////////////////////////////////////////////////*/

    /// the owner's other doors, which only ever touch the allow list and the owner slot, all at once: remove a target,
    /// add one (live at once, and removed again), start a handover and clear it, and a stranger who tries the owner
    /// doors (OnlyOwner). the locks are one way and never fuzzed here. none of it moves an asset
    function ownerMisc(uint256 seed, uint256 mode) external checked {
        uint8 a = A_OWNER_MISC;
        OPre memory p = _opre();
        address t = address(uint160(uint256(keccak256(abi.encode("misc", seed)))));
        uint256 m = mode % 4;
        _att(a);
        if (m == 0) {
            vm.prank(owner);
            core.removeTarget(t);
        } else if (m == 1) {
            vm.startPrank(owner);
            try core.addTarget(t) {
                if (!core.allowedTarget(t)) _flag(V_OWNER, "addTarget did not allow the target at once");
                core.removeTarget(t);
            } catch (bytes memory why) {
                // the stack contracts and the exit side are refused, nothing else is
                bool shut = core.targetsLocked() && bytes4(why) == ICore.Locked.selector;
                if (bytes4(why) != ICore.ForbiddenTarget.selector && !shut) _unexpected(a, why);
            }
            vm.stopPrank();
        } else if (m == 2) {
            vm.startPrank(owner);
            core.transferOwnership(t);
            if (core.pendingOwner() != t || core.owner() != owner) _flag(V_OWNER, "a handover moved the owner early");
            core.transferOwnership(address(0));
            vm.stopPrank();
            if (core.pendingOwner() != address(0)) _flag(V_OWNER, "the handover was not cleared");
        } else {
            vm.startPrank(t);
            try core.addTarget(t) {
                _flag(V_OWNER, "a stranger added a target");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            }
            try core.lockTargets() {
                _flag(V_OWNER, "a stranger locked the targets");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            }
            try core.acceptOwnership() {
                _flag(V_OWNER, "a stranger accepted a handover that was not offered");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyPendingOwner.selector) _unexpected(a, why);
            }
            vm.stopPrank();
        }
        if (core.owner() != owner) _flag(V_OWNER, "the owner changed");
        _opost(p, "ownerMisc");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                              REPLACE THE EXIT MODULE
    //////////////////////////////////////////////////////////////*/

    /// the owner replaces the exit module at once (docs/FLOW.md section 8): a new module with the same
    /// exit token and a new unit, the same address again after its unit changed, the same address and unit, and the
    /// refused ones (another exit token, no unit, a unit the opening price floor refuses, no code). a good set keeps the pots, the balances and the
    /// exit auction price and clock, credits the exit rate under the old unit, resyncs the funded flag, reads the unit again and
    /// switches the handler to the new module. a refused one changes nothing
    function replaceModule(uint256 seed, uint256 mode) external checked {
        uint8 a = A_REPLACE_MODULE;
        if (!phase2()) return _skip(a);
        address token = core.exitToken();
        address oldModule = core.exitModule();
        uint256 oldUnit = core.unitPerCredit();
        (MockExitModule next, bytes4 want) = _nextModule(seed, mode % 8, token);
        // a locked module door refuses every set, whatever the module
        if (core.exitModuleLocked()) want = ICore.Locked.selector;
        _att(a);
        OPre memory p = _opre();
        uint256 start0 = core.xStartPrice();
        uint64 at0 = core.xStartTime();
        vm.prank(owner);
        try core.setExitModule(address(next)) {
            if (want != 0) _flag(V_OWNER, "a refused module set was accepted");
            _afterModuleSet(p, next, token, start0, at0);
            module = next;
            _ok(a);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "replaceModule");
            _opost(p, "replaceModule");
            if (want == 0 || bytes4(why) != want) _unexpected(a, why);
            else _ok(a);
            if (core.exitModule() != oldModule || core.unitPerCredit() != oldUnit || core.exitToken() != token) {
                _flag(V_OWNER, "a refused module set changed the module, the unit or the token");
            }
        }
    }

    /// the module the owner proposes and the selector the set must revert with, zero when it must go through
    function _nextModule(uint256 seed, uint256 m, address token) internal returns (MockExitModule next, bytes4 want) {
        if (m <= 1) {
            next = new MockExitModule(token, _logBound(seed >> 8, 2e9, 5e10));
        } else if (m <= 3) {
            // the same module again: its unit changed (m 2) or did not (m 3), and it answers the unit read
            module.setRevertUnit(false);
            if (m == 2) module.setUnitPerCredit(_logBound(seed >> 8, 2e9, 5e10));
            next = module;
        } else if (m == 4) {
            next = new MockExitModule(address(new MockExitToken("Other", "OTH")), 1e10);
            want = ICore.ExitTokenChanged.selector;
        } else if (m == 5) {
            next = new MockExitModule(token, seed % 2 == 0 ? 0 : uint256(type(uint128).max) + 1);
            want = ICore.BadModule.selector;
        } else if (m == 6) {
            // the opening price asks the supply for one slice (exitSliceCredits * unit, at least the unit): above
            // 1e33 per credit it falls under 1e12 under any setting
            next = new MockExitModule(token, 1e34);
            want = ICore.BadModule.selector;
        } else {
            next = MockExitModule(address(uint160(uint256(keccak256(abi.encode("nocode", seed))))));
            want = ICore.BadModule.selector;
        }
    }

    function _afterModuleSet(OPre memory p, MockExitModule next, address token, uint256 start0, uint64 at0) internal {
        _opost(p, "replaceModule");
        if (core.exitModule() != address(next)) _flag(V_OWNER, "the module set did not install the module");
        if (core.exitToken() != token) _flag(V_OWNER, "a module set changed the exit token");
        if (core.unitPerCredit() != next.currentUnit()) _flag(V_OWNER, "a module set did not read the unit again");
        // the climb so far was credited under the old unit
        if (core.xRate() != p.xRate) _flag(V_RATE_BOUND, "a module set lost or invented exit rate climb");
        _xFundedCheck();
        // the price is coin per exit token: kept whatever the unit, and the clock too while there is something to sell
        if (core.exitAuctionPrice() < p.xPrice) _flag(V_AUCTION, "a module set made the exit auction cheaper");
        // a later set never touches the start price or the clock, with or without something for sale
        if (core.exitAuctionPrice() != p.xPrice || core.xStartPrice() != start0 || core.xStartTime() != at0) {
            _flag(V_AUCTION, "a module set moved the exit auction");
        }
        if (core.allowedTarget(address(next))) {
            _flag(V_OWNER, "a module set left the allowed target flag of the module");
        }
    }

    /*//////////////////////////////////////////////////////////////
                           REPOINT THE FEE ROUTER
    //////////////////////////////////////////////////////////////*/

    /// the router owner as an adversary: points the engine at the core, at an engine that takes eth, at one that refuses it,
    /// at an address with no code or the zero address (both refused), and now and then locks the router while the core is
    /// the engine. a good set takes effect at once and moves no eth, not the router's and not the core's. after the lock
    /// every set reverts and the engine stays
    function repoint(uint256 seed, uint256 mode) external checked {
        uint8 a = A_REPOINT;
        if (otherEngine == address(0)) {
            otherEngine = address(new CountingEngine());
            refusingEngine = address(new RefusingEngine());
        }
        address ro = feeRouter.owner();
        uint256 m = mode % 6;
        address target = m == 0 ? address(core) : (m == 1 ? otherEngine : (m == 2 ? refusingEngine : (m == 3 ? address(uint160(seed | 0x10000)) : (m == 4 ? address(0) : address(core)))));
        OPre memory pre = _opre();
        uint256 held = address(feeRouter).balance;
        _att(a);
        if (m == 5 && !gRouterLocked && seed % 25 == 0 && gEngine == address(core)) {
            vm.prank(ro);
            try feeRouter.lock() {
                gRouterLocked = true;
            } catch {
                _flag(V_ROUTER, "the router owner could not lock with an engine set");
            }
        }
        vm.prank(ro);
        try feeRouter.setEngine(target) {
            if (gRouterLocked) {
                _flag(V_ROUTER, "setEngine worked on a locked router");
            } else if (target == address(0) || target.code.length == 0) {
                _flag(V_ROUTER, "setEngine took an address with no code");
            } else {
                gEngine = target;
            }
        } catch {
            bool bad = !gRouterLocked && target != address(0) && target.code.length != 0;
            if (bad) _flag(V_ROUTER, "setEngine refused a good engine");
        }
        if (feeRouter.engine() != gEngine) _flag(V_ROUTER, "the router engine is not the one set");
        if (feeRouter.locked() != gRouterLocked) _flag(V_LOCK, "the router lock flag differs from the ghost");
        if (address(feeRouter).balance != held) _flag(V_ROUTER, "setting the engine moved router eth");
        _opost(pre, "repoint");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                               RESCUE AN NFT
    //////////////////////////////////////////////////////////////*/

    /// the owner calls `rescueNft` on every kind of token: a credit in a pile and a held statement (both refused, the
    /// books and the holder unchanged), a credit an actor sent straight to the core (leaves, to a fresh address, and the
    /// piles keep their sizes), the coin, the exit token and an address with no code (refused), and a stranger (refused).
    /// no eth, pot or exit token moves in any of them
    function rescueNft(uint256 seed, uint256 mode) external checked {
        uint8 a = A_RESCUE_NFT;
        Rescue memory r = _rescuePick(seed, mode % 6);
        if (!r.ok) return _skip(a);
        address to = address(uint160(uint256(keccak256(abi.encode("rescue", seed)))));
        OPre memory p = _opre();
        uint256 books = _rescueBooks();
        _att(a);
        vm.prank(r.who);
        try core.rescueNft(r.token, r.id, to) {
            if (!r.leaves) _flag(V_OWNER, "rescueNft moved a token that must stay");
            else if (CREDITS.ownerOf(r.id) != to) _flag(V_OWNER, "a stray credit did not reach the destination");
        } catch (bytes memory why) {
            if (r.leaves || bytes4(why) != r.want) _unexpected(a, why);
        }
        if (r.token == address(CREDITS) && !r.leaves && CREDITS.ownerOf(r.id) == to) {
            _flag(V_OWNER, "a credit that must stay left the core");
        }
        if (r.token == address(STATEMENTS) && _ownerOf(r.id) == to) _flag(V_OWNER, "a held statement left the core");
        if (_rescueBooks() != books) _flag(V_OWNER, "rescueNft changed a pile or the held statements");
        _opost(p, "rescueNft");
        _ok(a);
    }

    struct Rescue {
        bool ok;
        bool leaves;
        address token;
        uint256 id;
        address who;
        bytes4 want;
    }

    /// the oldest credit of the pile of `lane`, zero when it is empty
    function _head(Lane lane) internal view returns (uint256) {
        uint256[] memory page = core.pilePage(lane, 0, 1);
        return page.length == 0 ? 0 : page[0];
    }

    function _rescueBooks() internal view returns (uint256) {
        return uint256(keccak256(abi.encode(core.pileSize(Lane.Eth), core.pileSize(Lane.Exit), core.heldStatements())));
    }

    /// the token and the caller of one `rescueNft` call, by kind. a stray credit is moved into the core here
    function _rescuePick(uint256 seed, uint256 m) internal returns (Rescue memory r) {
        r.who = owner;
        if (m == 0) {
            r.token = address(CREDITS);
            r.id = _head(seed % 2 == 0 ? Lane.Eth : Lane.Exit);
            if (r.id == 0) r.id = _head(seed % 2 == 0 ? Lane.Exit : Lane.Eth);
            r.ok = r.id != 0;
            r.want = ICore.InPile.selector;
        } else if (m == 1) {
            uint256[] memory held = core.heldStatements();
            r.ok = held.length != 0;
            if (r.ok) r.id = held[seed % held.length];
            r.token = address(STATEMENTS);
            r.want = ICore.Held.selector;
        } else if (m == 2) {
            address from = _actor(seed >> 8);
            uint256 len = inventory[from].length;
            if (len == 0) return r;
            r.id = inventory[from][seed % len];
            if (CREDITS.ownerOf(r.id) != from) return r;
            r.token = address(CREDITS);
            r.leaves = true;
            r.ok = true;
            vm.prank(from);
            CREDITS.transferFrom(from, address(core), r.id);
            _removeFrom(inventory[from], r.id);
        } else if (m == 3) {
            r.token = address(coin);
            if (phase2() && seed % 2 == 0) r.token = core.exitToken();
            if (seed % 5 == 0) r.token = address(uint160(seed));
            r.id = 1 + seed % 1e18;
            r.ok = true;
            r.want = ICore.NotHolder.selector;
        } else if (m == 4) {
            r.token = address(CREDITS);
            r.id = _head(Lane.Eth);
            r.ok = r.id != 0;
            r.who = _actor(seed >> 16);
            r.want = ICore.OnlyOwner.selector;
        } else {
            r.token = address(STATEMENTS);
            r.id = STATEMENTS.supply() + 1 + seed % 5;
            r.ok = true;
            r.want = ICore.NotHolder.selector;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         SUCCESSOR AND MIGRATION
    //////////////////////////////////////////////////////////////*/

    /// the stand in successor and the one way lock of `setSuccessor` as the handler has seen it
    MigrationSink public sink;
    bool public gLockedS;
    address public gSuccessorAtLock;

    struct MigPre {
        uint256 eth;
        uint256 balance;
        uint256 x;
        uint256 xBuyback;
        uint256 xBalance;
        uint256 sinkEth;
        uint256 sinkX;
        uint256[] credits;
        uint256[] statements;
        uint256 maxCredits;
        uint256 buyback;
        bool wasRetired;
    }

    /// the owner's successor doors and `migrate`. by mode: set the successor (refused after the lock), a stranger on the
    /// three doors (refused), the lock (only with a successor set, rarely), and mostly `migrate` with random batch sizes.
    /// a migration is modelled from the ghosts: `ethPot` and `xPot` go to the sink whole, `ethToBuyback` and `xToBuyback` stay, the first
    /// `maxCredits` of each pile go to the sink, and the held statements stay as they are. eth, exit token, credits,
    /// the held list, trackers and the event are compared with that model
    function migrate(uint256 seed, uint256 mode) external checked {
        uint8 a = A_MIGRATE;
        uint256 m = mode % 10;
        if (address(sink) == address(0)) sink = new MigrationSink();
        _att(a);
        if (m == 0) return _successorSet(a, seed);
        if (m == 1) return _successorStranger(a, seed);
        if (m == 2) return _successorLock(a, seed);
        _migrate(a, seed);
    }

    function _successorSet(uint8 a, uint256 seed) internal {
        OPre memory p = _opre();
        bool locked = core.successorLocked();
        address want = seed % 4 == 0 ? address(0) : address(sink);
        vm.prank(owner);
        try core.setSuccessor(want) {
            if (locked) _flag(V_LOCK, "setSuccessor worked after the lock");
            else if (core.successor() != want) _flag(V_OWNER, "setSuccessor did not set the successor");
        } catch (bytes memory why) {
            if (!locked || bytes4(why) != ICore.Locked.selector) _unexpected(a, why);
        }
        _opost(p, "setSuccessor");
        _ok(a);
    }

    function _successorStranger(uint8 a, uint256 seed) internal {
        OPre memory p = _opre();
        address who = _actor(seed);
        bytes[3] memory calls = [
            abi.encodeCall(ICore.setSuccessor, (who)),
            abi.encodeCall(ICore.lockSuccessor, ()),
            abi.encodeCall(ICore.migrate, (100))
        ];
        address was = core.successor();
        bool wasLocked = core.successorLocked();
        for (uint256 i; i < 3; ++i) {
            vm.prank(who);
            (bool ok, bytes memory out) = address(core).call(calls[i]);
            if (ok || bytes4(out) != ICore.OnlyOwner.selector) _flag(V_OWNER, "a stranger used a successor door");
        }
        if (core.successor() != was || core.successorLocked() != wasLocked) _flag(V_OWNER, "a stranger moved the successor");
        _opost(p, "successorStranger");
        _ok(a);
    }

    /// the lock closes `setSuccessor` for good, so it is only taken while a successor is set and then rarely
    function _successorLock(uint8 a, uint256 seed) internal {
        if (core.successor() == address(0) || seed % 6 != 0) return _skip(a);
        OPre memory p = _opre();
        vm.prank(owner);
        try core.lockSuccessor() {
            gLockedS = true;
            gSuccessorAtLock = core.successor();
            if (!core.successorLocked()) _flag(V_LOCK, "lockSuccessor did not set its flag");
        } catch (bytes memory why) {
            _unexpected(a, why);
        }
        _successorShut();
        _opost(p, "lockSuccessor");
        _ok(a);
    }

    function _successorShut() internal {
        vm.prank(owner);
        (bool ok, bytes memory out) = address(core).call(abi.encodeCall(ICore.setSuccessor, (address(0))));
        if (ok || bytes4(out) != ICore.Locked.selector) _flag(V_LOCK, "a locked successor door took a successor");
    }

    function _migrate(uint8 a, uint256 seed) internal {
        if (core.successor() == address(0)) {
            if (core.successorLocked()) {
                vm.prank(owner);
                try core.migrate(1) {
                    _flag(V_OWNER, "migrate worked with no successor");
                } catch (bytes memory why) {
                    if (bytes4(why) != ICore.NoSuccessor.selector) _unexpected(a, why);
                }
                return _ok(a);
            }
            vm.prank(owner);
            core.setSuccessor(address(sink));
        }
        // a migrate retires the core for the rest of the run, so the first one is rare
        if (!gRetired && (seed >> 16) % 6 != 0) return _skip(a);
        address to = core.successor();
        MigPre memory q = _migPre(seed, to);
        vm.recordLogs();
        vm.prank(owner);
        try core.migrate(q.maxCredits) {
            _migPost(q, to);
            _ok(a);
        } catch (bytes memory why) {
            _unexpected(a, why);
        }
    }

    function _migPre(uint256 seed, address to) internal returns (MigPre memory q) {
        q.eth = core.ethPot();
        q.buyback = core.ethToBuyback();
        q.wasRetired = gRetired;
        q.balance = address(core).balance;
        q.x = core.xPot();
        q.xBuyback = core.xToBuyback();
        q.xBalance = _xBal(address(core));
        q.sinkEth = to.balance;
        q.sinkX = _xBal(to);
        q.maxCredits = seed % 7 == 0 ? 0 : _logBound(seed >> 8, 1, 120);
        uint256 e = core.pileSize(Lane.Eth);
        uint256 x = core.pileSize(Lane.Exit);
        uint256[] memory eth = core.pilePage(Lane.Eth, 0, q.maxCredits < e ? q.maxCredits : e);
        uint256[] memory exit = core.pilePage(Lane.Exit, 0, q.maxCredits < x ? q.maxCredits : x);
        q.credits = new uint256[](eth.length + exit.length);
        for (uint256 i; i < eth.length; ++i) {
            q.credits[i] = eth[i];
        }
        for (uint256 i; i < exit.length; ++i) {
            q.credits[eth.length + i] = exit[i];
        }
        q.statements = core.heldStatements();
    }

    function _migPost(MigPre memory q, address to) internal {
        gRetired = true;
        if (!core.retired()) _flag(V_RETIRED, "migrate did not set retired");
        // eth and exit token: the trackers went to the successor whole
        // the pot goes to the successor, the buyback pot stays
        _eth(q.balance, q.eth, 0, "migrate");
        _x(q.xBalance, q.x, 0, "migrate");
        if (to.balance != q.sinkEth + q.eth) _flag(V_OWNER, "the successor did not get the eth pots");
        if (_xBal(to) != q.sinkX + q.x) _flag(V_OWNER, "the successor did not get xPot");
        if (core.ethPot() != 0 || core.xPot() != 0) _flag(V_OWNER, "a tracker is not zero after a migration");
        if (core.xToBuyback() != q.xBuyback) _flag(V_OWNER, "migrate moved the exit buyback pot");
        if (core.ethToBuyback() != q.buyback) _flag(V_OWNER, "migrate moved the eth buyback pot");
        // credits: the first of each pile
        for (uint256 i; i < q.credits.length; ++i) {
            uint256 id = q.credits[i];
            if (CREDITS.ownerOf(id) != to) _flag(V_OWNER, "a credit of the batch did not reach the successor");
            (bool inPile,,,) = core.creditInfo(id);
            if (inPile) _flag(V_OWNER, "a migrated credit is still in a pile");
            CG storage c = cg[id];
            if (!c.inPile) {
                _flag(V_MODEL, "the core moved a credit the ghost does not have in a pile");
            } else {
                c.inPile = false;
            }
        }
        // statements: the held list is as it was
        uint256[] memory held = core.heldStatements();
        if (held.length != q.statements.length) _flag(V_OWNER, "the held list differs from the model after a migration");
        else {
            for (uint256 i; i < held.length; ++i) {
                if (held[i] != q.statements[i]) _flag(V_OWNER, "the held list changed order after a migration");
            }
        }
        _migEvent(q, to);
    }

    function _migEvent(MigPre memory q, address to) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        uint256 retiredLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.EngineRetired.selector) ++retiredLogs;
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.Migrated.selector) continue;
            seen = true;
            if (address(uint160(uint256(logs[i].topics[1]))) != to) _flag(V_OWNER, "Migrated names another successor");
            (uint256 eth, uint256 x, uint256 credits) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (eth != q.eth || x != q.x || credits != q.credits.length) _flag(V_OWNER, "Migrated differs from the model");
        }
        if (!seen) _flag(V_OWNER, "migrate emitted no Migrated");
        if (retiredLogs != (q.wasRetired ? 0 : 1)) _flag(V_RETIRED, "EngineRetired is not logged exactly by the first migrate");
    }
}
