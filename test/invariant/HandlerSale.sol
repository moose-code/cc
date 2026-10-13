// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";
import {HandlerBase} from "./HandlerBase.sol";
import {HandlerOwner} from "./HandlerOwner.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {SellingController} from "../attackers/SaleAttackers.sol";

/// @notice the sale controller and the owner as an adversary. actions: `buy` through the first controller, the
/// controller's own `sellTo` through a selling controller the owner installs, the controller's sale settings, the owner
/// swapping the controller and the exit module in one go, the three one way locks and the two step handover. every call is checked against a model written from docs/FLOW.md: who may
/// sell, at what least price, what is booked where, who holds the statement after. a refusal must carry the selector
/// the model names. nothing here reverts, a violation goes to `viol`.
abstract contract HandlerSale is HandlerOwner {
    /// the controller that sells statements for the owner, and its buyers
    SellingController public selling;
    /// every owner the run has had, in order, and the next heirs
    address[] public formerOwners;
    address[] public heirs;
    uint256 public heirNext;
    /// every exit module the owner ever installed: none may have called the core successfully from inside an exit
    MockExitModule[] public modulesEver;
    /// the one way locks seen by the handler. they must never come undone
    bool public gLockedC;
    bool public gLockedE;
    bool public gLockedT;
    /// sales through `sellTo`
    uint256 public gSoldTo;

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
    /// controller (`sellTo`): the record (a held statement), then the hard floor. zero when the sale must go
    /// through
    function _sellToRefusal(SG storage g, uint256 value, uint256 floor) internal view returns (bytes4) {
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

    /// the refusal of `ControllerV1.buy` in the order of its checks: the pause, the record `priceOf` reads, the payment, the
    /// controller in force (the core takes `sellTo` from the controller only), then what `sellTo` checks
    function _buyRefusal(uint256 sid, SalePre memory p, bool short_) internal view returns (bytes4) {
        if (IControllerV1(v1).paused()) return IControllerV1.Paused.selector;
        (bool held,,) = core.statementInfo(sid);
        if (!held) return IControllerV1.NotForSale.selector;
        if (short_) return IControllerV1.Underpaid.selector;
        if (core.controller() != v1) return ICore.OnlyController.selector;
        return _sellToRefusal(_sg[sid], p.price, p.floor);
    }

    uint256 internal _anchor0;
    uint256 internal _cost0;
    uint256 internal _stored0;
    uint256 internal _anchorTime0;

    /// the anchor after a sale at `price` of a statement of `cost`, written out again from docs/FLOW.md 64 and 70: the
    /// anchor now when `cost` is under `anchorMinCost` or the sale price in bps of cost (rounded up) is not above it,
    /// otherwise the mean of the two, at most the start cap
    function _anchorAfter(uint256 anchor0, uint256 price, uint256 cost) internal view returns (uint256 next) {
        uint256 saleBps = (price * 10_000 + cost - 1) / cost;
        if (cost < IControllerV1(v1).anchorMinCost() || saleBps <= anchor0) return anchor0;
        next = (anchor0 + saleBps) / 2;
        uint256 cap = IControllerV1(v1).startCapBps();
        if (next > cap) next = cap;
    }

    /// a buyer pays the asking price of the first controller, with an excess now and then and a short payment now and
    /// then. with another controller in force, on a sold, exited or exit lane statement it must refuse with the model's
    /// selector. a sale pays the ask exactly, the excess comes back
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
            _flag(V_SALE_PATH, "the asking price differs from the curve at the age outside every pause window");
        }
        bool short_ = priced && price != 0 && xSeed % 7 == 0;
        uint256 value = !priced ? 1 ether : (short_ ? price - 1 : price + (xSeed % 3 == 0 ? 0 : _logBound(xSeed, 1, 1 ether)));
        SalePre memory p = _salePre(sid, who, who, value);
        p.price = price;
        p.want = _buyRefusal(sid, p, short_);
        vm.deal(who, who.balance + value);
        p.payerBal = who.balance;
        RS memory rs = _rs();
        _anchor0 = IControllerV1(v1).anchorBps();
        _stored0 = IControllerV1(v1).storedAnchorBps();
        _anchorTime0 = IControllerV1(v1).anchorTime();
        (, _cost0,) = core.statementInfo(sid);
        _att(a);
        vm.prank(who);
        try IControllerV1(v1).buy{value: value}(sid) {
            _ok(a);
            if (IControllerV1(v1).anchorBps() != _anchorAfter(_anchor0, price, _cost0)) {
                _flag(V_SALE_PATH, "a buy did not move the anchor halfway to the sale price");
            }
            if (
                ((price * 10_000 + _cost0 - 1) / _cost0 <= _anchor0 || _cost0 < IControllerV1(v1).anchorMinCost())
                    && (IControllerV1(v1).storedAnchorBps() != _stored0 || IControllerV1(v1).anchorTime() != _anchorTime0)
            ) {
                _flag(V_SALE_PATH, "a buy at or below the anchor, or of a statement under the minimum cost, stored the anchor");
            }
            if (p.payerBal - who.balance != price) {
                _flag(V_SALE_PATH, "the buyer did not pay exactly the ask, or the excess was not refunded");
            }
            if (address(v1).balance != baseOf[v1].eth) _flag(V_SALE_PATH, "the controller kept eth after a buy");
            _saleDone(sid, p, price);
        } catch (bytes memory why) {
            _saleRefused(sid, p, why, a);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    the pause of the first controller
    //////////////////////////////////////////////////////////////*/

    /// the pause windows the handler applied to the first controller: start and end, an end of 0 for the open window
    uint256[] internal _pauseStart;
    uint256[] internal _pauseEnd;

    function pauseCount() external view returns (uint256) {
        return _pauseStart.length;
    }

    function _modelPaused() internal view returns (bool) {
        uint256 n = _pauseEnd.length;
        return n != 0 && _pauseEnd[n - 1] == 0;
    }

    /// the age of a statement composed at `composedAt`: the seconds to now outside every pause window
    function _modelAge(uint256 composedAt) internal view returns (uint256 age) {
        age = block.timestamp - composedAt;
        for (uint256 i; i < _pauseStart.length; ++i) {
            uint256 s = _pauseStart[i] > composedAt ? _pauseStart[i] : composedAt;
            uint256 e = _pauseEnd[i] == 0 ? block.timestamp : _pauseEnd[i];
            if (e > s) age -= e - s;
        }
    }

    /// the asking price of statement `sid` written out again from docs/ARCHITECTURE.md section 7: the price in units of
    /// 1/3600 bps falls `fastDecayBpsPerHour` a second to the knee and `slowDecayBpsPerHour` after it (rounded up), at
    /// the age outside every pause window, at least `floorBps` and at least the hard floor of the core
    function _modelAsk(uint256 sid) internal view returns (uint256) {
        (, uint256 cost, uint64 at) = core.statementInfo(sid);
        uint256 n = _modelUnits(_modelAge(at));
        uint256 ask = cost * n / (3600 * 10_000);
        uint256 hard = cost * core.settings().saleFloorBps / 10_000;
        return ask < hard ? hard : ask;
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
        uint256 low = uint256(c.floorBps()) * 3600;
        if (n < low) n = low;
    }

    /// the owner pauses or resumes sales of the first controller, or a stranger tries. a repeat of the current state is
    /// accepted and changes nothing. a stranger gets OnlyOwner. the state reads back as the model says, and no asset or
    /// pot moves
    function pause(uint256 seed, uint256 mode) external checked {
        uint8 a = A_PAUSE;
        IControllerV1 c = IControllerV1(v1);
        bool stranger = mode % 5 == 0;
        bool want = (mode >> 4) % 8 < 2;
        bool was = c.paused();
        if (was != _modelPaused()) _flag(V_SALE_PATH, "the pause state differs from the model");
        OPre memory pre = _opre();
        _att(a);
        vm.prank(stranger ? address(uint160(uint256(keccak256(abi.encode("stranger", seed))))) : owner);
        (bool ok, bytes memory out) = address(c).call(abi.encodeCall(IControllerV1.setPaused, (want)));
        if (stranger) {
            if (ok) _flag(V_OWNER, "a stranger changed the pause");
            else if (bytes4(out) != IControllerV1.OnlyOwner.selector) _unexpected(a, out);
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
        if (c.paused() != (stranger || !ok ? was : want)) _flag(V_SALE_PATH, "the pause state differs from the model");
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
            v = bad ? (seed % 2 == 0 ? c.floorBps() - 1 : cap + 1) : _f(seed, c.floorBps(), cap, cur);
            valid = v >= c.floorBps() && v <= cap;
        } else if (which == 5) {
            sel = IControllerV1.setFloorBps.selector;
            cur = c.floorBps();
            v = bad ? (seed % 3 == 0 ? 999 : (seed % 3 == 1 ? 10_001 : knee + 1)) : _f(seed, 1_000, _min(10_000, knee), cur);
            valid = v >= 1_000 && v <= 10_000 && v <= knee;
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

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    function _saleGot(IControllerV1 c, uint256 which) internal view returns (uint256) {
        if (which == 0) return c.markupBps();
        if (which == 1) return c.startCapBps();
        if (which == 2) return c.fastDecayBpsPerHour();
        if (which == 3) return c.slowDecayBpsPerHour();
        if (which == 4) return c.kneeBps();
        if (which == 5) return c.floorBps();
        if (which == 6) return c.anchorBps();
        if (which == 7) return c.anchorHalfLife();
        return c.anchorMinCost();
    }

    /// the owner sets one of the nine sale numbers of the first controller to a value inside or outside the bounds of
    /// docs/FLOW.md 9.3 (written out again here), or a stranger tries. inside: it goes through and reads back. outside:
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

    /// the call a hostile module makes from inside an exit: nothing, or one door of the core, or the selling controller.
    /// k = 1..11 selects compose, skim, buyback, exitStatement, the selling controller's sell, adopt, releaseRedeemBurn,
    /// sellForEth, buyListing, sellTo and sellForExitToken
    function _callout(uint256 k, uint256 seed, MockExitModule next) internal {
        if (k == 0) return;
        address target = address(core);
        bytes memory data;
        uint256 n = everHeld.length;
        uint256 sid = n == 0 ? 1 : everHeld[seed % n];
        uint256[] memory ids = new uint256[](1);
        ids[0] = seed >> 8;
        if (k == 1) data = abi.encodeCall(ICore.compose, ());
        else if (k == 2) data = abi.encodeCall(ICore.skim, ());
        else if (k == 3) data = abi.encodeCall(ICore.buyback, ());
        else if (k == 4) data = abi.encodeCall(ICore.exitStatement, (sid));
        else if (k == 6) data = abi.encodeCall(ICore.adopt, (ids));
        else if (k == 7) data = abi.encodeCall(ICore.releaseRedeemBurn, (1));
        else if (k == 8) data = abi.encodeWithSignature("sellForEth(uint256[])", ids);
        else if (k == 9) data = abi.encodeCall(ICore.buyListing, (1, "", seed >> 8, address(next)));
        else if (k == 10) data = abi.encodeCall(ICore.sellTo, (sid, address(next)));
        else if (k == 11) data = abi.encodeWithSignature("sellForExitToken(uint256[])", ids);
        else {
            target = address(selling);
            data = abi.encodeCall(SellingController.sell, (sid, address(next)));
        }
        next.setCall(target, data);
    }

    /// the owner replaces the controller and, in phase 2, the exit module in one go. the controller is any of the three
    /// the run knows, the module a new one with the same exit token, a new unit, and now and then a gas burning body and a
    /// call into the core from inside the exit. both take effect at once unless the owner locked the door. the call must
    /// not move an asset or a pot, and no call from inside an exit may ever go through
    function hostileOwner(uint256 seed, uint256 mode) external checked {
        uint8 a = A_HOSTILE_OWNER;
        address c = seed % 3 == 0 ? v1 : (seed % 3 == 1 && canSwapController ? address(fuzz) : address(selling));
        bool swapMod = phase2() && mode % 2 == 0;
        MockExitModule next;
        if (swapMod) {
            next = new MockExitModule(core.exitToken(), _logBound(seed >> 8, 2e9, 5e10));
            uint256 burn = (mode >> 4) % 4;
            if (burn == 1) next.setBurn(300_000);
            else if (burn == 2) next.setBurn(2_000_000);
            _callout((mode >> 8) % 12, seed >> 16, next);
        }
        bool lockedC = core.controllerLocked();
        bool lockedE = core.exitModuleLocked();
        address oldC = core.controller();
        address oldM = core.exitModule();
        OPre memory pre = _opre();
        _att(a);
        vm.startPrank(owner);
        (bool okC,) = address(core).call(abi.encodeCall(ICore.setController, (c)));
        bool okM = true;
        if (swapMod) (okM,) = address(core).call(abi.encodeCall(ICore.setExitModule, (address(next))));
        vm.stopPrank();
        if (okC == lockedC) _flag(V_LOCK, "the controller door and its lock disagree");
        if (core.controller() != (okC ? c : oldC)) _flag(V_OWNER, "the controller is not what the owner set at once");
        if (swapMod) {
            if (okM == lockedE) _flag(V_LOCK, "the exit module door and its lock disagree");
            if (core.exitModule() != (okM ? address(next) : oldM)) _flag(V_OWNER, "the exit module is not what the owner set");
            if (okM) {
                module = next;
                modulesEver.push(next);
                if (core.unitPerPoint() != next.currentUnit()) _flag(V_OWNER, "the unit was not read from the new module");
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
            which == 0 ? ICore.lockController.selector : (which == 1 ? ICore.lockExitModule.selector : ICore.lockTargets.selector)
        );
        vm.prank(stranger);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok || bytes4(out) != ICore.OnlyOwner.selector) _flag(V_LOCK, "a stranger locked a door");
        bool noModule = which == 1 && core.exitModule() == address(0);
        vm.prank(owner);
        (ok, out) = address(core).call(data);
        if (noModule) {
            if (ok || bytes4(out) != ICore.NoExitModule.selector) _flag(V_LOCK, "the module lock worked with no module");
        } else {
            if (!ok) _flag(V_LOCK, "the owner could not lock a door");
            bool nowLocked = which == 0 ? core.controllerLocked() : (which == 1 ? core.exitModuleLocked() : core.targetsLocked());
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
                    ? abi.encodeCall(ICore.setExitModule, (core.exitModule()))
                    : abi.encodeCall(ICore.addTarget, (address(0xA110C))));
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
            if (!core.exitModuleLocked()) _flag(V_LOCK, "the exit module lock came undone");
            _setterShut(1);
        }
        if (gLockedT) {
            if (!core.targetsLocked()) _flag(V_LOCK, "the targets lock came undone");
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
        (bool ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
        if (!ok) _flag(V_LOCK, "the owner lost a power before the handover was accepted");
        vm.prank(m == 2 ? other : heir);
        (ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
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
        (ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
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
            (bool ok,) = address(core).call(abi.encodeCall(ICore.lockTargets, ()));
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
