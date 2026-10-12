// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Lane, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {ICoreLens} from "../../src/interfaces/ICoreLens.sol";
import {RateStore} from "../../src/lib/RateStore.sol";
import {Halving} from "../../src/lib/Halving.sol";
import {IArtCoinsMevSkimV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @notice SPEC section 10 as reworked by docs/FLOW.md, one `invariant_` function per item, against the real system on
/// the mainnet fork: the real Core, the live Credits, Statements,
/// CreditStrategy, pool manager and artcoins stack. only the exit module and exit token are stand ins.
///
/// how to run:
///   set -a; . ./.env; set +a
///   forge test --match-path 'test/invariant/*' -vv      # the default, runs 24 and depth 80, a few minutes
///   INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 \
///     forge test --match-contract '.*Deep' -vv           # deeper, only the Deep variants run
/// the defaults come from inline `forge-config` lines on the concrete suites: phase 1 after the sniper window, phase 1
/// starting inside the window (90 percent skim at the start), phase 2 with the exit auction, phase 2 under a hostile
/// controller, and phase 2 under a hostile owner (the owner's calls are frequent and adversarial). an inline line beats
/// an environment variable, so the Deep variants carry no inline config and skip themselves unless INVARIANT_DEEP is
/// set. they are the same suites, only the depth comes from the environment.
/// every `invariant_` function is its own campaign, so cost grows with runs times depth times the number of
/// functions. each campaign starts from the state after `setUp`, which has a funded pot, pre filled piles, held
/// statements, two of them sold and a climbed rate. `-vv` shows the call summary that
/// `invariant_callSummary` logs. the summary also keeps running totals over all runs in this process through the
/// environment, which no revert can undo.
///
/// every swap is a real swap through the live skim hook, which pushes its bounty into the core's receive(). a swap
/// failure is classified by revert selector, and the one that matters, the hook's BidForwardFailed, is a violation
/// of invariant 10.
///
/// the handler never reverts. a failed core call is caught, counted, and checked for leaving state untouched, so
/// a violation recorded in the ghosts cannot be lost to `fail_on_revert = false`.
abstract contract InvariantsBase is InvariantFixture {
    /// the violation codes of the handler, grouped by SPEC item.
    uint256[] internal g1 = [1, 2, 3, 4, 6, 18, 19, 17, 23];
    uint256[] internal g2 = [5];
    uint256[] internal g3 = [7];
    uint256[] internal g4 = [8, 9, 10];
    uint256[] internal g5 = [20];
    uint256[] internal g6 = [11, 12];
    uint256[] internal g7 = [13];
    uint256[] internal g8 = [14, 15, 16, 24, 25];
    uint256[] internal g9 = [22];
    uint256[] internal g10 = [21];
    /// sales through sellTo and buy, and the departures of statements
    uint256[] internal g11 = [7, 8, 26];
    /// locks and handovers
    uint256[] internal g12 = [27, 29];
    /// the fee router: its eth goes only to the engine set at that time, by the flush rule
    uint256[] internal g13 = [28];

    function _zero(uint256[] storage codes) internal view {
        for (uint256 i; i < codes.length; ++i) {
            assertEq(handler.viol(codes[i]), 0, handler.violMsg(codes[i]));
        }
    }

    /// 1. eth leaves the core only as a credit purchase within the ceiling, a `buyListing` payment within the bid less the
    /// cost, keeperFee and keeperMaxBaseFee, the caller payment of `compose`, `composeExit` and `exitStatement` within callerFee,
    /// callerMaxBaseFee and the pot, a buyback slice (the swap input plus the payment to the caller), a refund of
    /// overpayment, or a migration to the successor. every action's balance change is matched to those flows, measured at the
    /// recipients, against the settings in force at that moment (the owner changes them throughout). the inflows are the
    /// hook's skim pushed into receive() during real swaps, including the one the hook pushes back during the buyback, the
    /// fee router's flush, `sellTo` payments and a plain
    /// donation. any other movement is a violation. exit token flows too: it leaves the core only as a bid payment in
    /// sellForExitToken or as an auction slice paid for at or above the quoted coin price.
    function invariant_01_ethOnlyLeavesByAllowedPaths() public view {
        _zero(g1);
    }

    /// 2. no credit is bought above the read, the eth rate taken just before the action. every credit has the same
    /// price, so the sum paid by a batch is at most the number of credits times that read.
    function invariant_02_noCreditAboveTheRead() public view {
        _zero(g2);
    }

    /// 3. a statement leaves the core's control only by a sale at or above the hard floor (cost * saleFloorBps of the
    /// settings in force at the sale) or by an exit that returned at least credits * unitPerCredit. `sellTo` is paid the
    /// decaying ask, at least the hard floor. here the first part: every sold statement was paid at least the hard
    /// floor in force at its sale.
    function invariant_03_noStatementSoldBelowTheHardFloor() public view {
        _zero(g3);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            if (s.status == handler.S_SOLD()) {
                assertGe(s.price, s.floor, "a sale paid less than the hard floor");
            }
        }
    }

    /// 4. every statement ever composed is, at all times, exactly one of: held by the core, sold or exited. the ghost
    /// status is checked against the statements token and the core's own records, and the held count against the core's
    /// list.
    function invariant_04_everyStatementIsInExactlyOnePlace() public view {
        _zero(g4);
        uint256 n = handler.everHeldCount();
        uint256 inRecord;
        for (uint256 i; i < n; ++i) {
            uint256 sid = handler.everHeld(i);
            HandlerBase.SG memory s = handler.statementGhost(sid);
            address o = _ownerOfStatement(sid);
            (bool held, Lane lane, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
            if (s.status == handler.S_HELD()) {
                inRecord++;
                assertEq(o, address(core), "a held statement is not held by the core");
                assertTrue(held, "a held statement is not recorded as held");
                assertEq(cost, s.cost, "held cost basis differs");
                assertEq(uint256(lane), uint256(s.lane), "held lane differs");
                assertEq(composedAt, s.composedAt, "compose time differs");
            } else if (s.status == handler.S_SOLD()) {
                assertEq(o, s.buyer, "a sold statement is not with its buyer");
                assertTrue(!held, "a sold statement is still recorded as held");
                assertGe(s.price, s.floor, "sold below the hard floor");
            } else if (s.status == handler.S_EXITED()) {
                assertTrue(!held, "exited but still held");
                assertEq(o, address(s.module), "an exited statement is not with the module that took it");
                assertGe(s.received, s.required, "exit returned less than credits * unitPerCredit");
            } else {
                revert("an ever held statement has no recorded status");
            }
        }
        assertEq(inRecord, core.heldStatements().length, "held count differs from the core's list");
    }

    /// 5. ethPot + ethToBuyback never exceeds the core's eth balance, and the same for the exit token pots. a sale
    /// books its payment at once, split by saleToBuybackBps, so nothing is owed outside the pots.
    function invariant_05_potsNeverExceedBalances() public view {
        _zero(g5);
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots above balance");
        address t = core.exitToken();
        if (t != address(0)) {
            assertLe(core.xPot() + core.xToBuyback(), _balanceOf(t, address(core)), "exit token pots above balance");
        }
    }

    /// 6. the stored price state and the read follow the model around every action and every warp, against the
    /// settings in force over the interval. the only calls that make the stored rate jump are the owner's `setRate`,
    /// which lands on the rate asked for: a settings call keeps the rate exactly.
    function invariant_06_rateFollowsTheModel() public view {
        _zero(g6);
    }

    /// 7. no spend exceeds the pot at that moment. every purchase of a credit (`sellForEth`, `buyListing`) is checked
    /// against the pot the core held when the purchase began, one credit after the other inside a batch. the read after
    /// every action is at most the pot, so the next fill cannot pay more than the pot. a sale refused above the pot
    /// ends in `PotTooSmall`, an arithmetic panic fails the invariant. the books themselves are checked by invariants 5
    /// and 6 and the pot bookkeeping of invariant 1.
    function invariant_07_noSpendAboveThePot() public view {
        _zero(g7);
    }

    /// 8. the hard rule: across the whole campaign neither the owner address nor any controller address ever gains eth,
    /// coin, credits, statements or exit token from the core, whatever settings the owner chooses. their balances are
    /// compared with what they held at the start (the owner pays gas only). the controllers' attack calls all failed,
    /// their reentry attempts through targets failed, and nobody but the owner changed a setting.
    function invariant_08_ownerAndControllersNeverGain() public view {
        _zero(g8);
        uint256 n = handler.watchedCount();
        address xtoken = core.exitToken();
        for (uint256 i; i < n; ++i) {
            address c = handler.watched(i);
            (uint256 eth, uint256 coin_, uint256 credits_, uint256 statements_, uint256 xt_) = handler.baseOf(c);
            assertLe(c.balance, eth, "owner or controller gained eth");
            assertLe(coin.balanceOf(c), coin_, "owner or controller gained coin");
            assertLe(CREDITS.balanceOf(c), credits_, "owner or controller gained credits");
            assertLe(_statementsBalance(c), statements_, "owner or controller gained statements");
            if (xtoken != address(0)) assertLe(_balanceOf(xtoken, c), xt_, "owner or controller gained exit token");
        }
        bool known;
        for (uint256 i; i < handler.controllerCount(); ++i) {
            if (handler.controllers(i) == core.controller()) known = true;
        }
        assertTrue(known, "the installed controller is not tracked");
    }

    /// 9. coin total supply never increases, and it falls by exactly the coin the eth buyback bought and burned plus
    /// the coin burned out of takers in exit auction fills. coin taxed to the burn address is a transfer, not a
    /// burn: 0xdEaD holds it and the supply does not move. the handler keeps a ghost of the expected supply and the
    /// two burn totals from the token's own transfer events and the auction's events.
    function invariant_09_coinSupplyOnlyFallsByBurns() public view {
        _zero(g9);
        uint256 supply = coin.totalSupply();
        assertLe(supply, core.SUPPLY(), "coin supply rose above its launch supply");
        assertEq(supply, handler.gSupply(), "coin supply differs from the ghost of expected supply");
        assertEq(
            core.SUPPLY() - supply,
            handler.gBurnedByBuyback() + handler.gBurnedByAuction(),
            "supply fell by something other than buyback and auction burns"
        );
        assertGe(coin.balanceOf(Mainnet.DEAD), handler.gDead(), "the burn address lost coin");
        assertEq(coin.balanceOf(Mainnet.DEAD), handler.gDead(), "the burn address holds coin nothing sent it");
        assertEq(coin.balanceOf(address(core)), 0, "the core holds coin");
    }

    /// 10. the core's receive() never reverted in the campaign. every direct send, from an account and from the
    /// hook's address, was accepted, and no real swap died of the hook's BidForwardFailed, which is how a reverting
    /// receive() would show up. swaps that failed for other reasons are counted by selector in the call summary.
    function invariant_10_receiveNeverReverts() public view {
        _zero(g10);
        assertEq(handler.receiveFails(), 0, "receive() reverted");
        uint256 n = handler.swapFailSelCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(handler.swapFailSels(i) != bytes4(keccak256("BidForwardFailed()")), "bid forward failed");
        }
    }

    /// 11. model check: no action the ghost model expected to succeed reverted, and every action it expected to
    /// revert did so with the selector it expected. a core that started refusing calls it used to accept, or refusing
    /// for another reason, would show up here and nowhere else. after a migrate the model expects the six doors to
    /// revert `Retired`; any other outcome there is counted.
    function invariant_11_noUnexpectedReverts() public view {
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            assertEq(
                handler.unexpectedFails(a),
                0,
                string.concat(
                    "unexpected revert in ",
                    handler.actionName(a),
                    ", selector ",
                    vm.toString(handler.lastUnexpected(a))
                )
            );
        }
    }

    /// 12. docs/FLOW.md 9.2: a statement leaves the core only by `sellTo` or by an exit. every ever held statement has
    /// one of the ghost statuses Held, Sold or Exited, a sale through `sellTo` paid at least the hard floor (cost *
    /// saleFloorBps of the settings in force at the sale), and the handler's departure and sale path violation codes
    /// (codes 7, 8 and 26: price, booking by saleToBuybackBps, holder and record of each sale) stay at zero.
    function invariant_12_aStatementOnlyLeavesByASaleOrAnExit() public view {
        _zero(g11);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            uint8 st = s.status;
            assertTrue(
                st == handler.S_HELD() || st == handler.S_SOLD() || st == handler.S_EXITED(),
                "a statement left the core by a path that is not allowed"
            );
            if (st == handler.S_SOLD()) assertGe(s.price, s.floor, "a sale below the hard floor");
        }
    }

    /// 13. the four one way locks (controller, exit module, targets, successor) never come undone and the setter of a
    /// locked door always refuses. the retired flag set by the first `migrate` never clears, and from then on the six
    /// doors (`sellForEth`, `buyListing`, `adopt`, `compose`, `composeExit`, `sellForExitToken`) revert `Retired`. every
    /// former owner has no power over the core or over the controller's sale settings, and the core's owner is the one
    /// the handler last saw accept. the handler checks each of these again on every call to `lockCheck` and
    /// `formerOwnersCheck`.
    function invariant_13_locksAndHandoversNeverComeUndone() public {
        handler.lockCheck();
        handler.formerOwnersCheck();
        _zero(g12);
        assertEq(core.owner(), handler.owner(), "the core owner differs from the last accepted owner");
        assertTrue(core.pendingOwner() != core.owner(), "the pending owner is the owner");
    }

    /// 15. the fee router's eth goes only to the engine the owner set at that time (the payees' parts, the rest to the
    /// engine), whichever engine that is. a flush against an engine that refuses reverts and the eth waits, the lock is
    /// one way, and nothing the router owner does moves an asset or a pot of the core. what the core books from the
    /// router is exactly the engine share of the flush when the engine is the core, and zero when it is not.
    function invariant_15_routerEthOnlyGoesToTheEngineSetAtThatTime() public view {
        _zero(g13);
        assertEq(feeRouter.engine(), handler.gEngine(), "the router engine differs from the last one set");
        assertEq(feeRouter.locked(), handler.gRouterLocked(), "the router lock differs from the ghost");
        assertGe(address(feeRouter).balance, handler.parked(), "eth that waited in the router is gone");
    }

    /// 14. no exit module ever called the core, or the selling controller, successfully from inside an exit. the hostile
    /// module's callouts are compose, composeExit, skim, buyback, buybackExit, exitStatement, adopt, sellForEth,
    /// buyListing, sellTo and the selling controller's sell. every one of them
    /// reverts while the core is inside `exitStatement`, whatever the module does with its gas
    function invariant_14_noCallFromInsideAnExitEverWorked() public view {
        uint256 n = handler.moduleEverCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(!handler.modulesEver(i).calledOk(), "a module made a call into the core that went through");
        }
    }

    /// 16. the eth bid stays open while the core has not migrated. when the read (`ethRate`) is not zero, a one credit
    /// `sellForEth` by a holder succeeds. the check runs after every action
    /// under a snapshot that is reverted, so the state is unchanged. it starts with the flush of the fee router that
    /// every `sellForEth` makes first, so the price is the one the sale itself reads.
    function invariant_16_theBidNeverCloses() public {
        if (core.retired()) return;
        uint256 snap = vm.snapshotState();
        vm.prank(address(core));
        try feeRouter.flush{gas: 1_000_000}() {} catch {}
        (address holder, uint256 id) = _sellable(core.ethPot());
        if (holder == address(0)) {
            vm.revertToState(snap);
            return;
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(holder);
        CREDITS.setApprovalForAll(address(core), true);
        (bool ok, bytes memory why) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        vm.stopPrank();
        vm.revertToState(snap);
        assertTrue(
            ok,
            string.concat(
                "sellForEth refused a credit whose price the pot covers, selector ",
                vm.toString(bytes4(why))
            )
        );
    }

    /// the sale of invariant 16 has a seller in the state `setUp` builds, so its success branch runs in the campaigns
    function test_theBidCheckFindsASeller() public {
        (address holder,) = _sellable(core.ethPot());
        assertTrue(holder != address(0), "no actor holds a credit that the pot covers");
        invariant_16_theBidNeverCloses();
    }

    /// the first credit among the first four of each actor whose price is above zero and at most `afford`
    function _sellable(uint256 afford) internal view returns (address holder, uint256 id) {
        uint256 n = handler.actorCount();
        for (uint256 a; a < n; ++a) {
            address actor = handler.actors(a);
            uint256[] memory held = CREDITS.tokensOf(actor);
            for (uint256 j; j < held.length && j < 4; ++j) {
                uint256 price = core.ethRate();
                if (price != 0 && price <= afford) return (actor, held[j]);
            }
        }
    }

    /// the oldest credit of the pile of `lane`, zero when it is empty
    function _head(Lane lane) internal view returns (uint256) {
        uint256[] memory page = core.pilePage(lane, 0, 1);
        return page.length == 0 ? 0 : page[0];
    }

    function _hostileController() internal view returns (bool) {
        return core.controller() == address(fuzz) && fuzz.hostile();
    }

    /// 17. every credit the core owns is in exactly one place. a credit in a pile is reached by walking that pile from
    /// its head, is recorded as in that pile and in that lane, is owned by the core and appears once across both piles.
    /// each pile holds as many credits as its size says and its walk ends. a credit the core owns outside both piles has
    /// no record and `adopt` puts it into the eth pile. a credit the ghost ever piled that the core does not own has no
    /// record.
    function invariant_17_everyCreditInExactlyOnePlace() public {
        uint256[] memory eth = _walkPile(Lane.Eth);
        uint256[] memory exitIds = _walkPile(Lane.Exit);
        uint256[] memory table = _emptySet(eth.length + exitIds.length);
        for (uint256 i; i < eth.length; ++i) {
            assertTrue(_insert(table, eth[i]), "a credit appears twice in the eth pile");
        }
        for (uint256 i; i < exitIds.length; ++i) {
            assertTrue(_insert(table, exitIds[i]), "a credit is in both piles or twice in the exit pile");
        }
        uint256[] memory owned = CREDITS.tokensOf(address(core));
        uint256[] memory loose = new uint256[](owned.length);
        uint256 looseCount;
        for (uint256 i; i < owned.length; ++i) {
            if (_contains(table, owned[i])) continue;
            (bool inPile,,,) = core.creditInfo(owned[i]);
            assertTrue(!inPile, "a credit recorded as piled is not reached by walking its pile");
            loose[looseCount++] = owned[i];
        }
        assertEq(owned.length, eth.length + exitIds.length + looseCount, "an owned credit is counted twice or missed");
        if (!core.retired()) _adoptable(loose, looseCount);
        uint256 piled = handler.everPiledCount();
        for (uint256 i; i < piled; ++i) {
            uint256 id = handler.everPiled(i);
            if (_creditOwner(id) == address(core)) continue;
            (bool inPile,,,) = core.creditInfo(id);
            assertTrue(!inPile, "a credit the core no longer owns still has a pile record");
        }
    }

    /// the owner of a credit, zero once the credit was burned into a statement
    function _creditOwner(uint256 id) internal view returns (address o) {
        (bool ok, bytes memory out) = address(CREDITS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    /// the credits of a pile from its head to its end. every id is recorded in the pile, is owned by the core, and the
    /// walk takes exactly `pileSize` steps
    function _walkPile(Lane lane) internal view returns (uint256[] memory ids) {
        uint256 size = core.pileSize(lane);
        ids = new uint256[](size);
        uint256 n;
        ids = core.pilePage(lane, 0, size);
        n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            (bool inPile, Lane l,,) = core.creditInfo(id);
            assertTrue(inPile, "a credit of a pile has no pile record");
            assertEq(uint256(l), uint256(lane), "a credit is recorded in another lane than its pile");
            assertEq(CREDITS.ownerOf(id), address(core), "a pile holds a credit the core does not own");
        }
        assertEq(n, size, "a pile walk is shorter than its size");
    }

    /// `adopt` of the credits the core owns without a record puts all of them into the eth pile. undone afterwards
    function _adoptable(uint256[] memory loose, uint256 count) internal {
        if (count == 0) return;
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = loose[i];
        }
        uint256 snap = vm.snapshotState();
        uint256 size = core.pileSize(Lane.Eth);
        vm.prank(address(0xADA9));
        core.adopt(ids);
        assertEq(core.pileSize(Lane.Eth), size + count, "adopt did not pile every unrecorded credit");
        for (uint256 i; i < count; ++i) {
            (bool inPile, Lane l,,) = core.creditInfo(ids[i]);
            assertTrue(inPile && l == Lane.Eth, "an adopted credit is not in the eth pile");
        }
        vm.revertToState(snap);
    }

    /// an open addressing set of ids in memory, sized for `n` entries
    function _emptySet(uint256 n) internal pure returns (uint256[] memory) {
        uint256 cap = 8;
        while (cap < 2 * n + 1) cap *= 2;
        return new uint256[](cap);
    }

    /// false when `id` is already in the set
    function _insert(uint256[] memory table, uint256 id) internal pure returns (bool) {
        uint256 cap = table.length;
        uint256 i = id % cap;
        while (table[i] != 0) {
            if (table[i] == id) return false;
            i = (i + 1) % cap;
        }
        table[i] = id;
        return true;
    }

    function _contains(uint256[] memory table, uint256 id) internal pure returns (bool) {
        uint256 cap = table.length;
        uint256 i = id % cap;
        while (table[i] != 0) {
            if (table[i] == id) return true;
            i = (i + 1) % cap;
        }
        return false;
    }

    /// 18. the eth books balance over the whole run. the pots (`ethPot + ethToBuyback`) at the start of the run plus
    /// every amount booked into them (fee flushes, sale proceeds, sale payments, skims) equal the pots now plus every
    /// amount that left them (credit purchases, tips, exit repayments, buyback spends, migrations). the handler adds
    /// each amount to its ledger where the action measures it at the recipient. unbooked eth, forced eth included, is
    /// outside the sum until `skim` books it.
    function invariant_18_ethConservation() public view {
        assertEq(
            core.ethPot() + core.ethToBuyback() + handler.gEthOut(),
            handler.gEthStart() + handler.gEthIn(),
            "the eth books do not balance: start + booked != pots + paid out"
        );
    }

    /// 19. the price state and the read stay inside the bounds the settings and the state give, with no model of the
    /// climb. the read never exceeds the price state. the price state never exceeds `rateCap` and the ceiling, which is
    /// `ceilBps` of `max(last fill rate, peak now)` grown by `idleLoosenBps` per full 10 minutes since the last fill,
    /// where the peak is `peakRate` halved over the time since `peakTime`. the read is the price state lowered to the pot.
    function invariant_19_bidBounds() public view {
        Settings memory st = core.settings();
        uint256 rate = core.ethRate();
        uint256 price = core.ethPrice();
        assertLe(rate, price, "the read is above the price state");
        uint256 lastFill = core.lastFillTime();
        uint256 idle = block.timestamp > lastFill ? block.timestamp - lastFill : 0;
        uint256 lastFillRate = uint256(vm.load(address(core), RateStore.SLOT));
        uint256 peakTime = uint64(uint256(vm.load(address(core), bytes32(uint256(RateStore.SLOT) + 2))) >> 64);
        uint256 peakRate = uint256(vm.load(address(core), bytes32(uint256(RateStore.SLOT) + 3)));
        uint256 peakNow = Halving.halve(peakRate, block.timestamp > peakTime ? block.timestamp - peakTime : 0, st.peakHalfLife);
        uint256 anchor = lastFillRate > peakNow ? lastFillRate : peakNow;
        uint256 ceiling = anchor * (10_000 + uint256(st.idleLoosenBps) * (idle / 600)) * st.ceilBps / 1e8;
        uint256 cap = ceiling < st.rateCap ? ceiling : st.rateCap;
        assertLe(price, cap, "the price state is above the rate cap and the ceiling");
        uint256 pot = core.ethPot();
        assertLe(rate, pot, "the read is above the pot");
        assertEq(rate, price < pot ? price : pot, "the read is not the price state lowered to the pot");
    }

    /// 20. `CoreLens` reports what the Core and the fee router report. every scalar of `snapshot` equals the
    /// direct read, the flush fields equal the split of the router balance (and an actual flush when the engine is the
    /// core), and `statementsPage` over the held list equals the Core's held list and records, whole and in a window.
    /// the page readiness and the asking prices come from the controller, which a hostile one answers differently from
    /// call to call, and are left out then.
    function invariant_20_lensEqualsTheCore() public {
        ICoreLens.Snapshot memory s = lens.snapshot();
        Settings memory st = core.settings();
        assertEq(s.ethRate, core.ethRate(), "lens ethRate");
        assertEq(s.ethPrice, core.ethPrice(), "lens ethPrice");
        assertEq(s.ethPileSize, core.pileSize(Lane.Eth), "lens ethPileSize");
        assertEq(s.ethPileHead, _head(Lane.Eth), "lens ethPileHead");
        assertEq(s.exitPileSize, core.pileSize(Lane.Exit), "lens exitPileSize");
        assertEq(s.exitPileHead, _head(Lane.Exit), "lens exitPileHead");
        assertEq(s.ethPot, core.ethPot(), "lens ethPot");
        assertEq(s.ethToBuyback, core.ethToBuyback(), "lens ethToBuyback");
        assertEq(s.xPot, core.xPot(), "lens xPot");
        assertEq(s.xToBuyback, core.xToBuyback(), "lens xToBuyback");
        uint256 booked = core.ethPot() + core.ethToBuyback();
        assertEq(s.unbookedEth, address(core).balance > booked ? address(core).balance - booked : 0, "lens unbookedEth");
        assertEq(s.routerBalance, address(feeRouter).balance, "lens routerBalance");
        assertEq(s.routerOwed, feeRouter.totalOwed(), "lens routerOwed");
        assertEq(s.controller, core.controller(), "lens controller");
        assertEq(s.successor, core.successor(), "lens successor");
        assertEq(s.controllerLocked, core.controllerLocked(), "lens controllerLocked");
        assertEq(s.exitModuleLocked, core.exitModuleLocked(), "lens exitModuleLocked");
        assertEq(s.targetsLocked, core.targetsLocked(), "lens targetsLocked");
        assertEq(s.successorLocked, core.successorLocked(), "lens successorLocked");
        _lensFlush(s);
        bool hostile = _hostileController();
        if (!hostile) {
            assertEq(s.ethPageReady, _pageReady(s.controller, Lane.Eth), "lens ethPageReady");
            assertEq(s.exitPageReady, _pageReady(s.controller, Lane.Exit), "lens exitPageReady");
        }
        uint256[] memory held = core.heldStatements();
        assertEq(s.statements.length, held.length, "lens statement count");
        ICoreLens.StatementView[] memory page = lens.statementsPage(0, held.length);
        assertEq(page.length, held.length, "lens page length");
        for (uint256 i; i < held.length; ++i) {
            _lensStatement(s.statements[i], held[i], s.controller, hostile);
            _lensStatement(page[i], held[i], s.controller, hostile);
        }
        if (held.length > 2) {
            uint256 start = held.length / 2;
            ICoreLens.StatementView[] memory part = lens.statementsPage(start, 3);
            uint256 expected = held.length - start < 3 ? held.length - start : 3;
            assertEq(part.length, expected, "lens partial page length");
            for (uint256 i; i < part.length; ++i) {
                assertEq(part[i].id, held[start + i], "lens partial page id");
            }
        }
        assertEq(lens.statementsPage(held.length, 5).length, 0, "lens page past the end");
    }

    /// the flush fields against the split of the router balance read directly, and against an actual flush (undone)
    /// when the engine is the core
    function _lensFlush(ICoreLens.Snapshot memory s) internal {
        uint256 balance = address(feeRouter).balance;
        uint256 owed = feeRouter.totalOwed();
        uint256 toPayees;
        uint256 toCore;
        if (feeRouter.engine() != address(0) && balance > owed) {
            uint256 amount = balance - owed;
            if (feeRouter.splitOn()) {
                (, uint32[] memory ppm) = feeRouter.payees();
                for (uint256 i; i < ppm.length; ++i) {
                    toPayees += amount * ppm[i] / 1_000_000;
                }
            }
            toCore = amount - toPayees;
        }
        assertEq(s.flushToCore, toCore, "lens flushToCore");
        assertEq(s.flushToPayees, toPayees, "lens flushToPayees");
        if (feeRouter.engine() == address(core) && balance > owed) {
            uint256 snap = vm.snapshotState();
            uint256 before = address(core).balance;
            try feeRouter.flush() {
                assertEq(address(core).balance - before, s.flushToCore, "lens flushToCore differs from a flush");
            } catch {}
            vm.revertToState(snap);
        }
    }

    function _pageReady(address ctl, Lane lane) internal view returns (bool ready) {
        (bool ok, bytes memory out) = ctl.staticcall{gas: 500_000}(abi.encodeCall(IControllerV1.nextPage, (lane)));
        ready = ok && out.length >= 82 * 32 && abi.decode(out, (uint256)) == 1;
    }

    /// a statement view against the Core's record and (outside a hostile controller) the asking price
    function _lensStatement(ICoreLens.StatementView memory v, uint256 sid, address ctl, bool hostile) internal view {
        assertEq(v.id, sid, "lens statement id");
        (, Lane lane, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
        assertEq(uint256(v.lane), uint256(lane), "lens statement lane");
        assertEq(v.cost, cost, "lens statement cost");
        assertEq(v.composedAt, composedAt, "lens statement compose time");
        if (hostile) return;
        uint256 asking;
        if (lane == Lane.Eth) {
            (bool ok, bytes memory out) = ctl.staticcall{gas: 200_000}(abi.encodeCall(IControllerV1.priceOf, (sid)));
            if (ok && out.length == 32) asking = abi.decode(out, (uint256));
        }
        assertEq(v.askingPrice, asking, "lens statement asking price");
    }

    /// logs how often each action ran, succeeded and was skipped in this run, and over all runs so far.
    function invariant_callSummary() public view {
        _summary();
    }

    function _summary() internal view {
        console.log("suite", handler.tag());
        console.log("action | attempts | ok | skipped | unexpected fail | totals over all runs: att ok skip unexp");
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            console.log(
                string.concat(
                    handler.actionName(a),
                    " | ",
                    vm.toString(handler.attempts(a)),
                    " | ",
                    vm.toString(handler.successes(a)),
                    " | ",
                    vm.toString(handler.skips(a)),
                    " | ",
                    vm.toString(handler.unexpectedFails(a)),
                    " ",
                    vm.toString(
                        vm.envOr(
                            string.concat("INV_", handler.tag(), "_", handler.actionName(a), "_lastsel"), bytes32(0)
                        )
                    ),
                    " | ",
                    vm.toString(handler.tally(a, "att")),
                    " ",
                    vm.toString(handler.tally(a, "ok")),
                    " ",
                    vm.toString(handler.tally(a, "skip")),
                    " ",
                    vm.toString(handler.tally(a, "unexpected"))
                )
            );
        }
        console.log("eth pot", core.ethPot(), "rate", core.ethRate());
        console.log("owner calls checked", handler.gOwnerCalls(), "refused as expected", handler.gOwnerRefused());
        console.log("statements ever held", handler.everHeldCount(), "held now", core.heldStatements().length);
        console.log("coin supply", coin.totalSupply(), "burned by buybacks", handler.gBurnedByBuyback());
        console.log("burned by auction fills", handler.gBurnedByAuction(), "held by the burn address", handler.gDead());
        console.log("swaps under a skim above baseline", handler.windowSwaps());
        console.log("receive() direct sends", handler.receiveSends(), "failures", handler.receiveFails());
        uint256 f = handler.swapFailSelCount();
        for (uint256 i; i < f; ++i) {
            bytes4 sel = handler.swapFailSels(i);
            console.log("real swap failures by selector", vm.toString(sel), handler.swapFails(sel));
        }
    }

    /*//////////////////////////////////////////////////////////////
                         HANDLER SELF CHECKS
    //////////////////////////////////////////////////////////////*/

    /// dispatches one handler action by number. the arguments mean what the action needs.
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal virtual {
        a = a % 37;
        if (a == 36) return handler.pause(w, x);
        if (a == 35) return handler.adopt(w, x, y);
        if (a == 34) return handler.migrate(w, x);
        if (a == 33) return handler.rescueNft(w, x);
        if (a == 31) return handler.flush(w, x);
        if (a == 32) return handler.repoint(w, x);
        if (a == 25) return handler.buy(w, x, y, z);
        a = a % 25;
        if (a == 0) handler.buyCoin(w, x, y);
        else if (a == 1) handler.sellCoin(w, x, y);
        else if (a == 2) handler.sellForEth(w, x, y, z);
        else if (a == 3) handler.listingStrategy(w, x);
        else if (a == 4) handler.listingHostile(w, x);
        else if (a == 5) handler.warp(w);
        else if (a == 6) handler.roll(w);
        else if (a == 7) handler.compose(w, x);
        else if (a == 8) handler.buyback(w);
        else if (a == 9) handler.skim(w);
        else if (a == 10) handler.donate(w, x);
        else if (a == 11) handler.controllerSeed(w);
        else if (a == 12) handler.controllerSwap(w);
        else if (a == 13) handler.probeController(w);
        else if (a == 14) handler.sellForExit(w, x, y);
        else if (a == 15) handler.composeExit(w, x);
        else if (a == 16) handler.exitStatement(w, x);
        else if (a == 17) handler.buybackExit(w, x);
        else if (a == 18) handler.moduleMode(w);
        else if (a == 19) handler.walletMove(w, x);
        else if (a == 20) handler.setSettings(w, x);
        else if (a == 21) handler.setSettingsInvalid(w, x);
        else if (a == 22) handler.setRate(w, x);
        else if (a == 23) handler.ownerMisc(w, x);
        else handler.replaceModule(w, x);
    }

    /// no action may revert, whatever the inputs. a reverting handler loses its ghost writes and hides violations.
    /// the violation counters must also stay at zero after any single action.
    function testFuzz_handlerNeverReverts(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) public {
        _act(a, w, x, y, z);
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
    }

    uint256 internal _nonce;

    /// calls action `a` with derived seeds until it succeeds once more than before, up to `tries` times.
    function _try(uint256 a, uint256 tries) internal returns (bool) {
        uint256 before = handler.successes(a);
        for (uint256 i; i < tries; ++i) {
            uint256 s = uint256(keccak256(abi.encode(a, i, before, ++_nonce)));
            // the fuzz controller answers from its seed, so a new seed gives new answers
            handler.controllerSeed(s >> 40);
            _act(a, s, s >> 8, s >> 16, s >> 24);
            if (handler.successes(a) > before) return true;
        }
        return false;
    }

    /// a suite where everything reverts proves nothing. this drives every action of the suite to a success.
    /// forge-config: default.gas_limit = 9223372036854775807
    function test_everyActionSucceeds() public virtual {
        _smoke();
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            if (!_available(a)) continue;
            assertGt(handler.successes(a), 0, string.concat("never succeeded: ", handler.actionName(a)));
        }
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
        _summary();
    }

    /// the first successful `migrate` of the handler retires the core. every action that calls one of the six doors
    /// then sends its call, which must revert `Retired` with the books untouched, and no violation or unexpected revert
    /// is recorded
    function test_aRetiredCoreRefusesTheSixDoorActions() public virtual {
        for (uint256 i; i < 300 && !handler.gRetired(); ++i) {
            uint256 s = uint256(keccak256(abi.encode("retire", i)));
            _act(34, s, s >> 8, 0, 0);
        }
        assertTrue(handler.gRetired(), "the handler never migrated");
        assertTrue(core.retired(), "the core is not retired");
        // sellForEth, listingStrategy, listingHostile, compose, adopt, then sellForExit and composeExit in phase 2
        uint8[7] memory doors = [2, 3, 4, 7, 35, 14, 15];
        for (uint256 k; k < doors.length; ++k) {
            if (!_available(doors[k])) continue;
            assertTrue(_try(doors[k], 40), string.concat("no refusal checked: ", handler.actionName(doors[k])));
        }
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
        for (uint256 a; a < handler.actionCount(); ++a) {
            assertEq(handler.unexpectedFails(a), 0, handler.actionName(a));
        }
    }

    /// the sale and owner actions of `HandlerSale` run only in the suites that list them
    function _saleSuite() internal pure virtual returns (bool) {
        return false;
    }

    function _available(uint256 a) internal view returns (bool) {
        if (a == 36) return false;
        if (a >= 31 || a == 25) return true;
        if (a >= 26) return _saleSuite();
        if ((a >= 14 && a <= 18 || a == 24) && !handler.phase2()) return false;
        if (a == 12 && !handler.canSwapController()) return false;
        return true;
    }

    function _smoke() internal virtual {
        // the owner may swap to the fuzz controller at once in the swap suites. switch to it, so the page answers
        if (handler.canSwapController()) {
            assertTrue(_try(12, 20), "no controller swap executed");
            // the swap action may have ended on the plain controller: put the fuzz controller in force by hand
            if (core.controller() != address(fuzz)) {
                vm.prank(handler.owner());
                core.setController(address(fuzz));
            }
        }
        // plain actions
        _try(0, 20);
        _try(1, 20);
        assertTrue(_try(19, 20), "no taxed side pool buy");
        _try(5, 5);
        _try(6, 5);
        _try(9, 5);
        _try(10, 5);
        _try(11, 5);
        _try(13, 5);
        // credits in, so the eth pile reaches 80
        assertTrue(_try(35, 40), "no adopt");
        _try(2, 40);
        _try(2, 40);
        _try(2, 40);
        _try(4, 60);
        // the real listings need the ceiling to clear the price, so warp until one passes. the launch ceiling (110 percent,
        // 2 percent loosening per 10 idle minutes) takes days to reach the price of a real listing, and the launch rate cap
        // (2.67e16) is under the 0.036 eth price of the real CreditStrategy listings: the owner widens both here
        Settings memory wide = core.settings();
        wide.ceilBps = 30_000;
        wide.idleLoosenBps = 2_000;
        wide.rateCap = 1e17;
        handler.setSettingsExact(wide);
        // the real listings need the ceiling to clear the price, so warp until one passes
        for (uint256 i; i < 12 && !_try(3, 20); ++i) {
            handler.warp(uint256(keccak256(abi.encode("w", i))) / 10 * 10 + 1);
        }
        assertTrue(handler.successes(3) > 0, "no real listing was bought");
        // each try draws a controller seed. under the hostile controller a try ends in a compose when the page the
        // controller answers is ready and valid (2 of 14 page modes, 1/7) and the handler gate passes (1/2); the
        // compose then succeeds when the in frame attacks and the statement price answers leave it alone (0.43 of
        // those). measured over 2,800 seeds: 6.8 percent of tries reach a valid compose and 2.96 percent succeed,
        // so the success count is geometric with p = 0.0296. 400 tries fail with probability (1 - p)^400 = 6e-6
        // (5e-5 at the lower end of the measured p).
        assertTrue(_try(7, 400), "compose never succeeded");
        // the statement sale through the controller
        assertTrue(_try(25, 80), "no sale of a held statement");
        if (handler.phase2()) _phase2Smoke();
        // buyback needs buybackDelay blocks after the last one
        vm.roll(block.number + 200);
        assertTrue(_try(8, 60), "no buyback");
        _ownerSmoke();
        _routerSmoke();
    }

    /// the router actions: flushes with the core as engine, then the router owner points the engine at every kind of
    /// target (the core, an engine that takes eth, one that refuses it, bad addresses), flushes against each, swaps keep
    /// working with an engine that refuses, and the engine goes back to the core
    function _routerSmoke() internal {
        assertTrue(_try(31, 20), "no flush");
        for (uint256 m; m < 6; ++m) {
            handler.repoint(m + 6 * 7, m);
            handler.flush(m, 0);
            handler.buyCoin(m, 1, 0);
        }
        assertTrue(_try(32, 20), "no repoint");
        handler.repoint(0, 0);
        assertEq(feeRouter.engine(), address(core), "the engine is back at the core");
        handler.flush(1, 0);
    }

    /// the owner's calls: valid settings across the bounds, refused ones, the rate and the other doors
    function _ownerSmoke() internal {
        assertTrue(_try(20, 20), "no settings change");
        assertTrue(_try(21, 20), "no refused settings");
        assertTrue(_try(22, 20), "no setRate");
        assertTrue(_try(23, 20), "no owner door");
        assertTrue(_try(33, 60), "no rescue of an NFT");
        assertTrue(_try(34, 120), "no migration");
        // the books keep working under the new settings, whatever they are
        for (uint256 i; i < 6; ++i) {
            _try(20, 5);
            _try(5, 5);
            _try(2, 5);
        }
    }

    function _phase2Smoke() internal {
        // an eth lane statement exits only after exitAfter since its compose (105 hours at launch)
        vm.warp(block.timestamp + 106 hours);
        assertTrue(_try(16, 80), "no exit");
        assertTrue(_try(14, 60), "no exit token sale");
        _try(14, 60);
        assertTrue(_try(15, 80), "no exit lane compose");
        assertTrue(_try(18, 20), "no module mode");
        // the owner replaces the exit module: a new one, the same one with a new unit, and the refusals
        assertTrue(_try(24, 40), "no module replacement");
        for (uint256 i; i < 8; ++i) {
            handler.replaceModule(i * 7919 + 1, i);
        }
        // the auction opens at the whole coin supply for one slice and halves every 6 hours. wait until a taker can
        // afford a fill with a little coin bought in the real pool
        for (uint256 i; i < 120 && handler.successes(17) == 0; ++i) {
            _try(17, 4);
            vm.warp(block.timestamp + 1 hours);
        }
        assertGt(handler.successes(17), 0, "no exit auction fill");
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    function _ownerOfStatement(uint256 sid) internal view returns (address o) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", sid));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    function _statementsBalance(address a) internal view returns (uint256) {
        return _balanceOf(address(STATEMENTS), a);
    }

    function _balanceOf(address token, address a) internal view returns (uint256 b) {
        (bool ok, bytes memory out) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", a));
        if (ok && out.length == 32) b = abi.decode(out, (uint256));
    }
}

/// phase 1 after the sniper window: the exit module slot is empty, the controller is ControllerV1 and may be swapped
/// for the fuzz controller in benign mode at once. the owner setup came a week, so the skim is
/// the 10 point baseline.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1 is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, false, "p1");
    }

    /// the storage slots used by the handler match the public getters.
    function test_storageLayoutMatchesTheHandlerSlots() public view {
        assertEq(uint256(vm.load(address(core), bytes32(uint256(6)))), core.ethPot());
        assertEq(uint256(vm.load(address(core), bytes32(uint256(10)))), core.rateAtCheckpoint());
        assertEq((uint256(vm.load(address(core), bytes32(uint256(11)))) >> 64) & type(uint64).max, core.lastFillTime());
    }
}

/// the same suite for deep runs. it has no inline config, so it takes its runs and depth from the environment or
/// from foundry.toml, and it skips itself unless INVARIANT_DEEP is set. see the header of this file.
contract InvariantsPhase1Deep is InvariantsPhase1 {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}

/// phase 1 starting inside the sniper window: setUp ends a few seconds after launch, the pot, the piles and the
/// statements were all built under a 90 percent skim, and the owner has allowed the hostile target. the run begins
/// with the skim near its maximum and the handler may switch the controller at any time.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1Window is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, true, "w1");
    }

    /// the run starts inside the window with the skim well above the baseline
    function test_startsInsideTheSniperWindow() public view {
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW / 2);
        assertGt(_skimBpsNow(), 690);
    }

    function _skimBpsNow() internal view returns (uint256) {
        (uint24 bps,) = IArtCoinsMevSkimV2(lc.mevModule).currentSkimBps(poolId);
        return bps;
    }

    /// everything the money side does inside the window first, then the standard smoke after a week
    function _smoke() internal override {
        assertGt(_skimBpsNow(), 690);
        _try(0, 20);
        _try(1, 20);
        _try(2, 40);
        _try(2, 40);
        _try(9, 5);
        _try(10, 5);
        assertTrue(_try(7, 80), "no compose inside the window");
        // statements composed inside the window are for sale at once
        assertTrue(_try(25, 80), "no sale inside the window");
        for (uint256 i; i < 5; ++i) {
            _try(0, 10);
        }
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW, "the window closed during the smoke");
        assertGe(handler.windowSwaps(), 3, "too few swaps ran under the high skim");
        // the compose used the pile up, so fill it again for the compose of the standard smoke
        for (uint256 i; i < 30 && core.pileSize(Lane.Eth) < 80; ++i) {
            _try(2, 10);
        }
        assertGe(core.pileSize(Lane.Eth), 80, "the pile did not refill");
        vm.warp(block.timestamp + 7 days + 1);
        vm.roll(block.number + 7 days / 12);
        super._smoke();
    }
}

/// the same suite for deep runs. no inline config, skipped unless INVARIANT_DEEP is set.
contract InvariantsPhase1WindowDeep is InvariantsPhase1Window {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}
