// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {HandlerBase} from "./HandlerBase.sol";
import {HandlerOwner} from "./HandlerOwner.sol";
import {MockBalanceModule} from "../standins/MockBalanceModule.sol";
import {SellingController} from "../attackers/SaleAttackers.sol";
import {ComposeCall} from "../utils/ComposeCall.sol";

/// @notice the sale controller and the owner as an adversary. actions: `buy` through the first controller, the
/// controller's own `sellTo` through a selling controller the owner installs, the controller's sale settings, the owner
/// swapping the controller and the balance module in one go, the three one way locks and the two step handover. every call is checked against a model written from docs/DECISIONS.md: who may
/// sell, at what least price, what is booked where, who holds the statement after. a refusal must carry the selector
/// the model names. nothing here reverts, a violation goes to `viol`.
abstract contract HandlerSale is HandlerOwner {
    /// the controller that sells statements for the owner, and its buyers
    SellingController public selling;
    /// every owner the run has had, in order, and the next heirs
    address[] public formerOwners;
    address[] public heirs;
    uint256 public heirNext;
    /// every balance module the owner ever installed: none may have called the core successfully from inside a redemption
    MockBalanceModule[] public modulesEver;
    /// the one way locks seen by the handler. they must never come undone
    bool public gLockedC;
    bool public gLockedE;
    bool public gLockedT;
    /// sales through `sellTo`
    uint256 public gSoldTo;
    /// the first controller's royalty owed and balance before the action under check
    uint256 internal _owed0;
    uint256 internal _ctlBal0;

    /// the fixture hands over what only it can build (from artifacts, so the contract stays small)
    function setSaleParts(address selling_, address[] calldata heirs_) external {
        selling = SellingController(payable(selling_));
        controllers.push(selling_);
        watched.push(selling_);
        _snapBase(selling_);
        for (uint256 i; i < heirs_.length; ++i) {
            heirs.push(heirs_[i]);
            watched.push(heirs_[i]);
            _snapBase(heirs_[i]);
        }
        if (address(module) != address(0)) modulesEver.push(module);
    }

    function moduleEverCount() external view returns (uint256) {
        return modulesEver.length;
    }

    /// the royalty on an engine price `price` at the first controller's current `royaltyBps`
    function _royaltyOn(uint256 price) internal view returns (uint256) {
        return price * IControllerV1(v1).royaltyBps() / 10_000;
    }

    function _bps() internal view returns (uint256) {
        return core.settings().saleToBuybackBps;
    }

    function _hardFloor(uint256 sid) internal view returns (uint256) {
        (, uint256 cost,) = core.statementInfo(sid);
        return cost * core.settings().saleFloorBps / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                         THE MODEL OF A SALE THROUGH sellTo
    //////////////////////////////////////////////////////////////*/

    struct SalePre {
        uint256 bal;
        uint256 pot;
        uint256 tb;
        uint256 rate;
        uint256 payerBal;
        uint256 held;
        uint256 bps;
        uint256 floor;
        uint256 price;
        uint256 value;
        address buyer;
        address payer;
        bytes4 want;
    }

    /// the refusal the core's own order of checks gives for a statement in ghost state `g` once the caller is the
    /// controller (`sellTo`): the pause, the record (a held statement), then the hard floor. zero when the sale must go
    /// through
    function _sellToRefusal(SG storage g, uint256 value, uint256 floor) internal view returns (bytes4) {
        if (core.paused()) return ICore.Paused.selector;
        if (g.status != S_HELD) return ICore.NotForSale.selector;
        if (value < floor) return ICore.BelowFloor.selector;
        return bytes4(0);
    }

    /// reads the books before a sale
    function _salePre(uint256 sid, address payer, address buyer, uint256 value) internal view returns (SalePre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        p.payerBal = payer.balance;
        p.held = core.heldStatements().length;
        p.bps = _bps();
        p.floor = _hardFloor(sid);
        p.value = value;
        p.buyer = buyer;
        p.payer = payer;
    }

    /// a sale went through: the whole payment is booked, split by saleToBuybackBps, the statement is with the buyer and
    /// the record is gone. the payment is at least the hard floor
    function _saleDone(uint256 sid, SalePre memory p, uint256 paid) internal {
        SG storage g = _sg[sid];
        if (p.want != 0) _flag(V_SALE_PATH, "a sale the model refuses went through");
        if (paid < p.floor) _flag(V_SALE_PATH, "a statement was sold below the hard floor");
        _eth(p.bal, 0, paid, "sellTo");
        uint256 toBb = paid * p.bps / 10_000;
        if (core.ethToBuyback() != p.tb + toBb || core.ethPot() != p.pot + paid - toBb) {
            _flag(V_SALE_PATH, "the sale payment was not booked exactly, split by saleToBuybackBps");
        }
        _booked(paid);
        if (_ownerOf(sid) != p.buyer) _flag(V_SALE_PATH, "the buyer does not hold the statement");
        (bool held,,) = core.statementInfo(sid);
        if (held || core.heldStatements().length != p.held - 1) _flag(V_SALE_PATH, "the core record was not cleared");
        g.status = S_SOLD;
        g.price = paid;
        g.buyer = p.buyer;
        g.floor = p.floor;
        gSoldTo++;
    }

    /// a refused sale changes nothing: books, holder, record
    function _saleRefused(uint256 sid, SalePre memory p, bytes memory why, uint8 a) internal {
        _failed(p.bal, p.pot, p.rate, "sale");
        if (core.ethToBuyback() != p.tb) _flag(V_REVERT_CHANGED, "a refused sale moved the buyback pot");
        SG storage g = _sg[sid];
        if (g.status == S_HELD && _ownerOf(sid) != address(core)) _flag(V_SALE_PATH, "a refused sale moved a statement");
        if (p.want == 0 || bytes4(why) != p.want) _unexpected(a, why);
    }

    /*//////////////////////////////////////////////////////////////
                         buy (the first controller)
    //////////////////////////////////////////////////////////////*/

    /// the refusal of `ControllerV1.buy` in the order of its checks: the record `priceOf` reads, the payment, the
    /// controller in force (the core takes `sellTo` from the controller only), then what `sellTo` checks, the pause first
    function _buyRefusal(uint256 sid, SalePre memory p, bool short_) internal view returns (bytes4) {
        (bool held,,) = core.statementInfo(sid);
        if (!held) return IControllerV1.NotForSale.selector;
        if (short_) return IControllerV1.Underpaid.selector;
        if (core.controller() != v1) return ICore.OnlyController.selector;
        return _sellToRefusal(_sg[sid], p.price, p.floor);
    }

    uint256 internal _anchor0;
    uint256 internal _cost0;
    uint256 internal _ref0;
    uint256 internal _stored0;
    uint256 internal _anchorTime0;

    /// the anchor after a sale at `price` of a statement of cost `cost` and reference `ref`: the anchor now when `cost`
    /// is under `anchorMinCost` or the sale price in bps of the reference (rounded up) is not above it, otherwise the
    /// mean of the two, at most the start cap
    function _anchorAfter(uint256 anchor0, uint256 price, uint256 cost, uint256 ref)
        internal
        view
        returns (uint256 next)
    {
        uint256 saleBps = (price * 10_000 + ref - 1) / ref;
        if (cost < IControllerV1(v1).anchorMinCost() || saleBps <= anchor0) return anchor0;
        next = (anchor0 + saleBps) / 2;
        uint256 cap = IControllerV1(v1).startCapBps();
        if (next > cap) next = cap;
    }

    /// reads the royalty owed and the balance of the first controller before a sale
    function _royaltyPre() internal {
        _owed0 = IControllerV1(v1).royaltyOwed();
        _ctlBal0 = address(v1).balance;
    }

    /// after a sale that collected `royalty`, the first controller owes `royalty` more and holds `royalty` more eth
    function _royaltyCheck(uint256 royalty) internal {
        if (IControllerV1(v1).royaltyOwed() != _owed0 + royalty) {
            _flag(V_SALE_PATH, "royaltyOwed differs from the royalty of the sale");
        }
        if (address(v1).balance != _ctlBal0 + royalty) _flag(V_SALE_PATH, "the controller holds other than the royalty owed");
    }

    /// anyone claims the royalty: the recipient receives exactly what is owed and nothing stays in the controller
    function _claimChecked() internal {
        IControllerV1 c = IControllerV1(v1);
        address to = c.royaltyRecipient();
        uint256 owed = c.royaltyOwed();
        if (owed == 0) return;
        uint256 before_ = to.balance;
        _ctlBal0 = address(c).balance;
        (bool ok,) = address(c).call(abi.encodeCall(IControllerV1.claimRoyalty, ()));
        if (!ok) {
            _flag(V_SALE_PATH, "claimRoyalty reverted with a royalty owed");
            return;
        }
        if (to.balance - before_ != owed) _flag(V_SALE_PATH, "the recipient did not receive the royalty owed");
        if (c.royaltyOwed() != 0 || address(c).balance != _ctlBal0 - owed) {
            _flag(V_SALE_PATH, "the controller kept eth after the royalty claim");
        }
    }

    /// a buyer pays the asking price of the first controller plus the royalty, with an excess now and then and a short
    /// payment now and then. with another controller in force, on a sold, redeemed or balance side statement it must
    /// refuse with the model's selector. a sale pays the ask and the royalty exactly, the excess comes back
    function buy(uint256 sIdx, uint256 aSeed, uint256 xSeed, uint256 mode) external checked {
        uint8 a = A_BUY;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 4 == 0 ? K_ANY : K_HELD);
        if (!found) return _skip(a);
        // the owner, now and then, puts the first controller back in force: a legal owner move that keeps the buy path
        // busy under the fuzzer. a locked controller door is left alone
        if (mode % 3 == 1) {
            vm.startPrank(owner);
            if (core.controller() != v1 && !core.controllerLocked()) core.setController(v1);
            vm.stopPrank();
        }
        address who = _actor(aSeed);
        uint256 price;
        bool priced;
        try IControllerV1(v1).priceOf(sid) returns (uint256 pr) {
            price = pr;
            priced = true;
        } catch {}
        if (priced && price != _modelAsk(sid)) {
            _flag(V_SALE_PATH, "the asking price differs from the curve at the age outside every pause");
        }
        uint256 gross = price + _royaltyOn(price);
        if (priced && IControllerV1(v1).grossPriceOf(sid) != gross) {
            _flag(V_SALE_PATH, "the gross price is not the asking price plus the royalty");
        }
        bool short_ = priced && price != 0 && xSeed % 7 == 0;
        uint256 value = !priced ? 1 ether : (short_ ? gross - 1 : gross + (xSeed % 3 == 0 ? 0 : _logBound(xSeed, 1, 1 ether)));
        SalePre memory p = _salePre(sid, who, who, value);
        _royaltyPre();
        p.price = price;
        p.want = _buyRefusal(sid, p, short_);
        vm.deal(who, who.balance + value);
        p.payerBal = who.balance;
        RS memory rs = _rs();
        _anchor0 = IControllerV1(v1).anchorBps();
        _stored0 = IControllerV1(v1).storedAnchorBps();
        _anchorTime0 = IControllerV1(v1).anchorTime();
        (, _cost0,) = core.statementInfo(sid);
        // referenceOf reverts for a statement the core no longer holds, so the reference is modelled here and matches
        // the controller's for a held statement
        _ref0 = _modelRef(sid, _cost0);
        _att(a);
        vm.prank(who);
        try IControllerV1(v1).buy{value: value}(sid) {
            _ok(a);
            if (IControllerV1(v1).anchorBps() != _anchorAfter(_anchor0, price, _cost0, _ref0)) {
                _flag(V_SALE_PATH, "a buy did not move the anchor halfway to the sale price");
            }
            if (
                ((price * 10_000 + _ref0 - 1) / _ref0 <= _anchor0 || _cost0 < IControllerV1(v1).anchorMinCost())
                    && (IControllerV1(v1).storedAnchorBps() != _stored0 || IControllerV1(v1).anchorTime() != _anchorTime0)
            ) {
                _flag(V_SALE_PATH, "a buy at or below the anchor, or of a statement under the minimum cost, stored the anchor");
            }
            if (p.payerBal - who.balance != gross) {
                _flag(V_SALE_PATH, "the buyer did not pay exactly the ask plus the royalty, or the excess was not refunded");
            }
            _royaltyCheck(gross - price);
            _saleDone(sid, p, price);
            if (mode % 5 == 2) _claimChecked();
        } catch (bytes memory why) {
            _saleRefused(sid, p, why, a);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         buyCredit (the credit sale window)
    //////////////////////////////////////////////////////////////*/

    /// the number of ghost credits in the pile now
    function _piledCount() internal view returns (uint256 n) {
        for (uint256 i; i < cgList.length; ++i) {
            if (cg[cgList[i]].inPile) n++;
        }
    }

    /// an in-pile ghost credit from `seed` on. not found when the pile is empty
    function _pickPiled(uint256 seed) internal view returns (uint256 id, uint256 cost, bool found) {
        uint256 n = cgList.length;
        if (n == 0) return (0, 0, false);
        for (uint256 k; k < n; ++k) {
            uint256 cand = cgList[(seed % n + k) % n];
            if (cg[cand].inPile) return (cand, cg[cand].cost, true);
        }
        return (0, 0, false);
    }

    /// the refusal of `ControllerV1.buyCredit` in the order of its checks: the sale window, the price read
    /// (`priceErr`, nonzero when `creditPrice` reverts, e.g. NotForSale for a credit not in the pile), the payment,
    /// then the core's `sellCreditTo`, which refuses any controller but the one the core named, then a pause
    function _buyCreditRefusal(bool saleOn, bool paused_, bytes4 priceErr, bool short_, bool realCtl)
        internal
        pure
        returns (bytes4)
    {
        if (!saleOn) return IControllerV1.CreditSaleOff.selector;
        if (priceErr != 0) return priceErr;
        if (short_) return IControllerV1.Underpaid.selector;
        if (!realCtl) return ICore.OnlyController.selector;
        if (paused_) return ICore.Paused.selector;
        return bytes4(0);
    }

    /// the quote of a credit buy: the price (or batch total), the value the buyer sends, and the selector the model
    /// expects when the call must revert
    struct CQ {
        uint256 price;
        uint256 royalty;
        uint256 value;
        bytes4 want;
    }

    /// the value a buyer sends: a placeholder when no price was read, a short payment, or the price with an excess
    function _creditValue(bool priced, uint256 price, bool short_, uint256 xSeed) internal view returns (uint256) {
        if (!priced) return 1 ether;
        if (short_) return price - 1;
        return price + (xSeed % 3 == 0 ? 0 : _logBound(xSeed, 1, 1 ether));
    }

    function _quoteOne(uint256 id, uint256 xSeed) internal view returns (CQ memory q) {
        IControllerV1 c = IControllerV1(v1);
        bool priced;
        bytes4 priceErr;
        try c.creditPrice(id) returns (uint256 pr) {
            q.price = pr;
            priced = true;
        } catch (bytes memory reason) {
            priceErr = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        }
        q.royalty = _royaltyOn(q.price);
        bool short_ = priced && q.price != 0 && xSeed % 7 == 0;
        q.value = _creditValue(priced, q.price + q.royalty, short_, xSeed);
        q.want = _buyCreditRefusal(c.creditSaleOn(), core.paused(), priceErr, short_, core.controller() == v1);
    }

    function _quoteMany(uint256[] memory ids, uint256 xSeed) internal view returns (CQ memory q) {
        IControllerV1 c = IControllerV1(v1);
        bool priced = true;
        bytes4 priceErr;
        for (uint256 i; i < ids.length; ++i) {
            try c.creditPrice(ids[i]) returns (uint256 pr) {
                q.price += pr;
                q.royalty += _royaltyOn(pr);
            } catch (bytes memory reason) {
                priced = false;
                // the batch loop prices ids in order and reverts at the first credit whose price reverts, so the first
                // reverting selector governs
                if (priceErr == 0) priceErr = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            }
        }
        bool short_ = priced && q.price != 0 && xSeed % 6 == 0;
        q.value = _creditValue(priced, q.price + q.royalty, short_, xSeed);
        q.want = _buyCreditsRefusal(c.creditSaleOn(), core.paused(), priceErr, short_, core.controller() == v1);
    }

    /// the refusal of `ControllerV1.buyCredits` in the order its one pass loop reaches: the sale window, then per
    /// credit a price read, a payment check and the core's `sellCreditTo`. a price read that reverts on ids[0]
    /// precedes both. a short batch payment is `total - 1`, which clears the first credit's cumulative check, so a
    /// wrong controller reverts `OnlyController` and a pause reverts `Paused` on the first sale before the short
    /// payment reverts `Underpaid` on the last credit. this flips the payment and controller order of
    /// the single `buyCredit` refusal
    function _buyCreditsRefusal(bool saleOn, bool paused_, bytes4 priceErr, bool short_, bool realCtl)
        internal
        pure
        returns (bytes4)
    {
        if (!saleOn) return IControllerV1.CreditSaleOff.selector;
        // the price read of ids[0] runs before its payment check and its `sellCreditTo`, so a price revert precedes the
        // wrong controller and the short payment
        if (priceErr != 0) return priceErr;
        if (!realCtl) return ICore.OnlyController.selector;
        if (paused_) return ICore.Paused.selector;
        if (short_) return IControllerV1.Underpaid.selector;
        return bytes4(0);
    }

    /// a buyer pays the curve price of one pile credit through the first controller, with an excess or a short payment
    /// now and then. a sale pays the price exactly and refunds the rest, the credit leaves the pile to the buyer, the
    /// cost share goes to the pot and the markup to the buyback, and no credit leaves for less than its recorded cost
    function buyCredit(uint256 sSeed, uint256 aSeed, uint256 xSeed) external checked {
        uint8 a = A_BUY_CREDIT;
        (uint256 id, uint256 cost, bool found) = _pickPiled(sSeed);
        if (!found) return _skip(a);
        CQ memory q = _quoteOne(id, xSeed);
        address who = _actor(aSeed);
        CreditPre memory p = _creditPre(q.value);
        vm.deal(who, who.balance + q.value);
        p.payerBal = who.balance;
        _royaltyPre();
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try IControllerV1(v1).buyCredit{value: q.value}(id) {
            _ok(a);
            if (q.want != 0) _flag(V_SALE_PATH, "a credit sale the model refuses went through");
            _afterCreditBuyOne(id, cost, q.price, q.royalty, p, who);
        } catch (bytes memory why) {
            _creditRefused(p, why, a, q.want);
        }
        _rsCheck(rs, 0);
    }

    /// a buyer pays the sum of the curve prices of a batch of pile credits. the batch total is read before any sale, so
    /// a sale does not raise the price of a later credit in the same batch
    function buyCredits(uint256 sSeed, uint256 aSeed, uint256 xSeed) external checked {
        uint8 a = A_BUY_CREDITS;
        uint256 avail = _piledCount();
        if (avail < 2) return _skip(a);
        (uint256[] memory ids, uint256[] memory costs) = _pickPiledMany(sSeed, bound(xSeed, 2, avail < 5 ? avail : 5));
        if (ids.length < 2) return _skip(a);
        CQ memory q = _quoteMany(ids, xSeed);
        address who = _actor(aSeed);
        CreditPre memory p = _creditPre(q.value);
        vm.deal(who, who.balance + q.value);
        p.payerBal = who.balance;
        _royaltyPre();
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try IControllerV1(v1).buyCredits{value: q.value}(ids) {
            _ok(a);
            if (q.want != 0) _flag(V_SALE_PATH, "a credit batch the model refuses went through");
            _afterCreditBuy(ids, costs, q.price, q.royalty, p, who);
        } catch (bytes memory why) {
            _creditRefused(p, why, a, q.want);
        }
        _rsCheck(rs, 0);
    }

    /// up to `want` distinct in-pile ghost credits from `seed` on, with their recorded costs
    function _pickPiledMany(uint256 seed, uint256 want_)
        internal
        view
        returns (uint256[] memory ids, uint256[] memory costs)
    {
        uint256 cap = cgList.length;
        uint256[] memory tmp = new uint256[](want_);
        uint256[] memory tmpCost = new uint256[](want_);
        uint256 got;
        for (uint256 k; k < cap && got < want_; ++k) {
            uint256 cand = cgList[(seed % cap + k) % cap];
            if (!cg[cand].inPile) continue;
            bool dup;
            for (uint256 j; j < got; ++j) {
                if (tmp[j] == cand) dup = true;
            }
            if (dup) continue;
            tmp[got] = cand;
            tmpCost[got] = cg[cand].cost;
            got++;
        }
        ids = new uint256[](got);
        costs = new uint256[](got);
        for (uint256 i; i < got; ++i) {
            ids[i] = tmp[i];
            costs[i] = tmpCost[i];
        }
    }

    struct CreditPre {
        uint256 bal;
        uint256 pot;
        uint256 tb;
        uint256 rate;
        uint256 payerBal;
        uint256 value;
    }

    function _creditPre(uint256 value) internal view returns (CreditPre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        p.value = value;
    }

    function _afterCreditBuyOne(uint256 id, uint256 cost, uint256 price, uint256 royalty, CreditPre memory p, address who)
        internal
    {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory costs = new uint256[](1);
        ids[0] = id;
        costs[0] = cost;
        _afterCreditBuy(ids, costs, price, royalty, p, who);
    }

    /// a credit sale went through: the buyer paid the price and the royalty exactly and got the excess back, the credits left the pile
    /// to the buyer, the cost share went to the pot and the markup to the buyback, and no credit left for less than its
    /// recorded cost
    function _afterCreditBuy(
        uint256[] memory ids,
        uint256[] memory costs,
        uint256 price,
        uint256 royalty,
        CreditPre memory p,
        address who
    ) internal {
        if (p.payerBal - who.balance != price + royalty) {
            _flag(V_SALE_PATH, "the credit buyer did not pay exactly the price plus the royalty");
        }
        uint256 toPotSum;
        uint256 costSum;
        for (uint256 i; i < ids.length; ++i) {
            if (CREDITS.ownerOf(ids[i]) != who) _flag(V_SALE_PATH, "the credit buyer does not hold the credit");
            (bool inPile,,) = core.creditInfo(ids[i]);
            if (inPile) _flag(V_SALE_PATH, "a sold credit still has a pile record");
            cg[ids[i]].inPile = false;
            toPotSum += costs[i] * core.creditCostToPotBps() / 10_000;
            costSum += costs[i];
        }
        // no credit leaves the pot for less than it was bought for: the price is at least the sum of the costs
        if (price < costSum) _flag(V_SALE_PATH, "a credit was sold below its recorded cost");
        if (core.ethPot() != p.pot + toPotSum || core.ethToBuyback() != p.tb + price - toPotSum) {
            _flag(V_SALE_PATH, "the credit sale payment was not booked by creditCostToPotBps");
        }
        _eth(p.bal, 0, price, "credit buy");
        _booked(price);
        _royaltyCheck(royalty);
    }

    function _creditRefused(CreditPre memory p, bytes memory why, uint8 a, bytes4 want) internal {
        _failed(p.bal, p.pot, p.rate, "credit sale");
        if (core.ethToBuyback() != p.tb) _flag(V_REVERT_CHANGED, "a refused credit sale moved the buyback pot");
        if (want == 0 || bytes4(why) != want) _unexpected(a, why);
    }

    /*//////////////////////////////////////////////////////////////
                              the pause of the Core
    //////////////////////////////////////////////////////////////*/

    /// the pauses the handler applied to the Core: start and end, an end of 0 for the open pause. the ghost
    /// integrates the overlap of a pause with a statement's life, so it is a model of the age that does not share the
    /// accumulator arithmetic of the Core. the Core's `pausedTotal` and `pausedSince` are compared with it
    uint256[] internal _pauseStart;
    uint256[] internal _pauseEnd;

    function pauseCount() external view returns (uint256) {
        return _pauseStart.length;
    }

    function _modelPaused() internal view returns (bool) {
        uint256 n = _pauseEnd.length;
        return n != 0 && _pauseEnd[n - 1] == 0;
    }

    /// the age of a statement composed at `composedAt`: the seconds to now outside every pause
    function _modelAge(uint256 composedAt) internal view returns (uint256 age) {
        age = block.timestamp - composedAt;
        for (uint256 i; i < _pauseStart.length; ++i) {
            uint256 s = _pauseStart[i] > composedAt ? _pauseStart[i] : composedAt;
            uint256 e = _pauseEnd[i] == 0 ? block.timestamp : _pauseEnd[i];
            if (e > s) age -= e - s;
        }
    }

    /// the Core's accumulator against the ghost pauses: `pausedTotal` is the length of the closed pauses and
    /// `pausedSince` the start of the open one
    function _checkPauseClock() internal {
        uint256 closed;
        for (uint256 i; i < _pauseStart.length; ++i) {
            if (_pauseEnd[i] != 0) closed += _pauseEnd[i] - _pauseStart[i];
        }
        uint256 open = _modelPaused() ? _pauseStart[_pauseStart.length - 1] : 0;
        if (core.pausedTotal() != closed || core.pausedSince() != open) {
            _flag(V_SALE_PATH, "the pause clock of the core differs from the model");
        }
    }

    /// the asking price of statement `sid` written out again from docs/SPEC.md section 7: the price in units of
    /// 1/3600 bps falls `fastDecayBpsPerHour` a second to the knee and `slowDecayBpsPerHour` after it (rounded up), at
    /// the age outside every pause, at least `saleFloorBps` of the reference
    function _modelAsk(uint256 sid) internal returns (uint256) {
        (, uint256 cost, uint64 at) = core.statementInfo(sid);
        uint256 ref = _modelRef(sid, cost);
        uint256 n = _modelUnits(_modelAge(at));
        uint256 ask = ref * n / (3600 * 10_000);
        uint256 hard = cost * core.settings().saleFloorBps / 10_000;
        return ask < hard ? hard : ask;
    }

    /// the price reference of statement `sid`: the larger of its cost and `valueOf(rating)`, the same value the
    /// controller prices against. `valueOf` is at least the floor rate times the rating over `refScore`, which is
    /// written out here (the product cannot overflow a word, so the plain divide matches the controller `mulDiv`)
    function _modelRef(uint256 sid, uint256 cost) internal returns (uint256) {
        uint256 rating = core.ratingOf(sid);
        uint256 rate = core.floorRate() * rating / uint256(IControllerV1(v1).refScore());
        uint256 value = IControllerV1(v1).valueOf(rating);
        if (value < rate) _flag(V_SALE_PATH, "valueOf is below the floor rate times the points over refScore");
        return value > cost ? value : cost;
    }

    function _modelUnits(uint256 age) internal view returns (uint256 n) {
        IControllerV1 c = IControllerV1(v1);
        uint256 start = c.startBps() * 3600;
        uint256 knee = uint256(c.kneeBps()) * 3600;
        uint256 fast = c.fastDecayBpsPerHour();
        uint256 span = start > knee ? start - knee : 0;
        if (age * fast <= span) {
            n = start - age * fast;
        } else {
            uint256 drop = (c.slowDecayBpsPerHour() * (age * fast - span) + fast - 1) / fast;
            uint256 base = start < knee ? start : knee;
            n = base > drop ? base - drop : 0;
        }
        uint256 low = uint256(core.settings().saleFloorBps) * 3600;
        if (n < low) n = low;
    }

    /// the owner pauses or resumes sales on the Core, or a stranger tries. a repeat of the current state is
    /// accepted and changes nothing. a stranger gets OnlyOwner. the state reads back as the model says, and no asset or
    /// pot moves
    function pause(uint256 seed, uint256 mode) external checked {
        uint8 a = A_PAUSE;
        bool stranger = mode % 5 == 0;
        bool want = (mode >> 4) % 8 < 2;
        bool was = core.paused();
        if (was != _modelPaused()) _flag(V_SALE_PATH, "the pause state differs from the model");
        OPre memory pre = _opre();
        _att(a);
        vm.prank(stranger ? address(uint160(uint256(keccak256(abi.encode("stranger", seed))))) : owner);
        (bool ok, bytes memory out) = address(core).call(abi.encodeCall(ICore.setPaused, (want)));
        if (stranger) {
            if (ok) _flag(V_OWNER, "a stranger changed the pause");
            else if (bytes4(out) != ICore.OnlyOwner.selector) _unexpected(a, out);
        } else if (!ok) {
            _unexpected(a, out);
        } else if (want != was) {
            if (want) {
                _pauseStart.push(block.timestamp);
                _pauseEnd.push(0);
            } else {
                _pauseEnd[_pauseEnd.length - 1] = block.timestamp;
            }
        }
        if (core.paused() != (stranger || !ok ? was : want)) _flag(V_SALE_PATH, "the pause state differs from the model");
        _checkPauseClock();
        _opost(pre, "pause");
        _ok(a);
    }

    /// the owner's controller, when the owner has installed the selling one, sells at the payment the caller sends: below
    /// the hard floor it refuses, at or above it sells to a buyer the owner chose (an actor or a fresh address). the whole
    /// payment is booked. with another controller in force the call is refused for OnlyController
    function ownerSell(uint256 sIdx, uint256 aSeed, uint256 vSeed, uint256 mode) external checked {
        uint8 a = A_OWNER_SELL;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 3 == 0 ? K_ANY : K_HELD);
        if (!found) return _skip(a);
        if (mode % 2 == 0 && core.controller() != address(selling) && !core.controllerLocked()) {
            vm.prank(owner);
            core.setController(address(selling));
        }
        if (core.controller() != address(selling) && aSeed % 4 != 0) return _skip(a);
        address who = _actor(aSeed);
        address buyer = mode % 5 == 0 ? _actor(vSeed) : address(uint160(uint256(keccak256(abi.encode("buyer", vSeed)))));
        uint256 floor = _hardFloor(sid);
        uint256 m = (mode >> 4) % 5;
        uint256 value = m == 0 ? (floor == 0 ? 0 : floor - 1) : m == 1
            ? floor
            : m == 2 ? floor + _logBound(vSeed, 1, 1 ether) : m == 3 ? floor * 2 : 0;
        SalePre memory p = _salePre(sid, who, buyer, value);
        p.want = core.controller() != address(selling) ? ICore.OnlyController.selector : _sellToRefusal(_sg[sid], value, floor);
        vm.deal(who, who.balance + value);
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try selling.sell{value: value}(sid, buyer) {
            _ok(a);
            _saleDone(sid, p, value);
        } catch (bytes memory why) {
            _saleRefused(sid, p, why, a);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    the controller's sale settings
    //////////////////////////////////////////////////////////////*/

    /// @dev the sale setting the handler tries: its selector, the value, and whether the model says it is inside the bounds
    /// (a helper so the locals of `saleSettings` fit the stack). `cur` is the live value of the setting
    function _saleCase(IControllerV1 c, uint256 seed, uint256 which, bool bad)
        internal
        view
        returns (bytes4 sel, uint256 v, bool valid, uint256 cur)
    {
        uint256 cap = c.startCapBps();
        uint256 knee = c.kneeBps();
        if (which == 0) {
            sel = IControllerV1.setMarkupBps.selector;
            cur = c.markupBps();
            v = bad ? (seed % 2 == 0 ? 9_999 : 40_001) : _f(seed, 10_000, 40_000, cur);
            valid = v >= 10_000 && v <= 40_000 && v <= cap;
        } else if (which == 1) {
            sel = IControllerV1.setStartCapBps.selector;
            cur = cap;
            v = bad
                ? (seed % 3 == 0 ? c.markupBps() - 1 : (seed % 3 == 1 ? 200_001 : knee - 1))
                : _f(seed, _max(c.markupBps(), knee), 200_000, cur);
            valid = v >= c.markupBps() && v >= knee && v <= 200_000;
        } else if (which == 2) {
            sel = IControllerV1.setFastDecayBpsPerHour.selector;
            cur = c.fastDecayBpsPerHour();
            v = bad ? (seed % 2 == 0 ? 0 : 10_001) : _f(seed, 1, 10_000, cur);
            valid = v >= 1 && v <= 10_000;
        } else if (which == 3) {
            sel = IControllerV1.setSlowDecayBpsPerHour.selector;
            cur = c.slowDecayBpsPerHour();
            v = bad ? (seed % 2 == 0 ? 0 : 10_001) : _f(seed, 1, 10_000, cur);
            valid = v >= 1 && v <= 10_000;
        } else if (which == 4) {
            sel = IControllerV1.setKneeBps.selector;
            cur = knee;
            v = bad ? (seed % 2 == 0 ? 999 : cap + 1) : _f(seed, 1_000, cap, cur);
            valid = v >= 1_000 && v <= cap;
        } else if (which == 5) {
            sel = IControllerV1.setRoyaltyBps.selector;
            cur = c.royaltyBps();
            v = bad ? 1_001 + seed % 60_000 : _f(seed, 0, 1_000, cur);
            valid = v <= 1_000;
        } else if (which == 6) {
            sel = IControllerV1.setAnchorBps.selector;
            cur = c.anchorBps();
            v = bad ? (seed % 2 == 0 ? 9_999 : cap + 1) : _f(seed, 10_000, cap, cur);
            valid = v >= 10_000 && v <= cap;
        } else if (which == 7) {
            sel = IControllerV1.setAnchorHalfLife.selector;
            cur = c.anchorHalfLife();
            v = bad ? (seed % 2 == 0 ? 1 days - 1 : 90 days + 1) : _f(seed, 1 days, 90 days, cur);
            valid = v >= 1 days && v <= 90 days;
        } else {
            sel = IControllerV1.setAnchorMinCost.selector;
            cur = c.anchorMinCost();
            v = bad ? 10 ether + 1 + seed % 1e18 : _f(seed, 0, 10 ether, cur);
            valid = v <= 10 ether;
        }
    }

    function _max(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x : y;
    }

    function _saleGot(IControllerV1 c, uint256 which) internal view returns (uint256) {
        if (which == 0) return c.markupBps();
        if (which == 1) return c.startCapBps();
        if (which == 2) return c.fastDecayBpsPerHour();
        if (which == 3) return c.slowDecayBpsPerHour();
        if (which == 4) return c.kneeBps();
        if (which == 5) return c.royaltyBps();
        if (which == 6) return c.anchorBps();
        if (which == 7) return c.anchorHalfLife();
        return c.anchorMinCost();
    }

    /// the owner sets one of the nine sale numbers (the royalty included) of the first controller to a value inside or outside the bounds of
    /// docs/DECISIONS.md 9.3 (written out again here), or a stranger tries. inside: it goes through and reads back. outside:
    /// BadSetting with the field. a stranger: OnlyOwner. no asset or pot moves
    function saleSettings(uint256 seed, uint256 mode) external checked {
        uint8 a = A_SALE_SETTINGS;
        IControllerV1 c = IControllerV1(v1);
        uint256 which = mode % 9;
        bool stranger = (mode >> 8) % 6 == 0;
        uint256 anchor0 = c.anchorBps();
        bool bad = (mode >> 12) % 4 == 0;
        (bytes4 sel, uint256 v, bool valid, uint256 cur) = _saleCase(c, seed, which, bad);
        address caller = stranger ? address(uint160(uint256(keccak256(abi.encode("stranger", seed))))) : owner;
        OPre memory pre = _opre();
        _att(a);
        vm.prank(caller);
        (bool ok, bytes memory out) = address(c).call(abi.encodeWithSelector(sel, v));
        bytes4 want = stranger ? IControllerV1.OnlyOwner.selector : (valid ? bytes4(0) : IControllerV1.BadSetting.selector);
        if (ok) {
            if (want != 0) _flag(V_OWNER, "a sale setting the model refuses was accepted");
            if (_saleGot(c, which) != v) _flag(V_OWNER, "a sale setting did not read back");
            if (which == 7 && c.anchorBps() != anchor0) _flag(V_OWNER, "a half life change moved the anchor");
            gOwnerCalls++;
        } else {
            if (want == 0 || bytes4(out) != want) _unexpected(a, out);
            if (_saleGot(c, which) != cur) _flag(V_OWNER, "a refused sale setting changed a value");
            gOwnerRefused++;
        }
        _opost(pre, "saleSettings");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                    the owner swapping the controller and the module
    //////////////////////////////////////////////////////////////*/

    /// the call a hostile module makes from inside a redemption: nothing, or one door of the core, or the selling controller.
    /// k = 1..11 selects compose, book, buyback, redeemStatement, the selling controller's sell, adopt, releaseRedeemBurn,
    /// sellForEth, buyListing, sellTo and sellForBalance
    function _callout(uint256 k, uint256 seed, MockBalanceModule next) internal {
        if (k == 0) return;
        address target = address(core);
        bytes memory data;
        uint256 n = everHeld.length;
        uint256 sid = n == 0 ? 1 : everHeld[seed % n];
        uint256[] memory ids = new uint256[](1);
        ids[0] = seed >> 8;
        if (k == 1) data = ComposeCall.noArgs();
        else if (k == 2) data = abi.encodeCall(ICore.book, ());
        else if (k == 3) data = abi.encodeCall(ICore.buyback, ());
        else if (k == 4) data = abi.encodeCall(ICore.redeemStatement, (sid));
        else if (k == 6) data = abi.encodeCall(ICore.adopt, (ids));
        else if (k == 7) data = abi.encodeCall(ICore.releaseRedeemBurn, (1));
        else if (k == 8) data = abi.encodeWithSignature("sellForEth(uint256[])", ids);
        else if (k == 9) data = abi.encodeCall(ICore.buyListing, (rawAdapter, seed >> 8, abi.encode(address(next), uint256(1), bytes(""))));
        else if (k == 10) data = abi.encodeCall(ICore.sellTo, (sid, address(next)));
        else if (k == 11) data = abi.encodeWithSignature("sellForBalance(uint256[])", ids);
        else {
            target = address(selling);
            data = abi.encodeCall(SellingController.sell, (sid, address(next)));
        }
        next.setCall(target, data);
    }

    /// the owner replaces the controller and, in the balance side, the balance module in one go. the controller is any of the three
    /// the run knows, the module a new one with the same balance token, a new unit, and now and then a gas burning body and a
    /// call into the core from inside the redemption. both take effect at once unless the owner locked the door. the call must
    /// not move an asset or a pot, and no call from inside a redemption may ever go through
    function hostileOwner(uint256 seed, uint256 mode) external checked {
        uint8 a = A_HOSTILE_OWNER;
        address c = seed % 3 == 0 ? v1 : (seed % 3 == 1 && canSwapController ? address(fuzz) : address(selling));
        bool swapMod = phase2() && mode % 2 == 0;
        MockBalanceModule next;
        if (swapMod) {
            next = new MockBalanceModule(core.balanceToken(), _logBound(seed >> 8, 2e9, 5e10));
            uint256 burn = (mode >> 4) % 4;
            if (burn == 1) next.setBurn(300_000);
            else if (burn == 2) next.setBurn(2_000_000);
            _callout((mode >> 8) % 12, seed >> 16, next);
        }
        bool lockedC = core.controllerLocked();
        bool lockedE = core.balanceModuleLocked();
        address oldC = core.controller();
        address oldM = core.balanceModule();
        OPre memory pre = _opre();
        _att(a);
        vm.startPrank(owner);
        (bool okC,) = address(core).call(abi.encodeCall(ICore.setController, (c)));
        bool okM = true;
        if (swapMod) (okM,) = address(core).call(abi.encodeCall(ICore.setBalanceModule, (address(next))));
        vm.stopPrank();
        if (okC == lockedC) _flag(V_LOCK, "the controller door and its lock disagree");
        if (core.controller() != (okC ? c : oldC)) _flag(V_OWNER, "the controller is not what the owner set at once");
        if (swapMod) {
            if (okM == lockedE) _flag(V_LOCK, "the balance module door and its lock disagree");
            if (core.balanceModule() != (okM ? address(next) : oldM)) _flag(V_OWNER, "the balance module is not what the owner set");
            if (okM) {
                module = next;
                modulesEver.push(next);
            }
        }
        _opost(pre, "hostileOwner");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                                 LOCKS
    //////////////////////////////////////////////////////////////*/

    /// the owner closes a door for good, or a stranger tries. rare: the lock stays for the rest of the run. afterwards the
    /// setter of that door reverts with Locked, and the other doors stay open
    function lockDoor(uint256 seed, uint256 mode) external checked {
        uint8 a = A_LOCK;
        if (seed % 5 != 0) return _skip(a);
        uint256 which = mode % 3;
        address stranger = address(uint160(uint256(keccak256(abi.encode("locker", seed)))));
        OPre memory pre = _opre();
        _att(a);
        bytes memory data = abi.encodeWithSelector(
            which == 0 ? ICore.lockController.selector : (which == 1 ? ICore.lockBalanceModule.selector : ICore.lockAdapters.selector)
        );
        vm.prank(stranger);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok || bytes4(out) != ICore.OnlyOwner.selector) _flag(V_LOCK, "a stranger locked a door");
        bool noModule = which == 1 && core.balanceModule() == address(0);
        vm.prank(owner);
        (ok, out) = address(core).call(data);
        if (noModule) {
            if (ok || bytes4(out) != ICore.NoBalanceModule.selector) _flag(V_LOCK, "the module lock worked with no module");
        } else {
            if (!ok) _flag(V_LOCK, "the owner could not lock a door");
            bool nowLocked = which == 0 ? core.controllerLocked() : (which == 1 ? core.balanceModuleLocked() : core.adaptersLocked());
            if (!nowLocked) _flag(V_LOCK, "a lock did not set its flag");
            if (which == 0) gLockedC = true;
            else if (which == 1) gLockedE = true;
            else gLockedT = true;
            _setterShut(which);
        }
        _opost(pre, "lockDoor");
        _ok(a);
    }

    /// the setter of a locked door reverts with Locked, whatever it is asked
    function _setterShut(uint256 which) internal {
        bytes memory data = which == 0
            ? abi.encodeCall(ICore.setController, (v1))
            : (which == 1
                    ? abi.encodeCall(ICore.setBalanceModule, (core.balanceModule()))
                    : abi.encodeCall(ICore.addAdapter, (address(0xA110C))));
        vm.prank(owner);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok || bytes4(out) != ICore.Locked.selector) _flag(V_LOCK, "a locked door's setter did not revert Locked");
    }

    /// the flags the handler has seen set must still be set, and the setters must still refuse
    function lockCheck() external {
        if (gLockedC) {
            if (!core.controllerLocked()) _flag(V_LOCK, "the controller lock came undone");
            _setterShut(0);
        }
        if (gLockedE) {
            if (!core.balanceModuleLocked()) _flag(V_LOCK, "the balance module lock came undone");
            _setterShut(1);
        }
        if (gLockedT) {
            if (!core.adaptersLocked()) _flag(V_LOCK, "the adapters lock came undone");
            _setterShut(2);
        }
        if (core.retired() != gRetired) _flag(V_RETIRED, "the retired flag differs from the ghost");
        if (gLockedS) {
            if (!core.successorLocked()) _flag(V_LOCK, "the successor lock came undone");
            if (core.successor() != gSuccessorAtLock) _flag(V_LOCK, "the locked successor changed");
            _successorShut();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HANDOVER
    //////////////////////////////////////////////////////////////*/

    /// the owner hands over to the next heir in one of three ways: transfer and accept, transfer then clear (the heir can no
    /// longer accept) then transfer and accept, or name one heir then another (only the second can accept). the old owner
    /// keeps every power until the accept and has none after, the heir has none before and every one after, the controller's
    /// sale settings follow the live owner. no asset moves
    function handover(uint256 seed, uint256 mode) external checked {
        uint8 a = A_HANDOVER;
        if (heirNext + 1 >= heirs.length || seed % 6 != 0) return _skip(a);
        address old = owner;
        address heir = heirs[heirNext];
        address other = heirs[heirNext + 1];
        uint256 m = mode % 3;
        OPre memory pre = _opre();
        _att(a);
        address target = address(0xD1CE);
        vm.prank(old);
        (bool ok0,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (m == 2 ? other : heir)));
        if (!ok0) _flag(V_LOCK, "the owner could not start a handover");
        if (core.owner() != old || core.pendingOwner() != (m == 2 ? other : heir)) _flag(V_LOCK, "the first step moved the owner");
        // the old owner still holds every power, the pending owner none
        vm.prank(old);
        (bool ok,) = address(core).call(abi.encodeCall(ICore.removeAdapter, (target)));
        if (!ok) _flag(V_LOCK, "the owner lost a power before the handover was accepted");
        vm.prank(m == 2 ? other : heir);
        (ok,) = address(core).call(abi.encodeCall(ICore.removeAdapter, (target)));
        if (ok) _flag(V_LOCK, "a pending owner had a power before accepting");
        address next = heir;
        if (m == 1) {
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (address(0))));
            vm.prank(heir);
            (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
            if (ok) _flag(V_LOCK, "a cleared handover was accepted");
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (heir)));
        } else if (m == 2) {
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (heir)));
            vm.prank(other);
            (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
            if (ok) _flag(V_LOCK, "a replaced pending owner accepted");
            next = heir;
        }
        vm.prank(address(uint160(uint256(keccak256(abi.encode("accepter", seed))))));
        (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
        if (ok) _flag(V_LOCK, "a stranger accepted a handover");
        vm.prank(next);
        (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
        if (!ok) _flag(V_LOCK, "the pending owner could not accept");
        if (core.owner() != next || core.pendingOwner() != address(0)) _flag(V_LOCK, "the accept did not complete the handover");
        formerOwners.push(old);
        owner = next;
        heirNext += 1;
        // the old owner has no power: the core and the controller's settings
        vm.prank(old);
        (ok,) = address(core).call(abi.encodeCall(ICore.removeAdapter, (target)));
        if (ok) _flag(V_LOCK, "the old owner kept a power after the handover");
        // the argument is read before the prank: a call in the argument list would use it up
        uint16 decay0 = IControllerV1(v1).fastDecayBpsPerHour();
        vm.prank(old);
        (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setFastDecayBpsPerHour, (decay0 == 200 ? 201 : 200)));
        if (ok) _flag(V_LOCK, "the old owner kept the sale settings");
        vm.prank(next);
        (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setFastDecayBpsPerHour, (decay0)));
        if (!ok) _flag(V_LOCK, "the new owner has no say over the sale settings");
        _opost(pre, "handover");
        _ok(a);
    }

    /// every former owner has no power, for the core and for the controller's settings
    function formerOwnersCheck() external {
        for (uint256 i; i < formerOwners.length; ++i) {
            vm.prank(formerOwners[i]);
            (bool ok,) = address(core).call(abi.encodeCall(ICore.lockAdapters, ()));
            if (ok) _flag(V_LOCK, "a former owner locked a door");
            vm.prank(formerOwners[i]);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (formerOwners[i])));
            if (ok) _flag(V_LOCK, "a former owner started a handover");
            vm.prank(formerOwners[i]);
            (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setFastDecayBpsPerHour, (200)));
            if (ok) _flag(V_LOCK, "a former owner set a sale setting");
        }
        if (core.owner() != owner) _flag(V_LOCK, "the core owner is not the handler's owner");
    }
}
