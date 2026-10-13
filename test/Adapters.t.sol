// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {ISeaportBasicAdapter} from "../src/interfaces/ISeaportBasicAdapter.sol";
import {ICreditStrategyAdapter} from "../src/interfaces/ICreditStrategyAdapter.sol";
import {ICreditStrategy, Mainnet} from "../src/interfaces/Interfaces.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {FaultyAdapter} from "./standins/FaultyAdapter.sol";
import {Prod} from "./utils/Prod.sol";
import {
    ISeaport,
    OrderComponents,
    AdditionalRecipient,
    BasicOrderParameters,
    BasicOrderType
} from "./utils/SeaportTypes.sol";

/// the two launch adapters read directly, and the Core door against adapters that misbehave. real Seaport, Credits and
/// CreditStrategy on the fork
contract AdaptersTest is SeaportBase {
    ISeaportBasicAdapter internal sea;

    function setUp() public override {
        super.setUp();
        sea = ISeaportBasicAdapter(seaportAdapter);
    }

    function _order(uint256 id) internal returns (BasicOrderParameters memory p) {
        OrderComponents memory c = _open(id, 1 ether, 0);
        p = abi.decode(_basicData(c), (BasicOrderParameters));
    }

    function _price(uint256 id, BasicOrderParameters memory p) internal view returns (address, uint256, bytes memory) {
        return sea.price(id, abi.encode(p));
    }

    function _priceExt(uint256 id, BasicOrderParameters memory p) external view returns (address, uint256, bytes memory) {
        return _price(id, p);
    }

    /*//////////////////////////////////////////////////////////////
                         SeaportBasicAdapter
    //////////////////////////////////////////////////////////////*/

    function test_seaport_pointsAtTheCoreAndTheLaunchAllowlist() public view {
        assertEq(sea.CORE(), address(core));
        assertEq(sea.SEAPORT(), Mainnet.SEAPORT);
        assertEq(sea.CREDITS(), Mainnet.CREDITS);
        assertTrue(sea.allowedRecipient(Mainnet.OPENSEA_FEE_COLLECTOR));
        assertFalse(sea.allowedRecipient(keeper));
    }

    function test_seaport_valueIsTheSumOfEveryPayoutAndTheCallIsTheOrder() public {
        uint256 id = _list();
        OrderComponents memory c = _open(id, 0.9 ether, 0.03 ether);
        c.consideration[1].recipient = payable(Mainnet.OPENSEA_FEE_COLLECTOR);
        BasicOrderParameters memory p = abi.decode(_basicData(c), (BasicOrderParameters));
        (address target, uint256 value, bytes memory data) = _price(id, p);
        assertEq(target, Mainnet.SEAPORT);
        assertEq(value, 0.93 ether, "the seller part plus the fee collector part");
        assertEq(data, abi.encodeCall(ISeaport.fulfillBasicOrder_efficient_6GL6yc, (p)));
    }

    function test_seaport_acceptsAnAllowlistedRecipientAndRefusesOthers() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.additionalRecipients = new AdditionalRecipient[](1);
        p.additionalRecipients[0] = AdditionalRecipient(5, payable(Mainnet.OPENSEA_FEE_COLLECTOR));
        (, uint256 value,) = _price(id, p);
        assertEq(value, 1 ether + 5);

        p.additionalRecipients[0] = AdditionalRecipient(5, payable(keeper));
        vm.expectRevert(abi.encodeWithSelector(ISeaportBasicAdapter.RecipientNotAllowed.selector, keeper));
        this._priceExt(id, p);

        // the offerer needs no entry, as the order's own payee or as an additional recipient
        p.additionalRecipients[0] = AdditionalRecipient(5, p.offerer);
        _price(id, p);
        p.additionalRecipients = new AdditionalRecipient[](0);
        _price(id, p);
    }

    function test_seaport_refusesAWrongToken() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.offerToken = Mainnet.STATEMENTS;
        vm.expectRevert(ISeaportBasicAdapter.WrongToken.selector);
        this._priceExt(id, p);
    }

    function test_seaport_refusesAWrongId() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        vm.expectRevert(ISeaportBasicAdapter.WrongId.selector);
        this._priceExt(id + 1, p);
    }

    function test_seaport_refusesAWrongAmount() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.offerAmount = 2;
        vm.expectRevert(ISeaportBasicAdapter.WrongAmount.selector);
        this._priceExt(id, p);
    }

    function test_seaport_refusesANonNativeConsideration() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.considerationToken = address(coin);
        vm.expectRevert(ISeaportBasicAdapter.NotNative.selector);
        this._priceExt(id, p);
    }

    function test_seaport_refusesAZeroPrice() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.considerationAmount = 0;
        vm.expectRevert(ISeaportBasicAdapter.ZeroPrice.selector);
        this._priceExt(id, p);
    }

    function test_seaport_refusesTheRestrictedRoutes() public {
        uint256 id = _list();
        BasicOrderParameters memory p = _order(id);
        p.basicOrderType = BasicOrderType.ETH_TO_ERC721_FULL_RESTRICTED;
        vm.expectRevert(ISeaportBasicAdapter.RestrictedOrder.selector);
        this._priceExt(id, p);
        p.basicOrderType = BasicOrderType.ETH_TO_ERC721_PARTIAL_RESTRICTED;
        vm.expectRevert(ISeaportBasicAdapter.RestrictedOrder.selector);
        this._priceExt(id, p);
        p.basicOrderType = BasicOrderType.ETH_TO_ERC721_PARTIAL_OPEN;
        _price(id, p);
    }

    function test_seaport_allowlistIsTheCoreOwners() public {
        vm.prank(keeper);
        vm.expectRevert(ISeaportBasicAdapter.OnlyCoreOwner.selector);
        sea.setAllowedRecipient(keeper, true);

        vm.expectEmit(address(sea));
        emit ISeaportBasicAdapter.RecipientSet(keeper, true);
        vm.prank(owner);
        sea.setAllowedRecipient(keeper, true);
        assertTrue(sea.allowedRecipient(keeper));

        vm.prank(owner);
        sea.setAllowedRecipient(keeper, false);
        assertFalse(sea.allowedRecipient(keeper));

        // after a handover the new owner holds the power
        vm.prank(owner);
        core.transferOwnership(keeper);
        vm.prank(keeper);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ISeaportBasicAdapter.OnlyCoreOwner.selector);
        sea.setAllowedRecipient(owner, true);
        vm.prank(keeper);
        sea.setAllowedRecipient(owner, true);
    }

    /*//////////////////////////////////////////////////////////////
                         CreditStrategyAdapter
    //////////////////////////////////////////////////////////////*/

    function test_strategy_readsNftForSale() public view {
        ICreditStrategyAdapter a = ICreditStrategyAdapter(strategyAdapter);
        assertEq(a.STRATEGY(), STRATEGY);
        (address target, uint256 value, bytes memory data) = a.price(LISTED_A, "");
        assertEq(target, STRATEGY);
        assertEq(value, ICreditStrategy(STRATEGY).nftForSale(LISTED_A));
        assertEq(value, 0.036 ether);
        assertEq(data, abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A)));
    }

    function test_strategy_refusesACreditThatIsNotForSale() public {
        uint256 unlisted = 999_999_999;
        assertEq(ICreditStrategy(STRATEGY).nftForSale(unlisted), 0);
        vm.expectRevert(ICreditStrategyAdapter.NotForSale.selector);
        ICreditStrategyAdapter(strategyAdapter).price(unlisted, "");
    }

    function test_strategy_buyThroughTheCore() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fundPot(10 ether);
        _warpUntilCeiling(LISTED_A, price);
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        // sold: the adapter no longer quotes it
        vm.prank(keeper);
        vm.expectRevert(ICore.AlreadyOwned.selector);
        core.buyListing(strategyAdapter, LISTED_A, "");
    }

    /*//////////////////////////////////////////////////////////////
                              the Core
    //////////////////////////////////////////////////////////////*/

    function test_core_addAdapterRefusesAForbiddenAddress() public {
        address[7] memory bad = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            core.HOOK(),
            Mainnet.PERMIT2,
            Mainnet.UNIVERSAL_ROUTER
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addAdapter(bad[i]);
        }
    }

    function test_core_lockAdaptersIsOneWay() public {
        address fresh = address(new FaultyAdapter());
        vm.prank(owner);
        core.lockAdapters();
        assertTrue(core.adaptersLocked());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("adapters")));
        core.addAdapter(fresh);
        // there is no unlock, a second lock changes nothing, and a removal still works
        vm.prank(owner);
        core.lockAdapters();
        assertTrue(core.adaptersLocked());
        // the lock also freezes who a sweep can pay: adding a recipient reverts, removing works
        vm.prank(owner);
        vm.expectRevert(ISeaportBasicAdapter.Locked.selector);
        sea.setAllowedRecipient(keeper, true);
        vm.prank(owner);
        sea.setAllowedRecipient(Mainnet.OPENSEA_FEE_COLLECTOR, false);
        assertFalse(sea.allowedRecipient(Mainnet.OPENSEA_FEE_COLLECTOR));
        vm.prank(owner);
        core.removeAdapter(seaportAdapter);
        assertFalse(core.allowedAdapter(seaportAdapter));
        assertTrue(core.adaptersLocked());
    }

    function test_core_constructorRefusesAZeroOrForbiddenAdapter() public {
        address[] memory zero = new address[](1);
        vm.expectRevert(ICore.ZeroAddress.selector);
        Prod.newCore(
            owner, buildConfig(lc, owner, address(0)), owner, address(ctl), lc.payee, lc.stack, lc.rateStart, lc.settings, lc.credit, zero
        );

        address[] memory forbidden = new address[](2);
        forbidden[0] = seaportAdapter;
        forbidden[1] = address(CREDITS);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        Prod.newCore(
            owner,
            buildConfig(lc, owner, address(0)),
            owner,
            address(ctl),
            lc.payee,
            lc.stack,
            lc.rateStart,
            lc.settings,
            lc.credit,
            forbidden
        );
    }

    function test_core_unapprovedAdapterReverts() public {
        _fundPot(1 ether);
        address stranger = address(new FaultyAdapter());
        vm.prank(keeper);
        vm.expectRevert(ICore.AdapterNotAllowed.selector);
        core.buyListing(stranger, LISTED_A, "");
    }

    function test_core_adapterThatQuotesAForbiddenTargetReverts() public {
        _fundPot(1 ether);
        address[4] memory bad = [address(CREDITS), address(STATEMENTS), address(core), core.ESCROW()];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(keeper);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            _buyRaw(1, "", LISTED_A, bad[i]);
        }
        FaultyAdapter f = new FaultyAdapter();
        _approveAdapter(address(f));
        f.setMode(5, address(CREDITS));
        vm.prank(keeper);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.buyListing(address(f), LISTED_A, "");
    }

    function test_core_alreadyOwnedReverts() public {
        _fundPot(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        vm.prank(keeper);
        core.buyListing(strategyAdapter, LISTED_A, "");
        vm.prank(keeper);
        vm.expectRevert(ICore.AlreadyOwned.selector);
        _buyRaw(1, "", LISTED_A, STRATEGY);
    }

    /// a revert, one word, an oversized answer, a gas overrun and a state write each end in `BadQuote`
    function test_core_aBadAnswerRevertsBadQuote() public {
        _fundPot(1 ether);
        FaultyAdapter f = new FaultyAdapter();
        _approveAdapter(address(f));
        for (uint256 m; m <= 4; ++m) {
            f.setMode(m, address(0));
            uint256 g = gasleft();
            vm.prank(keeper);
            vm.expectRevert(ICore.BadQuote.selector);
            core.buyListing(address(f), LISTED_A, "");
            // the quote read cannot take more than its gas cap with it
            assertLt(g - gasleft(), 2_000_000, "the read is capped");
        }
    }

    function test_core_zeroValueAndAboveBidAndPotRevert() public {
        _fundPot(1 ether);
        uint256 bid = core.ethRate();
        uint256 pot = core.ethPot();
        vm.startPrank(keeper);
        vm.expectRevert(ICore.ZeroAmount.selector);
        _buyRaw(0, "", LISTED_A, STRATEGY);
        vm.expectRevert(ICore.AboveBid.selector);
        _buyRaw(bid + 1, "", LISTED_A, STRATEGY);
        vm.stopPrank();
        assertLe(bid, pot);
        vm.prank(keeper);
        vm.expectRevert(ICore.PotTooSmall.selector);
        _buyRaw(pot + 1, "", LISTED_A, STRATEGY);
    }
}
