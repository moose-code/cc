// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {console} from "forge-std/console.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ISeaportBasicAdapter} from "../src/interfaces/ISeaportBasicAdapter.sol";
import {Mainnet, Settings, ICreditScore} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {BidModel} from "./utils/BidModel.sol";
import {
    ISeaport,
    ItemType,
    OrderType,
    BasicOrderType,
    OfferItem,
    ConsiderationItem,
    OrderComponents,
    AdditionalRecipient,
    BasicOrderParameters
} from "./utils/SeaportTypes.sol";

/// shared plumbing: genuine Seaport 1.6 orders for credits, signed by a maker key. the maker holds a real credit,
/// approves Seaport directly on Credits (no conduit), and signs the eip 712 digest of the order hash that Seaport
/// itself computes, under the domain separator Seaport itself reports. the core is the real core of the fixture and the
/// orders reach it through the launch `SeaportBasicAdapter`, whose allowlist holds the fee taker of the tests
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
        vm.prank(owner);
        ISeaportBasicAdapter(seaportAdapter).setAllowedRecipient(feeTaker, true);
        _skipSniperWindow();
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    /// hands the next usable credit to the maker and approves Seaport itself as operator, no conduit.
    function _list() internal returns (uint256 id) {
        id = _credits(maker, 1)[0];
        // refScore set to the listed credit's score, so its bid is the full rate and the ethRate based order prices hold
        _unitScore(id);
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

    /// the `params` of the adapter for the basic order of `c` signed with `sig`
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
        return abi.encode(b);
    }

    function _basicData(OrderComponents memory c) internal view returns (bytes memory) {
        return _basicData(c, _sign(c, makerKey));
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
    /// `cost` is the exact eth the adapter prices: the sum of every payout of the order.
    function _buy(uint256 id, bytes memory params, uint256 cost) internal returns (uint256 paid) {
        uint256 ceiling = core.bidOf(id);
        Snap memory before = _snap();
        uint256 rate = core.ethRate();
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));

        vm.prank(keeper);
        core.buyListing(seaportAdapter, id, params);

        assertEq(CREDITS.ownerOf(id), address(core), "core owns the credit");
        assertEq(CREDITS.balanceOf(address(core)), before.credits + 1);
        (bool inPile, uint256 booked,) = core.creditInfo(id);
        assertTrue(inPile, "in the pile");
        paid = keeper.balance - before.keeper;
        // the artist royalty on the price rides on top and is part of the cost basis (decision 163)
        uint256 royalty = cost * core.settings().buyToArtistBps / 10_000;
        assertEq(booked, cost + royalty + paid, "costOf is cost plus the royalty plus the payment");
        assertEq(core.pileSize(), before.pile + 1);
        uint256 gap = ceiling - cost;
        uint256 roomGap = before.pot - core.reserve() - cost - royalty;
        _assertListingPay(paid, gap < roomGap ? gap : roomGap);
        assertEq(core.ethPot(), before.pot - cost - royalty - paid, "pot down by exactly cost, the royalty and the payment");
        assertEq(
            address(core).balance, before.balance - cost - royalty - paid, "balance down by exactly cost, the royalty and the payment"
        );
        assertEq(core.ethToBuyback(), before.toBuyback);
        assertEq(
            core.rateAtCheckpoint(), BidModel.dropOnce(core.settings(), rate, rate, score, RATE_SCORE), "rate drop"
        );
        assertEq(core.lastFillTime(), block.timestamp);
        assertLe(cost + paid, ceiling, "never above the ceiling");
        _solvent();
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn(), 0, "no surplus");
    }

    function _expectFail(uint256 id, bytes memory params, bytes4 err) internal {
        Snap memory before = _snap();
        address owner_ = CREDITS.ownerOf(id);
        vm.prank(keeper);
        vm.expectRevert(err);
        core.buyListing(seaportAdapter, id, params);
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
        assertEq(
            address(core).balance,
            core.ethPot() + core.ethRedeemBurn(),
            "the pot and reserve are what real fees brought"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    1. the basic order through the adapter
    //////////////////////////////////////////////////////////////*/

    // promise: SPEC 6 buyListing caps value and the keeper payment at the credit's scaled bid, at score != refScore
    function test_basic_capAndPaymentAtScoreNotRefScore() public {
        // a fresh listing without forcing refScore to the credit's score, so score / refScore is not 1
        uint256 id = _credits(maker, 1)[0];
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        uint256 ref = RATE_SCORE;
        uint256 s = _scoreOf(id);
        assertTrue(s != ref, "the credit's score is not refScore");
        _fundPot(10 ether);
        // the per-credit bid by the hand formula, not bidOf
        uint256 handBid = (core.ethRate() * s) / ref;
        uint256 gap = 1000; // below the keeper fee, so the payment is capped at the gap
        uint256 value = handBid - gap;
        OrderComponents memory c = _open(id, value, 0);
        bytes memory order = _basicData(c);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        uint256 kb = keeper.balance;
        vm.prank(keeper);
        core.buyListing(seaportAdapter, id, order);
        assertEq(keeper.balance - kb, gap, "the keeper payment is capped at the scaled bid less value");
        (, uint256 basis,) = core.creditInfo(id);
        assertEq(
            basis,
            handBid + value * core.settings().buyToArtistBps / 10_000,
            "the cost basis is the scaled bid plus the royalty on value: value, its royalty and the capped payment"
        );
        assertEq(CREDITS.ownerOf(id), address(core), "the engine owns the credit");
    }

    // promise: SPEC 1 buyListing buys an adapter priced Seaport basic order (decision 100)
    function test_basic_singleConsiderationToSeller() public {
        uint256 id = _list();
        uint256 ceiling = core.ethRate();
        uint256 price = ceiling * 9 / 10;
        OrderComponents memory c = _open(id, price, 0);
        assertEq(c.consideration.length, 1);

        uint256 makerBefore = maker.balance;
        _buy(id, _basicData(c), price);
        assertEq(maker.balance - makerBefore, price, "maker received the price");
    }

    // promise: INTEGRATION SeaportBasicAdapter: additional recipients on the allowlist are part of the cost
    /// the fee taker is on the adapter allowlist: its payout is part of the cost
    function test_basic_additionalRecipient() public {
        uint256 id = _list();
        uint256 total = core.ethRate() * 7 / 10;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        assertEq(c.consideration.length, 2);
        assertEq(_total(c), total);

        uint256 makerBefore = maker.balance;
        uint256 feeBefore = feeTaker.balance;
        uint256 paid = _buy(id, _basicData(c), total);

        assertEq(maker.balance - makerBefore, total - fee, "maker got the price less the fee");
        assertEq(feeTaker.balance - feeBefore, fee, "fee recipient got one percent");
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(
            booked,
            total + total * core.settings().buyToArtistBps / 10_000 + paid,
            "cost is the sum of every payout plus the royalty on it plus the payment"
        );
    }

    // promise: INTEGRATION SeaportBasicAdapter: a payout off the allowlist makes price revert, BadQuote
    /// a payout to the caller on top of the signed order is a tip the adapter refuses
    function test_basic_tipToTheCallerIsRefused() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        OrderComponents memory c = _open(id, price, 1);
        c.consideration[1].recipient = payable(keeper);
        _expectFail(id, _basicData(c), ICore.BadQuote.selector);
        assertEq(keeper.balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              2. failures
    //////////////////////////////////////////////////////////////*/

    // promise: INTEGRATION CallFailed when Seaport rejects the order
    function test_fail_badSignature() public {
        uint256 id = _list();
        uint256 price = core.ethRate() / 2;
        OrderComponents memory c = _open(id, price, 0);
        (, uint256 otherKey) = makeAddrAndKey("creditsengine.seaport.impostor");
        _expectFail(id, _basicData(c, _sign(c, otherKey)), ICore.CallFailed.selector);

        // a signature made over a different order does not carry over either.
        OrderComponents memory other = _open(id, price + 1, 0);
        _expectFail(id, _basicData(c, _sign(other, makerKey)), ICore.CallFailed.selector);

        // and the genuine one still works afterwards.
        _buy(id, _basicData(c), price);
    }

    /*//////////////////////////////////////////////////////////////
                         8. fuzz the listing price
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                    9. the self dealing payment (spec 5.4)
    //////////////////////////////////////////////////////////////*/

    /// the maker lists their own credit on real Seaport and calls the door themselves. the order pays `price` less
    /// `side` to the maker and `side` to a second account the maker also controls. returns what both accounts gained
    function _selfDeal(uint256 id, uint256 price, uint256 side) internal returns (uint256 gained, uint256 paid) {
        OrderComponents memory c = _open(id, price - side, side);
        bytes memory data = _basicData(c);
        uint256 before = maker.balance + feeTaker.balance;
        uint256 pot = core.ethPot();
        vm.prank(maker);
        core.buyListing(seaportAdapter, id, data);
        gained = maker.balance + feeTaker.balance - before;
        // the artist royalty on the price leaves the pot as well (decision 163)
        paid = pot - core.ethPot() - price - price * core.settings().buyToArtistBps / 10_000;
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(gained, price + paid, "the maker side got the price and the payment");
    }

    function _sellThroughTheDoor(uint256 id) internal returns (uint256 gained) {
        uint256 before = maker.balance;
        vm.prank(maker);
        core.sellForEth(_one(id));
        gained = maker.balance - before;
    }

    // promise: SPEC 1 buyListing: the engine keeps the gap, a self dealt listing never beats sellForEth
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

    /*//////////////////////////////////////////////////////////////
                  10. settings reach the door at once
    //////////////////////////////////////////////////////////////*/
}

/// the pot bound refusal, on a core whose pot real swaps have not filled, or filled only a little. the launch
/// settings
contract SeaportColdTest is SeaportBase {}

/// the caller economics of `buyListing` at the launch settings (keeperFee 0.0003 ether, keeperMaxBaseFee 5 gwei) with
/// the gas of the call measured cold, through a basic Seaport order. the caller pays gas at the base fee and no
/// priority fee. profit is the payment less the transaction gas (21,000, the call, the calldata) at the base fee
contract SeaportCallerPayTest is SeaportBase {
    /// the opening bid of docs/DECISIONS.md section 2, wei per credit
    uint256 internal constant P0 = 8_900_000_000_000_000;
    /// gas that two runs of one call differ by
    uint256 internal constant GAS_NOISE = 10_000;

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
            seaportAdapter,
            address(PM),
            v2.hook,
            address(coin),
            v2.locker,
            v2.escrow,
            v2.factory,
            v2.mev,
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
        core.buyListing(seaportAdapter, id, data);
        g -= gasleft();
        paid = keeper.balance - before;
        uint256 txGas = 21_000 + g + _calldataGas(abi.encodeCall(core.buyListing, (seaportAdapter, id, data)));
        profit = int256(paid) - int256(txGas * bf);
        console.log("bid, gap bps, base fee gwei*1000:", bid, gapBps, bf / 1e6);
        console.log("  tx gas, paid, cost at the base fee:", txGas, paid, txGas * bf);
        console.log(profit < 0 ? "  loss:" : "  profit:", profit < 0 ? uint256(-profit) : uint256(profit));
    }

    // promise: SPEC 1 outside bots fill listings below the bid: break even gap at 2 gwei
    /// the payment is the gap while the gap is under the keeper fee plus the metered gas at the base fee, and the caller's
    /// cost is the transaction gas at the base fee, so the break even gap is that cost. at the opening bid and 2 gwei a
    /// 10 percent gap pays the whole gap and loses the rest of the cost. the gap in bps derived from the measured cost
    /// pays back the cost within one bps of the bid (the gap steps in bps) plus the gas noise between two runs of the
    /// same call, which is a few thousand gas (GasCap.t.sol `_sellBatch`); `GAS_NOISE` bounds it at 10,000 gas
    function test_breakEvenGapAtTwoGweiIsTheMeasuredGasCost() public {
        uint256 snap = vm.snapshotState();
        (uint256 paid, int256 profit) = _run(P0, 1_000, 2 gwei);
        assertEq(paid, P0 * 1_000 / 10_000, "a 10 percent gap is paid whole");
        assertLt(profit, 0, "a 10 percent gap is under the cost at 2 gwei");
        uint256 cost = uint256(int256(paid) - profit);
        uint256 breakEvenBps = (cost * 10_000 + P0 - 1) / P0;
        assertGt(breakEvenBps, 1_000, "the break even gap is wider than 10 percent");

        vm.revertToState(snap);
        (paid, profit) = _run(P0, breakEvenBps, 2 gwei);
        int256 tolerance = int256(P0 / 10_000) + int256(GAS_NOISE * 2 gwei);
        assertGt(profit, -tolerance, "the derived gap covers the cost");
        assertLt(profit, tolerance, "the derived gap is the narrowest in bps");
    }
}
