// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibTransient} from "solady/utils/LibTransient.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    Lane,
    IController,
    IExitModule,
    ICoin,
    ICoreViews,
    ICredits,
    IStatements,
    Stack,
    Settings,
    Mainnet,
    BUYBACK_GAS,
    BUYLISTING_GAS
} from "./interfaces/Interfaces.sol";
import {CoreLib} from "./lib/CoreLib.sol";
import {SettingsBounds} from "./lib/SettingsBounds.sol";
import {SettingsStore} from "./lib/SettingsStore.sol";
import {RateStore} from "./lib/RateStore.sol";

/// custody and every rule of the credits engine. the owner sets the controller, the exit module and the target list at
/// once, can set a successor that receives the assets on `migrate`, and can close each of the controller, the exit
/// module, the targets and the successor door with a one way lock (docs/ARCHITECTURE.md).
/// credits and statements sent to the core outside its doors are not tracked and stay in the core.
/// the pool's bounty recipient is the fee router, which flushes the fee eth here: `receive()` books eth from the fee
/// source (the router) into the pot.
contract Core is ICoreViews, IUnlockCallback, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibTransient for LibTransient.TBool;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyOwner();
    error OnlyPoolManager();
    error BadSender();
    error ZeroAddress();
    error ZeroId();
    error ZeroAmount();
    error Empty();
    error NotOwner();
    error NotHeld();
    error NotInPile(uint256 id);
    error NotReady();
    error BadFormat();
    error BadStatement();
    error BadCost();
    error BadModule();
    error BadSwap();
    error TargetNotAllowed();
    error ForbiddenTarget();
    error AlreadyOwned();
    error CallFailed();
    error Measuring();
    error NoCredit();
    error PotTooSmall();
    error AboveCeiling();
    error Slippage();
    error Underpaid();
    error NoExitModule();
    error ExitTokenChanged();
    error TooEarly();
    /// the door `what` ("controller", "exitModule" or "targets") was locked by the owner
    error Locked(bytes32 what);
    error OnlyController();
    error OnlyPendingOwner();
    /// a sale paid less than the hard floor of the statement
    error BelowFloor();
    error NothingToBuy();
    /// the buyback slice does not exceed the most the caller can be paid
    error SliceTooSmall();
    error NothingBought();
    error TooSoon();
    error BadRate();
    error BadStack();
    /// a setting is out of its bounds. `field` is its name
    error BadSetting(bytes32 field);
    /// `sellTo`: the statement is not an eth lane statement held by the core
    error NotForSale();
    /// a stack member that must be a contract has no code
    error NoCode(address who);
    /// `rescueNft`: the credit is in a pile
    error InPile();
    /// `rescueNft`: the statement is on the books of the core
    error Held();
    /// `rescueNft`: the core is not the holder of the token, or the token is not an ERC721
    error NotHolder();
    /// `migrate` with no successor set
    error NoSuccessor();
    /// `sellForEth`, `buyListing`, `sellForExitToken`, `adopt`, `compose` or `composeExit` after `migrate`
    error Retired();
    /// `setSuccessor` with the core or a contract the core works with
    error BadSuccessor(address who);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeesAdded(uint256 amount);
    event Skimmed(uint256 eth, uint256 exitToken);
    event CreditBought(uint256 indexed id, address indexed from, Lane lane, uint256 cost);
    event ListingBought(
        uint256 indexed id, address indexed target, address indexed caller, uint256 cost, uint256 paid, uint256 rate
    );
    event EthRateFill(uint256 spent, uint256 rate, uint256 pot);
    event ExitRateFill(uint256 rate, uint256 pot);
    event Composed(uint256 indexed sid, Lane lane, uint8 format, uint256 cost, address indexed caller);
    event SettingsSet(Settings settings);
    event RateSet(uint256 rate);
    event StatementExited(uint256 indexed sid, Lane lane, uint256 received);
    event Buyback(address indexed caller, uint256 amountIn, uint256 paid);
    event ExitBuyback(address indexed caller, uint256 slice, uint256 coinIn);
    /// the controller sold a statement: the buyer, the price paid and the part of it booked to the coin buyback (the
    /// rest went to the pot)
    event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback);
    event OwnershipTransferStarted(address indexed owner, address indexed pending);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ControllerLocked();
    event ExitModuleLocked();
    event TargetsLocked();
    event ControllerSet(address controller);
    event ExitModuleSet(address exitModule, address exitToken, uint256 unitPerCredit);
    event TargetAdded(address target);
    event TargetRemoved(address target);
    event CoinRescued(address indexed to, uint256 amount);
    event NftRescued(address indexed token, uint256 indexed id, address indexed to);
    event SuccessorSet(address successor);
    event SuccessorLocked();
    /// `adopt` put a credit the core held without a record into the eth pile at cost basis `cost`
    event CreditAdopted(uint256 indexed id, uint256 cost);
    /// `migrate` moved eth, exit token and credits to the successor
    event Migrated(address indexed successor, uint256 eth, uint256 exitTokens, uint256 credits);
    /// the first `migrate` set `retired`
    event EngineRetired(address indexed successor);
    /// `migrate` could not transfer `xPot` (`amount`) to the successor; the pot stays
    event ExitTokenMigrationSkipped(address indexed successor, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// the coin supply of the launch, which the exit auction opening price reads
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// the exit rate the state starts at, bps of one credit's exit value
    uint256 public constant XRATE_START = 6000;

    uint256 private constant BPS = 10_000;
    uint256 private constant PAGE = 80;
    uint256 private constant MAX_FORMAT = 7;
    uint256 private constant READ_GAS = 200_000;
    /// gas of the work after the end of `compose` and `composeExit` that the caller payment counts, with the
    /// transaction base cost
    uint256 private constant COMPOSE_OVERHEAD_GAS = 60_000;
    /// the most gas of a compose the caller payment counts. above the largest metered compose, 11.1 million with a loaded
    /// fee router of four gas burning payees, so a gas burning controller or router cannot inflate the payment
    uint256 private constant COMPOSE_GAS = 13_700_000;
    /// gas of the work after the end of `exitStatement` that the caller payment counts, with the transaction base cost
    uint256 private constant EXIT_OVERHEAD_GAS = 50_000;
    /// the most gas of an exit the caller payment counts, so a gas burning module cannot inflate it
    uint256 private constant EXIT_GAS = 1_500_000;
    /// gas of the work after the end of `buyback` that its refund counts, with the transaction base cost
    uint256 private constant BUYBACK_OVERHEAD_GAS = 60_000;
    /// gas of the work after the count in `buyListing` (the spend, the pile record, the event and the payment, about
    /// 200,000), the transaction base cost and typical calldata
    uint256 private constant BUYLISTING_OVERHEAD_GAS = 250_000;
    /// gas the controller's `nextPage` may use, in both lanes. a full page of ControllerV1 costs 238,062 gas on a cold
    /// read (test/GasCap.t.sol `test_gas_readCaps_nextPage`)
    uint256 private constant PAGE_GAS = 500_000;
    address private constant DEAD = Mainnet.DEAD;
    bytes32 private constant MEASURING_SLOT = keccak256("core.measuring");

    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    address public immutable COIN;
    /// opening bid, wei per credit, fixed at deploy
    uint256 public immutable RATE_START;
    /// the artcoins v2 stack this core launched on, fixed at deploy. FEE_SOURCE (the fee router) is the only sender whose
    /// eth is booked as fees
    IPoolManager public immutable MANAGER;
    address public immutable HOOK;
    address public immutable FEE_SOURCE;
    int24 public immutable TICK_SPACING;
    uint24 public immutable POOL_FEE;
    address public immutable FACTORY;
    address public immutable LOCKER;
    address public immutable ESCROW;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public controller;
    /// one way locks of the owner (docs/ARCHITECTURE.md): once set, the door never opens again
    bool public controllerLocked;
    bool public exitModuleLocked;
    bool public targetsLocked;
    address public exitModule;
    address public exitToken;
    mapping(address => bool) public allowedTarget;
    /// the owner and the pending owner of the two step handover
    address public owner;
    address public pendingOwner;

    uint256 public ethPot;
    uint256 public ethToBuyback;
    uint256 public xPot;
    uint256 public xToBuyback;

    uint256 public rateAtCheckpoint;
    uint64 public checkpointTime;
    uint64 public lastFillTime;

    uint256 xRateAtCheckpoint;
    uint64 xCheckpointTime;
    bool xFunded;

    uint256 public lastBuybackBlock;

    mapping(Lane => CoreLib.Pile) private _piles;
    mapping(uint256 => CoreLib.Credit) private _credits;
    mapping(uint256 => CoreLib.Statement) private _statements;
    uint256[] private _heldIds;

    /// exit token base units per credit, read from the module when it is set
    uint256 public unitPerCredit;
    /// exit token auction: price in coin wei per exit token unit, wad scaled, at `xStartTime`. it halves every
    /// `xAuctionHalfLife`. the clock only runs while `xToBuyback` is not zero
    uint256 public xStartPrice;
    uint64 public xStartTime;

    /// the contract `migrate` sends the assets to, and whether `setSuccessor` is closed
    address public successor;
    bool public successorLocked;
    /// set by the first `migrate`, one way. a retired core refuses `sellForEth`, `buyListing`, `sellForExitToken`,
    /// `adopt`, `compose` and `composeExit` with `Retired`
    bool public retired;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert OnlyOwner();
    }

    constructor(
        address owner_,
        address coin_,
        address controller_,
        Stack memory stack_,
        uint256 rateStart_,
        Settings memory settings_
    ) {
        if (owner_ == address(0) || coin_ == address(0) || controller_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            stack_.poolManager == address(0) || stack_.hook == address(0) || stack_.factory == address(0)
                || stack_.locker == address(0) || stack_.escrow == address(0) || stack_.feeSource == address(0)
        ) revert ZeroAddress();
        if (stack_.tickSpacing <= 0 || stack_.tickSpacing > 32_767) revert BadStack();
        // the stack members must be contracts. the coin is not deployed yet when the core is created
        if (stack_.poolManager.code.length == 0) revert NoCode(stack_.poolManager);
        if (stack_.hook.code.length == 0) revert NoCode(stack_.hook);
        if (stack_.feeSource.code.length == 0) revert NoCode(stack_.feeSource);
        if (stack_.factory.code.length == 0) revert NoCode(stack_.factory);
        if (stack_.locker.code.length == 0) revert NoCode(stack_.locker);
        if (stack_.escrow.code.length == 0) revert NoCode(stack_.escrow);
        if (!SettingsBounds.rateInBounds(rateStart_) || rateStart_ > settings_.rateCap) revert BadRate();
        owner = owner_;
        COIN = coin_;
        RATE_START = rateStart_;
        MANAGER = IPoolManager(stack_.poolManager);
        HOOK = stack_.hook;
        FEE_SOURCE = stack_.feeSource;
        TICK_SPACING = stack_.tickSpacing;
        POOL_FEE = stack_.poolFee;
        FACTORY = stack_.factory;
        LOCKER = stack_.locker;
        ESCROW = stack_.escrow;
        controller = controller_;
        allowedTarget[Mainnet.SEAPORT] = true;
        allowedTarget[Mainnet.CREDIT_STRATEGY] = true;
        rateAtCheckpoint = rateStart_;
        checkpointTime = uint64(block.timestamp);
        lastFillTime = uint64(block.timestamp);
        RateStore.load().lastFillRate = rateStart_;
        xRateAtCheckpoint = uint256(XRATE_START).min(settings_.xRateCap).max(settings_.xRateFloor);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        emit OwnershipTransferred(address(0), owner_);
        emit ControllerSet(controller_);
        emit TargetAdded(Mainnet.SEAPORT);
        emit TargetAdded(Mainnet.CREDIT_STRATEGY);
        // validates, stores at the settings slot and logs, by delegatecall into the library
        CoreLib.setSettings(settings_);
    }

    /// accepts eth from anyone but the fee source and leaves it unbooked (`skim` books it). eth from the fee source (the
    /// router flushing the pool's fee eth) is booked: `feeToBuybackBps` of it to the coin buyback, the rest to the pot.
    /// while a measurement is in flight the fee source REVERTS: a router flush started inside a measured call (by
    /// the seller's callback, say) then fails as a whole and the fees wait in the router. every other sender is
    /// accepted unbooked, so a refund or a sale payout can never fail a call
    receive() external payable {
        if (msg.sender != FEE_SOURCE) return;
        if (_measuring().get()) revert Measuring();
        _checkpoint();
        uint256 toBuyback = msg.value * _st().feeToBuybackBps / BPS;
        if (toBuyback != 0) ethToBuyback += toBuyback;
        ethPot += msg.value - toBuyback;
        emit FeesAdded(msg.value);
    }

    /// accepts statements and credits from their own contracts only.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(STATEMENTS) && msg.sender != address(CREDITS)) revert BadSender();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE INTAKE
    //////////////////////////////////////////////////////////////*/

    /// books any eth or exit token held above the recorded pots into the buying pots. anyone may call.
    function skim() external nonReentrant {
        uint256 eth = address(this).balance.zeroFloorSub(ethPot + ethToBuyback);
        if (eth != 0) {
            _checkpoint();
            ethPot += eth;
        }
        uint256 x;
        address token = exitToken;
        if (token != address(0)) {
            x = SafeTransferLib.balanceOf(token, address(this)).zeroFloorSub(xPot + xToBuyback);
            if (x != 0) {
                _xCheckpoint();
                xPot += x;
                _syncXFunded();
            }
        }
        emit Skimmed(eth, x);
    }

    /*//////////////////////////////////////////////////////////////
                               ETH RATE
    //////////////////////////////////////////////////////////////*/

    /// wei per credit right now: the price state (`rateAtCheckpoint` climbed lazily, bounded by the ceiling and
    /// `rateCap`) lowered to `ethPot`, the price of one credit that the pot affords. the clamp follows the current pot
    /// and is not stored. the math is in `CoreLib.climb`
    function ethRate() public view returns (uint256 read) {
        (, read) = _climb();
    }

    function _climb() private view returns (uint256, uint256) {
        return CoreLib.climb(rateAtCheckpoint, ethPot, lastFillTime, checkpointTime, block.timestamp);
    }

    /// wei per credit of the price state now: `rateAtCheckpoint` climbed lazily and bounded by the ceiling and
    /// `rateCap`, before the clamp that `ethRate` applies. the climb also stops at the pot, so with an empty pot the
    /// price state does not climb. the cost basis of an adopted credit is this price
    function ethPrice() external view returns (uint256 price) {
        (price,) = _climb();
    }

    function _checkpoint() private {
        (rateAtCheckpoint,) = _climb();
        checkpointTime = uint64(block.timestamp);
    }

    /// checkpoints, then books a spend of x from the pot: rate drop, fill time.
    function _spend(uint256 x) private {
        _checkpoint();
        uint256 p = ethPot;
        if (x == 0) revert ZeroAmount();
        if (x > p) revert PotTooSmall();
        uint256 r = CoreLib.drop(rateAtCheckpoint, block.timestamp);
        rateAtCheckpoint = r;
        lastFillTime = uint64(block.timestamp);
        ethPot = p - x;
        emit EthRateFill(x, r, p - x);
    }

    /*//////////////////////////////////////////////////////////////
                              EXIT RATE
    //////////////////////////////////////////////////////////////*/

    /// exit token bid in bps of one credit's exit value right now.
    function xRate() public view returns (uint256 r) {
        return CoreLib.xRateOf(xRateAtCheckpoint, xFunded, xPot, unitPerCredit, xCheckpointTime, _st());
    }

    function _xCheckpoint() private {
        xRateAtCheckpoint = xRate();
        xCheckpointTime = uint64(block.timestamp);
    }

    function _syncXFunded() private {
        xFunded = CoreLib.xFundedOf(xPot, xRateAtCheckpoint, unitPerCredit);
    }

    /*//////////////////////////////////////////////////////////////
                           CONTROLLER READS
    //////////////////////////////////////////////////////////////*/

    /// the settings, four packed slots at a fixed location shared with the library
    function _st() private pure returns (Settings storage) {
        return SettingsStore.load();
    }

    /// bounded read of a module. any failure or short answer returns false and a long answer is cut off
    function _ask(address module, bytes memory input, uint256 gasCap, uint256 outLen)
        private
        view
        returns (bool ok, bytes memory out)
    {
        out = new bytes(outLen);
        assembly ("memory-safe") {
            ok := staticcall(gasCap, module, add(input, 0x20), mload(input), add(out, 0x20), outLen)
            ok := and(ok, iszero(lt(returndatasize(), outLen)))
        }
    }

    function _nextPage(Lane lane) private view returns (bool ready, uint256[80] memory ids, uint256 format) {
        (bool ok, bytes memory out) =
            _ask(controller, abi.encodeCall(IController.nextPage, (lane)), PAGE_GAS, (PAGE + 2) * 32);
        if (!ok) return (false, ids, 0);
        uint256 flag;
        (flag, ids, format) = abi.decode(out, (uint256, uint256[80], uint256));
        ready = flag == 1;
    }

    /*//////////////////////////////////////////////////////////////
                                PILES
    //////////////////////////////////////////////////////////////*/

    function _push(Lane lane, uint256 id, uint256 cost) private {
        CoreLib.push(_piles[lane], _credits, lane, id, cost);
    }

    function _pull(Lane lane, uint256 id) private returns (uint256 cost) {
        CoreLib.Credit storage c = _credits[id];
        if (!c.inPile || c.lane != lane) revert NotInPile(id);
        CoreLib.Pile storage p = _piles[lane];
        uint256 prev = c.prev;
        uint256 next = c.next;
        if (prev == 0) p.head = next;
        else _credits[prev].next = next;
        if (next == 0) p.tail = prev;
        else _credits[next].prev = prev;
        p.size -= 1;
        cost = c.cost;
        delete _credits[id];
    }

    /// the first action of `sellForEth`, `buyListing`, `adopt`, `compose` and `composeExit`. two steps in order:
    /// 1. reverts `Retired` once `migrate` has run. `sellForExitToken` checks the same flag in `CoreLib`.
    /// 2. pulls the fee router: the router flushes its balance into `receive`, which books it, before the entry point
    /// reads a rate, checkpoints or measures. a failing router does not fail the entry point (docs/FLOW.md 10.8)
    function _openDoor() private {
        if (retired) revert Retired();
        CoreLib.pullFees(FEE_SOURCE);
    }

    /*//////////////////////////////////////////////////////////////
                                 DOORS
    //////////////////////////////////////////////////////////////*/

    /// sell credits into the eth bid at the current rate. caller must have approved the core. reverts `Retired` after
    /// `migrate`
    function sellForEth(uint256[] calldata ids) external nonReentrant {
        _sellForEth(ids, 0);
    }

    /// same as sellForEth with a floor on the total paid, for protection against a rate drop in the same block.
    function sellForEth(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _sellForEth(ids, minOut);
    }

    function _sellForEth(uint256[] calldata ids, uint256 minOut) private {
        _openDoor();
        if (ids.length == 0) revert Empty();
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = _owned(ids[i]);
            uint256 price = ethRate();
            _spend(price);
            _push(Lane.Eth, id, price);
            CREDITS.transferFrom(msg.sender, address(this), id);
            total += price;
            emit CreditBought(id, msg.sender, Lane.Eth, price);
        }
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransferETH(msg.sender, total);
    }

    /// buy credit id through an allowed target. the caller supplies the complete calldata and is paid from `ethPot`: the
    /// gas of the call at the base fee, capped at `keeperMaxBaseFee` and `BUYLISTING_GAS`, plus `keeperFee`. the payment
    /// is at most the bid less the listing cost, so the pot pays at most the bid for the credit. the gas counted
    /// includes the fee router flush. reverts `Retired` after `migrate`
    function buyListing(uint256 value, bytes calldata data, uint256 id, address target) external nonReentrant {
        uint256 gasStart = gasleft();
        _openDoor();
        if (!allowedTarget[target] || _forbidden(target)) revert TargetNotAllowed();
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) == address(this)) revert AlreadyOwned();
        _checkpoint();
        uint256 ceiling = ethRate();
        if (value > ethPot) revert PotTooSmall();
        if (value > ceiling) revert AboveCeiling();

        uint256 ethBefore = address(this).balance;
        uint256 creditsBefore = CREDITS.balanceOf(address(this));
        _measuring().set(true);
        (bool ok,) = target.call{value: value}(data);
        _measuring().set(false);
        if (!ok) revert CallFailed();
        if (CREDITS.balanceOf(address(this)) != creditsBefore + 1 || CREDITS.ownerOf(id) != address(this)) {
            revert NoCredit();
        }
        uint256 ethAfter = address(this).balance;
        if (ethAfter >= ethBefore) revert BadCost();
        uint256 cost = ethBefore - ethAfter;
        if (cost > value) revert BadCost();

        // the bid is at most `ethPot` (the read is lowered to the pot) and cost is at most `value`, at most the bid
        Settings storage s = _st();
        uint256 paid = _payment(gasStart, BUYLISTING_OVERHEAD_GAS, BUYLISTING_GAS, s.keeperMaxBaseFee, s.keeperFee)
            .min(ceiling - cost);
        _spend(cost + paid);
        _push(Lane.Eth, id, cost + paid);
        emit ListingBought(id, target, msg.sender, cost, paid, rateAtCheckpoint);
        if (paid != 0) SafeTransferLib.safeTransferETH(msg.sender, paid);
    }

    /// sell credits into the exit token bid. phase 2 only. reverts `Retired` after `migrate`. the body is
    /// `CoreLib.sellForExitToken`, called with the calldata untouched
    function sellForExitToken(uint256[] calldata ids) external nonReentrant {
        _toLib();
    }

    /// same as sellForExitToken with a floor on the total paid.
    function sellForExitToken(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _toLib();
    }

    /// checks that the caller owns credit id, which must not be the zero sentinel.
    function _owned(uint256 id) private view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    function _forbidden(address t) private view returns (bool) {
        return _forbiddenBase(t) || t == exitModule || t == exitToken;
    }

    /// every forbidden target except the exitModule and the exitToken, which a later set may name again
    function _forbiddenBase(address t) private view returns (bool) {
        return t == address(CREDITS) || t == address(STATEMENTS) || t == address(this) || t == COIN || t == HOOK
            || t == address(MANAGER) || t == FACTORY || t == LOCKER || t == ESCROW || t == FEE_SOURCE
            || t == Mainnet.PERMIT2 || t == Mainnet.POSITION_MANAGER
            || t == Mainnet.UNIVERSAL_ROUTER;
    }

    function _measuring() private pure returns (LibTransient.TBool storage) {
        return LibTransient.tBool(MEASURING_SLOT);
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOSING
    //////////////////////////////////////////////////////////////*/

    /// composes the controller's page of eth lane credits into a statement the core holds for sale. anyone may call. the
    /// gas counted for the caller payment includes the fee router flush. reverts `Retired` after `migrate`
    function compose() external nonReentrant {
        _compose();
    }

    /// composes the controller's page of exit lane credits into a statement. anyone may call. the gas counted for the
    /// caller payment includes the fee router flush. reverts `Retired` after `migrate`
    function composeExit() external nonReentrant {
        _compose();
    }

    /// one body for both lanes, told apart by the selector of the call, so the code is not duplicated
    function _compose() private {
        uint256 gasStart = gasleft();
        _openDoor();
        Lane lane = msg.sig == this.composeExit.selector ? Lane.Exit : Lane.Eth;
        (bool ready, uint256[80] memory ids, uint256 format) = _nextPage(lane);
        if (!ready) revert NotReady();
        if (format > MAX_FORMAT) revert BadFormat();
        uint256 cost;
        for (uint256 i; i < PAGE; ++i) {
            uint256 id = ids[i];
            cost += _pull(lane, id);
            if (CREDITS.ownerOf(id) != address(this)) revert NotHeld();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 sid = STATEMENTS.compose(ids, uint8(format));
        if (sid != STATEMENTS.supply() || STATEMENTS.ownerOf(sid) != address(this) || STATEMENTS.creditsOf(sid) != PAGE)
        {
            revert BadStatement();
        }

        _heldIds.push(sid);
        _statements[sid] = CoreLib.Statement({
            cost: cost,
            composedAt: uint64(block.timestamp),
            slot: uint64(_heldIds.length - 1),
            lane: lane,
            held: true
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Composed(sid, lane, uint8(format), cost, msg.sender);
        _payCaller(gasStart, COMPOSE_OVERHEAD_GAS, COMPOSE_GAS);
    }

    /// the payment to the caller of a paying door: the gas counted from `gasStart` plus `overhead`, at most `gasCap`,
    /// at the base fee capped at `maxBaseFee`, plus `fee`
    function _payment(uint256 gasStart, uint256 overhead, uint256 gasCap, uint256 maxBaseFee, uint256 fee)
        private
        view
        returns (uint256)
    {
        return (gasStart - gasleft() + overhead).min(gasCap) * block.basefee.min(maxBaseFee) + fee;
    }

    /// pays the caller of `compose`, `composeExit` and `exitStatement` from `ethPot`, at most the pot, by the
    /// `callerFee` and `callerMaxBaseFee` settings. the last action of the door, after all state is final
    function _payCaller(uint256 gasStart, uint256 overhead, uint256 gasCap) private {
        Settings storage s = _st();
        uint256 pay = _payment(gasStart, overhead, gasCap, s.callerMaxBaseFee, s.callerFee).min(ethPot);
        if (pay == 0) return;
        _checkpoint();
        ethPot -= pay;
        SafeTransferLib.safeTransferETH(msg.sender, pay);
    }

    /// forgets a held statement and compacts the held list.
    function _unhold(uint256 sid) private {
        CoreLib.Statement storage s = _statements[sid];
        uint256 slot = s.slot;
        uint256 last = _heldIds[_heldIds.length - 1];
        _heldIds[slot] = last;
        // forge-lint: disable-next-line(unsafe-typecast)
        _statements[last].slot = uint64(slot);
        _heldIds.pop();
        delete _statements[sid];
    }

    /*//////////////////////////////////////////////////////////////
                                 SALE
    //////////////////////////////////////////////////////////////*/

    /// the controller sells a held eth lane statement to `buyer` for `msg.value`, at least `saleFloorBps` of the
    /// statement cost. `saleToBuybackBps` of the payment goes to the coin buyback and the rest to the pot. the
    /// controller refunds its own caller
    function sellTo(uint256 sid, address buyer) external payable nonReentrant {
        if (msg.sender != controller) revert OnlyController();
        CoreLib.Statement storage st = _statements[sid];
        if (!st.held || st.lane != Lane.Eth) revert NotForSale();
        if (msg.value < st.cost * _st().saleFloorBps / BPS) revert BelowFloor();
        _unhold(sid);
        STATEMENTS.transferFrom(address(this), buyer, sid);
        uint256 toBuyback = msg.value * _st().saleToBuybackBps / BPS;
        ethToBuyback += toBuyback;
        _checkpoint();
        ethPot += msg.value - toBuyback;
        emit StatementSoldTo(sid, buyer, msg.value, toBuyback);
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT
    //////////////////////////////////////////////////////////////*/

    /// hands a held statement to the exit module. an eth lane statement must have been held for `exitAfter` since its
    /// compose. an exit lane statement goes at once.
    function exitStatement(uint256 sid) external nonReentrant {
        uint256 gasStart = gasleft();
        address module = exitModule;
        if (module == address(0)) revert NoExitModule();
        CoreLib.Statement memory s = _statements[sid];
        if (!s.held) revert NotHeld();
        if (s.lane == Lane.Eth && block.timestamp < s.composedAt + _st().exitAfter) revert TooEarly();
        address token = exitToken;
        uint256 required = STATEMENTS.creditsOf(sid) * unitPerCredit;
        _unhold(sid);

        uint256 balanceBefore = SafeTransferLib.balanceOf(token, address(this));
        _measuring().set(true);
        STATEMENTS.transferFrom(address(this), module, sid);
        IExitModule(module).exit(sid);
        _measuring().set(false);
        uint256 balanceAfter = SafeTransferLib.balanceOf(token, address(this));
        if (balanceAfter < balanceBefore + required) revert Underpaid();
        uint256 received = balanceAfter - balanceBefore;

        uint256 toBuyback = received * (s.lane == Lane.Eth ? _st().exitToBuybackBps : _st().exitLaneToBuybackBps) / BPS;
        _xCheckpoint();
        if (toBuyback != 0) {
            // new funds never inherit a decayed clock: the curve re anchors at the price now, floored at a quarter
            // of the start, and the clock restarts. with an empty pot the price now is the stored start price
            xStartPrice = exitAuctionPrice().max(xStartPrice / 4).max(1);
            xStartTime = uint64(block.timestamp);
        }
        xToBuyback += toBuyback;
        xPot += received - toBuyback;
        _syncXFunded();
        emit StatementExited(sid, s.lane, received);
        _payCaller(gasStart, EXIT_OVERHEAD_GAS, EXIT_GAS);
    }

    /*//////////////////////////////////////////////////////////////
                               BUYBACKS
    //////////////////////////////////////////////////////////////*/

    /// swaps up to one slice of the eth buyback pot for coin in the canonical pool, then burns the coin on the token
    /// so the total supply falls. the caller is paid from the slice: the gas of the call at the base fee, capped at
    /// `keeperMaxBaseFee` and `BUYBACK_GAS`, plus `keeperFee` scaled by `spent` over the largest swap budget the
    /// `buybackSlice` setting allows. the largest payment is `BUYBACK_GAS * rate + keeperFee`, the swap budget is the
    /// slice less that payment, and a slice under twice that payment reverts, so the payment is at most half the slice.
    /// the core's own bounty share of the hook's skim on this swap reaches the pot through the router (`flush`), and a
    /// partial fill refund through the escrow (`skim`, after anyone claims it).
    function buyback() external nonReentrant {
        uint256 gasStart = gasleft();
        uint256 pool = ethToBuyback;
        if (pool == 0) revert NothingToBuy();
        Settings storage s = _st();
        if (block.number < lastBuybackBlock + s.buybackDelay) revert TooSoon();
        uint256 setSlice = s.buybackSlice;
        uint256 slice = pool.min(setSlice);
        uint256 rate = block.basefee.min(s.keeperMaxBaseFee);
        uint256 fee = s.keeperFee;
        uint256 maxPay = BUYBACK_GAS * rate + fee;
        if (slice < 2 * maxPay) revert SliceTooSmall();
        uint256 budget = slice - maxPay;
        ethToBuyback = pool - slice;
        lastBuybackBlock = block.number;
        (uint256 spent, uint256 bought) = abi.decode(MANAGER.unlock(abi.encode(budget)), (uint256, uint256));
        if (bought == 0) revert NothingBought();
        ICoin(COIN).burn(bought);
        // spent is at most budget, which is at most setSlice - maxPay, so the scaled fee is at most the fee
        uint256 paid = _payment(
            gasStart, BUYBACK_OVERHEAD_GAS, BUYBACK_GAS, s.keeperMaxBaseFee, fee.min(fee * spent / (setSlice - maxPay))
        );
        ethToBuyback += slice - spent - paid;
        emit Buyback(msg.sender, spent, paid);
        if (paid != 0) SafeTransferLib.safeTransferETH(msg.sender, paid);
    }

    /// pool manager callback of `buyback`. swaps exact eth in for coin, which comes to the core. returns the eth
    /// spent, skim included, and the coin bought. the take of the coin from the pool manager passes the restriction of the
    /// coin through the transfer allowance the hook grants for the swap.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert OnlyPoolManager();
        (uint256 owed, uint256 bought) =
            CoreLib.swapIn(address(MANAGER), COIN, POOL_FEE, TICK_SPACING, HOOK, abi.decode(data, (uint256)));
        return abi.encode(owed, bought);
    }

    /// sells one slice of the exit token buyback pot for coin at the dutch auction price and burns the coin it
    /// takes from the caller. the caller must have approved the core for it. phase 2 only.
    function buybackExit(uint256 maxCoinIn) external nonReentrant {
        address token = exitToken;
        if (token == address(0)) revert NoExitModule();
        (uint256 slice, uint256 coinIn, uint256 price) = _exitQuote();
        if (slice == 0) revert NothingToBuy();
        if (coinIn > maxCoinIn) revert Slippage();
        xToBuyback -= slice;
        // never below a quarter of the start just played, never zero
        xStartPrice = (2 * price).max(xStartPrice / 4).max(1);
        xStartTime = uint64(block.timestamp);
        if (coinIn != 0) ICoin(COIN).burnFrom(msg.sender, coinIn);
        SafeTransferLib.safeTransfer(token, msg.sender, slice);
        emit ExitBuyback(msg.sender, slice, coinIn);
    }

    /// the exit token auction price now, coin wei per exit token unit in wad. it halves every 6 hours from the start
    /// price and may reach zero. while nothing is for sale the clock is stopped and this is the start price.
    function exitAuctionPrice() public view returns (uint256) {
        if (xToBuyback == 0) return xStartPrice;
        return CoreLib.decay(xStartPrice, block.timestamp - xStartTime, _st().xAuctionHalfLife);
    }

    /// the exit token slice a fill would take now and the coin it would burn.
    function exitAuctionQuote() external view returns (uint256 slice, uint256 coinIn) {
        (slice, coinIn,) = _exitQuote();
    }

    /// exit token of one full exit buyback slice: `exitSliceCredits` credits
    function _fullSlice(uint256 unit) private view returns (uint256) {
        return uint256(_st().exitSliceCredits) * unit;
    }

    function _exitQuote() private view returns (uint256 slice, uint256 coinIn, uint256 price) {
        slice = xToBuyback.min(_fullSlice(unitPerCredit));
        price = exitAuctionPrice();
        coinIn = slice.mulDivUp(price, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/

    /// starts the handover of the owner role: `to` becomes the owner when it calls `acceptOwnership`. the zero address
    /// clears a pending handover. there is no renounce
    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(msg.sender, to);
    }

    /// completes the handover, called by the pending owner. the zero caller never passes
    function acceptOwnership() external {
        if (msg.sender == address(0) || msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    /// sets the controller at once. never zero. reverts after `lockController`
    function setController(address c) external onlyOwner {
        if (controllerLocked) revert Locked("controller");
        if (c == address(0)) revert ZeroAddress();
        controller = c;
        emit ControllerSet(c);
    }

    /// sets or replaces the exit module at once (any number of times until `lockExitModule`)
    function setExitModule(address module) external onlyOwner nonReentrant {
        if (exitModuleLocked) revert Locked("exitModule");
        _setExitModule(module);
    }

    /// allows a target of `buyListing` at once. forbidden targets are refused. reverts after `lockTargets`
    function addTarget(address t) external onlyOwner {
        if (targetsLocked) revert Locked("targets");
        if (_forbidden(t)) revert ForbiddenTarget();
        allowedTarget[t] = true;
        emit TargetAdded(t);
    }

    /// the one way locks. each is irreversible. the settings and the controller's own sale settings stay open
    function lockController() external onlyOwner {
        controllerLocked = true;
        emit ControllerLocked();
    }

    /// reverts while no exit module is set, so phase 2 cannot be locked out by accident
    function lockExitModule() external onlyOwner {
        if (exitModule == address(0)) revert NoExitModule();
        exitModuleLocked = true;
        emit ExitModuleLocked();
    }

    /// after this no target can be added. removing one still works
    function lockTargets() external onlyOwner {
        targetsLocked = true;
        emit TargetsLocked();
    }

    /// sends coin the core holds to `to`. the core holds coin only in passing (the buyback burns what it buys in the same
    /// call), so this reaches only coin that an allowlisted holder sent to it, which the restriction of the coin permits.
    /// coin only: never eth, credits, statements or the exit token. owner only and guarded, both checked by the library,
    /// to which the call is handed untouched (the bytes saved keep the runtime under the size limit). it refuses the
    /// zero address, sends and logs `CoinRescued`
    function rescueCoin(address, uint256) external {
        _toLib();
    }

    /// sends an ERC721 token the core holds to `to` with `transferFrom`: a credit only while it is not in a pile, a
    /// statement only while the core has no record of it, any other ERC721 freely. owner only and guarded, both checked
    /// by the library, to which the call is handed untouched. a token whose `ownerOf(id)` does not answer with the
    /// core is refused. logs `NftRescued`
    function rescueNft(address, uint256, address) external {
        _toLib();
    }

    /// sets the successor that `migrate` sends the assets to. the zero address means no migration. it must have code.
    /// reverts `Locked("successor")` after `lockSuccessor`, and `BadSuccessor` for the core, the exit module, the exit
    /// token, the fee source, the coin, Credits and Statements. owner only, checked by the library, to which
    /// the call is handed untouched. logs `SuccessorSet`
    function setSuccessor(address) external {
        _toLib();
    }

    /// closes `setSuccessor`, one way. allowed while the successor is zero, which disables `migrate`.
    /// logs `SuccessorLocked`
    function lockSuccessor() external {
        _toLib();
    }

    /// moves `ethPot`, `xPot` and up to `maxCredits` credits from the head of each pile to the successor,
    /// in batches. callable again until nothing is left. `ethToBuyback` stays for the coin buyback and `xToBuyback`
    /// for the exit token burn auction (`buybackExit`). the held
    /// statements and their records stay with the core. an exit token transfer that fails leaves `xPot` and logs `ExitTokenMigrationSkipped`, the
    /// eth and credit legs go on. the first call sets `retired` and logs `EngineRetired`. owner only and guarded, both checked by the
    /// library, to which the call is handed untouched. reverts `NoSuccessor` while the successor is zero
    function migrate(uint256) external {
        _toLib();
    }

    /// delegatecalls the library with the calldata of this call, under the selector of this call, and reverts with
    /// whatever it reverts with
    function _toLib() private {
        address lib = address(CoreLib);
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            if iszero(delegatecall(gas(), lib, p, calldatasize(), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

    /// puts credits the core holds without a record into the eth pile, anyone may call. the fee router is pulled first,
    /// like at every door that reads the pot, so pending fee eth is booked before the price is read. the cost basis of
    /// each credit is the price state per credit (`ethPrice`), at least 1 wei. the price
    /// state is the figure the engine pays with a funded pot, so a statement built from adopted credits is priced at
    /// that level; the clamp of a thin pot would book a basis of 1 wei. the basis is booked and the eth pile grows: eth,
    /// the rate state and the pots keep their values. a donor who inflates the basis of a statement
    /// gives credits away. reverts `Retired` after `migrate`, `InPile`, `NotHolder`, `ZeroId` and `Empty`. logs
    /// `CreditAdopted`. the body is `CoreLib.adopt`, called with the calldata untouched
    function adopt(uint256[] calldata) external nonReentrant {
        _openDoor();
        _toLib();
    }

    /// removes an allowed target at once.
    function removeTarget(address target) external onlyOwner {
        allowedTarget[target] = false;
        emit TargetRemoved(target);
    }

    /// sets every economic setting at once, effective now. the eth rate and the exit rate are checkpointed first, so no
    /// climb is credited under the wrong numbers, then the call is handed to the library untouched: it checks every
    /// field against its bounds, stores them and logs them. the exit funded flag is recomputed after, the exit rate is
    /// held inside the new band, and the exit auction is re anchored at its price now when its half life changes
    function setSettings(Settings calldata) external onlyOwner nonReentrant {
        _checkpoint();
        _xCheckpoint();
        Settings storage s = _st();
        bool module = exitModule != address(0);
        bool anchor = module && xToBuyback != 0;
        uint256 half = s.xAuctionHalfLife;
        uint256 price = anchor ? exitAuctionPrice() : 0;
        address lib = address(CoreLib);
        bytes4 sel = CoreLib.setSettings.selector;
        assembly ("memory-safe") {
            // the same arguments under the library's selector (a library names a struct in its signature), built above
            // the free memory pointer
            let p := mload(0x40)
            mstore(p, sel)
            calldatacopy(add(p, 4), 4, sub(calldatasize(), 4))
            if iszero(delegatecall(gas(), lib, p, calldatasize(), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        if (anchor && s.xAuctionHalfLife != half) {
            xStartPrice = price.max(1);
            xStartTime = uint64(block.timestamp);
        }
        xRateAtCheckpoint = xRateAtCheckpoint.min(s.xRateCap).max(s.xRateFloor);
        if (module) _syncXFunded();
    }

    /// restates the eth rate (wei per credit) as `rate`, within the rate bounds. the stored rate and the ceiling
    /// anchor are both `rate`, the fill clock is unchanged. the clamp and the ceiling still bound the rate on read
    function setRate(uint256 rate) external onlyOwner nonReentrant {
        if (!SettingsBounds.rateInBounds(rate) || rate > _st().rateCap) revert BadRate();
        RateStore.load().lastFillRate = rate;
        rateAtCheckpoint = rate;
        checkpointTime = uint64(block.timestamp);
        emit RateSet(rate);
    }

    /// sets or replaces the exit module. the exit token never changes once set.
    /// the unit is read again every time, so naming the same module again is how the unit is updated. the exit rate is
    /// checkpointed under the old unit first and the exit funded flag resynced after. a later set never touches the exit
    /// auction price or clock: the price is coin per exit token, the unit only changes the slice. a dormant allowed
    /// target flag of the new module is cleared, so it cannot come back to life when the module is replaced
    function _setExitModule(address module) private {
        address old = exitModule;
        if (module.code.length == 0) revert BadModule();
        address token = IExitModule(module).exitToken();
        if (old != address(0) && token != exitToken) revert ExitTokenChanged();
        if (token.code.length == 0 || _forbiddenBase(module) || _forbiddenBase(token)) revert BadModule();
        (bool ok, bytes memory out) = _ask(module, abi.encodeCall(IExitModule.unitPerCredit, ()), READ_GAS, 32);
        uint256 unit = ok ? abi.decode(out, (uint256)) : 0;
        if (unit == 0 || unit > type(uint128).max) revert BadModule();
        // the climb so far is credited under the old unit
        _xCheckpoint();
        exitModule = module;
        exitToken = token;
        unitPerCredit = unit;
        // the opening price asks the whole coin supply for one full slice
        uint256 start = SUPPLY * 1e18 / _fullSlice(unit);
        // below 1e12 the integer halves to zero within days, and zero hands the slice away
        if (start < 1e12) revert BadModule();
        if (allowedTarget[module]) delete allowedTarget[module];
        if (old == address(0)) {
            xStartPrice = start;
            xStartTime = uint64(block.timestamp);
        } else {
            _syncXFunded();
        }
        emit ExitModuleSet(module, token, unit);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// number of credits in a lane pile.
    function pileSize(Lane lane) external view returns (uint256) {
        return _piles[lane].size;
    }

    /// up to n credit ids of a lane pile, oldest first, after startAfter. zero starts at the head.
    function pilePage(Lane lane, uint256 startAfter, uint256 n) external view returns (uint256[] memory ids) {
        uint256 first = startAfter == 0 ? _piles[lane].head : _credits[startAfter].next;
        // at most the pile size, so a huge n cannot blow up memory. the length is cut to the count found
        ids = new uint256[](n.min(_piles[lane].size));
        uint256 count;
        for (uint256 id = first; id != 0 && count < ids.length; id = _credits[id].next) {
            ids[count++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    /// pile membership, lane, cost basis and arrival time of a credit.
    function creditInfo(uint256 id) external view returns (bool inPile, Lane lane, uint256 cost, uint64 acquiredAt) {
        CoreLib.Credit storage c = _credits[id];
        return (c.inPile, c.lane, c.cost, c.acquiredAt);
    }

    /// whether the core holds a statement for sale or exit, with its lane, cost basis and compose time
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 composedAt) {
        CoreLib.Statement storage s = _statements[sid];
        return (s.held, s.lane, s.cost, s.composedAt);
    }

    /// every setting. the four packed slots go to the library, which unpacks them into the struct, and the answer is
    /// returned as it comes (an abi encoded `Settings`)
    function settings() external view returns (Settings memory) {
        bytes32 slot = SettingsStore.SLOT;
        address lib = address(CoreLib);
        bytes4 sel = CoreLib.unpack.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), sload(slot))
            mstore(add(p, 0x24), sload(add(slot, 1)))
            mstore(add(p, 0x44), sload(add(slot, 2)))
            mstore(add(p, 0x64), sload(add(slot, 3)))
            if iszero(staticcall(gas(), lib, p, 0x84, 0, 0)) { revert(0, 0) }
            returndatacopy(p, 0, returndatasize())
            return(p, returndatasize())
        }
    }

    /// every statement the core holds for sale or exit.
    function heldStatements() external view returns (uint256[] memory sids) {
        return _heldIds;
    }
}
