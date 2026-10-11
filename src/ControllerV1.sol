// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Halving} from "./lib/Halving.sol";
import {Lane, Sale, IController, ICoreViews, ICoreSale} from "./interfaces/Interfaces.sol";

/// first policy module. composes the oldest 80 credits of a lane with format 0.
/// it prices and sells statements. the asking price of a statement of cost `c` is a fraction of `c` in bps that starts at
/// `start = min(anchorBps * markupBps / 10_000, startCapBps)` and falls at a fixed rate per second in two stages: at
/// `fastDecayBpsPerHour` from `start` to `kneeBps`, then at `slowDecayBpsPerHour` to `floorBps`, where it stays. a `start`
/// at or below `kneeBps` falls at the slow rate from the first second. the price is computed at every call from the age of
/// statement (time since its compose) and the current settings, so a setting change applies to held statements at once.
/// `anchorBps` (bps of cost, at least 10_000) is the running level of sale prices. it moves up with sales and down with
/// time. a `buy` whose sale price in bps of cost is above the anchor sets the anchor to the mean of the two. a `buy`
/// at or below the anchor leaves it unchanged. the part of the anchor above 10_000 halves every `anchorHalfLife`,
/// continuously. the controller stores the anchor at its last change (`storedAnchorBps`, `anchorTime`) and evaluates
/// the decay at the call. the price is computed from the current anchor at every call, so held statements follow it.
/// `buy` sells a held eth lane statement at once at the asking price.
/// it holds no funds between calls. its settings belong to the live owner of the core (`core.owner()`), there is no
/// second owner. the core enforces its own hard floor whatever this contract answers
contract ControllerV1 is IController {
    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error Reentrant();

    event MarkupBpsSet(uint16 markupBps);
    event StartCapBpsSet(uint32 startCapBps);
    event FastDecayBpsPerHourSet(uint16 fastDecayBpsPerHour);
    event KneeBpsSet(uint32 kneeBps);
    event SlowDecayBpsPerHourSet(uint16 slowDecayBpsPerHour);
    event FloorBpsSet(uint16 floorBps);
    event AnchorBpsSet(uint32 anchorBps);
    event AnchorHalfLifeSet(uint32 anchorHalfLife);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps);

    ICoreViews public immutable CORE;

    /// start price over the anchor, bps. 10_000 to 40_000, at most `startCapBps`
    uint16 public markupBps;
    /// the most the start price can be, bps of cost. the larger of `markupBps` and `kneeBps` to 200_000
    uint32 public startCapBps;
    /// fall of the asking price per hour above `kneeBps`, bps of cost. 1 to 10_000
    uint16 public fastDecayBpsPerHour;
    /// fall of the asking price per hour at or below `kneeBps`, bps of cost. 1 to 10_000
    uint16 public slowDecayBpsPerHour;
    /// the price where the fast fall ends and the slow fall starts, bps of cost. `floorBps` to `startCapBps`
    uint32 public kneeBps;
    /// lowest asking price, bps of cost. 1_000 to the smaller of 10_000 and `kneeBps`
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
        if (sale.markupBps < BPS || sale.markupBps > 40_000) revert BadSetting("markupBps");
        markupBps = sale.markupBps;
        if (sale.startCapBps < sale.markupBps || sale.startCapBps > 200_000) revert BadSetting("startCapBps");
        startCapBps = sale.startCapBps;
        if (sale.floorBps < 1_000 || sale.floorBps > BPS) revert BadSetting("floorBps");
        floorBps = sale.floorBps;
        if (sale.kneeBps < sale.floorBps || sale.kneeBps > sale.startCapBps) revert BadSetting("kneeBps");
        kneeBps = sale.kneeBps;
        if (sale.fastDecayBpsPerHour < 1 || sale.fastDecayBpsPerHour > BPS) revert BadSetting("fastDecayBpsPerHour");
        fastDecayBpsPerHour = sale.fastDecayBpsPerHour;
        if (sale.slowDecayBpsPerHour < 1 || sale.slowDecayBpsPerHour > BPS) revert BadSetting("slowDecayBpsPerHour");
        slowDecayBpsPerHour = sale.slowDecayBpsPerHour;
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

    /// 10_000 to 40_000, and not above `startCapBps`
    function setMarkupBps(uint16 v) external onlyOwner {
        if (v < BPS || v > 40_000 || v > startCapBps) revert BadSetting("markupBps");
        markupBps = v;
        emit MarkupBpsSet(v);
    }

    /// the larger of `markupBps` and `kneeBps` to 200_000. an `anchorBps()` above the new cap is lowered to it
    function setStartCapBps(uint32 v) external onlyOwner {
        if (v < markupBps || v < kneeBps || v > 200_000) revert BadSetting("startCapBps");
        startCapBps = v;
        emit StartCapBpsSet(v);
        if (anchorBps() > v) _setAnchor(v);
    }

    /// 1 to 10_000
    function setFastDecayBpsPerHour(uint16 v) external onlyOwner {
        if (v < 1 || v > BPS) revert BadSetting("fastDecayBpsPerHour");
        fastDecayBpsPerHour = v;
        emit FastDecayBpsPerHourSet(v);
    }

    /// 1 to 10_000
    function setSlowDecayBpsPerHour(uint16 v) external onlyOwner {
        if (v < 1 || v > BPS) revert BadSetting("slowDecayBpsPerHour");
        slowDecayBpsPerHour = v;
        emit SlowDecayBpsPerHourSet(v);
    }

    /// `floorBps` to `startCapBps`. raising it above the cap takes `setStartCapBps` first, lowering it below the floor
    /// takes `setFloorBps` first
    function setKneeBps(uint32 v) external onlyOwner {
        if (v < floorBps || v > startCapBps) revert BadSetting("kneeBps");
        kneeBps = v;
        emit KneeBpsSet(v);
    }

    /// 1_000 to the smaller of 10_000 and `kneeBps`
    function setFloorBps(uint16 v) external onlyOwner {
        if (v < 1_000 || v > BPS || v > kneeBps) revert BadSetting("floorBps");
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

    /// the start price of a new statement, bps of cost: the anchor times `markupBps`, at most `startCapBps`
    function startBps() public view returns (uint256) {
        uint256 start = uint256(anchorBps()) * markupBps / BPS;
        return start < startCapBps ? start : startCapBps;
    }

    /// the asking price of statement `sid` now, read from the core. never below the core hard floor
    /// `cost * saleFloorBps / 10_000`, so the quote is always a price `sellTo` takes
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,) = _quote(sid);
    }

    /// pays the asking price, gets the statement at once, and moves the anchor halfway to the sale price in bps of
    /// cost. the excess of `msg.value` is refunded to the caller last
    function buy(uint256 sid) external payable {
        if (_busy) revert Reentrant();
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
        uint64 composedAt;
        (held, lane, cost, composedAt) = CORE.statementInfo(sid);
        if (!held || lane != Lane.Eth) revert NotForSale();
        price = _ask(cost, block.timestamp - composedAt);
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

    /// the asking price in wei after `age` seconds. the price is held in units of 1/3600 bps so each stage is an integer
    /// line of the second: it falls by `fastDecayBpsPerHour` units a second from the start to the knee and by
    /// `slowDecayBpsPerHour` units a second after, never below `floorBps`. the slow stage starts at the second the fast
    /// stage reaches the knee, which is `(start - knee) / fastDecayBpsPerHour` hours and need not be a whole second, so
    /// its fall is rounded up. the rounding keeps the price non-increasing in `age`
    function _ask(uint256 cost, uint256 age) private view returns (uint256) {
        uint256 start = startBps() * 1 hours;
        uint256 knee = uint256(kneeBps) * 1 hours;
        uint256 fast = fastDecayBpsPerHour;
        uint256 fallen = fast * age;
        uint256 span = start > knee ? start - knee : 0;
        uint256 n;
        if (fallen <= span) {
            n = start - fallen;
        } else {
            uint256 drop = (slowDecayBpsPerHour * (fallen - span) + fast - 1) / fast;
            uint256 base = start < knee ? start : knee;
            n = base > drop ? base - drop : 0;
        }
        uint256 low = uint256(floorBps) * 1 hours;
        if (n < low) n = low;
        return cost * n / (1 hours * BPS);
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
