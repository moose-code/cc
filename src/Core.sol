// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IListingAdapter} from "./interfaces/IListingAdapter.sol";
import {IArtCoinsFactoryV2, IArtCoinsFeeEscrowV2} from "./interfaces/ArtCoinsV2.sol";
import {
    IController,
    IBalanceModule,
    ICoin,
    ICoreViews,
    ICredits,
    IStatements,
    Stack,
    Settings,
    Credit,
    Mainnet,
    BUYBACK_GAS,
    BUYLISTING_GAS
} from "./interfaces/Interfaces.sol";
import {CoreLib, State} from "./lib/CoreLib.sol";
import {SettingsBounds} from "./lib/SettingsBounds.sol";
import {CreditBounds} from "./lib/CreditBounds.sol";

/// custody and every rule of the credits engine. the owner sets the controller, the balance module and the adapter list at
/// once, can set a successor that receives the assets on `migrate`, and can close each of the controller, the balance
/// module, the adapters and the successor door with a one way lock (docs/ARCHITECTURE.md).
/// credits and statements sent to the core outside its doors are not tracked and stay in the core.
/// the Core is the bounty recipient of the pool. `receive()` accepts eth from the hook and the fee escrow only, and every
/// door starts with `_book()`, which splits the eth above the tracked pots into the payee claim, the coin buyback, the
/// redeem burn reserve and the pot.
contract Core is ICoreViews, IUnlockCallback, ReentrancyGuard {
    using FixedPointMathLib for uint256;

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
    /// a chosen compose while `chosenComposeOn` is false
    error ChosenComposeOff();
    /// the caller of a chosen compose holds less coin than `minCcToChoose`
    error BelowMinCc();
    /// a chosen compose names credit `id`, whose window has not passed while the credit sale is on
    error InWindow(uint256 id);
    error BadStatement();
    error BadCost();
    /// a plain send from an address other than the hook and the escrow. eth enters through `fund()` or as pool fees
    error UseFund();
    error BadModule();
    error BadSwap();
    /// `buyListing` names an adapter the owner has not approved
    error AdapterNotAllowed();
    /// the adapter reverted, ran out of its gas cap, or answered with fewer than three words or more than `QUOTE_MAX` bytes,
    /// or `sellForBalance` could not read a nonzero `refScore()` from the controller
    error BadQuote();
    error ForbiddenTarget();
    error AlreadyOwned();
    error CallFailed();
    error NoCredit();
    error PotTooSmall();
    /// the quoted `value` of `buyListing` is above the bid
    error AboveBid();
    error Slippage();
    error Underpaid();
    error NoBalanceModule();
    error BalanceTokenChanged();
    /// `redeemStatement` while `redeemOn` is false
    error RedeemOff();
    /// `sellForBalance` while `balanceBidOn` is false
    error BalanceBidOff();
    /// `redeemStatement`: the controller's `atFloor` is false (the curve price has not reached its floor) or the
    /// controller did not answer
    error NotEligible();
    /// the door `what` ("controller", "balanceModule" or "adapters") was locked by the owner
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
    /// `sellTo`: the statement is not held by the core
    error NotForSale();
    /// `sellTo` or `sellCreditTo` while sales are paused
    error Paused();
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
    /// `sellForEth`, `buyListing`, `sellForBalance`, `adopt`, `compose` or `composeChosen` after `migrate`
    error Retired();
    /// `setSuccessor` with the core or a contract the core works with
    error BadSuccessor(address who);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeesAdded(uint256 amount);
    /// `fund` added `amount` to the pot
    event Funded(address indexed from, uint256 amount);
    /// `collectEscrow` claimed `amount` from the fee escrow into the pot
    event EscrowCollected(uint256 amount);
    /// `bookBalance` added `amount` of the balance token to `balancePot`
    event BalanceBooked(uint256 amount);
    event PayeeSet(address indexed payee);
    event PayeeClaimed(address indexed payee, uint256 amount);
    event CreditBought(uint256 indexed id, address indexed from, uint256 cost);
    event ListingBought(
        uint256 indexed id, address indexed adapter, address indexed caller, uint256 cost, uint256 paid, uint256 rate
    );
    event EthRateFill(uint256 spent, uint256 rate, uint256 pot);
    event Composed(uint256 indexed sid, uint256[80] ids, uint8 format, uint256 cost, address indexed caller);
    event HeldFormatSet(uint256 indexed sid, uint8 format, address indexed caller);
    event SettingsSet(Settings settings);
    event RateSet(uint256 rate);
    event StatementRedeemed(uint256 indexed sid, uint256 received);
    event Buyback(address indexed caller, uint256 amountIn, uint256 paid);
    /// the controller sold a statement: the buyer, the price paid and the part of it booked to the coin buyback (the
    /// rest went to the pot)
    event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback);
    /// the controller sold a pile credit through the credit sale window: the buyer and the price paid
    event CreditSold(uint256 indexed id, address indexed buyer, uint256 price);
    event OwnershipTransferStarted(address indexed owner, address indexed pending);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ControllerLocked();
    event BalanceModuleLocked();
    event AdaptersLocked();
    event ControllerSet(address controller);
    event BalanceModuleSet(address balanceModule, address balanceToken, uint256 unitPerPoint);
    /// `releaseRedeemBurn` moved `amount` of the redeem burn reserve into the coin buyback
    event RedeemBurnReleased(uint256 amount);
    event AdapterSet(address indexed adapter, bool allowed);
    event CoinRescued(address indexed to, uint256 amount);
    event NftRescued(address indexed token, uint256 indexed id, address indexed to);
    event SuccessorSet(address successor);
    event SuccessorLocked();
    /// `adopt` put a credit the core held without a record into the pile at cost basis `cost`
    event CreditAdopted(uint256 indexed id, uint256 cost);
    /// `migrate` moved eth, balance token and credits to the successor
    event Migrated(address indexed successor, uint256 eth, uint256 balanceTokens, uint256 credits);
    /// the first `migrate` set `retired`
    event EngineRetired(address indexed successor);
    /// `migrate` could not transfer `balancePot` (`amount`) to the successor; the pot stays
    event BalanceTokenMigrationSkipped(address indexed successor, uint256 amount);
    /// share of a sold credit's cost booked to ethPot, the rest of the payment to ethToBuyback (docs/FLOW.md 88)
    event CreditCostToPotBpsSet(uint16 bps);
    /// whether a caller may pick the 80 credits and the format of a compose (docs/FLOW.md 89)
    event ChosenComposeOnSet(bool on);
    /// least coin balance a caller of a chosen compose must hold (docs/FLOW.md 89)
    event MinCcToChooseSet(uint96 min);
    event PausedSet(bool paused);

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant BPS = 10_000;
    uint256 private constant PPM = 1_000_000;
    uint256 private constant PAGE = 80;
    uint256 private constant MAX_FORMAT = 7;
    uint256 private constant READ_GAS = 200_000;
    /// gas the controller's `atFloor` may use: its reads of the settings, `floorRate`, the module's `unitPerPoint` and the
    /// pool `getSlot0`
    uint256 private constant AT_FLOOR_GAS = 400_000;
    /// words of the `deploymentInfo` answer the Core reads: the offset word and the fields up to `launchedAt`, the 9th
    uint256 private constant INFO_WORDS = 10;
    uint256 private constant LAUNCHED_AT_WORD = 9;
    /// gas of the work after the end of `compose` that the caller payment counts, with the transaction base cost
    uint256 private constant COMPOSE_OVERHEAD_GAS = 50_000;
    /// the most gas of a compose the caller payment counts. above the largest metered compose, so a gas burning
    /// controller cannot inflate the payment
    uint256 private constant COMPOSE_GAS = 13_700_000;
    /// gas of the work after the end of `redeemStatement` that the caller payment counts, with the transaction base cost
    uint256 private constant REDEEM_OVERHEAD_GAS = 50_000;
    /// the most gas of a redemption the caller payment counts, so a gas burning module cannot inflate it
    uint256 private constant REDEEM_GAS = 1_500_000;
    /// gas of the work after the end of `buyback` that its refund counts, with the transaction base cost
    uint256 private constant BUYBACK_OVERHEAD_GAS = 60_000;
    /// gas of the work after the count in `buyListing` (the spend, the pile record, the event and the payment, about
    /// 200,000), the transaction base cost and typical calldata
    uint256 private constant BUYLISTING_OVERHEAD_GAS = 250_000;
    /// gas the quote of a listing adapter may use
    uint256 private constant QUOTE_GAS = 300_000;
    /// bytes of the answer of a listing adapter the Core accepts
    uint256 private constant QUOTE_MAX = 8_192;
    /// gas the controller's `nextPage` may use. a full page of ControllerV1 costs under 250,000 gas on a
    /// cold read
    uint256 private constant PAGE_GAS = 500_000;
    address private constant DEAD = Mainnet.DEAD;

    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    address public immutable COIN;
    /// opening bid, wei per credit, fixed at deploy
    uint256 public immutable RATE_START;
    /// the artcoins v2 stack this core launched on, fixed at deploy. `receive` accepts eth from HOOK and ESCROW only
    IPoolManager public immutable MANAGER;
    address public immutable HOOK;
    int24 public immutable TICK_SPACING;
    uint24 public immutable POOL_FEE;
    address public immutable FACTORY;
    address public immutable LOCKER;
    address public immutable ESCROW;
    /// seconds from the launch to the start of the payee share, the window of the anti sniper skim
    uint256 public immutable SNIPER_SECONDS;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// every state variable of the Core (`State` in src/lib/CoreLib.sol), at slot 0. the library addresses it by the same type
    State internal s;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        if (msg.sender != s.owner) revert OnlyOwner();
    }

    /// `cfg_` is the launch config of the v2 factory. a zero `coin_` is a launch: the bounty recipient of `cfg_` is set
    /// to this contract and `COIN` is the address the factory predicts for `launcher_` and that config, so the coin and
    /// the Core refer to each other. a nonzero `coin_` is a successor of a Core of a coin that is launched already: it
    /// must be a coin the factory recorded, and `cfg_` supplies the anti sniper window
    constructor(
        address owner_,
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg_,
        address launcher_,
        address coin_,
        address controller_,
        address payee_,
        Stack memory stack_,
        uint256 rateStart_,
        Settings memory settings_,
        Credit memory credit_,
        address[] memory adapters_
    ) {
        if (owner_ == address(0) || controller_ == address(0) || payee_ == address(0)) revert ZeroAddress();
        if (
            stack_.poolManager == address(0) || stack_.hook == address(0) || stack_.factory == address(0)
                || stack_.locker == address(0) || stack_.escrow == address(0)
        ) revert ZeroAddress();
        if (stack_.tickSpacing <= 0 || stack_.tickSpacing > 32_767) revert BadStack();
        // the stack members must be contracts. the coin is not deployed yet when the core is created
        if (stack_.poolManager.code.length == 0) revert NoCode(stack_.poolManager);
        if (stack_.hook.code.length == 0) revert NoCode(stack_.hook);
        if (stack_.factory.code.length == 0) revert NoCode(stack_.factory);
        if (stack_.locker.code.length == 0) revert NoCode(stack_.locker);
        if (stack_.escrow.code.length == 0) revert NoCode(stack_.escrow);
        if (!SettingsBounds.rateInBounds(rateStart_) || rateStart_ > settings_.rateCap) revert BadRate();
        if (cfg_.pool.hook != stack_.hook) revert BadStack();
        address coin = coin_;
        if (coin == address(0)) {
            cfg_.fee.bountyRecipient = payable(address(this));
            coin = IArtCoinsFactoryV2(stack_.factory).predictToken(launcher_, cfg_);
            if (coin == address(0)) revert ZeroAddress();
        } else if (!IArtCoinsFactoryV2(stack_.factory).isCoin(coin)) {
            revert BadStack();
        }
        s.owner = owner_;
        s.payee = payee_;
        COIN = coin;
        SNIPER_SECONDS = cfg_.mev.windowSeconds;
        RATE_START = rateStart_;
        MANAGER = IPoolManager(stack_.poolManager);
        HOOK = stack_.hook;
        TICK_SPACING = stack_.tickSpacing;
        POOL_FEE = stack_.poolFee;
        FACTORY = stack_.factory;
        LOCKER = stack_.locker;
        ESCROW = stack_.escrow;
        s.controller = controller_;
        if (!CreditBounds.costToPotBpsOk(credit_.costToPotBps)) revert BadSetting("creditCostToPotBps");
        s.creditCostToPotBps = credit_.costToPotBps;
        s.chosenComposeOn = credit_.chosenComposeOn;
        s.minCcToChoose = credit_.minCcToChoose;
        for (uint256 i; i < adapters_.length; ++i) {
            address adapter = adapters_[i];
            if (adapter == address(0)) revert ZeroAddress();
            if (_forbiddenBase(adapter)) revert ForbiddenTarget();
            s.allowedAdapter[adapter] = true;
            emit AdapterSet(adapter, true);
        }
        s.rateAtCheckpoint = rateStart_;
        s.checkpointTime = uint64(block.timestamp);
        s.lastFillTime = uint64(block.timestamp);
        s.anchor.lastFillRate = rateStart_;
        s.anchor.peakRate = rateStart_;
        s.anchor.peakTime = uint64(block.timestamp);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        emit OwnershipTransferred(address(0), owner_);
        emit ControllerSet(controller_);
        emit PayeeSet(payee_);
        // validates, stores at the settings slot and logs, by delegatecall into the library
        CoreLib.setSettings(settings_);
    }

    /// accepts eth from the hook (the pool's bounty) and the fee escrow (a claim). the hook pushes with 2,300 gas, so
    /// the body is the sender compare. the eth is booked by the next `_book`
    receive() external payable {
        if (msg.sender != HOOK && msg.sender != ESCROW) revert UseFund();
    }

    /// accepts statements and credits from their own contracts only.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(STATEMENTS) && msg.sender != address(CREDITS)) revert BadSender();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE INTAKE
    //////////////////////////////////////////////////////////////*/

    /// books the eth above the tracked pots as fee income. anyone may call
    function book() external nonReentrant {
        _book();
    }

    /// adds `msg.value` to the pot. the eth above the tracked pots is booked first, so `msg.value` is never counted as
    /// fee income
    function fund() external payable nonReentrant {
        _book();
        _checkpoint();
        s.ethPot += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// claims the eth credit of the Core in the fee escrow (the refund of a partial buyback fill) into the pot
    function collectEscrow() external nonReentrant {
        _book();
        uint256 before = address(this).balance;
        IArtCoinsFeeEscrowV2(ESCROW).claim(address(this), address(0));
        uint256 amount = address(this).balance - before;
        if (amount != 0) {
            _checkpoint();
            s.ethPot += amount;
        }
        emit EscrowCollected(amount);
    }

    /// sends the booked payee share to `payee`. a payee that reverts blocks only its own claim
    function claimPayee() external nonReentrant {
        uint256 amount = s.payeeOwed;
        if (amount == 0) revert ZeroAmount();
        s.payeeOwed = 0;
        address to = s.payee;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert CallFailed();
        emit PayeeClaimed(to, amount);
    }

    /// adds the balance token held above `balancePot` to `balancePot`. no effect while no balance module is set
    function bookBalance() external nonReentrant {
        address token = s.balanceToken;
        uint256 amount;
        if (token != address(0)) {
            amount = SafeTransferLib.balanceOf(token, address(this)).zeroFloorSub(s.balancePot);
            s.balancePot += amount;
        }
        emit BalanceBooked(amount);
    }

    /// the eth held above `ethPot`, `ethToBuyback`, `ethRedeemBurn` and `payeeOwed`, without `value` of the current call
    function _income(uint256 value) private view returns (uint256) {
        return (address(this).balance - value).zeroFloorSub(s.ethPot + s.ethToBuyback + s.ethRedeemBurn + s.payeeOwed);
    }

    /// the parts of `income` that go to the payee and the redeem burn reserve. the rest goes to the pot. the payee share
    /// is `payeePpm` of the income while `payeeOn`, and the reserve share is `feeToRedeemBurnBps` of the income after it
    function _split(uint256 income) private view returns (uint256 toPayee, uint256 toRedeemBurn) {
        Settings storage cfg = s.settings;
        if (s.payeeOn) {
            toPayee = income * cfg.payeePpm / PPM;
            income -= toPayee;
        }
        toRedeemBurn = income * cfg.feeToRedeemBurnBps / BPS;
    }

    /// the share of the unbooked income that the next `_book` adds to the pot
    function _pendingPot() private view returns (uint256) {
        uint256 income = _income(0);
        (uint256 toPayee, uint256 toRedeemBurn) = _split(income);
        return income - toPayee - toRedeemBurn;
    }

    /// books the fee income. the first action of every door that reads or moves a pot, with `msg.value` of the door
    /// excluded. the rate is checkpointed before the pot grows. the payee share starts with the first book at or after
    /// `launchedAt + SNIPER_SECONDS` that has income, and that book shares nothing
    function _book() private {
        uint256 income = _income(msg.value);
        if (income == 0) return;
        _checkpoint();
        (uint256 toPayee, uint256 toRedeemBurn) = _split(income);
        if (s.payeeOn) {
            if (toPayee != 0) s.payeeOwed += toPayee;
        } else if (_sniperOver()) {
            s.payeeOn = true;
        }
        if (toRedeemBurn != 0) s.ethRedeemBurn += toRedeemBurn;
        income -= toPayee;
        s.ethPot += income - toRedeemBurn;
        emit FeesAdded(income);
    }

    /// whether the launch time recorded by the factory plus `SNIPER_SECONDS` has passed. a launch that is not recorded
    /// or a factory that does not answer reads as not passed
    function _sniperOver() private view returns (bool) {
        (bool ok, bytes memory out) =
            _ask(FACTORY, abi.encodeCall(IArtCoinsFactoryV2.deploymentInfo, (COIN)), READ_GAS, INFO_WORDS * 32);
        if (!ok) return false;
        uint256 launchedAt;
        assembly ("memory-safe") {
            launchedAt := mload(add(out, add(0x20, mul(LAUNCHED_AT_WORD, 0x20))))
        }
        return launchedAt != 0 && block.timestamp >= launchedAt + SNIPER_SECONDS;
    }

    /*//////////////////////////////////////////////////////////////
                               ETH RATE
    //////////////////////////////////////////////////////////////*/

    /// wei per credit right now: the price state (`rateAtCheckpoint` climbed lazily, bounded by the ceiling and
    /// `rateCap`) lowered to the pot, the price of one credit that the pot affords. the pot of the clamp is `ethPot`
    /// plus the share of the unbooked fee income that the next `_book` adds to it. the clamp is not stored. the math is
    /// in `CoreLib.climb`
    function ethRate() external view returns (uint256) {
        (uint256 price,) = _climb();
        return price.min(s.ethPot + _pendingPot());
    }

    /// the rate of the booked pot, for the doors, which book first
    function _bid() private view returns (uint256 read) {
        (, read) = _climb();
    }

    function _climb() private view returns (uint256, uint256) {
        return CoreLib.climb(s.rateAtCheckpoint, s.ethPot, s.lastFillTime, s.checkpointTime, block.timestamp);
    }

    /// wei per credit of the price state now: `rateAtCheckpoint` climbed lazily and bounded by the ceiling and
    /// `rateCap`, before the clamp that `ethRate` applies. the climb also stops at the pot, so with an empty pot the
    /// price state does not climb. the cost basis of an adopted credit is this price
    function ethPrice() external view returns (uint256 price) {
        (price,) = _climb();
    }

    /// wei per credit of the floor rate now: the larger of `ethPrice`, the price state climbed before the pot clamp,
    /// and the remembered peak of the eth bid decayed to now. selling credits lowers only the rate and the peak decays
    /// between fills, so the maximum follows the climb and holds against a sale within the block. the engine's price
    /// floors read it. the math is in `CoreLib.floorRate`
    function floorRate() external view returns (uint256) {
        return CoreLib.floorRate(s.rateAtCheckpoint, s.ethPot, s.lastFillTime, s.checkpointTime, block.timestamp);
    }

    function _checkpoint() private {
        (s.rateAtCheckpoint,) = _climb();
        s.checkpointTime = uint64(block.timestamp);
    }

    /// checkpoints, then books a spend of x from the pot: rate drop, fill time.
    function _spend(uint256 x) private {
        _checkpoint();
        uint256 p = s.ethPot;
        if (x == 0) revert ZeroAmount();
        if (x > p) revert PotTooSmall();
        uint256 r = CoreLib.drop(s.rateAtCheckpoint, block.timestamp);
        s.rateAtCheckpoint = r;
        s.lastFillTime = uint64(block.timestamp);
        s.ethPot = p - x;
        emit EthRateFill(x, r, p - x);
    }

    /*//////////////////////////////////////////////////////////////
                           CONTROLLER READS
    //////////////////////////////////////////////////////////////*/

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

    function _nextPage() private view returns (bool ready, uint256[80] memory ids, uint256 format) {
        (bool ok, bytes memory out) =
            _ask(s.controller, abi.encodeCall(IController.nextPage, ()), PAGE_GAS, (PAGE + 2) * 32);
        if (!ok) return (false, ids, 0);
        uint256 flag;
        (flag, ids, format) = abi.decode(out, (uint256, uint256[80], uint256));
        ready = flag == 1;
    }

    /// bounded read of the controller's eligibility answer for a statement. a revert, a short answer or a
    /// `false` reads as not eligible
    function _atFloor(uint256 sid) private view returns (bool) {
        (bool ok, bytes memory out) = _ask(s.controller, abi.encodeCall(IController.atFloor, (sid)), AT_FLOOR_GAS, 32);
        return ok && abi.decode(out, (bool));
    }

    /// bounded read of the controller's window answer for a credit acquired at `acquiredAt`. a revert, a short answer
    /// or a `false` reads as not past the window
    function _pastWindow(uint64 acquiredAt) private view returns (bool) {
        (bool ok, bytes memory out) =
            _ask(s.controller, abi.encodeCall(IController.pastWindow, (acquiredAt)), READ_GAS, 32);
        return ok && abi.decode(out, (bool));
    }

    /*//////////////////////////////////////////////////////////////
                                PILES
    //////////////////////////////////////////////////////////////*/

    function _push(uint256 id, uint256 cost) private {
        CoreLib.push(s.pile, s.credits, id, cost);
    }

    function _pull(uint256 id) private returns (uint256 cost) {
        CoreLib.Credit storage c = s.credits[id];
        if (!c.inPile) revert NotInPile(id);
        CoreLib.Pile storage p = s.pile;
        uint256 prev = c.prev;
        uint256 next = c.next;
        if (prev == 0) p.head = next;
        else s.credits[prev].next = next;
        if (next == 0) p.tail = prev;
        else s.credits[next].prev = prev;
        p.size -= 1;
        cost = c.cost;
        delete s.credits[id];
    }

    /// the first action of `sellForEth`, `sellForBalance`, `buyListing`, `adopt`, `compose` and `composeChosen`. two
    /// steps in order:
    /// 1. reverts `Retired` once `migrate` has run.
    /// 2. books the fee income, before the entry point reads a rate or checkpoints
    function _openDoor() private {
        if (s.retired) revert Retired();
        _book();
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
            uint256 price = _bid();
            _spend(price);
            _push(id, price);
            CREDITS.transferFrom(msg.sender, address(this), id);
            total += price;
            emit CreditBought(id, msg.sender, price);
        }
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransferETH(msg.sender, total);
    }

    /// buys credit `id` from the listing that an approved adapter prices. the adapter answers the one call the Core
    /// makes (`target`, `value`, `data`) from the venue's own data, by a read capped at `QUOTE_GAS` gas and `QUOTE_MAX`
    /// bytes. `value` is at most the bid (`ethRate()`) and at most `ethPot`. the Core must own `id` after the call and
    /// its credit balance must have risen by one. the caller is paid from `ethPot`: the gas of the call at the base fee,
    /// capped at `keeperMaxBaseFee` and `BUYLISTING_GAS`, plus `keeperFee`. the payment is at most the bid less
    /// `value`, so the pot pays at most the bid for the credit. reverts `Retired` after `migrate`
    function buyListing(address adapter, uint256 id, bytes calldata params) external nonReentrant {
        uint256 gasStart = gasleft();
        _openDoor();
        if (!s.allowedAdapter[adapter]) revert AdapterNotAllowed();
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) == address(this)) revert AlreadyOwned();
        (address target, uint256 value, bytes memory data) = _quote(adapter, id, params);
        if (_forbidden(target)) revert ForbiddenTarget();
        _checkpoint();
        uint256 bid = _bid();
        if (value == 0) revert ZeroAmount();
        if (value > s.ethPot) revert PotTooSmall();
        if (value > bid) revert AboveBid();

        uint256 ethBefore = address(this).balance;
        uint256 creditsBefore = CREDITS.balanceOf(address(this));
        (bool ok,) = target.call{value: value}(data);
        if (!ok) revert CallFailed();
        if (CREDITS.balanceOf(address(this)) != creditsBefore + 1 || CREDITS.ownerOf(id) != address(this)) {
            revert NoCredit();
        }
        if (address(this).balance + value < ethBefore) revert BadCost();

        // `value` is at most the bid, which is at most `ethPot`
        Settings storage cfg = s.settings;
        uint256 paid = _payment(gasStart, BUYLISTING_OVERHEAD_GAS, BUYLISTING_GAS, cfg.keeperMaxBaseFee, cfg.keeperFee)
            .min(bid - value);
        _spend(value + paid);
        _push(id, value + paid);
        emit ListingBought(id, adapter, msg.sender, value, paid, s.rateAtCheckpoint);
        if (paid != 0) SafeTransferLib.safeTransferETH(msg.sender, paid);
    }

    /// reads the quote of `adapter` for `id`. a revert, a gas cap overrun, an answer under three words or over
    /// `QUOTE_MAX` bytes reverts `BadQuote`
    function _quote(address adapter, uint256 id, bytes calldata params)
        private
        view
        returns (address target, uint256 value, bytes memory data)
    {
        bytes memory input = abi.encodeCall(IListingAdapter.price, (id, params));
        bool ok;
        bytes memory out;
        assembly ("memory-safe") {
            ok := staticcall(QUOTE_GAS, adapter, add(input, 0x20), mload(input), 0, 0)
            let n := returndatasize()
            ok := and(ok, and(iszero(lt(n, 0x60)), iszero(gt(n, QUOTE_MAX))))
            if ok {
                out := mload(0x40)
                mstore(out, n)
                returndatacopy(add(out, 0x20), 0, n)
                mstore(0x40, add(add(out, 0x20), and(add(n, 0x1f), not(0x1f))))
            }
        }
        if (!ok) revert BadQuote();
        (target, value, data) = abi.decode(out, (address, uint256, bytes));
    }

    /// sell credits into the balance token bid. the balance side only. reverts `Retired` after `migrate`. the body is
    /// `CoreLib.sellForBalance`, called with the calldata untouched
    function sellForBalance(uint256[] calldata ids) external nonReentrant {
        _openDoor();
        _toLib();
    }

    /// same as sellForBalance with a floor on the total paid.
    function sellForBalance(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _openDoor();
        _toLib();
    }

    /// checks that the caller owns credit id, which must not be the zero sentinel.
    function _owned(uint256 id) private view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    function _forbidden(address t) private view returns (bool) {
        return _forbiddenBase(t) || t == s.balanceModule || t == s.balanceToken;
    }

    /// every forbidden target except the balanceModule and the balanceToken, which a later set may name again
    function _forbiddenBase(address t) private view returns (bool) {
        return t == address(CREDITS) || t == address(STATEMENTS) || t == address(this) || t == COIN || t == HOOK
            || t == address(MANAGER) || t == FACTORY || t == LOCKER || t == ESCROW
            || t == Mainnet.PERMIT2 || t == Mainnet.POSITION_MANAGER
            || t == Mainnet.UNIVERSAL_ROUTER;
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOSING
    //////////////////////////////////////////////////////////////*/

    /// composes the controller's page of the oldest 80 pile credits into a statement the core holds for sale. the
    /// format is `keccak256(abi.encode(block.prevrandao, first page id)) % 8`. anyone may call. reverts `Retired` after
    /// `migrate`
    function compose() external nonReentrant {
        _composePage(0, true, gasleft());
    }

    /// composes the controller's page as `compose` does, with the given format (0 to 7, else `BadFormat`)
    function compose(uint8 format) external nonReentrant {
        if (format > MAX_FORMAT) revert BadFormat();
        _composePage(format, false, gasleft());
    }

    /// the shared body of the two system composes. the controller's `nextPage` format is not used
    function _composePage(uint256 format, bool random, uint256 gasStart) private {
        _openDoor();
        (bool ready, uint256[80] memory ids,) = _nextPage();
        if (!ready) revert NotReady();
        if (random) format = uint256(keccak256(abi.encode(block.prevrandao, ids[0]))) % (MAX_FORMAT + 1);
        _compose(ids, format, gasStart);
    }

    /// sets the render format of a statement the core holds for sale. anyone holding at least `minCcToChoose` coin may
    /// call. reverts `NotForSale` for a statement that is not held, `BadFormat` above 7 and `BelowMinCc` below the
    /// coin minimum. callable while paused and after `migrate`: statements held by a retired engine stay with it and
    /// are sold by it. the coin minimum is a balance read at the call, so a flash balance passes it. the gate is a
    /// speed bump on a cosmetic door
    function setHeldFormat(uint256 sid, uint8 format) external nonReentrant {
        if (!s.statements[sid].held) revert NotForSale();
        if (format > MAX_FORMAT) revert BadFormat();
        if (SafeTransferLib.balanceOf(COIN, msg.sender) < s.minCcToChoose) revert BelowMinCc();
        STATEMENTS.setFormat(sid, format);
        emit HeldFormatSet(sid, format, msg.sender);
    }

    /// composes a statement from 80 pile credits the caller names and a format the caller picks. requires
    /// `chosenComposeOn`, a caller coin balance at least `minCcToChoose`, and that every named credit is in the pile.
    /// the core passes only the newest named credit's acquisition time to the controller's `pastWindow`. the controller
    /// must keep `pastWindow` non-increasing in the acquisition time, so the newest named credit passing means every
    /// named credit passes. every other compose rule, the record and the event are the same as `compose`. reverts
    /// `Retired` after `migrate`
    function composeChosen(uint256[80] calldata ids, uint8 format) external nonReentrant {
        uint256 gasStart = gasleft();
        _openDoor();
        if (!s.chosenComposeOn) revert ChosenComposeOff();
        if (SafeTransferLib.balanceOf(COIN, msg.sender) < s.minCcToChoose) revert BelowMinCc();
        uint64 newest;
        uint256 newestId;
        for (uint256 i; i < PAGE; ++i) {
            uint64 a = s.credits[ids[i]].acquiredAt;
            if (a > newest) {
                newest = a;
                newestId = ids[i];
            }
        }
        if (!_pastWindow(newest)) revert InWindow(newestId);
        _compose(ids, format, gasStart);
    }

    /// pulls the 80 named credits from the pile, composes the statement, stores its record and pays the caller. the
    /// cost basis is the sum of the credits' costs. a credit named twice or absent reverts in `_pull`. shared by
    /// `compose` and `composeChosen`
    function _compose(uint256[80] memory ids, uint256 format, uint256 gasStart) private {
        if (format > MAX_FORMAT) revert BadFormat();
        uint256 cost;
        for (uint256 i; i < PAGE; ++i) {
            uint256 id = ids[i];
            cost += _pull(id);
            if (CREDITS.ownerOf(id) != address(this)) revert NotHeld();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 sid = STATEMENTS.compose(ids, uint8(format));
        if (sid != STATEMENTS.supply() || STATEMENTS.ownerOf(sid) != address(this) || STATEMENTS.creditsOf(sid) != PAGE)
        {
            revert BadStatement();
        }

        s.heldIds.push(sid);
        s.composerOf[sid] = msg.sender;
        // rating is the sum of 80 credit scores in ten-thousandths of a point, each at most 8_000_000, so at most
        // 640_000_000, within uint32. the cast is checked so a statement whose rating does not fit is refused rather
        // than stored truncated (a compose cannot overprint, so this bound always holds)
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        if (rating > type(uint32).max) revert BadStatement();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.statements[sid] = CoreLib.Statement({
            cost: cost,
            composedAt: uint64(block.timestamp),
            slot: uint64(s.heldIds.length - 1),
            rating: uint32(rating),
            held: true,
            pauseMark: pausedNow()
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Composed(sid, ids, uint8(format), cost, msg.sender);
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

    /// pays the caller of `compose` and `redeemStatement` from `ethPot`, at most the pot, by the
    /// `callerFee` and `callerMaxBaseFee` settings. the last action of the door, after all state is final. the
    /// checkpoint runs before the payment is metered, so the caller is repaid for it and the overhead constant does not
    /// track the climb's gas. both settings zero (the launch value) is the only case that pays nothing, and it skips the
    /// checkpoint and the metering
    function _payCaller(uint256 gasStart, uint256 overhead, uint256 gasCap) private {
        Settings storage cfg = s.settings;
        if (cfg.callerMaxBaseFee == 0 && cfg.callerFee == 0) return;
        _checkpoint();
        uint256 pay = _payment(gasStart, overhead, gasCap, cfg.callerMaxBaseFee, cfg.callerFee).min(s.ethPot);
        if (pay == 0) return;
        s.ethPot -= pay;
        SafeTransferLib.safeTransferETH(msg.sender, pay);
    }

    /// forgets a held statement and compacts the held list.
    function _unhold(uint256 sid) private {
        CoreLib.Statement storage st = s.statements[sid];
        uint256 slot = st.slot;
        uint256 last = s.heldIds[s.heldIds.length - 1];
        s.heldIds[slot] = last;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.statements[last].slot = uint64(slot);
        s.heldIds.pop();
        delete s.statements[sid];
    }

    /*//////////////////////////////////////////////////////////////
                                 SALE
    //////////////////////////////////////////////////////////////*/

    /// the controller sells a held statement to `buyer` for `msg.value`, at least `saleFloorBps` of the
    /// statement cost. `saleToBuybackBps` of the payment goes to the coin buyback and the rest to the pot. the
    /// controller refunds its own caller
    function sellTo(uint256 sid, address buyer) external payable nonReentrant {
        if (msg.sender != s.controller) revert OnlyController();
        if (s.paused) revert Paused();
        _book();
        CoreLib.Statement storage st = s.statements[sid];
        if (!st.held) revert NotForSale();
        if (msg.value < st.cost * s.settings.saleFloorBps / BPS) revert BelowFloor();
        _unhold(sid);
        STATEMENTS.transferFrom(address(this), buyer, sid);
        uint256 toBuyback = msg.value * s.settings.saleToBuybackBps / BPS;
        s.ethToBuyback += toBuyback;
        _checkpoint();
        s.ethPot += msg.value - toBuyback;
        emit StatementSoldTo(sid, buyer, msg.value, toBuyback);
    }

    /// the controller sells pile credit `id` to `buyer` for `msg.value`. the payment is at least the credit's cost: no
    /// credit leaves the pot for less than it was bought for, whatever the controller quotes. `creditCostToPotBps` of
    /// the cost goes to the pot and the rest of the payment to the coin buyback, so the markup over cost funds a coin
    /// buy and burn. the controller refunds its own caller
    function sellCreditTo(uint256 id, address buyer) external payable nonReentrant {
        if (msg.sender != s.controller) revert OnlyController();
        if (s.paused) revert Paused();
        _book();
        CoreLib.Credit storage c = s.credits[id];
        if (!c.inPile) revert NotInPile(id);
        uint256 cost = c.cost;
        if (msg.value < cost) revert BelowFloor();
        _pull(id);
        CREDITS.transferFrom(address(this), buyer, id);
        uint256 toPot = cost * s.creditCostToPotBps / BPS;
        s.ethToBuyback += msg.value - toPot;
        // checkpoint the climbed rate before the pot grows, so a credit sale cannot raise the eth bid read within its
        // own block
        _checkpoint();
        s.ethPot += toPot;
        emit CreditSold(id, buyer, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    /// hands a held statement to the balance module and books the balance token it returns into `balancePot`. requires
    /// `redeemOn` and a module set. a statement is eligible when the controller's curve price has reached its floor.
    /// the redemption must raise the balance token holding by at least
    /// `rating * unitPerPoint * (10_000 - redeemSlippageBps) / 10_000`, with `unitPerPoint` read from the module in the
    /// call (`BadModule` when the read fails, is zero or exceeds uint128). every redemption moves `redeemBurnBps` of the
    /// redeem burn reserve into the coin buyback
    function redeemStatement(uint256 sid) external nonReentrant {
        uint256 gasStart = gasleft();
        _book();
        address module = s.balanceModule;
        if (module == address(0)) revert NoBalanceModule();
        if (!s.settings.redeemOn) revert RedeemOff();
        CoreLib.Statement memory st = s.statements[sid];
        if (!st.held) revert NotHeld();
        if (!_atFloor(sid)) revert NotEligible();
        address token = s.balanceToken;
        uint256 required = uint256(st.rating) * _unitOf(module) * (BPS - s.settings.redeemSlippageBps) / BPS;
        _unhold(sid);

        uint256 balanceBefore = SafeTransferLib.balanceOf(token, address(this));
        STATEMENTS.transferFrom(address(this), module, sid);
        IBalanceModule(module).redeem(sid);
        uint256 balanceAfter = SafeTransferLib.balanceOf(token, address(this));
        if (balanceAfter < balanceBefore + required) revert Underpaid();
        uint256 received = balanceAfter - balanceBefore;
        s.balancePot += received;

        uint256 toBurn = s.ethRedeemBurn * s.settings.redeemBurnBps / BPS;
        if (toBurn != 0) {
            s.ethRedeemBurn -= toBurn;
            s.ethToBuyback += toBurn;
        }
        emit StatementRedeemed(sid, received);
        _payCaller(gasStart, REDEEM_OVERHEAD_GAS, REDEEM_GAS);
    }

    /*//////////////////////////////////////////////////////////////
                               BUYBACKS
    //////////////////////////////////////////////////////////////*/

    /// swaps up to one slice of the eth buyback pot for coin in the canonical pool, then burns the coin on the token
    /// so the total supply falls. the caller is paid from the slice: the gas of the call at the base fee, capped at
    /// `keeperMaxBaseFee` and `BUYBACK_GAS`, plus `keeperFee` scaled by `spent` over the largest swap budget the
    /// `buybackSlice` setting allows. the largest payment is `BUYBACK_GAS * rate + keeperFee`, the swap budget is the
    /// slice less that payment, and a slice under twice that payment reverts, so the payment is at most half the slice.
    /// the eth spent is the pool delta of the swap. the bounty share of the hook's skim on this swap reaches the Core
    /// during the swap and is booked by the next `_book`, and a partial fill refund through the escrow (`collectEscrow`).
    function buyback() external nonReentrant {
        uint256 gasStart = gasleft();
        _book();
        uint256 pool = s.ethToBuyback;
        if (pool == 0) revert NothingToBuy();
        Settings storage cfg = s.settings;
        if (block.number < s.lastBuybackBlock + cfg.buybackDelay) revert TooSoon();
        uint256 setSlice = cfg.buybackSlice;
        uint256 slice = pool.min(setSlice);
        uint256 rate = block.basefee.min(cfg.keeperMaxBaseFee);
        uint256 fee = cfg.keeperFee;
        uint256 maxPay = BUYBACK_GAS * rate + fee;
        if (slice < 2 * maxPay) revert SliceTooSmall();
        uint256 budget = slice - maxPay;
        s.ethToBuyback = pool - slice;
        s.lastBuybackBlock = block.number;
        (uint256 spent, uint256 bought) = abi.decode(MANAGER.unlock(abi.encode(budget)), (uint256, uint256));
        if (bought == 0) revert NothingBought();
        ICoin(COIN).burn(bought);
        // spent is at most budget, which is at most setSlice - maxPay, so the scaled fee is at most the fee
        uint256 paid = _payment(
            gasStart, BUYBACK_OVERHEAD_GAS, BUYBACK_GAS, cfg.keeperMaxBaseFee, fee.min(fee * spent / (setSlice - maxPay))
        );
        s.ethToBuyback += slice - spent - paid;
        emit Buyback(msg.sender, spent, paid);
        if (paid != 0) SafeTransferLib.safeTransferETH(msg.sender, paid);
    }

    /// pool manager callback of `buyback`. swaps exact eth in for coin, which comes to the core. returns the eth
    /// spent, hook skim included, and the coin bought. the take of the coin from the pool manager passes the restriction of the
    /// coin through the transfer allowance the hook grants for the swap.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert OnlyPoolManager();
        (uint256 owed, uint256 bought) =
            CoreLib.swapIn(address(MANAGER), COIN, POOL_FEE, TICK_SPACING, HOOK, abi.decode(data, (uint256)));
        return abi.encode(owed, bought);
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/

    /// starts the handover of the owner role: `to` becomes the owner when it calls `acceptOwnership`. the zero address
    /// clears a pending handover. there is no renounce
    function transferOwnership(address to) external onlyOwner {
        s.pendingOwner = to;
        emit OwnershipTransferStarted(msg.sender, to);
    }

    /// completes the handover, called by the pending owner. the zero caller never passes
    function acceptOwnership() external {
        if (msg.sender == address(0) || msg.sender != s.pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(s.owner, msg.sender);
        s.owner = msg.sender;
        delete s.pendingOwner;
    }

    /// sets the controller at once. never zero. reverts after `lockController`
    function setController(address c) external onlyOwner {
        if (s.controllerLocked) revert Locked("controller");
        if (c == address(0)) revert ZeroAddress();
        s.controller = c;
        emit ControllerSet(c);
    }

    /// sets the address `claimPayee` pays. never zero. effective at once, applies to the eth already owed
    function setPayee(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        s.payee = to;
        emit PayeeSet(to);
    }

    /// sets or replaces the balance module at once (any number of times until `lockBalanceModule`)
    function setBalanceModule(address module) external onlyOwner nonReentrant {
        if (s.balanceModuleLocked) revert Locked("balanceModule");
        _setBalanceModule(module);
    }

    /// moves `amount` of the redeem burn reserve into the coin buyback, capped at the reserve. the eth stays inside the
    /// core for a coin buy and burn: `ethRedeemBurn` falls and `ethToBuyback` rises by the same amount, so the tracked
    /// total and solvency hold. callable after `migrate`. reverts `ZeroAmount` when the reserve is empty or `amount` is 0
    function releaseRedeemBurn(uint256 amount) external onlyOwner nonReentrant {
        uint256 reserve = s.ethRedeemBurn;
        uint256 move = amount < reserve ? amount : reserve;
        if (move == 0) revert ZeroAmount();
        s.ethRedeemBurn = reserve - move;
        s.ethToBuyback += move;
        emit RedeemBurnReleased(move);
    }

    /// approves a listing adapter for `buyListing` at once. forbidden addresses are refused. reverts after `lockAdapters`
    function addAdapter(address a) external onlyOwner {
        if (s.adaptersLocked) revert Locked("adapters");
        if (_forbidden(a)) revert ForbiddenTarget();
        s.allowedAdapter[a] = true;
        emit AdapterSet(a, true);
    }

    /// the one way locks. each is irreversible. the settings and the controller's own sale settings stay open
    function lockController() external onlyOwner {
        s.controllerLocked = true;
        emit ControllerLocked();
    }

    /// reverts while no balance module is set, so the balance side cannot be locked out by accident
    function lockBalanceModule() external onlyOwner {
        if (s.balanceModule == address(0)) revert NoBalanceModule();
        s.balanceModuleLocked = true;
        emit BalanceModuleLocked();
    }

    /// after this no adapter can be added. removing one still works
    function lockAdapters() external onlyOwner {
        s.adaptersLocked = true;
        emit AdaptersLocked();
    }

    /// sends coin the core holds to `to`. the core holds coin only in passing (the buyback burns what it buys in the same
    /// call), so this reaches only coin that an allowlisted holder sent to it, which the restriction of the coin permits.
    /// coin only: never eth, credits, statements or the balance token. owner only and guarded, both checked by the library,
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
    /// reverts `Locked("successor")` after `lockSuccessor`, and `BadSuccessor` for the core, the balance module, the balance
    /// token, the coin, Credits and Statements. owner only, checked by the library, to which
    /// the call is handed untouched. logs `SuccessorSet`
    function setSuccessor(address) external {
        _toLib();
    }

    /// closes `setSuccessor`, one way. allowed while the successor is zero, which disables `migrate`.
    /// logs `SuccessorLocked`
    function lockSuccessor() external {
        _toLib();
    }

    /// moves `ethPot`, `balancePot` and up to `maxCredits` credits from the head of the pile to the successor,
    /// in batches. callable again until nothing is left. `ethToBuyback` and `ethRedeemBurn` stay for the coin buyback.
    /// the held statements and their records stay with the core. a balance token transfer that fails leaves `balancePot` and
    /// logs `BalanceTokenMigrationSkipped`, the eth and credit legs go on. the first call sets `retired` and logs
    /// `EngineRetired`. owner only and guarded, both checked by the library, to which the call is handed untouched.
    /// reverts `NoSuccessor` while the successor is zero
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

    /// puts credits the core holds without a record into the pile, anyone may call. the fee income is booked first,
    /// like at every door that reads the pot, so it is in the pot before the price is read. the cost basis of
    /// each credit is the price state per credit (`ethPrice`), at least 1 wei. the price
    /// state is the figure the engine pays with a funded pot, so a statement built from adopted credits is priced at
    /// that level; the clamp of a thin pot would book a basis of 1 wei. the basis is booked and the pile grows: eth,
    /// the rate state and the pots keep their values. a donor who inflates the basis of a statement
    /// gives credits away. reverts `Retired` after `migrate`, `InPile`, `NotHolder`, `ZeroId` and `Empty`. logs
    /// `CreditAdopted`. the body is `CoreLib.adopt`, called with the calldata untouched
    function adopt(uint256[] calldata) external nonReentrant {
        _openDoor();
        _toLib();
    }

    /// removes an approved adapter at once.
    function removeAdapter(address a) external onlyOwner {
        s.allowedAdapter[a] = false;
        emit AdapterSet(a, false);
    }

    /// sets the share of a sold credit's cost booked to ethPot, the rest of the payment to ethToBuyback. 0 to 10_000.
    /// read by `sellCreditTo` (docs/FLOW.md 88)
    function setCreditCostToPotBps(uint16 v) external onlyOwner {
        if (!CreditBounds.costToPotBpsOk(v)) revert BadSetting("creditCostToPotBps");
        s.creditCostToPotBps = v;
        emit CreditCostToPotBpsSet(v);
    }

    /// turns chosen composition on or off. gates `composeChosen`; `compose` is unaffected (docs/FLOW.md 89)
    function setChosenComposeOn(bool v) external onlyOwner {
        s.chosenComposeOn = v;
        emit ChosenComposeOnSet(v);
    }

    /// sets the least coin balance a caller of `composeChosen` must hold (docs/FLOW.md 89)
    function setMinCcToChoose(uint96 v) external onlyOwner {
        s.minCcToChoose = v;
        emit MinCcToChooseSet(v);
    }

    /// pauses or resumes `sellTo` and `sellCreditTo` at once. a call that repeats the current state changes nothing.
    /// a pause records its start in `pausedSince`, a resume adds the length of the pause to `pausedTotal`. compose,
    /// the bids, redemptions, buybacks and fee booking run in a pause
    function setPaused(bool on) external onlyOwner {
        if (on == s.paused) return;
        s.paused = on;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 t = uint40(block.timestamp);
        if (on) {
            s.pausedSince = t;
        } else {
            s.pausedTotal += t - s.pausedSince;
            s.pausedSince = 0;
        }
        emit PausedSet(on);
    }

    /// the paused seconds from deployment to now: `pausedTotal` plus the open pause
    function pausedNow() internal view returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return s.pausedTotal + (s.paused ? uint40(block.timestamp) - s.pausedSince : 0);
    }

    /// sets every economic setting at once, effective now. the eth rate is checkpointed first, so no climb is credited
    /// under the wrong numbers, then the call is handed to the library untouched: it checks every field against its
    /// bounds, stores them and logs them. a change of `peakHalfLife` restates the remembered peak at the old half life
    /// first, so the new one decays forward only
    function setSettings(Settings calldata) external onlyOwner nonReentrant {
        _book();
        _checkpoint();
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
    }

    /// restates the eth rate (wei per credit) as `rate`, within the rate bounds. the stored rate, the last fill rate and
    /// the remembered peak are all `rate`, the fill clock is unchanged. the clamp and the ceiling still bound the rate
    /// on read
    function setRate(uint256 rate) external onlyOwner nonReentrant {
        if (!SettingsBounds.rateInBounds(rate) || rate > s.settings.rateCap) revert BadRate();
        s.anchor.lastFillRate = rate;
        s.anchor.peakRate = rate;
        s.anchor.peakTime = uint64(block.timestamp);
        s.rateAtCheckpoint = rate;
        s.checkpointTime = uint64(block.timestamp);
        emit RateSet(rate);
    }

    /// the module's `unitPerPoint()`, read with at most `READ_GAS`. reverts `BadModule` for a failed or short read, zero,
    /// or a value above `type(uint128).max`
    function _unitOf(address module) private view returns (uint256 unit) {
        (bool ok, bytes memory out) = _ask(module, abi.encodeCall(IBalanceModule.unitPerPoint, ()), READ_GAS, 32);
        unit = ok ? abi.decode(out, (uint256)) : 0;
        if (unit == 0 || unit > type(uint128).max) revert BadModule();
    }

    /// sets or replaces the balance module. the balance token never changes once set. the module's unit must be valid
    /// at the set (`_unitOf`). a dormant approved adapter flag of the new module is cleared, so it cannot come back to
    /// life when the module is replaced
    function _setBalanceModule(address module) private {
        address old = s.balanceModule;
        if (module.code.length == 0) revert BadModule();
        address token = IBalanceModule(module).balanceToken();
        if (old != address(0) && token != s.balanceToken) revert BalanceTokenChanged();
        if (token.code.length == 0 || _forbiddenBase(module) || _forbiddenBase(token)) revert BadModule();
        uint256 unit = _unitOf(module);
        s.balanceModule = module;
        s.balanceToken = token;
        if (s.allowedAdapter[module]) delete s.allowedAdapter[module];
        emit BalanceModuleSet(module, token, unit);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function controller() external view returns (address) { return s.controller; }
    function controllerLocked() external view returns (bool) { return s.controllerLocked; }
    function balanceModuleLocked() external view returns (bool) { return s.balanceModuleLocked; }
    function adaptersLocked() external view returns (bool) { return s.adaptersLocked; }
    function balanceModule() external view returns (address) { return s.balanceModule; }
    function balanceToken() external view returns (address) { return s.balanceToken; }
    function allowedAdapter(address adapter) external view returns (bool) { return s.allowedAdapter[adapter]; }
    function owner() external view returns (address) { return s.owner; }
    function pendingOwner() external view returns (address) { return s.pendingOwner; }
    function ethPot() external view returns (uint256) { return s.ethPot; }
    function ethToBuyback() external view returns (uint256) { return s.ethToBuyback; }
    function ethRedeemBurn() external view returns (uint256) { return s.ethRedeemBurn; }
    function balancePot() external view returns (uint256) { return s.balancePot; }
    function rateAtCheckpoint() external view returns (uint256) { return s.rateAtCheckpoint; }
    function checkpointTime() external view returns (uint64) { return s.checkpointTime; }
    function lastFillTime() external view returns (uint64) { return s.lastFillTime; }
    function lastBuybackBlock() external view returns (uint256) { return s.lastBuybackBlock; }
    function successor() external view returns (address) { return s.successor; }
    function successorLocked() external view returns (bool) { return s.successorLocked; }
    function retired() external view returns (bool) { return s.retired; }
    function creditCostToPotBps() external view returns (uint16) { return s.creditCostToPotBps; }
    function chosenComposeOn() external view returns (bool) { return s.chosenComposeOn; }
    function minCcToChoose() external view returns (uint96) { return s.minCcToChoose; }
    function paused() external view returns (bool) { return s.paused; }
    function pausedSince() external view returns (uint40) { return s.pausedSince; }
    function pausedTotal() external view returns (uint40) { return s.pausedTotal; }
    function composerOf(uint256 sid) external view returns (address) { return s.composerOf[sid]; }
    function payee() external view returns (address) { return s.payee; }
    function payeeOwed() external view returns (uint256) { return s.payeeOwed; }
    function payeeOn() external view returns (bool) { return s.payeeOn; }

    /// number of credits in the pile.
    function pileSize() external view returns (uint256) {
        return s.pile.size;
    }

    /// up to n credit ids of the pile, oldest first, after startAfter. zero starts at the head.
    function pilePage(uint256 startAfter, uint256 n) external view returns (uint256[] memory ids) {
        uint256 first = startAfter == 0 ? s.pile.head : s.credits[startAfter].next;
        // at most the pile size, so a huge n cannot blow up memory. the length is cut to the count found
        ids = new uint256[](n.min(s.pile.size));
        uint256 count;
        for (uint256 id = first; id != 0 && count < ids.length; id = s.credits[id].next) {
            ids[count++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    /// pile membership, cost basis and arrival time of a credit.
    function creditInfo(uint256 id) external view returns (bool inPile, uint256 cost, uint64 acquiredAt) {
        CoreLib.Credit storage c = s.credits[id];
        return (c.inPile, c.cost, c.acquiredAt);
    }

    /// whether the core holds a statement for sale or redemption, with its cost basis and compose time
    function statementInfo(uint256 sid) external view returns (bool held, uint256 cost, uint64 composedAt) {
        CoreLib.Statement storage st = s.statements[sid];
        return (st.held, st.cost, st.composedAt);
    }

    /// the seconds a held statement has aged outside every pause: the time since its compose minus the paused seconds
    /// accumulated since. a statement composed in a pause has age 0 at the resume. the controller prices by this age
    function statementAge(uint256 sid) external view returns (uint256) {
        CoreLib.Statement storage st = s.statements[sid];
        if (!st.held) revert NotForSale();
        return (block.timestamp - st.composedAt) - (pausedNow() - st.pauseMark);
    }

    /// the stored rating of a statement: the sum of its credits' scores, read from Statements at compose
    function ratingOf(uint256 sid) external view returns (uint256) {
        return s.statements[sid].rating;
    }

    /// every setting
    function settings() external view returns (Settings memory) {
        return s.settings;
    }

    /// every statement the core holds for sale or redemption.
    function heldStatements() external view returns (uint256[] memory sids) {
        return s.heldIds;
    }
}
