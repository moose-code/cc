// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IListingAdapter} from "../../src/interfaces/IListingAdapter.sol";
import {BasicOrderParameters, BasicOrderType, AdditionalRecipient} from "../../src/interfaces/ISeaport.sol";
import {
    ICredits,
    ICreditScore,
    ICreditStrategy,
    IBalanceModule,
    Mainnet,
    BUYBACK_GAS
} from "../../src/interfaces/Interfaces.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";
import {Scenario, IUniversalRouterR, IPermit2R, IERC20R} from "./Scenario.s.sol";

interface IAllowanceR {
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPermit2AllowanceR {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface ISupplyR {
    function supply() external view returns (uint256);
}

/// @notice the activity speed run: `round(bool)` runs one round of actions in one forge run, `discover()` reads the
/// fork once for the inputs the rounds cache. the stages act on the deployment in `RECORD` (default
/// deployments/31337.json) and never deploy, seed or reset. every write is a transaction from an impersonated account
/// (forge --unlocked against an anvil --auto-impersonate node) through the doors and quotes the web uses. before each
/// write the call runs once in the simulation from the same sender and is sent only when it succeeds, so a round does
/// not broadcast a reverting transaction. `stage(string)` runs a single stage for debugging.
///
/// a round runs trading, bots, people, balance (balance rounds only), compose, buyers and buyback in that order.
/// `script/dev/activity.sh` warps the node between rounds.
///
/// env: SEED, ROUND, RECORD, CACHE_FILE (json written by activity.sh from `discover`: strategy listings and holders),
/// SEAPORT_FILE (listings of script/dev/opensea-listings.mjs), DISCOVER (comma list of listings, holders), BOT_MARGIN (wei, default 0.001 ether),
/// PEOPLE (most holders per stage, default 5), PEOPLE_CREDITS (most credits one holder sells, default 3).
///
/// funding: `anvil_setBalance` through `vm.rpc` tops an actor up when its balance is low. the random traders, the bot
/// and the composer are derived addresses; the Credits holders are the real owners at the fork block.
contract Activity is Scenario {
    uint256 internal constant TRADERS = 20;
    /// @dev ids in test/utils/CreditIds.sol, the Credits the CreditStrategy holds and lists at the fork block
    uint256 internal constant LISTED = 200;
    uint256 internal constant SWEEP_MAX = 40;
    /// @dev holder discovery samples this many ids and keeps at most HOLDERS_MAX distinct owners
    uint256 internal constant HOLDER_SAMPLES = 300;
    uint256 internal constant HOLDERS_MAX = 40;

    uint256 internal rng;
    address internal strategyAdapter;
    address internal seaportAdapter;
    address internal bot;
    address internal composer;
    uint256 internal refScore;

    function round(bool withBalance) external {
        _init("round");
        doTrading();
        doBots();
        doPeople();
        if (withBalance) doBalance();
        doCompose();
        doBuyers();
        doBuyback();
    }

    function stage(string calldata name) external {
        _init(name);
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("trading")) doTrading();
        else if (h == keccak256("bots")) doBots();
        else if (h == keccak256("people")) doPeople();
        else if (h == keccak256("compose")) doCompose();
        else if (h == keccak256("buyers")) doBuyers();
        else if (h == keccak256("buyback")) doBuyback();
        else if (h == keccak256("balance")) doBalance();
        else revert(string.concat("unknown stage ", name));
    }

    function _init(string memory name) internal {
        string memory rec = vm.readFile(vm.envOr("RECORD", string("deployments/31337.json")));
        core = ICore(payable(vm.parseJsonAddress(rec, ".core")));
        strategyAdapter = vm.parseJsonAddress(rec, ".strategyAdapter");
        seaportAdapter = vm.parseJsonAddress(rec, ".seaportAdapter");
        ctl = IControllerV1(core.controller());
        coin = core.COIN();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        refScore = core.settings().refScore;
        bot = _actor("bot", 0);
        composer = _actor("composer", 0);
        rng = uint256(keccak256(abi.encode(vm.envOr("SEED", uint256(1)), vm.envOr("ROUND", uint256(0)), name)));
        console.log(string.concat("[", name, "] round"), vm.envOr("ROUND", uint256(0)));
    }

    // ------------------------------------------------------------------ 1 trading

    /// 6 to 12 swaps through the universal router from random pool addresses: buys of 0.05 to 2 eth, and sells of 10 to
    /// 60 percent of the coin an address holds. the hook fees reach the Core and are booked at the end.
    function doTrading() internal {
        uint256 n = 6 + _rnd(7);
        uint256 buys;
        uint256 sells;
        for (uint256 i; i < n; ++i) {
            address who = _actor("trader", _rnd(TRADERS));
            _topUp(who, 10 ether, 60 ether);
            uint256 held = IERC20R(coin).balanceOf(who);
            if (held > 0 && _rnd(100) < 45) {
                uint256 amt = held * (10 + _rnd(51)) / 100;
                _approveSell(who, amt);
                vm.broadcast(who);
                IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute(hex"10", _v4Swap(false, amt), block.timestamp + 1 hours);
                console.log("swap sell cc", amt, who);
                ++sells;
            } else {
                uint256 eth = 0.05 ether + _rnd(1.95 ether);
                vm.broadcast(who);
                IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: eth}(
                    hex"10", _v4Swap(true, eth), block.timestamp + 1 hours
                );
                console.log("swap buy eth", eth, who);
                ++buys;
            }
        }
        _topUp(bot, 5 ether, 100 ether);
        if (_dry(bot, address(core), 0, abi.encodeCall(ICore.book, ()))) {
            vm.broadcast(bot);
            core.book();
        }
        console.log("trading: buys", buys);
        console.log("trading: sells", sells);
        console.log("trading: ethPot", core.ethPot());
    }

    function _approveSell(address who, uint256 amt) internal {
        if (IAllowanceR(coin).allowance(who, Mainnet.PERMIT2) < amt) {
            vm.broadcast(who);
            IERC20R(coin).approve(Mainnet.PERMIT2, type(uint256).max);
        }
        (uint160 a, uint48 exp,) = IPermit2AllowanceR(Mainnet.PERMIT2).allowance(who, coin, Mainnet.UNIVERSAL_ROUTER);
        if (a < amt || exp <= block.timestamp + 1 days) {
            vm.broadcast(who);
            IPermit2R(Mainnet.PERMIT2).approve(coin, Mainnet.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        }
    }

    // ------------------------------------------------------------------ 2 bots

    struct Listing {
        uint256 id;
        uint256 price;
        uint256 score;
        bool done;
    }

    /// buys every cached CreditStrategy listing priced under `bidOf(id)` minus the margin, best gap first, through
    /// `buyListing` with the CreditStrategy adapter, until the pot is short or no listing qualifies. the listings are
    /// the ids of test/utils/CreditIds.sol that `discover` found sweepable at some rate under 1.5 times the rate cap (the
    /// strategy exposes `nftForSale(id)` and no enumeration). Seaport listings come from SEAPORT_FILE.
    function doBots() internal {
        uint256 margin = vm.envOr("BOT_MARGIN", uint256(0.001 ether));
        _topUp(bot, 5 ether, 100 ether);
        Listing[] memory ls = _cachedListings();
        uint256 swept;
        for (uint256 it; it < SWEEP_MAX; ++it) {
            (bool found, uint256 best) = _bestListing(ls, margin);
            if (!found) break;
            ls[best].done = true;
            bytes memory call = abi.encodeCall(ICore.buyListing, (strategyAdapter, ls[best].id, ""));
            if (!_dry(bot, address(core), 0, call)) {
                console.log("bots: strategy listing skipped, id", ls[best].id);
                continue;
            }
            uint256 bid = core.bidOf(ls[best].id);
            vm.broadcast(bot);
            core.buyListing(strategyAdapter, ls[best].id, "");
            console.log("bots: strategy sweep id", ls[best].id);
            console.log("bots:   price / bid", ls[best].price, bid);
            ++swept;
        }
        console.log("bots: strategy listings watched", ls.length);
        console.log("bots: strategy swept", swept);
        _seaportSweep(margin);
        console.log("bots: ethPot / ethRate", core.ethPot(), core.ethRate());
    }

    function _cachedListings() internal view returns (Listing[] memory ls) {
        string memory json = vm.readFile(vm.envString("CACHE_FILE"));
        uint256[] memory ids = vm.parseJsonUintArray(json, ".ids");
        uint256[] memory prices = vm.parseJsonUintArray(json, ".prices");
        uint256[] memory scores = vm.parseJsonUintArray(json, ".scores");
        ls = new Listing[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            // a listing the strategy no longer holds is done
            ls[i] = Listing(ids[i], prices[i], scores[i], !_heldByStrategy(ids[i]));
        }
    }

    function _bestListing(Listing[] memory ls, uint256 margin) internal view returns (bool found, uint256 best) {
        uint256 rate = core.ethRate();
        uint256 pot = core.ethPot();
        uint256 bestGap;
        for (uint256 i; i < ls.length; ++i) {
            if (ls[i].done || ls[i].price > pot) continue;
            uint256 bid = rate * ls[i].score / refScore;
            if (bid < ls[i].price + margin) continue;
            uint256 gap = bid - ls[i].price;
            if (gap > bestGap) {
                bestGap = gap;
                best = i;
                found = true;
            }
        }
    }

    /// the listings of SEAPORT_FILE: counts those Seaport takes on the fork now (a dry run of the fill from the bot),
    /// and sweeps the ones priced under the bid minus the margin
    function _seaportSweep(uint256 margin) internal {
        string memory path = vm.envOr("SEAPORT_FILE", string(""));
        if (bytes(path).length == 0) return;
        string memory json = vm.readFile(path);
        uint256 count = vm.parseJsonUint(json, ".count");
        uint256 fulfillable;
        uint256 swept;
        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(".orders[", vm.toString(i), "]");
            uint256 id = vm.parseJsonUint(json, string.concat(at, ".id"));
            if (!_exists(id) || ICredits(Mainnet.CREDITS).ownerOf(id) == address(core)) continue;
            bytes memory params = abi.encode(_parseOrder(json, string.concat(at, ".params")));
            (bool valid, bool done) = _sweepSeaport(id, params, margin);
            if (valid) ++fulfillable;
            if (done) ++swept;
        }
        console.log("seaport: listings in file", count);
        console.log("seaport: fulfillable on the fork now", fulfillable);
        console.log("seaport: swept", swept);
    }

    function _sweepSeaport(uint256 id, bytes memory params, uint256 margin) internal returns (bool valid, bool done) {
        try IListingAdapter(seaportAdapter).price(id, params) returns (address target, uint256 value, bytes memory data) {
            _topUp(bot, value + 1 ether, value + 100 ether);
            if (!_dry(bot, target, value, data)) return (false, false);
            uint256 bid = core.bidOf(id);
            if (value + margin >= bid || value > core.ethPot()) return (true, false);
            bytes memory call = abi.encodeCall(ICore.buyListing, (seaportAdapter, id, params));
            if (!_dry(bot, address(core), 0, call)) {
                console.log("seaport: listing skipped, id", id);
                return (true, false);
            }
            vm.broadcast(bot);
            core.buyListing(seaportAdapter, id, params);
            console.log("seaport: sweep id", id);
            console.log("seaport:   price / bid", value, bid);
            return (true, true);
        } catch {
            return (false, false);
        }
    }

    // ------------------------------------------------------------------ discover

    /// reads the fork once. prints one line per input of the round cache: `LISTING id price score` for each strategy
    /// listing that breaks even at an eth rate under 1.5 times the rate cap, and `HOLDER address` for each EOA owner of a
    /// sampled Credits id. DISCOVER selects the parts.
    function discover() external {
        _init("discover");
        string memory what = vm.envOr("DISCOVER", string("listings,holders"));
        if (_contains(what, "listings")) _discoverListings();
        if (_contains(what, "holders")) _discoverHolders();
    }

    function _discoverListings() internal view {
        uint256 maxRate = uint256(core.settings().rateCap) * 3 / 2;
        uint256 n;
        for (uint256 i; i < LISTED; ++i) {
            uint256 id = CreditIds.at(i);
            if (!_heldByStrategy(id)) continue;
            uint256 price = ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(id);
            if (price == 0) continue;
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(
                ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id)
            );
            if (price * refScore / score > maxRate) continue;
            console.log("LISTING", id, price, score);
            ++n;
        }
        console.log("discover: strategy listings kept", n);
    }

    /// @dev one `HOLDER address id` line per sampled id owned by an EOA, for at most HOLDERS_MAX distinct owners
    function _discoverHolders() internal {
        address[] memory hs = new address[](HOLDERS_MAX);
        uint256 got;
        uint256 span = ISupplyR(Mainnet.CREDITS).supply() + 1000;
        for (uint256 t; t < HOLDER_SAMPLES; ++t) {
            uint256 id = 1 + _rnd(span);
            address h;
            try ICredits(Mainnet.CREDITS).ownerOf(id) returns (address o) {
                h = o;
            } catch {
                continue;
            }
            if (h == address(0) || h.code.length != 0 || h == Mainnet.CREDIT_STRATEGY || h == address(core)) continue;
            if (_isActor(h)) continue;
            if (!_has(hs, got, h)) {
                if (got == HOLDERS_MAX) continue;
                hs[got++] = h;
            }
            console.log("HOLDER", h, id);
        }
        console.log("discover: holders kept", got);
    }

    /// @dev a credit composed into a statement no longer exists
    function _exists(uint256 id) internal view returns (bool) {
        try ICredits(Mainnet.CREDITS).ownerOf(id) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _heldByStrategy(uint256 id) internal view returns (bool) {
        try ICredits(Mainnet.CREDITS).ownerOf(id) returns (address o) {
            return o == Mainnet.CREDIT_STRATEGY;
        } catch {
            return false;
        }
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool eq = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) return true;
        }
        return false;
    }

    function _parseOrder(string memory json, string memory at) internal pure returns (BasicOrderParameters memory p) {
        p.considerationToken = vm.parseJsonAddress(json, string.concat(at, ".considerationToken"));
        p.considerationIdentifier = vm.parseJsonUint(json, string.concat(at, ".considerationIdentifier"));
        p.considerationAmount = vm.parseJsonUint(json, string.concat(at, ".considerationAmount"));
        p.offerer = payable(vm.parseJsonAddress(json, string.concat(at, ".offerer")));
        p.zone = vm.parseJsonAddress(json, string.concat(at, ".zone"));
        p.offerToken = vm.parseJsonAddress(json, string.concat(at, ".offerToken"));
        p.offerIdentifier = vm.parseJsonUint(json, string.concat(at, ".offerIdentifier"));
        p.offerAmount = vm.parseJsonUint(json, string.concat(at, ".offerAmount"));
        p.basicOrderType = BasicOrderType(uint8(vm.parseJsonUint(json, string.concat(at, ".basicOrderType"))));
        p.startTime = vm.parseJsonUint(json, string.concat(at, ".startTime"));
        p.endTime = vm.parseJsonUint(json, string.concat(at, ".endTime"));
        p.zoneHash = vm.parseJsonBytes32(json, string.concat(at, ".zoneHash"));
        p.salt = vm.parseJsonUint(json, string.concat(at, ".salt"));
        p.offererConduitKey = vm.parseJsonBytes32(json, string.concat(at, ".offererConduitKey"));
        p.fulfillerConduitKey = vm.parseJsonBytes32(json, string.concat(at, ".fulfillerConduitKey"));
        p.totalOriginalAdditionalRecipients =
            vm.parseJsonUint(json, string.concat(at, ".totalOriginalAdditionalRecipients"));
        p.additionalRecipients = new AdditionalRecipient[](p.totalOriginalAdditionalRecipients);
        for (uint256 j; j < p.additionalRecipients.length; ++j) {
            string memory r = string.concat(at, ".additionalRecipients[", vm.toString(j), "]");
            p.additionalRecipients[j] = AdditionalRecipient(
                vm.parseJsonUint(json, string.concat(r, ".amount")),
                payable(vm.parseJsonAddress(json, string.concat(r, ".recipient")))
            );
        }
        p.signature = vm.parseJsonBytes(json, string.concat(at, ".signature"));
    }

    // ------------------------------------------------------------------ 3 people

    /// 2 to 5 real Credits holders sell 1 to 3 credits each into the eth bid at the quote (`bidOf`). a few more name an
    /// ask above the bid and hold out.
    function doPeople() internal {
        uint256 maxHolders = vm.envOr("PEOPLE", uint256(5));
        uint256 maxCredits = vm.envOr("PEOPLE_CREDITS", uint256(3));
        uint256 want = maxHolders < 2 ? maxHolders : 2 + _rnd(maxHolders - 1);
        uint256[] memory hs = _findHolders(want + 2);
        uint256 sold;
        uint256 creditsSold;
        for (uint256 i; i < hs.length; ++i) {
            if (i >= want) {
                _holdOut(hs[i]);
                continue;
            }
            uint256 n = _sellEth(hs[i], 1 + _rnd(maxCredits));
            if (n != 0) ++sold;
            creditsSold += n;
        }
        console.log("people: holders selling", sold);
        console.log("people: credits sold for eth", creditsSold);
        console.log("people: ethPot", core.ethPot());
    }

    function _holdOut(uint256 k) internal {
        (address h, uint256[] memory ids) = _holding(k, 1);
        if (ids.length == 0) return;
        uint256 bid = core.bidOf(ids[0]);
        uint256 ask = bid * (110 + _rnd(90)) / 100;
        console.log("held out: holder", h);
        console.log("held out:   credit / ask / bid", ids[0], ask, bid);
    }

    /// holder sells up to `n` credits for eth in one `sellForEth`, trimmed to a batch the pot pays. returns the count
    function _sellEth(uint256 k, uint256 n) internal returns (uint256 sold) {
        (address h, uint256[] memory ids) = _holding(k, n);
        uint256 pot = core.ethPot() * 9 / 10;
        uint256 sum;
        uint256 k;
        for (; k < ids.length; ++k) {
            uint256 bid = core.bidOf(ids[k]);
            if (sum + bid > pot) break;
            sum += bid;
        }
        if (k == 0) {
            console.log("people: nothing sellable or pot too short for holder", h);
            return 0;
        }
        assembly {
            mstore(ids, k)
        }
        _approveCredits(h);
        uint256 minOut = sum * (100 - (k < 40 ? k : 40)) / 100;
        bytes memory call = abi.encodeWithSignature("sellForEth(uint256[],uint256)", ids, minOut);
        if (!_dry(h, address(core), 0, call)) {
            console.log("people: sale skipped for holder", h);
            return 0;
        }
        vm.broadcast(h);
        core.sellForEth(ids, minOut);
        console.log("people: sellForEth holder", h);
        console.log("people:   credits / quote", k, sum);
        return k;
    }

    function _approveCredits(address h) internal {
        _topUp(h, 0.5 ether, 2 ether);
        if (!ICredits(Mainnet.CREDITS).isApprovedForAll(h, address(core))) {
            vm.broadcast(h);
            ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        }
    }

    /// @dev `want` distinct cached holders
    function _findHolders(uint256 want) internal returns (uint256[] memory idx) {
        uint256 total = vm.parseJsonAddressArray(vm.readFile(vm.envString("CACHE_FILE")), ".holders").length;
        idx = new uint256[](want < total ? want : total);
        uint256 got;
        for (uint256 t; t < 4 * want && got < idx.length; ++t) {
            uint256 k = _rnd(total);
            bool dup;
            for (uint256 i; i < got; ++i) {
                if (idx[i] == k) dup = true;
            }
            if (!dup) idx[got++] = k;
        }
    }

    /// @dev holder `k` of the cache and up to `n` of its cached ids that it still owns
    function _holding(uint256 k, uint256 n) internal returns (address h, uint256[] memory ids) {
        string memory json = vm.readFile(vm.envString("CACHE_FILE"));
        h = vm.parseJsonAddressArray(json, ".holders")[k];
        uint256[] memory cached = vm.parseJsonUintArray(json, string.concat(".holdings[", vm.toString(k), "]"));
        ids = new uint256[](n < cached.length ? n : cached.length);
        uint256 got;
        uint256 start = cached.length == 0 ? 0 : _rnd(cached.length);
        for (uint256 i; i < cached.length && got < ids.length; ++i) {
            uint256 id = cached[(start + i) % cached.length];
            try ICredits(Mainnet.CREDITS).ownerOf(id) returns (address o) {
                if (o == h) ids[got++] = id;
            } catch {}
        }
        assembly {
            mstore(ids, got)
        }
    }

    function _has(address[] memory a, uint256 n, address x) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == x) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ 4 compose

    function doCompose() internal {
        (bool ready,,) = ctl.nextPage();
        if (!ready) {
            console.log("compose: not ready, pileSize", core.pileSize());
            return;
        }
        uint8 format = uint8(_rnd(8));
        _topUp(composer, 5 ether, 50 ether);
        bytes memory call = abi.encodeWithSignature("compose(uint8)", format);
        if (!_dry(composer, address(core), 0, call)) {
            console.log("compose: reverted in simulation, skipped");
            return;
        }
        vm.broadcast(composer);
        core.compose(format);
        uint256[] memory held = core.heldStatements();
        console.log("compose: format", format);
        console.log("compose: statement", held[held.length - 1]);
    }

    // ------------------------------------------------------------------ 5 buyers

    /// 1 to 3 statement purchases at `priceOf` and 1 to 4 credit purchases at `creditPrice` from random pool addresses
    /// that can pay.
    function doBuyers() internal {
        uint256 statements = 1 + _rnd(3);
        uint256 bought;
        for (uint256 i; i < statements; ++i) {
            uint256[] memory held = core.heldStatements();
            if (held.length == 0) break;
            uint256 sid = held[_rnd(held.length)];
            address who = _actor("trader", _rnd(TRADERS));
            _topUp(who, 10 ether, 60 ether);
            uint256 price = ctl.priceOf(sid);
            uint256 value = price + price / 50;
            if (who.balance < value + 0.1 ether) {
                console.log("buyers: statement not affordable, price", price);
                continue;
            }
            if (!_dry(who, address(ctl), value, abi.encodeCall(IControllerV1.buy, (sid)))) {
                console.log("buyers: statement skipped", sid);
                continue;
            }
            vm.broadcast(who);
            ctl.buy{value: value}(sid);
            console.log("buyers: statement", sid);
            console.log("buyers:   price / buyer", price, who);
            ++bought;
        }
        console.log("buyers: statements bought", bought);
        _buyCredits(1 + _rnd(4));
    }

    function _buyCredits(uint256 want) internal {
        uint256 bought;
        for (uint256 i; i < want; ++i) {
            uint256 size = core.pileSize();
            if (size == 0) break;
            uint256[] memory page = core.pilePage(0, size < 200 ? size : 200);
            uint256 id = page[_rnd(page.length)];
            address who = _actor("trader", _rnd(TRADERS));
            _topUp(who, 10 ether, 60 ether);
            uint256 price = ctl.creditPrice(id);
            uint256 value = price + price / 50;
            if (!_dry(who, address(ctl), value, abi.encodeCall(IControllerV1.buyCredit, (id)))) {
                console.log("buyers: credit skipped", id);
                continue;
            }
            vm.broadcast(who);
            ctl.buyCredit{value: value}(id);
            console.log("buyers: credit", id);
            console.log("buyers:   price / buyer", price, who);
            ++bought;
        }
        console.log("buyers: credits bought", bought);
    }

    // ------------------------------------------------------------------ 6 buyback

    function doBuyback() internal {
        _topUp(bot, 5 ether, 100 ether);
        if (!_dry(bot, address(core), 0, abi.encodeCall(ICore.buyback, ()))) {
            console.log("buyback: not eligible, ethToBuyback", core.ethToBuyback());
            return;
        }
        uint256 before = core.ethToBuyback();
        vm.broadcast(bot);
        core.buyback();
        console.log("buyback: pot before / after", before, core.ethToBuyback());
    }

    // ------------------------------------------------------------------ 7 balance

    /// the balance side: 1 to 2 redemptions of held statements at their floor, 1 to 3 holders selling credits for the
    /// balance token at the balance quote, and 1 to 2 sales for eth by other holders. needs the module set.
    function doBalance() internal {
        require(core.balanceModule() != address(0), "balance: no balance module, run the post phase");
        redeemHeld(1 + _rnd(2));
        uint256 maxCredits = vm.envOr("PEOPLE_CREDITS", uint256(3));
        uint256[] memory hs = _findHolders(5);
        uint256 nBalance = 1 + _rnd(3);
        uint256 creditsSold;
        uint256 holders;
        for (uint256 i; i < hs.length; ++i) {
            if (i < nBalance) {
                uint256 n = _sellBalance(hs[i], 1 + _rnd(maxCredits));
                if (n != 0) ++holders;
                creditsSold += n;
            } else {
                _sellEth(hs[i], 1 + _rnd(maxCredits));
            }
        }
        console.log("balance: holders selling for balance", holders);
        console.log("balance: credits sold for balance", creditsSold);
        console.log("balance: balanceRate bps", core.balanceRate());
        console.log("balance: module available", IBalanceModule(core.balanceModule()).available());
    }

    function redeemHeld(uint256 want) internal {
        uint256[] memory held = core.heldStatements();
        uint256 done;
        for (uint256 i; i < held.length && done < want; ++i) {
            if (!ctl.atFloor(held[i])) continue;
            _topUp(bot, 5 ether, 100 ether);
            if (!_dry(bot, address(core), 0, abi.encodeCall(ICore.redeemStatement, (held[i])))) {
                console.log("balance: redemption skipped", held[i]);
                continue;
            }
            vm.broadcast(bot);
            core.redeemStatement(held[i]);
            console.log("balance: redeemed statement", held[i]);
            ++done;
        }
        console.log("balance: statements redeemed", done);
    }

    function _sellBalance(uint256 k, uint256 n) internal returns (uint256 sold) {
        (address h, uint256[] memory ids) = _holding(k, n);
        uint256 avail = IBalanceModule(core.balanceModule()).available() * 9 / 10;
        uint256 sum;
        uint256 k;
        for (; k < ids.length; ++k) {
            uint256 bid = core.balanceBidOf(ids[k]);
            if (sum + bid > avail) break;
            sum += bid;
        }
        if (k == 0) {
            console.log("balance: module too short for holder", h);
            return 0;
        }
        assembly {
            mstore(ids, k)
        }
        _approveCredits(h);
        uint256 minOut = sum * (100 - (k < 40 ? k : 40)) / 100;
        bytes memory call = abi.encodeWithSignature("sellForBalance(uint256[],uint256)", ids, minOut);
        if (!_dry(h, address(core), 0, call)) {
            console.log("balance: sale skipped for holder", h);
            return 0;
        }
        vm.broadcast(h);
        core.sellForBalance(ids, minOut);
        console.log("balance: sellForBalance holder", h);
        console.log("balance:   credits / quote", k, sum);
        return k;
    }

    // ------------------------------------------------------------------ helpers

    function _rnd(uint256 n) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng % n;
    }

    /// @dev derived address of role `i`; the same on every run
    function _actor(string memory role, uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("cc-speedrun", role, i)))));
    }

    function _isActor(address a) internal pure returns (bool) {
        if (a == _actor("bot", 0) || a == _actor("composer", 0)) return true;
        for (uint256 i; i < TRADERS; ++i) {
            if (a == _actor("trader", i)) return true;
        }
        return false;
    }

    /// @dev raises the balance of `a` to `target` on the node and in the simulation when it is under `floor`
    function _topUp(address a, uint256 floor, uint256 target) internal {
        if (a.balance >= floor) return;
        vm.deal(a, target);
        vm.rpc("anvil_setBalance", string.concat('["', vm.toString(a), '","', vm.toString(bytes32(target)), '"]'));
    }

    /// @dev runs `data` against `to` from `from` in the simulation and reverts the state. true when the call succeeds
    function _dry(address from, address to, uint256 value, bytes memory data) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(from);
        (ok,) = to.call{value: value}(data);
        vm.revertToState(snap);
    }
}
