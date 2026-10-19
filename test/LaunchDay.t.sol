// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, RATE_SCORE, ICreditStrategy, BUYLISTING_GAS} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Fixture} from "./utils/Fixture.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";

/// @notice the first 24 hours of a mainnet launch with the keeper as the only engine caller. a chain id 1 fork of the
/// live artcoins v2 stack, the engine deployed through the fixture's real launch path, the owner funded, no door call
/// after deploy. the day is driven by external events only: real pool swaps push fee income through the hook unbooked
/// (`autoBook` off, no `fund`, no `vm.deal` on the Core), credits are listed on the CreditStrategy and on genuine
/// Seaport orders, holders sell at the bid, and a keeper address evaluates the ported `keeper/src/decide.ts` gates at
/// every block and sends exactly those calls.
///
/// The funded climb waits for fee income to be booked. Unbooked hook income can support the opening bid, but cannot
/// start a climb clock whose fee arrival time the Core does not know.
abstract contract LaunchDayBase is SeaportBase {
    using FixedPointMathLib for uint256;

    uint256 internal constant LAUNCH_RATE = 4_650_000_000_000_000;

    function _fixtureRateStart() internal pure override returns (uint256) {
        return LAUNCH_RATE;
    }

    function _fixtureCreditSaleOn() internal pure override returns (bool) {
        return true;
    }

    function _settings() internal view override returns (Settings memory) {
        return Mainnet.defaultSettings();
    }

    /// @dev the keeper's buyListing gas guess (keeper/src/decide.ts GAS_GUESS.buyListing), restated
    uint256 internal constant GAS_GUESS_BUYLISTING = 520_000;
    /// @dev the keeper's listing staleness delay, seconds (keeper/src/config listingDelaySec)
    uint256 internal constant LISTING_DELAY = 120;
    /// @dev the base fee the day runs at, under the keeper ceiling so a listing gap wider than the gas cost is profitable
    uint256 internal constant BASEFEE = 0.2 gwei;

    /// @dev a listing the keeper watches. `score` is RATE_SCORE for the unit-scored Seaport orders and the real score
    /// for the strategy credits, so the keeper reads its bid as `ethRate() * score / RATE_SCORE` without a per-tick call
    struct Listing {
        address adapter;
        uint256 id;
        uint256 price;
        bytes params;
        uint256 score;
        bool underBidTarget;
        bool filled;
        uint64 sweepSince;
        uint64 sweepAtBuy;
        uint64 stepAtBuy;
        uint64 boughtAt;
    }

    Listing[] internal lst;

    /// @dev the current advance step, read when a buyListing fires so the timing promise bounds the delay by one tick
    uint64 internal curStep;
    /// @dev set by any eth-bid fill (buyListing or an organic sell) since the last climb checkpoint
    bool internal fillSinceCheck;
    uint256 internal prevCheckRate;
    /// @dev seconds between the fixture's trickle buys
    uint256 internal constant TRICKLE_EVERY = 300;
    uint256 internal lastTrickle;

    uint256 internal launchedAt;
    bool internal payeeLatchedByBook;
    uint64 internal payeeLatchTime;
    uint64 internal lastBookTime;
    uint256 internal postLatchBooks;
    uint256 internal statementsBefore;
    uint256[25] internal hourRate;
    uint256[25] internal hourBooked;
    uint256[25] internal hourPending;
    uint256[25] internal hourPile;
    uint256 internal hourSamples;

    // the two organic sellers' credits, provisioned in setUp so their real scores are cached before the day runs
    uint256 internal sell2h;
    uint256 internal sell6h;

    function setUp() public virtual override {
        // the sniper window must stay open (SeaportBase.setUp skips it), so build the fixture and the Seaport maker here
        Fixture.setUp();
        (maker, makerKey) = makeAddrAndKey("creditsengine.launchday.maker");
        feeTaker = makeAddr("creditsengine.launchday.fees");
        assertEq(maker.code.length + feeTaker.code.length, 0);

        autoBook = false; // fee income arrives through the hook unbooked, as on mainnet before a door books
        vm.fee(BASEFEE);
        launchedAt = IArtCoinsFactoryV2(FACTORY).deploymentInfo(address(coin)).launchedAt;
        assertEq(launchedAt, launchTime, "the factory recorded the launch at deploy");

        // the two holders who sell at the bid later in the day. real scores, so the bid scales by score over 100 points
        sell2h = _credits(seller, 1)[0];
        sell6h = _credits(seller, 1)[0];
    }

    /*//////////////////////////////////////////////////////////////
                         the ported keeper gates
    //////////////////////////////////////////////////////////////*/

    /// @dev the unbooked fee income: the Core balance above the three pots (keeper/src/read pendingIncome)
    function _pending() internal view returns (uint256) {
        return address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
    }

    /// @dev the pot share of the pending income that the next `_book` folds into `ethPot` (decision 147): the payee
    /// share while latched, then `feeToRedeemBurnBps` of the rest to the redeem-burn pot, the remainder to the pot
    function _pendingPot(Settings memory s) internal view returns (uint256) {
        uint256 income = _pending();
        uint256 toPayee = core.payeeOn() ? income * s.payeePpm / 1_000_000 : 0;
        uint256 toBurn = (income - toPayee) * s.feeToRedeemBurnBps / 10_000;
        return income - toPayee - toBurn;
    }

    /// @dev the worst base fee a keeper transaction can land at: `min(baseFee * 9 / 8, door ceiling)`
    function _worstBaseFee(uint256 ceiling) internal view returns (uint256) {
        uint256 bumped = (block.basefee * 9 + 7) / 8;
        return bumped < ceiling ? bumped : ceiling;
    }

    /// @dev Core.buyListing payment at base fee `b`: min(min(gasGuess, BUYLISTING_GAS) * min(b, keeperMaxBaseFee) +
    /// keeperFee, bid - price, potWithPending - price). the pot is read after the door's own `_book`
    function _listingPayment(Settings memory s, uint256 bid, uint256 price, uint256 potWithPending, uint256 b)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = GAS_GUESS_BUYLISTING < BUYLISTING_GAS ? GAS_GUESS_BUYLISTING : BUYLISTING_GAS;
        uint256 rate = b < s.keeperMaxBaseFee ? b : s.keeperMaxBaseFee;
        uint256 refund = cap * rate + s.keeperFee;
        uint256 gap = bid - price;
        uint256 room = potWithPending - price;
        uint256 pay = refund < gap ? refund : gap;
        return pay < room ? pay : room;
    }

    /// @dev one keeper evaluation at a block: it fires exactly the calls the gates clear, from the keeper address, and
    /// nothing else. the doors that clear in this scenario are buyListing and books; the buyback,
    /// compose, collectEscrow and redeemStatement gates are evaluated and skip (no buyback pot, under 80 credits, no
    /// escrow credit, no statements), the same skips keeper/src/decide.ts would log
    function _keeperTick() internal {
        if (core.paused()) return;
        Settings memory s = core.settings();
        uint256 rate = core.ethRate();
        uint256 potWithPending = core.ethPot() + _pendingPot(s);

        // 1. buyListing: a listing under its bid and under the pot, profitable, continuously for LISTING_DELAY seconds
        uint256 b = _worstBaseFee(s.keeperMaxBaseFee);
        uint256 ownCost = GAS_GUESS_BUYLISTING * b; // tip 0, margin 0
        for (uint256 i; i < lst.length; ++i) {
            Listing storage l = lst[i];
            if (l.filled) continue;
            uint256 bid = rate.mulDiv(l.score, RATE_SCORE);
            bool sweepable = l.price <= bid && l.price <= potWithPending;
            if (sweepable && _listingPayment(s, bid, l.price, potWithPending, b) < ownCost) sweepable = false;
            if (!sweepable) {
                l.sweepSince = 0;
                continue;
            }
            if (l.sweepSince == 0) l.sweepSince = uint64(block.timestamp);
            if (block.timestamp - l.sweepSince < LISTING_DELAY) continue;
            l.sweepAtBuy = l.sweepSince;
            l.stepAtBuy = curStep;
            l.boughtAt = uint64(block.timestamp);
            l.filled = true;
            l.sweepSince = 0;
            fillSinceCheck = true;
            vm.prank(keeper);
            core.buyListing(l.adapter, l.id, l.params);
            // one call per block keeps the keeper to one in-flight transaction; re-evaluate the rest next block
            return;
        }

        // 5. book: latch after the sniper window, then book pending income above the keeper's 0.01 ETH threshold
        // after its 600-second spacing. Both rules come from keeper/src/decide.ts.
        if (!core.payeeOn() && launchedAt != 0 && block.timestamp >= launchedAt + s.sniperSeconds && _pending() != 0) {
            payeeLatchedByBook = true;
            payeeLatchTime = uint64(block.timestamp);
            vm.prank(keeper);
            core.book();
            lastBookTime = uint64(block.timestamp);
        } else if (core.payeeOn() && _pending() > 0.01 ether && block.timestamp - lastBookTime > 600) {
            vm.prank(keeper);
            core.book();
            lastBookTime = uint64(block.timestamp);
            postLatchBooks++;
        }

        // 2/3/4/6 are evaluated for fidelity and skip in this scenario:
        // buyback: ethToBuyback is 0 (no credit sale, no released redeem-burn), so NothingToBuy
        // compose: pileSize stays under 80, so nextPage is NotReady
        // collectEscrow: the Core holds no escrow credit (no partial buyback fill)
        // redeemStatement: no statements were composed, so heldStatements is empty
    }

    /*//////////////////////////////////////////////////////////////
                         the day's external drivers
    //////////////////////////////////////////////////////////////*/

    /// @dev advances to `toTs` in `step`-second blocks, ticking the keeper at each and dripping a small buy every
    /// TRICKLE_EVERY seconds when `trickle`. the step stays under LISTING_DELAY through the active hours so the keeper's
    /// staleness clock is sampled at least once per delay window
    function _advance(uint256 toTs, uint256 step, bool trickle) internal {
        curStep = uint64(step);
        while (block.timestamp < toTs) {
            uint256 nxt = block.timestamp + step;
            if (nxt > toTs) nxt = toTs;
            vm.warp(nxt);
            vm.roll(block.number + 1);
            if (trickle && block.timestamp >= lastTrickle + TRICKLE_EVERY) {
                _buyCoin(funder, 0.05 ether);
                lastTrickle = block.timestamp;
            }
            _keeperTick();
            uint256 age = block.timestamp - launchTime;
            if (age >= 1 hours && age <= 24 hours && age % 1 hours == 0) {
                uint256 h = age / 1 hours;
                hourRate[h] = core.ethRate();
                hourBooked[h] = core.ethPot();
                hourPending[h] = _pending();
                hourPile[h] = core.pileSize();
                hourSamples++;
            }
        }
    }

    /// @dev the first-hour fee burst: large buys and a sell back, both directions through the real pool, all unbooked
    function _burst() internal {
        _buyCoin(funder, 3 ether);
        _buyCoin(funder, 2 ether);
        _sellCoin(funder, coin.balanceOf(funder) / 4);
        assertGt(_pending(), 0.1 ether, "the burst pushed fee income the hook left unbooked");
        assertEq(core.ethPot(), 0, "no door booked, the pot is still empty");
    }

    /// @dev lists `id` on a genuine Seaport order at `price`, score forced to RATE_SCORE so its bid is the full rate.
    /// `underBidTarget` marks the two orders priced under the opening bid, which must fill
    function _placeSeaport(uint256 price, bool underBidTarget) internal {
        uint256 id = _credits(maker, 1)[0];
        _unitScore(id);
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        OrderComponents memory c = _open(id, price, 0);
        lst.push(
            Listing({
                adapter: seaportAdapter,
                id: id,
                price: price,
                params: _basicData(c),
                score: RATE_SCORE,
                underBidTarget: underBidTarget,
                filled: false,
                sweepSince: 0,
                sweepAtBuy: 0,
                stepAtBuy: 0,
                boughtAt: 0
            })
        );
    }

    /// @dev a signed Seaport order using the Credit's actual onchain score, for the first-page keeper stress path
    function _placeSeaportRealScore(uint256 price) internal {
        uint256 id = _credits(maker, 1)[0];
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        OrderComponents memory c = _open(id, price, 0);
        lst.push(
            Listing({
                adapter: seaportAdapter,
                id: id,
                price: price,
                params: _basicData(c),
                score: _scoreOf(id),
                underBidTarget: false,
                filled: false,
                sweepSince: 0,
                sweepAtBuy: 0,
                stepAtBuy: 0,
                boughtAt: 0
            })
        );
    }

    /// @dev adds a CreditStrategy listing at its real `nftForSale` price
    function _placeStrategy(uint256 id) internal {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(id);
        assertGt(price, 0, "the strategy lists the credit");
        lst.push(
            Listing({
                adapter: strategyAdapter,
                id: id,
                price: price,
                params: "",
                score: _scoreOf(id),
                underBidTarget: false,
                filled: false,
                sweepSince: 0,
                sweepAtBuy: 0,
                stepAtBuy: 0,
                boughtAt: 0
            })
        );
    }

    /// @dev a holder sells one credit at the bid. reads the quoted bid and the view rate in the same block, sells, and
    /// returns the quote, the paid amount and the rate the EthRateFill event reports
    function _organicSell(uint256 id) internal returns (uint256 quoted, uint256 paid, uint256 fillRate) {
        uint256 score = _scoreOf(id);
        quoted = core.bidOf(id);
        assertEq(quoted, core.ethRate().mulDiv(score, RATE_SCORE), "bidOf is the view rate scaled by the credit score");
        uint256 before = seller.balance;
        vm.recordLogs();
        vm.prank(seller);
        core.sellForEth(_one(id));
        paid = seller.balance - before;
        fillRate = _ethRateFill(vm.getRecordedLogs());
        fillSinceCheck = true;
    }

    /// @dev the rate the Core's EthRateFill event reports (the post-drop rate), from `logs`
    function _ethRateFill(Vm.Log[] memory logs) internal view returns (uint256 rate) {
        bytes32 sig = ICore.EthRateFill.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == sig) {
                (, rate,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                return rate;
            }
        }
        revert("no EthRateFill event");
    }

    /*//////////////////////////////////////////////////////////////
                             the checkpoints
    //////////////////////////////////////////////////////////////*/

    /// @dev after a known funded interval the eth bid climbs strictly when no fill happened since the last checkpoint.
    /// the read never exceeds the pot plus the pending pot share, and the pots never exceed the Core balance
    function _checkpoint(string memory tag, bool fundedInterval) internal {
        uint256 r = core.ethRate();
        // the promise is a strict climb only across a fill-free interval; a fill drops the rate, so across one only the
        // clamp and solvency are asserted
        if (fundedInterval && !fillSinceCheck && prevCheckRate < core.settings().rateCap) {
            assertGt(r, prevCheckRate, string.concat(tag, ": the bid climbs while nothing fills"));
        }
        Settings memory s = core.settings();
        assertLe(
            r, core.ethPot() + _pendingPot(s), string.concat(tag, ": the bid rides the pot plus the pending pot share")
        );
        _solvent();
        prevCheckRate = r;
        fillSinceCheck = false;
    }
}

/// @notice the launch day scenario one (keeper the only caller) and the isolated climb from unbooked income, driven
/// through the shared `LaunchDayBase`
contract LaunchDayTest is LaunchDayBase {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                    1. the launch day, keeper only
    //////////////////////////////////////////////////////////////*/

    // promise: the keeper-only launch day waits for booked funding to climb; under-bid listings fill within the delay,
    // organic sells pay the bid, the payee latches at the first post-window book, and the rate equals the next fill
    function test_launchDayKeeperIsTheOnlyEngineCaller() public {
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertEq(address(core).balance, 0, "the fresh engine holds no eth");
        assertEq(core.ethRate(), 0, "an empty pot clamps the live bid to 0 until income arrives");
        assertEq(core.RATE_START(), LAUNCH_RATE, "the stored opening rate the bid climbs from");
        assertEq(core.settings().reserveWei, 0.1 ether, "the launch reserve is active");
        assertTrue(ctl.creditSaleOn(), "the launch credit sale is on");
        statementsBefore = STATEMENTS.supply();
        // the opening rate is the reference the live bid climbs from once income is booked
        prevCheckRate = LAUNCH_RATE;

        // the strategy listings sit on the book from the start: one reachable as the rate climbs (35377, 0.036 eth, a
        // high score), two above the launch cap (28352, 18683) the keeper keeps skipping
        _placeStrategy(LISTED_A);
        _placeStrategy(LISTED_B);
        _placeStrategy(LISTED_C);

        // minute one: the fee burst, unbooked
        _advance(launchTime + 60, 12, false);
        _burst();

        // t = 5 min: no door has booked the fee income, so the opening bid is payable but has not climbed
        _advance(launchTime + 300, 12, false);
        assertEq(core.ethRate(), LAUNCH_RATE, "unbooked income did not start the funded clock");
        _solvent();

        // place the Seaport orders just after 5 min: two under the opening bid (must fill), one near the cap (sits above
        // the bid). they are sweepable at once; the keeper buys them LISTING_DELAY later
        _placeSeaport(LAUNCH_RATE * 85 / 100, true);
        _placeSeaport(LAUNCH_RATE * 82 / 100, true);
        _placeSeaport(uint256(core.settings().rateCap) * 95 / 100, false);

        // to 30 min, 12 s blocks: the keeper sweeps the two under-bid orders near 8 min, then books to latch the payee
        // share at the first block past the sniper window
        _advance(launchTime + 1800, 12, true);
        _checkpoint("30 min", false); // earlier listing fills break a strict between-checkpoint climb comparison
        assertTrue(payeeLatchedByBook, "the payee share latched on the keeper's book, not an organic fill");
        Settings memory s = core.settings();
        assertGe(payeeLatchTime, launchedAt + s.sniperSeconds, "the latch waited for the sniper window");
        assertLe(payeeLatchTime, launchedAt + s.sniperSeconds + 12, "and landed on the first block past it");
        assertTrue(core.payeeOn(), "the payee share is on after the post-window book");
        _assertUnderBidListingsFilled();

        // to 2 h, 60 s blocks (under the delay): a holder sells one credit at the bid
        _advance(launchTime + 7200, 60, true);
        (uint256 q2, uint256 p2, uint256 f2) = _organicSell(sell2h);
        assertEq(p2, q2, "the 2 h organic sell paid the quoted bid");
        assertLe(f2, q2, "the fill event's post-drop rate is at or below the paid rate");
        _checkpoint("2 h", true);

        // to 6 h, 60 s blocks: the climb clears 35377's price along the way and the keeper buys it; a second holder sells
        _advance(launchTime + 21600, 60, true);
        (uint256 q6, uint256 p6,) = _organicSell(sell6h);
        assertEq(p6, q6, "the 6 h organic sell paid the quoted bid");
        _checkpoint("6 h", true);

        // to 24 h, 5 min blocks: nothing new lists or sells, the keeper is idle, the bid rides the idle loosening up
        _advance(launchTime + 86400, 300, true);
        _checkpoint("24 h", true);
        assertEq(hourSamples, 24, "every launch hour has a keeper-driven state sample");
        for (uint256 h = 1; h <= 24; ++h) {
            emit log_named_uint("launch hour", h);
            emit log_named_uint("eth bid wei per 100 points", hourRate[h]);
            emit log_named_uint("booked pot wei", hourBooked[h]);
            emit log_named_uint("pending hook income wei", hourPending[h]);
            emit log_named_uint("pile credits", hourPile[h]);
        }
        assertGt(postLatchBooks, 0, "the keeper also books income after the latch");
        console.log("post-latch keeper books in 24 h:", postLatchBooks);

        // compose needs an 80 credit page; the day put far fewer in the pile, so the keeper correctly never composed
        uint256 pile = core.pileSize();
        assertLt(pile, 80, "fewer than a page of credits entered the pile in 24 h");
        assertEq(STATEMENTS.supply(), statementsBefore, "no page composed: the pile never reached 80");
        console.log("credits in the pile at 24 h (a page is 80):", pile);

        _assertTimingOnEveryFill();
    }

    function _assertUnderBidListingsFilled() internal view {
        for (uint256 i; i < lst.length; ++i) {
            if (lst[i].underBidTarget) assertTrue(lst[i].filled, "a listing priced under the opening bid was swept");
        }
    }

    /// every filled listing was bought within LISTING_DELAY plus one tick (two co-sweepable orders fire on consecutive
    /// blocks) of becoming continuously sweepable, and never before the delay elapsed
    function _assertTimingOnEveryFill() internal view {
        for (uint256 i; i < lst.length; ++i) {
            Listing storage l = lst[i];
            if (!l.filled) continue;
            uint256 waited = l.boughtAt - l.sweepAtBuy;
            assertGe(waited, LISTING_DELAY, "the keeper waited the full staleness delay");
            assertLe(waited, LISTING_DELAY + l.stepAtBuy + 24, "and bought within one tick of the delay elapsing");
        }
    }

    /*//////////////////////////////////////////////////////////////
          2. the climb from unbooked income, the main failure
    //////////////////////////////////////////////////////////////*/

    // promise: unbooked fee income makes the opening bid payable without starting the climb clock; the first keeper
    // book starts that clock, and a funded interval with no fill raises the bid
    function test_unbookedIncomeWaitsForBookBeforeBidClimbs() public {
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertEq(address(core).balance, 0, "the fresh engine holds no eth");
        assertEq(core.ethRate(), 0, "an empty pot clamps the live bid to 0 until income arrives");
        assertEq(core.RATE_START(), LAUNCH_RATE, "the stored opening rate the bid climbs from");

        // minute one: a fee burst through the real pool, left unbooked (no door, no book, no fund)
        _advance(launchTime + 60, 12, false);
        _buyCoin(funder, 3 ether);
        _sellCoin(funder, coin.balanceOf(funder) / 3);
        assertGt(_pending(), 0.1 ether, "the hook pushed unbooked fee income");
        assertEq(core.ethPot(), 0, "still nothing booked");

        // before the sniper window ends, no seller or listing opens a door and the keeper has not booked the fees
        _advance(launchTime + 300, 12, false);
        uint256 r5 = core.ethRate();
        assertEq(r5, LAUNCH_RATE, "5 min: unbooked fees do not earn climb time");

        _advance(launchTime + 900, 12, false);
        uint256 r15 = core.ethRate();
        assertEq(r15, r5, "15 min: the funded clock has not started");

        _advance(launchTime + 1740, 12, false);
        uint256 r29 = core.ethRate();
        assertEq(r29, r15, "29 min: pending income still earns no climb");

        assertEq(core.ethPot(), 0, "no door booked in the first 30 minutes");
        assertLe(r29, core.ethPot() + _pendingPot(core.settings()), "the climb stayed inside the pending pot clamp");
        _advance(launchTime + 1800, 12, false);
        assertGt(core.ethPot(), 0, "the keeper booked income at the sniper-window end");
        assertEq(core.ethRate(), r29, "booking did not credit the preceding empty time");
        _advance(launchTime + 2100, 12, false);
        assertGt(core.ethRate(), r29, "the bid climbed over the funded interval");
    }

    // promise: a real Seaport ask exactly at the capped bid is legal but supplies no gap to pay the keeper, so the
    // keeper's profit gate leaves it idle even after the listing delay
    function test_equalAskAtCappedBidRemainsIdleForTheKeeper() public {
        _buyCoin(funder, 3 ether);
        vm.prank(keeper);
        core.book();
        vm.warp(launchTime + 24 hours);
        uint256 bid = core.ethRate();
        assertEq(bid, core.settings().rateCap, "the bid has reached its hard cap");
        _placeSeaport(bid, false);
        _advance(launchTime + 24 hours + 10 minutes, 12, false);
        assertFalse(lst[0].filled, "zero gap never clears the keeper's gas and margin gate");
        assertEq(lst[0].sweepSince, 0, "the keeper never begins the listing delay");
        assertEq(core.pileSize(), 0, "no purchase entered the pile");
        emit log_named_uint("equal ask and capped bid wei", bid);
    }

    // promise: after a keeper fills one real Seaport page from hook-funded income, the first keeper compose can make
    // a Statement once the launch credit sale window has elapsed
    function test_firstComposeFromKeeperBoughtRealSeaportPage() public {
        _buyCoin(funder, 3 ether);
        uint256 supplyBefore = STATEMENTS.supply();
        for (uint256 i; i < 80; ++i) {
            _placeSeaportRealScore(1);
            Listing storage l = lst[i];
            assertGt(core.bidOf(l.id), l.price + 0.0003 ether, "a real-score listing pays the keeper");
            vm.prank(keeper);
            core.buyListing(l.adapter, l.id, l.params);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
        }
        assertEq(core.pileSize(), 80, "the keeper bought one complete page");
        (bool ready,,) = ctl.nextPage();
        assertFalse(ready, "launch credit sales hold fresh Credits through their window");
        vm.warp(block.timestamp + ctl.creditWindow());
        (ready,,) = ctl.nextPage();
        assertTrue(ready, "the first page is eligible after the sale window");
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supplyBefore + 1);
        assertEq(core.pileSize(), 0);
    }
}

/// @notice a seven day launch driven by buyers: credit sale buyers each hour, statement buyers at the decayed price on
/// day 2 and day 5, pages composing between, sales paying the artist and operator cuts and 25 percent of the rest to the
/// buyback, buybacks firing, and the payee latching through a book door. the eth bid view equals the next fill at every
/// day. events are stepped in large jumps between the active hours, so the fork work stays small
contract LaunchDayBuyersTest is LaunchDayBase {
    using FixedPointMathLib for uint256;

    address internal creditBuyer;
    address internal statementBuyer;
    uint256 internal pagesComposed;
    uint256 internal buybacks;

    function setUp() public override {
        super.setUp();
        // the buyers scenario books after every swap, so the pot funds the climbing bid and the composed pages
        autoBook = true;
        creditBuyer = _user("launchday.creditbuyer");
        statementBuyer = _user("launchday.statementbuyer");
        statementsBefore = STATEMENTS.supply();
        _setCreditSaleOn(true);
    }

    // promise: SPEC 1 the buyers path: credit and statement sales split to the artist, operator and buyback, pages
    // compose over the week, buybacks fire, the payee latches through a door, and ethRate() is the next fill at each day
    function test_sevenDaysWithBuyers() public {
        // the window closes, then the first fee income books and latches the payee share through the book door
        _skipSniperWindow();
        _fundPot(2 ether);
        assertTrue(core.payeeOn(), "the first post-window book latched the payee share");

        // two pages of credits enter the pile for the week's composes
        _fillEthPile(85);
        _fillEthPile(85);
        assertGe(core.pileSize(), 160, "two pages of credits are in the pile");

        // day 0 active hours: a credit sale buyer buys one pile credit each hour at the quoted price
        uint256[] memory page = core.pilePage(0, 10);
        for (uint256 h; h < 3; ++h) {
            _buyCreditChecked(page[h], h == 0);
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
        }
        _dayCheckpoint("day 0");

        // day 1: past the credit window, compose page one
        _warpTo(launchTime + 1 days);
        _composePage();
        uint256 sid1 = STATEMENTS.supply();
        _dayCheckpoint("day 1");

        // day 2: a statement buyer buys the composed statement at its decayed price, then a buyback fires
        _warpTo(launchTime + 2 days);
        _buyStatementChecked(sid1);
        _fireBuyback();
        _dayCheckpoint("day 2");

        // day 4: compose page two
        _warpTo(launchTime + 4 days);
        _composePage();
        uint256 sid2 = STATEMENTS.supply();
        _dayCheckpoint("day 4");

        // day 5: a second statement buyer at the decayed price, another buyback
        _warpTo(launchTime + 5 days);
        _buyStatementChecked(sid2);
        _fireBuyback();
        _dayCheckpoint("day 5");

        // day 7: idle to the week's end
        _warpTo(launchTime + 7 days);
        _dayCheckpoint("day 7");

        assertEq(pagesComposed, 2, "two pages composed over the week");
        assertGe(buybacks, 2, "a buyback fired after each statement sale");
        console.log("pages composed:", pagesComposed);
        console.log("buybacks fired:", buybacks);
    }

    /// @dev warps to `ts` and advances one block, for the large steps between the active hours
    function _warpTo(uint256 ts) internal {
        if (block.timestamp < ts) vm.warp(ts);
        vm.roll(block.number + 1);
    }

    /// @dev a credit sale buyer buys pile credit `id` at the quoted price. when `split`, asserts the artist and operator
    /// cuts come off the payment (250 and 50 bps of the launch settings)
    function _buyCreditChecked(uint256 id, bool split) internal {
        uint256 price = ctl.creditPrice(id);
        vm.deal(creditBuyer, price);
        uint256 art0 = core.artist().balance;
        uint256 op0 = core.payee().balance;
        vm.prank(creditBuyer);
        ctl.buyCredit{value: price}(id);
        assertEq(CREDITS.ownerOf(id), creditBuyer, "the credit sale delivered the credit");
        if (split) {
            assertEq(core.artist().balance - art0, price * 250 / 10_000, "credit sale artist cut");
            assertEq(core.payee().balance - op0, price * 50 / 10_000, "credit sale operator cut");
        }
    }

    /// @dev a statement buyer buys `sid` at its decayed price. asserts the artist and operator cuts and that 25 percent
    /// of the rest goes to the buyback pot
    function _buyStatementChecked(uint256 sid) internal {
        assertTrue(_isHeld(sid), "the statement is held for sale");
        uint256 art0 = core.artist().balance;
        uint256 op0 = core.payee().balance;
        uint256 bb0 = core.ethToBuyback();
        uint256 price = _buy(statementBuyer, sid);
        uint256 toArtist = price * 250 / 10_000;
        uint256 toOperator = price * 50 / 10_000;
        uint256 rest = price - toArtist - toOperator;
        assertEq(core.artist().balance - art0, toArtist, "statement artist cut");
        assertEq(core.payee().balance - op0, toOperator, "statement operator cut");
        assertEq(core.ethToBuyback() - bb0, rest * 2_500 / 10_000, "25 percent of the rest to the buyback");
        assertEq(STATEMENTS.ownerOf(sid), statementBuyer, "the buyer holds the statement");
    }

    /// @dev composes the oldest past-window page as the keeper and checks the pile dropped by one page
    function _composePage() internal {
        vm.fee(composeBasefee);
        uint256 supplyBefore = STATEMENTS.supply();
        uint256 pileBefore = core.pileSize();
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supplyBefore + 1, "a page composed");
        assertEq(core.pileSize(), pileBefore - 80, "80 credits left the pile");
        ++pagesComposed;
    }

    /// @dev fires a buyback as the keeper once the delay has passed, and checks coin was bought and burned
    function _fireBuyback() internal {
        if (core.ethToBuyback() == 0) return;
        vm.roll(block.number + core.settings().buybackDelay + 1);
        uint256 supply0 = coin.totalSupply();
        uint256 bb0 = core.ethToBuyback();
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supply0, "the buyback bought and burned coin");
        assertLt(core.ethToBuyback(), bb0, "the buyback spent from the buyback pot");
        ++buybacks;
    }

    /// @dev the daily checkpoint: the eth bid stays within the cap, and its view equals the next fill a fresh credit pays
    function _dayCheckpoint(string memory tag) internal {
        Settings memory s = core.settings();
        assertLe(core.ethRate(), s.rateCap, string.concat(tag, ": the eth bid stays within the cap"));
        uint256 id = _credits(seller, 1)[0];
        (uint256 quoted, uint256 paid,) = _organicSell(id);
        assertEq(paid, quoted, string.concat(tag, ": the eth bid view equals the next fill"));
        _solvent();
        console.log(tag);
        console.log("  pile size:", core.pileSize());
        console.log("  statements composed:", STATEMENTS.supply() - statementsBefore);
    }
}
