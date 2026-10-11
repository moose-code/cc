// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {Lane, Sale, IController, ICoreViews, ICoreSale} from "./interfaces/Interfaces.sol";

/// first policy module. composes the oldest 80 credits of a lane with format 0.
/// it prices and sells statements. the asking price of a statement of cost `c` at age `t` since listing is
/// `c * (start - (start - floorBps) * min(t, decayDuration) / decayDuration)`, in bps of `c`, falling in a straight line
/// from `start` to `floorBps`. `start = min(anchorBps * markupBps / 10_000, startCapBps)`.
/// `anchorBps` (bps of cost, at least 10_000) is the running level of sale prices. it moves up with sales and down with
/// time. a `buy` whose sale price in bps of cost is above the anchor sets the anchor to the mean of the two. a `buy`
/// at or below the anchor leaves it unchanged. the part of the anchor above 10_000 halves every `anchorHalfLife`,
/// continuously. the controller stores the anchor at its last change (`storedAnchorBps`, `anchorTime`) and evaluates
/// the decay at the call. the price is computed from the current anchor at every call, so open listings follow it. in
/// auction mode the core uses the price as the house reserve, so the first bid at the asking price opens the english
/// auction, and house sales do not move the anchor. in buy only mode `buy` sells a statement at once at the asking
/// price.
/// it holds no funds between calls. its settings belong to the live owner of the core (`core.owner()`), there is no
/// second owner. the core enforces its own hard floor whatever this contract answers
contract ControllerV1 is IController {
    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotBuyOnly();
    error NotForSale();
    error Underpaid();
    error Reentrant();

    event BuyOnlySet(bool buyOnly);
    event MarkupBpsSet(uint16 markupBps);
    event StartCapBpsSet(uint32 startCapBps);
    event DecayDurationSet(uint32 decayDuration);
    event FloorBpsSet(uint16 floorBps);
    event AnchorBpsSet(uint32 anchorBps);
    event AnchorHalfLifeSet(uint32 anchorHalfLife);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);

    ICoreViews public immutable CORE;

    /// buy only mode: `statementPrice` returns the cap `cost * startCapBps / 10_000` as the house reserve and `buy` sells
    /// at the decayed asking price
    bool public buyOnly;
    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of cost. `markupBps` to 200_000
    uint32 public startCapBps;
    /// seconds from the start price to the floor. 1 hour to 30 days
    uint32 public decayDuration;
    /// the asking price never falls below this, bps of cost. 1_000 to 10_000
    uint16 public floorBps;
    /// the anchor at `anchorTime`, bps of cost. 10_000 to `startCapBps`. `anchorBps()` is the value now
    uint32 public storedAnchorBps;
    /// when `storedAnchorBps` was last set
    uint40 public anchorTime;
    /// seconds for the part of the anchor above 10_000 to halve. 1 day to 90 days
    uint32 public anchorHalfLife;
    bool private _busy;

    constructor(address core, Sale memory sale) {
        CORE = ICoreViews(core);
        buyOnly = sale.buyOnly;
        if (sale.markupBps < BPS || sale.markupBps > 40_000) revert BadSetting("markupBps");
        markupBps = sale.markupBps;
        if (sale.startCapBps < sale.markupBps || sale.startCapBps > 200_000) revert BadSetting("startCapBps");
        startCapBps = sale.startCapBps;
        if (sale.decayDuration < 1 hours || sale.decayDuration > 30 days) revert BadSetting("decayDuration");
        decayDuration = sale.decayDuration;
        if (sale.floorBps < 1_000 || sale.floorBps > BPS) revert BadSetting("floorBps");
        floorBps = sale.floorBps;
        if (sale.anchorHalfLife < 1 days || sale.anchorHalfLife > 90 days) revert BadSetting("anchorHalfLife");
        anchorHalfLife = sale.anchorHalfLife;
        storedAnchorBps = uint32(BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ sale settings, owner, at once

    function setBuyOnly(bool on) external onlyOwner {
        buyOnly = on;
        emit BuyOnlySet(on);
    }

    /// 10_000 to 40_000, and not above `startCapBps`
    function setMarkupBps(uint16 v) external onlyOwner {
        if (v < BPS || v > 40_000 || v > startCapBps) revert BadSetting("markupBps");
        markupBps = v;
        emit MarkupBpsSet(v);
    }

    /// `markupBps` to 200_000. an `anchorBps()` above the new cap is lowered to it
    function setStartCapBps(uint32 v) external onlyOwner {
        if (v < markupBps || v > 200_000) revert BadSetting("startCapBps");
        startCapBps = v;
        emit StartCapBpsSet(v);
        if (anchorBps() > v) _setAnchor(v);
    }

    /// 1 hour to 30 days
    function setDecayDuration(uint32 v) external onlyOwner {
        if (v < 1 hours || v > 30 days) revert BadSetting("decayDuration");
        decayDuration = v;
        emit DecayDurationSet(v);
    }

    /// 1_000 to 10_000
    function setFloorBps(uint16 v) external onlyOwner {
        if (v < 1_000 || v > BPS) revert BadSetting("floorBps");
        floorBps = v;
        emit FloorBpsSet(v);
    }

    /// 10_000 to `startCapBps`. replaces the running level of sale prices and restarts its decay
    function setAnchorBps(uint32 v) external onlyOwner {
        if (v < BPS || v > startCapBps) revert BadSetting("anchorBps");
        _setAnchor(v);
    }

    /// 1 day to 90 days. the anchor at the call is stored first, so the new half life applies from now on
    function setAnchorHalfLife(uint32 v) external onlyOwner {
        if (v < 1 days || v > 90 days) revert BadSetting("anchorHalfLife");
        _setAnchorStored(anchorBps());
        anchorHalfLife = v;
        emit AnchorHalfLifeSet(v);
    }

    // ------------------------------------------------------------------ pricing and sale

    /// the running level of sale prices now, bps of cost: 10_000 plus the part of `storedAnchorBps` above 10_000,
    /// halved every `anchorHalfLife` since `anchorTime`
    function anchorBps() public view returns (uint32) {
        uint256 excess = storedAnchorBps - BPS;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(BPS + Halving.halve(excess, block.timestamp - anchorTime, anchorHalfLife));
    }

    /// the start price of a new listing, bps of cost: the anchor times `markupBps`, at most `startCapBps`
    function startBps() public view returns (uint256) {
        uint256 start = uint256(anchorBps()) * markupBps / BPS;
        return start < startCapBps ? start : startCapBps;
    }

    /// the price the core uses as the house reserve, in wei. falls with the age of the listing in auction mode. in buy
    /// only mode it is the cap `cost * startCapBps / 10_000`, the highest `buy` price a listing can reach while the
    /// anchor rises, so the reserve never undercuts the live ask
    function statementPrice(uint256, uint256 cost, uint64 listedAt) external view returns (uint256) {
        if (buyOnly) return cost * startCapBps / BPS;
        return _ask(cost, block.timestamp - listedAt);
    }

    /// the asking price of statement `sid` now, in either mode, read from the core. never below the core hard floor
    /// `cost * saleFloorBps / 10_000`, so the quote is always a price `sellTo` takes
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,) = _quote(sid);
    }

    /// buy only mode: pays the asking price, gets the statement at once, and moves the anchor halfway to the sale price
    /// in bps of cost. the excess of `msg.value` is refunded to the caller last. reverts while a bid is live on the house
    function buy(uint256 sid) external payable {
        if (_busy) revert Reentrant();
        if (!buyOnly) revert NotBuyOnly();
        _busy = true;
        (uint256 price, uint256 cost) = _quote(sid);
        if (msg.value < price) revert Underpaid();
        _moveAnchor(sid, price, cost);
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    function _quote(uint256 sid) private view returns (uint256 price, uint256 cost) {
        bool held;
        Lane lane;
        uint64 listedAt;
        (held, lane, cost, listedAt) = CORE.statementInfo(sid);
        if (!held || lane != Lane.Eth || listedAt == 0) revert NotForSale();
        price = _ask(cost, block.timestamp - listedAt);
        uint256 floor = cost * ICoreSale(address(CORE)).settings().saleFloorBps / BPS;
        if (price < floor) price = floor;
    }

    /// a sale price in bps of cost (rounded up) above the anchor sets the anchor to the mean of the two, at most
    /// `startCapBps`. a sale price at or below the anchor leaves the stored anchor and `anchorTime` unchanged
    function _moveAnchor(uint256 sid, uint256 price, uint256 cost) private {
        // cost is at least 80: every eth lane credit enters the pile through `_spend` (nonzero) or `adopt` (at least 1 wei)
        uint256 saleBps = (price * BPS + cost - 1) / cost;
        uint256 current = anchorBps();
        if (saleBps <= current) return;
        uint256 next = (current + saleBps) / 2;
        uint256 cap = startCapBps;
        if (next > cap) next = cap;
        // forge-lint: disable-next-line(unsafe-typecast)
        _setAnchorStored(uint32(next));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit AnchorMoved(sid, saleBps, uint32(next));
    }

    function _setAnchor(uint32 v) private {
        _setAnchorStored(v);
        emit AnchorBpsSet(v);
    }

    function _setAnchorStored(uint32 v) private {
        storedAnchorBps = v;
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorTime = uint40(block.timestamp);
    }

    /// the asking price in wei after `age` seconds: a straight line from `startBps()` of `cost` to `floorBps` of `cost`
    /// over `decayDuration`
    function _ask(uint256 cost, uint256 age) private view returns (uint256) {
        uint256 d = decayDuration;
        uint256 start = startBps();
        uint256 t = age < d ? age : d;
        return cost * (start * d - (start - floorBps) * t) / (d * BPS);
    }

    // ------------------------------------------------------------------ credit picking, unchanged

    /// ready when the lane pile holds a full page. the page is the 80 oldest credits with format 0.
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize(lane) < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(lane, 0, PAGE);
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }
}
