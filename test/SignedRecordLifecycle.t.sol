// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICredits, ICreditStrategy, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Reads the signed local deployment and runs real pool transactions in an in-process fork.
/// SIGNED_RECORD_REHEARSAL=1 opts in while the isolated Anvil deployment is running. The trader is test-funded;
/// swaps use the test router against the deployed v4 pool manager and hook.
contract SignedRecordLifecycleTest is Test {
    uint256 internal constant LISTED_CREDIT = 35377;
    string internal constant RECORD = "deployments/rehearsal.json";

    // promise: the signed launch pool sends real swap fees to Core, booking accounts for them, and a live
    // CreditStrategy listing can enter the pile once the funded bid reaches an executable price.
    function test_signedRecordSwapFeesAndStrategyAcquisition() public {
        if (!vm.envOr("SIGNED_RECORD_REHEARSAL", false)) vm.skip(true);
        string memory record = vm.readFile(RECORD);
        uint256 launchBlock = vm.parseJsonUint(record, ".launchBlock");
        vm.createSelectFork("http://127.0.0.1:8618", launchBlock);
        assertEq(block.chainid, vm.parseJsonUint(record, ".chainId"));
        assertEq(block.number, launchBlock, "fork starts from the signed launch block");

        ICore core = ICore(payable(vm.parseJsonAddress(record, ".core")));
        address coinAt = vm.parseJsonAddress(record, ".coin");
        address adapter = vm.parseJsonAddress(record, ".strategyAdapter");
        assertGt(address(core).code.length, 0, "signed Core exists");
        assertGt(coinAt.code.length, 0, "signed coin exists");
        assertGt(adapter.code.length, 0, "signed strategy adapter exists");
        assertEq(core.COIN(), coinAt, "Core points to signed coin");
        assertTrue(core.allowedAdapter(adapter), "signed adapter is enabled");
        assertEq(core.ethPot(), 0, "signed launch began without a booked pot");

        _swap(core, coinAt);
        _book(core);
        _acquire(core, adapter);
    }

    function _swap(ICore core, address coinAt) internal {
        IArtCoinsTokenV2 coin = IArtCoinsTokenV2(coinAt);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coinAt),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        TestSwapRouter router = new TestSwapRouter();
        address trader = makeAddr("signed-record-trader");
        vm.deal(trader, 5 ether);
        vm.warp(block.timestamp + 31 minutes);

        uint256 coreBefore = address(core).balance;
        vm.prank(trader);
        router.swap{value: 1 ether}(key, true, -int256(1 ether), trader);
        uint256 bought = coin.balanceOf(trader);
        assertGt(bought, 0, "real pool buy delivered coin");
        assertGt(address(core).balance, coreBefore, "hook pushed ETH fees to Core");
        uint256 afterBuy = address(core).balance;
        vm.startPrank(trader);
        coin.approve(address(router), bought / 2);
        router.swap(key, false, -int256(bought / 2), trader);
        vm.stopPrank();
        uint256 afterSell = address(core).balance;
        assertGt(afterSell, afterBuy, "real pool sell also pushed fees to Core");
        vm.prank(trader);
        router.swap{value: 1 ether}(key, true, -int256(1 ether), trader);
    }

    function _book(ICore core) internal {
        uint256 pending = address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
        assertGt(pending, 0, "swaps generated unbooked fees");
        Settings memory s = core.settings();
        bool payeeWasOn = core.payeeOn();
        core.book();
        uint256 payeeShare = payeeWasOn ? pending * s.payeePpm / 1_000_000 : 0;
        uint256 reserveShare = (pending - payeeShare) * s.feeToRedeemBurnBps / 10_000;
        assertEq(core.ethPot(), pending - payeeShare - reserveShare, "book credited the expected pot share");
        assertEq(core.ethRedeemBurn(), reserveShare, "book credited the expected reserve share");
        assertEq(
            core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), address(core).balance,
            "all Core ETH is accounted for"
        );
        console.log("booked swap fees wei", pending);
    }

    function _acquire(ICore core, address adapter) internal {
        uint256 price = ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(LISTED_CREDIT);
        assertGt(price, 0, "pinned strategy listing is executable");
        // The fork keeps this listing in place during the time jump; real order persistence is unproven.
        vm.warp(block.timestamp + 24 hours);
        vm.roll(block.number + 1);
        vm.fee(5 gwei);
        uint256 bid = core.bidOf(LISTED_CREDIT);
        assertGt(bid, price + 0.01 ether, "bid leaves room for ask and realistic caller payment");
        uint256 potBefore = core.ethPot();
        address keeper = makeAddr("signed-record-keeper");
        uint256 keeperBefore = keeper.balance;
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        core.buyListing(adapter, LISTED_CREDIT, "");
        uint256 measuredGas = gasBefore - gasleft();
        uint256 keeperReward = keeper.balance - keeperBefore;
        assertEq(ICredits(Mainnet.CREDITS).ownerOf(LISTED_CREDIT), address(core), "Core received real Credit");
        assertEq(core.pileSize(), 1, "Credit entered pile");
        assertLt(core.ethPot(), potBefore, "acquisition spent booked fee income");
        assertGt(keeperReward, measuredGas * 5 gwei, "caller reward covers measured test-call gas at 5 gwei");
        console.log("signed-record fork block", block.number);
        console.log("listed Credit ask wei", price);
        console.log("Credit bid wei", bid);
        console.log("pot spent wei", potBefore - core.ethPot());
        console.log("keeper reward wei", keeperReward);
        console.log("test-call gas", measuredGas);
    }
}
