// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditStrategy, IStatements, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";
import {ComposeCall} from "./utils/ComposeCall.sol";

/// @notice every transaction this system needs, against the per transaction gas cap of mainnet (EIP-7825, since the
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
            v2.hook,
            address(coin),
            v2.locker,
            v2.escrow,
            v2.factory,
            v2.mev,
            address(mod),
            address(xt)
        ];
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != address(0)) vm.cool(a[i]);
        }
        if (target.code.length == 0) revert("target has no code");
    }

    // ------------------------------------------------------------------ the deploy transactions of script/SystemDeployer.sol

    /// @dev tx 1, the linked library through the create2 deployer: 32 byte salt plus the creation code, plus the proxy
    function test_gas_deploy_1_library() public {
        bytes memory code = vm.getCode("CoreLib.sol:CoreLib");
        uint256 g = gasleft();
        deployCode("CoreLib.sol:CoreLib");
        g -= gasleft();
        _row("deploy 1 library CoreLib (create2 deployer)", g, bytes.concat(bytes32(0), code), 512);
    }

    function test_gas_deploy_2_controller() public {
        bytes memory args = abi.encode(address(core), lc.sale, lc.credit);
        bytes memory code = bytes.concat(vm.getCode("ControllerV1.sol:ControllerV1"), args);
        _cool(address(this));
        uint256 g = gasleft();
        deployCode("ControllerV1.sol:ControllerV1", args);
        g -= gasleft();
        _row("deploy 2 controller", g, code);
    }

    /// @dev tx 3, a second Core
    function test_gas_deploy_3_core() public {
        bytes memory args = abi.encode(
            owner,
            buildConfig(lc, owner, address(0)),
            owner,
            address(0),
            address(ctl),
            lc.payee,
            lc.stack,
            lc.rateStart,
            lc.settings,
            lc.credit,
            launchAdapters(address(core), lc)
        );
        bytes memory code = bytes.concat(vm.getCode("Core.sol:Core"), args);
        _cool(address(this));
        uint256 g = gasleft();
        address c2 = deployCode("Core.sol:Core", args);
        g -= gasleft();
        assertTrue(c2 != address(core), "a new core");
        console.log("core initcode bytes", code.length, "runtime bytes", c2.code.length);
        _row("deploy 3 core", g, code);
    }

    /// @dev tx 4 on a fresh launch (new salt), as the owner: `deployTokenAsOwner`
    function test_gas_deploy_4_launch() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg =
            buildConfig(owner, creator, "Gas Coin", "GASC", keccak256("gas cap coin"));
        uint256 fee = FACTORY.deployFee();
        bytes memory data = abi.encodeCall(IArtCoinsFactoryV2.deployTokenAsOwner, (cfg, lc.protocolBps));
        vm.deal(owner, 1 ether);
        _cool(address(FACTORY));
        vm.prank(owner);
        uint256 g = gasleft();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        g -= gasleft();
        _row("deploy 4 launch through the factory (deployTokenAsOwner)", g, data);
    }

    /// @dev `book` with the payee share on, cold, the call that counts the pool fees the hook pushed into the Core
    function test_gas_book() public {
        _skipToPayeeStart();
        _buyCoin(funder, 20 ether);
        autoBook = false;
        _buyCoin(funder, 5 ether);
        _book();
        _buyCoin(funder, 5 ether);
        assertTrue(core.payeeOn(), "the payee share is on");
        bytes memory data = abi.encodeCall(core.book, ());
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.book();
        g -= gasleft();
        _row("book with the payee share on (the Core books the fees)", g, data);
    }

    /// @dev the first book at or after the end of the window: reads the launch time from the factory, turns the payee
    /// share on and shares nothing
    function test_gas_book_firstAfterTheWindow() public {
        _skipToPayeeStart();
        autoBook = false;
        _buyCoin(funder, 5 ether);
        assertFalse(core.payeeOn());
        bytes memory data = abi.encodeCall(core.book, ());
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.book();
        g -= gasleft();
        assertTrue(core.payeeOn());
        _row("book that turns the payee share on (reads the factory record)", g, data);
    }

    /// @dev `fund`, cold: books the income above the pots, then adds the value to the pot
    function test_gas_fund() public {
        _skipToPayeeStart();
        _buyCoin(funder, 20 ether);
        autoBook = false;
        _buyCoin(funder, 5 ether);
        bytes memory data = abi.encodeCall(core.fund, ());
        vm.deal(stranger, 2 ether);
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.fund{value: 1 ether}();
        g -= gasleft();
        _row("fund with income to book, cold", g, data);
    }

    /// @dev `claimPayee`, cold
    function test_gas_claimPayee() public {
        _skipToPayeeStart();
        _buyCoin(funder, 20 ether);
        _buyCoin(funder, 5 ether);
        assertGt(core.payeeOwed(), 0);
        bytes memory data = abi.encodeCall(core.claimPayee, ());
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.claimPayee();
        g -= gasleft();
        _row("claimPayee, cold", g, data);
    }

    /// @dev the keeper calls the v2 escrow adds: `collectEscrow` claims the Core credit into the pot, and `rescueCoin`
    function test_gas_escrowClaim_collect_rescue() public {
        _skipToPayeeStart();
        _buyCoin(funder, 5 ether);
        vm.deal(v2.hook, 1 ether);
        vm.prank(v2.hook);
        (bool ok,) = v2.escrow.call{value: 0.3 ether}(abi.encodeWithSignature("storeFeesNative(address)", address(core)));
        assertTrue(ok);
        bytes memory data = abi.encodeCall(core.collectEscrow, ());
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.collectEscrow();
        g -= gasleft();
        _row("collectEscrow claims the Core credit into the pot", g, data);

        vm.prank(owner);
        coin.setAllowed(funder, true);
        vm.prank(funder);
        coin.transfer(address(core), 1_000e18);
        data = abi.encodeCall(core.rescueCoin, (funder, 1_000e18));
        _cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.rescueCoin(funder, 1_000e18);
        g -= gasleft();
        _row("rescueCoin", g, data);
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
        assertEq(keeper.balance, kb, "the compose pays the caller nothing");
        _row(name, g, ComposeCall.noArgs());
    }

    /// @dev full page of 80, nothing warmed by earlier work
    function test_gas_compose_ethLane_firstCold() public {
        _fillEthPile(80);
        _cool(address(core));
        _measureCompose("compose eth lane, 80 credits, first compose, cold");
    }

    function test_gas_compose_ethLane_secondWarmAndCold() public {
        _composeOnce();
        _fillEthPile(80);
        uint256 snap = vm.snapshotState();
        _measureCompose("compose eth lane, 80 credits, second compose, warm (no cooling)");
        vm.revertToState(snap);
        _cool(address(core));
        _measureCompose("compose eth lane, 80 credits, second compose, cold");
    }

    /// @dev puts 1 eth of unbooked income in the Core, so the compose books it first
    function _loadIncome() internal {
        vm.deal(address(core), address(core).balance + 1 ether);
    }

    function _composeLoaded() internal returns (uint256 g) {
        _skipToPayeeStart();
        _buyCoin(funder, 5 ether);
        _fillEthPile(80);
        _loadIncome();
        vm.fee(composeBasefee);
        _cool(address(core));
        vm.prank(keeper);
        g = gasleft();
        core.compose();
        g -= gasleft();
        assertEq(address(core).balance, _tracked(), "the compose booked the income");
        _row("compose eth lane, 1 eth of unbooked income, payee share on, cold", g, ComposeCall.noArgs());
    }

    function test_gas_compose_ethLane_incomeLoaded() public {
        _composeLoaded();
    }

    function test_gas_redeemStatement_ethLane() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.redeemStatement(sid);
        g -= gasleft();
        _row(
            "redeemStatement, eth lane (stand in balanceModule), cold",
            g,
            abi.encodeCall(core.redeemStatement, (sid))
        );
    }

    function _composeMore() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
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
    function _searchBatch(string memory label, bool balance_) internal {
        (uint256 g1, uint256 t1) = _sellBatch(balance_, 1);
        _row(string.concat(label, ", 1 credit, cold"), g1, abi.encodeWithSignature("sellForEth(uint256[])", _one(1)));
        (uint256 g10,) = _sellBatch(balance_, 10);
        (uint256 g40, uint256 t40) = _sellBatch(balance_, 40);
        uint256 slope = (t40 - t1) / 39;
        console.log(string.concat(label, ": marginal tx gas per credit (fit 1 to 40)"), slope);
        console.log(string.concat(label, ": exec gas for 10 credits"), g10);
        uint256 n = (CAP - t1) / slope + 1;
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

    function test_gas_sellForEth_batch_launchSettings() public {
        _fundPot(30 ether);
        _warp(1 hours + 1);
        _searchBatch("sellForEth (launch)", false);
    }

    function test_gas_sellForBalance_batch() public {
        _enterPhase2();
        _setBalancePool();
        _fillBalanceBuyback();
        xt.mint(address(core), 1_000_000e18);
        core.bookBalance();
        _searchBatch("sellForBalance", true);
    }

    // ------------------------------------------------------------------ buyListing, sales proceeds, buybacks

    function test_gas_buyListing_creditStrategy() public {
        _fundPot(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        bytes memory data = abi.encodeCall(core.buyListing, (strategyAdapter, LISTED_A, ""));
        _cool(address(core));
        _cool(strategyAdapter);
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(strategyAdapter, LISTED_A, "");
        g -= gasleft();
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _row("buyListing through the CreditStrategy adapter, cold", g, data);
    }

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
        uint256 price = core.ethRate() * 9 / 10;
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

    function test_gas_buyListing_seaport_basic() public {
        _seaportBuy("buyListing through the Seaport adapter, basic order, cold", 0);
    }

    function test_gas_buyListing_seaport_basicWithFee() public {
        _seaportBuy("buyListing through the Seaport adapter, basic order with a fee recipient, cold", 1);
    }

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

    // ------------------------------------------------------------------ statements: sellTo

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (, c,) = core.statementInfo(sid);
    }

    /// @dev ControllerV1.buy pays the asking price and takes the statement through Core.sellTo
    function test_gas_sellTo_throughControllerBuy() public {
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.grossPriceOf(sid);
        vm.deal(bidder, price);
        _cool(address(ctl));
        vm.prank(bidder);
        uint256 g = gasleft();
        ctl.buy{value: price}(sid);
        g -= gasleft();
        assertEq(STATEMENTS.ownerOf(sid), bidder);
        _row("sellTo through ControllerV1.buy, cold", g, abi.encodeCall(ctl.buy, (sid)));
    }

    // ------------------------------------------------------------------ owner doors

    /// @dev the balance side on with balance token in the bid pot: setSettings checkpoints the eth rate and rewrites every field
    function test_gas_setSettings() public {
        _enterPhase2();
        _fillBalanceBuyback();
        Settings memory s = core.settings();
        s.climbPerMinBps = 90;
        s.dropPerCreditBps = 150;
        s.saleFloorBps = 8_000;
        s.saleToBuybackBps = 4_000;
        s.buybackSlice = 1 ether;
        s.redeemSlippageBps = 500;
        s.redeemBurnBps = 3_500;
        bytes memory data = abi.encodeCall(core.setSettings, (s));
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setSettings(s);
        g -= gasleft();
        assertEq(core.settings().saleFloorBps, 8_000);
        _row("setSettings (the balance side, balance auction re anchored), cold", g, data);
    }

    function test_gas_setController() public {
        ScriptedController sc = new ScriptedController();
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setController(address(sc));
        g -= gasleft();
        assertEq(core.controller(), address(sc));
        _row("setController, cold", g, abi.encodeCall(core.setController, (address(sc))));
    }

    function test_gas_setBalanceModule_firstAndReplace() public {
        xt = new MockBalanceToken("XT", "XT");
        mod = new MockBalanceModule(address(xt), UNIT);
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setBalanceModule(address(mod));
        g -= gasleft();
        _row("setBalanceModule, first set, cold", g, abi.encodeCall(core.setBalanceModule, (address(mod))));
        MockBalanceModule mod2 = new MockBalanceModule(address(xt), UNIT * 2);
        _cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.setBalanceModule(address(mod2));
        g -= gasleft();
        _row(
            "setBalanceModule, replace with a module of the same balanceToken, cold",
            g,
            abi.encodeCall(core.setBalanceModule, (address(mod2)))
        );
    }

    // ------------------------------------------------------------------ the gas capped reads inside the core

    /// @dev the core reads `nextPage` with 500,000 gas. a full pile, cold access
    function test_gas_readCaps_nextPage() public {
        _fillEthPile(80);
        _cool(address(ctl));
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage();
        g -= gasleft();
        assertTrue(ready);
        console.log("READ ControllerV1.nextPage, full eth pile, cold, gas", g, "cap", PAGE_GAS);
        console.log("READ nextPage share of the cap in percent", g * 100 / PAGE_GAS);
        assertLt(g, PAGE_GAS);
    }

    /// @dev the same read for a pile far larger than a page (the read takes the head page). the deep pile is filled
    /// through the balance bid so the eth pot is not drained
    function test_gas_readCaps_nextPage_deepPile() public {
        _enterPhase2();
        _setBalancePool();
        _fillBalanceBuyback();
        xt.mint(address(core), 1_000_000e18);
        core.bookBalance();
        uint256[] memory ids = _credits(seller, 400);
        // in batches of 100: a cold sale of 400 credits in one call exceeds the gas of one call
        for (uint256 from; from < 400; from += 100) {
            uint256[] memory batch = new uint256[](100);
            for (uint256 j; j < 100; ++j) {
                batch[j] = ids[from + j];
            }
            vm.prank(seller);
            core.sellForBalance(batch);
        }
        assertEq(core.pileSize(), 400);
        _cool(address(ctl));
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage();
        g -= gasleft();
        assertTrue(ready);
        console.log("READ ControllerV1.nextPage, pile of 400, cold, gas", g, "cap", PAGE_GAS);
        assertLt(g, PAGE_GAS);
    }

    /// @dev a policy module may choose a format from 0 to 7. the shipped controller always answers 0. what each format
    /// costs the compose, with a scripted controller
    function test_gas_compose_everyFormat() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        for (uint8 f; f < 8; ++f) {
            uint256 snap = vm.snapshotState();
            sc.setPage(true, ids, f);
            _cool(address(core));
            _measureCompose(
                string.concat("compose eth lane, scripted controller, format ", vm.toString(uint256(f)), ", cold")
            );
            vm.revertToState(snap);
        }
    }

    /// @dev how much the compose cost depends on which credits are composed: the live Statements contract directly, with
    /// pages of 80 real credits taken from different id ranges (first minted to latest), cold.
    /// measured once on the pin: 7,900,110 to 8,067,758 for the Statements call alone, so the page changes it by about 2 percent
    function test_gas_compose_pageVariance_liveStatements() public {
        // scans real credit owners over the rpc, minutes on a cold cache: runs only with GAS_VARIANCE=1
        if (!vm.envOr("GAS_VARIANCE", false)) vm.skip(true);
        address holder = _user("gas holder");
        vm.prank(holder);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 worst;
        uint256 best = type(uint256).max;
        uint256[6] memory bases = [uint256(1), 6_000, 14_000, 22_000, 30_000, 38_000];
        for (uint256 b; b < bases.length; ++b) {
            uint256[80] memory ids;
            uint256 got;
            for (uint256 id = bases[b]; id < bases[b] + 2_000 && got < 80; ++id) {
                try CREDITS.ownerOf(id) returns (address o) {
                    if (o == holder) continue;
                    vm.prank(o);
                    CREDITS.transferFrom(o, holder, id);
                    ids[got++] = id;
                } catch {}
            }
            if (got < 80) {
                console.log("page base with fewer than 80 credits in range, skipped", bases[b]);
                continue;
            }
            vm.cool(address(STATEMENTS));
            vm.cool(address(CREDITS));
            vm.prank(holder);
            uint256 g = gasleft();
            STATEMENTS.compose(ids, 0);
            g -= gasleft();
            console.log("STATEMENTS.compose, 80 real credits from id", bases[b], "gas", g);
            if (g > worst) worst = g;
            if (g < best) best = g;
        }
        console.log("STATEMENTS.compose spread: best", best, "worst", worst);
        assertGt(worst, 0);
    }
}
