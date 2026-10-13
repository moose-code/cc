// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoreLens} from "../src/interfaces/ICoreLens.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// `CoreLens` on the fork: the real Core, controller, Credits and Statements. every field of `snapshot` is compared
/// with the direct reads on a populated system, and the pending income with an actual book
contract LensTest is Fixture {
    uint256 internal sidFirst;
    uint256 internal sidSecond;
    uint256 internal sidBalanceBid;

    function _composedStatement() internal returns (uint256 sid) {
        _fillEthPile(80);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    /// a statement composed from credits bought through the balance token bid. one pile, so it is a normal statement
    function _balanceBidStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.bookBalance();
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    // promise: INTEGRATION NotReady: the lens and compose agree on a short nextPage answer
    /// the lens requires the answer size of `nextPage` that the Core requires, so both agree on a short answer
    function test_OK_aShortNextPageAnswerIsNotReadyForTheLensAndForCompose() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(0, 80);
        assertTrue(lens.snapshot().pageReady, "the real controller answers ready");
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1)));
        assertFalse(lens.snapshot().pageReady, "one word is a short answer");
        vm.expectRevert(ICore.NotReady.selector);
        vm.prank(keeper);
        core.compose();
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1), ids, uint256(0)));
        assertTrue(lens.snapshot().pageReady, "the full size answer is ready");
        vm.clearMockedCalls();
    }

    // promise: INTEGRATION creditPriceOf answers under a gas burning module
    /// the lens forwards enough gas for the controller's two bounded module reads, so a module that burns most of the
    /// read budget in unitPerPoint gives the same creditPrice through the lens as a direct controller read
    function test_OK_creditPriceThroughTheLensSurvivesAGasBurningModule() public {
        _enterPhase2();
        _setBalancePool();
        uint256[] memory ids = _fillEthPile(1);
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        mod.setBurnUnitGas(190_000);
        uint256 direct = ctl.creditPrice(ids[0]);
        assertGt(direct, 0, "the controller prices the credit");
        assertEq(lens.creditPriceOf(ids[0]), direct, "the lens answer equals the controller through a gas burning module");
    }

}
