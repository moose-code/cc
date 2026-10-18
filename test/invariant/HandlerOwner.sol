// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {
    Settings,
    CreditSale,
    RATE_START_MIN_WEI,
    RATE_START_MAX_WEI,
    BUYBACK_GAS
} from "../../src/interfaces/Interfaces.sol";
import {BidModel} from "../utils/BidModel.sol";
import {HandlerBase} from "./HandlerBase.sol";
import {MockBalanceModule} from "../standins/MockBalanceModule.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";
import {MockNft} from "../standins/MockNft.sol";
import {MigrationSink} from "../standins/MigrationSink.sol";

/// @notice the owner as an adversarial actor. the owner calls `setSettings` with random valid settings across the
/// operating ranges, with selected boundary cases, `setRate` anywhere in its bounds, and invalid
/// settings, rates and callers that must revert. the bounds are written out again here, independently of the
/// library under test. after every owner call the settings are what was set, the rate is what it should be, and the
/// core's eth, pots and balance token did not move: the owner has no path to the assets.
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

    /// random valid settings over operating ranges, from `seed`. `corner` picks an extreme to force on top
    function _genSettings(uint256 seed, uint256 corner, Settings memory c) internal pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPer100PointsBps = uint16(_f(_r(seed, 2), 1, 1_000, c.dropPer100PointsBps));
        s.dropFloorBps = uint16(_f(_r(seed, 3), 5_000, 10_000, c.dropFloorBps));
        s.climbPerMinBps = uint16(_f(_r(seed, 4), 1, 1_000, c.climbPerMinBps));
        s.ceilBps = uint16(_f(_r(seed, 5), 10_000, 30_000, c.ceilBps));
        s.idleLoosenBps = uint16(_f(_r(seed, 29), 1, 2_000, c.idleLoosenBps));
        s.saleFloorBps = uint16(_f(_r(seed, 12), 1_000, 40_000, c.saleFloorBps));
        s.saleToBuybackBps = uint16(_f(_r(seed, 15), 0, 10_000, c.saleToBuybackBps));
        s.buybackSlice = uint128(_f(_r(seed, 17), 0.01 ether, 1 ether, c.buybackSlice));
        s.buybackDelay = uint16(_f(_r(seed, 18), 1, 7_200, c.buybackDelay));
        s.keeperFee = uint64(_f(_r(seed, 19), 0, 0.005 ether, c.keeperFee));
        s.keeperMaxBaseFee = uint48(_f(_r(seed, 30), 1 gwei, 100 gwei, c.keeperMaxBaseFee));
        s.redeemOn = _f(_r(seed, 20), 0, 1, c.redeemOn ? 1 : 0) == 1;
        s.balanceBidOn = _f(_r(seed, 34), 0, 1, c.balanceBidOn ? 1 : 0) == 1;
        s.redeemSlippageBps = uint16(_f(_r(seed, 21), 0, 1_000, c.redeemSlippageBps));
        s.balanceBidMarginBps = uint16(_f(_r(seed, 22), 0, 9_000, c.balanceBidMarginBps));
        s.redeemBurnBps = uint16(_f(_r(seed, 23), 0, 10_000, c.redeemBurnBps));
        s.rateCap = uint64(_f(_r(seed, 26), RATE_START_MIN_WEI, RATE_START_MAX_WEI, c.rateCap));
        s.feeToRedeemBurnBps = uint16(_f(_r(seed, 27), 0, 10_000, c.feeToRedeemBurnBps));
        s.payeePpm = uint24(_f(_r(seed, 40), 0, 200_000, c.payeePpm));
        s.pointsPerPage = uint32(_f(_r(seed, 41), 1, 100_000, c.pointsPerPage));
        s.swapFeeCc = uint96(_f(_r(seed, 42), 0, 1e24, c.swapFeeCc));
        s.climbMultiplierCapBps = uint16(_f(_r(seed, 43), 10_000, 40_000, c.climbMultiplierCapBps));
        s.callerFee = uint64(_f(_r(seed, 10), 0, 0.005 ether, c.callerFee));
        s.callerMaxBaseFee = uint48(_f(_r(seed, 11), 0, 100 gwei, c.callerMaxBaseFee));
        s.spendCapBps = uint16(_f(_r(seed, 44), 1, 10_000, c.spendCapBps));
        s.bucketSeconds = uint32(_f(_r(seed, 45), 1, 3600, c.bucketSeconds));
        s.balanceBidCapBps = uint32(_f(_r(seed, 46), 10_000, 30_000, c.balanceBidCapBps));
        s.idleStepSeconds = uint32(_f(_r(seed, 47), 1, 3600, c.idleStepSeconds));
        s.sniperSeconds = uint32(_f(_r(seed, 48), 0, 3600, c.sniperSeconds));
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
            s.dropPer100PointsBps = 1;
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
            s.dropPer100PointsBps = 1_000;
            s.dropFloorBps = 5_000;
        } else if (k == 10) {
            // the smallest slice: the cheapest payment allows it
            s.buybackSlice = 0.01 ether;
            s.keeperFee = 0;
            s.keeperMaxBaseFee = 1 gwei;
        } else if (k == 11) {
            s.buybackSlice = 1 ether;
        } else if (k == 12) {
            s.redeemOn = false;
            s.balanceBidOn = false;
        } else if (k == 13) {
            s.redeemOn = true;
            s.balanceBidOn = true;
            s.redeemSlippageBps = 1_000;
            s.balanceBidMarginBps = 9_000;
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
        } else if (k == 17) {
            // the lowest rate cap: it pulls the eth rate down to it at the checkpoint
            s.rateCap = uint64(RATE_START_MIN_WEI);
        } else if (k == 18) {
            // the whole fee stream to the pot
            s.feeToRedeemBurnBps = 0;
        } else if (k == 19) {
            // the whole fee stream to the redeem burn reserve and the full per redemption release
            s.feeToRedeemBurnBps = 10_000;
            s.redeemBurnBps = 10_000;
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
        uint256 reserve;
        uint256 rate;
        uint256 price;
        uint256 stored;
        uint256 xBal;
        address xToken;
    }

    function _opre() internal view returns (OPre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.toBuyback = core.ethToBuyback();
        p.reserve = core.ethRedeemBurn();
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.stored = core.rateAtCheckpoint();
        p.xBal = _xBal(address(core));
        p.xToken = core.balanceToken();
    }

    /// what no owner call may touch: the core's eth and its pots. the core holds only balance token donated straight to
    /// it (dust the module does not hold), so the token holding is unchanged unless the call replaced the token. a
    /// replacement onto a fresh token is checked against the donated dust in `replaceModule`
    function _opost(OPre memory p, string memory what) internal {
        _eth(p.bal, 0, 0, what);
        if (core.balanceToken() == p.xToken) _x(p.xBal, 0, 0, what);
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.toBuyback || core.ethRedeemBurn() != p.reserve) {
            _flag(V_OWNER, "an owner call moved a pot");
        }
        gOwnerCalls++;
    }

    /// the owner changes the settings to random valid ones, effective at once. nothing may revert. afterwards the
    /// settings are what was set; the call checkpoints accrued ETH growth while open and preserves the stored rate
    /// while paused. The pots and balances do not move.
    /// the owner sets exactly `ns` and the ghost follows. not in the fuzz selector list: the smoke tests use it
    function setSettingsExact(Settings memory ns) external {
        vm.prank(owner);
        core.setSettings(ns);
        gSettingsHash = keccak256(abi.encode(core.settings()));
    }

    /// the owner sets exactly `rate` through `setRate`. not in the fuzz selector list: the smoke tests use it
    function setRateExact(uint256 rate) external {
        vm.prank(owner);
        core.setRate(rate);
    }

    function setSettings(uint256 seed, uint256 corner) external checked {
        uint8 a = A_SET_SETTINGS;
        Settings memory cur = core.settings();
        Settings memory ns = _genSettings(seed, corner, cur);
        // decision 124: keep the floor at or below the real controller's start so its setSale is never blocked. the core
        // enforces this only while the live controller answers markupBps, so the handler holds the stronger bound itself
        if (v1 != address(0)) {
            uint16 mk = IControllerV1(v1).markupBps();
            if (ns.saleFloorBps > mk) ns.saleFloorBps = mk;
        }
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
        // Outside an owner pause the call checkpoints under the old settings. During a pause the stored rate remains
        // frozen. The new settings still bound the read through the ceiling, rate cap and live clamp.
        {
            uint256 stored = core.rateAtCheckpoint();
            uint256 want = BidModel.read(ns, _room(), _priceNow(ns));
            if (stored != (core.paused() ? p.stored : p.price)) {
                _flag(V_RATE_BOUND, "a settings call moved the stored eth rate");
            }
            if (core.ethRate() != want) _flag(V_RATE_BOUND, "a settings call moved the eth rate");
        }
    }

    /// the bounds of docs/DECISIONS.md section 2, written out again. the name of the first field out of bounds, or zero
    function _firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.dropPer100PointsBps < 1 || s.dropPer100PointsBps > 10_000) return "dropPer100PointsBps";
        if (s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1) return "climbPerMinBps";
        if (s.ceilBps < 10_000) return "ceilBps";
        if (s.idleLoosenBps < 1) return "idleLoosenBps";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (uint256(s.saleToArtistBps) + s.saleToOperatorBps >= 10_000) return "saleToOperatorBps";
        if (s.peakHalfLife < 1) return "peakHalfLife";
        if (s.recoveryClimbPerMinBps < s.climbPerMinBps) return "recoveryClimbPerMinBps";
        if (s.recoveryGapBps > 10_000) return "recoveryGapBps";
        if (s.buybackSlice < 1) return "buybackSlice";
        if (s.buybackDelay < 1) return "buybackDelay";
        // A funded swap keeps at least half its slice after the largest keeper payment.
        if (s.buybackSlice < 2 * (BUYBACK_GAS * uint256(s.keeperMaxBaseFee) + s.keeperFee)) return "buybackSlice";
        if (s.rateCap < RATE_START_MIN_WEI || s.rateCap > RATE_START_MAX_WEI) return "rateCap";
        if (s.feeToRedeemBurnBps > 10_000) return "feeToRedeemBurnBps";
        if (s.redeemSlippageBps > 10_000) return "redeemSlippageBps";
        if (s.balanceBidMarginBps > 10_000) return "balanceBidMarginBps";
        if (s.redeemBurnBps > 10_000) return "redeemBurnBps";
        if (s.payeePpm > 1_000_000) return "payeePpm";
        if (s.pointsPerPage < 1) return "pointsPerPage";
        if (s.climbMultiplierCapBps < 10_000) return "climbMultiplierCapBps";
        if (s.spendCapBps < 1 || s.spendCapBps > 10_000) return "spendCapBps";
        if (s.bucketSeconds < 1) return "bucketSeconds";
        if (s.balanceBidCapBps < 10_000) return "balanceBidCapBps";
        if (s.idleStepSeconds < 1) return "idleStepSeconds";
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// breaks exactly one field of valid settings, `which` picks it. returns the name the library must report
    function _break(Settings memory s, uint256 which) internal pure returns (bytes32 name) {
        which %= 24;
        if (which == 0) {
            s.dropPer100PointsBps = 10_001;
            return "dropPer100PointsBps";
        } else if (which == 1) {
            s.dropPer100PointsBps = 0;
            return "dropPer100PointsBps";
        } else if (which == 2) {
            s.dropFloorBps = 10_001;
            return "dropFloorBps";
        } else if (which == 3) {
            s.climbPerMinBps = 0;
            return "climbPerMinBps";
        } else if (which == 4) {
            s.ceilBps = 9_999;
            return "ceilBps";
        } else if (which == 5) {
            s.idleLoosenBps = 0;
            return "idleLoosenBps";
        } else if (which == 6) {
            s.saleToBuybackBps = 10_001;
            return "saleToBuybackBps";
        } else if (which == 7) {
            s.peakHalfLife = 0;
            return "peakHalfLife";
        } else if (which == 8) {
            s.recoveryClimbPerMinBps = 0;
            return "recoveryClimbPerMinBps";
        } else if (which == 9) {
            s.recoveryGapBps = 10_001;
            return "recoveryGapBps";
        } else if (which == 10) {
            s.buybackSlice = 0;
            return "buybackSlice";
        } else if (which == 11) {
            s.buybackDelay = 0;
            return "buybackDelay";
        } else if (which == 12) {
            s.rateCap = 0;
            return "rateCap";
        } else if (which == 13) {
            s.feeToRedeemBurnBps = 10_001;
            return "feeToRedeemBurnBps";
        } else if (which == 14) {
            s.redeemSlippageBps = 10_001;
            return "redeemSlippageBps";
        } else if (which == 15) {
            s.balanceBidMarginBps = 10_001;
            return "balanceBidMarginBps";
        } else if (which == 16) {
            s.redeemBurnBps = 10_001;
            return "redeemBurnBps";
        } else if (which == 17) {
            s.payeePpm = 1_000_001;
            return "payeePpm";
        } else if (which == 18) {
            s.pointsPerPage = 0;
            return "pointsPerPage";
        } else if (which == 19) {
            s.climbMultiplierCapBps = 9_999;
            return "climbMultiplierCapBps";
        } else if (which == 20) {
            s.spendCapBps = 0;
            return "spendCapBps";
        } else if (which == 21) {
            s.bucketSeconds = 0;
            return "bucketSeconds";
        } else if (which == 22) {
            s.balanceBidCapBps = 9_999;
            return "balanceBidCapBps";
        } else if (which == 23) {
            s.idleStepSeconds = 0;
            return "idleStepSeconds";
        }
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
            uint256 want = BidModel.read(cs, _room(), _priceNow(cs));
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

    /// the owner's other doors, which only ever touch the adapter list and the owner slot, all at once: remove an adapter,
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
            core.removeAdapter(t);
        } else if (m == 1) {
            vm.startPrank(owner);
            try core.addAdapter(t) {
                if (!core.allowedAdapter(t)) _flag(V_OWNER, "addAdapter did not approve the adapter at once");
                core.removeAdapter(t);
            } catch (bytes memory why) {
                // the stack contracts and the balance side are refused, nothing else is
                bool shut = core.adaptersLocked() && bytes4(why) == ICore.Locked.selector;
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
            try core.addAdapter(t) {
                _flag(V_OWNER, "a stranger added an adapter");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            }
            try core.lockAdapters() {
                _flag(V_OWNER, "a stranger locked the adapters");
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
                              REPLACE THE BALANCE MODULE
    //////////////////////////////////////////////////////////////*/

    /// the owner replaces the balance module at once (docs/DECISIONS.md section 8): a new module with the same
    /// balance token and a new unit, the same address again after its unit changed, the same address and unit, a new
    /// module on a fresh token, and the refused ones (a token equal to a forbidden base address, no unit, a unit above
    /// the uint128 bound, no code). a good set keeps the pots and the eth balances, reads the unit again, follows the
    /// module and token with the handler ghosts, and leaves the Core holding no balance token. a refused one changes
    /// nothing
    function replaceModule(uint256 seed, uint256 mode) external checked {
        uint8 a = A_REPLACE_MODULE;
        if (!phase2()) return _skip(a);
        address token = core.balanceToken();
        address oldModule = core.balanceModule();
        (MockBalanceModule next, bytes4 want) = _nextModule(seed, mode % 9, token);
        // a locked module door refuses every set, whatever the module
        if (core.balanceModuleLocked()) want = ICore.Locked.selector;
        _att(a);
        OPre memory p = _opre();
        uint256 oldReserve = _xBal(oldModule);
        vm.prank(owner);
        try core.setBalanceModule(address(next)) {
            if (want != 0) _flag(V_OWNER, "a refused module set was accepted");
            _afterModuleSet(p, next, token);
            // a token change leaves the replaced module's reserve where it was, the Core holding only the dust donated
            // straight to it on the replaced token, and none of the fresh token
            if (core.balanceToken() != token) {
                MockBalanceToken old = MockBalanceToken(token);
                if (old.balanceOf(oldModule) != oldReserve) _flag(V_OWNER, "a replacement moved the old reserve");
                if (old.balanceOf(address(core)) != gDonatedX[token]) {
                    _flag(V_OWNER, "the Core holds the replaced token beyond the donated dust");
                }
                if (_xBal(address(core)) != 0) _flag(V_OWNER, "the Core holds the new token");
            }
            module = next;
            balanceToken = MockBalanceToken(core.balanceToken());
            _ok(a);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "replaceModule");
            _opost(p, "replaceModule");
            if (want == 0 || bytes4(why) != want) _unexpected(a, why);
            else _ok(a);
            if (core.balanceModule() != oldModule || core.balanceToken() != token) {
                _flag(V_OWNER, "a refused module set changed the module or the token");
            }
        }
    }

    /// the module the owner proposes and the selector the set must revert with, zero when it must go through
    function _nextModule(uint256 seed, uint256 m, address token)
        internal
        returns (MockBalanceModule next, bytes4 want)
    {
        if (m <= 1) {
            next = new MockBalanceModule(token, _logBound(seed >> 8, 2e6, 5e7));
        } else if (m <= 3) {
            // the same module again: its unit changed (m 2) or did not (m 3), and it answers the unit read
            module.setRevertUnit(false);
            if (m == 2) module.setUnitPerPoint(_logBound(seed >> 8, 2e6, 5e7));
            next = module;
        } else if (m == 4) {
            // a module whose token is a forbidden base address is refused with BadModule
            next = new MockBalanceModule(address(CREDITS), 1e7);
            want = ICore.BadModule.selector;
        } else if (m == 5) {
            next = new MockBalanceModule(token, seed % 2 == 0 ? 0 : uint256(type(uint128).max) + 1);
            want = ICore.BadModule.selector;
        } else if (m == 6) {
            // a plain valid set with a large in bounds unit
            next = new MockBalanceModule(token, _logBound(seed >> 8, 1e8, 1e10));
        } else if (m == 8) {
            // a valid replacement onto a fresh token: the token changes and the ghosts follow it
            MockBalanceToken fresh = new MockBalanceToken("inv-replacement", "IRX");
            next = new MockBalanceModule(address(fresh), _logBound(seed >> 8, 1e8, 1e10));
        } else {
            next = MockBalanceModule(address(uint160(uint256(keccak256(abi.encode("nocode", seed))))));
            want = ICore.BadModule.selector;
        }
    }

    function _afterModuleSet(OPre memory p, MockBalanceModule next, address token) internal {
        _opost(p, "replaceModule");
        if (core.balanceModule() != address(next)) _flag(V_OWNER, "the module set did not install the module");
        if (core.balanceToken() != next.balanceToken()) _flag(V_OWNER, "the balance token is not the module's token");
        if (core.allowedAdapter(address(next))) {
            _flag(V_OWNER, "a module set left the approved adapter flag of the module");
        }
    }

    /*//////////////////////////////////////////////////////////////
                      CHANGE THE UNIT, RELEASE THE RESERVE
    //////////////////////////////////////////////////////////////*/

    /// the module reports a new unit. the core reads it at the next redemption or bid, so no asset moves
    function changeUnit(uint256 seed) external checked {
        uint8 a = A_CHANGE_UNIT;
        if (!phase2()) return _skip(a);
        OPre memory p = _opre();
        _att(a);
        module.setRevertUnit(false);
        module.setUnitPerPoint(_logBound(seed >> 8, 5e6, 2e7));
        _opost(p, "changeUnit");
        _ok(a);
    }

    /// the owner moves part of the redeem burn reserve into the coin buyback. no eth leaves the core and the three eth
    /// trackers keep their sum, so solvency and the eth books hold. a zero release or a stranger is refused
    function releaseRedeem(uint256 seed, uint256 amt) external checked {
        uint8 a = A_RELEASE_REDEEM;
        bool stranger = seed % 5 == 0;
        uint256 reserve = core.ethRedeemBurn();
        uint256 ask = seed % 4 == 0 ? reserve + 1 : (seed % 4 == 1 ? 0 : _logBound(amt, 1, reserve == 0 ? 1 : reserve));
        uint256 move = ask < reserve ? ask : reserve;
        uint256 pot = core.ethPot();
        uint256 tb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        uint256 rate = core.ethRate();
        _att(a);
        vm.prank(stranger ? _actor(seed >> 8) : owner);
        try core.releaseRedeemBurn(ask) {
            if (stranger) _flag(V_OWNER, "a stranger released the reserve");
            if (move == 0) _flag(V_OWNER, "a zero release was accepted");
            if (core.ethRedeemBurn() != reserve - move) _flag(V_OWNER, "the reserve did not fall by the move");
            if (core.ethToBuyback() != tb + move) {
                _flag(V_OWNER, "the released reserve did not reach the coin buyback");
            }
            if (core.ethPot() != pot) _flag(V_OWNER, "a release moved the pot");
            if (address(core).balance != bal) _flag(V_ETH_OUT, "a release moved eth out of the core");
            _ok(a);
        } catch (bytes memory why) {
            _failed(bal, pot, rate, "releaseRedeem");
            if (stranger) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
                else _ok(a);
            } else if (move == 0) {
                if (bytes4(why) != ICore.ZeroAmount.selector) _unexpected(a, why);
                else _ok(a);
            } else {
                _unexpected(a, why);
            }
            if (core.ethRedeemBurn() != reserve || core.ethToBuyback() != tb) {
                _flag(V_REVERT_CHANGED, "a refused release moved a pot");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               RESCUE AN NFT
    //////////////////////////////////////////////////////////////*/

    /// the owner calls `rescueNft` on every kind of token: a credit in a pile, a credit an actor sent straight to the
    /// core and a held statement (all refused, the books and the holder unchanged), the coin, the balance token and an
    /// address with no code (refused), and a stranger (refused). no eth, pot or balance token moves in any of them
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
            _flag(V_OWNER, "rescueNft moved a token that must stay");
        } catch (bytes memory why) {
            if (bytes4(why) != r.want) _unexpected(a, why);
        }
        if (r.token == address(CREDITS) && CREDITS.ownerOf(r.id) == to) {
            _flag(V_OWNER, "a credit that must stay left the core");
        }
        if (r.token == address(STATEMENTS) && _ownerOf(r.id) == to) _flag(V_OWNER, "a held statement left the core");
        if (_rescueBooks() != books) _flag(V_OWNER, "rescueNft changed a pile or the held statements");
        _opost(p, "rescueNft");
        _ok(a);
    }

    MockNft internal rescueMock;

    struct Rescue {
        bool ok;
        address token;
        uint256 id;
        address who;
        bytes4 want;
    }

    /// the oldest credit of the pile, zero when it is empty
    function _head() internal view returns (uint256) {
        uint256[] memory page = core.pilePage(0, 1);
        return page.length == 0 ? 0 : page[0];
    }

    function _rescueBooks() internal view returns (uint256) {
        return uint256(keccak256(abi.encode(core.pileSize(), core.heldStatements())));
    }

    /// the token and the caller of one `rescueNft` call, by kind. a stray credit is moved into the core here
    function _rescuePick(uint256 seed, uint256 m) internal returns (Rescue memory r) {
        r.who = owner;
        if (m == 0) {
            r.token = address(CREDITS);
            r.id = _head();
            r.ok = r.id != 0;
            r.want = ICore.NoCreditRescue.selector;
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
            r.ok = true;
            r.want = ICore.NoCreditRescue.selector;
            vm.prank(from);
            CREDITS.transferFrom(from, address(core), r.id);
            _removeFrom(inventory[from], r.id);
        } else if (m == 3) {
            r.token = address(coin);
            if (phase2() && seed % 2 == 0) r.token = core.balanceToken();
            // a deployed token that does not hold the id, so the call never depends on what lives at a derived address
            if (seed % 5 == 0) {
                if (address(rescueMock) == address(0)) rescueMock = new MockNft();
                r.token = address(rescueMock);
            }
            r.id = 1 + seed % 1e18;
            r.ok = true;
            r.want = ICore.NotHolder.selector;
        } else if (m == 4) {
            r.token = address(CREDITS);
            r.id = _head();
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
        uint256 xBalance;
        uint256 sinkEth;
        uint256 sinkX;
        uint256[] credits;
        uint256[] statements;
        uint256 maxCredits;
        uint256 buyback;
        uint256 reserve;
        bool wasRetired;
    }

    /// the owner's successor doors and `migrate`. by mode: set the successor (refused after the lock), a stranger on the
    /// three doors (refused), the lock (only with a successor set, rarely), and mostly `migrate` with random batch sizes.
    /// a migration is modelled from the ghosts: `ethPot` goes to the sink whole, `ethToBuyback` stays, the balance token is held by the module and does not move, the first
    /// `maxCredits` of each pile go to the sink, and the held statements stay as they are. eth, balance token, credits,
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
        if (core.successor() != was || core.successorLocked() != wasLocked) {
            _flag(V_OWNER, "a stranger moved the successor");
        }
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
        q.reserve = core.ethRedeemBurn();
        q.wasRetired = gRetired;
        q.balance = address(core).balance;
        q.xBalance = _xBal(address(core));
        q.sinkEth = to.balance;
        q.sinkX = _xBal(to);
        q.maxCredits = seed % 7 == 0 ? 0 : _logBound(seed >> 8, 1, 120);
        uint256 e = core.pileSize();
        q.credits = core.pilePage(0, q.maxCredits < e ? q.maxCredits : e);
        q.statements = core.heldStatements();
    }

    function _migPost(MigPre memory q, address to) internal {
        gRetired = true;
        if (!core.retired()) _flag(V_RETIRED, "migrate did not set retired");
        // the eth pot goes to the successor, the buyback pot stays; the balance token is held by the module, not moved
        _eth(q.balance, q.eth, 0, "migrate");
        _x(q.xBalance, 0, 0, "migrate");
        if (to.balance != q.sinkEth + q.eth) _flag(V_OWNER, "the successor did not get the eth pots");
        if (_xBal(to) != q.sinkX) _flag(V_OWNER, "the successor got balance token from migrate");
        if (core.ethPot() != 0) _flag(V_OWNER, "the eth pot is not zero after a migration");
        if (core.ethToBuyback() != q.buyback) _flag(V_OWNER, "migrate moved the eth buyback pot");
        if (core.ethRedeemBurn() != q.reserve) _flag(V_OWNER, "migrate moved the redeem burn reserve");
        // credits: the first of the pile
        for (uint256 i; i < q.credits.length; ++i) {
            uint256 id = q.credits[i];
            if (CREDITS.ownerOf(id) != to) _flag(V_OWNER, "a credit of the batch did not reach the successor");
            (bool inPile,,) = core.creditInfo(id);
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
        if (held.length != q.statements.length) {
            _flag(V_OWNER, "the held list differs from the model after a migration");
        } else {
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
            (uint256 eth, uint256 credits) = abi.decode(logs[i].data, (uint256, uint256));
            if (eth != q.eth || credits != q.credits.length) _flag(V_OWNER, "Migrated differs from the model");
        }
        if (!seen) _flag(V_OWNER, "migrate emitted no Migrated");
        if (retiredLogs != (q.wasRetired ? 0 : 1)) {
            _flag(V_RETIRED, "EngineRetired is not logged exactly by the first migrate");
        }
    }

    /*//////////////////////////////////////////////////////////////
                      the credit sale, chosen compose and reference settings
    //////////////////////////////////////////////////////////////*/

    /// the owner sets one of the eight credit settings (three on the core, five on the controller) to a value inside or
    /// outside its bounds, or a stranger tries. inside: it goes through and reads back. outside a bounded numeric field:
    /// BadSetting. a stranger: OnlyOwner. no asset or pot moves
    // the settings fuzz mutates pointsPerPage, a Core setting
    function creditSettings(uint256 seed, uint256 mode) external checked {
        uint8 a = A_CREDIT_SETTINGS;
        uint256 which = mode % 7;
        bool stranger = (mode >> 8) % 6 == 0;
        bool bad = (mode >> 12) % 4 == 0;
        (address target, bytes memory data, bool valid, uint256 want, uint256 cur) = _creditCase(which, seed, bad);
        address caller = stranger ? address(uint160(uint256(keccak256(abi.encode("creditStranger", seed))))) : owner;
        OPre memory pre = _opre();
        _att(a);
        vm.prank(caller);
        (bool ok, bytes memory out) = target.call(data);
        bytes4 expect = stranger ? ICore.OnlyOwner.selector : (valid ? bytes4(0) : ICore.BadSetting.selector);
        if (ok) {
            if (expect != 0) _flag(V_OWNER, "a credit setting the model refuses was accepted");
            if (_creditGot(which) != want) _flag(V_OWNER, "a credit setting did not read back");
            gOwnerCalls++;
        } else {
            if (expect == 0 || bytes4(out) != expect) _unexpected(a, out);
            if (_creditGot(which) != cur) _flag(V_OWNER, "a refused credit setting changed a value");
            gOwnerRefused++;
        }
        _opost(pre, "creditSettings");
        _ok(a);
    }

    /// the credit setting the handler tries: the target contract, the calldata, whether the model says it is inside the
    /// bounds, the value as a uint (a bool is 0 or 1, an address is its uint160), and the live value
    function _creditCase(uint256 which, uint256 seed, bool bad)
        internal
        view
        returns (address target, bytes memory data, bool valid, uint256 want, uint256 cur)
    {
        IControllerV1 c = IControllerV1(v1);
        if (which == 0) {
            target = address(core);
            cur = core.creditCostToPotBps();
            uint256 v = bad ? 10_001 + seed % 100 : _f(seed, 0, 10_000, cur);
            data = abi.encodeCall(ICore.setCreditCostToPotBps, (uint16(v)));
            valid = v <= 10_000;
            want = v;
        } else if (which == 1) {
            target = address(core);
            cur = core.chosenComposeOn() ? 1 : 0;
            bool bv = seed % 2 == 0;
            data = abi.encodeCall(ICore.setChosenComposeOn, (bv));
            valid = true;
            want = bv ? 1 : 0;
        } else if (which == 2) {
            target = address(core);
            cur = core.minCcToChoose();
            uint256 v = _f(seed, 0, 1e24, cur);
            data = abi.encodeCall(ICore.setMinCcToChoose, (uint96(v)));
            valid = true;
            want = v;
        } else if (which == 3) {
            target = v1;
            cur = c.creditSaleOn() ? 1 : 0;
            bool bv = seed % 2 == 0;
            CreditSale memory cs = _creditSaleOf(c);
            cs.saleOn = bv;
            data = abi.encodeCall(IControllerV1.setCredit, (cs));
            valid = true;
            want = bv ? 1 : 0;
        } else if (which == 4) {
            target = v1;
            cur = c.creditWindow();
            uint256 v = bad ? (0) : _f(seed, 1 minutes, 30 days, cur);
            CreditSale memory cs = _creditSaleOf(c);
            cs.window = uint32(v);
            data = abi.encodeCall(IControllerV1.setCredit, (cs));
            valid = v >= 1;
            want = v;
        } else if (which == 5) {
            target = v1;
            cur = c.creditSpreadBps();
            uint256 v = _f(seed, 0, 30_000, cur);
            CreditSale memory cs = _creditSaleOf(c);
            cs.spreadBps = uint16(v);
            data = abi.encodeCall(IControllerV1.setCredit, (cs));
            // the loop closure bound (decision 157): the spread must cover the reference band at the current tolerance,
            // so a spread below `(10_000 + tol) * 10_000 / (10_000 - tol) - 10_000` reverts BadSetting
            (,, uint16 tol,,,) = c.quote();
            uint256 req = ((10_000 + uint256(tol)) * 10_000 + (10_000 - uint256(tol)) - 1) / (10_000 - uint256(tol)) - 10_000;
            valid = v >= req;
            want = v;
        } else if (which == 6) {
            target = v1;
            cur = c.creditStartBps();
            uint256 v = bad ? (seed % 2 == 0 ? 9_999 : 200_001) : _f(seed, 10_000, 200_000, cur);
            CreditSale memory cs = _creditSaleOf(c);
            cs.startBps = uint32(v);
            data = abi.encodeCall(IControllerV1.setCredit, (cs));
            valid = v >= 10_000;
            want = v;
        }
    }

    /// the controller's credit sale settings as a struct
    function _creditSaleOf(IControllerV1 c) internal view returns (CreditSale memory) {
        return CreditSale({
            saleOn: c.creditSaleOn(),
            window: c.creditWindow(),
            spreadBps: c.creditSpreadBps(),
            startBps: c.creditStartBps()
        });
    }

    /// the live value of credit setting `which` as a uint (a bool is 0 or 1, an address is its uint160)
    function _creditGot(uint256 which) internal view returns (uint256) {
        IControllerV1 c = IControllerV1(v1);
        if (which == 0) return core.creditCostToPotBps();
        if (which == 1) return core.chosenComposeOn() ? 1 : 0;
        if (which == 2) return core.minCcToChoose();
        if (which == 3) return c.creditSaleOn() ? 1 : 0;
        if (which == 4) return c.creditWindow();
        if (which == 5) return c.creditSpreadBps();
        return c.creditStartBps();
    }
}
