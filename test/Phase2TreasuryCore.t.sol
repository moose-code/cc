// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CreditSale, Quote, Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {ITreasury} from "./Phase2Treasury.t.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// the ControllerV2 surface this file drives, restated so the test compiles without via_ir
interface IControllerV2Core {
    error StatementSalesOff();
    error BadSetting(bytes32 field);

    function atFloor(uint256 sid) external view returns (bool);
    function priceOf(uint256 sid) external view returns (uint256);
    function referenceOf(uint256 sid) external view returns (uint256);
    function buy(uint256 sid) external payable;
    function setStatementSales(bool enabled) external;
    function setStatementSaleMultiplierBps(uint32 v) external;
    function setStatementRedeemDelaySeconds(uint32 v) external;
    function statementSaleMultiplierBps() external view returns (uint32);
    function statementRedeemDelaySeconds() external view returns (uint32);
    function markupBps() external view returns (uint16);
    function decayHours() external view returns (uint16);
    function creditWindow() external view returns (uint32);
    function pastWindow(uint64 acquiredAt) external view returns (bool);
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format);
}

/// the phase 2 treasury behind the live Core, Statements and the restricted coin on the pinned fork. the happy path
/// tests run against the live BALANCE token (funded by a real holder transfer, the ink rule); the three tests that need
/// behavior the live token cannot show (a closed transfer gate, a short receipt, a refused artist transfer) keep the
/// stand in, bound to the same live Core. the stand in still reads the live Statements for its quote
contract Phase2TreasuryCoreTest is LiveFixture {
    Phase2BalanceTokenStandin internal token;
    ITreasury internal t;
    address internal policyAddr;

    function setUp() public override {
        super.setUp();
        policyAddr = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
    }

    /// @dev a fresh treasury bound to the live Core for the given balance token
    function _deployTreasury(address tokenAddr) internal returns (ITreasury) {
        return ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), tokenAddr, policyAddr, address(0))
            )
        );
    }

    /// @dev the live BALANCE token treasury, selected on the Core
    function _useLive() internal {
        t = _deployTreasury(liveBalanceToken);
        _select();
    }

    /// @dev a stand in token treasury, for the gates and fault modes the live token cannot present
    function _useStandin() internal {
        token = new Phase2BalanceTokenStandin();
        t = _deployTreasury(address(token));
        _select();
    }

    function _select() internal {
        _setBalanceModule(address(t));
        assertEq(core.balanceModule(), address(t));
        assertEq(core.balanceToken(), t.balanceToken());
        assertTrue(t.selected());
    }

    /// a statement the live Core already holds and the live controller finds eligible (atFloor). the live Core holds a
    /// steady set of these at the pin, so no compose or warp is needed
    function _eligibleStatement() internal view returns (uint256 sid) {
        sid = _eligibleHeldStatement();
        assertTrue(ctl.atFloor(sid));
    }

    /// held inventory for the statement sale steps: the live Core already holds real Statements, which only need to
    /// exist to be sold or priced (no fresh age), so draw distinct ones from its held set rather than composing more
    /// heavy pages. this is the held inventory the promise is about
    uint256[] internal _heldPool;
    uint256 internal _heldIdx;

    function _composeAnother() internal returns (uint256 sid) {
        if (_heldPool.length == 0) _heldPool = core.heldStatements();
        while (_heldIdx < _heldPool.length) {
            uint256 s = _heldPool[_heldIdx++];
            if (_isHeld(s)) return s;
        }
        revert("no held Statement left for the sale steps");
    }

    function _deployV2() internal returns (IControllerV2Core v2) {
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: ctl.creditSpreadBps(),
            startBps: ctl.creditStartBps()
        });
        Quote memory none;
        v2 = IControllerV2Core(
            vm.deployCode(
                "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(30_000), uint32(3_600))
            )
        );
    }

    // promise: SPEC phase 2 the Core's physical receipt check passes with the 1,000 bps claim earmark kept inside the treasury, before transfers open
    // kept on the stand in: the live token's transfers are already open, so the "before transfers open" gate (custody
    // held, available still zero) cannot be shown against it
    function test_coreReceiptCheckPassesWithInternalEarmark() public {
        _useStandin();
        assertEq(t.available(), 0, "nothing available before the switches and the gates");
        uint256 sid = _eligibleStatement();
        uint256 rating = core.ratingOf(sid);
        token.setGates(true, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(ITreasury.ConversionOff.selector);
        core.redeemStatement(sid);
        vm.prank(owner);
        t.setSwitches(true, false, false);
        assertTrue(t.conversionReady());
        assertFalse(t.transfersReady());
        vm.expectEmit(address(core));
        emit ICore.StatementRedeemed(sid, rating * 1e14);
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(t.custody(), rating * 1e14, "every token stays in the treasury");
        assertEq(t.claimReserve(), rating * 1e14 * 1_000 / 10_000);
        assertEq(t.working(), rating * 1e14 - t.claimReserve());
        assertEq(STATEMENTS.ownerOf(sid), address(token), "the token took the statement");
        assertFalse(_isHeld(sid));
        assertEq(t.available(), 0, "still nothing available while transfers are closed");
    }

    // promise: SPEC phase 2 a short conversion receipt reverts the whole Core redemption and the statement stays held
    // kept on the stand in: the receipt shortfall is injected with setShortfall, which the live token cannot do
    function test_shortReceiptRevertsTheCoreRedemption() public {
        _useStandin();
        uint256 sid = _eligibleStatement();
        token.setGates(true, 0, 0);
        vm.prank(owner);
        t.setSwitches(true, false, false);
        token.setShortfall(1);
        vm.prank(keeper);
        vm.expectRevert(ITreasury.RedeemedBelowRating.selector);
        core.redeemStatement(sid);
        assertTrue(_isHeld(sid));
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(t.custody(), 0);
    }

    // promise: SPEC phase 2 the balance bid pays sellers and the artist from working funds above the floor; the claim reserve is never spent
    function test_balanceBidSpendsWorkingFundsOnly() public {
        _useLive();
        // route the artist royalty to a fresh account so its payout is read cleanly on the live token
        _setArtist(creator);
        // the live token transfers are open at the pin; fund the treasury by a real holder transfer (the ink rule)
        _fundBalance(address(t), 1_040 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, false);
        t.allocateToClaims(40 ether);
        vm.stopPrank();
        _setSwitches(true, true);
        assertEq(t.available(), 1_000 ether, "working funds, not the claims");
        uint256[] memory ids = _credits(seller, 2);
        uint256 posted;
        for (uint256 i; i < 2; ++i) {
            posted += _scoreOf(ids[i]) * 1e14 * (10_000 - core.settings().balanceDiscountBps) / 10_000;
        }
        uint256 royalty = posted * core.settings().buyToArtistBps / 10_000;
        assertEq(
            core.balanceBidOf(ids[0]),
            _scoreOf(ids[0]) * 1e14 * (10_000 - core.settings().balanceDiscountBps) / 10_000,
            "the posted bid is the live payout share of rating"
        );
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(_balanceOf(seller), posted, "the seller got the whole posted payout");
        assertEq(_balanceOf(creator), royalty, "the artist royalty on top");
        assertEq(t.claimReserve(), 40 ether, "claims untouched");
        assertEq(t.custody(), 1_040 ether - posted - royalty);
        assertEq(t.available(), 1_000 ether - posted - royalty);
        assertTrue(t.solvent());
        // the floor closes the bid: the Core reads zero available and refuses the batch
        vm.prank(owner);
        t.setMinimumWorkingBalance(1_000 ether);
        assertEq(t.available(), 0);
        assertEq(core.balanceBidOf(ids[0]), 0, "the view shows no payout");
        uint256[] memory more = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(bytes4(keccak256("PotTooSmall()")));
        core.sellForBalance(more);
        // the claim reserve cannot cover a sale: working funds below the payout refuse it even though custody could pay
        vm.prank(owner);
        t.setMinimumWorkingBalance(0);
        uint256 nearlyAll = t.freeWorking() - 1;
        vm.prank(owner);
        t.allocateToClaims(nearlyAll);
        assertGt(t.custody(), _scoreOf(more[0]) * 1e14, "custody could pay but the claims are not spendable");
        vm.prank(seller);
        vm.expectRevert(bytes4(keccak256("PotTooSmall()")));
        core.sellForBalance(more);
    }

    // promise: SPEC phase 2 CC bought through the canonical hook route burns through `burnFrom` on the restricted coin and pays the proportional share
    function test_redeemCCBurnsRestrictedCoinFromTheHookRoute() public {
        _useLive();
        _fundBalance(address(t), 140 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, true);
        t.allocateToClaims(40 ether);
        vm.stopPrank();
        address arb = _user("arb");
        uint256 got = _buyCoin(arb, 1 ether);
        assertGt(got, 0);
        assertTrue(coin.restricted(), "the live coin is restricted");
        uint256 supply = coin.totalSupply();
        uint256 x = got / 2;
        uint256 share = FullMath.mulDiv(x, 40 ether, supply);
        (uint256 q,,,, bool exec) = t.quoteRedemption(x);
        assertEq(q, share);
        assertTrue(exec);
        uint64 epoch = t.configEpoch();
        vm.startPrank(arb);
        coin.approve(address(t), x);
        uint256 out = t.redeemCC(x, arb, share, block.timestamp, epoch);
        vm.stopPrank();
        assertEq(out, share);
        assertEq(_balanceOf(arb), share);
        assertEq(coin.totalSupply(), supply - x, "the supply fell by exactly the burn");
        assertEq(coin.balanceOf(arb), got - x);
        assertEq(t.claimReserve(), 40 ether - share);
        assertEq(t.working(), 100 ether, "working funds untouched by a burn");
        assertEq(t.available(), 100 ether);
        // without an allowance the burn is refused and nothing moves
        vm.prank(arb);
        vm.expectRevert();
        t.redeemCC(x, arb, 0, block.timestamp, epoch);
        assertEq(coin.totalSupply(), supply - x);
    }

    // promise: SPEC phase 2 artist debt survives a module replacement through the real Core, and the Core pause stops the balance bid but not a conversion through the treasury
    // kept on the stand in: the debt is forced by a refused artist transfer (setBanned), which the live token cannot do
    function test_debtSurvivesReplacementAndPauseDoesNotBlockConversion() public {
        _useStandin();
        // route the artist royalty to a fresh account the stand in can then refuse, forcing the royalty into debt
        _setArtist(creator);
        token.open();
        token.mint(address(t), 1_040 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, false);
        t.allocateToClaims(40 ether);
        vm.stopPrank();
        _setSwitches(true, true);
        // the artist royalty transfer fails: the Core's bounded call records debt in the treasury
        token.setBanned(creator);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 debt = t.owed(creator);
        assertGt(debt, 0, "the royalty became debt");
        token.setBanned(address(0));
        // a replacement treasury takes over the Core; the old one keeps paying its debt
        ITreasury next = ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), address(token), policyAddr, address(0))
            )
        );
        _setBalanceModule(address(next));
        assertFalse(t.selected());
        assertEq(t.available(), 0);
        assertEq(t.claim(creator), debt);
        assertEq(token.balanceOf(creator), debt);
        // the Core pause: the balance bid stops, a conversion through the new treasury does not
        vm.prank(owner);
        next.setSwitches(true, false, false);
        uint256 sid = _eligibleStatement();
        uint256 rating = core.ratingOf(sid);
        vm.prank(owner);
        core.setPaused(true);
        uint256[] memory more = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForBalance(more);
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(next.custody(), rating * 1e14, "converted while paused");
        assertFalse(_isHeld(sid));
    }

    // promise: SPEC phase 2 ControllerV2 replaces the live controller with held inventory: the Core's probes answer, eligibility is age only and the ask is the persistent multiple
    function test_controllerV2SelectsWithHeldInventory() public {
        _useLive();
        // the live Core already holds real Statements: use its held inventory, the subject of this promise
        uint256 sid = core.heldStatements()[0];
        uint256 cost;
        (, cost,) = core.statementInfo(sid);
        IControllerV2Core v2 = _deployV2();
        _setController(address(v2));
        assertEq(core.controller(), address(v2));
        assertEq(v2.creditWindow(), ctl.creditWindow(), "the credit window carried over");
        assertEq(v2.markupBps(), 30_000);
        assertEq(v2.decayHours(), 1);
        // age only eligibility (the subject): with the constructor delay a held Statement is already eligible, so set
        // the delay one hour past its recorded age (pause adjusted) to drive the transition at the hour
        uint32 delay = uint32(core.statementAge(sid) + 3600);
        vm.prank(owner);
        v2.setStatementRedeemDelaySeconds(delay);
        assertFalse(v2.atFloor(sid));
        _warp(3_599);
        assertFalse(v2.atFloor(sid));
        _warp(1);
        assertTrue(v2.atFloor(sid));
        // the ask is the persistent multiple of the reference, never under the Core's cost floor, and does not decay
        uint256 ref = v2.referenceOf(sid);
        uint256 ask = FullMath.mulDivRoundingUp(ref, 30_000, 10_000);
        if (ask < cost * core.settings().saleFloorBps / 10_000) ask = cost * core.settings().saleFloorBps / 10_000;
        assertEq(v2.priceOf(sid), ask);
        // the mode off reference follows the idle eth bid; the multiple over it never decays
        _warp(2 days);
        assertEq(v2.priceOf(sid), FullMath.mulDivRoundingUp(v2.referenceOf(sid), 30_000, 10_000), "no decay");
        assertGe(v2.priceOf(sid), ask, "the ask did not fall");
        assertTrue(v2.atFloor(sid), "still eligible");
        // sales off refuses a purchase while redemption stays eligible
        address buyer = _user("buyer");
        vm.deal(buyer, ask);
        vm.prank(buyer);
        vm.expectRevert(IControllerV2Core.StatementSalesOff.selector);
        v2.buy{value: ask}(sid);
        // a conversion through the treasury under the V2 eligibility (live token transfers are open at the pin)
        vm.prank(owner);
        t.setSwitches(true, false, false);
        uint256 rating = core.ratingOf(sid);
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(t.custody(), rating * 1e14);
        // another statement sells at the multiple once sales are on
        uint256 sid2 = _composeAnother();
        vm.prank(owner);
        v2.setStatementSales(true);
        uint256 price = v2.priceOf(sid2);
        vm.deal(buyer, price);
        vm.prank(buyer);
        v2.buy{value: price}(sid2);
        assertEq(STATEMENTS.ownerOf(sid2), buyer);
        // bounds and immediate effect of the two settings
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IControllerV2Core.BadSetting.selector, bytes32("statementSaleMultiplierBps"))
        );
        v2.setStatementSaleMultiplierBps(9_999);
        uint256 sid3 = _composeAnother();
        vm.prank(owner);
        v2.setStatementRedeemDelaySeconds(0);
        assertTrue(v2.atFloor(sid3), "a zero delay is eligible at once");
        vm.prank(owner);
        v2.setStatementSaleMultiplierBps(10_000);
        (, uint256 cost3,) = core.statementInfo(sid3);
        uint256 floor3 = cost3 * core.settings().saleFloorBps / 10_000;
        uint256 ref3 = v2.referenceOf(sid3);
        assertEq(
            v2.priceOf(sid3), ref3 > floor3 ? ref3 : floor3, "a 1x multiple asks the reference over the cost floor"
        );
    }
}
