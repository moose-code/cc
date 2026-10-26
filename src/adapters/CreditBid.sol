// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    ICreditScore,
    ICredits,
    Mainnet,
    Settings,
    BalanceBid,
    SpenderState,
    RATE_SCORE,
    POINT_UNIT
} from "../interfaces/Interfaces.sol";

interface IBidCore {
    function owner() external view returns (address);
    function controller() external view returns (address);
    function artist() external view returns (address);
    function settings() external view returns (Settings memory);
    function ethPrice() external view returns (uint256);
    function creditInfo(uint256 id) external view returns (bool inPile, uint256 cost, uint64 acquiredAt);
    function adopt(uint256[] calldata ids) external;
}

/// the ControllerV3 views the bid reads
interface IBidController {
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
    function creditSoldAt(uint256 id) external view returns (uint64);
    function floorMultBps() external view returns (uint256);
}

/// the treasury v2 surface the bid draws through
interface IBidTreasury {
    function core() external view returns (address);
    function unitPerPoint() external view returns (uint256);
    function paused() external view returns (bool);
    function selected() external view returns (bool);
    function spenders(address spender) external view returns (SpenderState memory);
    function drawable(address spender) external view returns (uint256);
    function drawableTotal(address spender) external view returns (uint256);
    function draw(address to, uint256 amount, bool accrue) external;
}

interface IBidCredits {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

/// the balance bid, a registered spender of treasury v2: buys the caller's Credits for the balance token at `bidBps`
/// of par and adopts them into the Core's pile. the band, the eth cap and the return lock are this module's rule; the
/// bucket, the caps, the switch and the pause are the treasury's, read at each fill. a new pricing rule is a new
/// module registered beside this one, never a treasury migration. the owner is the Core's owner
contract CreditBid {
    address public immutable core;
    address public immutable treasury;
    uint256 public immutable unitPerPoint;

    uint256 private constant BPS = 10_000;
    /// transient reentrancy lock slot, keccak256("CreditBid.lock") less one
    uint256 private constant LOCK_SLOT = 0x944164d9912a88a33cc8c7131ce7562231fe6665796bac9e5d2ae990e6149108;

    error OnlyOwner();
    error Reentrant();
    error BidOff();
    error BidUnpriced();
    error ReturnLocked(uint256 id);
    error NotInPile(uint256 id);
    error NotOwner(uint256 id);
    error InvalidAmount();
    error ZeroAmount();
    error Slippage();
    error BadSetting(bytes32 field);
    error InvalidConfiguration();

    event CreditSold(
        uint256 indexed id, address indexed seller, uint256 score, uint256 paid, uint256 toArtist, uint256 bidBps
    );
    event BidFill(address indexed seller, uint256 credits, uint256 paid, uint256 toArtist, uint256 bidBudget);
    event BidSet(BalanceBid bid);

    BalanceBid public bid;
    /// the bid price at the last fill or setting, bps of par, and its time
    uint16 public bidAnchorBps;
    uint40 public bidAnchorTime;
    /// cumulative payouts and royalties paid through this module
    uint256 public bidOut;

    constructor(address treasury_) {
        if (treasury_.code.length == 0) revert InvalidConfiguration();
        treasury = treasury_;
        core = IBidTreasury(treasury_).core();
        unitPerPoint = IBidTreasury(treasury_).unitPerPoint();
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OnlyOwner();
        _;
    }

    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked != 0) revert Reentrant();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    // ------------------------------------------------------------------ views

    function owner() public view returns (address) {
        return IBidCore(core).owner();
    }

    /// this module's bucket in the treasury: what the bid can pay in all
    function bidBudget() public view returns (uint256) {
        return IBidTreasury(treasury).spenders(address(this)).bucket;
    }

    /// the bid is on: the treasury switched this spender on, is not paused, and is the selected module of a live Core
    function bidEnabled() public view returns (bool) {
        IBidTreasury t = IBidTreasury(treasury);
        return t.spenders(address(this)).on && !t.paused() && t.selected();
    }

    /// the bid price now, bps of par: the anchor climbed `climbBps` per full step, inside [floorBps, capBps]
    function bidBpsNow() public view returns (uint256 x) {
        BalanceBid memory b = bid;
        x = bidAnchorBps;
        if (b.stepSeconds != 0) x += (block.timestamp - bidAnchorTime) / b.stepSeconds * b.climbBps;
        if (x > b.capBps) x = b.capBps;
        if (x < b.floorBps) x = b.floorBps;
    }

    /// `bidBpsNow()` below the controller's credit floor multiplier, read at each fill: the Core's `balanceBidCapBps`
    /// can fall after `setBid`, and a credit the engine resells after its return lock must stay worth more at the
    /// engine than here
    function _fillBps() private view returns (uint256 bps) {
        bps = bidBpsNow();
        uint256 floorMult = IBidController(IBidCore(core).controller()).floorMultBps();
        if (bps >= floorMult) bps = floorMult - 1;
    }

    /// what `sellCredit([id])` would pay the seller and the artist now, zero when the bid could not price or settle it
    /// inside the treasury's caps (both draws). the return lock and the holder are checked only by the fill
    function quoteCredit(uint256 id) external view returns (uint256 paid, uint256 toArtist) {
        if (!bidEnabled()) return (0, 0);
        (bool ok, uint256 ethPrice, uint256 vSell) = _ethTerms();
        if (!ok) return (0, 0);
        paid = _price(_scoreOf(id), _fillBps(), ethPrice, vSell, bid.overEthBps);
        toArtist = paid * IBidCore(core).settings().buyToArtistBps / BPS;
        // the fill is two draws: each at most perCall, both together inside the bucket, the period and the lifetime
        IBidTreasury t = IBidTreasury(treasury);
        uint256 perCall = t.spenders(address(this)).perCall;
        if (paid > perCall || toArtist > perCall || paid + toArtist > t.drawableTotal(address(this))) return (0, 0);
    }

    // ------------------------------------------------------------------ the fill

    /// sells the caller's credits `ids` to the balance bid. each credit is paid `bidBps` of par, capped at its eth
    /// terms, and the artist `buyToArtistBps` of that on top, both drawn from this module's bucket. the credits go to
    /// the Core and are adopted into its pile in the same call. a credit the controller sold inside the Core's return
    /// lock is refused, so a credit bought from the engine's resale cannot come straight back through adoption. the
    /// caller has approved this module on Credits. the seller is paid exactly; the artist draw accrues in the treasury
    /// when the split cannot take it
    function sellCredit(uint256[] calldata ids, uint256 minOut) external nonReentrant returns (uint256 total) {
        if (!bidEnabled()) revert BidOff();
        if (ids.length == 0) revert InvalidAmount();
        IBidCore c = IBidCore(core);
        (bool ok, uint256 ethPrice, uint256 vSell) = _ethTerms();
        if (!ok) revert BidUnpriced();
        Settings memory cfg = c.settings();
        IBidController ctrl = IBidController(c.controller());
        BalanceBid memory b = bid;
        uint256 bps = _fillBps();
        uint256 artistTotal;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (IBidCredits(Mainnet.CREDITS).ownerOf(id) != msg.sender) revert NotOwner(id);
            uint256 soldAt = ctrl.creditSoldAt(id);
            if (soldAt != 0 && block.timestamp < soldAt + cfg.returnLockSeconds) revert ReturnLocked(id);
            uint256 score = _scoreOf(id);
            uint256 paid = _price(score, bps, ethPrice, vSell, b.overEthBps);
            if (paid == 0) revert ZeroAmount();
            uint256 toArtist = paid * cfg.buyToArtistBps / BPS;
            total += paid;
            artistTotal += toArtist;
            emit CreditSold(id, msg.sender, score, paid, toArtist, bps);
            uint256 drop = uint256(b.dropPer100PointsBps) * score / RATE_SCORE;
            bps = bps > b.floorBps + drop ? bps - drop : b.floorBps;
            IBidCredits(Mainnet.CREDITS).transferFrom(msg.sender, core, id);
        }
        if (total < minOut) revert Slippage();
        // forge-lint: disable-next-line(unsafe-typecast)
        bidAnchorBps = uint16(bps);
        bidAnchorTime = uint40(block.timestamp);
        bidOut += total + artistTotal;

        c.adopt(ids);
        for (uint256 i; i < ids.length; ++i) {
            (bool inPile,,) = c.creditInfo(ids[i]);
            if (!inPile) revert NotInPile(ids[i]);
        }
        IBidTreasury t = IBidTreasury(treasury);
        t.draw(msg.sender, total, false);
        if (artistTotal != 0) t.draw(c.artist(), artistTotal, true);
        emit BidFill(msg.sender, ids.length, total, artistTotal, bidBudget());
    }

    /// the eth terms of the bid: the Core's eth price per 100 points and the controller's value of one point at the
    /// protected sale price. false on a zero price or an unusable quote, which pauses the bid
    function _ethTerms() private view returns (bool ok, uint256 ethPrice, uint256 vSell) {
        ethPrice = IBidCore(core).ethPrice();
        (vSell, ok) = IBidController(IBidCore(core).controller()).valuePerPoint(true);
        ok = ok && ethPrice != 0 && vSell != 0;
    }

    /// `score * unitPerPoint * bps / 10_000`, at most the balance token worth `ethPrice * score / RATE_SCORE * (10_000 +
    /// overEthBps) / 10_000` wei at the protected sale price (`vSell` wei per `POINT_UNIT * unitPerPoint` base units)
    function _price(uint256 score, uint256 bps, uint256 ethPrice, uint256 vSell, uint256 overEthBps)
        private
        view
        returns (uint256 paid)
    {
        paid = score * unitPerPoint * bps / BPS;
        uint256 ethCap = FixedPointMathLib.fullMulDiv(ethPrice * score, BPS + overEthBps, RATE_SCORE * BPS);
        uint256 cap = FixedPointMathLib.fullMulDiv(ethCap, POINT_UNIT * unitPerPoint, vSell);
        if (cap < paid) paid = cap;
    }

    function _scoreOf(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
    }

    // ------------------------------------------------------------------ owner

    /// sets the band and restarts its price at `floorBps`. the cap is at most par and must stay below the controller's
    /// credit floor multiplier, so a credit the engine resells after its return lock is still worth more at the engine
    /// than here
    function setBid(BalanceBid calldata v) external onlyOwner {
        // par is the ceiling: a credit bought above par loses BALANCE on conversion
        if (v.floorBps > v.capBps || v.capBps == 0 || v.capBps > BPS) revert BadSetting("bidBand");
        if (v.climbBps != 0 && v.stepSeconds == 0) revert BadSetting("bidStep");
        if (v.capBps >= IBidController(IBidCore(core).controller()).floorMultBps()) revert BadSetting("bidCap");
        bid = v;
        bidAnchorBps = v.floorBps;
        bidAnchorTime = uint40(block.timestamp);
        emit BidSet(v);
    }
}
