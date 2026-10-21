// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IBalanceModule, IRedemptionPolicy, Mainnet} from "../interfaces/Interfaces.sol";

/// the InterfaceAuctionWithdrawals surface this treasury reads. `withdraw` releases the token's own reserve and is
/// allowed before ordinary transfers open; ordinary transfers need finalized retirement, funding phase 3 and the open block
interface IAuctionBalanceToken {
    function statements() external view returns (address);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function decimals() external view returns (uint8);
    function ready() external view returns (bool);
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function fundingPhase() external view returns (uint8);
    function transfersOpenBlock() external view returns (uint64);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
}

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ITreasuryStatements {
    function approve(address to, uint256 id) external;
    function creditScoreOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
}

interface ITreasuryCore {
    function owner() external view returns (address);
    function COIN() external view returns (address);
    function retired() external view returns (bool);
    function successor() external view returns (address);
    function balanceModule() external view returns (address);
}

interface ITreasuryCoin {
    function totalSupply() external view returns (uint256);
    function burnFrom(address account, uint256 amount) external;
}

/// the successor handshake of `migrateTo`
interface IPhase2Successor {
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

/// the phase 2 balance module and the custodian of the balance token: it converts the Core's statements, pays the
/// Core's credit sellers and the artist from working funds, and pays CC burners a proportional share of its claim
/// reserve. accounts, in balance base units, with `B` the token held here:
///
///   C = claimReserve, backing for CC burns; D = totalOwed, recorded unpaid payments; W = B - C - D, working funds;
///   F = minimumWorkingBalance; the rule is B >= C + D, and `available()` for the Core's balance bid is max(W - F, 0)
///
/// working funds are derived from custody, never kept as a second total. unsolicited transfers are working funds. the
/// claim reserve moves only through conversions (`conversionToClaimBps` of each measured receipt), the owner's explicit
/// funding and reallocation, migration and CC burns. the owner is the Core's owner. the owner can move backing back to
/// working funds while CC redemption is paused and can withdraw free working funds: backing is owner managed, not
/// inaccessible. every administrative change to a burner's terms advances `configEpoch`, which `redeemCC` pins.
/// the redemption policy is a bounded static read whose answer is capped at the proportional share computed here
contract Phase2BalanceTreasury is IBalanceModule {
    address public immutable core;
    address public immutable override balanceToken;
    /// the Core's coin, the token `redeemCC` burns
    address public immutable ccToken;
    /// the treasury `receiveMigration` accepts from, zero for a first treasury
    address public immutable predecessor;
    uint256 public constant override unitPerPoint = 1e14;

    uint256 private constant BPS = 10_000;
    /// gas kept back from a payment transfer so an unpaid amount can still be recorded: two storage writes and an event
    uint256 private constant ACCRUE_RESERVE = 60_000;
    /// gas of a policy read. the policy is pure arithmetic; a policy that needs more fails closed
    uint256 private constant POLICY_GAS = 200_000;
    /// the upstream funding phase after which ordinary transfers can open
    uint8 private constant FUNDING_COMPLETE = 3;
    /// transient reentrancy lock slot, keccak256("Phase2BalanceTreasury.lock") less one
    uint256 private constant LOCK_SLOT = 0x9e6a3b0f1d2c4e5f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e00;

    error InvalidConfiguration();
    error OnlyCore();
    error OnlyOwner();
    error OnlyPredecessor();
    error Reentrant();
    error ConversionOff();
    error RedemptionOff();
    error NotHeld();
    error RedeemedBelowRating();
    error InsufficientAvailable();
    error InsufficientWorking();
    error InsufficientClaims();
    error Insolvent();
    error BadSetting(bytes32 field);
    error BadPolicy();
    error ZeroSupply();
    error ZeroAmount();
    error InvalidAmount();
    error InvalidRecipient();
    error Expired();
    error StaleEpoch();
    error Slippage();
    error BurnMismatch();
    error ShortPayment();
    error RedemptionEnabled();
    error SwitchesOn();
    error Migrated();
    error InvalidSuccessor();
    error ProtectedAsset();

    event StatementConverted(
        uint256 indexed statementId, uint256 received, uint256 allocated, uint16 contributionBps, uint256 claimReserve
    );
    event PaymentAccrued(address indexed to, uint256 amount);
    event OwedClaimed(address indexed to, uint256 amount);
    event CCRedeemed(
        address indexed burner,
        address indexed recipient,
        uint256 ccIn,
        uint256 balanceOut,
        uint256 claimReserve,
        uint256 ccSupply,
        uint64 configEpoch
    );
    event SwitchesSet(bool conversionEnabled, bool workingPaymentsEnabled, bool ccRedemptionEnabled);
    event ConversionToClaimBpsSet(uint16 bps);
    event RedemptionFeeSet(uint16 bps, uint64 configEpoch);
    event MinimumWorkingBalanceSet(uint256 amount);
    event RedemptionPolicySet(address indexed policy, uint64 configEpoch);
    event ClaimsFunded(address indexed from, uint256 amount, uint256 claimReserve);
    event ClaimsAllocated(uint256 amount, uint256 claimReserve);
    event ClaimsReturned(uint256 amount, uint256 claimReserve, uint64 configEpoch);
    event WorkingWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event TreasuryMigrated(address indexed successor, uint256 moved, uint256 claimsImported, uint64 configEpoch);
    event MigrationReceived(
        address indexed predecessor, uint256 claimsImported, uint256 claimReserve, uint64 configEpoch
    );

    /// balance base units backing CC burns. never spent by `pay`
    uint256 public claimReserve;
    /// balance token owed to an address whose transfer from `pay` did not complete. excluded from `available()`
    mapping(address => uint256) public owed;
    uint256 public totalOwed;
    /// working funds `available()` keeps back from the Core's balance bid
    uint256 public minimumWorkingBalance;
    /// share of each measured conversion receipt added to the claim reserve, bps. 300 at deployment
    uint16 public conversionToClaimBps;
    /// fee the policy keeps in the claim reserve on a CC burn, bps. 0 at deployment
    uint16 public redemptionFeeBps;
    /// the three money movement switches, all false at deployment
    bool public conversionEnabled;
    bool public workingPaymentsEnabled;
    bool public ccRedemptionEnabled;
    /// the quote `redeemCC` reads. replaceable by the owner; replacement turns CC redemption off
    address public redemptionPolicy;
    /// advances on every administrative change to a burner's terms: policy, fee, a claim reduction, migration
    uint64 public configEpoch;
    /// true after `migrateTo`: no switch can be turned on again and the claim reserve is zero
    bool public migrated;

    constructor(address core_, address balanceToken_, address policy_, address predecessor_) {
        if (core_.code.length == 0 || balanceToken_.code.length == 0) revert InvalidConfiguration();
        IAuctionBalanceToken token = IAuctionBalanceToken(balanceToken_);
        if (
            token.statements() != Mainnet.STATEMENTS || token.SCORE_TO_TOKEN() != unitPerPoint || token.decimals() != 18
        ) revert InvalidConfiguration();
        address coin = ITreasuryCore(core_).COIN();
        if (coin.code.length == 0) revert InvalidConfiguration();
        if (predecessor_ != address(0) && predecessor_.code.length == 0) revert InvalidConfiguration();
        core = core_;
        balanceToken = balanceToken_;
        ccToken = coin;
        predecessor = predecessor_;
        conversionToClaimBps = 300;
        _setPolicy(policy_);
    }

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OnlyOwner();
        _;
    }

    /// one lock over every mutation and outflow. transient, set and cleared per call, so the Core's two sequential `pay`
    /// calls of one sale both pass while a token or artwork callback cannot enter a second outflow
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

    /// the Core's current owner, read at each use so an ownership handover carries over
    function owner() public view returns (address) {
        return ITreasuryCore(core).owner();
    }

    /// `B`, the balance token held here
    function custody() public view returns (uint256) {
        return SafeTransferLib.balanceOf(balanceToken, address(this));
    }

    /// `W`, custody less the claim reserve and the recorded debt, floored at zero
    function working() public view returns (uint256) {
        uint256 bal = custody();
        uint256 reserved = claimReserve + totalOwed;
        return bal > reserved ? bal - reserved : 0;
    }

    /// working funds above the minimum working balance
    function freeWorking() public view returns (uint256) {
        uint256 w = working();
        uint256 floor = minimumWorkingBalance;
        return w > floor ? w - floor : 0;
    }

    /// custody covers the claim reserve and the recorded debt
    function solvent() public view returns (bool) {
        return custody() >= claimReserve + totalOwed;
    }

    /// this treasury is the bound Core's selected module, the Core has not retired and this treasury has not migrated:
    /// the gate of conversions and working payments, which need the Core
    function selected() public view returns (bool) {
        return selectedForClaims() && !ITreasuryCore(core).retired();
    }

    /// this treasury is the bound Core's selected module and has not migrated: the gate of CC burns, which need no
    /// Core interaction, so a retired Core does not strand the claim reserve. a module replacement still closes it, so
    /// two publicly active claim pools cannot exist by accident
    function selectedForClaims() public view returns (bool) {
        return !migrated && ITreasuryCore(core).balanceModule() == address(this);
    }

    /// the upstream launch retirement is finalized
    function retirementFinalized() public view returns (bool) {
        IAuctionBalanceToken token = IAuctionBalanceToken(balanceToken);
        uint256 retired = token.totalRetired();
        return retired != 0 && retired == token.launchRetirement();
    }

    /// a statement conversion can run: the switch, the selection, finalized retirement and the registered renderer. the
    /// token releases its own reserve before ordinary transfers open, so this can be true while `transfersReady` is not
    function conversionReady() public view returns (bool) {
        return conversionEnabled && selected() && retirementFinalized() && IAuctionBalanceToken(balanceToken).ready();
    }

    /// ordinary balance transfers are open: finalized retirement, funding phase 3 and the bound open block reached
    function transfersReady() public view returns (bool) {
        IAuctionBalanceToken token = IAuctionBalanceToken(balanceToken);
        uint64 open = token.transfersOpenBlock();
        return retirementFinalized() && token.fundingPhase() == FUNDING_COMPLETE && open != 0 && block.number >= open;
    }

    /// the balance token the Core's bid may pay out: free working funds while working payments are on, this treasury is
    /// selected and transfers are open; else zero. never reverts, so `setBalanceModule` can probe it before selection
    function available() public view override returns (uint256) {
        if (!workingPaymentsEnabled || !selected() || !transfersReady()) return 0;
        return freeWorking();
    }

    /// the balance token `redeemCC(ccIn)` would pay now and whether it would execute for reasons other than the burner's
    /// own minimum and deadline. `balanceOut` is zero for an input the policy or the cap refuses
    function quoteRedemption(uint256 ccIn)
        external
        view
        returns (uint256 balanceOut, uint256 reserve, uint256 supply, uint64 epoch, bool executable)
    {
        reserve = claimReserve;
        supply = ITreasuryCoin(ccToken).totalSupply();
        epoch = configEpoch;
        if (ccIn == 0 || ccIn > supply) return (0, reserve, supply, epoch, false);
        (bool ok, uint256 out) = _policyQuote(ccIn, reserve, supply);
        if (!ok || out == 0 || out > FixedPointMathLib.fullMulDiv(ccIn, reserve, supply)) {
            return (0, reserve, supply, epoch, false);
        }
        balanceOut = out;
        executable = ccRedemptionEnabled && selectedForClaims() && transfersReady() && solvent();
    }

    // ------------------------------------------------------------------ the Core's module calls

    /// the Core transfers custody first. approval is limited to this statement and consumed by the withdrawal. the receipt
    /// is measured; it must be at least the statement's rating times `unitPerPoint`. `conversionToClaimBps` of it is
    /// earmarked as claim backing and every token stays here, so the Core's receipt check reads the whole amount
    function redeem(uint256 statementId) external override onlyCore nonReentrant returns (uint256 out) {
        if (!conversionEnabled || !selected()) revert ConversionOff();
        IAuctionBalanceToken token = IAuctionBalanceToken(balanceToken);
        ITreasuryStatements statements = ITreasuryStatements(Mainnet.STATEMENTS);
        if (statements.ownerOf(statementId) != address(this)) revert NotHeld();
        uint256 required = statements.creditScoreOf(statementId) * unitPerPoint;
        uint256 expected = token.quote(statementId);
        statements.approve(balanceToken, statementId);
        uint256 before = custody();
        token.withdraw(statementId, expected);
        out = custody() - before;
        if (out < required) revert RedeemedBelowRating();
        uint16 bps = conversionToClaimBps;
        uint256 allocated = out * bps / BPS;
        if (allocated != 0) claimReserve += allocated;
        emit StatementConverted(statementId, out, allocated, bps, claimReserve);
    }

    /// pays at most `available()`, working funds only. transfers `amount` with all gas except `ACCRUE_RESERVE`, then
    /// records the shortfall (`amount` less the custody decrease) in `owed[to]` for `claim`. the token's return value is
    /// not read: a transfer that reverts, runs out of gas, returns false, returns no data or moves less than `amount`
    /// accrues exactly the undelivered part. the Core checks the seller's receipt itself and bounds the artist call
    function pay(address to, uint256 amount) external override onlyCore nonReentrant {
        if (amount > available()) revert InsufficientAvailable();
        uint256 before = custody();
        uint256 g = gasleft();
        if (g > ACCRUE_RESERVE) {
            (bool sent,) =
                balanceToken.call{gas: g - ACCRUE_RESERVE}(abi.encodeCall(IERC20Transfer.transfer, (to, amount)));
            sent;
        }
        uint256 afterBal = custody();
        uint256 delivered = before > afterBal ? before - afterBal : 0;
        if (delivered < amount) {
            uint256 short = amount - delivered;
            owed[to] += short;
            totalOwed += short;
            emit PaymentAccrued(to, short);
        }
    }

    /// pays `owed[to]` to `to` with all gas. anyone may call, whatever the switches, before and after migration
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = owed[to];
        owed[to] = 0;
        totalOwed -= amount;
        if (amount != 0) {
            SafeTransferLib.safeTransfer(balanceToken, to, amount);
            emit OwedClaimed(to, amount);
        }
    }

    // ------------------------------------------------------------------ CC redemption

    /// burns `ccIn` of the caller's CC and pays `recipient` the policy's quote, at most the proportional share of the
    /// claim reserve snapshotted before the burn. the burn, the ledger change and the payment are one transaction: a
    /// failed, short or unsupported burn or payment reverts everything, and no user debt is ever recorded. the caller
    /// has approved this treasury on the coin for `burnFrom`
    function redeemCC(
        uint256 ccIn,
        address recipient,
        uint256 minBalanceOut,
        uint256 deadline,
        uint64 expectedConfigEpoch
    ) external nonReentrant returns (uint256 balanceOut) {
        if (block.timestamp > deadline) revert Expired();
        if (expectedConfigEpoch != configEpoch) revert StaleEpoch();
        if (!ccRedemptionEnabled || !selectedForClaims() || !transfersReady()) revert RedemptionOff();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 supply = ITreasuryCoin(ccToken).totalSupply();
        if (ccIn == 0 || ccIn > supply) revert InvalidAmount();
        uint256 reserve = claimReserve;
        uint256 cap = FixedPointMathLib.fullMulDiv(ccIn, reserve, supply);
        (bool ok, uint256 out) = _policyQuote(ccIn, reserve, supply);
        if (!ok || out > cap) revert BadPolicy();
        if (out == 0) revert ZeroAmount();
        if (out < minBalanceOut) revert Slippage();
        uint256 before = custody();
        if (before < reserve + totalOwed) revert Insolvent();
        claimReserve = reserve - out;
        ITreasuryCoin(ccToken).burnFrom(msg.sender, ccIn);
        if (ITreasuryCoin(ccToken).totalSupply() != supply - ccIn) revert BurnMismatch();
        uint256 held = SafeTransferLib.balanceOf(balanceToken, recipient);
        SafeTransferLib.safeTransfer(balanceToken, recipient, out);
        if (SafeTransferLib.balanceOf(balanceToken, recipient) < held + out) revert ShortPayment();
        if (custody() + out != before) revert ShortPayment();
        balanceOut = out;
        emit CCRedeemed(msg.sender, recipient, ccIn, out, claimReserve, supply - ccIn, configEpoch);
    }

    /// the policy's answer under `POLICY_GAS` with a 32 byte copy. `ok` false on a revert or a short answer
    function _policyQuote(uint256 ccIn, uint256 reserve, uint256 supply) private view returns (bool ok, uint256 out) {
        bytes memory input = abi.encodeCall(IRedemptionPolicy.quote, (ccIn, reserve, supply, redemptionFeeBps));
        address policy = redemptionPolicy;
        assembly ("memory-safe") {
            ok := staticcall(POLICY_GAS, policy, add(input, 0x20), mload(input), 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            out := mload(0)
        }
    }

    // ------------------------------------------------------------------ owner

    /// turns the three movement paths on or off at once. nothing turns on after migration
    function setSwitches(bool conversion, bool workingPayments, bool ccRedemption) external onlyOwner {
        if (migrated && (conversion || workingPayments || ccRedemption)) revert Migrated();
        conversionEnabled = conversion;
        workingPaymentsEnabled = workingPayments;
        ccRedemptionEnabled = ccRedemption;
        emit SwitchesSet(conversion, workingPayments, ccRedemption);
    }

    /// 0 to 10,000. applies to later conversions only
    function setConversionToClaimBps(uint16 v) external onlyOwner {
        if (v > BPS) revert BadSetting("conversionToClaimBps");
        conversionToClaimBps = v;
        emit ConversionToClaimBpsSet(v);
    }

    /// 0 to 10,000. a burner's terms change, so the epoch advances
    function setRedemptionFeeBps(uint16 v) external onlyOwner {
        if (v > BPS) revert BadSetting("redemptionFeeBps");
        redemptionFeeBps = v;
        _bumpEpoch();
        emit RedemptionFeeSet(v, configEpoch);
    }

    /// any amount. lowers `available()` only
    function setMinimumWorkingBalance(uint256 v) external onlyOwner {
        minimumWorkingBalance = v;
        emit MinimumWorkingBalanceSet(v);
    }

    /// replaces the quote. the new policy must have code, answer the probe and never quote above the proportional
    /// share on a sample. CC redemption turns off; turning it on again is a separate owner call after readback
    function setRedemptionPolicy(address policy) external onlyOwner {
        _setPolicy(policy);
        ccRedemptionEnabled = false;
        emit SwitchesSet(conversionEnabled, workingPaymentsEnabled, false);
    }

    function _setPolicy(address policy) private {
        if (policy.code.length == 0) revert BadPolicy();
        (bool ok, bytes memory ret) =
            policy.staticcall{gas: POLICY_GAS}(abi.encodeCall(IRedemptionPolicy.isRedemptionPolicy, ()));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 1) revert BadPolicy();
        (ok, ret) = policy.staticcall{gas: POLICY_GAS}(abi.encodeCall(IRedemptionPolicy.quote, (1e18, 1e18, 4e18, 0)));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) > 0.25e18) revert BadPolicy();
        redemptionPolicy = policy;
        _bumpEpoch();
        emit RedemptionPolicySet(policy, configEpoch);
    }

    /// pulls `amount` of the balance token from the owner into the claim reserve, by measured receipt. refused while CC
    /// has no supply. the token refuses the pull before transfers open
    function fundClaims(uint256 amount) external onlyOwner nonReentrant returns (uint256 received) {
        if (ITreasuryCoin(ccToken).totalSupply() == 0) revert ZeroSupply();
        uint256 before = custody();
        SafeTransferLib.safeTransferFrom(balanceToken, msg.sender, address(this), amount);
        received = custody() - before;
        if (received == 0) revert ZeroAmount();
        claimReserve += received;
        emit ClaimsFunded(msg.sender, received, claimReserve);
    }

    /// reclassifies `amount` of free working funds as claim backing. no transfer
    function allocateToClaims(uint256 amount) external onlyOwner nonReentrant {
        if (ITreasuryCoin(ccToken).totalSupply() == 0) revert ZeroSupply();
        if (amount == 0 || amount > freeWorking()) revert InsufficientWorking();
        claimReserve += amount;
        emit ClaimsAllocated(amount, claimReserve);
    }

    /// returns `amount` of claim backing to working funds. only while CC redemption is off; the epoch advances so a
    /// burner's pinned terms cannot execute against the smaller reserve
    function returnClaimsToWorking(uint256 amount) external onlyOwner nonReentrant {
        if (ccRedemptionEnabled) revert RedemptionEnabled();
        if (amount == 0 || amount > claimReserve) revert InsufficientClaims();
        claimReserve -= amount;
        _bumpEpoch();
        emit ClaimsReturned(amount, claimReserve, configEpoch);
    }

    /// sends `amount` of free working funds to `to`. never the claim reserve, the recorded debt or the floor
    function withdrawWorking(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0 || amount > freeWorking()) revert InsufficientWorking();
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

    /// moves custody less the recorded debt to `successor` and imports the claim reserve there. every switch must be off
    /// on both sides; the successor must bind the same coin and token and either the same Core or, once this Core has
    /// retired, the Core's successor, name this treasury as its predecessor, not have migrated itself, and already be
    /// the selected module of its Core: a reserve never moves to a treasury the Core cannot or has not selected (a
    /// locked module selection would strand every CC claim), so the order is select the successor, migrate, enable it.
    /// the claim reserve must be fully funded to move. this treasury then refuses every switch forever; `claim` keeps
    /// paying the debt left behind, and later inflows leave through `withdrawWorking`
    function migrateTo(address successor) external onlyOwner nonReentrant returns (uint256 moved) {
        if (migrated) revert Migrated();
        if (conversionEnabled || workingPaymentsEnabled || ccRedemptionEnabled) revert SwitchesOn();
        if (successor == address(this) || successor.code.length == 0) revert InvalidSuccessor();
        IPhase2Successor next = IPhase2Successor(successor);
        address nextCore = next.core();
        bool sameCore = nextCore == core;
        if (!sameCore) {
            ITreasuryCore c = ITreasuryCore(core);
            address heir = c.successor();
            if (!c.retired() || heir == address(0) || nextCore != heir) revert InvalidSuccessor();
        }
        if (ITreasuryCore(nextCore).balanceModule() != successor) revert InvalidSuccessor();
        if (
            next.balanceToken() != balanceToken || next.ccToken() != ccToken || next.predecessor() != address(this)
                || next.migrated() || next.conversionEnabled() || next.workingPaymentsEnabled()
                || next.ccRedemptionEnabled()
        ) revert InvalidSuccessor();
        uint256 bal = custody();
        uint256 debt = totalOwed;
        moved = bal > debt ? bal - debt : 0;
        uint256 claims = claimReserve;
        if (claims > moved) revert Insolvent();
        claimReserve = 0;
        migrated = true;
        _bumpEpoch();
        if (moved != 0) SafeTransferLib.safeTransfer(balanceToken, successor, moved);
        next.receiveMigration(claims);
        emit TreasuryMigrated(successor, moved, claims, configEpoch);
    }

    /// the predecessor's side of `migrateTo`: records `claimAmount` as claim backing once custody covers it with the
    /// existing reserve and debt. the transfer has already landed, so the check is on actual custody
    function receiveMigration(uint256 claimAmount) external nonReentrant {
        if (predecessor == address(0) || msg.sender != predecessor) revert OnlyPredecessor();
        if (migrated) revert Migrated();
        if (custody() < claimReserve + totalOwed + claimAmount) revert Insolvent();
        claimReserve += claimAmount;
        _bumpEpoch();
        emit MigrationReceived(msg.sender, claimAmount, claimReserve, configEpoch);
    }

    function _bumpEpoch() private {
        unchecked {
            ++configEpoch;
        }
    }
}
