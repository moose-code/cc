// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Mainnet, Settings, CreditSale} from "../../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Halving} from "../../src/lib/Halving.sol";
import {IArtCoinsMevSkimV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @notice SPEC section 10 as reworked by docs/DECISIONS.md, one `invariant_` function per item, against the real system on
/// the mainnet fork: the real Core, the live Credits, Statements,
/// CreditStrategy, pool manager and artcoins stack. only the balance module and balance token are stand ins.
///
/// how to run:
///   set -a; . ./.env; set +a
///   forge test --match-path 'test/invariant/*' -vv      # the default, runs 24 and depth 80, a few minutes
///   INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 \
///     forge test --match-contract '.*Deep' -vv           # deeper, only the Deep variants run
/// the defaults come from inline `forge-config` lines on the concrete suites: phase 1 after the sniper window, phase 1
/// starting inside the window (90 percent skim at the start), the balance side, the balance side under a hostile
/// controller, and the balance side under a hostile owner (the owner's calls are frequent and adversarial). an inline line beats
/// an environment variable, so the Deep variants carry no inline config and skip themselves unless INVARIANT_DEEP is
/// set. they are the same suites, only the depth comes from the environment.
/// every `invariant_` function is its own campaign, so cost grows with runs times depth times the number of
/// functions. each campaign starts from the state after `setUp`, which has a funded pot, pre filled piles, held
/// statements, two of them sold and a climbed rate. `-vv` shows the call summary that
/// `invariant_callSummary` logs. the summary also keeps running totals over all runs in this process through the
/// environment, which no revert can undo.
///
/// every swap is a real swap through the live skim hook, which pushes its bounty into the core's receive(), where it
/// waits for the next book. a swap failure is classified by revert selector, and the one that matters, the hook's
/// BidForwardFailed, is a violation of invariant 10.
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
    /// the payee share: the share, the latch and the claim follow the model of the book
    uint256[] internal g13 = [28];

    function _zero(uint256[] storage codes) internal view {
        for (uint256 i; i < codes.length; ++i) {
            assertEq(handler.viol(codes[i]), 0, handler.violMsg(codes[i]));
        }
    }

    /// 1. eth leaves the core only as a credit purchase within the ceiling, a `buyListing` payment within the bid less the
    /// cost, keeperFee and keeperMaxBaseFee, the caller payment of `compose`, `composeChosen` and `redeemStatement` within callerFee,
    /// callerMaxBaseFee and the pot, a buyback slice (the swap input plus the payment to the caller), a refund of
    /// overpayment, or a migration to the successor. every action's balance change is matched to those flows, measured at the
    /// recipients, against the settings in force at that moment (the owner changes them throughout). the inflows are the
    /// hook's skim pushed into receive() during real swaps, including the one the hook pushes back during the buyback,
    /// `sellTo` payments, `fund` and eth forced in. a plain send from anyone but the hook and the escrow reverts. any other
    /// movement is a violation. balance token flows too: it leaves the core only as a bid payment in
    /// sellForBalance.
    function invariant_01_ethOnlyLeavesByAllowedPaths() public view {
        _zero(g1);
    }

    /// 2. no credit is bought above its bid, `bidOf(id)` = the read times the credit's score over refScore, taken just
    /// before the action. the sum paid by a batch is at most the sum of the per-credit bids.
    function invariant_02_noCreditAboveTheRead() public view {
        _zero(g2);
    }

    /// 3. a statement leaves the core's control only by a sale at or above the hard floor (cost * saleFloorBps of the
    /// settings in force at the sale) or by a redemption that returned at least credits * unitPerPoint. `sellTo` is paid the
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

    /// 4. every statement ever composed is, at all times, exactly one of: held by the core, sold or redeemed. the ghost
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
            (bool held, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
            if (s.status == handler.S_HELD()) {
                inRecord++;
                assertEq(o, address(core), "a held statement is not held by the core");
                assertTrue(held, "a held statement is not recorded as held");
                assertEq(cost, s.cost, "held cost basis differs");
                assertEq(composedAt, s.composedAt, "compose time differs");
            } else if (s.status == handler.S_SOLD()) {
                assertEq(o, s.buyer, "a sold statement is not with its buyer");
                assertTrue(!held, "a sold statement is still recorded as held");
                assertGe(s.price, s.floor, "sold below the hard floor");
            } else if (s.status == handler.S_REDEEMED()) {
                assertTrue(!held, "redeemed but still held");
                assertEq(o, address(s.module), "an redeemed statement is not with the module that took it");
                assertGe(s.received, s.required, "redemption returned less than credits * unitPerPoint");
            } else {
                revert("an ever held statement has no recorded status");
            }
        }
        assertEq(inRecord, core.heldStatements().length, "held count differs from the core's list");
    }

    /// 5. ethPot + ethToBuyback + ethRedeemBurn + payeeOwed never exceeds the core's eth balance, and the same for the
    /// balance token pots. a sale books its payment at once, split by saleToBuybackBps, so nothing is owed outside the
    /// pots and the payee claim.
    function invariant_05_potsNeverExceedBalances() public view {
        _zero(g5);
        assertLe(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() + core.payeeOwed(),
            address(core).balance,
            "eth pots above balance"
        );
        // the balance token is held by the module, not the core, so there is no balance pot to bound
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
    /// coin, credits, statements or balance token from the core, whatever settings the owner chooses. their balances are
    /// compared with what they held at the start (the owner pays gas only). the controllers' attack calls all failed,
    /// their reentry attempts through the test adapter failed, and nobody but the owner changed a setting.
    function invariant_08_ownerAndControllersNeverGain() public view {
        _zero(g8);
        uint256 n = handler.watchedCount();
        address xtoken = core.balanceToken();
        for (uint256 i; i < n; ++i) {
            address c = handler.watched(i);
            (uint256 eth, uint256 coin_, uint256 credits_, uint256 statements_, uint256 xt_) = handler.baseOf(c);
            // the first controller holds the royalty it owes between claims, paid by buyers
            assertLe(c.balance, eth + (c == handler.v1() ? IControllerV1(c).royaltyOwed() : 0), "owner or controller gained eth");
            assertLe(coin.balanceOf(c), coin_, "owner or controller gained coin");
            assertLe(CREDITS.balanceOf(c), credits_, "owner or controller gained credits");
            assertLe(_statementsBalance(c), statements_, "owner or controller gained statements");
            if (xtoken != address(0)) assertLe(_balanceOf(xtoken, c), xt_, "owner or controller gained balance token");
        }
        bool known;
        for (uint256 i; i < handler.controllerCount(); ++i) {
            if (handler.controllers(i) == core.controller()) known = true;
        }
        assertTrue(known, "the installed controller is not tracked");
    }

    /// 9. coin total supply never increases, and it falls by exactly the coin the eth buyback bought and burned plus the
    /// coin the swapCredit fee burned. coin taxed to the burn address is a transfer, not a burn: 0xdEaD holds it and the
    /// supply does not move. the handler keeps a ghost of the expected supply and the burn total from the token's own
    /// transfer events.
    function invariant_09_coinSupplyOnlyFallsByBurns() public view {
        _zero(g9);
        uint256 launchSupply = 1_000_000_000e18;
        uint256 supply = coin.totalSupply();
        assertLe(supply, launchSupply, "coin supply rose above its launch supply");
        assertEq(supply, handler.gSupply(), "coin supply differs from the ghost of expected supply");
        assertEq(
            launchSupply - supply,
            handler.gBurnedByBuyback() + handler.gBurnedBySwap(),
            "supply fell by something other than buyback and swap burns"
        );
        assertGe(coin.balanceOf(Mainnet.DEAD), handler.gDead(), "the burn address lost coin");
        assertEq(coin.balanceOf(Mainnet.DEAD), handler.gDead(), "the burn address holds coin nothing sent it");
        assertEq(coin.balanceOf(address(core)), 0, "the core holds coin");
    }

    /// 10. the core's receive() never reverted for the hook or the escrow, and reverted `UseFund` for every other sender.
    /// every send from the hook's address and the escrow's address was accepted, every send from an account was
    /// refused with `UseFund`, and no real swap died of the hook's BidForwardFailed, which is how a reverting
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

    /// 12. docs/DECISIONS.md 9.2: a statement leaves the core only by `sellTo` or by a redemption. every ever held statement has
    /// one of the ghost statuses Held, Sold or Redeemed, a sale through `sellTo` paid at least the hard floor (cost *
    /// saleFloorBps of the settings in force at the sale), and the handler's departure and sale path violation codes
    /// (codes 7, 8 and 26: price, booking by saleToBuybackBps, holder and record of each sale) stay at zero.
    function invariant_12_aStatementOnlyLeavesByASaleOrARedemption() public view {
        _zero(g11);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            uint8 st = s.status;
            assertTrue(
                st == handler.S_HELD() || st == handler.S_SOLD() || st == handler.S_REDEEMED(),
                "a statement left the core by a path that is not allowed"
            );
            if (st == handler.S_SOLD()) assertGe(s.price, s.floor, "a sale below the hard floor");
        }
    }

    /// 13. the four one way locks (controller, balance module, adapters, successor) never come undone and the setter of a
    /// locked door always refuses. the retired flag set by the first `migrate` never clears, and from then on the six
    /// doors (`sellForEth`, `buyListing`, `adopt`, `compose`, `composeChosen`, `sellForBalance`) revert `Retired`. every
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

    /// 15. retired with the fee router (docs/DECISIONS.md decision 109): the pool pays the core directly, so there is no
    /// router whose eth goes to an engine. the numbering of the items stays. the payee share that replaced the router
    /// split is checked under item 18.

    /// 14. no balance module ever called the core, or the selling controller, successfully from inside a redemption. the hostile
    /// module's callouts are compose, book, buyback, releaseRedeemBurn, redeemStatement, adopt, sellForEth,
    /// buyListing, sellTo and sellForBalance, and the selling controller's sell. every one of them
    /// reverts while the core is inside `redeemStatement`, whatever the module does with its gas
    function invariant_14_noCallFromInsideARedemptionEverWorked() public view {
        uint256 n = handler.moduleEverCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(!handler.modulesEver(i).calledOk(), "a module made a call into the core that went through");
        }
    }

    /// 16. the eth bid stays open while the core has not migrated. when a held credit's bid (`bidOf`) is not zero and the
    /// pot covers it, a one credit `sellForEth` by its holder succeeds. the check runs after every action
    /// under a snapshot that is reverted, so the state is unchanged. it starts with the book of the fee income that
    /// every `sellForEth` makes first, so the price is the one the sale itself reads.
    function invariant_16_theBidNeverCloses() public {
        if (core.retired()) return;
        uint256 snap = vm.snapshotState();
        try core.book() {} catch {}
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

    // promise: inv 16 the bid check reaches its success branch
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
                uint256 price = core.bidOf(held[j]);
                if (price != 0 && price <= afford) return (actor, held[j]);
            }
        }
    }

    /// 17. every credit the core owns is in exactly one place. a credit in the pile is reached by walking it from
    /// its head, is recorded as in the pile, is owned by the core and appears once. the pile holds as many credits as
    /// its size says and its walk ends. a credit the core owns outside the pile has no record and `adopt` puts it into
    /// the pile. a credit the ghost ever piled that the core does not own has no record.
    function invariant_17_everyCreditInExactlyOnePlace() public {
        uint256[] memory piled = _walkPile();
        uint256[] memory table = _emptySet(piled.length);
        for (uint256 i; i < piled.length; ++i) {
            assertTrue(_insert(table, piled[i]), "a credit appears twice in the pile");
        }
        uint256[] memory owned = CREDITS.tokensOf(address(core));
        uint256[] memory loose = new uint256[](owned.length);
        uint256 looseCount;
        for (uint256 i; i < owned.length; ++i) {
            if (_contains(table, owned[i])) continue;
            (bool inPile,,) = core.creditInfo(owned[i]);
            assertTrue(!inPile, "a credit recorded as piled is not reached by walking the pile");
            loose[looseCount++] = owned[i];
        }
        assertEq(owned.length, piled.length + looseCount, "an owned credit is counted twice or missed");
        if (!core.retired()) _adoptable(loose, looseCount);
        uint256 everPiled = handler.everPiledCount();
        uint256 inPileNow;
        for (uint256 i; i < everPiled; ++i) {
            uint256 id = handler.everPiled(i);
            (bool inPile,,) = core.creditInfo(id);
            if (inPile) inPileNow++;
            if (_creditOwner(id) == address(core)) continue;
            assertTrue(!inPile, "a credit the core no longer owns still has a pile record");
        }
        // every credit the core marks as in the pile is reached by the pile walk, so the count of in-pile credits is
        // exactly the pile size
        assertEq(inPileNow, core.pileSize(), "the count of in-pile credits differs from the pile size");
    }

    /// the owner of a credit, zero once the credit was burned into a statement
    function _creditOwner(uint256 id) internal view returns (address o) {
        (bool ok, bytes memory out) = address(CREDITS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    /// the credits of the pile from its head to its end. every id is recorded in the pile, is owned by the core, and
    /// the walk takes exactly `pileSize` steps
    function _walkPile() internal view returns (uint256[] memory ids) {
        uint256 size = core.pileSize();
        ids = core.pilePage(0, size);
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            (bool inPile,,) = core.creditInfo(id);
            assertTrue(inPile, "a credit of the pile has no pile record");
            assertEq(CREDITS.ownerOf(id), address(core), "the pile holds a credit the core does not own");
        }
        assertEq(n, size, "a pile walk is shorter than its size");
    }

    /// `adopt` of the credits the core owns without a record puts all of them into the pile. undone afterwards
    function _adoptable(uint256[] memory loose, uint256 count) internal {
        if (count == 0) return;
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = loose[i];
        }
        uint256 snap = vm.snapshotState();
        uint256 size = core.pileSize();
        vm.prank(address(0xADA9));
        core.adopt(ids);
        assertEq(core.pileSize(), size + count, "adopt did not pile every unrecorded credit");
        for (uint256 i; i < count; ++i) {
            (bool inPile,,) = core.creditInfo(ids[i]);
            assertTrue(inPile, "an adopted credit is not in the pile");
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

    /// 18. the eth books balance over the whole run. the pots (`ethPot + ethToBuyback + ethRedeemBurn`) at the start of
    /// the run plus every amount booked into them (fee income less the payee share, sale proceeds, sale payments,
    /// `fund`) equal the pots now plus every amount that left them (credit purchases, tips, redemption repayments, buyback
    /// spends, migrations). the handler adds each amount to its ledger where the action measures it at the recipient.
    /// unbooked eth, forced eth included, is outside the sum until `book` counts it. the payee claim follows the model of
    /// the book: the share is `payeePpm` of the income once the share is on, the first book with income at or after
    /// `launchedAt + SNIPER_SECONDS` turns it on and shares nothing, and `claimPayee` pays exactly the eth owed.
    function invariant_18_ethConservation() public view {
        _zero(g13);
        assertEq(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() + handler.gEthOut(),
            handler.gEthStart() + handler.gEthIn(),
            "the eth books do not balance: start + booked != pots + paid out"
        );
        assertEq(core.payeeOwed(), handler.gPayeeOwed(), "the payee claim differs from the model");
        assertEq(core.payeeOn(), handler.gPayeeOn(), "the payee latch differs from the model");
        assertEq(core.payee(), handler.gPayee(), "the payee differs from the one the owner set last");
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
        (uint256 lastFillRate,,) = _anchor();
        (uint256 peakRate, uint256 peakTime) = _peak();
        uint256 peakNow = Halving.halve(peakRate, block.timestamp > peakTime ? block.timestamp - peakTime : 0, st.peakHalfLife);
        uint256 anchor = lastFillRate > peakNow ? lastFillRate : peakNow;
        uint256 ceiling = anchor * (10_000 + uint256(st.idleLoosenBps) * (idle / 600)) * st.ceilBps / 1e8;
        uint256 cap = ceiling < st.rateCap ? ceiling : st.rateCap;
        assertLe(price, cap, "the price state is above the rate cap and the ceiling");
        uint256 pot = core.ethPot();
        uint256 pending = address(core).balance - pot - core.ethToBuyback() - core.ethRedeemBurn() - core.payeeOwed();
        assertLe(rate, pot + pending, "the read is above the pot and the pending income");
        if (pending == 0) {
            assertEq(rate, price < pot ? price : pot, "the read is not the price state lowered to the pot");
        } else {
            assertGe(rate, price < pot ? price : pot, "the read is below the price state lowered to the booked pot");
        }
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
        console.log("held by the burn address", handler.gDead());
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

    /// dispatches one handler action by number. the arguments mean what the action needs. the numbering follows the
    /// handler's name and counter arrays
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal virtual {
        a = a % handler.actionCount();
        if (a == 0) handler.buyCoin(w, x, y);
        else if (a == 1) handler.sellCoin(w, x, y);
        else if (a == 2) handler.sellForEth(w, x, y, z);
        else if (a == 3) handler.listingStrategy(w, x);
        else if (a == 4) handler.listingHostile(w, x);
        else if (a == 5) handler.warp(w);
        else if (a == 6) handler.roll(w);
        else if (a == 7) handler.compose(w, x);
        else if (a == 8) handler.buyback(w);
        else if (a == 9) handler.swapCredit(w, x);
        else if (a == 10) handler.donate(w, x);
        else if (a == 11) handler.controllerSeed(w);
        else if (a == 12) handler.controllerSwap(w);
        else if (a == 13) handler.probeController(w);
        else if (a == 14) handler.sellForBalance(w, x, y);
        else if (a == 15) handler.redeemStatement(w, x);
        else if (a == 16) handler.moduleMode(w);
        else if (a == 17) handler.walletMove(w, x);
        else if (a == 18) handler.setSettings(w, x);
        else if (a == 19) handler.setSettingsInvalid(w, x);
        else if (a == 20) handler.setRate(w, x);
        else if (a == 21) handler.ownerMisc(w, x);
        else if (a == 22) handler.replaceModule(w, x);
        else if (a == 23) handler.buy(w, x, y, z);
        else if (a == 24) handler.ownerSell(w, x, y, z);
        else if (a == 25) handler.saleSettings(w, x);
        else if (a == 26) handler.hostileOwner(w, x);
        else if (a == 27) handler.lockDoor(w, x);
        else if (a == 28) handler.handover(w, x);
        else if (a == 29) handler.book(w, x);
        else if (a == 30) handler.claimPayee(w, x);
        else if (a == 31) handler.rescueNft(w, x);
        else if (a == 32) handler.migrate(w, x);
        else if (a == 33) handler.adopt(w, x, y);
        else if (a == 34) handler.pause(w, x);
        else if (a == 35) handler.changeUnit(w);
        else if (a == 36) handler.releaseRedeem(w, x);
        else if (a == 37) handler.buyCredit(w, x, y);
        else if (a == 38) handler.buyCredits(w, x, y);
        else if (a == 39) handler.composeChosen(w, x);
        else if (a == 40) handler.creditSettings(w, x);
        else handler.setHeldFormat(w, x);
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

    // promise: inv 1 to 20 are not vacuous: every handler action succeeds
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

    // promise: inv 11 the six doors refuse with Retired after migrate
    /// the first successful `migrate` of the handler retires the core. every action that calls one of the six doors
    /// then sends its call, which must revert `Retired` with the books untouched, and no violation or unexpected revert
    /// is recorded
    function test_aRetiredCoreRefusesTheSixDoorActions() public virtual {
        for (uint256 i; i < 300 && !handler.gRetired(); ++i) {
            uint256 s = uint256(keccak256(abi.encode("retire", i)));
            _act(32, s, s >> 8, 0, 0);
        }
        assertTrue(handler.gRetired(), "the handler never migrated");
        assertTrue(core.retired(), "the core is not retired");
        // sellForEth, listingStrategy, listingHostile, compose, adopt, composeChosen, swapCredit, then sellForBalance in the balance side
        uint8[8] memory doors = [2, 3, 4, 7, 33, 39, 9, 14];
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
        // pause and composeChosen are exercised by their own tests, not by test_everyActionSucceeds (a chosen compose
        // needs a fresh page of 80 pile credits, which its own test builds)
        if (a == 34 || a == 39) return false;
        // changeUnit moves the module's unit, so it only lands in the balance side
        if (a == 35) return handler.phase2();
        // the sale and owner door actions run only in the suites that list them
        if (a >= 24 && a <= 28) return _saleSuite();
        // book through creditSettings, and buy, are available in every suite
        if (a >= 29 || a == 23) return true;
        // the redemption actions and the module replacement need the balance side
        if ((a >= 14 && a <= 16 || a == 22) && !handler.phase2()) return false;
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
        assertTrue(_try(17, 20), "no taxed side pool buy");
        _try(5, 5);
        _try(6, 5);
        _try(10, 5);
        _try(11, 5);
        _try(13, 5);
        // credits in, so the eth pile reaches 80
        assertTrue(_try(33, 40), "no adopt");
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
        // a fee free swap, so the smoke success needs only a credit pair; the fuzz campaign drives the fee from the
        // settings action and the swap handler models the burn
        wide.swapFeeCc = 0;
        handler.setSettingsExact(wide);
        // a holder swaps a pile credit for one it owns of equal or higher score
        assertTrue(_try(9, 80), "no credit swap");
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
        assertTrue(_try(41, 40), "no held format set");
        // a funded caller must restyle a held statement to a different format, not only meet BelowMinCc
        uint256 restyles = handler.fundedRestyles();
        for (uint256 i; i < 40 && handler.fundedRestyles() == restyles; ++i) {
            _try(41, 1);
        }
        assertGt(handler.fundedRestyles(), restyles, "no funded restyle changed a format");
        // the statement sale through the controller
        assertTrue(_try(23, 80), "no sale of a held statement");
        if (handler.phase2()) _phase2Smoke();
        // buyback needs buybackDelay blocks after the last one
        vm.roll(block.number + 200);
        assertTrue(_try(8, 60), "no buyback");
        _creditSmoke();
        _ownerSmoke();
        _payeeSmoke();
    }

    /// the owner's credit settings and the credit sale window. the real controller is put back in force first, so the
    /// core takes the controller's sellCreditTo, then the sale is turned on and a page is refilled for the buyers.
    /// chosen composition is covered by its own test, which builds the page of 80 it needs
    function _creditSmoke() internal {
        if (core.controller() != address(ctl) && !core.controllerLocked()) {
            vm.prank(handler.owner());
            core.setController(address(ctl));
        }
        assertTrue(_try(40, 20), "no credit setting");
        CreditSale memory cs = _creditSale();
        cs.saleOn = true;
        vm.prank(handler.owner());
        ctl.setCredit(cs);
        for (uint256 i; i < 20 && core.pileSize() < 5; ++i) {
            _try(2, 10);
        }
        assertTrue(_try(37, 40), "no credit buy");
        assertTrue(_try(38, 40), "no credit batch buy");
    }

    // promise: inv 1 to 20 are not vacuous: composeChosen succeeds
    /// a chosen compose: the owner turns it on, a page of 80 pile credits is built with the sale off (so the window is
    /// trivially satisfied), and the oldest 80 are composed into a statement. runs in every concrete suite
    function test_composeChosenComposesAPage() public {
        if (core.controller() != address(ctl) && !core.controllerLocked()) {
            vm.prank(handler.owner());
            core.setController(address(ctl));
        }
        if (ctl.creditSaleOn()) {
            CreditSale memory cs = _creditSale();
            cs.saleOn = false;
            vm.prank(handler.owner());
            ctl.setCredit(cs);
        }
        vm.startPrank(handler.owner());
        core.setChosenComposeOn(true);
        core.setMinCcToChoose(0);
        vm.stopPrank();
        for (uint256 i; i < 40 && core.pileSize() < 80; ++i) {
            _try(2, 10);
        }
        assertGe(core.pileSize(), 80, "the pile did not reach 80 for the chosen compose");
        assertTrue(_try(39, 10), "chosen compose never succeeded");
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
    }

    /// the book and the payee actions: books with and without pushed eth, then the owner points the payee at every kind
    /// of target (a fresh account, a payee that reverts, one that burns its gas, the zero address), claims against each,
    /// swaps keep working with a payee that refuses, and the payee goes back to a working account
    function _payeeSmoke() internal {
        assertTrue(_try(29, 20), "no book");
        for (uint256 m; m < 6; ++m) {
            handler.buyCoin(m, 1, 0);
            handler.claimPayee(m + 6 * 7, m);
            handler.book(m, 0);
        }
        assertTrue(_try(30, 20), "no claim");
        handler.claimPayee(1, 1);
        assertEq(core.payee(), handler.gPayee(), "the payee is the one the owner set last");
        handler.book(1, 0);
    }

    /// the owner's calls: valid settings across the bounds, refused ones, the rate and the other doors
    function _ownerSmoke() internal {
        assertTrue(_try(18, 20), "no settings change");
        assertTrue(_try(19, 20), "no refused settings");
        assertTrue(_try(20, 20), "no setRate");
        assertTrue(_try(21, 20), "no owner door");
        assertTrue(_try(36, 20), "no reserve release");
        assertTrue(_try(31, 60), "no rescue of an NFT");
        assertTrue(_try(32, 120), "no migration");
        // the books keep working under the new settings, whatever they are
        for (uint256 i; i < 6; ++i) {
            _try(18, 5);
            _try(5, 5);
            _try(2, 5);
        }
    }

    function _phase2Smoke() internal {
        // an eth lane statement is redeemable once its asking price falls to its cost; the long warp takes every held
        // statement there
        vm.warp(block.timestamp + 160 hours);
        assertTrue(_try(15, 80), "no redemption");
        assertTrue(_try(14, 60), "no balance token sale");
        _try(14, 60);
        // the balance bid credits sit in the single pile and compose through the regular compose, proven in _smoke
        assertTrue(_try(16, 20), "no module mode");
        // the owner replaces the balance module: a new one, the same one with a new unit, and the refusals
        assertTrue(_try(22, 40), "no module replacement");
        for (uint256 i; i < 8; ++i) {
            handler.replaceModule(i * 7919 + 1, i);
        }
        assertTrue(_try(35, 20), "no unit change");
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

/// phase 1 after the sniper window: the balance module slot is empty, the controller is ControllerV1 and may be swapped
/// for the fuzz controller in benign mode at once. the owner setup came a week, so the skim is
/// the 10 point baseline.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1 is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, false, "p1");
    }

    // promise: inv 5 the handler reads the Core storage slots
    /// the storage slots used by the handler match the public getters.
    function test_storageLayoutMatchesTheHandlerSlots() public view {
        assertEq(uint256(vm.load(address(core), bytes32(uint256(6)))), core.ethPot());
        assertEq(uint256(vm.load(address(core), bytes32(uint256(9)))), core.rateAtCheckpoint());
        assertEq((uint256(vm.load(address(core), bytes32(uint256(10)))) >> 64) & type(uint64).max, core.lastFillTime());
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
/// statements were all built under a 90 percent skim, and the owner has approved the test adapter that reaches the hostile target. the run begins
/// with the skim near its maximum and the handler may switch the controller at any time.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1Window is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, true, "w1");
    }

    // promise: inv 10 the window suite starts inside the anti sniper window
    /// the run starts inside the window with the skim well above the baseline
    function test_startsInsideTheSniperWindow() public view {
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW / 2);
        assertGt(_skimBpsNow(), 1000);
    }

    function _skimBpsNow() internal view returns (uint256) {
        (uint24 bps,) = IArtCoinsMevSkimV2(lc.mevModule).currentSkimBps(poolId);
        return bps;
    }

    /// everything the money side does inside the window first, then the standard smoke after a week
    function _smoke() internal override {
        assertGt(_skimBpsNow(), 1000);
        _try(0, 20);
        _try(1, 20);
        _try(2, 40);
        _try(2, 40);
        _try(9, 5);
        _try(10, 5);
        assertTrue(_try(7, 80), "no compose inside the window");
        // statements composed inside the window are for sale at once
        assertTrue(_try(23, 80), "no sale inside the window");
        for (uint256 i; i < 5; ++i) {
            _try(0, 10);
        }
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW, "the window closed during the smoke");
        assertGe(handler.windowSwaps(), 3, "too few swaps ran under the high skim");
        // the compose used the pile up, so fill it again for the compose of the standard smoke
        for (uint256 i; i < 30 && core.pileSize() < 80; ++i) {
            _try(2, 10);
        }
        assertGe(core.pileSize(), 80, "the pile did not refill");
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
