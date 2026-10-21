// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IBalanceModule, IRedemptionPolicy, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";

/// the treasury surface the tests drive, restated so the test compiles without via_ir
interface ITreasury is IBalanceModule {
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
    event CCRedeemed(
        address indexed burner,
        address indexed recipient,
        uint256 ccIn,
        uint256 balanceOut,
        uint256 claimReserve,
        uint256 ccSupply,
        uint64 configEpoch
    );
    event ClaimsReturned(uint256 amount, uint256 claimReserve, uint64 configEpoch);
    event TreasuryMigrated(address indexed successor, uint256 moved, uint256 claimsImported, uint64 configEpoch);

    function core() external view returns (address);
    function ccToken() external view returns (address);
    function predecessor() external view returns (address);
    function owner() external view returns (address);
    function custody() external view returns (uint256);
    function working() external view returns (uint256);
    function freeWorking() external view returns (uint256);
    function solvent() external view returns (bool);
    function selected() external view returns (bool);
    function selectedForClaims() external view returns (bool);
    function conversionReady() external view returns (bool);
    function transfersReady() external view returns (bool);
    function claimReserve() external view returns (uint256);
    function owed(address) external view returns (uint256);
    function totalOwed() external view returns (uint256);
    function minimumWorkingBalance() external view returns (uint256);
    function conversionToClaimBps() external view returns (uint16);
    function redemptionFeeBps() external view returns (uint16);
    function conversionEnabled() external view returns (bool);
    function workingPaymentsEnabled() external view returns (bool);
    function ccRedemptionEnabled() external view returns (bool);
    function redemptionPolicy() external view returns (address);
    function configEpoch() external view returns (uint64);
    function migrated() external view returns (bool);
    function quoteRedemption(uint256 ccIn)
        external
        view
        returns (uint256 balanceOut, uint256 reserve, uint256 supply, uint64 epoch, bool executable);
    function claim(address to) external returns (uint256);
    function redeemCC(
        uint256 ccIn,
        address recipient,
        uint256 minBalanceOut,
        uint256 deadline,
        uint64 expectedConfigEpoch
    ) external returns (uint256);
    function setSwitches(bool conversion, bool workingPayments, bool ccRedemption) external;
    function setConversionToClaimBps(uint16 v) external;
    function setRedemptionFeeBps(uint16 v) external;
    function setMinimumWorkingBalance(uint256 v) external;
    function setRedemptionPolicy(address policy) external;
    function fundClaims(uint256 amount) external returns (uint256);
    function allocateToClaims(uint256 amount) external;
    function returnClaimsToWorking(uint256 amount) external;
    function withdrawWorking(address to, uint256 amount) external;
    function rescueToken(address token, address to, uint256 amount) external;
    function migrateTo(address successor) external returns (uint256);
    function receiveMigration(uint256 claimAmount) external;
}

/// stand in for the Statements calls the treasury and the token make
contract Phase2StatementsDouble {
    mapping(uint256 => uint256) public creditScoreOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function set(uint256 id, address holder, uint256 score) external {
        ownerOf[id] = holder;
        creditScoreOf[id] = score;
    }

    function approve(address to, uint256 id) external {
        require(ownerOf[id] == msg.sender, "not owner");
        getApproved[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || getApproved[id] == msg.sender), "not allowed");
        ownerOf[id] = to;
        delete getApproved[id];
    }
}

/// the restricted coin's burn surface: burns from an account that approved the caller
contract CoinDouble is ERC20 {
    /// 0 burns, 1 burns half, 2 reverts
    uint8 public burnMode;

    function name() public pure override returns (string memory) {
        return "CC";
    }

    function symbol() public pure override returns (string memory) {
        return "CC";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurnMode(uint8 m) external {
        burnMode = m;
    }

    function burnFrom(address account, uint256 amount) external {
        if (burnMode == 2) revert("burn refused");
        _spendAllowance(account, msg.sender, amount);
        _burn(account, burnMode == 1 ? amount / 2 : amount);
    }
}

/// a policy that passes the treasury's probe and misbehaves on a live quote
contract RoguePolicy is IRedemptionPolicy {
    /// 0 honest, 1 quotes above the share, 2 reverts, 3 returns no data, 4 burns all gas
    uint8 public mode;
    bool public probeHonest = true;

    function set(uint8 m, bool honestProbe) external {
        mode = m;
        probeHonest = honestProbe;
    }

    function quote(uint256 ccIn, uint256 claimReserve, uint256 ccSupply, uint256) external view returns (uint256) {
        bool probe = ccIn == 1e18 && claimReserve == 1e18 && ccSupply == 4e18;
        if (probe && probeHonest) return 0.25e18;
        if (mode == 1) return claimReserve;
        if (mode == 2) revert("policy reverts");
        if (mode == 3) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == 4) {
            while (true) {}
        }
        return ccIn * claimReserve / ccSupply;
    }

    function isRedemptionPolicy() external pure returns (bool) {
        return true;
    }
}

/// a successor Core double: owner, coin, retirement, successor and the selected module
contract CoreDouble {
    address public owner;
    address public COIN;
    bool public retired;
    address public successor;
    address public balanceModule;

    constructor(address owner_, address coin_) {
        owner = owner_;
        COIN = coin_;
    }

    function select(address m) external {
        balanceModule = m;
    }
}

/// calls back into the treasury from inside a balance transfer
contract Reenterer {
    ITreasury public t;
    bytes public lastRevert;

    constructor(ITreasury t_) {
        t = t_;
    }

    function onTransfer(address, uint256) external {
        try t.claim(address(this)) {}
        catch (bytes memory r) {
            lastRevert = r;
        }
    }
}

/// the test contract is the Core double: the treasury reads its owner, coin, retirement and selected module from it
contract Phase2TreasuryTest is Test {
    using stdStorage for StdStorage;

    Phase2StatementsDouble internal statements;
    Phase2BalanceTokenStandin internal token;
    CoinDouble internal coin;
    IRedemptionPolicy internal policy;
    ITreasury internal t;

    address public owner = address(0xA11CE);
    address public balanceModule;
    bool public retired;
    /// the Core double's successor Core, zero until a test sets one
    address public successor;
    address internal seller = address(0xBEEF);
    address internal artist = address(0xA27);
    address internal burner = address(0xB0B);
    uint256 internal constant SUPPLY = 1e27;

    function COIN() external view returns (address) {
        return address(coin);
    }

    function setUp() public {
        vm.etch(Mainnet.STATEMENTS, address(new Phase2StatementsDouble()).code);
        statements = Phase2StatementsDouble(Mainnet.STATEMENTS);
        token = new Phase2BalanceTokenStandin();
        coin = new CoinDouble();
        coin.mint(address(0xD00D), SUPPLY);
        policy = IRedemptionPolicy(vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy"));
        t = _deploy(address(policy), address(0));
        balanceModule = address(t);
        vm.roll(100);
    }

    function _deploy(address policy_, address predecessor_) internal returns (ITreasury) {
        return ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(this), address(token), policy_, predecessor_)
            )
        );
    }

    /// everything open and on, working funds `working`, claim backing `claims`
    function _live(uint256 working, uint256 claims) internal {
        token.open();
        token.mint(address(t), working + claims);
        vm.startPrank(owner);
        t.setSwitches(true, true, true);
        if (claims != 0) t.allocateToClaims(claims);
        vm.stopPrank();
    }

    function _burnerWith(uint256 cc) internal {
        coin.mint(burner, cc);
        vm.prank(burner);
        coin.approve(address(t), type(uint256).max);
    }

    function _redeem(uint256 ccIn, uint256 minOut) internal returns (uint256) {
        uint64 epoch = t.configEpoch();
        vm.prank(burner);
        return t.redeemCC(ccIn, burner, minOut, block.timestamp, epoch);
    }

    // ------------------------------------------------------------------ deployment

    // promise: SPEC phase 2 the treasury binds the Core, its coin and the token and starts with every switch off, no claims and nothing available
    function test_deploymentIsDisabledAndBound() public view {
        assertEq(t.core(), address(this));
        assertEq(t.balanceToken(), address(token));
        assertEq(t.ccToken(), address(coin));
        assertEq(t.unitPerPoint(), 1e14);
        assertEq(t.owner(), owner);
        assertEq(t.predecessor(), address(0));
        assertFalse(t.conversionEnabled());
        assertFalse(t.workingPaymentsEnabled());
        assertFalse(t.ccRedemptionEnabled());
        assertEq(t.claimReserve(), 0);
        assertEq(t.conversionToClaimBps(), 300);
        assertEq(t.redemptionFeeBps(), 0);
        assertEq(t.redemptionPolicy(), address(policy));
        assertEq(t.configEpoch(), 1, "the policy set advanced the epoch once");
        assertEq(t.available(), 0);
        assertFalse(t.conversionReady());
        assertFalse(t.transfersReady());
        assertTrue(t.solvent());
    }

    // promise: SPEC phase 2 a wrong statements source, unit, decimals, coin or policy is refused at deployment
    function test_deploymentRefusesWrongBindings() public {
        Phase2BalanceTokenStandin bad = new Phase2BalanceTokenStandin();
        bad.configure(address(0x1234), 18);
        vm.expectRevert(ITreasury.InvalidConfiguration.selector);
        vm.deployCode(
            "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
            abi.encode(address(this), address(bad), address(policy), address(0))
        );
        bad.configure(Mainnet.STATEMENTS, 6);
        vm.expectRevert(ITreasury.InvalidConfiguration.selector);
        vm.deployCode(
            "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
            abi.encode(address(this), address(bad), address(policy), address(0))
        );
        vm.expectRevert(ITreasury.BadPolicy.selector);
        vm.deployCode(
            "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
            abi.encode(address(this), address(token), address(0xBAD), address(0))
        );
        RoguePolicy rogue = new RoguePolicy();
        rogue.set(1, false);
        vm.expectRevert(ITreasury.BadPolicy.selector);
        vm.deployCode(
            "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
            abi.encode(address(this), address(token), address(rogue), address(0))
        );
    }

    // ------------------------------------------------------------------ available

    // promise: SPEC phase 2 `available()` is zero until working payments are on, the treasury is selected and transfers are open, and it never reverts before selection
    function test_availableFailsClosedUntilEveryGateHolds() public {
        token.mint(address(t), 100 ether);
        assertEq(t.available(), 0, "switch off");
        vm.prank(owner);
        t.setSwitches(false, true, false);
        assertEq(t.available(), 0, "transfers not open");
        token.setGates(true, 3, 0);
        assertEq(t.available(), 0, "open block unset");
        token.setGates(true, 2, uint64(block.number));
        assertEq(t.available(), 0, "funding phase 2");
        token.setGates(false, 3, uint64(block.number));
        assertEq(t.available(), 0, "retirement not finalized");
        token.setGates(true, 3, uint64(block.number + 1));
        assertEq(t.available(), 0, "open block ahead");
        token.open();
        assertEq(t.available(), 100 ether, "every gate holds");
        balanceModule = address(0xDEAD);
        assertEq(t.available(), 0, "not the selected module");
        balanceModule = address(t);
        retired = true;
        assertEq(t.available(), 0, "core retired");
        retired = false;
        assertEq(t.available(), 100 ether);
    }

    // promise: SPEC phase 2 `available()` excludes the claim reserve, the recorded debt and the working floor
    function test_availableExcludesClaimsDebtAndFloor() public {
        _live(100 ether, 40 ether);
        assertEq(t.available(), 100 ether);
        vm.prank(owner);
        t.setMinimumWorkingBalance(30 ether);
        assertEq(t.available(), 70 ether);
        token.setMode(2);
        t.pay(seller, 10 ether);
        token.setMode(0);
        assertEq(t.owed(seller), 10 ether);
        assertEq(t.totalOwed(), 10 ether);
        assertEq(t.custody(), 140 ether, "nothing moved");
        assertEq(t.working(), 90 ether, "debt is reserved");
        assertEq(t.available(), 60 ether, "floor and debt both excluded");
        vm.prank(owner);
        t.setMinimumWorkingBalance(200 ether);
        assertEq(t.available(), 0, "the floor can close the bid");
    }

    // ------------------------------------------------------------------ conversion

    // promise: SPEC phase 2 a conversion measures its receipt, keeps every token here and earmarks 300 bps as claim backing
    function test_redeemEarmarksMeasuredReceipt() public {
        statements.set(7, address(t), 2_000_000);
        token.setGates(true, 0, 0);
        vm.prank(owner);
        t.setSwitches(true, false, false);
        assertTrue(t.conversionReady(), "conversion is ready before transfers open");
        assertFalse(t.transfersReady());
        vm.expectEmit(address(t));
        emit ITreasury.StatementConverted(7, 2e20, 6e18, 300, 6e18);
        uint256 out = t.redeem(7);
        assertEq(out, 2e20);
        assertEq(t.custody(), 2e20, "every token stays in custody");
        assertEq(t.claimReserve(), 6e18);
        assertEq(t.working(), 194e18);
        assertEq(statements.ownerOf(7), address(token), "the token took the statement");
        assertEq(t.available(), 0, "no working payment before transfers open");
    }

    // promise: SPEC phase 2 a conversion is refused by the switch, a wrong caller, a statement not held, a retired or deselected Core and a short receipt
    function test_redeemFailsClosed() public {
        statements.set(7, address(t), 2_000_000);
        token.setGates(true, 0, 0);
        vm.expectRevert(ITreasury.ConversionOff.selector);
        t.redeem(7);
        vm.prank(owner);
        t.setSwitches(true, false, false);
        vm.prank(seller);
        vm.expectRevert(ITreasury.OnlyCore.selector);
        t.redeem(7);
        vm.expectRevert(ITreasury.NotHeld.selector);
        t.redeem(8);
        balanceModule = seller;
        vm.expectRevert(ITreasury.ConversionOff.selector);
        t.redeem(7);
        balanceModule = address(t);
        retired = true;
        vm.expectRevert(ITreasury.ConversionOff.selector);
        t.redeem(7);
        retired = false;
        token.setShortfall(1);
        vm.expectRevert(ITreasury.RedeemedBelowRating.selector);
        t.redeem(7);
        token.setShortfall(0);
        vm.prank(owner);
        t.setConversionToClaimBps(0);
        t.redeem(7);
        assertEq(t.claimReserve(), 0, "a zero contribution earmarks nothing");
        assertEq(t.custody(), 2e20);
    }

    // ------------------------------------------------------------------ pay and claim

    // promise: SPEC phase 2 `pay` spends working funds only, records every shortfall as debt and `claim` pays the debt whatever the switches
    function test_payAccruesShortfallAndClaimPaysIt() public {
        _live(100 ether, 50 ether);
        vm.expectRevert(ITreasury.InsufficientAvailable.selector);
        t.pay(seller, 100 ether + 1);
        vm.prank(seller);
        vm.expectRevert(ITreasury.OnlyCore.selector);
        t.pay(seller, 1);
        t.pay(seller, 10 ether);
        assertEq(token.balanceOf(seller), 10 ether);
        // half delivered, false returned: the undelivered half is debt
        token.setMode(1);
        vm.expectEmit(address(t));
        emit ITreasury.PaymentAccrued(artist, 5 ether);
        t.pay(artist, 10 ether);
        assertEq(token.balanceOf(artist), 5 ether);
        assertEq(t.owed(artist), 5 ether);
        // reverting, silent and empty transfers accrue the whole amount
        token.setMode(2);
        t.pay(artist, 1 ether);
        token.setMode(3);
        t.pay(artist, 1 ether);
        token.setMode(5);
        t.pay(artist, 1 ether);
        token.setMode(0);
        assertEq(t.owed(artist), 8 ether);
        assertEq(t.totalOwed(), 8 ether);
        assertEq(t.claimReserve(), 50 ether, "claims untouched");
        vm.prank(owner);
        t.setSwitches(false, false, false);
        assertEq(t.claim(artist), 8 ether);
        assertEq(token.balanceOf(artist), 13 ether);
        assertEq(t.totalOwed(), 0);
        assertEq(t.claim(artist), 0);
    }

    // promise: SPEC phase 2 the accrual path of `pay` fits the Core's 600,000 gas artist bound with the transient lock
    function test_payAccrualFitsTheCoreArtistBound() public {
        _live(100 ether, 0);
        token.setMode(2);
        (bool ok,) = address(t).call{gas: 600_000}(abi.encodeCall(IBalanceModule.pay, (artist, 1 ether)));
        assertTrue(ok, "the bounded call completed");
        assertEq(t.owed(artist), 1 ether);
    }

    // ------------------------------------------------------------------ CC redemption

    // promise: SPEC phase 2 a burn of x pays floor(x * C / S) from the claim reserve, reduces the supply by exactly x and leaves working funds and debt untouched
    function test_redeemCCPaysTheProportionalShare() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        uint256 supply = coin.totalSupply();
        uint256 x = supply / 200; // 0.5 percent
        uint256 expected = x * 40 ether / supply;
        (uint256 q, uint256 c, uint256 s, uint64 e, bool exec) = t.quoteRedemption(x);
        assertEq(q, expected);
        assertEq(c, 40 ether);
        assertEq(s, supply);
        assertEq(e, 1);
        assertTrue(exec);
        vm.expectEmit(address(t));
        emit ITreasury.CCRedeemed(burner, burner, x, expected, 40 ether - expected, supply - x, 1);
        uint256 out = _redeem(x, expected);
        assertEq(out, expected);
        assertEq(token.balanceOf(burner), expected);
        assertEq(coin.totalSupply(), supply - x);
        assertEq(coin.balanceOf(burner), SUPPLY / 100 - x);
        assertEq(t.claimReserve(), 40 ether - expected);
        assertEq(t.working(), 100 ether, "working funds untouched");
        assertEq(t.available(), 100 ether);
        assertTrue(t.solvent());
    }

    // promise: SPEC phase 2 the backing per remaining token does not fall through sequential zero fee burns
    function test_sequentialBurnsPreserveBackingPerToken() public {
        _live(10 ether, 123_456_789 ether);
        _burnerWith(SUPPLY / 10);
        uint256 lastRate = t.claimReserve() * 1e36 / coin.totalSupply();
        uint256[5] memory sizes = [uint256(1), 1e18, 7_777_777_777_777, SUPPLY / 1000, SUPPLY / 33];
        for (uint256 i; i < sizes.length; ++i) {
            (uint256 q,,,,) = t.quoteRedemption(sizes[i]);
            if (q == 0) {
                uint64 epoch = t.configEpoch();
                vm.prank(burner);
                vm.expectRevert(ITreasury.ZeroAmount.selector);
                t.redeemCC(sizes[i], burner, 0, block.timestamp, epoch);
                continue;
            }
            _redeem(sizes[i], q);
            uint256 rate = t.claimReserve() * 1e36 / coin.totalSupply();
            assertGe(rate, lastRate, "backing per token fell");
            lastRate = rate;
        }
        assertTrue(t.solvent());
    }

    // promise: SPEC phase 2 the last holder can burn the whole supply for the whole reserve
    function test_lastHolderTakesTheWholeReserve() public {
        _live(5 ether, 9 ether);
        vm.prank(address(0xD00D));
        coin.transfer(burner, SUPPLY);
        vm.prank(burner);
        coin.approve(address(t), SUPPLY);
        uint256 out = _redeem(SUPPLY, 9 ether);
        assertEq(out, 9 ether);
        assertEq(coin.totalSupply(), 0);
        assertEq(t.claimReserve(), 0);
        (,,,, bool exec) = t.quoteRedemption(1);
        assertFalse(exec, "nothing to burn against a zero supply");
    }

    // promise: SPEC phase 2 a burn is refused when expired, on a stale epoch, with a switch off, before transfers open, deselected, for a bad recipient, a zero or oversized input, a zero output or a missed minimum
    function test_redeemCCFailsClosed() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        uint256 x = SUPPLY / 1000;
        uint64 epoch = t.configEpoch();
        vm.startPrank(burner);
        vm.expectRevert(ITreasury.Expired.selector);
        t.redeemCC(x, burner, 0, block.timestamp - 1, epoch);
        vm.expectRevert(ITreasury.StaleEpoch.selector);
        t.redeemCC(x, burner, 0, block.timestamp, epoch + 1);
        vm.expectRevert(ITreasury.InvalidRecipient.selector);
        t.redeemCC(x, address(0), 0, block.timestamp, epoch);
        vm.expectRevert(ITreasury.InvalidRecipient.selector);
        t.redeemCC(x, address(t), 0, block.timestamp, epoch);
        vm.expectRevert(ITreasury.InvalidAmount.selector);
        t.redeemCC(0, burner, 0, block.timestamp, epoch);
        uint256 live = coin.totalSupply();
        vm.expectRevert(ITreasury.InvalidAmount.selector);
        t.redeemCC(live + 1, burner, 0, block.timestamp, epoch);
        vm.expectRevert(ITreasury.ZeroAmount.selector);
        t.redeemCC(1, burner, 0, block.timestamp, epoch);
        vm.expectRevert(ITreasury.Slippage.selector);
        t.redeemCC(x, burner, x * 40 ether / SUPPLY + 1, block.timestamp, epoch);
        vm.stopPrank();
        vm.prank(owner);
        t.setSwitches(true, true, false);
        vm.prank(burner);
        vm.expectRevert(ITreasury.RedemptionOff.selector);
        t.redeemCC(x, burner, 0, block.timestamp, epoch);
        vm.prank(owner);
        t.setSwitches(true, true, true);
        token.setGates(true, 3, uint64(block.number + 10));
        (,,,, bool exec) = t.quoteRedemption(x);
        assertFalse(exec);
        vm.prank(burner);
        vm.expectRevert(ITreasury.RedemptionOff.selector);
        t.redeemCC(x, burner, 0, block.timestamp, epoch);
        token.open();
        balanceModule = seller;
        vm.prank(burner);
        vm.expectRevert(ITreasury.RedemptionOff.selector);
        t.redeemCC(x, burner, 0, block.timestamp, epoch);
        balanceModule = address(t);
        assertEq(coin.totalSupply(), SUPPLY + SUPPLY / 100, "nothing burned");
        assertEq(t.claimReserve(), 40 ether);
    }

    // promise: SPEC phase 2 a short, silent or failed payment and a short or failed burn revert the whole redemption
    function test_redeemCCRevertsOnShortPaymentOrBurn() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        uint256 x = SUPPLY / 1000;
        uint256 supply = coin.totalSupply();
        uint8[3] memory modes = [1, 2, 5];
        uint64 epoch = t.configEpoch();
        for (uint256 i; i < modes.length; ++i) {
            token.setMode(modes[i]);
            vm.prank(burner);
            // a false return or a revert fails the safe transfer; a silent no-op fails the custody check
            if (modes[i] == 5) vm.expectRevert(ITreasury.ShortPayment.selector);
            else vm.expectRevert();
            t.redeemCC(x, burner, 0, block.timestamp, epoch);
        }
        token.setMode(0);
        coin.setBurnMode(1);
        vm.prank(burner);
        vm.expectRevert(ITreasury.BurnMismatch.selector);
        t.redeemCC(x, burner, 0, block.timestamp, epoch);
        coin.setBurnMode(2);
        vm.prank(burner);
        vm.expectRevert(bytes("burn refused"));
        t.redeemCC(x, burner, 0, block.timestamp, epoch);
        coin.setBurnMode(0);
        assertEq(coin.totalSupply(), supply);
        assertEq(t.claimReserve(), 40 ether);
        assertEq(t.custody(), 140 ether);
        assertEq(token.balanceOf(burner), 0);
        _redeem(x, 0);
        assertEq(coin.totalSupply(), supply - x, "the honest path still works");
    }

    // promise: SPEC phase 2 a reentering token callback cannot enter a second outflow: the inner call reverts `Reentrant` and the outer call settles once
    function test_reentrantCallbackIsRefused() public {
        _live(100 ether, 40 ether);
        Reenterer r = new Reenterer(t);
        token.setReentrant(address(r));
        // pay records the undelivered amount for a recipient whose callback tries to claim
        t.pay(seller, 1 ether);
        assertEq(r.lastRevert(), abi.encodeWithSelector(ITreasury.Reentrant.selector), "the inner claim was refused");
        assertEq(token.balanceOf(seller), 1 ether, "the outer payment completed");
        assertEq(t.owed(seller), 0);
        // a burn whose payment callback reenters still settles once
        _burnerWith(SUPPLY / 100);
        uint256 x = SUPPLY / 1000;
        uint256 out = _redeem(x, 0);
        assertEq(r.lastRevert(), abi.encodeWithSelector(ITreasury.Reentrant.selector));
        assertEq(token.balanceOf(burner), out);
        assertEq(t.claimReserve(), 40 ether - out);
    }

    // promise: SPEC phase 2 a policy that quotes above the share, reverts, answers short or exhausts its gas fails closed without trapping the owner's controls
    function test_badPolicyFailsClosed() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        RoguePolicy rogue = new RoguePolicy();
        vm.prank(owner);
        t.setRedemptionPolicy(address(rogue));
        assertFalse(t.ccRedemptionEnabled(), "a policy change turns redemption off");
        uint64 epoch = t.configEpoch();
        assertEq(epoch, 2);
        vm.prank(owner);
        t.setSwitches(true, true, true);
        uint256 x = SUPPLY / 1000;
        for (uint8 m = 1; m <= 4; ++m) {
            rogue.set(m, true);
            (uint256 q,,,, bool exec) = t.quoteRedemption(x);
            assertEq(q, 0, "the view refuses it");
            assertFalse(exec);
            vm.prank(burner);
            vm.expectRevert(ITreasury.BadPolicy.selector);
            t.redeemCC(x, burner, 0, block.timestamp, epoch);
        }
        rogue.set(0, true);
        uint256 share = x * 40 ether / coin.totalSupply();
        assertEq(_redeem(x, share), share, "an honest quote executes at the share");
        // the owner can always replace it
        vm.prank(owner);
        t.setRedemptionPolicy(address(policy));
        assertEq(t.configEpoch(), 3);
        vm.prank(burner);
        vm.expectRevert(ITreasury.StaleEpoch.selector);
        t.redeemCC(x, burner, 0, block.timestamp, 2);
    }

    // promise: SPEC phase 2 a redemption fee stays in the claim reserve and advances the epoch
    function test_redemptionFeeStaysInTheReserve() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        vm.prank(owner);
        t.setRedemptionFeeBps(1_000);
        assertEq(t.configEpoch(), 2);
        uint256 x = SUPPLY / 1000;
        uint256 share = x * 40 ether / coin.totalSupply();
        uint256 out = _redeem(x, 0);
        assertEq(out, share * 9 / 10);
        assertEq(t.claimReserve(), 40 ether - out, "the fee is still backing");
        assertEq(t.working(), 100 ether, "the fee did not become working funds");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITreasury.BadSetting.selector, bytes32("redemptionFeeBps")));
        t.setRedemptionFeeBps(10_001);
    }

    // promise: SPEC phase 2 a burn against an insolvent ledger is refused
    function test_redeemCCRefusesInsolvency() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        stdstore.target(address(t)).sig("claimReserve()").checked_write(uint256(150 ether));
        assertFalse(t.solvent());
        assertEq(t.available(), 0, "an insolvent ledger has no working funds");
        uint64 epoch = t.configEpoch();
        vm.prank(burner);
        vm.expectRevert(ITreasury.Insolvent.selector);
        t.redeemCC(SUPPLY / 1000, burner, 0, block.timestamp, epoch);
    }

    // ------------------------------------------------------------------ owner controls

    // promise: SPEC phase 2 every control is owner only, bounded, evented, and the claim ledger moves only by explicit actions
    function test_ownerControls() public {
        token.open();
        token.mint(address(t), 100 ether);
        vm.expectRevert(ITreasury.OnlyOwner.selector);
        t.setSwitches(true, true, true);
        vm.expectRevert(ITreasury.OnlyOwner.selector);
        t.allocateToClaims(1);
        vm.expectRevert(ITreasury.OnlyOwner.selector);
        t.withdrawWorking(seller, 1);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITreasury.BadSetting.selector, bytes32("conversionToClaimBps")));
        t.setConversionToClaimBps(10_001);
        t.setConversionToClaimBps(10_000);
        assertEq(t.conversionToClaimBps(), 10_000);
        // allocation is bounded by free working funds after the floor
        t.setMinimumWorkingBalance(30 ether);
        vm.expectRevert(ITreasury.InsufficientWorking.selector);
        t.allocateToClaims(70 ether + 1);
        t.allocateToClaims(70 ether);
        assertEq(t.claimReserve(), 70 ether);
        assertEq(t.freeWorking(), 0);
        // funding is by measured receipt
        token.mint(owner, 10 ether);
        token.approve(address(t), 10 ether);
        assertEq(t.fundClaims(10 ether), 10 ether);
        assertEq(t.claimReserve(), 80 ether);
        // returning claims needs redemption off and advances the epoch
        t.setSwitches(false, false, true);
        vm.expectRevert(ITreasury.RedemptionEnabled.selector);
        t.returnClaimsToWorking(1);
        t.setSwitches(false, false, false);
        vm.expectRevert(ITreasury.InsufficientClaims.selector);
        t.returnClaimsToWorking(80 ether + 1);
        vm.expectEmit(address(t));
        emit ITreasury.ClaimsReturned(50 ether, 30 ether, 2);
        t.returnClaimsToWorking(50 ether);
        assertEq(t.configEpoch(), 2);
        // withdrawal takes free working funds only
        assertEq(t.freeWorking(), 50 ether);
        vm.expectRevert(ITreasury.InsufficientWorking.selector);
        t.withdrawWorking(seller, 50 ether + 1);
        vm.expectRevert(ITreasury.InvalidRecipient.selector);
        t.withdrawWorking(address(0), 1);
        t.withdrawWorking(seller, 50 ether);
        assertEq(token.balanceOf(seller), 50 ether);
        assertEq(t.custody(), 60 ether);
        assertEq(t.claimReserve(), 30 ether);
        assertTrue(t.solvent());
        // rescue refuses the protected assets
        vm.expectRevert(ITreasury.ProtectedAsset.selector);
        t.rescueToken(address(token), owner, 1);
        vm.expectRevert(ITreasury.ProtectedAsset.selector);
        t.rescueToken(address(coin), owner, 1);
        vm.expectRevert(ITreasury.ProtectedAsset.selector);
        t.rescueToken(Mainnet.STATEMENTS, owner, 1);
        CoinDouble stray = new CoinDouble();
        stray.mint(address(t), 5);
        t.rescueToken(address(stray), owner, 5);
        assertEq(stray.balanceOf(owner), 5);
        vm.stopPrank();
    }

    // promise: SPEC phase 2 claim funding and allocation are refused while CC has no supply
    function test_claimFundingNeedsSupply() public {
        token.open();
        token.mint(address(t), 10 ether);
        vm.prank(address(0xD00D));
        coin.transfer(burner, SUPPLY);
        vm.prank(burner);
        coin.approve(address(t), SUPPLY);
        _live(0, 0);
        vm.prank(owner);
        t.allocateToClaims(1 ether);
        _redeem(SUPPLY, 0);
        assertEq(coin.totalSupply(), 0);
        vm.prank(owner);
        vm.expectRevert(ITreasury.ZeroSupply.selector);
        t.allocateToClaims(1 ether);
    }

    // ------------------------------------------------------------------ migration

    // promise: SPEC phase 2 a migration moves custody less the debt, imports the claim reserve, leaves the debt payable and refuses every switch on the source afterwards
    function test_migrationPreservesClaimsAndLeavesDebtFunded() public {
        _live(100 ether, 40 ether);
        token.setMode(2);
        t.pay(artist, 7 ether);
        token.setMode(0);
        ITreasury next = _deploy(address(policy), address(t));
        vm.prank(owner);
        vm.expectRevert(ITreasury.SwitchesOn.selector);
        t.migrateTo(address(next));
        vm.startPrank(owner);
        t.setSwitches(false, false, false);
        vm.expectEmit(address(t));
        emit ITreasury.TreasuryMigrated(address(next), 133 ether, 40 ether, 2);
        assertEq(t.migrateTo(address(next)), 133 ether);
        vm.stopPrank();
        assertTrue(t.migrated());
        assertEq(t.claimReserve(), 0);
        assertEq(t.custody(), 7 ether, "the debt stays funded");
        assertEq(next.custody(), 133 ether);
        assertEq(next.claimReserve(), 40 ether, "claims imported, not working funds");
        assertEq(next.working(), 93 ether);
        assertEq(next.configEpoch(), 2);
        assertTrue(next.solvent());
        vm.prank(owner);
        vm.expectRevert(ITreasury.Migrated.selector);
        t.setSwitches(true, false, false);
        vm.prank(owner);
        vm.expectRevert(ITreasury.Migrated.selector);
        t.migrateTo(address(next));
        assertEq(t.available(), 0);
        assertEq(t.claim(artist), 7 ether);
        assertEq(token.balanceOf(artist), 7 ether);
        // the successor becomes the selected module and redeems against the imported reserve
        balanceModule = address(next);
        vm.prank(owner);
        next.setSwitches(true, true, true);
        _burnerWith(SUPPLY / 100);
        vm.prank(burner);
        coin.approve(address(next), type(uint256).max);
        uint256 x = SUPPLY / 1000;
        uint64 nextEpoch = next.configEpoch();
        vm.prank(burner);
        uint256 out = next.redeemCC(x, burner, 0, block.timestamp, nextEpoch);
        assertEq(out, x * 40 ether / (SUPPLY + SUPPLY / 100));
        // a late inflow to the source is working funds, withdrawable, never a new reserve
        token.mint(address(t), 3 ether);
        assertEq(t.working(), 3 ether);
        vm.prank(owner);
        t.withdrawWorking(owner, 3 ether);
        assertEq(token.balanceOf(owner), 3 ether);
    }

    // promise: SPEC phase 2 a successor with another Core, coin, token or predecessor, or one already migrated, is refused, and only the predecessor can import
    function test_migrationRefusesWrongSuccessor() public {
        _live(10 ether, 4 ether);
        vm.prank(owner);
        t.setSwitches(false, false, false);
        ITreasury wrongPredecessor = _deploy(address(policy), address(0));
        vm.prank(owner);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(address(wrongPredecessor));
        vm.prank(owner);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(address(t));
        vm.prank(owner);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(seller);
        ITreasury next = _deploy(address(policy), address(t));
        vm.expectRevert(ITreasury.OnlyPredecessor.selector);
        next.receiveMigration(1);
        vm.prank(address(t));
        vm.expectRevert(ITreasury.Insolvent.selector);
        next.receiveMigration(1);
        // an unfunded claim reserve cannot move
        stdstore.target(address(t)).sig("claimReserve()").checked_write(uint256(50 ether));
        vm.prank(owner);
        vm.expectRevert(ITreasury.Insolvent.selector);
        t.migrateTo(address(next));
        stdstore.target(address(t)).sig("claimReserve()").checked_write(uint256(4 ether));
        vm.prank(owner);
        t.migrateTo(address(next));
        ITreasury third = _deploy(address(policy), address(next));
        vm.prank(owner);
        next.setSwitches(true, false, false);
        vm.prank(owner);
        vm.expectRevert(ITreasury.SwitchesOn.selector);
        next.migrateTo(address(third));
    }
}

contract Phase2TreasuryRetirementTest is Phase2TreasuryTest {
    // promise: SPEC phase 2 a retired Core closes conversions and working payments but not CC burns, and the reserve can migrate to a treasury of the Core's successor
    function test_retiredCoreKeepsBurnsOpenAndMigratesToTheSuccessorCore() public {
        _live(100 ether, 40 ether);
        _burnerWith(SUPPLY / 100);
        retired = true;
        assertFalse(t.selected());
        assertTrue(t.selectedForClaims());
        assertEq(t.available(), 0, "no working payments after retirement");
        assertFalse(t.conversionReady());
        uint256 x = SUPPLY / 1000;
        uint256 share = x * 40 ether / coin.totalSupply();
        assertEq(_redeem(x, share), share, "a burn still pays after retirement");
        // a successor treasury bound to the successor Core is accepted only once this Core has retired and names it
        CoreDouble heir = new CoreDouble(owner, address(coin));
        ITreasury next = ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(heir), address(token), address(policy), address(t))
            )
        );
        vm.prank(owner);
        t.setSwitches(false, false, false);
        vm.prank(owner);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(address(next));
        successor = address(heir);
        retired = false;
        vm.prank(owner);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(address(next));
        retired = true;
        vm.prank(owner);
        t.migrateTo(address(next));
        assertEq(next.claimReserve(), 40 ether - share);
        assertTrue(t.migrated());
        heir.select(address(next));
        vm.prank(owner);
        next.setSwitches(false, false, true);
        vm.prank(burner);
        coin.approve(address(next), type(uint256).max);
        uint64 epoch = next.configEpoch();
        vm.prank(burner);
        assertGt(next.redeemCC(x, burner, 0, block.timestamp, epoch), 0, "burns continue on the successor");
    }

    // promise: SPEC phase 2 a successor with a switch on is refused
    function test_migrationRefusesAnEnabledSuccessor() public {
        _live(10 ether, 4 ether);
        ITreasury next = _deploy(address(policy), address(t));
        vm.startPrank(owner);
        t.setSwitches(false, false, false);
        next.setSwitches(false, true, false);
        vm.expectRevert(ITreasury.InvalidSuccessor.selector);
        t.migrateTo(address(next));
        next.setSwitches(false, false, false);
        t.migrateTo(address(next));
        vm.stopPrank();
        assertEq(next.claimReserve(), 4 ether);
    }

    // promise: SPEC phase 2 the quote follows actual contributions and independent burns
    function test_quoteFollowsContributionsAndIndependentBurns() public {
        _live(100 ether, 40 ether);
        uint256 x = SUPPLY / 1000;
        (uint256 q0,,,,) = t.quoteRedemption(x);
        statements.set(7, address(t), 2_000_000);
        t.redeem(7);
        (uint256 q1, uint256 c1,,,) = t.quoteRedemption(x);
        assertEq(c1, 40 ether + 6e18);
        assertGt(q1, q0, "a conversion's earmark raises the quote");
        vm.startPrank(address(0xD00D));
        coin.approve(address(0xD00D), SUPPLY / 2);
        coin.burnFrom(address(0xD00D), SUPPLY / 2);
        vm.stopPrank();
        (uint256 q2,, uint256 s2,,) = t.quoteRedemption(x);
        assertEq(s2, SUPPLY / 2);
        assertEq(q2, q1 * 2, "an independent burn doubles the share of every token");
    }
}

contract ProRataPolicyTest is Test {
    IRedemptionPolicy internal p;

    function setUp() public {
        p = IRedemptionPolicy(vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy"));
    }

    // promise: SPEC phase 2 the V1 policy is floor(x * C / S) less the fee, full precision, and refuses zero, oversized and overfee inputs
    function test_quoteIsProportional() public {
        assertEq(p.quote(1e27, 100 ether, 1e27, 0), 100 ether);
        assertEq(p.quote(1, 100 ether, 1e27, 0), 0);
        assertEq(p.quote(5e24, 100 ether, 1e27, 0), 0.5 ether);
        assertEq(p.quote(5e24, 100 ether, 1e27, 1_000), 0.45 ether);
        assertEq(p.quote(type(uint256).max / 2, type(uint256).max / 3, type(uint256).max, 0), type(uint256).max / 6);
        assertTrue(p.isRedemptionPolicy());
        vm.expectRevert(bytes4(keccak256("ZeroInput()")));
        p.quote(0, 1, 1, 0);
        vm.expectRevert(bytes4(keccak256("ZeroInput()")));
        p.quote(1, 1, 0, 0);
        vm.expectRevert(bytes4(keccak256("InputAboveSupply()")));
        p.quote(2, 1, 1, 0);
        vm.expectRevert(bytes4(keccak256("BadFee()")));
        p.quote(1, 1, 1, 10_001);
    }
}
