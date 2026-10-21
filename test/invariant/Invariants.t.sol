// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ICreditStrategy, Mainnet, Settings, CreditSale} from "../../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Halving} from "../../src/lib/Halving.sol";
import {IArtCoinsMevSkimV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {Fixture} from "../utils/Fixture.sol";
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
    /// the payee share: the forced push, the latch and the payee follow the model of the book
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
    // promise: 01 eth only leaves by allowed paths
    function invariant_01_ethOnlyLeavesByAllowedPaths() public view {
        _zero(g1);
    }

    /// 2. no credit is bought above its bid, `bidOf(id)` = the read times the credit's score over 100 points, taken just
    /// before the action. the sum paid by a batch is at most the sum of the per-credit bids.
    // promise: 02 no credit above the read
    function invariant_02_noCreditAboveTheRead() public view {
        _zero(g2);
    }

    /// 3. a statement leaves the core's control only by a sale at or above the hard floor (cost * saleFloorBps of the
    /// settings in force at the sale) or by a redemption that returned at least credits * unitPerPoint. `sellTo` is paid the
    /// decaying ask, at least the hard floor. here the first part: every sold statement was paid at least the hard
    /// floor in force at its sale.
    // promise: 03 no statement sold below the hard floor
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
    // promise: 04 every statement is in exactly one place
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

    /// 5. ethPot + ethToBuyback + ethRedeemBurn never exceeds the core's eth balance, and the same for the balance
    /// token pots. a sale books its payment at once, the artist and operator cuts pushed off the top and the rest split
    /// by saleToBuybackBps, and the payee share is pushed by the book, so no eth is owed outside the pots.
    // promise: 05 pots never exceed balances
    function invariant_05_potsNeverExceedBalances() public view {
        _zero(g5);
        assertLe(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), address(core).balance, "eth pots above balance"
        );
        // the balance token is held by the module, not the core, so there is no balance pot to bound
    }

    /// 6. the stored price state and the read follow the model around every action and every warp, against the
    /// settings in force over the interval. the only calls that make the stored rate jump are the owner's `setRate`,
    /// which lands on the rate asked for: a settings call checkpoints the old rate when open and preserves it when paused.
    // promise: 06 rate follows the model
    function invariant_06_rateFollowsTheModel() public view {
        _zero(g6);
    }

    /// 7. no spend exceeds the pot at that moment. every purchase of a credit (`sellForEth`, `buyListing`) is checked
    /// against the pot the core held when the purchase began, one credit after the other inside a batch. the read after
    /// every action is at most the pot, so the next fill cannot pay more than the pot. a sale refused above the pot
    /// ends in `PotTooSmall`, an arithmetic panic fails the invariant. the books themselves are checked by invariants 5
    /// and 6 and the pot bookkeeping of invariant 1.
    // promise: 07 no spend above the pot
    function invariant_07_noSpendAboveThePot() public view {
        _zero(g7);
    }

    /// 8. the hard rule: across the whole campaign neither the owner address nor any controller address ever gains eth,
    /// coin, credits, statements or balance token from the core, whatever settings the owner chooses. their balances are
    /// compared with what they held at the start (the owner pays gas only). the controllers' attack calls all failed,
    /// their reentry attempts through the test adapter failed, and nobody but the owner changed a setting.
    // promise: 08 owner and controllers never gain
    function invariant_08_ownerAndControllersNeverGain() public view {
        _zero(g8);
        uint256 n = handler.watchedCount();
        address xtoken = core.balanceToken();
        for (uint256 i; i < n; ++i) {
            address c = handler.watched(i);
            (uint256 eth, uint256 coin_, uint256 credits_, uint256 statements_, uint256 xt_) = handler.baseOf(c);
            // a watched address that is the configured payee (the owner on the live Core) legitimately receives the
            // payee share the book pushes. allow its eth to grow by exactly the share pushed to it over the campaign,
            // never more. on the fresh fixture the payee is a separate account, so this allowance is zero
            assertLe(c.balance, eth + handler.gPayeeOut(c), "owner or controller gained eth beyond the payee share");
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
    // promise: 09 coin supply only falls by burns
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
    // promise: 10 receive never reverts
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
    // promise: 11 no unexpected reverts
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
    // promise: 12 a statement only leaves by asale or aredemption
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
    // promise: 13 locks and handovers never come undone
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
    // promise: 14 no call from inside aredemption ever worked
    function invariant_14_noCallFromInsideARedemptionEverWorked() public view {
        uint256 n = handler.moduleEverCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(!handler.modulesEver(i).calledOk(), "a module made a call into the core that went through");
        }
    }

    /// 16. the eth bid stays open while the core has not migrated or paused. when a held credit's bid (`bidOf`) is not
    /// zero and the pot less the reserve covers both seller payment and artist royalty, a one credit `sellForEth` succeeds
    /// under a snapshot that is reverted, so the state is unchanged. it starts with the book of the fee income that
    /// every `sellForEth` makes first, so the price is the one the sale itself reads.
    // promise: 16 the bid never closes
    function invariant_16_theBidNeverCloses() public {
        if (core.retired() || core.paused()) return;
        uint256 snap = vm.snapshotState();
        try core.book() {} catch {}
        uint256 pot = core.ethPot();
        uint256 res = core.reserve();
        (address holder, uint256 id) = _sellable(pot > res ? pot - res : 0);
        if (holder == address(0)) {
            vm.revertToState(snap);
            return;
        }
        Settings memory cfg = core.settings();
        bool active = handler.gSpendActive() && handler.gSpendBucket() == block.timestamp / handler.gSpendSeconds();
        uint256 budget =
            active ? handler.gSpendSnapshot() * cfg.spendCapBps / 10_000 : core.ethPot() * cfg.spendCapBps / 10_000;
        uint256 spent = active ? handler.gSpent() : 0;
        bool capRefusal = cfg.spendCapBps != 10_000 && spent != 0
            && spent + _purchaseCost(core.bidOf(id), cfg.buyToArtistBps) > budget;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(holder);
        CREDITS.setApprovalForAll(address(core), true);
        (bool ok, bytes memory why) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        vm.stopPrank();
        vm.revertToState(snap);
        // a credit the engine sold within the return lock is refused by the lock, not a closed bid
        assertTrue(
            ok || bytes4(why) == ICore.ReturnLocked.selector
                || (bytes4(why) == ICore.SpendCapReached.selector && capRefusal),
            string.concat("sellForEth refused a credit whose payment and royalty fit, selector ", vm.toString(bytes4(why)))
        );
    }

    // promise: the independent budget ghost observes enforced fills and exhausted-budget refusals
    function test_purchaseBudgetGhostIsNotVacuous() public {
        Settings memory cfg = core.settings();
        vm.warp(block.timestamp + cfg.bucketSeconds);
        cfg.spendCapBps = 5_000;
        vm.prank(handler.owner());
        core.setSettings(cfg);
        assertTrue(_try(2, 40), "no capped purchase succeeded");
        assertGt(handler.gCappedFills(), 0);
        assertGt(handler.gSpent(), 0);
        cfg.spendCapBps = 1;
        vm.prank(handler.owner());
        core.setSettings(cfg);
        handler.setRate(0, 1); // Raise the quote above the small retained budget in every fixture.
        for (uint256 a; a < handler.actorCount(); ++a) {
            handler.sellForEth(a, 1, 0, 1);
        }
        assertGt(handler.gCapRejections(), 0, "no exhausted-budget refusal observed");
        invariant_20_purchaseBudgetIsRespected();
    }

    // promise: the widened one-wei rate can refuse a batch whose later payouts round to zero
    function test_lowRateBatchZeroRefusalMatchesModel() public {
        handler.setRate(15_000, 100_000_000_000_000_000_000);
        handler.sellForEth(300_000, 3_610_759_366, 21_059, 200);
        assertEq(handler.unexpectedFails(2), 0);
    }

    // promise: inv 16 the bid check reaches its success branch
    /// the sale of invariant 16 has a seller in the state `setUp` builds, so its success branch runs in the campaigns
    function test_theBidCheckFindsASeller() public {
        (address holder,) = _sellable(core.ethPot());
        assertTrue(holder != address(0), "no actor holds a credit that the pot covers");
        invariant_16_theBidNeverCloses();
    }

    /// the first credit among the first four of each actor whose seller payment and artist royalty fit `afford`
    function _sellable(uint256 afford) internal view returns (address holder, uint256 id) {
        uint256 royaltyBps = core.settings().buyToArtistBps;
        uint256 n = handler.actorCount();
        for (uint256 a; a < n; ++a) {
            address actor = handler.actors(a);
            uint256[] memory held = CREDITS.tokensOf(actor);
            for (uint256 j; j < held.length && j < 4; ++j) {
                uint256 price = core.bidOf(held[j]);
                if (price != 0 && _purchaseCost(price, royaltyBps) <= afford) return (actor, held[j]);
            }
        }
    }

    function _purchaseCost(uint256 bid, uint256 royaltyBps) internal pure returns (uint256 cost) {
        cost = bid + bid * royaltyBps / 10_000;
    }

    /// 17. every credit the core owns is in exactly one place. a credit in the pile is reached by walking it from
    /// its head, is recorded as in the pile, is owned by the core and appears once. the pile holds as many credits as
    /// its size says and its walk ends. a credit the core owns outside the pile has no record and `adopt` puts it into
    /// the pile. a credit the ghost ever piled that the core does not own has no record.
    // promise: 17 every credit in exactly one place
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
        if (!core.retired() && !core.paused()) _adoptable(loose, looseCount);
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
    /// unbooked eth, forced eth included, is outside the sum until `book` counts it. the payee share is pushed by the
    /// book, not held: the share is `payeePpm` of the income once the share is on, the first book with income at or after
    /// `launchedAt + settings.sniperSeconds` turns it on and shares nothing, and the share is forced out to the payee. the ledger
    /// counts the whole income in and the pushed share out.
    // promise: 18 eth conservation
    function invariant_18_ethConservation() public view {
        _zero(g13);
        assertEq(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() + handler.gEthOut(),
            handler.gEthStart() + handler.gEthIn(),
            "the eth books do not balance: start + booked != pots + paid out"
        );
        assertEq(core.payeeOn(), handler.gPayeeOn(), "the payee latch differs from the model");
        assertEq(core.payee(), handler.gPayee(), "the payee differs from the one the owner set last");
    }

    /// 19. the price state and the read stay inside the bounds the settings and the state give, with no model of the
    /// climb. the read never exceeds the price state. the price state never exceeds `rateCap` and the ceiling, which is
    /// `ceilBps` of `max(last fill rate, peak now)` grown by `idleLoosenBps` per full 10 minutes since the last fill,
    /// where the peak is `peakRate` halved over the time since `peakTime`. the read is the price state lowered to the pot
    /// less the reserve, so it never exceeds what a purchase may spend.
    // promise: 19 bid bounds
    function invariant_19_bidBounds() public view {
        uint256 rate = core.ethRate();
        uint256 price = core.ethPrice();
        assertLe(rate, price, "the read is above the price state");
        uint256 pot = core.ethPot();
        uint256 res = core.reserve();
        uint256 pending = address(core).balance - pot - core.ethToBuyback() - core.ethRedeemBurn();
        assertLe(price, _ethCap(pot + pending), "the price state is above the rate cap and the ceiling");
        assertLe(rate, pot + pending > res ? pot + pending - res : 0, "the read is above the pot and the pending income less the reserve");
        if (pending == 0) {
            // the bid's room is the pot less the reserve over 1 + buyToArtistBps / 10_000 (decision 163)
            uint256 room = (pot > res ? pot - res : 0) * 10_000 / (10_000 + core.settings().buyToArtistBps);
            assertEq(rate, price < room ? price : room, "the read is not the price state lowered to the pot less the reserve");
        } else {
            uint256 bookedRoom = (pot > res ? pot - res : 0) * 10_000 / (10_000 + core.settings().buyToArtistBps);
            assertGe(rate, price < bookedRoom ? price : bookedRoom, "the read is below the price state lowered to the booked pot less the reserve");
        }
    }

    /// 20. every successful ETH purchase after the first of its bucket fits the opening-pot budget of that bucket, tracked
    /// by the handler apart from the Core's bucket state. a cap of 10,000 bypasses the budget.
    // promise: 20 the purchase budget is respected after the first purchase of the bucket
    function invariant_20_purchaseBudgetIsRespected() public view {
        assertEq(handler.gCapViolations(), 0, "successful purchase exceeded the independently tracked bucket budget");
    }

    /// 21. with intake open, `bidOf(id)` read in a block equals the eth a single-credit `sellForEth` pays in that block.
    /// every door books the unbooked fee income as its first step and checkpoints with the pot
    /// clamp the view reads, so a bid quoted while income waits unbooked, or after idle time, is the bid the fill pays.
    /// checked under a reverted snapshot after every action, so the preceding time warps and value arrivals are in the
    /// state. covers the class where a quote and the value the next call uses disagree once value arrives with no call
    // promise: 21 the eth bid quoted equals the eth the next fill pays
    function invariant_21_ethBidEqualsNextFill() public {
        if (core.retired() || core.paused()) return;
        uint256 snap = vm.snapshotState();
        (address holder, uint256 id) = _sellable(core.ethPot());
        if (holder == address(0)) {
            vm.revertToState(snap);
            return;
        }
        uint256 quoted = core.bidOf(id);
        uint256 balBefore = holder.balance;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(holder);
        CREDITS.setApprovalForAll(address(core), true);
        (bool ok, bytes memory why) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        vm.stopPrank();
        if (ok) {
            assertEq(
                holder.balance - balBefore,
                quoted,
                string.concat("eth fill paid differs from bidOf quoted in the same block, id ", vm.toString(id))
            );
        } else {
            // a credit the engine sold inside its return lock is refused by the lock, a later purchase of a
            // capped bucket by its exhausted budget, and a credit whose bid passes the pot less the reserve by
            // `PotTooSmall`; none is a quote against fill divergence
            assertTrue(
                bytes4(why) == ICore.ReturnLocked.selector || bytes4(why) == ICore.SpendCapReached.selector
                    || bytes4(why) == ICore.PotTooSmall.selector,
                string.concat("sellForEth refused a sellable credit, selector ", vm.toString(bytes4(why)))
            );
        }
        vm.revertToState(snap);
    }

    /// 21b. with intake open, `balanceBidOf(id)` read in a block equals the balance token a single-credit
    /// `sellForBalance` pays the seller in that block (decision 164). the posted bid does not climb
    /// or drop, so the quote and the fill agree whenever the module can pay the payout and its royalty.
    // promise: 21b the balance bid quoted equals the balance token the next fill pays
    function invariant_21b_balanceBidEqualsNextFill() public {
        if (core.retired() || core.paused() || !core.settings().balanceBidOn || core.balanceModule() == address(0)) return;
        uint256 snap = vm.snapshotState();
        (address holder, uint256 id) = _balanceSellable();
        if (holder == address(0)) {
            vm.revertToState(snap);
            return;
        }
        uint256 quoted = core.balanceBidOf(id);
        address token = core.balanceToken();
        uint256 balBefore = _balanceOf(token, holder);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(holder);
        CREDITS.setApprovalForAll(address(core), true);
        (bool ok, bytes memory why) = address(core).call(abi.encodeWithSignature("sellForBalance(uint256[])", ids));
        vm.stopPrank();
        if (ok) {
            assertEq(
                _balanceOf(token, holder) - balBefore,
                quoted,
                string.concat("balance fill paid differs from balanceBidOf quoted in the same block, id ", vm.toString(id))
            );
        } else {
            // a credit the engine sold inside its return lock is refused by the lock, and a module that cannot pay the
            // payout and its royalty by `PotTooSmall`; neither is a quote against fill divergence
            assertTrue(
                bytes4(why) == ICore.ReturnLocked.selector || bytes4(why) == ICore.PotTooSmall.selector,
                string.concat("sellForBalance refused a sellable credit, selector ", vm.toString(bytes4(why)))
            );
        }
        vm.revertToState(snap);
    }

    /// a credit an actor holds whose posted balance bid is nonzero: the module can pay its payout and the royalty
    function _balanceSellable() internal view returns (address holder, uint256 id) {
        uint256 n = handler.actorCount();
        for (uint256 a; a < n; ++a) {
            address actor = handler.actors(a);
            uint256[] memory held = CREDITS.tokensOf(actor);
            for (uint256 j; j < held.length && j < 4; ++j) {
                if (core.balanceBidOf(held[j]) != 0) return (actor, held[j]);
            }
        }
    }

    /// the eth price state ceiling now: `ceilBps` of the fill anchor grown by `idleLoosenBps` scaled by the pot
    /// multiplier `m` per 10 idle minutes, capped by `rateCap` (decision 128)
    function _ethCap(uint256 pagesPot) internal view returns (uint256) {
        Settings memory st = core.settings();
        (uint256 lastFillRate,,) = _anchor();
        (uint256 peakRate, uint256 peakTime) = _peak();
        uint256 growthNow = core.paused() ? core.pausedSince() : block.timestamp;
        uint256 anchor = _anchorNow(lastFillRate, peakRate, peakTime, st.peakHalfLife, growthNow);
        uint256 idle = growthNow > core.lastFillTime() ? growthNow - core.lastFillTime() : 0;
        // decision 128 variant d: the loosening scales by m, counted at the last fill rate, capped by climbMultiplierCapBps
        uint256 m = _climbMulBps(pagesPot, lastFillRate, st.pointsPerPage, st.climbMultiplierCapBps);
        uint256 ceiling =
            anchor * (10_000 + uint256(st.idleLoosenBps) * m / 10_000 * (idle / st.idleStepSeconds)) * st.ceilBps / 1e8;
        return ceiling < st.rateCap ? ceiling : st.rateCap;
    }

    /// the pot scaled multiplier in bps, clamped to [1x, capBps]: the pages of 80 credits the pages pot covers at the
    /// last fill rate (decision 128 variant d, the loosening only)
    function _climbMulBps(uint256 pagesPot, uint256 rate, uint256 pointsPerPage, uint256 capBps)
        internal
        pure
        returns (uint256)
    {
        if (rate == 0) return 10_000;
        uint256 mBps = pagesPot * 1_000_000 / (rate * pointsPerPage);
        return mBps < 10_000 ? 10_000 : (mBps > capBps ? capBps : mBps);
    }

    /// the larger of the fill rate and the remembered peak decayed to now
    function _anchorNow(uint256 fillRate, uint256 peakRate, uint256 peakTime, uint256 halfLife, uint256 growthNow)
        internal
        view
        returns (uint256)
    {
        uint256 peakNow = Halving.halve(peakRate, growthNow > peakTime ? growthNow - peakTime : 0, halfLife);
        return fillRate > peakNow ? fillRate : peakNow;
    }

    /// logs how often each action ran, succeeded and was skipped in this run, and over all runs so far.
    // promise: logs how often each action ran, succeeded and was skipped in this run, and over all runs so far.
    function invariant_callSummary() public view {
        console.log("capped fills / budget rejections", handler.gCappedFills(), handler.gCapRejections());
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
        else if (a == 30) handler.book(w, x);
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
        else if (a == 41) handler.setHeldFormat(w, x);
        else handler.buyCoinNoBook(w, x, y);
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
        // slot 30 is reserved: the former standalone payee claim, folded into the book under the push model
        if (a == 30) return false;
        // buyCoinNoBook (a buy left unbooked, then a warp over the pending income, then a book) is exercised by the
        // random campaign, not the deterministic smoke
        if (a == 42) return false;
        // moduleMode, replaceModule and changeUnit drive the mock module's fault and unit knobs, which the honest
        // treasury of the stage B phase 1 build suites does not carry
        if ((a == 16 || a == 22 || a == 35) && handler.treasuryModule()) return false;
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
        // fund the pot with fee income so the pot covers a real listing's ask (the per credit bid is paid from the pot,
        // and a credit above 100 points bids more than the per-100-point rate)
        for (uint256 k; k < 20; ++k) _try(0, 30);
        // the best real listing needs a bid of at least its ask. when the bid is short the owner lifts the rate to the
        // one that pays the ask with 2 percent to spare (bid = rate * score / 1_000_000), within the rate cap
        _clearBestListing();
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
        // the credit sale window exists on both ControllerV1 and ControllerV2 (`setCredit`, `creditSaleOn`,
        // `buyCredit`), so this smoke runs in both live states; `_creditSale` reads only fields both carry
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
        // turning the credit sale off keeps the compose window trivially satisfied. both controllers carry the sale, so
        // this runs in both live states
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

    /// the book and the payee push: books with and without pushed eth, then the owner points the payee at a fresh
    /// account, one whose receive reverts and one that burns its gas, and a book forces the share out to each
    function _payeeSmoke() internal {
        assertTrue(_try(29, 20), "no book");
        for (uint256 m = 1; m <= 3; ++m) {
            handler.buyCoin(m, 1, 0);
            handler.book(m, m);
        }
        assertEq(core.payee(), handler.gPayee(), "the payee is the one the owner set last");
        handler.book(1, 0);
    }

    /// buys the best candidate listing through the handler, with the rate lifted first when its bid is below its ask
    function _clearBestListing() internal {
        uint256 id = bestCandidate;
        uint256 ask = ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(id);
        if (ask != 0 && core.bidOf(id) < ask) {
            uint256 rate = ask * 1_000_000 / _score(id) * 102 / 100;
            uint256 cap = core.settings().rateCap;
            handler.setRateExact(rate < cap ? rate : cap);
        }
        for (uint256 i; i < 5 && handler.successes(3) == 0; ++i) _try(3, 20);
        assertTrue(
            handler.successes(3) > 0,
            string.concat(
                "no real listing was bought: best ask ",
                vm.toString(ask),
                " bid ",
                vm.toString(core.bidOf(id)),
                " rate ",
                vm.toString(core.ethRate())
            )
        );
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
        if (handler.treasuryModule()) return _phase2SmokeTreasury();
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

    /// the stage B balance side runs on the honest Phase2BalanceTreasury (the live module), not the mock. activate it
    /// the way the lifecycle does: turn conversion and working payments on, open the Core's redemptions and balance
    /// bids, reach the token's transfers-open block, and fund a working balance. then drive the redemption and the
    /// balance sale. the mock-only fault, replacement and unit actions have no subject here and are left out
    function _phase2SmokeTreasury() internal {
        vm.prank(handler.owner());
        treasury.setSwitches(true, true, false);
        Settings memory s = core.settings();
        s.redeemOn = true;
        s.balanceBidOn = true;
        handler.setSettingsExact(s);
        (bool ok, bytes memory out) = liveBalanceToken.staticcall(abi.encodeWithSignature("transfersOpenBlock()"));
        if (ok && out.length == 32) {
            uint256 open = abi.decode(out, (uint256));
            if (block.number <= open) vm.roll(open + 1);
        }
        _fundTreasuryWorking(LIVE_WORKING_FUND);
        vm.warp(block.timestamp + 160 hours);
        assertTrue(_try(15, 80), "no redemption");
        assertTrue(_try(14, 60), "no balance token sale");
        _try(14, 60);
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
/// the 6.9 percent baseline.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1 is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, false, "p1");
    }

    // promise: the bid ceiling model excludes elapsed pause time, as the price state does
    function test_bidCeilingModelFreezesDuringPause() public {
        vm.prank(owner);
        core.setPaused(true);
        uint256 ceiling = _ethCap(core.ethPot());
        vm.warp(block.timestamp + 76);
        assertEq(_ethCap(core.ethPot()), ceiling, "the modeled ceiling changed during pause");
        assertLe(core.ethPrice(), ceiling, "the price exceeded the frozen ceiling");
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

    /// this variant stays on the fresh fixture, not the live Core. the elevated anti sniper skim of the launch window
    /// (the premise of `test_startsInsideTheSniperWindow` and the window `_smoke`) is a fresh launch state the live
    /// system cannot return to on a post launch fork, so a fresh system is deployed to exercise the window
    function _setUpBase() internal override {
        Fixture.setUp();
    }

    // promise: inv 10 the window suite starts inside the anti sniper window
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
