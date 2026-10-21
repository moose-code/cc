// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IRedemptionPolicy, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {ITreasury, Phase2StatementsDouble, CoinDouble, FixedQuotePolicy} from "../Phase2Treasury.t.sol";
import {Phase2BalanceTokenStandin} from "../standins/Phase2BalanceTokenStandin.sol";

/// the handler is the Core double of its treasuries: it answers owner, coin, retirement and the selected module, and it
/// is the only caller of `redeem` and `pay`. it interleaves funding, conversions, payments with every token fault mode,
/// debt claims, CC burns through a policy it steers around the share and the bid budget, independent burns, owner
/// settings including the bid budget, time passing, reallocations, withdrawals and one migration, and keeps the ledger
/// ghosts the invariants compare against
contract Phase2TreasuryHandler {
    Phase2StatementsDouble public statements;
    Phase2BalanceTokenStandin public token;
    CoinDouble public coin;
    /// the policy of every treasury: the handler sets its answer before each burn
    FixedQuotePolicy public policy;
    ITreasury public source;
    ITreasury public current;
    address public owner = address(0xA11CE);
    address public balanceModule;
    bool public retired;
    address public burner = address(0xB0B);
    address public holder = address(0xD00D);
    uint256 public nextStatement = 1;

    // ghosts: the claim ledger of every treasury, and the burn path
    uint256 public claimsIn; // conversions, allocations, funding, imports
    uint256 public claimsReturned;
    uint256 public claimsPaidByBurns;
    uint256 public ccBurnedByTreasury;
    uint256 public successfulBurns;
    /// burns paid above the larger of floor(x * C / S) and the bid budget of the pre burn snapshot, or above the reserve:
    /// must stay zero
    uint256 public capViolations;
    /// burns paid above floor(x * C / S) while the budget was zero: must stay zero
    uint256 public shareViolations;
    /// burns paid above the share from the bid budget
    uint256 public bidsPaid;
    uint256 public successfulConversions;
    uint256 public successfulPays;
    uint256 public debtAccruals;
    /// the backing per token after the last owner action that may lower it or the last bid paid above the share from
    /// the owner's budget, times 1e36
    uint256 public rateFloor;
    bool public migratedOnce;

    function COIN() external view returns (address) {
        return address(coin);
    }

    constructor() {
        statements = Phase2StatementsDouble(Mainnet.STATEMENTS);
        token = new Phase2BalanceTokenStandin();
        coin = new CoinDouble();
        coin.mint(holder, 1e27);
        policy = new FixedQuotePolicy();
    }

    /// the treasuries bind this handler as their Core, which needs code: deployed after construction
    function init() external {
        require(address(source) == address(0), "initialized");
        source = _deployTreasury(address(0));
        current = source;
        balanceModule = address(source);
        token.open();
        _asOwner().setSwitches(true, true, true);
        _refreshRateFloor();
    }

    function _deployTreasury(address predecessor) private returns (ITreasury t) {
        bytes memory init = abi.encodePacked(
            _code("Phase2BalanceTreasury"), abi.encode(address(this), address(token), address(policy), predecessor)
        );
        address a;
        assembly ("memory-safe") {
            a := create(0, add(init, 32), mload(init))
        }
        require(a != address(0), "treasury");
        t = ITreasury(a);
    }

    function _code(string memory name) private view returns (bytes memory) {
        return
            VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).getCode(string.concat(name, ".sol:", name));
    }

    function _asOwner() private returns (ITreasury) {
        VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(owner);
        return current;
    }

    function _refreshRateFloor() private {
        uint256 s = coin.totalSupply();
        rateFloor = s == 0 ? 0 : current.claimReserve() * 1e36 / s;
    }

    // ------------------------------------------------------------------ actions

    /// an unsolicited transfer: working funds
    function fund(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        token.mint(address(current), amount);
    }

    /// a conversion of a statement held by the treasury, as the Core
    function convert(uint256 score) external {
        score = bound(score, 800_000, 80_000_000);
        uint256 id = nextStatement++;
        statements.set(id, address(current), score);
        uint256 reserveBefore = current.claimReserve();
        try current.redeem(id) returns (uint256 out) {
            require(out == score * 1e14, "receipt");
            claimsIn += current.claimReserve() - reserveBefore;
            ++successfulConversions;
        } catch {}
    }

    /// a Core payment under a random token fault mode, within or just above `available()`
    function pay(address to, uint256 amount, uint8 mode) external {
        if (to == address(0) || to == address(current) || to == address(token)) to = burner;
        mode = uint8(bound(mode, 0, 5));
        uint256 avail = current.available();
        amount = bound(amount, 0, avail + 1);
        token.setMode(mode == 4 ? 0 : mode);
        uint256 debtBefore = current.totalOwed();
        try current.pay(to, amount) {
            ++successfulPays;
            if (current.totalOwed() > debtBefore) ++debtAccruals;
        } catch {}
        token.setMode(0);
    }

    function claimDebt(address to) external {
        current.claim(to);
    }

    /// the pre burn snapshot a paid burn is checked against
    struct BurnSnapshot {
        uint256 supply;
        uint256 reserve;
        uint256 share;
        uint256 budget;
        uint256 cap;
        uint128 carried;
        uint40 time;
    }

    /// a CC burn against the live quote, the policy answering the share, under it, a bid within the budget or above the
    /// cap. when the quote says executable the burn must succeed with exactly that output
    function burn(uint256 ccIn, uint256 bid) external {
        ccIn = bound(ccIn, 1, 1e25);
        VmLike vm = VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
        uint256 held = coin.balanceOf(burner);
        if (held < ccIn) {
            vm.prank(holder);
            coin.transfer(burner, ccIn - held);
        }
        vm.prank(burner);
        coin.approve(address(current), ccIn);
        BurnSnapshot memory s = _answer(ccIn, bid);
        (uint256 q,,, uint64 epoch, bool exec) = current.quoteRedemption(ccIn);
        vm.prank(burner);
        try current.redeemCC(ccIn, burner, q, block.timestamp, epoch) returns (uint256 out) {
            require(exec && out == q, "a burn executed against a non executable or different quote");
            _checkPaid(ccIn, out, s);
        } catch {
            require(!exec || q == 0, "an executable quote failed to execute");
        }
    }

    /// sets the policy's answer from the live terms and keeps the snapshot
    function _answer(uint256 ccIn, uint256 bid) private returns (BurnSnapshot memory s) {
        (s.share, s.budget, s.cap) = current.redemptionTerms(ccIn);
        s.supply = coin.totalSupply();
        s.reserve = current.claimReserve();
        s.carried = current.bidBudgetCarried();
        s.time = current.bidBudgetTime();
        uint256 kind = bid % 4;
        uint256 answer = s.share;
        if (kind == 1) answer = bound(bid / 4, 0, s.share);
        else if (kind == 2) answer = bound(bid / 4, s.share, s.cap);
        else if (kind == 3) answer = s.cap + 1;
        policy.set(answer);
    }

    function _checkPaid(uint256 ccIn, uint256 out, BurnSnapshot memory s) private {
        require(coin.totalSupply() == s.supply - ccIn, "supply");
        if (out > s.cap || out > s.reserve) ++capViolations;
        if (s.budget == 0 && out > s.share) ++shareViolations;
        require(current.claimReserve() == s.reserve - out, "the reserve fell by exactly the payout");
        if (out > s.share) {
            require(current.bidBudgetAvailable() == s.budget - out, "the whole payment left the budget");
            ++bidsPaid;
            _refreshRateFloor();
        } else {
            require(
                current.bidBudgetCarried() == s.carried && current.bidBudgetTime() == s.time,
                "a payment within the share touched the budget"
            );
        }
        claimsPaidByBurns += out;
        ccBurnedByTreasury += ccIn;
        ++successfulBurns;
    }

    /// a burn outside the treasury: the backing per remaining token rises
    function independentBurn(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        if (coin.balanceOf(holder) < amount) return;
        VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(holder);
        coin.approve(holder, amount);
        VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(holder);
        coin.burnFrom(holder, amount);
    }

    // owner actions. each that can lower a burner's terms refreshes the rate floor after it runs

    function allocate(uint256 amount) external {
        amount = bound(amount, 0, current.freeWorking() + 1);
        uint256 before = current.claimReserve();
        try _asOwner().allocateToClaims(amount) {
            claimsIn += current.claimReserve() - before;
        } catch {}
    }

    function fundClaims(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        token.mint(owner, amount);
        VmLike vm = VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
        vm.prank(owner);
        token.approve(address(current), amount);
        uint256 before = current.claimReserve();
        try _asOwner().fundClaims(amount) {
            claimsIn += current.claimReserve() - before;
        } catch {}
    }

    function returnClaims(uint256 amount) external {
        amount = bound(amount, 0, current.claimReserve() + 1);
        bool conv = current.conversionEnabled();
        bool work = current.workingPaymentsEnabled();
        _asOwner().setSwitches(conv, work, false);
        uint256 before = current.claimReserve();
        try _asOwner().returnClaimsToWorking(amount) {
            claimsReturned += before - current.claimReserve();
        } catch {}
        _asOwner().setSwitches(conv, work, true);
        _refreshRateFloor();
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, current.freeWorking() + 1);
        try _asOwner().withdrawWorking(owner, amount) {} catch {}
    }

    function setFee(uint16 bps) external {
        bps = uint16(bound(bps, 0, 10_000));
        _asOwner().setRedemptionFeeBps(bps);
    }

    function setContribution(uint16 bps) external {
        bps = uint16(bound(bps, 0, 10_000));
        _asOwner().setConversionToClaimBps(bps);
    }

    function setFloor(uint256 v) external {
        v = bound(v, 0, 1e24);
        _asOwner().setMinimumWorkingBalance(v);
    }

    /// the standing bid budget: a positive bounded rate under a bounded maximum, or off
    function setBidBudget(uint256 perDay, uint256 max_, bool off) external {
        if (off) {
            perDay = 0;
            max_ = 0;
        } else {
            max_ = bound(max_, 1e18, 1e24);
            perDay = bound(perDay, 1e18, max_);
        }
        _asOwner().setBidBudget(uint128(perDay), uint128(max_));
    }

    /// time passes, an hour to a week, so the budget accrues
    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 7 days);
        VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).warp(block.timestamp + secs);
    }

    function toggle(bool a, bool b, bool c) external {
        _asOwner().setSwitches(a, b, c);
    }

    /// one migration to a fresh successor; later actions run on the successor
    function migrate() external {
        if (migratedOnce) return;
        ITreasury next = _deployTreasury(address(current));
        _asOwner().setSwitches(false, false, false);
        uint256 claims = current.claimReserve();
        // the Core selects the successor first; the reserve never moves to an unselected treasury
        balanceModule = address(next);
        try _asOwner().migrateTo(address(next)) {
            require(next.claimReserve() == claims, "claims imported");
            require(current.claimReserve() == 0 && current.migrated(), "source closed");
            current = next;
            migratedOnce = true;
            _asOwner().setSwitches(true, true, true);
            _refreshRateFloor();
        } catch {
            balanceModule = address(current);
            _asOwner().setSwitches(true, true, true);
        }
    }

    function bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) return lo;
        return lo + (x % (hi - lo + 1));
    }
}

interface VmLike {
    function prank(address) external;
    function warp(uint256) external;
    function getCode(string calldata) external view returns (bytes memory);
}

contract InvariantsPhase2TreasuryTest is Test {
    Phase2TreasuryHandler internal h;

    function setUp() public {
        vm.etch(Mainnet.STATEMENTS, address(new Phase2StatementsDouble()).code);
        h = new Phase2TreasuryHandler();
        h.init();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = h.fund.selector;
        selectors[1] = h.convert.selector;
        selectors[2] = h.pay.selector;
        selectors[3] = h.claimDebt.selector;
        selectors[4] = h.burn.selector;
        selectors[5] = h.independentBurn.selector;
        selectors[6] = h.allocate.selector;
        selectors[7] = h.fundClaims.selector;
        selectors[8] = h.returnClaims.selector;
        selectors[9] = h.withdraw.selector;
        selectors[10] = h.setFee.selector;
        selectors[11] = h.setContribution.selector;
        selectors[12] = h.setFloor.selector;
        selectors[13] = h.toggle.selector;
        selectors[14] = h.migrate.selector;
        selectors[15] = h.setBidBudget.selector;
        selectors[16] = h.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    function _each() internal view returns (ITreasury[2] memory ts, uint256 n) {
        ts[0] = h.source();
        n = 1;
        if (address(h.current()) != address(h.source())) {
            ts[1] = h.current();
            n = 2;
        }
    }

    // promise: SPEC phase 2 custody covers the claim reserve and the recorded debt in every treasury at every step
    function invariant_custodyCoversClaimsAndDebt() public view {
        (ITreasury[2] memory ts, uint256 n) = _each();
        for (uint256 i; i < n; ++i) {
            assertGe(ts[i].custody(), ts[i].claimReserve() + ts[i].totalOwed(), "custody under claims plus debt");
            assertTrue(ts[i].solvent());
            assertLe(ts[i].available(), ts[i].working(), "available above working");
        }
    }

    // promise: SPEC phase 2 the claim ledger moves only through conversions, owner funding, imports, owner returns and actual CC burns
    function invariant_claimLedgerIsExplicit() public view {
        (ITreasury[2] memory ts, uint256 n) = _each();
        uint256 reserve;
        for (uint256 i; i < n; ++i) {
            reserve += ts[i].claimReserve();
        }
        assertEq(reserve, h.claimsIn() - h.claimsReturned() - h.claimsPaidByBurns(), "claim ledger identity");
    }

    // promise: SPEC phase 2 balance leaves the claim reserve only alongside a CC burn, no burn pays more than the larger of floor(x * C / S) and the bid budget of the pre burn snapshot nor more than the reserve, and without a budget no burn pays more than the share
    function invariant_burnsPayAtMostTheCap() public view {
        if (h.ccBurnedByTreasury() == 0) {
            assertEq(h.claimsPaidByBurns(), 0, "paid without a burn");
        }
        assertEq(h.capViolations(), 0, "a burn paid above the cap or the reserve");
        assertEq(h.shareViolations(), 0, "a burn paid above the proportional share without a budget");
    }

    // promise: SPEC phase 2 the bid budget never exceeds its maximum nor the claim reserve, and the carried amount and the rate never exceed the maximum, in every treasury at every step
    function invariant_bidBudgetWithinMaxAndReserve() public view {
        (ITreasury[2] memory ts, uint256 n) = _each();
        for (uint256 i; i < n; ++i) {
            uint256 budget = ts[i].bidBudgetAvailable();
            assertLe(budget, ts[i].bidBudgetMax(), "budget above its maximum");
            assertLe(budget, ts[i].claimReserve(), "budget above the claim reserve");
            assertLe(ts[i].bidBudgetCarried(), ts[i].bidBudgetMax(), "carried amount above the maximum");
            assertLe(ts[i].bidBudgetPerDay(), ts[i].bidBudgetMax(), "rate above the maximum");
        }
    }

    // promise: SPEC phase 2 the backing per remaining token does not fall below the level after the last owner action that could lower it or the last bid the owner's budget paid above the share
    function invariant_backingPerTokenNeverFallsWithoutOwnerAction() public view {
        uint256 s = h.coin().totalSupply();
        if (s == 0) return;
        uint256 rate = h.current().claimReserve() * 1e36 / s;
        assertGe(rate + 1, h.rateFloor(), "backing per token fell through ordinary activity");
    }

    // promise: SPEC phase 2 a migrated source holds exactly its debt, has no claims and advertises nothing
    function invariant_migratedSourceIsClosed() public view {
        if (!h.migratedOnce()) return;
        ITreasury s = h.source();
        assertTrue(s.migrated());
        assertEq(s.claimReserve(), 0);
        assertEq(s.available(), 0);
        assertGe(s.custody(), s.totalOwed());
    }

    // promise: SPEC phase 2 the handler exercises the successful paths, so the invariants are not vacuous
    function test_handlerPathsSucceed() public {
        h.fund(5e23);
        h.convert(5_000_000);
        h.allocate(1e21);
        h.pay(address(0xBEEF), 1e20, 0);
        h.pay(address(0xBEEF), 1e20, 2);
        h.claimDebt(address(0xBEEF));
        h.burn(1e24, 0);
        // a budget of 1e21 accrued over a day, then a bid of the share plus 5e20 within it
        h.setBidBudget(1e21, 1e21, false);
        h.warp(1 days);
        h.burn(1e24, 2e21 + 2);
        assertEq(h.bidsPaid(), 1);
        h.burn(1e24, 3);
        h.setFee(500);
        h.burn(1e24, 0);
        h.returnClaims(1e18);
        h.withdraw(1e18);
        h.independentBurn(1e23);
        // one unit, under the share
        h.burn(1e24, 5);
        h.migrate();
        h.convert(6_000_000);
        h.burn(1e24, 0);
        assertEq(h.successfulConversions(), 2);
        assertEq(h.successfulPays(), 2);
        assertEq(h.debtAccruals(), 1);
        assertEq(h.successfulBurns(), 5, "the bid above the cap was the only refused burn");
        assertTrue(h.migratedOnce());
        invariant_custodyCoversClaimsAndDebt();
        invariant_claimLedgerIsExplicit();
        invariant_burnsPayAtMostTheCap();
        invariant_bidBudgetWithinMaxAndReserve();
        invariant_backingPerTokenNeverFallsWithoutOwnerAction();
        invariant_migratedSourceIsClosed();
    }
}
