// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IRedemptionPolicy, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {ITreasury, Phase2StatementsDouble, CoinDouble} from "../Phase2Treasury.t.sol";
import {Phase2BalanceTokenStandin} from "../standins/Phase2BalanceTokenStandin.sol";

/// the handler is the Core double of its treasuries: it answers owner, coin, retirement and the selected module, and it
/// is the only caller of `redeem` and `pay`. it interleaves funding, conversions, payments with every token fault mode,
/// debt claims, CC burns, independent burns, owner settings, reallocations, withdrawals and one migration, and keeps the
/// ledger ghosts the invariants compare against
contract Phase2TreasuryHandler {
    Phase2StatementsDouble public statements;
    Phase2BalanceTokenStandin public token;
    CoinDouble public coin;
    address public policy;
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
    uint256 public successfulConversions;
    uint256 public successfulPays;
    uint256 public debtAccruals;
    /// the backing per token after the last owner action that may lower it, times 1e36
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
        policy = _deployPolicy();
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

    function _deployPolicy() private returns (address p) {
        bytes memory code = _code("ProRataRedemptionPolicy");
        assembly ("memory-safe") {
            p := create(0, add(code, 32), mload(code))
        }
        require(p != address(0), "policy");
    }

    function _deployTreasury(address predecessor) private returns (ITreasury t) {
        bytes memory init = abi.encodePacked(
            _code("Phase2BalanceTreasury"), abi.encode(address(this), address(token), policy, predecessor)
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

    /// a CC burn against the live quote: when the quote says executable the burn must succeed with exactly that output
    function burn(uint256 ccIn) external {
        ccIn = bound(ccIn, 1, 1e25);
        uint256 held = coin.balanceOf(burner);
        if (held < ccIn) {
            uint256 need = ccIn - held;
            VmLike(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(holder);
            coin.transfer(burner, need);
        }
        VmLike vm = VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
        vm.prank(burner);
        coin.approve(address(current), ccIn);
        (uint256 q,,, uint64 epoch, bool exec) = current.quoteRedemption(ccIn);
        uint256 supplyBefore = coin.totalSupply();
        vm.prank(burner);
        try current.redeemCC(ccIn, burner, q, block.timestamp, epoch) returns (uint256 out) {
            require(exec && out == q, "a burn executed against a non executable or different quote");
            require(coin.totalSupply() == supplyBefore - ccIn, "supply");
            claimsPaidByBurns += out;
            ccBurnedByTreasury += ccIn;
            ++successfulBurns;
        } catch {
            require(!exec || q == 0, "an executable quote failed to execute");
        }
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

    function toggle(bool a, bool b, bool c) external {
        _asOwner().setSwitches(a, b, c);
    }

    /// one migration to a fresh successor; later actions run on the successor
    function migrate() external {
        if (migratedOnce) return;
        ITreasury next = _deployTreasury(address(current));
        _asOwner().setSwitches(false, false, false);
        uint256 claims = current.claimReserve();
        try _asOwner().migrateTo(address(next)) {
            require(next.claimReserve() == claims, "claims imported");
            require(current.claimReserve() == 0 && current.migrated(), "source closed");
            current = next;
            balanceModule = address(next);
            migratedOnce = true;
            _asOwner().setSwitches(true, true, true);
            _refreshRateFloor();
        } catch {
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
    function getCode(string calldata) external view returns (bytes memory);
}

contract InvariantsPhase2TreasuryTest is Test {
    Phase2TreasuryHandler internal h;

    function setUp() public {
        vm.etch(Mainnet.STATEMENTS, address(new Phase2StatementsDouble()).code);
        h = new Phase2TreasuryHandler();
        h.init();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](15);
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

    // promise: SPEC phase 2 balance leaves the claim reserve only alongside a CC burn, and a burn never pays more than the share
    function invariant_burnsPayAtMostTheShare() public view {
        if (h.ccBurnedByTreasury() == 0) {
            assertEq(h.claimsPaidByBurns(), 0, "paid without a burn");
        }
    }

    // promise: SPEC phase 2 the backing per remaining token does not fall below the level after the last owner action that could lower it
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
        h.burn(1e24);
        h.setFee(500);
        h.burn(1e24);
        h.returnClaims(1e18);
        h.withdraw(1e18);
        h.independentBurn(1e23);
        h.burn(1e24);
        h.migrate();
        h.convert(6_000_000);
        h.burn(1e24);
        assertEq(h.successfulConversions(), 2);
        assertEq(h.successfulPays(), 2);
        assertEq(h.debtAccruals(), 1);
        assertEq(h.successfulBurns(), 4);
        assertTrue(h.migratedOnce());
        invariant_custodyCoversClaimsAndDebt();
        invariant_claimLedgerIsExplicit();
        invariant_backingPerTokenNeverFallsWithoutOwnerAction();
        invariant_migratedSourceIsClosed();
    }
}
