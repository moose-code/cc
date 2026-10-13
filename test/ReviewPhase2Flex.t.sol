// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {SettingsStore} from "../src/lib/SettingsStore.sol";
import {Settings, Mainnet, IBalanceModule, IStatements, ICreditScore, ICredits} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";

/// @notice a module that tries to re enter every core door from inside its redeem callback. it pays the statement rating
/// times the unit
contract ReenteringModule is IBalanceModule {
    address public balanceToken;
    uint256 public unit;
    address public core;
    uint256 public attempts;
    uint256 public succeeded;
    bool public skimInside;

    constructor(address token, uint256 unit_, address core_) {
        balanceToken = token;
        unit = unit_;
        core = core_;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function _try(bytes memory data) private {
        ++attempts;
        (bool ok,) = core.call(data);
        if (ok) ++succeeded;
    }

    /// every non view door of the core, called from inside a callback
    function _poke() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        (skimInside,) = core.call(abi.encodeWithSignature("skim()"));
        _try(abi.encodeWithSignature("skim()"));
        _try(abi.encodeWithSignature("compose()"));
        _try(abi.encodeWithSignature("buyback()"));
        _try(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        _try(abi.encodeWithSignature("sellForBalance(uint256[])", ids));
        _try(abi.encodeWithSignature("redeemStatement(uint256)", 1));
        _try(abi.encodeWithSignature("buyListing(address,uint256,bytes)", address(this), 1, bytes("")));
        _try(abi.encodeWithSignature("setBalanceModule(address)", address(this)));
        _try(abi.encodeWithSignature("setController(address)", address(this)));
        _try(abi.encodeWithSignature("addAdapter(address)", address(this)));
        _try(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        _try(abi.encodeWithSignature("sellTo(uint256,address)", 1, address(this)));
        _try(abi.encodeWithSignature("adopt(uint256[])", ids));
    }

    /// the same skim from outside any callback, the control
    function skimOutside() external returns (bool ok) {
        (ok,) = core.call(abi.encodeWithSignature("skim()"));
    }

    function redeem(uint256 sid) external returns (uint256 out) {
        _poke();
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid) * unit;
        MockBalanceToken(balanceToken).mint(msg.sender, out);
    }
}

/// @notice a module whose balanceToken report and unit can change after it was set
contract FlipModule is IBalanceModule {
    address public balanceToken;
    uint256 public unit;

    constructor(address token, uint256 unit_) {
        balanceToken = token;
        unit = unit_;
    }

    function setToken(address t) external {
        balanceToken = t;
    }

    function setUnit(uint256 u) external {
        unit = u;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function redeem(uint256 sid) external returns (uint256 out) {
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid) * unit;
        MockBalanceToken(balanceToken).mint(msg.sender, out);
    }
}

/// @notice writes every settings field at the max of its type through the compiler layout, to read the raw words
contract PackHarness {
    function maxAll() external {
        Settings storage s = SettingsStore.load();
        s.dropPerCreditBps = type(uint16).max;
        s.dropFloorBps = type(uint16).max;
        s.climbPerMinBps = type(uint16).max;
        s.ceilBps = type(uint16).max;
        s.idleLoosenBps = type(uint16).max;
        s.saleFloorBps = type(uint16).max;
        s.saleToBuybackBps = type(uint16).max;
        s.recoveryClimbPerMinBps = type(uint16).max;
        s.recoveryGapBps = type(uint16).max;
        s.peakHalfLife = type(uint32).max;
        s.buybackDelay = type(uint16).max;
        s.balanceMode = type(uint8).max;
        s.redeemSlippageBps = type(uint16).max;
        s.balanceBidMarginBps = type(uint16).max;
        s.redeemBurnBps = type(uint16).max;
        s.buybackSlice = type(uint128).max;
        s.keeperFee = type(uint64).max;
        s.keeperMaxBaseFee = type(uint48).max;
        s.rateCap = type(uint64).max;
        s.callerFee = type(uint64).max;
        s.callerMaxBaseFee = type(uint48).max;
        s.feeToBuybackBps = type(uint16).max;
        s.feeToRedeemBurnBps = type(uint16).max;
    }

    function words() external view returns (uint256 a, uint256 b, uint256 c) {
        bytes32 slot = SettingsStore.SLOT;
        assembly {
            a := sload(slot)
            b := sload(add(slot, 1))
            c := sload(add(slot, 2))
        }
    }
}

/// @notice review of the balance side after the per point rebuild: the module is replaceable, a hostile module
/// cannot re enter any door, a module that flips its reported token only bricks itself, the per point bid takes one
/// unit across a set with minOut protection, and the settings pack into three words
contract ReviewPhase2FlexTest is Fixture {
    using FixedPointMathLib for uint256;

    function _mod(uint256 unit) internal returns (MockBalanceModule) {
        return new MockBalanceModule(address(xt), unit);
    }

    function _replace(address m) internal {
        _setBalanceModule(m);
    }

    function _potX(uint256 amount) internal {
        xt.mint(address(core), amount);
        core.skim();
    }

    function _bid(uint256 id, uint256 unit) internal view returns (uint256) {
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        return score * unit * (10_000 - core.settings().balanceBidMarginBps) / 10_000;
    }

    /// a hostile module cannot re enter any door from its redeem callback, and the redemption books exactly what arrived
    function test_OK_hostileModuleCannotReenterAnyDoor() public {
        _enterPhase2();
        ReenteringModule rm = new ReenteringModule(address(xt), UNIT, address(core));
        _replace(address(rm));
        assertTrue(rm.skimOutside(), "control: the same skim works outside a callback");
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        uint256 before = xt.balanceOf(address(core));
        core.redeemStatement(sid);
        assertGe(rm.attempts(), 13, "tried every door");
        assertEq(rm.succeeded(), 0, "none got through");
        assertFalse(rm.skimInside(), "the guard refused skim inside the callback");
        assertGt(xt.balanceOf(address(core)), before, "the redemption booked the received token");
        assertEq(core.balancePot(), xt.balanceOf(address(core)), "all the core's balance token is in the bid pot");
        _solvent();
    }

    /// a module that reports another balance token after it was set cannot move the core's token: its redemptions come back
    /// Underpaid, the same address cannot be set again, and a good module replaces it
    function test_OK_moduleThatChangesItsReportedTokenOnlyBricksItself() public {
        _enterPhase2();
        FlipModule fm = new FlipModule(address(xt), UNIT);
        _replace(address(fm));
        MockBalanceToken other = new MockBalanceToken("O", "O");
        fm.setToken(address(other));
        assertEq(core.balanceToken(), address(xt), "the core kept its own copy");
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.expectRevert(ICore.Underpaid.selector);
        core.redeemStatement(sid);
        vm.prank(owner);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(fm));
        // a unit change reported later is ignored until a set reads it
        fm.setToken(address(xt));
        fm.setUnit(5 * UNIT);
        assertEq(core.unitPerPoint(), UNIT);
        _replace(address(_mod(UNIT)));
        core.redeemStatement(sid);
        _solvent();
    }

    /// a seller in the block of the set is paid by one unit; minOut in balance token units protects a seller who quoted the
    /// old unit from a drop to a lower new unit
    function test_OK_sellInTheBlockOfTheSetUsesOneUnitAndMinOutProtects() public {
        _enterPhase2();
        _setBalancePool();
        _potX(5e21);
        uint256[] memory ids = _credits(seller, 1);
        uint256 quoteOld = _bid(ids[0], UNIT);
        // the owner drops the unit in the same block, then the seller sells with a floor from the old quote
        _replace(address(_mod(UNIT / 10)));
        uint256[] memory withFloor = ids;
        vm.prank(seller);
        vm.expectRevert(ICore.Slippage.selector);
        core.sellForBalance(withFloor, quoteOld);
        // without the floor the sale goes through at the new unit
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(seller) - before, _bid(ids[0], UNIT / 10), "paid by the new unit");
        _solvent();
    }

    /// after a replacement the old module may be an adapter and the new one may not, and the stack members and non
    /// contracts are refused as modules
    function test_OK_forbiddenSetsAndStackMembersAfterAReplacement() public {
        _enterPhase2();
        MockBalanceModule m2 = _mod(2 * UNIT);
        _replace(address(m2));
        _approveAdapter(address(mod));
        assertTrue(core.allowedAdapter(address(mod)));
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addAdapter(address(m2));
        // a non contract is never a module
        vm.expectRevert(ICore.BadModule.selector);
        core.setBalanceModule(address(0x1234));
        // a module whose balance token is a stack member keeps the same token first, so the token change is caught
        MockBalanceModule alien = new MockBalanceModule(Mainnet.CREDITS, UNIT);
        vm.expectRevert(ICore.BalanceTokenChanged.selector);
        core.setBalanceModule(address(alien));
        vm.stopPrank();
    }

    /// the settings pack into three storage words: every field at its type max reads back at its type max
    function test_OK_packingEveryFieldAtTypeMaxRoundTrips() public {
        PackHarness h = new PackHarness();
        h.maxAll();
        (uint256 a, uint256 b, uint256 c) = h.words();
        // slot 0
        assertEq(uint16(a), type(uint16).max, "dropPerCreditBps");
        assertEq(uint16(a >> 16), type(uint16).max, "dropFloorBps");
        assertEq(uint16(a >> 32), type(uint16).max, "climbPerMinBps");
        assertEq(uint16(a >> 48), type(uint16).max, "ceilBps");
        assertEq(uint16(a >> 64), type(uint16).max, "idleLoosenBps");
        assertEq(uint16(a >> 80), type(uint16).max, "saleFloorBps");
        assertEq(uint16(a >> 96), type(uint16).max, "saleToBuybackBps");
        assertEq(uint16(a >> 112), type(uint16).max, "recoveryClimbPerMinBps");
        assertEq(uint16(a >> 128), type(uint16).max, "recoveryGapBps");
        assertEq(uint32(a >> 144), type(uint32).max, "peakHalfLife");
        assertEq(uint16(a >> 176), type(uint16).max, "buybackDelay");
        assertEq(uint8(a >> 192), type(uint8).max, "balanceMode");
        assertEq(uint16(a >> 200), type(uint16).max, "redeemSlippageBps");
        assertEq(uint16(a >> 216), type(uint16).max, "balanceBidMarginBps");
        assertEq(uint16(a >> 232), type(uint16).max, "redeemBurnBps");
        // slot 1
        assertEq(uint128(b), type(uint128).max, "buybackSlice");
        assertEq(uint64(b >> 128), type(uint64).max, "keeperFee");
        assertEq(uint48(b >> 192), type(uint48).max, "keeperMaxBaseFee");
        // slot 2
        assertEq(uint64(c), type(uint64).max, "rateCap");
        assertEq(uint64(c >> 64), type(uint64).max, "callerFee");
        assertEq(uint48(c >> 128), type(uint48).max, "callerMaxBaseFee");
        assertEq(uint16(c >> 176), type(uint16).max, "feeToBuybackBps");
        assertEq(uint16(c >> 192), type(uint16).max, "feeToRedeemBurnBps");
        // nothing above bit 208 of slot 2
        assertEq(c >> 208, 0, "no field above feeToRedeemBurnBps");
    }

    /// nothing of the core's eth or balance token moves when the owner replaces the module
    function test_OK_nothingUnbookedAroundSets() public {
        _enterPhase2();
        _composeOnce();
        _potX(2e19);
        uint256 bal = address(core).balance;
        uint256 xbal = xt.balanceOf(address(core));
        uint256 ep = core.ethPot();
        uint256 eb = core.ethToBuyback();
        uint256 reserve = core.ethRedeemBurn();
        uint256 xp = core.balancePot();
        _replace(address(_mod(2 * UNIT)));
        assertEq(address(core).balance, bal);
        assertEq(xt.balanceOf(address(core)), xbal);
        assertEq(core.ethPot(), ep);
        assertEq(core.ethToBuyback(), eb);
        assertEq(core.ethRedeemBurn(), reserve);
        assertEq(core.balancePot(), xp);
        _solvent();
    }
}
