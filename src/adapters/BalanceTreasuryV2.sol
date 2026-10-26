// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {
    IBalanceModule,
    IRedeemer,
    Mainnet,
    CommittedPayout,
    SpenderState
} from "../interfaces/Interfaces.sol";

/// the InterfaceAuctionWithdrawals surface this treasury reads
interface IV2BalanceToken {
    function statements() external view returns (address);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function decimals() external view returns (uint8);
    function ready() external view returns (bool);
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
}

interface IV2Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IV2Statements {
    function approve(address to, uint256 id) external;
    function creditScoreOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
}

interface IV2Core {
    function owner() external view returns (address);
    function COIN() external view returns (address);
    function retired() external view returns (bool);
    function successor() external view returns (address);
    function balanceModule() external view returns (address);
}

interface IV2Coin {
    function totalSupply() external view returns (uint256);
    function burnFrom(address account, uint256 amount) external;
}

/// the surface of a successor this treasury migrates to: a later BalanceTreasuryV2 or a treasury built on the same
/// handshake
interface IV2Successor {
    function core() external view returns (address);
    function balanceToken() external view returns (address);
    function ccToken() external view returns (address);
    function predecessor() external view returns (address);
    function migrated() external view returns (bool);
    function conversionEnabled() external view returns (bool);
    function workingPaymentsEnabled() external view returns (bool);
    function ccRedemptionEnabled() external view returns (bool);
    function receiveMigration(uint256 claimAmount) external;
}

/// treasury v2, the balance module and the custodian of the balance token. the Core faces the v1 surface unchanged
/// (`unitPerPoint` 1e14, `available`, `pay`, `redeem`). custody `B` is split into earmarks and working funds:
///
///   D = totalOwed, recorded unpaid payments; K = totalBuckets, the spender buckets; L = totalCommitted, vesting and
///   deferred payouts; W = B - D - K - L, working funds
///
/// the rule is B >= D + K + L. the Core's exchange pays from W (`available()`). `cushion` is the part of W kept for the
/// Core's exchange: `sweep`, allocation and withdrawal take only `surplus()`, W above the cushion. every rule that
/// spends the backing is a registered spender with its own bucket, switch, caps and share of each sweep: a redeemer
/// (quoted through `IRedeemer` for a CC burn in `redeemCC`) or a module that draws itself (`draw`), the credit bid
/// (src/adapters/CreditBid.sol) among them. no bucket pays from another, the debt or the cushion; every committed
/// payout is reserved in full when it is created. the treasury itself holds no pricing rule, so a new rule is a new
/// spender: deploy, register, fund its bucket, switch it on. the owner is the Core's owner and manages the backing:
/// it can pause, return a switched off spender's bucket to working funds, withdraw the surplus and, as a last resort,
/// migrate the custody to a successor through the same handshake v1 used
contract BalanceTreasuryV2 is IBalanceModule {
    address public immutable core;
    address public immutable override balanceToken;
    /// the Core's coin, the token redemptions burn
    address public immutable ccToken;
    /// the treasury `receiveMigration` accepts from, zero for none
    address public immutable predecessor;
    /// redeemer 1, registered at deployment: the conversion contribution and a migrated claim reserve fill its bucket
    address public immutable proRataRedeemer;
    uint256 public constant override unitPerPoint = 1e14;

    uint256 private constant BPS = 10_000;
    /// gas kept back from a payment transfer so an unpaid amount can still be recorded: two storage writes and an event
    uint256 private constant ACCRUE_RESERVE = 60_000;
    /// the period of the per-period caps of the spenders
    uint256 private constant PERIOD = 1 days;
    /// a newly registered spender draws nothing before this delay
    uint256 private constant NEW_SPENDER_DELAY = 1 days;
    uint256 private constant MAX_SPENDERS = 8;
    uint256 private constant MAX_DURATION = 4 * 365 days;
    /// transient reentrancy lock slot, keccak256("BalanceTreasuryV2.lock") less one
    uint256 private constant LOCK_SLOT = 0xacad7041682364bcd8282b25bcb22caf85f0b515f60f41b113151841b24681ad;

    error InvalidConfiguration();
    error OnlyCore();
    error OnlyOwner();
    error OnlyPredecessor();
    error Reentrant();
    error Paused();
    error ConversionOff();
    error RedemptionOff();
    error SpenderOff();
    error NotHeld();
    error RedeemedBelowRating();
    error InsufficientAvailable();
    error InsufficientSurplus();
    error InsufficientBucket();
    error OverCap();
    error BadSetting(bytes32 field);
    error BadPayout();
    error UnknownSpender();
    error ZeroAmount();
    error InvalidAmount();
    error InvalidRecipient();
    error Expired();
    error StaleEpoch();
    error Slippage();
    error BurnMismatch();
    error ShortPayment();
    error SpenderOn();
    error Insolvent();
    error ProtectedAsset();
    error NothingDue();
    error Migrated();
    error SwitchesOn();
    error InvalidSuccessor();

    event StatementConverted(uint256 indexed statementId, uint256 received, uint256 toProRata, uint16 contributionBps);
    event PaymentAccrued(address indexed to, uint256 amount);
    event OwedClaimed(address indexed to, uint256 amount);
    event Drawn(address indexed spender, address indexed to, uint256 amount, uint256 accrued, uint256 bucket);
    event Swept(uint256 surplus, uint256 toBuckets);
    event Allocated(address indexed spender, uint256 amount);
    event Unallocated(address indexed spender, uint256 amount);
    event SpenderRegistered(address indexed spender, uint40 activeAt);
    event SpenderCapsSet(address indexed spender, uint128 perCall, uint128 perPeriod, uint128 lifetime, uint64 epoch);
    event SpenderSwitched(address indexed spender, bool on);
    event SharesSet(address indexed spender, uint16 shareBps, uint16 totalShareBps);
    event CCRedeemed(
        address indexed redeemer,
        address indexed burner,
        address indexed recipient,
        uint256 ccIn,
        uint256 amount,
        uint8 mode,
        uint32 duration,
        uint256 claimId,
        uint64 epoch
    );
    event ClaimReleased(uint256 indexed claimId, address indexed recipient, uint256 amount);
    event SwitchesSet(bool conversionEnabled, bool workingPaymentsEnabled);
    event PausedSet(bool paused);
    event CushionSet(uint256 cushion);
    event ConversionToClaimBpsSet(uint16 bps);
    event WorkingWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event MigrationReceived(address indexed predecessor, uint256 claimsImported, uint256 custody);
    event TreasuryMigrated(address indexed successor, uint256 moved, uint256 claimsExported);

    mapping(address => uint256) public owed;
    uint256 public totalOwed;
    uint256 public totalBuckets;
    uint256 public totalCommitted;
    /// working funds kept for the Core's exchange
    uint256 public cushion;

    /// share of each measured conversion receipt added to the pro-rata redeemer's bucket, bps
    uint16 public conversionToClaimBps;
    /// the sum of the spender shares of a sweep, bps, at most 10,000
    uint16 public totalShareBps;
    bool public conversionEnabled;
    bool public workingPaymentsEnabled;
    bool public paused;
    /// set by `migrateTo`: every switch and spender stays off forever after
    bool public migrated;

    mapping(address => SpenderState) internal _spenders;
    address[] public spenderList;
    CommittedPayout[] private _claims;

    constructor(
        address core_,
        address balanceToken_,
        address proRataRedeemer_,
        uint128 proRataPerPeriod,
        address predecessor_
    ) {
        if (core_.code.length == 0 || balanceToken_.code.length == 0) revert InvalidConfiguration();
        IV2BalanceToken token = IV2BalanceToken(balanceToken_);
        if (
            token.statements() != Mainnet.STATEMENTS || token.SCORE_TO_TOKEN() != unitPerPoint || token.decimals() != 18
        ) revert InvalidConfiguration();
        address coin = IV2Core(core_).COIN();
        if (coin.code.length == 0) revert InvalidConfiguration();
        if (predecessor_ != address(0) && predecessor_.code.length == 0) revert InvalidConfiguration();
        core = core_;
        balanceToken = balanceToken_;
        ccToken = coin;
        predecessor = predecessor_;
        proRataRedeemer = proRataRedeemer_;
        conversionToClaimBps = 1_000;
        _register(proRataRedeemer_, type(uint128).max, proRataPerPeriod, type(uint128).max);
    }

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OnlyOwner();
        _;
    }

    /// one transient lock over every mutation and outflow, so the Core's two sequential `pay` calls of one sale both
    /// pass while a token, artwork or spender callback cannot enter a second outflow
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

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    // ------------------------------------------------------------------ views

    /// the Core's current owner, read at each use so an ownership handover carries over
    function owner() public view returns (address) {
        return IV2Core(core).owner();
    }

    /// `B`, the balance token held here
    function custody() public view returns (uint256) {
        return SafeTransferLib.balanceOf(balanceToken, address(this));
    }

    /// D + K + L
    function earmarked() public view returns (uint256) {
        return totalOwed + totalBuckets + totalCommitted;
    }

    /// `W`, custody less every earmark, floored at zero
    function working() public view returns (uint256) {
        uint256 bal = custody();
        uint256 e = earmarked();
        return bal > e ? bal - e : 0;
    }

    /// working funds above the cushion: what `sweep`, allocation and withdrawal may take
    function surplus() public view returns (uint256) {
        uint256 w = working();
        return w > cushion ? w - cushion : 0;
    }

    function solvent() public view returns (bool) {
        return custody() >= earmarked();
    }

    /// this treasury is the bound Core's module and the Core has not retired: the gate of conversions and working
    /// payments, which need the Core. a spender that needs the Core (the credit bid adopts into the pile) reads it too
    function selected() public view returns (bool) {
        return IV2Core(core).balanceModule() == address(this) && !IV2Core(core).retired();
    }

    /// this treasury is the bound Core's module: the gate of every spender draw, which needs no Core interaction, so a
    /// retired Core does not strand the buckets. a module replacement closes them
    function selectedForClaims() public view returns (bool) {
        return IV2Core(core).balanceModule() == address(this);
    }

    function retirementFinalized() public view returns (bool) {
        IV2BalanceToken token = IV2BalanceToken(balanceToken);
        uint256 retired = token.totalRetired();
        return retired != 0 && retired == token.launchRetirement();
    }

    /// a statement conversion can run: the switch, the selection, finalized retirement and the registered renderer
    function conversionReady() public view returns (bool) {
        return conversionEnabled && selected() && retirementFinalized() && IV2BalanceToken(balanceToken).ready();
    }

    /// the balance token the Core's exchange may pay out: working funds while working payments are on and this
    /// treasury is selected, else zero. never reverts, so `setBalanceModule` can probe it before selection
    function available() public view override returns (uint256) {
        if (!workingPaymentsEnabled || !selected()) return 0;
        return working();
    }

    /// whether any spender is on. read by a predecessor's `migrateTo` handshake, which requires false
    function ccRedemptionEnabled() public view returns (bool) {
        for (uint256 i; i < spenderList.length; ++i) {
            if (_spenders[spenderList[i]].on) return true;
        }
        return false;
    }

    function spenders(address spender) external view returns (SpenderState memory) {
        return _spenders[spender];
    }

    function spenderCount() external view returns (uint256) {
        return spenderList.length;
    }

    /// what `spender` may draw now in one call: `drawableTotal` capped at `perCall`
    function drawable(address spender) external view returns (uint256) {
        uint256 x = drawableTotal(spender);
        uint256 perCall = _spenders[spender].perCall;
        return x > perCall ? perCall : x;
    }

    /// what `spender` may draw now over any number of calls: its bucket inside its period and lifetime room, zero
    /// while it is off, not yet active, the treasury is paused or not the module. a module that pays in several
    /// draws quotes against this and `perCall` on each draw
    function drawableTotal(address spender) public view returns (uint256) {
        SpenderState storage r = _spenders[spender];
        if (!r.registered || !r.on || paused || block.timestamp < r.activeAt || !selectedForClaims()) return 0;
        uint256 x = r.bucket;
        uint256 used = block.timestamp >= uint256(r.periodStart) + PERIOD ? 0 : r.periodUsed;
        uint256 period = r.perPeriod > used ? r.perPeriod - used : 0;
        if (x > period) x = period;
        uint256 life = r.lifetime > r.lifetimeUsed ? r.lifetime - r.lifetimeUsed : 0;
        if (x > life) x = life;
        return x;
    }

    function claimCount() external view returns (uint256) {
        return _claims.length;
    }

    /// committed payout `claimId` (1 based) and the amount `release` would pay now
    function claimOf(uint256 claimId) external view returns (CommittedPayout memory c, uint256 due) {
        c = _claims[claimId - 1];
        due = _vested(c) - c.released;
    }

    // ------------------------------------------------------------------ the Core's module calls

    /// the Core transfers custody first. approval is limited to this statement and consumed by the withdrawal. the receipt
    /// is measured and must be at least the statement's rating times `unitPerPoint`; `conversionToClaimBps` of it fills
    /// the pro-rata redeemer's bucket and every token stays here, so the Core's receipt check reads the whole amount
    function redeem(uint256 statementId) external override onlyCore nonReentrant returns (uint256 out) {
        if (!conversionEnabled || !selected()) revert ConversionOff();
        IV2BalanceToken token = IV2BalanceToken(balanceToken);
        IV2Statements statements = IV2Statements(Mainnet.STATEMENTS);
        if (statements.ownerOf(statementId) != address(this)) revert NotHeld();
        uint256 required = statements.creditScoreOf(statementId) * unitPerPoint;
        uint256 expected = token.quote(statementId);
        statements.approve(balanceToken, statementId);
        uint256 before = custody();
        token.withdraw(statementId, expected);
        out = custody() - before;
        if (out < required) revert RedeemedBelowRating();
        uint16 bps = conversionToClaimBps;
        uint256 toProRata = out * bps / BPS;
        if (toProRata != 0) _fill(_spenders[proRataRedeemer], toProRata);
        emit StatementConverted(statementId, out, toProRata, bps);
    }

    /// pays at most `available()`, working funds only, with the v1 accrual: a transfer that fails, runs out of gas or
    /// moves less than `amount` records exactly the undelivered part in `owed[to]`. the Core checks the seller's
    /// receipt itself and bounds the artist call
    function pay(address to, uint256 amount) external override onlyCore nonReentrant {
        if (amount > available()) revert InsufficientAvailable();
        _payOrAccrue(to, amount);
    }

    /// pays `owed[to]` to `to` with all gas. anyone may call, whatever the switches
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = owed[to];
        owed[to] = 0;
        totalOwed -= amount;
        if (amount != 0) {
            SafeTransferLib.safeTransfer(balanceToken, to, amount);
            emit OwedClaimed(to, amount);
        }
    }

    // ------------------------------------------------------------------ the spender draw

    /// the calling spender pays `to` `amount` from its own bucket, inside its caps, while it is on and active and this
    /// treasury is the module. `accrue` false requires exact delivery; true transfers with bounded gas and records the
    /// undelivered part in `owed[to]`, for a recipient that may revert or burn gas (the artist split). the treasury
    /// checks only the bucket, the caps and the recipient: what the spender got for the payment is the spender's rule
    function draw(address to, uint256 amount, bool accrue) external nonReentrant notPaused {
        SpenderState storage r = _spenders[msg.sender];
        if (!r.registered || !r.on || block.timestamp < r.activeAt || !selectedForClaims()) revert SpenderOff();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (amount > r.bucket) revert InsufficientBucket();
        _useCaps(r, amount);
        r.bucket -= amount;
        r.totalOut += amount;
        totalBuckets -= amount;
        uint256 accrued;
        if (accrue) accrued = _payOrAccrue(to, amount);
        else _transferExact(to, amount);
        emit Drawn(msg.sender, to, amount, accrued, r.bucket);
    }

    // ------------------------------------------------------------------ funding

    /// moves the whole surplus (working funds above the cushion) into the spender buckets in proportion to the
    /// owner's shares, `s * share / totalShareBps`; with no share set nothing moves. the surplus is split in full so
    /// a repeated call finds nothing left: a share is a proportion of what leaves working funds, never a rate at which
    /// working funds drain (a partial share base would re-share the remainder on every call). anyone may call
    function sweep() external nonReentrant notPaused returns (uint256 moved) {
        uint256 s = surplus();
        uint256 total = totalShareBps;
        if (s == 0 || total == 0) return 0;
        for (uint256 i; i < spenderList.length; ++i) {
            SpenderState storage r = _spenders[spenderList[i]];
            uint256 x = s * r.shareBps / total;
            if (x != 0) {
                _fill(r, x);
                moved += x;
            }
        }
        emit Swept(s, moved);
    }

    function _fill(SpenderState storage r, uint256 x) private {
        r.bucket += x;
        r.totalIn += x;
        totalBuckets += x;
    }

    // ------------------------------------------------------------------ redemption

    /// burns `ccIn` of the caller's CC through `redeemer` and pays `recipient` the redeemer's quote from its own
    /// bucket: at once, or as a committed payout reserved in full now and released by `release`. the treasury checks
    /// only the burn, the bucket, the caps, the recipient and the caller's pinned epoch. the caller has approved this
    /// treasury on the coin for `burnFrom`. returns the payout and the claim id (zero for an immediate payout)
    function redeemCC(
        address redeemer,
        uint256 ccIn,
        address recipient,
        uint256 minOut,
        uint256 deadline,
        uint64 expectedEpoch,
        bytes calldata data
    ) external nonReentrant notPaused returns (uint256 amount, uint256 claimId) {
        if (block.timestamp > deadline) revert Expired();
        SpenderState storage r = _spenders[redeemer];
        if (!r.on || block.timestamp < r.activeAt || !selectedForClaims()) revert RedemptionOff();
        if (expectedEpoch != r.epoch) revert StaleEpoch();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 supply = IV2Coin(ccToken).totalSupply();
        if (ccIn == 0 || ccIn > supply) revert InvalidAmount();
        uint8 mode;
        uint32 duration;
        (amount, mode, duration) = IRedeemer(redeemer).quote(msg.sender, ccIn, r.bucket, supply, data);
        if (amount == 0) revert ZeroAmount();
        if (amount < minOut) revert Slippage();
        if (amount > r.bucket) revert InsufficientBucket();
        if (mode > 2 || (mode != 0 && (duration == 0 || duration > MAX_DURATION))) revert BadPayout();
        _useCaps(r, amount);
        r.bucket -= amount;
        r.totalOut += amount;
        totalBuckets -= amount;

        IV2Coin(ccToken).burnFrom(msg.sender, ccIn);
        if (IV2Coin(ccToken).totalSupply() != supply - ccIn) revert BurnMismatch();
        if (mode == 0) {
            _transferExact(recipient, amount);
        } else {
            totalCommitted += amount;
            _claims.push(
                CommittedPayout({
                    recipient: recipient,
                    redeemer: redeemer,
                    start: uint40(block.timestamp),
                    end: uint40(block.timestamp + duration),
                    linear: mode == 1,
                    amount: uint128(amount),
                    released: 0
                })
            );
            claimId = _claims.length;
        }
        emit CCRedeemed(redeemer, msg.sender, recipient, ccIn, amount, mode, duration, claimId, r.epoch);
    }

    function _useCaps(SpenderState storage r, uint256 amount) private {
        if (amount > r.perCall) revert OverCap();
        if (block.timestamp >= uint256(r.periodStart) + PERIOD) {
            r.periodStart = uint40(block.timestamp);
            r.periodUsed = 0;
        }
        if (uint256(r.periodUsed) + amount > r.perPeriod) revert OverCap();
        if (uint256(r.lifetimeUsed) + amount > r.lifetime) revert OverCap();
        r.periodUsed += uint128(amount);
        r.lifetimeUsed += uint128(amount);
    }

    /// pays the vested, unreleased part of committed payout `claimId` to its recipient. anyone may call, whatever the
    /// switches and the pause
    function release(uint256 claimId) external nonReentrant returns (uint256 out) {
        CommittedPayout storage c = _claims[claimId - 1];
        out = _vested(c) - c.released;
        if (out == 0) revert NothingDue();
        c.released += uint128(out);
        totalCommitted -= out;
        SafeTransferLib.safeTransfer(balanceToken, c.recipient, out);
        emit ClaimReleased(claimId, c.recipient, out);
    }

    function _vested(CommittedPayout memory c) private view returns (uint256) {
        if (block.timestamp >= c.end) return c.amount;
        if (!c.linear || block.timestamp <= c.start) return 0;
        return uint256(c.amount) * (block.timestamp - c.start) / (c.end - c.start);
    }

    // ------------------------------------------------------------------ payments

    /// transfers `amount` with all gas but `ACCRUE_RESERVE` and records the undelivered part in `owed[to]`. returns
    /// the part recorded
    function _payOrAccrue(address to, uint256 amount) private returns (uint256 short) {
        uint256 before = custody();
        uint256 g = gasleft();
        if (g > ACCRUE_RESERVE) {
            (bool sent,) = balanceToken.call{gas: g - ACCRUE_RESERVE}(abi.encodeCall(IV2Transfer.transfer, (to, amount)));
            sent;
        }
        uint256 afterBal = custody();
        uint256 delivered = before > afterBal ? before - afterBal : 0;
        if (delivered < amount) {
            short = amount - delivered;
            owed[to] += short;
            totalOwed += short;
            emit PaymentAccrued(to, short);
        }
    }

    /// transfers `amount` to `to` and requires both the recipient's receipt and custody's fall to equal it
    function _transferExact(address to, uint256 amount) private {
        uint256 before = custody();
        uint256 held = SafeTransferLib.balanceOf(balanceToken, to);
        SafeTransferLib.safeTransfer(balanceToken, to, amount);
        if (SafeTransferLib.balanceOf(balanceToken, to) < held + amount || custody() + amount != before) {
            revert ShortPayment();
        }
    }

    // ------------------------------------------------------------------ owner

    /// refused forever after `migrateTo`
    function setSwitches(bool conversion, bool workingPayments) external onlyOwner {
        if (migrated) revert Migrated();
        conversionEnabled = conversion;
        workingPaymentsEnabled = workingPayments;
        emit SwitchesSet(conversion, workingPayments);
    }

    /// stops every spender draw, redemption and sweep. the Core's calls, `claim` and `release` keep running
    function setPaused(bool on) external onlyOwner {
        paused = on;
        emit PausedSet(on);
    }

    function setCushion(uint256 v) external onlyOwner {
        cushion = v;
        emit CushionSet(v);
    }

    /// 0 to 10,000. applies to later conversions only
    function setConversionToClaimBps(uint16 v) external onlyOwner {
        if (v > BPS) revert BadSetting("conversionToClaimBps");
        conversionToClaimBps = v;
        emit ConversionToClaimBpsSet(v);
    }

    /// the sweep share of a registered spender's bucket, bps. the shares sum to at most 10,000
    function setSpenderShare(address spender, uint16 v) external onlyOwner {
        SpenderState storage r = _spenders[spender];
        if (!r.registered) revert UnknownSpender();
        uint256 total = totalShareBps - r.shareBps + v;
        if (total > BPS) revert BadSetting("shares");
        r.shareBps = v;
        // forge-lint: disable-next-line(unsafe-typecast)
        totalShareBps = uint16(total);
        emit SharesSet(spender, v, uint16(total));
    }

    /// registers a spender, switched off, drawing nothing for `NEW_SPENDER_DELAY`, with a nonzero per-period cap
    function registerSpender(address spender, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        external
        onlyOwner
    {
        _register(spender, perCall, perPeriod, lifetime);
    }

    function _register(address spender, uint128 perCall, uint128 perPeriod, uint128 lifetime) private {
        if (spender.code.length == 0 || _spenders[spender].registered || spenderList.length == MAX_SPENDERS) {
            revert BadSetting("spender");
        }
        SpenderState storage r = _spenders[spender];
        r.registered = true;
        r.activeAt = uint40(block.timestamp + NEW_SPENDER_DELAY);
        spenderList.push(spender);
        emit SpenderRegistered(spender, r.activeAt);
        _setCaps(r, spender, perCall, perPeriod, lifetime);
    }

    /// a spender's caps. the per-period cap is never zero; the epoch advances
    function setSpenderCaps(address spender, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        external
        onlyOwner
    {
        SpenderState storage r = _spenders[spender];
        if (!r.registered) revert UnknownSpender();
        _setCaps(r, spender, perCall, perPeriod, lifetime);
    }

    function _setCaps(SpenderState storage r, address spender, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        private
    {
        if (perPeriod == 0) revert BadSetting("perPeriod");
        r.perCall = perCall;
        r.perPeriod = perPeriod;
        r.lifetime = lifetime;
        ++r.epoch;
        emit SpenderCapsSet(spender, perCall, perPeriod, lifetime, r.epoch);
    }

    /// switching on is refused forever after `migrateTo`
    function setSpenderOn(address spender, bool on) external onlyOwner {
        SpenderState storage r = _spenders[spender];
        if (!r.registered) revert UnknownSpender();
        if (on && migrated) revert Migrated();
        r.on = on;
        emit SpenderSwitched(spender, on);
    }

    /// moves `amount` of the surplus into a registered spender's bucket
    function allocate(address spender, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > surplus()) revert InsufficientSurplus();
        SpenderState storage r = _spenders[spender];
        if (!r.registered) revert UnknownSpender();
        _fill(r, amount);
        emit Allocated(spender, amount);
    }

    /// returns `amount` of a switched off spender's bucket to working funds. the return advances the spender's epoch
    /// so a pinned quote cannot execute against the smaller bucket
    function unallocate(address spender, uint256 amount) external onlyOwner nonReentrant {
        SpenderState storage r = _spenders[spender];
        if (!r.registered) revert UnknownSpender();
        if (r.on) revert SpenderOn();
        if (amount == 0 || amount > r.bucket) revert InsufficientBucket();
        r.bucket -= amount;
        r.totalOut += amount;
        totalBuckets -= amount;
        ++r.epoch;
        emit Unallocated(spender, amount);
    }

    /// sends `amount` of the surplus to `to`. never an earmark or the cushion
    function withdrawWorking(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0 || amount > surplus()) revert InsufficientSurplus();
        SafeTransferLib.safeTransfer(balanceToken, to, amount);
        emit WorkingWithdrawn(to, amount);
    }

    /// moves an unrelated erc20 out. never the balance token, the coin, Credits or Statements
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == balanceToken || token == ccToken || token == Mainnet.STATEMENTS || token == Mainnet.CREDITS) {
            revert ProtectedAsset();
        }
        if (to == address(0)) revert InvalidRecipient();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ------------------------------------------------------------------ migration

    /// the successor side of a predecessor's `migrateTo`: the custody has already landed; `claimAmount`, the
    /// predecessor's claim reserve or pro-rata bucket, fills the pro-rata redeemer's bucket once custody covers it
    /// with every existing earmark
    function receiveMigration(uint256 claimAmount) external nonReentrant {
        if (predecessor == address(0) || msg.sender != predecessor) revert OnlyPredecessor();
        if (custody() < earmarked() + claimAmount) revert Insolvent();
        SpenderState storage r = _spenders[proRataRedeemer];
        _fill(r, claimAmount);
        ++r.epoch;
        emit MigrationReceived(msg.sender, claimAmount, custody());
    }

    /// the last resort, the v1 handshake again: moves custody less the recorded debt and the committed payouts to
    /// `successor` and exports the pro-rata bucket there. every switch and spender must be off here, every other
    /// bucket returned to working funds first (`unallocate`), and the successor must bind the same coin and token and
    /// either the same Core or, once this Core has retired, the Core's successor, name this treasury as its
    /// predecessor, not have migrated itself, have every switch off and already be the selected module of its Core,
    /// so the order is select the successor, migrate, enable it. this treasury then refuses every switch and spender
    /// forever; `claim` and `release` keep paying what it left behind, and later inflows leave through
    /// `withdrawWorking`. a rule change never needs this: a new rule is a new spender. the successor's answers are its
    /// own word: the owner alone selects it, so this is the owner's power to move every token but the debt and the
    /// committed payouts to a contract of its choosing, to be pinned and rehearsed like the v1 to v2 move
    function migrateTo(address successor) external onlyOwner nonReentrant returns (uint256 moved) {
        if (migrated) revert Migrated();
        if (conversionEnabled || workingPaymentsEnabled || ccRedemptionEnabled()) revert SwitchesOn();
        if (successor == address(this) || successor.code.length == 0) revert InvalidSuccessor();
        IV2Successor next = IV2Successor(successor);
        address nextCore = next.core();
        if (nextCore != core) {
            IV2Core c = IV2Core(core);
            address heir = c.successor();
            if (!c.retired() || heir == address(0) || nextCore != heir) revert InvalidSuccessor();
        }
        if (IV2Core(nextCore).balanceModule() != successor) revert InvalidSuccessor();
        if (
            next.balanceToken() != balanceToken || next.ccToken() != ccToken || next.predecessor() != address(this)
                || next.migrated() || next.conversionEnabled() || next.workingPaymentsEnabled()
                || next.ccRedemptionEnabled()
        ) revert InvalidSuccessor();
        SpenderState storage r = _spenders[proRataRedeemer];
        uint256 claims = r.bucket;
        if (totalBuckets != claims) revert InsufficientBucket();
        uint256 bal = custody();
        uint256 kept = totalOwed + totalCommitted;
        moved = bal > kept ? bal - kept : 0;
        if (claims > moved) revert Insolvent();
        r.bucket = 0;
        r.totalOut += claims;
        totalBuckets = 0;
        ++r.epoch;
        migrated = true;
        uint256 held = SafeTransferLib.balanceOf(balanceToken, successor);
        if (moved != 0) SafeTransferLib.safeTransfer(balanceToken, successor, moved);
        next.receiveMigration(claims);
        // the token's word, not the successor's: the custody landed and stayed through the import
        if (SafeTransferLib.balanceOf(balanceToken, successor) < held + moved) revert ShortPayment();
        emit TreasuryMigrated(successor, moved, claims);
    }
}
