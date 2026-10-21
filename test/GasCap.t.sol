// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {Fixture} from "./utils/Fixture.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";
import {ComposeCall} from "./utils/ComposeCall.sol";

/// @notice the transactions that carry a gas bound in the Core, against the per transaction gas cap of mainnet (EIP-7825, since the
/// fusaka upgrade): 16,777,216 gas. one test per transaction, real contracts on the pinned fork, from an EOA style
/// prank. each number is a `gasleft()` delta around the one top level external call, with the touched accounts and
/// slots cooled first, so the first access of every slot is charged the cold price like in a fresh transaction.
/// ESTIMATE: the transaction gas is that delta plus 21,000 intrinsic plus the calldata cost (4 per zero byte, 16 per
/// other byte, or the EIP-7623 floor of 10 per token when that is larger). it ignores the access list, the gas refund
/// (the cap counts gas before refunds) and a few hundred gas of call overhead inside the delta. `balanceModule` and
/// `balanceToken` are test stand ins: what a real `balanceModule` costs inside `redeem` is not measured here
contract GasCapTest is SeaportBase {
    uint256 internal constant CAP = 16_777_216;
    /// @dev above this share of the cap a row is flagged
    uint256 internal constant FLAG_PCT = 60;
    uint256 internal constant PAGE_GAS = 500_000;

    address internal bidder;
    address internal bidder2;
    address internal taker;
    address internal stranger;

    function setUp() public override {
        super.setUp();
        bidder = _user("gas bidder");
        bidder2 = _user("gas bidder two");
        taker = _user("gas taker");
        stranger = _user("gas stranger");
        // populate `lc` from the live stack so `_cool` cools the live AMM accounts (the fresh fixture read them from its
        // deployed v2 stack, which `LiveFixture` leaves unset)
        _initLiveConfig();
        vm.fee(composeBasefee);
    }

    // ------------------------------------------------------------------ measuring helpers

    function _calldataGas(bytes memory data) internal pure returns (uint256 std, uint256 floor_) {
        uint256 z;
        uint256 nz;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++z;
            else ++nz;
        }
        std = 4 * z + 16 * nz;
        floor_ = 10 * (z + 4 * nz);
    }

    function _pct(uint256 g) internal pure returns (string memory) {
        uint256 p = g * 1000 / CAP;
        return string.concat(vm.toString(p / 10), ".", vm.toString(p % 10));
    }

    function _txGas(uint256 exec, bytes memory data, uint256 extra) internal pure returns (uint256 total) {
        (uint256 std, uint256 floor_) = _calldataGas(data);
        total = 21_000 + exec + extra + std;
        if (21_000 + floor_ > total) total = 21_000 + floor_;
    }

    /// @dev logs one table row for an estimated transaction gas and asserts it is below the cap
    function _log(string memory name, uint256 exec, uint256 total) internal {
        string memory flag = total * 100 > CAP * FLAG_PCT ? " | FLAG above 60 percent" : "";
        if (total >= CAP) flag = " | LAUNCH BLOCKER above the cap";
        string memory head = string.concat("GAS | ", name, " | exec ", vm.toString(exec));
        console.log(string.concat(head, " | tx ", vm.toString(total), " | pct ", _pct(total), flag));
        assertLt(total, CAP, name);
    }

    /// @dev `extra` is execution gas the delta cannot see (the proxy of a create2 deploy). returns the estimate
    function _row(string memory name, uint256 exec, bytes memory data, uint256 extra) internal returns (uint256 total) {
        total = _txGas(exec, data, extra);
        _log(name, exec, total);
    }

    function _row(string memory name, uint256 exec, bytes memory data) internal returns (uint256) {
        return _row(name, exec, data, 0);
    }

    /// @dev marks every account the system touches as cold, with its slots, then warms only the account of `target`
    /// (a transaction starts with its target warm). the sender is not cooled
    function _cool(address target) internal {
        address[15] memory a = [
            address(core),
            address(ctl),
            address(STATEMENTS),
            address(CREDITS),
            STRATEGY,
            Mainnet.SEAPORT,
            address(PM),
            lc.stack.hook,
            address(coin),
            lc.stack.locker,
            lc.stack.escrow,
            lc.stack.factory,
            lc.mevModule,
            address(mod),
            address(xt)
        ];
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != address(0)) vm.cool(a[i]);
        }
        if (target.code.length == 0) revert("target has no code");
    }

    // ------------------------------------------------------------------ compose and redeem

    function _measureCompose(string memory name) internal returns (uint256 g) {
        uint256 held = core.heldStatements().length;
        uint256 kb = keeper.balance;
        vm.prank(keeper);
        g = gasleft();
        core.compose();
        g -= gasleft();
        assertEq(core.heldStatements().length, held + 1, "composed");
        // the launch caller settings pay the caller (decision 138), so the measure includes the payment path
        assertGt(keeper.balance, kb, "the compose pays the caller");
        _row(name, g, ComposeCall.noArgs());
    }

    // promise: SPEC 1 compose counted gas bound (13,700,000) and the transaction cap
    /// @dev full page of 80, nothing warmed by earlier work
    function test_gas_compose_ethLane_firstCold() public {
        _fillEthPile(80);
        // the live credit sale window is on, so age the page to eligibility before the cold measurement (the warp
        // reads the controller, so it runs before `_cool` re-cools every touched account)
        _warpPageReady();
        _cool(address(core));
        _measureCompose("compose eth lane, 80 credits, first compose, cold");
    }

    // promise: SPEC 1 redeemStatement counted gas bound and the transaction cap
    function test_gas_redeemStatement_ethLane() public {
        // the stand in balance module and token (this measures the Core's gas, not the real module's: see the contract
        // header). selected on the live Core by owner prank through the base `Fixture._enterPhase2`
        Fixture._enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.redeemStatement(sid);
        g -= gasleft();
        _row("redeemStatement, eth lane (stand in balanceModule), cold", g, abi.encodeCall(core.redeemStatement, (sid)));
    }

    // ------------------------------------------------------------------ the sell doors, batch size

    /// @dev a sell of `n` fresh credits by `seller`, measured, then the state is rolled back. returns the exec gas and
    /// the estimated transaction gas
    function _sellBatch(bool balance_, uint256 n) internal returns (uint256 g, uint256 total) {
        // two runs, the larger counts: repeated runs of one size differ by a few thousand gas
        (uint256 g1, uint256 t1) = _sellOnce(balance_, n);
        (uint256 g2, uint256 t2) = _sellOnce(balance_, n);
        return t1 > t2 ? (g1, t1) : (g2, t2);
    }

    function _sellOnce(bool balance_, uint256 n) internal returns (uint256 g, uint256 total) {
        uint256 snap = vm.snapshotState();
        uint256[] memory ids = _credits(seller, n);
        bytes memory data =
            abi.encodeWithSignature(balance_ ? "sellForBalance(uint256[])" : "sellForEth(uint256[])", ids);
        _cool(address(core));
        // the eth door books the income first: the measured sell carries a book of 1 eth
        if (!balance_) vm.deal(address(core), address(core).balance + 1 ether);
        vm.prank(seller);
        g = gasleft();
        if (balance_) core.sellForBalance(ids);
        else core.sellForEth(ids);
        g -= gasleft();
        total = _txGas(g, data, 0);
        vm.revertToState(snap);
    }

    /// @dev the core does not bound the batch. the largest `n` whose transaction stays under the cap is found by a
    /// linear fit on three sizes, then walked to the exact edge
    function _searchBatch(string memory label, bool balance_) internal returns (uint256 n) {
        (uint256 g1, uint256 t1) = _sellBatch(balance_, 1);
        _row(string.concat(label, ", 1 credit, cold"), g1, abi.encodeWithSignature("sellForEth(uint256[])", _one(1)));
        (uint256 g10,) = _sellBatch(balance_, 10);
        (uint256 g40, uint256 t40) = _sellBatch(balance_, 40);
        uint256 slope = (t40 - t1) / 39;
        console.log(string.concat(label, ": marginal tx gas per credit (fit 1 to 40)"), slope);
        console.log(string.concat(label, ": exec gas for 10 credits"), g10);
        n = (CAP - t1) / slope + 1;
        while (n > 1) {
            (, uint256 t) = _sellBatch(balance_, n);
            if (t < CAP) break;
            --n;
        }
        while (n < 600) {
            (, uint256 t) = _sellBatch(balance_, n + 1);
            if (t >= CAP) break;
            ++n;
        }
        (uint256 gn, uint256 tn) = _sellBatch(balance_, n);
        // a size measured under the cap during the walk can measure over it again: the edge is the last size whose final
        // measurement is under the cap
        while (tn >= CAP) {
            --n;
            (gn, tn) = _sellBatch(balance_, n);
        }
        (, uint256 tn1) = _sellBatch(balance_, n + 1);
        console.log(string.concat(label, ": LARGEST BATCH under the cap"), n);
        console.log(string.concat(label, ": gas per credit at the largest batch"), tn / n);
        string memory big = string.concat(label, ", largest batch ", vm.toString(n), ", cold");
        _log(big, gn, tn);
        console.log(string.concat(label, ": next size is over the cap, tx gas"), tn1);
        assertGe(tn1, CAP, "the search found the edge");
        assertGt(g40, g10);
    }

    // promise: SPEC 1 at least 86 credits fit the launch ETH transaction cap; measure the exact edge on the pinned fork
    function test_gas_sellForEth_batch_launchSettings() public {
        _fundPot(30 ether);
        _warp(1 hours + 1);
        assertGe(_searchBatch("sellForEth (launch)", false), 86, "the launch ETH batch fits at least 86 credits");
    }

    // promise: mode-off value pricing keeps the pre-packet 86-credit ETH batch within the mainnet cap; the per-credit
    // marginal cost is low enough that the batch no longer falls to 85 (decision 159, C08). the one-credit figure is a
    // regression guard: the batch checkpoint hoist does not lower it (one credit still pays the reserve, pending and
    // return-lock reads the mandated launch features added), and the artist royalty on every purchase adds the once-per-
    // batch forced push (decision 163), so it is bounded, not restored to the pre-packet 482,000
    function test_modeOffPrePacket86CreditEthBatchGasRegression() public {
        assertFalse(core.settings().valueModeOn, "launch keeps value mode off");
        _fundPot(30 ether);
        _warp(1 hours + 1);
        (, uint256 one) = _sellBatch(false, 1);
        emit log_named_uint("mode-off one-credit estimated tx gas", one);
        assertLe(one, 530_000, "the one-credit mode-off sell does not regress beyond the audited point");
        (, uint256 total) = _sellBatch(false, 86);
        emit log_named_uint("mode-off 86-credit estimated tx gas", total);
        assertLt(total, CAP, "the 86-credit batch fits the mainnet cap again");
    }

    // promise: SPEC 1 the balance bid batch fits the transaction cap; the module holds the token and pays the seller
    function test_gas_sellForBalance_batch() public {
        // the stand in balance module and token, selected on the live Core: this measures the Core's sellForBalance gas
        // (contract header), and the batch search needs a module that pays an unbounded batch, which the live treasury
        // (capped by the holder and the pool) cannot. the mock mints enough for the largest batch the search walks to
        Fixture._enterPhase2();
        _fundPot(30 ether);
        _warp(1 hours + 1);
        xt.mint(address(mod), 1e30);
        _searchBatch("sellForBalance (launch)", true);
    }

    // ------------------------------------------------------------------ buyListing, sales proceeds, buybacks

    // promise: SPEC 1 buyListing counted gas bound (1,500,000) and the transaction cap
    /// @dev the CreditStrategy listing with the payee share on and 1 eth of unbooked income, so the door's book runs
    function test_gas_buyListing_creditStrategy_incomeLoaded() public {
        _skipToPayeeStart();
        _buyCoin(funder, 5 ether);
        _fundPot(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        vm.deal(address(core), address(core).balance + 1 ether);
        bytes memory data = abi.encodeCall(core.buyListing, (strategyAdapter, LISTED_A, ""));
        _cool(address(core));
        _cool(strategyAdapter);
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(strategyAdapter, LISTED_A, "");
        g -= gasleft();
        assertEq(address(core).balance, _tracked(), "the buy booked the income");
        _row("buyListing through the CreditStrategy adapter, 1 eth of unbooked income, cold", g, data);
    }

    function _seaportBuy(string memory name, uint256 mode) internal {
        _fundPot(10 ether);
        uint256 id = _list();
        uint256 price = core.bidOf(id) * 9 / 10;
        OrderComponents memory c = mode == 1 ? _open(id, price - price / 100, price / 100) : _open(id, price, 0);
        bytes memory order = _basicData(c);
        bytes memory data = abi.encodeCall(core.buyListing, (seaportAdapter, id, order));
        _cool(address(core));
        _cool(seaportAdapter);
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(seaportAdapter, id, order);
        g -= gasleft();
        assertEq(CREDITS.ownerOf(id), address(core));
        _row(name, g, data);
    }

    // promise: SPEC 1 buyListing counted gas bound (1,500,000) and the transaction cap
    function test_gas_buyListing_seaport_basicWithFee() public {
        _seaportBuy("buyListing through the Seaport adapter, basic order with a fee recipient, cold", 1);
    }

    // promise: SPEC 1 buyback counted gas bound (600,000) and the transaction cap
    /// @dev a statement sold through the controller books its buyback share, then the buyback swaps in the real pool
    function test_gas_buyback_afterAStatementSale() public {
        _sellStatement(bidder);
        vm.roll(block.number + 1);
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyback();
        g -= gasleft();
        _row("buyback (swaps, burns), cold", g, abi.encodeCall(core.buyback, ()));
    }

    // promise: SPEC 1 swapCredit gas, a pile credit swapped for one of higher score with the fee burned, cold
    function test_gas_swapCredit() public {
        uint256[] memory two = _credits(taker, 2);
        (uint256 outId, uint256 inId) = _scoreOf(two[0]) <= _scoreOf(two[1]) ? (two[0], two[1]) : (two[1], two[0]);
        // the outgoing credit goes into the pile through a sell at its live scaled bid (the live CreditScore is read,
        // never mocked); swapCredit's gas does not depend on the exact sell price
        _liftRateCap();
        _fundPot(5 ether);
        _warp(1 hours + 1);
        vm.prank(taker);
        core.sellForEth(_one(outId));
        // a representative nonzero fee the caller burns, and the coin and approval for it
        _setSwapFeeCc(1e18);
        _buyCoin(taker, 1 ether);
        vm.prank(taker);
        coin.approve(address(core), 1e18);

        bytes memory data = abi.encodeCall(core.swapCredit, (inId, outId));
        _cool(address(core));
        vm.prank(taker);
        uint256 g = gasleft();
        core.swapCredit(inId, outId);
        g -= gasleft();
        assertEq(CREDITS.ownerOf(inId), address(core), "the incoming credit is in the pile");
        _row("swapCredit, one pile credit for one of higher score, fee burned, cold", g, data);
    }

    // ------------------------------------------------------------------ statements: sellTo

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (, c,) = core.statementInfo(sid);
    }

    // promise: inv 18 the statement sale pushes the artist and operator cuts and books the rest
    /// @dev the door cost of `buy`, which forwards the price to `sellTo`: the core takes the artist and operator cuts off
    /// the top and forces them to the artist and the payee
    function test_gas_buy_statementSalePushesTheCuts() public {
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.priceOf(sid);
        address who = makeAddr("gascap statement buyer");
        vm.deal(who, price);
        _cool(address(core));
        _cool(address(ctl));
        bytes memory data = abi.encodeCall(IControllerV1.buy, (sid));
        vm.prank(who);
        uint256 g = gasleft();
        ctl.buy{value: price}(sid);
        g -= gasleft();
        _row("buy a statement (sellTo forces the artist and operator cuts), cold", g, data);
    }

    // promise: inv 18 the credit sale pushes the artist and operator cuts and books the rest
    /// @dev the door cost of `buyCredit`, which forwards the price to `sellCreditTo`
    function test_gas_buyCredit_creditSalePushesTheCuts() public {
        // pre-fund the pot above the live reserve before filling: with one credit, `_fillEthPile` tops the pot only to
        // about the opening rate, which a live score above 100 points and the nonzero live reserve leave too small to
        // pay the bid, so the fill's own sell reverts PotTooSmall (decision 156; the fresh fixture ran reserveWei 0)
        _fundPot(2 ether);
        uint256[] memory ids = _fillEthPile(1);
        _setCreditSaleOn(true);
        uint256 id = ids[0];
        uint256 price = ctl.creditPrice(id);
        address who = makeAddr("gascap credit buyer");
        vm.deal(who, price);
        _cool(address(core));
        _cool(address(ctl));
        bytes memory data = abi.encodeCall(IControllerV1.buyCredit, (id));
        vm.prank(who);
        uint256 g = gasleft();
        ctl.buyCredit{value: price}(id);
        g -= gasleft();
        _row("buyCredit (sellCreditTo forces the artist and operator cuts), cold", g, data);
    }

    // promise: inv 18 the booking door forces the payee share out
    /// @dev the door cost of `book` when the payee share is on and nonzero: the book forces the share to the payee
    function test_gas_book_forcesThePayeeShare() public {
        Settings memory s = core.settings();
        s.payeePpm = 90_909;
        _setSettings(s);
        vm.warp(block.timestamp + core.settings().sniperSeconds + 1);
        vm.deal(address(core), address(core).balance + 1 ether);
        core.book(); // the latch book past the window shares nothing
        vm.deal(address(core), address(core).balance + 1 ether);
        _cool(address(core));
        bytes memory data = abi.encodeCall(ICore.book, ());
        uint256 g = gasleft();
        core.book();
        g -= gasleft();
        _row("book with a nonzero payee share (forced push), cold", g, data);
    }

    // ------------------------------------------------------------------ owner doors

    // ------------------------------------------------------------------ the gas capped reads inside the core

    // promise: INTEGRATION the Core reads nextPage with 500,000 gas
    /// @dev the core reads `nextPage` with 500,000 gas. a full pile, cold access
    function test_gas_readCaps_nextPage() public {
        _fillEthPile(80);
        // the live credit sale window is on, so age the page to eligibility before the cold read (the warp reads the
        // controller, so it runs before `_cool` re-cools it)
        _warpPageReady();
        _cool(address(ctl));
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage();
        g -= gasleft();
        assertTrue(ready);
        console.log("READ ControllerV1.nextPage, full eth pile, cold, gas", g, "cap", PAGE_GAS);
        console.log("READ nextPage share of the cap in percent", g * 100 / PAGE_GAS);
        assertLt(g, PAGE_GAS);
    }
}
