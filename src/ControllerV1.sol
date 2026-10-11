// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Lane, Sale, IController, ICoreViews, ICoreSale} from "./interfaces/Interfaces.sol";

/// first policy module. composes the oldest 80 credits of a lane with format 0.
/// it prices and sells statements. the asking price of a statement of cost `c` at age `t` since listing is
/// `c * (start - (start - floorBps) * min(t, decayDuration) / decayDuration)`, in bps of `c`, falling in a straight line
/// from `start` to `floorBps`. `start = min(anchorBps * markupBps / 10_000, startCapBps)`.
/// `anchorBps` (bps of cost, at least 10_000) is the running level of sale prices: each `buy` sets it to the mean of
/// the old anchor and the sale price. the price is computed from the current anchor at every call, so open listings
/// follow it. in auction mode the core uses the price as the house reserve, so the first bid at the asking price opens
/// the english auction, and house sales do not move the anchor. in buy only mode `buy` sells a statement at once at
/// the asking price.
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
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);

    ICoreViews public immutable CORE;

    /// buy only mode: `statementPrice` returns the start price without decay (the house reserve is not walked down) and
    /// `buy` sells at the decayed asking price
    bool public buyOnly;
    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of cost. `markupBps` to 200_000
    uint32 public startCapBps;
    /// seconds from the start price to the floor. 1 hour to 30 days
    uint32 public decayDuration;
    /// the asking price never falls below this, bps of cost. 1_000 to 10_000
    uint16 public floorBps;
    /// the running level of sale prices, bps of cost. 10_000 to `startCapBps`
    uint32 public anchorBps;
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
        anchorBps = uint32(BPS);
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

    /// `markupBps` to 200_000
    function setStartCapBps(uint32 v) external onlyOwner {
        if (v < markupBps || v > 200_000) revert BadSetting("startCapBps");
        startCapBps = v;
        emit StartCapBpsSet(v);
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

    /// 10_000 to `startCapBps`. replaces the running level of sale prices
    function setAnchorBps(uint32 v) external onlyOwner {
        if (v < BPS || v > startCapBps) revert BadSetting("anchorBps");
        anchorBps = v;
        emit AnchorBpsSet(v);
    }

    // ------------------------------------------------------------------ pricing and sale

    /// the start price of a new listing, bps of cost: the anchor times `markupBps`, at most `startCapBps`
    function startBps() public view returns (uint256) {
        uint256 start = uint256(anchorBps) * markupBps / BPS;
        return start < startCapBps ? start : startCapBps;
    }

    /// the price the core uses as the house reserve, in wei. falls with the age of the listing in auction mode, stays at
    /// the start price in buy only mode so the reserve is not walked down
    function statementPrice(uint256, uint256 cost, uint64 listedAt) external view returns (uint256) {
        return _ask(cost, buyOnly ? 0 : block.timestamp - listedAt);
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

    /// the new anchor is the mean of the old anchor and the sale price in bps of cost (rounded up), from 10_000 to
    /// `startCapBps`
    function _moveAnchor(uint256 sid, uint256 price, uint256 cost) private {
        uint256 saleBps = (price * BPS + cost - 1) / cost;
        uint256 next = (anchorBps + saleBps) / 2;
        uint256 cap = startCapBps;
        if (next < BPS) next = BPS;
        else if (next > cap) next = cap;
        // forge-lint: disable-next-line(unsafe-typecast)
        anchorBps = uint32(next);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit AnchorMoved(sid, saleBps, uint32(next));
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
