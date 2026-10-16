// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ICreditStrategy, ICreditScore, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {CreditIds} from "../utils/CreditIds.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockBalanceModule} from "../standins/MockBalanceModule.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestLiquidityHelper} from "../utils/TestLiquidityHelper.sol";
import {Handler} from "./Handler.sol";
import {Wiring, HandlerBase} from "./HandlerBase.sol";
import {HandlerOwner} from "./HandlerOwner.sol";
import {HandlerSale} from "./HandlerSale.sol";

/// @notice builds the real system on the fork for the invariant suites on top of the single real stack `Fixture`:
/// the real Core and ControllerV1 deployed through the deploy path, the coin launched through the live artcoins
/// factory, the live skim hook, locker, mev module and pool manager, and the live Credits, Statements
/// and CreditStrategy. the only stand ins are the balance module and balance token of the balance side. the attack contracts are
/// the fuzz controller and the hostile listing target. the owner adds the hostile target, the fuzz controller and,
/// in the balance side, the balance module at once. the eth pot is funded by real swap fees, the piles are
/// pre filled with real credits so that composes happen, and the clock is moved so that the rate has climbed far
/// enough for the real CreditStrategy listings to fit under the ceiling.
///
/// every statement of the prefill is held by the core, and two of them are bought through the controller before the
/// run (outside the sniper window variant), so the run starts with sale proceeds booked and the anchor moved.
///
/// two start states: after the sniper window (a week passes before the owner setup) and inside it (the run starts a
/// few seconds after launch, the skim is 90 percent).
abstract contract InvariantFixture is Fixture {
    /// eth the whale spends on coin. in steady state 9.5 percent of it becomes pot
    uint256 internal constant FUND_ETH = 100 ether;
    /// credits that stay in the eth pile after the pre filled composes, so two more fill it to 80
    uint256 internal constant LEFT_IN_PILE = 78;
    /// statements composed before the run
    uint256 internal constant COMPOSES = 4;
    /// real listings are read from the reserved tail of the recorded ids, which `_credits` never takes from
    uint256 internal constant CANDIDATE_POOL = 200;
    /// the candidate with the lowest ask per point, set by `_candidates`
    uint256 internal bestCandidate;

    /// @dev the credit budget is kept in the balance side suites, which also sell 80 credits into the balance side, by
    /// giving the four actors 25 credits each
    uint256 internal constant ACTOR_CREDITS = 25;

    FuzzController internal fuzz;
    ProbeTarget internal probeTarget;
    Handler internal handler;
    address internal filler;
    address internal whale;

    /// @dev the suites differ in the redemption phase, the controller, the start state and the tag of their counters.
    function _build(bool phase2, bool hostile, bool canSwapController, bool inWindow, string memory tag) internal {
        Fixture.setUp();
        filler = _user("inv.filler");
        whale = _user("inv.whale");
        fuzz = new FuzzController(address(core));
        probeTarget = new ProbeTarget(address(core));
        if (phase2) {
            xt = new MockBalanceToken("Balance Token", "XT");
            mod = new MockBalanceModule(address(xt), UNIT);
        }
        _ownerSetup(phase2, hostile, inWindow);
        _fundWhale();

        Wiring memory w = Wiring({
            core: core,
            coin: coin,
            router: router,
            launchKey: launchKey,
            hook: lc.stack.hook,
            mev: lc.mevModule,
            poolId: poolId,
            owner: owner,
            v1: address(ctl),
            fuzz: fuzz,
            probe: probeTarget,
            rawAdapter: rawAdapter,
            module: mod,
            balanceToken: xt,
            canSwapController: canSwapController,
            tag: tag
        });
        // built from its artifact: the handler is large and no test contract may embed its creation code
        handler = Handler(deployCode("Handler.sol:Handler", abi.encode(w)));
        _saleParts();
        _actors();
        _prefill(phase2, inWindow);
        _holders();
        _candidates();
        if (hostile) {
            fuzz.setHostile(true);
            fuzz.setSeed(uint256(keccak256("hostile start")));
        }
        _seedGhosts(phase2);
        if (!inWindow) {
            // four days without a fill let the rate climb about thirtyfold, which puts the cheapest real listings
            // under the ceiling, and the fuzz can warp the rest
            vm.warp(block.timestamp + 4 days);
            vm.roll(block.number + 4 days / 12);
        } else {
            assertLt(block.timestamp, launchTime + SNIPER_WINDOW / 2, "the window start state drifted");
        }
        _targets(phase2);
    }

    /// the controller that sells for the owner and the heirs of the handover chain, handed to the handler. the selling
    /// controller is built from its artifact. the owner installs it only when the handler's hostile owner does
    function _saleParts() internal {
        address selling = deployCode("SaleAttackers.sol:SellingController", abi.encode(address(core)));
        address[] memory heirs = new address[](4);
        for (uint256 i; i < 4; ++i) {
            heirs[i] = _user(string.concat("inv.heir", vm.toString(i)));
        }
        handler.setSaleParts(selling, heirs);
    }

    /// the suites that list the sale and owner actions of `HandlerSale` override this
    function _saleActions() internal pure virtual returns (bool) {
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// the owner allows the hostile target, and in the suites that need it sets the fuzz controller and the balance module.
    /// everything is at once. outside the sniper window variant a week passes first, so the run starts past the
    /// window; inside it the run starts a few seconds after launch
    function _ownerSetup(bool phase2, bool hostile, bool inWindow) internal {
        if (!inWindow) vm.warp(block.timestamp + 7 days + 1);
        vm.startPrank(owner);
        if (phase2) {
            core.setBalanceModule(address(mod));
            Settings memory es = core.settings();
            es.redeemOn = true;
            es.balanceBidOn = true;
            core.setSettings(es);
            // the balance token / native eth pool prices the statement value floor and the credit sale baseline. a
            // real initialized pool at a 1:1 sqrt price, pointed at by the real controller
            PoolKey memory vk = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(xt)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            // the balance token is cheap in eth, so the balance bid's eth cost basis is the eth market bid and the decision
            // 87 value floor stays below the sale curve
            PM.initialize(vk, uint160((uint256(1) << 96) * 1000));
            IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(address(xt)),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            });
            ctl.setBalancePoolKey(k);
        }
        // the hostile controller swap comes after the pool key is set on the real controller, so the key survives it
        if (hostile) core.setController(address(fuzz));
        vm.stopPrank();
        assertTrue(core.allowedAdapter(rawAdapter));
    }

    /// the whale buys coin through the real launch pool. the skim funds the eth pot, and the whale holds coin
    function _fundWhale() internal {
        _buyCoin(whale, FUND_ETH);
        vm.prank(whale);
        coin.approve(address(router), type(uint256).max);
        assertGt(core.ethPot(), 3 ether);
        assertEq(address(core).balance, _tracked());
    }

    /// how many of actor 0's credits are carved out for the dedicated swapper
    uint256 internal constant SWAPPER_CREDITS = 6;

    /// four actors with credits, eth and coin, all approved for the core and the router. every approval and every
    /// swap is real. a dedicated swapper for the swapCredit action takes `SWAPPER_CREDITS` of actor 0's allocation, so no
    /// other action ever spends them and the swap always has an incoming credit; it holds coin for the fuzzed fee. the
    /// carve out leaves the credits handed out as they were
    function _actors() internal {
        for (uint256 i; i < 4; ++i) {
            address a = _user(string.concat("inv.actor", vm.toString(i)));
            vm.deal(a, 100 ether);
            vm.prank(a);
            coin.approve(address(router), type(uint256).max);
            _buyCoin(a, 2 ether);
            uint256[] memory ids = _credits(a, ACTOR_CREDITS);
            handler.addActor(a);
            if (i != 0) {
                handler.giveCredits(a, ids);
                continue;
            }
            address sw = _user("inv.swapper");
            vm.deal(sw, 100 ether);
            vm.prank(sw);
            coin.approve(address(router), type(uint256).max);
            _buyCoin(sw, 20 ether);
            uint256[] memory swIds = new uint256[](SWAPPER_CREDITS);
            uint256[] memory keep = new uint256[](ACTOR_CREDITS - SWAPPER_CREDITS);
            for (uint256 j; j < ACTOR_CREDITS; ++j) {
                if (j < SWAPPER_CREDITS) {
                    vm.prank(a);
                    CREDITS.transferFrom(a, sw, ids[j]);
                    swIds[j] = ids[j];
                } else {
                    keep[j - SWAPPER_CREDITS] = ids[j];
                }
            }
            vm.prank(sw);
            CREDITS.setApprovalForAll(address(core), true);
            handler.giveCredits(a, keep);
            handler.setSwapper(sw, swIds);
        }
    }

    /// the statements the prefill sold before the run, with the price
    uint256 internal sold1;
    uint256 internal sold2;
    uint256 internal price1;
    uint256 internal price2;

    /// real credits sold into the piles, four composes so statements exist for the sale and the redemption. outside the
    /// sniper window two of them are bought by the whale at the asking price, so the buyback pot is not empty when the
    /// run starts. in the balance side the balance token bid is funded and 80 more credits are sold into it, so the balance side has a
    /// full page
    function _prefill(bool phase2, bool inWindow) internal {
        uint256 ethN = COMPOSES * 80 + LEFT_IN_PILE;
        uint256[] memory ids = _credits(filler, ethN + (phase2 ? 80 : 0));
        vm.fee(1 gwei);
        uint256[] memory ethIds = new uint256[](ethN);
        for (uint256 i; i < ethN; ++i) {
            ethIds[i] = ids[i];
        }
        uint256 openingPot = core.ethPot();
        uint256 spent;
        // in batches of 100: one call of all the credits would not fit the 60M gas of a call
        for (uint256 from; from < ethN; from += 100) {
            uint256 n = ethN - from < 100 ? ethN - from : 100;
            uint256[] memory batch = new uint256[](n);
            for (uint256 j; j < n; ++j) {
                batch[j] = ethIds[from + j];
            }
            uint256 beforePot = core.ethPot();
            vm.prank(filler);
            core.sellForEth(batch);
            spent += beforePot - core.ethPot();
        }
        handler.seedSpendBooks(openingPot, spent, block.timestamp);
        uint256 firstStatement = STATEMENTS.supply() + 1;
        for (uint256 i; i < COMPOSES; ++i) {
            vm.prank(keeper);
            core.compose();
        }
        assertEq(core.pileSize(), LEFT_IN_PILE);
        if (!inWindow) {
            (sold1, price1) = _saleOf(firstStatement);
            assertGt(core.ethToBuyback(), 0);
            (sold2, price2) = _saleOf(firstStatement + 1);
        }
        if (phase2) {
            // the balance token bid is funded the way the launch would: the launch allocation mints to the module
            xt.mint(address(mod), 1e20);
            uint256[] memory balanceIds = new uint256[](80);
            for (uint256 i; i < 80; ++i) {
                balanceIds[i] = ids[ethN + i];
            }
            // the balance bid uses the fixed 100 point basis, so it does not depend on the controller in force.
            // the credits enter the single pile with an eth cost basis
            vm.prank(filler);
            core.sellForBalance(balanceIds);
            assertEq(core.pileSize(), LEFT_IN_PILE + 80);
        }
    }

    /// the whale buys `sid` at the asking price
    function _saleOf(uint256 sid) internal returns (uint256, uint256) {
        // the sale needs the first controller in force: the hostile suites hand the core to the fuzz controller first
        address current = core.controller();
        if (current != address(ctl)) {
            vm.prank(owner);
            core.setController(address(ctl));
        }
        uint256 price = _buy(whale, sid);
        if (current != address(ctl)) {
            vm.prank(owner);
            core.setController(current);
        }
        assertEq(STATEMENTS.ownerOf(sid), whale);
        return (sid, price);
    }

    /// credits held by the hostile target
    function _holders() internal {
        handler.setProbeIds(_credits(address(probeTarget), 16));
        vm.deal(address(probeTarget), 100 ether);
    }

    /// the listings that clear first: the credits the strategy holds and lists among the last `CANDIDATE_POOL` recorded ids, ranked
    /// by ask over score ascending, so the first candidates are the ones whose bid reaches the ask at the lowest rate.
    /// the score is fixed at mint, so the order does not depend on the pot or the rate at this point
    function _candidates() internal {
        uint256 total = CreditIds.count();
        uint256 n = total < CANDIDATE_POOL ? total : CANDIDATE_POOL;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory key = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = CreditIds.at(total - 1 - i);
            ids[i] = id;
            uint256 ask = _heldByStrategy(id) ? ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(id) : 0;
            // ask per point in 1e18 units, larger is worse. an id the strategy does not hold or list sorts last
            key[i] = ask == 0 ? type(uint256).max : ask * 1e18 / _score(id);
        }
        uint256 keep = 12;
        uint256[] memory best = new uint256[](keep);
        for (uint256 k; k < keep; ++k) {
            uint256 bi;
            uint256 bk = type(uint256).max;
            for (uint256 i; i < n; ++i) {
                if (key[i] < bk) {
                    bk = key[i];
                    bi = i;
                }
            }
            best[k] = ids[bi];
            key[bi] = type(uint256).max;
        }
        bestCandidate = best[0];
        handler.setCandidates(best);
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// tells the handler what the fixture already did, so the ghost model starts level with the core.
    function _seedGhosts(bool) internal {
        uint256[] memory ids = core.pilePage(0, 200);
        for (uint256 i; i < ids.length; ++i) {
            (, uint256 cost,) = core.creditInfo(ids[i]);
            handler.seedGhostPile(ids[i], cost);
        }
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            handler.seedGhostStatement(held[i]);
        }
        if (sold1 != 0) handler.seedGhostSold(sold1, whale, price1);
        if (sold2 != 0) handler.seedGhostSold(sold2, whale, price2);
        handler.seedEthBooks();
    }

    /// how many times each owner action appears in the fuzzer's list. the hostile owner suite raises it
    function _ownerWeight() internal pure virtual returns (uint256) {
        return 1;
    }

    /// the actions the fuzzer may call. the setters of the handler are left out. an action listed twice is called
    /// twice as often
    function _targets(bool phase2) internal virtual {
        bytes4[] memory s = new bytes4[](200);
        uint256 n;
        s[n++] = HandlerBase.buyCoin.selector;
        s[n++] = HandlerBase.buyCoin.selector;
        s[n++] = HandlerBase.buyCoinNoBook.selector;
        s[n++] = HandlerBase.sellCoin.selector;
        s[n++] = HandlerBase.walletMove.selector;
        s[n++] = HandlerBase.sellForEth.selector;
        s[n++] = HandlerBase.sellForEth.selector;
        s[n++] = HandlerBase.listingStrategy.selector;
        s[n++] = HandlerBase.listingHostile.selector;
        s[n++] = HandlerBase.warp.selector;
        s[n++] = HandlerBase.warp.selector;
        s[n++] = HandlerBase.roll.selector;
        s[n++] = HandlerBase.compose.selector;
        s[n++] = HandlerBase.composeChosen.selector;
        s[n++] = HandlerBase.setHeldFormat.selector;
        s[n++] = HandlerSale.buy.selector;
        s[n++] = HandlerSale.buy.selector;
        s[n++] = HandlerSale.buyCredit.selector;
        s[n++] = HandlerSale.buyCredit.selector;
        s[n++] = HandlerSale.buyCredits.selector;
        s[n++] = HandlerBase.buyback.selector;
        s[n++] = HandlerBase.donate.selector;
        s[n++] = HandlerBase.adopt.selector;
        s[n++] = HandlerBase.controllerSeed.selector;
        s[n++] = HandlerBase.controllerSwap.selector;
        s[n++] = HandlerBase.probeController.selector;
        // the book of the fee income by anyone, which forces the payee share out, now and then after the owner
        // replaces the payee
        s[n++] = HandlerBase.book.selector;
        s[n++] = HandlerBase.book.selector;
        s[n++] = HandlerBase.book.selector;
        // the balance module is set in the balance side suites before the run starts, so the redemption actions are listed only there
        if (phase2) {
            s[n++] = HandlerBase.sellForBalance.selector;
            s[n++] = HandlerBase.redeemStatement.selector;
            s[n++] = HandlerBase.moduleMode.selector;
        }
        if (_saleActions()) {
            s[n++] = HandlerSale.ownerSell.selector;
            s[n++] = HandlerSale.saleSettings.selector;
            s[n++] = HandlerSale.hostileOwner.selector;
            s[n++] = HandlerSale.lockDoor.selector;
            s[n++] = HandlerSale.handover.selector;
            s[n++] = HandlerSale.pause.selector;
        }
        // the owner as an adversary: settings anywhere in the bounds, rates, invalid calls, the other owner doors
        for (uint256 k; k < _ownerWeight(); ++k) {
            s[n++] = HandlerOwner.setSettings.selector;
            s[n++] = HandlerOwner.setSettingsInvalid.selector;
            s[n++] = HandlerOwner.setRate.selector;
            s[n++] = HandlerOwner.ownerMisc.selector;
            s[n++] = HandlerOwner.rescueNft.selector;
            s[n++] = HandlerOwner.migrate.selector;
            s[n++] = HandlerOwner.creditSettings.selector;
            if (phase2) s[n++] = HandlerOwner.replaceModule.selector;
        }
        bytes4[] memory sel = new bytes4[](n);
        for (uint256 i; i < n; ++i) {
            sel[i] = s[i];
        }
        // the fuzzer's own random senders would each cost a slow rpc account lookup on a fork. two fixed ones
        // are cached. the handler pranks every account it needs, so the sender is never used
        targetSender(_user("inv.sender0"));
        targetSender(_user("inv.sender1"));
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }
}
