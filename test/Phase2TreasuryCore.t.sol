// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
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

/// the phase 2 treasury behind the real Core, Statements and the restricted coin on the pinned fork, with the standin
/// balance token carrying the upstream gates
contract Phase2TreasuryCoreTest is Fixture {
    Phase2BalanceTokenStandin internal token;
    ITreasury internal t;
    address internal policyAddr;

    function setUp() public override {
        super.setUp();
        token = new Phase2BalanceTokenStandin();
        policyAddr = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), address(token), policyAddr, address(0))
            )
        );
    }

    function _select() internal {
        _setBalanceModule(address(t));
        assertEq(core.balanceModule(), address(t));
        assertEq(core.balanceToken(), address(token));
        assertTrue(t.selected());
    }

    /// a statement the Core holds and the controller finds eligible
    function _eligibleStatement() internal returns (uint256 sid) {
        sid = _composeOnce().sid;
        _makeEligible(sid);
        assertTrue(ctl.atFloor(sid));
    }

    /// a further page composed after `_composeOnce`, which memoizes its statement
    function _composeAnother() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
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

    // promise: SPEC phase 2 the Core's physical receipt check passes with the 300 bps claim earmark kept inside the treasury, before transfers open
    function test_coreReceiptCheckPassesWithInternalEarmark() public {
        _select();
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
        assertEq(t.claimReserve(), rating * 1e14 * 300 / 10_000);
        assertEq(t.working(), rating * 1e14 - t.claimReserve());
        assertEq(STATEMENTS.ownerOf(sid), address(token), "the token took the statement");
        assertFalse(_isHeld(sid));
        assertEq(t.available(), 0, "still nothing available while transfers are closed");
    }

    // promise: SPEC phase 2 a short conversion receipt reverts the whole Core redemption and the statement stays held
    function test_shortReceiptRevertsTheCoreRedemption() public {
        _select();
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
        _select();
        token.open();
        token.mint(address(t), 1_040 ether);
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
        assertEq(core.balanceBidOf(ids[0]), _scoreOf(ids[0]) * 1e14 * 9_000 / 10_000, "the posted 90 percent bid");
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(token.balanceOf(seller), posted, "the seller got the whole posted payout");
        assertEq(token.balanceOf(creator), royalty, "the artist royalty on top");
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
        _select();
        token.open();
        token.mint(address(t), 140 ether);
        vm.startPrank(owner);
        t.setSwitches(true, true, true);
        t.allocateToClaims(40 ether);
        vm.stopPrank();
        address arb = _user("arb");
        uint256 got = _buyCoin(arb, 1 ether);
        assertGt(got, 0);
        assertTrue(coin.restricted(), "the fixture coin is restricted");
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
        assertEq(token.balanceOf(arb), share);
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
    function test_debtSurvivesReplacementAndPauseDoesNotBlockConversion() public {
        _select();
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
        _select();
        uint256 sid = _composeOnce().sid;
        uint256 cost;
        (, cost,) = core.statementInfo(sid);
        IControllerV2Core v2 = _deployV2();
        _setController(address(v2));
        assertEq(core.controller(), address(v2));
        assertEq(v2.creditWindow(), ctl.creditWindow(), "the credit window carried over");
        assertEq(v2.markupBps(), 30_000);
        assertEq(v2.decayHours(), 1);
        // age only eligibility from the Core's recorded age, pause adjusted
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
        // a conversion through the treasury under the V2 eligibility
        token.setGates(true, 0, 0);
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
