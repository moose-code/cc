// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {BidModel} from "./utils/BidModel.sol";
import {
    ISeaport,
    ItemType,
    OrderType,
    BasicOrderType,
    OfferItem,
    ConsiderationItem,
    OrderParameters,
    OrderComponents,
    Order,
    AdvancedOrder,
    CriteriaResolver,
    AdditionalRecipient,
    BasicOrderParameters,
    ZoneParameters
} from "./utils/SeaportTypes.sol";

/// a restricted order zone that accepts a fill only when the caller supplied the extra data it expects.
/// it stands in for the server signed extra data a live restricted listing needs. seaport 1.6 asks the zone twice,
/// `authorizeOrder` before the transfers and `validateOrder` after them.
contract ExtraDataZone {
    bytes public constant EXPECTED = hex"c0ffee";

    function authorizeOrder(ZoneParameters calldata p) external pure returns (bytes4) {
        require(keccak256(p.extraData) == keccak256(EXPECTED), "extra data");
        return this.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata p) external pure returns (bytes4) {
        require(keccak256(p.extraData) == keccak256(EXPECTED), "extra data");
        return this.validateOrder.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// shared plumbing: genuine Seaport 1.6 orders for credits, signed by a maker key. the maker holds a real credit,
/// approves Seaport directly on Credits (no conduit), and signs the eip 712 digest of the order hash that Seaport
/// itself computes, under the domain separator Seaport itself reports. the core is the real core of the fixture
abstract contract SeaportBase is Fixture {
    using FixedPointMathLib for uint256;

    ISeaport internal constant SEAPORT = ISeaport(Mainnet.SEAPORT);

    address internal maker;
    uint256 internal makerKey;
    address internal feeTaker;
    uint256 internal salt;

    struct Snap {
        uint256 pot;
        uint256 balance;
        uint256 toBuyback;
        uint256 rate;
        uint256 fillTime;
        uint256 pile;
        uint256 credits;
        uint256 keeper;
        uint256 maker;
        uint256 feeTaker;
    }

    function setUp() public virtual override {
        super.setUp();
        (maker, makerKey) = makeAddrAndKey("creditsengine.seaport.maker");
        feeTaker = makeAddr("creditsengine.seaport.fees");
        assertEq(maker.code.length + feeTaker.code.length, 0);
        _skipSniperWindow();
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    /// hands the next usable credit to the maker and approves Seaport itself as operator, no conduit.
    function _list() internal returns (uint256 id) {
        id = _credits(maker, 1)[0];
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        assertEq(CREDITS.ownerOf(id), maker);
        assertTrue(CREDITS.isApprovedForAll(maker, address(SEAPORT)));
    }

    function _components(uint256 id, uint256 makerAmount, uint256 feeAmount, address zone, OrderType orderType)
        internal
        returns (OrderComponents memory c)
    {
        c.offerer = maker;
        c.zone = zone;
        c.offer = new OfferItem[](1);
        c.offer[0] = OfferItem(ItemType.ERC721, address(CREDITS), id, 1, 1);
        c.consideration = new ConsiderationItem[](feeAmount == 0 ? 1 : 2);
        c.consideration[0] = ConsiderationItem(ItemType.NATIVE, address(0), 0, makerAmount, makerAmount, payable(maker));
        if (feeAmount != 0) {
            c.consideration[1] =
                ConsiderationItem(ItemType.NATIVE, address(0), 0, feeAmount, feeAmount, payable(feeTaker));
        }
        c.orderType = orderType;
        c.startTime = block.timestamp - 1;
        c.endTime = block.timestamp + 7 days;
        c.zoneHash = bytes32(0);
        c.salt = ++salt;
        c.conduitKey = bytes32(0);
        c.counter = SEAPORT.getCounter(maker);
    }

    function _open(uint256 id, uint256 makerAmount, uint256 feeAmount) internal returns (OrderComponents memory) {
        return _components(id, makerAmount, feeAmount, address(0), OrderType.FULL_OPEN);
    }

    /// the real domain separator from `information()` and the real order hash from `getOrderHash`.
    function _digest(OrderComponents memory c) internal view returns (bytes32) {
        (string memory version, bytes32 domainSeparator,) = SEAPORT.information();
        assertEq(version, "1.6");
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, SEAPORT.getOrderHash(c)));
    }

    function _sign(OrderComponents memory c, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(c));
        return abi.encodePacked(r, s, v);
    }

    function _total(OrderComponents memory c) internal pure returns (uint256 sum) {
        for (uint256 i; i < c.consideration.length; ++i) {
            sum += c.consideration[i].startAmount;
        }
    }

    function _params(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
        p = OrderParameters(
            c.offerer,
            c.zone,
            c.offer,
            c.consideration,
            c.orderType,
            c.startTime,
            c.endTime,
            c.zoneHash,
            c.salt,
            c.conduitKey,
            c.consideration.length
        );
    }

    function _basicData(OrderComponents memory c, bytes memory sig) internal pure returns (bytes memory) {
        AdditionalRecipient[] memory extra = new AdditionalRecipient[](c.consideration.length - 1);
        for (uint256 i; i < extra.length; ++i) {
            extra[i] = AdditionalRecipient(c.consideration[i + 1].startAmount, c.consideration[i + 1].recipient);
        }
        BasicOrderParameters memory b = BasicOrderParameters({
            considerationToken: address(0),
            considerationIdentifier: 0,
            considerationAmount: c.consideration[0].startAmount,
            offerer: payable(c.offerer),
            zone: c.zone,
            offerToken: c.offer[0].token,
            offerIdentifier: c.offer[0].identifierOrCriteria,
            offerAmount: 1,
            basicOrderType: BasicOrderType(uint8(c.orderType)),
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash,
            salt: c.salt,
            offererConduitKey: c.conduitKey,
            fulfillerConduitKey: bytes32(0),
            totalOriginalAdditionalRecipients: extra.length,
            additionalRecipients: extra,
            signature: sig
        });
        return abi.encodeCall(ISeaport.fulfillBasicOrder_efficient_6GL6yc, (b));
    }

    function _basicData(OrderComponents memory c) internal view returns (bytes memory) {
        return _basicData(c, _sign(c, makerKey));
    }

    /// standard path. there is no recipient argument, the credit goes to the caller.
    function _orderData(OrderComponents memory c) internal view returns (bytes memory) {
        return abi.encodeCall(ISeaport.fulfillOrder, (Order(_params(c), _sign(c, makerKey)), bytes32(0)));
    }

    function _advancedData(OrderComponents memory c, bytes memory extraData, address recipient)
        internal
        view
        returns (bytes memory)
    {
        AdvancedOrder memory a = AdvancedOrder(_params(c), 1, 1, _sign(c, makerKey), extraData);
        return abi.encodeCall(ISeaport.fulfillAdvancedOrder, (a, new CriteriaResolver[](0), bytes32(0), recipient));
    }

    function _snap() internal view returns (Snap memory s) {
        s.pot = core.ethPot();
        s.balance = address(core).balance;
        s.toBuyback = core.ethToBuyback();
        s.rate = core.rateAtCheckpoint();
        s.fillTime = core.lastFillTime();
        s.pile = core.pileSize();
        s.credits = CREDITS.balanceOf(address(core));
        s.keeper = keeper.balance;
        s.maker = maker.balance;
        s.feeTaker = feeTaker.balance;
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.pot, b.pot, "pot");
        assertEq(a.balance, b.balance, "balance");
        assertEq(a.toBuyback, b.toBuyback, "toBuyback");
        assertEq(a.rate, b.rate, "rate");
        assertEq(a.fillTime, b.fillTime, "fillTime");
        assertEq(a.pile, b.pile, "pile");
        assertEq(a.credits, b.credits, "credits");
        assertEq(a.keeper, b.keeper, "keeper");
        assertEq(a.maker, b.maker, "maker");
        assertEq(a.feeTaker, b.feeTaker, "feeTaker");
    }

    /// calls the door as the keeper and checks everything a successful buy must leave behind.
    /// `cost` is the exact net eth the order takes from the core.
    function _buy(uint256 id, uint256 value, bytes memory data, uint256 cost) internal returns (uint256 paid) {
        uint256 ceiling = core.ethRate();
        Snap memory before = _snap();
        uint256 rate = core.ethRate();

        vm.prank(keeper);
        core.buyListing(value, data, id, Mainnet.SEAPORT);

        assertEq(CREDITS.ownerOf(id), address(core), "core owns the credit");
        assertEq(CREDITS.balanceOf(address(core)), before.credits + 1);
        (bool inPile, uint256 booked,) = core.creditInfo(id);
        assertTrue(inPile, "in the pile");
        paid = keeper.balance - before.keeper;
        assertEq(booked, cost + paid, "costOf is cost plus the payment");
        assertEq(core.pileSize(), before.pile + 1);
        _assertListingPay(paid, ceiling - cost);
        assertEq(core.ethPot(), before.pot - cost - paid, "pot down by exactly cost and the payment");
        assertEq(address(core).balance, before.balance - cost - paid, "balance down by exactly cost and the payment");
        assertEq(core.ethToBuyback(), before.toBuyback);
        assertEq(core.rateAtCheckpoint(), BidModel.dropOnce(core.settings(), rate, rate), "rate drop");
        assertEq(core.lastFillTime(), block.timestamp);
        assertLe(cost + paid, ceiling, "never above the ceiling");
        _solvent();
        assertEq(
            address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn(), 0, "no surplus"
        );
    }

    function _expectFail(uint256 id, uint256 value, bytes memory data, bytes4 err) internal {
        Snap memory before = _snap();
        address owner_ = CREDITS.ownerOf(id);
        vm.prank(keeper);
        vm.expectRevert(err);
        core.buyListing(value, data, id, Mainnet.SEAPORT);
        _assertSame(before, _snap());
        assertEq(CREDITS.ownerOf(id), owner_, "credit did not move");
    }
}

/// every door case against genuine Seaport 1.6 orders, with the pot filled by real swaps. the launch settings
contract SeaportTest is SeaportBase {
    using FixedPointMathLib for uint256;

    /// the pot is large enough to clear every ceiling the tests use
    uint256 internal constant POT = 30 ether;
    /// wei per credit the cases run at: a credit costs 0.433 ether
    uint256 internal constant TARGET_RATE = 4.33e17;

    function setUp() public override {
        super.setUp();
        // the launch rate cap (3 times the opening rate) is far below the rate the cases need: raise it to the bounds,
        // with the clamp at one credit of pot and the ceiling at its loosest so the bid reaches it in days
        Settings memory cs = core.settings();
        cs.rateCap = uint64(TARGET_RATE);
        cs.ceilBps = 30_000;
        cs.idleLoosenBps = 2_000;
        _setSettings(cs);
        _fundPot(POT);
        for (uint256 i; i < 900 && core.ethRate() < TARGET_RATE; ++i) {
            _warp(1 hours);
        }
        assertGe(core.ethRate(), TARGET_RATE, "rate cleared");
        // real fees split between the pot and the redeem burn reserve (feeToRedeemBurnBps), nothing else held
        assertEq(address(core).balance, core.ethPot() + core.ethRedeemBurn(), "the pot and reserve are what real fees brought");
    }

    /*//////////////////////////////////////////////////////////////
                    1 and 2. fulfillBasicOrder_efficient
    //////////////////////////////////////////////////////////////*/

    function test_basic_singleConsiderationToSeller() public {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        uint256 price = ceiling * 9 / 10;
        OrderComponents memory c = _open(id, price, 0);
        assertEq(c.consideration.length, 1);

        uint256 makerBefore = maker.balance;
        _buy(id, price, _basicData(c), price);
        assertEq(maker.balance - makerBefore, price, "maker received the price");
    }

    /// 10 percent under the bid the gap is 0.0433 ether, far above the largest payment at the base fee
    function test_basic_paymentBelowTheGapIsGasPlusFee() public {
        uint256 id = _list();
        uint256 price = core.ethRate() * 9 / 10;
        OrderComponents memory c = _open(id, price, 0);
        vm.fee(1 gwei);
        uint256 paid = _buy(id, price, _basicData(c), price);
        assertLt(paid, core.ethRate() / 10, "the gap does not bind");
        assertGt(paid, core.settings().keeperFee, "gas is paid on top of the fee");
        assertEq((paid - core.settings().keeperFee) % 1 gwei, 0, "gas units at 1 gwei");
    }

    /// a price a few wei under the bid leaves a gap smaller than any payment: the payment is the gap
    function test_basic_paymentIsTheGapNearTheCeiling() public {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        uint256 price = ceiling - 1000;
        OrderComponents memory c = _open(id, price, 0);
        vm.fee(1 gwei);
        assertEq(_buy(id, price, _basicData(c), price), 1000, "the payment is the gap");
    }

    function test_basic_additionalRecipient() public {
        uint256 id = _list();
        uint256 total = core.ethRate() * 7 / 10;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        assertEq(c.consideration.length, 2);
        assertEq(_total(c), total);

        uint256 makerBefore = maker.balance;
        uint256 feeBefore = feeTaker.balance;
        uint256 paid = _buy(id, total, _basicData(c), total);

        assertEq(maker.balance - makerBefore, total - fee, "maker got the price less the fee");
        assertEq(feeTaker.balance - feeBefore, fee, "fee recipient got one percent");
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, total + paid, "cost is the sum of every payout plus the payment");
    }

    /*//////////////////////////////////////////////////////////////
                         3. fulfillOrder, standard path
    //////////////////////////////////////////////////////////////*/

    function test_fulfillOrder_recipientDefaultsToCaller() public {
        uint256 id = _list();
        uint256 total = core.ethRate() * 6 / 10;
        uint256 fee = total / 50;
        OrderComponents memory c = _open(id, total - fee, fee);

        uint256 makerBefore = maker.balance;
        uint256 feeBefore = feeTaker.balance;
        bytes memory data = _orderData(c);
        assertEq(bytes4(data), ISeaport.fulfillOrder.selector);
        _buy(id, total, data, total);

        assertEq(CREDITS.ownerOf(id), address(core), "msg.sender, the core, received the credit");
        assertEq(maker.balance - makerBefore, total - fee);
        assertEq(feeTaker.balance - feeBefore, fee);
    }

    /*//////////////////////////////////////////////////////////////
                  4. fulfillAdvancedOrder, explicit recipient
    //////////////////////////////////////////////////////////////*/

    function test_fulfillAdvancedOrder_explicitRecipientIsCore() public {
        uint256 id = _list();
        uint256 price = core.ethRate() * 8 / 10;
        OrderComponents memory c = _open(id, price, 0);

        uint256 makerBefore = maker.balance;
        bytes memory data = _advancedData(c, "", address(core));
        assertEq(bytes4(data), ISeaport.fulfillAdvancedOrder.selector);
        _buy(id, price, data, price);
        assertEq(maker.balance - makerBefore, price);
    }

    /*//////////////////////////////////////////////////////////////
                           5. overpayment refund
    //////////////////////////////////////////////////////////////*/

    function _overpay(uint256 path) internal {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        uint256 total = ceiling * 6 / 10;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        bytes memory data = path == 0 ? _basicData(c) : path == 1 ? _orderData(c) : _advancedData(c, "", address(core));
        // value is above the order total and at the ceiling, so the door lets it through.
        uint256 value = ceiling;
        assertGt(value, total);

        uint256 balanceBefore = address(core).balance;
        uint256 makerBefore = maker.balance;
        uint256 feeBefore = feeTaker.balance;
        uint256 paid = _buy(id, value, data, total);

        // the excess came back to the core mid call: the balance fell by the cost and the payment, not by value.
        assertEq(balanceBefore - address(core).balance, total + paid, "refund came back");
        assertEq(maker.balance - makerBefore, total - fee);
        assertEq(feeTaker.balance - feeBefore, fee);
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, total + paid, "cost is the order total, not value");

        // the refund is not revenue: nothing for skim to book, pot and buyback pot unchanged by it.
        uint256 pot = core.ethPot();
        core.skim();
        assertEq(core.ethPot(), pot, "skim books nothing");
        assertEq(core.ethToBuyback(), 0);
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }

    function test_overpay_basic() public {
        _overpay(0);
    }

    function test_overpay_fulfillOrder() public {
        _overpay(1);
    }

    function test_overpay_fulfillAdvancedOrder() public {
        _overpay(2);
    }

    /*//////////////////////////////////////////////////////////////
                              6. failures
    //////////////////////////////////////////////////////////////*/

    function test_fail_orderForDifferentCredit() public {
        uint256 listed = _list();
        uint256 asked = CreditIds.at(300);
        assertTrue(asked != LISTED_A && asked != LISTED_B && asked != LISTED_C);
        assertEq(CREDITS.ownerOf(asked), STRATEGY);
        uint256 price = core.ethRate().min(core.ethRate()) / 2;
        OrderComponents memory c = _open(listed, price, 0);
        // the call delivers a credit, just not the one the caller asked for.
        _expectFail(asked, price, _basicData(c), ICore.NoCredit.selector);
        _expectFail(asked, price, _orderData(c), ICore.NoCredit.selector);
        assertEq(CREDITS.ownerOf(listed), maker);
    }

    function test_fail_recipientIsNotTheCore() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        OrderComponents memory c = _open(id, price, 0);
        // the order fills, the credit goes to the keeper, the core gets nothing and the whole buy unwinds.
        _expectFail(id, price, _advancedData(c, "", keeper), ICore.NoCredit.selector);
    }

    function test_fail_cancelledOrder() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        OrderComponents memory c = _open(id, price, 0);
        bytes memory data = _basicData(c);

        // control: the same order fills before the cancel.
        uint256 snap = vm.snapshotState();
        _buy(id, price, data, price);
        vm.revertToState(snap);

        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = c;
        vm.prank(maker);
        assertTrue(SEAPORT.cancel(orders));

        _expectFail(id, price, data, ICore.CallFailed.selector);
        _expectFail(id, price, _orderData(c), ICore.CallFailed.selector);
    }

    function test_fail_badSignature() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        OrderComponents memory c = _open(id, price, 0);
        (, uint256 otherKey) = makeAddrAndKey("creditsengine.seaport.impostor");
        _expectFail(id, price, _basicData(c, _sign(c, otherKey)), ICore.CallFailed.selector);

        // a signature made over a different order does not carry over either.
        OrderComponents memory other = _open(id, price + 1, 0);
        _expectFail(id, price, _basicData(c, _sign(other, makerKey)), ICore.CallFailed.selector);

        // and the genuine one still works afterwards.
        _buy(id, price, _basicData(c), price);
    }

    function test_fail_valueAboveCeiling() public {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        OrderComponents memory c = _open(id, ceiling, 0);
        // the order itself is fine at exactly the ceiling.
        _expectFail(id, ceiling + 1, _basicData(c), ICore.AboveCeiling.selector);
        _expectFail(id, ceiling + 1, _orderData(c), ICore.AboveCeiling.selector);
        uint256 paid = _buy(id, ceiling, _basicData(c), ceiling);
        assertEq(paid, 0, "no gap, no payment");
    }

    function test_fail_orderPaysOutMoreThanValue() public {
        uint256 id = _list();
        uint256 total = core.ethRate() / 2;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        // seaport needs the full sum of every payout in msg.value. one wei short reverts the whole fill.
        _expectFail(id, total - 1, _basicData(c), ICore.CallFailed.selector);
        _expectFail(id, total - 1, _orderData(c), ICore.CallFailed.selector);
        _expectFail(id, total - 1, _advancedData(c, "", address(core)), ICore.CallFailed.selector);
        _expectFail(id, 0, _basicData(c), ICore.CallFailed.selector);
        // the full sum goes through.
        _buy(id, total, _basicData(c), total);
    }

    function test_fail_extraConsiderationCannotBeFundedFromThePot() public {
        // the core only ever sends `value`. an order whose payouts exceed it cannot reach into the rest of the pot.
        uint256 id = _list();
        uint256 value = core.ethRate() / 4;
        OrderComponents memory c = _open(id, value, value);
        assertEq(_total(c), value * 2);
        // control: the same order fills when value covers every payout.
        uint256 snap = vm.snapshotState();
        _buy(id, value * 2, _basicData(c), value * 2);
        vm.revertToState(snap);
        _expectFail(id, value, _basicData(c), ICore.CallFailed.selector);
        _expectFail(id, value, _orderData(c), ICore.CallFailed.selector);
    }

    function test_fail_targetGuards() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        bytes memory data = _basicData(_open(id, price, 0));
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(price, data, id, makeAddr("creditsengine.seaport.notatarget"));
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(price, data, id, address(CREDITS));
    }

    /*//////////////////////////////////////////////////////////////
                         7. restricted orders
    //////////////////////////////////////////////////////////////*/

    function test_restricted_eoaZoneReverts() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        address zone = makeAddr("creditsengine.seaport.zone");
        assertEq(zone.code.length, 0);
        OrderComponents memory c = _components(id, price, 0, zone, OrderType.FULL_RESTRICTED);

        // a restricted order needs its zone to approve the fill, and the core is not the zone. the door only
        // forwards what the caller supplies, it adds nothing, so the whole buy reverts.
        _expectFail(id, price, _basicData(c), ICore.CallFailed.selector);
        _expectFail(id, price, _orderData(c), ICore.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, hex"c0ffee", address(core)), ICore.CallFailed.selector);

        // control: the order is otherwise genuine. when the zone is the caller itself seaport skips the zone
        // callbacks and the same fill goes through, so the revert above comes from the zone and nothing else.
        OrderComponents memory own = _components(id, price, 0, address(core), OrderType.FULL_RESTRICTED);
        _buy(id, price, _basicData(own), price);
    }

    function test_restricted_zoneNeedsTheCallersExtraData() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        ExtraDataZone zone = new ExtraDataZone();
        OrderComponents memory c = _components(id, price, 0, address(zone), OrderType.FULL_RESTRICTED);

        // no extra data, and the basic path has no way to carry any: the zone says no.
        _expectFail(id, price, _basicData(c), ICore.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, "", address(core)), ICore.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, hex"deadbeef", address(core)), ICore.CallFailed.selector);

        // the door forwards whatever bytes the caller supplies, so the right extra data makes the same order fill.
        _buy(id, price, _advancedData(c, hex"c0ffee", address(core)), price);
    }

    /*//////////////////////////////////////////////////////////////
                         8. fuzz the listing price
    //////////////////////////////////////////////////////////////*/

    function testFuzz_priceFromOneWeiToCeiling(uint256 price) public {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        assertLe(ceiling, core.ethPot(), "the pot clears every ceiling here");
        price = bound(price, 1, ceiling);
        OrderComponents memory c = _open(id, price, 0);

        uint256 makerBefore = maker.balance;
        uint256 paid = _buy(id, price, _basicData(c), price);

        (, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, price + paid);
        assertLe(booked, ceiling, "cost plus the payment never exceeds the ceiling");
        assertEq(maker.balance - makerBefore, price);
    }

    /*//////////////////////////////////////////////////////////////
                    9. the self dealing payment (spec 5.4)
    //////////////////////////////////////////////////////////////*/

    /// the maker lists their own credit on real Seaport and calls the door themselves. the order pays `price` less
    /// `side` to the maker and `side` to a second account the maker also controls. returns what both accounts gained
    function _selfDeal(uint256 id, uint256 price, uint256 side) internal returns (uint256 gained, uint256 paid) {
        OrderComponents memory c = _open(id, price - side, side);
        bytes memory data = _orderData(c);
        uint256 before = maker.balance + feeTaker.balance;
        uint256 pot = core.ethPot();
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        gained = maker.balance + feeTaker.balance - before;
        paid = pot - core.ethPot() - price;
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(gained, price + paid, "the maker side got the price and the payment");
    }

    function _sellThroughTheDoor(uint256 id) internal returns (uint256 gained) {
        uint256 before = maker.balance;
        vm.prank(maker);
        core.sellForEth(_one(id));
        gained = maker.balance - before;
    }

    /// for any listing price up to the ceiling the maker ends with at most the eth the sell door pays: the price and the
    /// payment together never exceed the bid. the maker's own gas is not counted, so the sell door is never worse. at
    /// exactly the ceiling there is no payment and it is break even. the order is a genuine Seaport order, filled by
    /// the maker through the door
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_selfDealingNeverBeatsTheSellDoor(uint256 priceSeed, uint256 sideSeed, uint256 warpHours) public {
        _warp(bound(warpHours, 0, 12) * 1 hours);
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        assertLe(ceiling, core.ethPot(), "the pot clears every ceiling here");
        uint256 price = bound(priceSeed, 1, ceiling);
        uint256 side = bound(sideSeed, 0, price - 1) % (price / 2 + 1);
        uint256 snap = vm.snapshotState();

        (uint256 viaListing, uint256 paid) = _selfDeal(id, price, side);
        assertLe(price + paid, ceiling, "the price and the payment stay inside the bid");

        vm.revertToState(snap);
        uint256 viaDoor = _sellThroughTheDoor(id);
        assertEq(viaDoor, ceiling, "the door pays the ceiling");

        assertLe(viaListing, viaDoor, "self dealing never beats the sell door");
        if (price == ceiling) {
            assertEq(paid, 0, "no gap, no payment");
            assertEq(viaListing, viaDoor, "break even at the ceiling");
        }
    }

    /// the edges: one wei, one wei under the ceiling, and the ceiling
    function test_selfDealing_edges() public {
        _warp(8 hours);
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        uint256[3] memory prices = [uint256(1), ceiling - 1, ceiling];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            (uint256 viaListing, uint256 paid) = _selfDeal(id, prices[i], 0);
            assertLe(prices[i] + paid, ceiling);
            vm.revertToState(snap);
            uint256 viaDoor = _sellThroughTheDoor(id);
            vm.revertToState(snap);
            assertEq(viaDoor, ceiling);
            assertLe(viaListing, viaDoor);
            if (i == 0) assertLt(viaListing, viaDoor);
            if (i == 2) assertEq(viaListing, viaDoor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                  10. settings reach the door at once
    //////////////////////////////////////////////////////////////*/

    /// a settings change moves the ceiling the door enforces, in the same block
    function test_rateCapChangeMovesTheDoorCeiling() public {
        uint256 id = _list();
        uint256 before = core.ethRate();
        Settings memory s = core.settings();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.rateCap = uint64(before * 8 / 10);
        _setSettings(s);
        uint256 ceiling = core.ethRate();
        assertEq(ceiling, before * 8 / 10);
        bytes memory data = _basicData(_open(id, ceiling, 0));
        _expectFail(id, ceiling + 1, data, ICore.AboveCeiling.selector);
        _buy(id, ceiling, data, ceiling);
    }

    /// the payment settings reach the door at once: the keeper fee, and the base fee ceiling that binds when the base
    /// fee is above it. a zero fee at a zero base fee pays nothing
    function test_paymentSettingsReachTheDoor() public {
        Settings memory s = core.settings();
        s.keeperFee = 0.005 ether;
        s.keeperMaxBaseFee = 2 gwei;
        _setSettings(s);
        uint256 id = _list();
        uint256 price = core.ethRate() * 6 / 10;
        vm.fee(1 gwei);
        uint256 paid = _buy(id, price, _basicData(_open(id, price, 0)), price);
        assertGt(paid, 0.005 ether, "gas is paid on top of the raised fee");

        // a base fee above the ceiling pays at the ceiling: the same call at 2 gwei and at 50 gwei pays the same
        uint256 id2 = _list();
        uint256 snap = vm.snapshotState();
        vm.fee(2 gwei);
        uint256 atCeiling = _buy(id2, price, _basicData(_open(id2, price, 0)), price);
        vm.revertToState(snap);
        vm.fee(50 gwei);
        uint256 above = _buy(id2, price, _basicData(_open(id2, price, 0)), price);
        assertEq(above, atCeiling, "a base fee above the ceiling pays at the ceiling");

        s.keeperFee = 0;
        _setSettings(s);
        uint256 id4 = _list();
        vm.fee(0);
        assertEq(_buy(id4, price, _basicData(_open(id4, price, 0)), price), 0, "no fee, no base fee, no payment");
    }
}

/// the pot bound refusal, on a core whose pot real swaps have not filled, or filled only a little. the launch
/// settings
contract SeaportColdTest is SeaportBase {
    function test_fail_valueAbovePot() public {
        uint256 id = _list();
        uint256 price = 1e15;
        OrderComponents memory c = _open(id, price, 0);
        assertEq(core.ethPot(), 0);
        _expectFail(id, price, _basicData(c), ICore.PotTooSmall.selector);
    }
}

/// the caller economics of `buyListing` at the launch settings (keeperFee 0.0005 ether, keeperMaxBaseFee 10 gwei) with
/// the gas of the call measured cold, through a basic Seaport order. the caller pays gas at the base fee and no
/// priority fee. profit is the payment less the transaction gas (21,000, the call, the calldata) at the base fee
contract SeaportCallerPayTest is SeaportBase {
    /// the opening bid of docs/DECISIONS.md section 2, wei per credit
    uint256 internal constant P0 = 8_900_000_000_000_000;

    function setUp() public override {
        super.setUp();
        _fundPot(30 ether);
    }

    function _coolAll() internal {
        address[14] memory a = [
            address(core),
            address(ctl),
            address(STATEMENTS),
            address(CREDITS),
            address(SEAPORT),
            address(PM),
            v2.hook,
            address(coin),
            v2.locker,
            v2.escrow,
            v2.factory,
            v2.mev,
            address(feeRouter),
            STRATEGY
        ];
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != address(0)) vm.cool(a[i]);
        }
    }

    function _calldataGas(bytes memory d) internal pure returns (uint256 g) {
        for (uint256 i; i < d.length; ++i) {
            g += d[i] == 0 ? 4 : 16;
        }
    }

    /// one buy of a listing `gapBps` under `bid` at base fee `bf`. returns the payment and the caller's profit
    function _run(uint256 bid, uint256 gapBps, uint256 bf) internal returns (uint256 paid, int256 profit) {
        vm.prank(owner);
        core.setRate(bid);
        assertEq(core.ethRate(), bid, "the bid is the restated rate");
        uint256 id = _list();
        uint256 price = bid - bid * gapBps / 10_000;
        bytes memory data = _basicData(_open(id, price, 0));
        vm.fee(bf);
        vm.txGasPrice(bf);
        _coolAll();
        uint256 before = keeper.balance;
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        g -= gasleft();
        paid = keeper.balance - before;
        uint256 txGas = 21_000 + g + _calldataGas(abi.encodeCall(core.buyListing, (price, data, id, Mainnet.SEAPORT)));
        profit = int256(paid) - int256(txGas * bf);
        console.log("bid, gap bps, base fee gwei*1000:", bid, gapBps, bf / 1e6);
        console.log("  tx gas, paid, cost at the base fee:", txGas, paid, txGas * bf);
        console.log(profit < 0 ? "  loss:" : "  profit:", profit < 0 ? uint256(-profit) : uint256(profit));
    }

    /// 10 percent under a bid of 1.5 times the opening bid, at 2 gwei: the gap (0.001335 ether) is above the gas cost
    /// (about 0.0009 ether) and below the largest payment, so the caller is paid the gap and profits
    function test_listingTenPercentUnderTheBidProfitsAtTwoGwei() public {
        (uint256 paid, int256 profit) = _run(P0 * 3 / 2, 1_000, 2 gwei);
        assertEq(paid, P0 * 3 / 2 / 10, "the gap binds");
        assertGt(profit, 0.0003 ether, "profit");
    }

    /// at the rate cap bid (3 times the opening bid) the payment is gas plus the keeper fee, not the gap
    function test_listingTenPercentUnderTheCapBidProfitsAtTwoGwei() public {
        (uint256 paid, int256 profit) = _run(P0 * 3, 1_000, 2 gwei);
        assertLt(paid, P0 * 3 / 10, "the gap does not bind");
        assertGt(profit, 0.0005 ether, "the keeper fee and the overhead margin");
    }

    /// at the opening bid itself a 10 percent gap (0.00089 ether) equals the gas cost at 2 gwei: no profit and no loss
    /// beyond a few thousand gwei
    function test_listingTenPercentUnderTheOpeningBidIsBreakEvenAtTwoGwei() public {
        (, int256 profit) = _run(P0, 1_000, 2 gwei);
        assertLt(profit, 0.0001 ether);
        assertGt(profit, -0.0001 ether);
    }

    /// the table of the report: gaps of 5, 10, 20 and 50 percent at the opening bid, base fees 1, 2, 5 gwei
    function test_profitTable() public {
        uint256[4] memory gaps = [uint256(500), 1_000, 2_000, 5_000];
        uint256[3] memory fees = [uint256(1 gwei), 2 gwei, 5 gwei];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < gaps.length; ++i) {
            for (uint256 j; j < fees.length; ++j) {
                _run(P0, gaps[i], fees[j]);
                vm.revertToState(snap);
            }
        }
    }
}
