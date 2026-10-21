// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {Fixture} from "./utils/Fixture.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet, Settings, BUYBACK_GAS} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsMevSkimV2, IArtCoinsFactoryV2, IArtCoinsFeeEscrowV2} from "../src/interfaces/ArtCoinsV2.sol";
import {SwapMidListing} from "./attackers/SwapMidCall.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";

/// shared helpers for the fee, buyback, auction and tax suites, with NO setUp so the two family bases (one live, one
/// fresh deploy) each supply the only setUp in their linearization. every swap goes through the real pool
abstract contract FeeHelpers is Fixture {
    enum Kind {
        BuyExactIn,
        BuyExactOut,
        SellExactIn,
        SellExactOut
    }

    /// @dev what one swap did. `bountyRise` is the bounty leg the hook pushed to the core, `potRise` what the core booked
    /// to the pot at the book after the swap (the payee share, the buyback share and the redeem burn share taken off),
    /// `toPayee` what the book pushed to the payee
    struct Flow {
        uint256 gross;
        uint256 potRise;
        uint256 bountyRise;
        uint256 toPayee;
        uint256 skimVolume;
        uint256 skimBounty;
        uint256 skimProtocol;
        uint256 skimReferral;
    }

    address internal trader;

    /// @dev what the book does with income `amount` right now: the payee share (only once the payee share is on) and
    /// the rest. mirrors `Core._book` from the core's own getters
    function _payeeSplit(uint256 amount) internal view returns (uint256 toPayee, uint256 toEngine) {
        if (core.payeeOn()) toPayee = amount * core.settings().payeePpm / 1_000_000;
        toEngine = amount - toPayee;
    }

    /// @dev the part of an engine inflow `toEngine` (the income less the payee share) the book adds to the pot: the
    /// redeem burn share, bps of the inflow, is taken off first
    function _toPot(uint256 toEngine) internal view returns (uint256) {
        Settings memory s = core.settings();
        return toEngine - toEngine * s.feeToRedeemBurnBps / 10_000;
    }

    /// @dev runs one swap of `kind`, then books. `amount` is eth in for BuyExactIn, coin out for
    /// BuyExactOut, coin in for SellExactIn and eth out for SellExactOut. the gross eth notional is measured from the
    /// swap, not from the hook
    function _flow(Kind kind, uint256 amount, bytes memory data) internal returns (Flow memory f) {
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        uint256 pm = address(PM).balance;
        if (kind == Kind.SellExactIn || kind == Kind.SellExactOut) {
            vm.prank(trader);
            coin.approve(address(router), type(uint256).max);
        }
        vm.recordLogs();
        vm.startPrank(trader);
        if (kind == Kind.BuyExactIn) {
            router.swapWithData{value: amount}(launchKey, true, -int256(amount), trader, data);
            f.gross = amount;
        } else if (kind == Kind.BuyExactOut) {
            BalanceDelta d = router.swapWithData{value: 500 ether}(launchKey, true, int256(amount), trader, data);
            f.gross = uint256(uint128(-d.amount0()));
        } else if (kind == Kind.SellExactIn) {
            router.swapWithData(launchKey, false, -int256(amount), trader, data);
            f.gross = pm - address(PM).balance;
        } else {
            router.swapWithData(launchKey, false, int256(amount), trader, data);
            f.gross = pm - address(PM).balance;
        }
        vm.stopPrank();
        _readSkim(f, vm.getRecordedLogs());
        f.bountyRise = address(core).balance - bal;
        uint256 payeeBefore = core.payee().balance;
        _book();
        f.toPayee = core.payee().balance - payeeBefore;
        f.potRise = core.ethPot() - pot;
    }

    function _readSkim(Flow memory f, Vm.Log[] memory logs) internal view {
        bytes32 sig = keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == v2.hook && logs[i].topics[0] == sig) {
                (f.skimVolume, f.skimBounty, f.skimProtocol, f.skimReferral) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }

    /// @dev steady state expectation for a gross eth notional: 690 bps of skim, 90 percent of it (the bounty leg) to the
    /// core, the rest the protocol leg
    function _expected(uint256 gross) internal pure returns (uint256 toCore, uint256 toProtocol) {
        uint256 skim = gross * 690 / 10_000;
        toCore = skim * 9_000 / 10_000;
        toProtocol = skim - toCore;
    }

    /// @dev moves past the sniper window, then gives the trader coin and the pool about 18 eth of depth. the first book
    /// after the window turns the payee share on. its `_buyCoin` books, so any fee income unbooked at the pin is booked too
    function _stock() internal {
        _skipToPayeeStart();
        _buyCoin(trader, 20 ether);
    }

    /// @dev the eth buyback pot gets filled the real way: a composed statement is bought through the controller at its
    /// asking price, and the core books the proceeds, which the split divides
    function _fillEthBuyback() internal returns (uint256 toBuyback) {
        Composed memory c = _composeOnce();
        address buyer = _user("statement buyer");
        uint256 before = core.ethToBuyback();
        _buy(buyer, c.sid);
        toBuyback = core.ethToBuyback() - before;
    }

    /// @dev one more statement composed and bought, the way real fees and sales fill the buyback pot
    function _anotherSale() internal {
        _fillEthPile(80);
        // the freshly sold credits must age past the live credit window before the controller will compose them
        _warp(ctl.creditWindow() + 1);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _buy(trader, sid);
    }
}

/// the live base for ported steady state tests: the live Core/controller/coin/pool from LiveFixture, bound to the
/// v2-mainnet stack the live coin runs on. the diamond `FeeHelpers, LiveFixture` resolves because LiveFixture's
/// `_enterPhase2` is virtual; both inherited functions are named in the override specifier the compiler demands
abstract contract FeeBase is FeeHelpers, LiveFixture {
    function setUp() public virtual override(Fixture, LiveFixture) {
        super.setUp();
        // book any fee income unbooked at the pin so the pot and skim deltas in the ported tests start from clean
        // books, and age the live credit pile past the credit window (creditSaleOn is live) so the first compose of a
        // ported test is ready. the fresh launch base does not do this: its window tests need the sniper window open
        core.book();
        _warp(ctl.creditWindow() + 1);
        trader = _user("trader");
        vm.deal(trader, 1000 ether);

        // the live coin runs on the v2-mainnet stack. read its record directly (not V2Stack.live()/attach(), which are
        // STACK-env dependent and would read the master record). the Fixture fields FACTORY/ESCROW follow from it
        string memory j = vm.readFile("script/config/v2-mainnet.json");
        v2.owner = vm.parseJsonAddress(j, ".owner");
        v2.escrow = vm.parseJsonAddress(j, ".escrow");
        v2.hook = vm.parseJsonAddress(j, ".hook");
        v2.mev = vm.parseJsonAddress(j, ".mevModule");
        v2.factory = vm.parseJsonAddress(j, ".factory");
        v2.controller = vm.parseJsonAddress(j, ".feeController");
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        ESCROW = IArtCoinsFeeEscrowV2(v2.escrow);
        assertEq(v2.hook, core.HOOK(), "the live coin runs on the v2-mainnet stack");

        // the test listing adapter the raw buy path needs; LiveFixture does not add it. etched at a namespaced address
        rawAdapter = _user("rawAdapter");
        vm.etch(rawAdapter, vm.getDeployedCode("RawListingAdapter.sol:RawListingAdapter"));
        vm.prank(owner);
        core.addAdapter(rawAdapter);
    }

    /// the diamond inherits `_enterPhase2` from both Fixture (virtual) and LiveFixture (virtual override), so FeeBase
    /// must resolve it. the fee suites never call it; super reaches LiveFixture's live phase 2 entry
    function _enterPhase2() internal override(Fixture, LiveFixture) {
        super._enterPhase2();
    }
}

/// the fresh launch base for tests that need an open sniper window, an unlatched payee, a cold empty engine or an etch
/// over the pool manager, none of which the live Core can reach
abstract contract FeeBaseFixture is FeeHelpers {
    function setUp() public virtual override {
        super.setUp();
        trader = _user("trader");
        vm.deal(trader, 1000 ether);
    }
}

/// fee flow of the real v2 skim hook into the core, steady state on the live core
contract FeeFlowTest is FeeBase {
    // promise: SPEC 1 payee 0 at launch, protocol 0.69 percent, engine the rest
    /// the protocol leg of the skim (0.69 percent) belongs to the v2 protocol controller, by push
    /// or by escrow credit
    function test_protocolLegGoesToTheProtocolController() public {
        _stock();
        address ctlr = v2.controller;
        uint256 before = ctlr.balance + ESCROW.balances(ctlr, address(0));
        Flow memory f = _flow(Kind.BuyExactIn, 5 ether, "");
        uint256 got = ctlr.balance + ESCROW.balances(ctlr, address(0)) - before;
        assertEq(got, f.skimProtocol);
        // 5 eth * 690 bps = 0.345 eth of skim, the protocol keeps 1000 of 10_000: 0.0345 eth
        assertEq(got, 5 ether * 690 / 10_000 * 1000 / 10_000);
    }

    // promise: SPEC 4 every door books pending fee eth before it prices
    /// every door books first, and the quote of `ethRate()` counts the fees that reached the core and are not booked yet:
    /// the sale at a door pays exactly the quoted rate
    function test_aDoorBooksTheFeesFirstAndPaysTheQuote() public {
        _stock();
        // payeePpm is 0 at launch (decision 120); the owner raises it so the door's book credits the payee, the evidence here
        Settings memory sp = core.settings();
        sp.payeePpm = 90_909;
        _setSettings(sp);
        autoBook = false;
        uint256[] memory ids = _credits(seller, 1);
        _buyCoin(trader, 5 ether);
        uint256 booked = _tracked();
        assertGt(address(core).balance, booked, "the fees are unbooked");
        // the payout by the hand formula, not bidOf: ethRate (the booked pot's rate) times the credit's score over refScore
        uint256 quote = (core.ethRate() * _scoreOf(ids[0])) / RATE_SCORE;
        assertTrue(_scoreOf(ids[0]) != RATE_SCORE, "the fork credit's score is not refScore");
        uint256 payeeBefore = core.payee().balance;
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - before, quote, "the door paid the quote");
        assertGt(core.payee().balance, payeeBefore, "the door pushed the payee share first");
        assertEq(address(core).balance, _tracked(), "every wei is booked");
    }

    // promise: SPEC 1 an empty pot never raises the price: receive checkpoints first
    /// the rate is checkpointed when the fee arrives, before the pot grows
    function test_rateCheckpointsOnFeeReceipt() public {
        _stock();
        // pin the pot multiplier to 1x so the fee inflow's pages pot does not move the ceiling loosening between the
        // read and the fee book; this test is the fee checkpoint, not the pot scaled climb
        Settings memory cfg = core.settings();
        cfg.climbMultiplierCapBps = 10_000;
        _setSettings(cfg);
        _fundPot(1 ether);
        vm.warp(block.timestamp + 6 hours);
        uint256 rateBefore = core.ethRate();
        assertGt(rateBefore, core.RATE_START(), "the rate climbed while funded");
        assertLt(core.checkpointTime(), block.timestamp);
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(core.checkpointTime(), block.timestamp, "checkpoint time moved to the fee");
        assertEq(core.rateAtCheckpoint(), rateBefore, "the climbed rate was locked in before the pot grew");
    }
}

/// the two fee flow promises that need a fresh launch: the window split with the payee 0 at launch, and the whole anti
/// sniper window. the live pool's window is long closed and its payee is already latched, so these stay on a fresh deploy
contract FeeFlowLaunchTest is FeeBaseFixture {
    // promise: SPEC 1 payee 0 at launch, protocol 0.69 percent, engine the rest
    /// the full split at launch values, per 1 eth of volume (multiply by 100 for 100 eth), steady state and inside the anti
    /// sniper window. baseline skim 6.9 percent: protocol 0.69 and core 6.21.
    /// steady state, payee 0 at launch, so the engine keeps the 6.21 percent Core inflow.
    /// window, skim starts at 69 percent (the v2-mainnet mev module's sniper start, not 90): protocol remains 0.69
    /// percent, the core gets 68.31 percent (0.0621 baseline bounty plus the 0.621 window extra)
    function test_launchSplitPerHundredEthOfVolume() public {
        Flow memory w = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(w.skimProtocol * 100, 0.69 ether, "window: protocol 0.69 per 100 eth");
        assertEq(w.bountyRise * 100, 68.31 ether, "window: core 68.31 per 100 eth");
        assertEq(w.toPayee, 0, "window: no payee share");

        _stock();
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.skimProtocol * 100, 0.69 ether, "protocol 0.69 per 100 eth");
        assertEq(f.bountyRise * 100, 6.21 ether, "core 6.21 per 100 eth");
        assertEq(f.toPayee, 0, "no payee share at launch");
        assertEq(f.skimProtocol + f.bountyRise, 0.069 ether, "protocol and core are the 6.9 percent skim");
        assertEq(f.bountyRise - f.toPayee, uint256(62_100_000_000_000_000) - f.toPayee, "the engine part is the rest");
    }

    // promise: SPEC 4 the anti sniper window extra reaches the pot, the payee takes none of it
    /// the extra of the anti sniper window all reaches the core, and through it the pot, the payee takes nothing of it
    function test_sniperWindowExtraLandsInThePot() public {
        (uint24 bps,) = IArtCoinsMevSkimV2(v2.mev).currentSkimBps(poolId);
        assertEq(bps, 6_900);
        assertFalse(core.payeeOn(), "no payee share in the window");
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        uint256 base = 1 ether * 690 / 10_000;
        uint256 bountyShare = base * 9_000 / 10_000;
        uint256 extra = 1 ether * uint256(bps) / 10_000 - base;
        assertEq(f.bountyRise, bountyShare + extra, "the whole extra goes to the bounty recipient");
        assertEq(f.skimProtocol, base - bountyShare, "the protocol leg does not grow in the window");
        assertEq(f.toPayee, 0);
        assertEq(f.potRise, _toPot(f.bountyRise), "the pot gets the window inflow less the redeem burn share");
        assertApproxEqAbs(f.potRise, _toPot(0.6831 ether), 0.005 ether);
        assertFalse(core.payeeOn());

        // halfway through the window the rate is halfway between 69 and the 6.9 percent baseline
        vm.warp(launchTime + SNIPER_WINDOW / 2);
        (bps,) = IArtCoinsMevSkimV2(v2.mev).currentSkimBps(poolId);
        assertEq(bps, 6_900 - (6_900 - 690) / 2);
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.bountyRise, bountyShare + 1 ether * uint256(bps) / 10_000 - base);
        assertEq(f.toPayee, 0);

        // sells pay the extra too
        f = _flow(Kind.SellExactIn, coin.balanceOf(trader) / 4, "");
        (bps,) = IArtCoinsMevSkimV2(v2.mev).currentSkimBps(poolId);
        assertGt(f.bountyRise, f.gross * 690 / 10_000 * 9_000 / 10_000);

        _skipSniperWindow();
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.bountyRise, 0.0621 ether, "steady state after the window");
    }
}

/// `receive()` is the hook's push target and the escrow's claim target. the hook pushes with 2,300 gas and a revert
/// there makes it credit the escrow, so the body is the sender compare alone. the push is booked by the next book
contract ReceiveTest is FeeBase {
    // promise: inv 10 receive never reverts inside a door
    /// a swap inside the target call of `buyListing`: the hook pushes the bounty to the Core inside the call. the buy
    /// succeeds, the cost is the price, the push stays unbooked until the next book and the books stay consistent
    function test_swapInsideBuyListingLeavesTheFeeForTheNextBook() public {
        SwapMidListing t = new SwapMidListing(router, address(core), launchKey);
        _stock();
        _fundPot(1 ether);
        uint256 id = _credits(address(t), 1)[0];
        // the per-credit bid by the hand formula, not bidOf
        uint256 ceiling = (core.ethRate() * _scoreOf(id)) / RATE_SCORE;
        assertTrue(_scoreOf(id) != RATE_SCORE, "the fork credit's score is not refScore");
        uint256 swapEth = ceiling * 5;
        vm.deal(address(t), swapEth);
        t.arm(id, swapEth);

        uint256 booked0 = _tracked();
        uint256 balance = address(core).balance;
        vm.prank(keeper);
        _buyRaw(ceiling, hex"deadbeef", id, address(t));
        assertEq(CREDITS.ownerOf(id), address(core));
        (, uint256 booked,) = core.creditInfo(id);
        assertEq(
            booked,
            ceiling + ceiling * core.settings().buyToArtistBps / 10_000,
            "no gap, no payment: the cost basis is the price plus its royalty"
        );
        // the price and its artist royalty left the core (decision 163); the push arrived on top
        uint256 royalty = ceiling * core.settings().buyToArtistBps / 10_000;
        uint256 fees = address(core).balance + ceiling + royalty - balance;
        assertGt(fees, 0, "the Core received the push");
        assertEq(_tracked(), booked0 - ceiling - royalty, "the push is not booked inside the call");
        assertEq(address(core).balance - _tracked(), fees, "it waits above the pots");
        _book();
        assertEq(_tracked(), booked0 + fees - ceiling - royalty, "the next book counts the push");
        assertEq(address(core).balance, _tracked(), "every wei is booked");
    }

    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    uint256 internal constant TWENTY_YEARS = 20 * 365 days;

    function _hookSend(uint256 amount) internal returns (bool ok) {
        vm.deal(v2.hook, v2.hook.balance + amount);
        vm.prank(v2.hook);
        (ok,) = address(core).call{value: amount}("");
    }

    // promise: SPEC 4 the hook pushes with the 2,300 gas stipend
    /// the hook pushes with 2,300 gas: the receive of the Core fits it
    function test_receiveFitsTheHookStipend() public {
        vm.deal(v2.hook, 1 ether);
        uint256 bal = address(core).balance;
        vm.prank(v2.hook);
        (bool ok,) = address(core).call{value: 1 ether, gas: 2_300}("");
        assertTrue(ok, "2,300 gas is enough");
        assertEq(address(core).balance - bal, 1 ether);
    }

    // promise: SPEC 4 book gas bound at the worst rate
    /// the worst case for the rate loop: a huge pot, the rate pushed down to its smallest value, twenty years
    /// without a checkpoint. the climb stops at the cap after a few dozen day long steps. the checkpoint runs in the book
    function test_bookGasAfterTwentyYearsAtTheWorstRate() public {
        assertTrue(_hookSend(1 ether));
        _book();
        uint256 slot = stdstore.target(address(core)).sig("rateAtCheckpoint()").find();
        vm.store(address(core), bytes32(slot), bytes32(uint256(1)));
        assertTrue(_hookSend(100_000_000 ether));
        _book();
        vm.warp(block.timestamp + TWENTY_YEARS);
        assertTrue(_hookSend(1 ether));
        uint256 g = gasleft();
        core.book();
        g -= gasleft();
        emit log_named_uint("book gas, 20 years, rate 1, pot 1e8 eth", g);
        assertLt(g, 400_000);
        assertEq(core.rateAtCheckpoint(), core.settings().rateCap, "cap");
    }

    // promise: INTEGRATION UseFund
    /// the hook and the escrow may send eth to `receive`, any other sender reverts `UseFund`. the eth waits above the
    /// pots until the next book, `fund` adds to the pot whole
    function test_onlyTheHookAndTheEscrowMaySend() public {
        // book any fee income unbooked at the pin so the sends below are measured against clean books
        core.book();
        address[2] memory from = [v2.hook, v2.escrow];
        uint256 potBefore = core.ethPot();
        uint256 balBefore = address(core).balance;
        for (uint256 i; i < 2; ++i) {
            vm.deal(from[i], 5 ether);
            vm.prank(from[i]);
            (bool ok,) = address(core).call{value: 1 ether}("");
            assertTrue(ok);
            assertEq(core.ethPot(), potBefore, "the pot does not move until the book");
            assertEq(address(core).balance - balBefore, (i + 1) * 1 ether, "the send raised the balance");
        }
        address stranger = _user("anyone");
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        (bool sent, bytes memory why) = address(core).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(bytes4(why), ICore.UseFund.selector, "a stranger is told to use fund");
        // a zero value send from a stranger reverts too
        vm.prank(stranger);
        (sent, why) = address(core).call("");
        assertFalse(sent);
        assertEq(bytes4(why), ICore.UseFund.selector);
        // the core has no fallback: unknown calls revert
        (sent,) = address(core).call(hex"deadbeef");
        assertFalse(sent);
        assertEq(address(core).balance - balBefore, 2 ether, "nothing else arrived");
        uint256 trackedBefore = _tracked();
        core.book();
        assertEq(_tracked() - trackedBefore, 2 ether, "the book counts both sends");
        // `fund` adds to the pot whole, from anyone
        uint256 pot = core.ethPot();
        vm.prank(stranger);
        core.fund{value: 1 ether}();
        assertEq(core.ethPot() - pot, 1 ether);
        assertEq(address(core).balance, _tracked());
    }
}

/// `receive()` under every setting the owner can reach, and in the middle of every call that measures
contract ReceiveSettingsTest is FeeBase {
    using FixedPointMathLib for uint256;

    function _hookSend(uint256 amount) internal returns (bool ok) {
        vm.deal(v2.hook, v2.hook.balance + amount);
        vm.prank(v2.hook);
        (ok,) = address(core).call{value: amount}("");
    }

    function _pick(uint256 seed, uint256 i, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, i))) % (hi - lo + 1);
    }

    /// @dev random settings inside the bounds for everything the rate and the pot depend on
    function _randomSettings(uint256 seed) internal view returns (Settings memory s) {
        s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPer100PointsBps = uint16(_pick(seed, 2, 1, 1_000));
        s.dropFloorBps = uint16(_pick(seed, 3, 5_000, 10_000));
        s.climbPerMinBps = uint16(_pick(seed, 4, 1, 1_000));
        s.recoveryClimbPerMinBps = uint16(_pick(seed, 12, s.climbPerMinBps, 1_000));
        s.peakHalfLife = uint32(_pick(seed, 13, 600, 604_800));
        s.ceilBps = uint16(_pick(seed, 5, 10_000, 30_000));
        s.idleLoosenBps = uint16(_pick(seed, 9, 1, 2_000));
        s.saleToBuybackBps = uint16(_pick(seed, 7, 0, 10_000));
        s.rateCap = uint64(_pick(seed, 8, 1e13, 1e18));
        s.payeePpm = uint24(_pick(seed, 14, 0, 200_000));
        // forge-lint: disable-end(unsafe-typecast)
    }

    // promise: inv 10 receive never reverts
    /// pots of any size, settings that change between pushes, gaps of any length: the hook push is always accepted and
    /// the book counts it in full, the rate checkpoint moves to the book, and the books stay solvent
    function testFuzz_receiveNeverRevertsAcrossSettings(uint256 seed, uint96 a, uint32 gap1, uint96 b, uint256 gap2)
        public
    {
        gap2 = bound(gap2, 0, 20 * 365 days);
        uint256[3] memory amounts = [uint256(a), uint256(b), uint256(a) + b];
        uint256[3] memory gaps = [uint256(gap1), gap2, uint256(gap1) + gap2];
        // book any fee income unbooked at the pin so the push accounting below starts from clean books
        core.book();
        uint256 booked;
        uint256 trackedStart = _tracked();
        uint256 payeeStart = core.payee().balance;
        for (uint256 i; i < 3; ++i) {
            _setSettings(_randomSettings(uint256(keccak256(abi.encode(seed, i)))));
            if (i == 1) {
                uint256 newRate = _pick(seed, 99, 1e13, core.settings().rateCap);
                vm.prank(owner);
                core.setRate(newRate);
            }
            vm.warp(block.timestamp + gaps[i]);
            uint256 rate = core.ethRate();
            assertTrue(_hookSend(amounts[i]), "receive does not revert");
            _book();
            booked += amounts[i];
            // the payee share is pushed out of the core, the rest stays in the pots (decision 123)
            assertEq(
                _tracked() - trackedStart + (core.payee().balance - payeeStart),
                booked,
                "every push booked or pushed to the payee"
            );
            if (amounts[i] != 0) {
                assertEq(core.checkpointTime(), block.timestamp, "checkpointed at the book");
                assertGe(core.rateAtCheckpoint(), rate, "the price state was locked in first, the read is at most that");
            }
            assertEq(address(core).balance, _tracked());
        }
    }
}

/// the eth buyback of the core against the real pool: it buys coin and burns it on the token
contract BuybackTest is FeeBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
        // a single live statement sale builds a buyback pot of a few ETH, above the live 0.5 ETH slice. raise the slice
        // well above it by the owner setter so one buyback still consumes the whole pot, which these tests assert
        Settings memory s = core.settings();
        s.buybackSlice = 100 ether;
        _setSettings(s);
    }

    struct Before {
        uint256 supply;
        uint256 pmCoin;
        uint256 deadCoin;
        uint256 pot;
        uint256 pool;
        uint256 coreBal;
        uint256 keeperEth;
    }

    function _before() internal view returns (Before memory b) {
        b.supply = coin.totalSupply();
        b.pmCoin = coin.balanceOf(Mainnet.POOL_MANAGER);
        b.deadCoin = coin.balanceOf(DEAD);
        b.pot = core.ethPot();
        b.pool = core.ethToBuyback();
        b.coreBal = address(core).balance;
        b.keeperEth = keeper.balance;
    }

    /// the pot left by a buyback that took the whole pot `pool`: the largest payment less the payment, since the swap
    /// spends the whole budget. reads the logs recorded since the call
    function _residue(uint256 pool) internal returns (uint256 residue) {
        (uint256 spent, uint256 paid) = _buybackEvent(vm.getRecordedLogs());
        uint256 maxPay = 600_000 * block.basefee.min(core.settings().keeperMaxBaseFee) + core.settings().keeperFee;
        assertEq(spent, pool - maxPay, "the swap spends the whole budget");
        residue = maxPay - paid;
    }

    // promise: SPEC 9 buyback burns the coin it buys (inv 9)
    function test_buybackBurnsTheCoinBoughtAndBooksTheSkim() public {
        _stock();
        uint256 toBuyback = _fillEthBuyback();
        vm.fee(5 gwei);
        assertGt(toBuyback, 0);
        assertEq(address(core).balance, _tracked(), "clean books before");
        Before memory b = _before();

        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Flow memory f;
        _readSkim(f, logs);
        (uint256 budget, uint256 paid) = _buybackEvent(logs);

        // the coin left the pool and was burned: total supply fell by exactly what the pool gave up
        uint256 bought = b.pmCoin - coin.balanceOf(Mainnet.POOL_MANAGER);
        assertGt(bought, 0);
        assertEq(b.supply - coin.totalSupply(), bought, "supply fell by exactly the coin bought");
        assertEq(coin.balanceOf(address(core)), 0, "the core holds no coin");
        assertEq(coin.balanceOf(DEAD), b.deadCoin, "the buyback take is untaxed");
        // eth side: the swap and the payment left the pot, the payment went to the caller
        assertEq(core.ethToBuyback(), b.pool - budget - paid, "buyback pot fell by the spend and the payment");
        assertEq(budget, b.pool - (600_000 * 5 gwei + core.settings().keeperFee), "the swap spends the whole budget");
        assertEq(keeper.balance - b.keeperEth, paid, "payment to the caller");
        uint256 feePart = core.settings().keeperFee * budget
            / (core.settings().buybackSlice - (600_000 * 5 gwei + core.settings().keeperFee));
        assertGt(paid, feePart, "the gas refund is paid on top of the fee");
        assertEq((paid - feePart) % 5 gwei, 0, "the refund is counted gas at the base fee");
        // the skim on the buyback reaches the core inside the unlock (6.21 percent of the eth spent) and waits above
        // the pots: the pot is unchanged until the next book
        (uint256 toCore,) = _expected(budget);
        assertEq(core.ethPot(), b.pot, "the skim does not return inside the call");
        assertEq(address(core).balance, b.coreBal - budget - paid + f.skimBounty, "the bounty leg reached the core");
        assertApproxEqAbs(f.skimBounty, toCore, 2, "6.21 percent of the eth spent");
        (, uint256 toEngine) = _payeeSplit(f.skimBounty);
        _book();
        assertEq(
            core.ethPot() - b.pot,
            _toPot(toEngine),
            "the book adds the engine share to the pot, less the buyback and redeem burn shares"
        );
        // the v2 hook reports the volume net of its own skim, so volume plus both legs is the eth spent
        assertApproxEqAbs(f.skimVolume + f.skimBounty + f.skimProtocol, budget, 2);
        assertEq(address(core).balance, _tracked(), "nothing left unbooked");
    }

    // promise: INTEGRATION TooSoon
    /// the launch values: a slice of 1 eth cuts the pot, and 25 blocks must pass between two buybacks. the pot a sale
    /// builds is under one slice, so a buyback takes all of it
    function test_buybackDelayAtLaunchValues() public {
        // the slice is raised above the live sale size in setUp, so one buyback still takes the whole pot
        _stock();
        _fillEthBuyback();
        Before memory b = _before();
        assertLt(b.pool, core.settings().buybackSlice, "a sale builds less than one slice");
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        uint256 residue = _residue(b.pool);
        _book();
        assertEq(core.ethToBuyback(), residue, "the slice was the whole pot, the unused payment margin stays");
        assertEq(core.lastBuybackBlock(), block.number);
        assertEq(address(core).balance, _tracked());

        _anotherSale();
        assertGt(core.ethToBuyback(), 0);
        vm.prank(keeper);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + core.settings().buybackDelay - 1);
        vm.prank(keeper);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        b = _before();
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), _residue(b.pool));
        _book();
        vm.roll(block.number + core.settings().buybackDelay);
        vm.expectRevert(ICore.SliceTooSmall.selector);
        core.buyback();
        assertEq(address(core).balance, _tracked());
    }

    /// @dev puts `eth` into the buyback pot, backed by real eth in the core: the one seam of this file. a statement sale
    /// needs a full page of credits and the sniper window is 69 minutes, so no real sale can fill the pot inside it
    function _forcePot(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    // promise: SPEC 1 with 1 ETH seeded in the buyback pot and a buyback 30 blocks after the buy, selling returns
    // less ETH than spent at 5, 20 and 100 ETH
    function test_buyThirtyBlocksBeforeBuybackThenSellReturnsLessEthAtThreeSizes() public {
        _skipSniperWindow();
        _buyCoin(_user("trader"), 20 ether);
        vm.deal(address(core), address(core).balance + 1 ether);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + 1 ether));
        address attacker = _user("attacker");
        uint256[3] memory xs = [uint256(5 ether), 20 ether, 100 ether];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            vm.deal(attacker, xs[i]);
            vm.prank(attacker);
            router.swap{value: xs[i]}(launchKey, true, -int256(xs[i]), attacker);
            uint256 coinGot = coin.balanceOf(attacker);
            vm.roll(block.number + 30);
            vm.prank(keeper);
            core.buyback();
            assertLt(_sellCoin(attacker, coinGot), xs[i], "sale returns less ETH than the earlier buy spent");
            vm.revertToState(snap);
        }
    }
}

/// pool manager stand in whose `unlock` burns gas, then reports the whole budget spent for `BOUGHT` coin
contract GasBurningManager {
    uint256 internal constant BOUGHT = 1_000e18;

    function unlock(bytes calldata data) external view returns (bytes memory) {
        uint256 end = gasleft() - 3_000_000;
        while (gasleft() > end) {}
        return abi.encode(abi.decode(data, (uint256)), BOUGHT);
    }
}

/// what the caller of `buyback` is paid: counted gas at the base fee, capped, plus the keeper fee
contract BuybackPaymentTest is FeeBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    /// mirrors the private constant `BUYBACK_OVERHEAD_GAS` of the Core
    uint256 internal constant BUYBACK_OVERHEAD_GAS = 60_000;

    function setUp() public override {
        super.setUp();
        _stock();
        _forcePot(1 ether);
    }

    function _forcePot(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    struct Run {
        uint256 pool;
        uint256 spent;
        uint256 paid;
        uint256 gasUsed;
        uint256 callerGain;
        uint256 potAfter;
    }

    /// one buyback by the keeper at `baseFee` and `gasPrice`, with the books read around it
    function _run(uint256 baseFee, uint256 gasPrice) internal returns (Run memory r) {
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        r.pool = core.ethToBuyback();
        uint256 before = keeper.balance;
        vm.recordLogs();
        vm.prank(keeper);
        uint256 g0 = gasleft();
        core.buyback();
        r.gasUsed = g0 - gasleft();
        (r.spent, r.paid) = _buybackEvent(vm.getRecordedLogs());
        _book();
        r.callerGain = keeper.balance - before;
        r.potAfter = core.ethToBuyback();
    }

    function _countedGas(Run memory r, uint256 baseFee) internal view returns (uint256) {
        uint256 refund = r.paid - core.settings().keeperFee;
        assertEq(refund % baseFee, 0, "the refund is a whole number of gas at the base fee");
        return refund / baseFee;
    }

    // promise: SPEC 1 keeper doors pay counted gas plus keeperFee
    function test_callerIsPaidCountedGasAtTheBaseFeePlusTheFee() public {
        Run memory r = _run(4 gwei, 4 gwei);
        assertEq(r.callerGain, r.paid, "the event reports what the caller received");
        uint256 counted = _countedGas(r, 4 gwei);
        emit log_named_uint("counted gas of a full buyback", counted);
        emit log_named_uint("gas used of the call", r.gasUsed);
        // counted gas is the measured part of the call plus the fixed overhead. it covers the transaction base cost on
        // top of the gas of the call, and the overhead bounds what is counted beyond the call
        assertGt(counted, BUYBACK_OVERHEAD_GAS);
        assertLt(counted, BUYBACK_GAS / 2, "the constant is more than twice the counted gas");
        assertGe(counted, r.gasUsed + 15_000, "covers the call and most of the transaction base cost");
        assertLe(counted, r.gasUsed + BUYBACK_OVERHEAD_GAS, "no more than the call plus the overhead");
        // a full slice spends the whole budget and pays the whole fee: the rest is whole gas at the base fee
        assertEq(r.spent, core.settings().buybackSlice - (BUYBACK_GAS * 4 gwei + core.settings().keeperFee));
        assertEq(r.potAfter, r.pool - r.spent - r.paid, "the pot fell by the spend and the payment");
        assertEq(address(core).balance, _tracked(), "no surplus, no deficit");
    }

    /// the pot set to exactly `eth`, backed by the same eth in the core on top of the pot and the redeem burn reserve
    function _setPot(uint256 eth) internal {
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(eth));
        vm.deal(address(core), core.ethPot() + eth + core.ethRedeemBurn());
    }

    // promise: INTEGRATION SliceTooSmall
    /// a slice under twice the largest payment (600,000 gas at the capped base fee plus the fee) reverts, twice that
    /// works. the pot is the slice, as the setting is above it
    function test_sliceUnderTwiceTheLargestPaymentReverts() public {
        uint256 maxPay = BUYBACK_GAS * 5 gwei + core.settings().keeperFee;
        _setPot(2 * maxPay - 1);
        vm.fee(5 gwei);
        vm.prank(keeper);
        vm.expectRevert(ICore.SliceTooSmall.selector);
        core.buyback();
        assertEq(core.ethToBuyback(), 2 * maxPay - 1, "nothing moved");
        _setPot(2 * maxPay);
        Run memory r = _run(5 gwei, 5 gwei);
        assertEq(r.spent, maxPay, "the budget is half the slice");
        assertLe(r.paid, maxPay, "the payment is at most half the slice");
        assertEq(r.potAfter, r.pool - r.spent - r.paid);
        assertEq(address(core).balance, _tracked(), "no surplus, no deficit");
    }
}

/// the gas bound of the counted buyback payment: it etches a gas burning stand in over the pool manager, which
/// overwrites live code, so it stays on a fresh deploy where the pool manager is the fixture's own fork target
contract GasBurnBuybackTest is FeeBaseFixture {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        _stock();
        _forcePot(1 ether);
    }

    function _forcePot(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    struct Run {
        uint256 pool;
        uint256 spent;
        uint256 paid;
        uint256 gasUsed;
        uint256 callerGain;
        uint256 potAfter;
    }

    /// one buyback by the keeper at `baseFee` and `gasPrice`, with the books read around it
    function _run(uint256 baseFee, uint256 gasPrice) internal returns (Run memory r) {
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        r.pool = core.ethToBuyback();
        uint256 before = keeper.balance;
        vm.recordLogs();
        vm.prank(keeper);
        uint256 g0 = gasleft();
        core.buyback();
        r.gasUsed = g0 - gasleft();
        (r.spent, r.paid) = _buybackEvent(vm.getRecordedLogs());
        _book();
        r.callerGain = keeper.balance - before;
        r.potAfter = core.ethToBuyback();
    }

    // promise: SPEC 1 buyback counted gas is bounded by BUYBACK_GAS
    /// the swap path burns 3 million gas: the call uses more than `BUYBACK_GAS`, the counted gas stops at it
    function test_countedGasIsCappedAtTheBuybackGasConstant() public {
        vm.etch(address(PM), address(new GasBurningManager()).code);
        deal(address(coin), address(core), 1_000e18);
        Run memory r = _run(4 gwei, 4 gwei);
        assertGt(r.gasUsed, BUYBACK_GAS + 2_000_000, "the call used far more than the constant");
        assertEq(r.paid, BUYBACK_GAS * 4 gwei + core.settings().keeperFee, "the gas counted stops at the constant");
    }
}

/// the buyback reads its slice, its delay and the keeper fee from the settings, effective at once
contract BuybackSettingsTest is FeeBase {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
        _stock();
        vm.fee(1 gwei);
    }

    /// what the last `_buyback` returned to the pot: the unused part of the slice
    uint256 internal lastMargin;

    /// one buyback by the keeper, checked against the settings. returns the slice taken and the payment
    function _buyback() internal returns (uint256 slice, uint256 paid) {
        Settings memory s = core.settings();
        uint256 pool = core.ethToBuyback();
        slice = pool.min(s.buybackSlice);
        uint256 supply = coin.totalSupply();
        uint256 keeper0 = keeper.balance;
        uint256 pot = core.ethPot();
        uint256 unbooked = address(core).balance - _tracked();
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        uint256 spent;
        (spent, paid) = _buybackEvent(vm.getRecordedLogs());
        assertEq(keeper.balance - keeper0, paid, "the caller got the payment");
        uint256 maxPay = 600_000 * block.basefee.min(s.keeperMaxBaseFee) + s.keeperFee;
        assertGe(
            paid, s.keeperFee * spent / (s.buybackSlice - maxPay), "the payment holds the scaled fee of the setting"
        );
        assertEq(core.ethToBuyback(), pool - spent - paid, "the pot fell by the spend and the payment");
        assertLe(spent + paid, slice, "the slice bounds both");
        assertLt(coin.totalSupply(), supply, "burned");
        assertEq(core.ethPot(), pot, "the skim of the swap waits unbooked");
        assertGt(address(core).balance - _tracked(), unbooked, "the skim of the swap reached the core");
        lastMargin = slice - spent - paid;
        _book();
        assertEq(core.ethToBuyback(), pool - slice + lastMargin, "the unused payment came back");
        assertEq(core.lastBuybackBlock(), block.number);
        assertEq(address(core).balance, _tracked(), "no surplus, no deficit");
    }
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// the restricted v2 token, as far as the credits engine depends on it: the pool is the only way to move coin, the Core
/// is not on the allowlist
contract RestrictedCoinTest is FeeBase {
    TestLiquidityHelper internal lp;

    function setUp() public override {
        super.setUp();
        lp = new TestLiquidityHelper();
        _stock();
    }

    // promise: SPEC 1 the coin is restricted (decisions 53, 83)
    function test_theLaunchIsRestrictedAndTheCoreIsNotAllowlisted() public view {
        assertTrue(coin.restricted());
        assertFalse(coin.isAllowed(address(core)), "the Core is not on the allowlist (FLOW 29)");
        assertFalse(coin.isAllowed(owner));
        assertFalse(coin.isAllowed(trader));
        assertEq(coin.admin(), owner);
    }

    // promise: SPEC 1 coin leaves the Core only through rescueCoin
    /// the Core is off the allowlist, so coin reaches it only from a holder the coin admin lists. the owner can send that
    /// coin on with `rescueCoin`, nobody else can
    function test_coinFromAListedHolderIsRescuedByTheOwner() public {
        uint256 amount = 1_000e18;
        vm.prank(owner);
        coin.setAllowed(trader, true);
        vm.prank(trader);
        coin.transfer(address(core), amount);
        assertEq(coin.balanceOf(address(core)), amount);

        address to = _user("rescue to");
        vm.prank(trader);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.rescueCoin(to, amount);
        // the Core is off the allowlist, so the rescue reaches a listed address only
        vm.prank(owner);
        vm.expectRevert();
        core.rescueCoin(to, amount);
        vm.prank(owner);
        coin.setAllowed(to, true);

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.CoinRescued(to, amount);
        vm.prank(owner);
        core.rescueCoin(to, amount);
        assertEq(coin.balanceOf(to), amount);
        assertEq(coin.balanceOf(address(core)), 0);

        vm.startPrank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.rescueCoin(address(0), 1);
        vm.expectRevert();
        core.rescueCoin(to, 1);
        vm.stopPrank();
    }
}

/// one buy and one sell through the real universal router, the way a wallet or aggregator would trade the coin
contract UniversalRouterTest is FeeBase {
    IUniversalRouter internal constant UR = IUniversalRouter(Mainnet.UNIVERSAL_ROUTER);
    IPermit2 internal constant PERMIT2 = IPermit2(Mainnet.PERMIT2);

    function _v4Swap(bool zeroForOne, uint256 amountIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        Currency cIn = zeroForOne ? launchKey.currency0 : launchKey.currency1;
        Currency cOut = zeroForOne ? launchKey.currency1 : launchKey.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(launchKey, zeroForOne, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    // promise: SPEC 12 buy and sell through the real universal router
    function test_buyAndSellThroughTheUniversalRouter() public {
        _skipSniperWindow();
        // book any fee income unbooked at the pin so the skim deltas below are measured against clean books
        core.book();
        uint256 dead = coin.balanceOf(DEAD);
        uint256 pot = core.ethPot();
        vm.deal(trader, 10 ether);

        // the same buy through the test router in a snapshot gives the reference amount out
        uint256 snap = vm.snapshotState();
        uint256 viaRouter = _buyCoin(funder, 1 ether);
        vm.revertToState(snap);

        vm.prank(trader);
        UR.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 bought = coin.balanceOf(trader);
        assertEq(bought, viaRouter, "same amount out as the plain swapper");
        assertEq(address(core).balance - _tracked(), 0.0621 ether, "skim on the buy: 6.21 percent to the core");
        (, uint256 toEngine) = _payeeSplit(0.0621 ether);
        _book();
        uint256 redeemBurn = toEngine * core.settings().feeToRedeemBurnBps / 10_000;
        assertEq(core.ethPot() - pot, toEngine - redeemBurn, "and the book adds the engine share less the redeem burn");
        assertEq(coin.balanceOf(DEAD), dead, "nothing burned");

        // sell half through permit2, the way the router pulls erc20 input
        uint256 sellIn = bought / 2;
        snap = vm.snapshotState();
        uint256 ethViaRouter = _sellCoin(trader, sellIn);
        vm.revertToState(snap);

        vm.startPrank(trader);
        coin.approve(Mainnet.PERMIT2, type(uint256).max);
        PERMIT2.approve(address(coin), address(UR), uint160(sellIn), uint48(block.timestamp + 1 hours));
        uint256 ethBefore = trader.balance;
        pot = core.ethPot();
        UR.execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 ethOut = trader.balance - ethBefore;
        assertEq(ethOut, ethViaRouter, "same eth out as the plain swapper");
        assertEq(coin.balanceOf(trader), bought - sellIn);
        // a sell skims 6.9 percent of the pool eth out, taken from the seller, 90 percent of it to the core
        uint256 gross = ethOut * 10_000 / 9_310;
        uint256 inflow = address(core).balance - _tracked();
        assertApproxEqAbs(inflow, gross * 690 / 10_000 * 9_000 / 10_000, 3, "skim on the sell");
        (, uint256 eng) = _payeeSplit(inflow);
        _book();
        assertEq(core.ethPot() - pot, _toPot(eng));
        assertEq(coin.balanceOf(DEAD), dead, "nothing burned on the sell either");
    }
}
