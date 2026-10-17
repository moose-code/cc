// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {Settings, Quote} from "../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IProductionBalance {
    function renderer() external view returns (address);
    function decimals() external view returns (uint8);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function launchSupply() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function totalRetired() external view returns (uint256);
    function transfersOpenBlock() external view returns (uint64);
    function balanceOf(address) external view returns (uint256);
    function quote(uint256) external view returns (uint256);
    function withdraw(uint256, uint256) external returns (uint256);
    function retireLaunchSupply() external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IProductionStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address, string calldata) external returns (uint8);
    function approve(address, uint256) external;
}

/// Fork probes use pinned AuctionLineageWithdrawals bytecode and its production module. The pool starts at the dev
/// parity price, a scenario rather than an auction-price prediction. The canonical initializer hook has no swap or
/// liquidity callbacks, so swaps and LP changes use the same pool math as the eventual canonical pool.
contract ProductionValueAuditTest is Fixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 private constant PARITY_SQRT = uint160(11318308930609191084791992905142);
    uint256 private constant BASE_LIQUIDITY = 1e20;
    uint256 private constant TEST_GAS_PRICE = 0.1 gwei;
    address private constant INITIALIZER_HOOK = 0xcDf73dEddE5e8C2FdC9c01C18607e0B40380E000;
    address private constant LBP_STRATEGY = 0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000;

    IProductionBalance private balance;
    PoolKey private balanceKey;
    TestLiquidityHelper private lp;
    uint256 private poolEthDepth;
    uint256 private poolTokenDepth;

    function setUp() public override {
        if (!vm.exists("out/upstream-balance.json")) {
            require(!vm.envOr("REQUIRE_UPSTREAM_BALANCE", false), "run script/tools/upstream-balance.sh first");
            vm.skip(true);
            return;
        }
        string memory artifact = vm.readFile("out/upstream-balance.json");
        bytes memory creation = vm.parseJsonBytes(artifact, ".bytecode.object");
        assertEq(sha256(creation), 0x980130b1bedb50d2f226fce4509ed80011780ff04d0641eafbdae4e6aeb89a08);
        super.setUp();
        vm.fee(TEST_GAS_PRICE);

        address funderWallet = _user("productionValueFunder");
        IProductionStatements source = IProductionStatements(address(STATEMENTS));
        uint8 format = uint8(source.formatCount());
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(
                address(STATEMENTS),
                format,
                uint64(block.number + 100),
                funderWallet,
                _user("productionValueAuction"),
                address(this)
            )
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        require(deployed != address(0), "upstream deployment failed");
        balance = IProductionBalance(deployed);
        assertEq(balance.decimals(), 18);
        assertEq(balance.SCORE_TO_TOKEN(), 1e14);
        assertEq(balance.launchSupply(), 53_750_000 ether);

        address sourceOwner = source.owner();
        address renderer = balance.renderer();
        vm.prank(sourceOwner);
        source.addFormat(renderer, "Balance");
        uint256[] memory ids = _credits(funderWallet, 160);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) page[i] = ids[i];
        vm.startPrank(funderWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 sid = STATEMENTS.compose(page, 0);
        source.approve(deployed, sid);
        balance.withdraw(sid, balance.quote(sid));
        for (uint256 i; i < 80; ++i) page[i] = ids[i + 80];
        sid = STATEMENTS.compose(page, 0);
        source.approve(deployed, sid);
        balance.withdraw(sid, balance.quote(sid));
        balance.retireLaunchSupply();
        vm.stopPrank();
        assertEq(balance.totalRetired(), balance.launchRetirement());
        vm.roll(balance.transfersOpenBlock());
        uint256 released = balance.balanceOf(funderWallet);
        vm.prank(funderWallet);
        balance.transfer(address(this), released);

        address module = vm.deployCode("StatementBalanceModule.sol:StatementBalanceModule", abi.encode(address(core), deployed));
        _setBalanceModule(module);
        _setSwitches(true, true);

        balanceKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(deployed),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(INITIALIZER_HOOK)
        });
        vm.prank(LBP_STRATEGY);
        PM.initialize(balanceKey, PARITY_SQRT);
        lp = new TestLiquidityHelper();
        balance.approve(address(lp), type(uint256).max);
        balance.approve(address(router), type(uint256).max);
        vm.deal(address(this), address(this).balance + 10 ether);
        uint256 ethBeforeLiquidity = address(this).balance;
        uint256 tokenBeforeLiquidity = balance.balanceOf(address(this));
        lp.modify{value: 1 ether}(balanceKey, -887220, 887220, int256(BASE_LIQUIDITY));
        poolEthDepth = ethBeforeLiquidity - address(this).balance;
        poolTokenDepth = tokenBeforeLiquidity - balance.balanceOf(address(this));
        assertGt(poolEthDepth, 0.6 ether);
        assertLt(poolEthDepth, 0.8 ether);
        assertEq(PM.getLiquidity(balanceKey.toId()), BASE_LIQUIDITY);

        IControllerV1.PoolKey memory key = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(deployed),
            fee: 3000,
            tickSpacing: 60,
            hooks: INITIALIZER_HOOK
        });
        uint256 spot = FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, PARITY_SQRT), FixedPoint96.Q96, PARITY_SQRT);
        vm.prank(owner);
        ctl.setBalancePoolKey(key, spot);
        vm.prank(owner);
        ctl.setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 450,
            referenceMaxStale: 1 hours,
            referenceMinSeconds: 600,
            minLiquidity: uint128(BASE_LIQUIDITY)
        }));
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.balanceBidCapBps = 11_000;
        s.spendCapBps = 9_999;
        s.saleFloorBps = 5_000;
        _setSettings(s);
    }

    // promise: the pinned launch token, exact redemption unit and canonical pool key do not make a
    // cross-refresh Credit sale safe merely because a synthetic token was replaced.
    function test_realLaunchTokenCrossRefreshSell() public {
        _addToPot(10 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 beforeSeller = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        uint256 baseline = seller.balance - beforeSeller;
        vm.revertToState(snap);

        uint256 trade = 0.023 ether;
        uint256 beforeToken = balance.balanceOf(address(this));
        uint256 gasStart = gasleft();
        router.swap{value: trade}(balanceKey, true, -int256(trade), address(this));
        uint256 gasUsed = gasStart - gasleft();
        uint256 bought = balance.balanceOf(address(this)) - beforeToken;
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        gasStart = gasleft();
        ctl.refreshReference();
        gasUsed += gasStart - gasleft();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        beforeSeller = seller.balance;
        gasStart = gasleft();
        vm.prank(seller);
        core.sellForEth(ids);
        gasUsed += gasStart - gasleft();
        uint256 manipulated = seller.balance - beforeSeller;
        uint256 beforeReverse = address(this).balance;
        gasStart = gasleft();
        router.swap(balanceKey, false, -int256(bought), address(this));
        gasUsed += gasStart - gasleft();
        uint256 poolLoss = trade - (address(this).balance - beforeReverse);
        uint256 gasCost = (gasUsed + 4 * 21_000) * TEST_GAS_PRICE;
        emit log_named_uint("production-token baseline payout wei", baseline);
        emit log_named_uint("production-token manipulated payout wei", manipulated);
        emit log_named_uint("production-token pool loss wei", poolLoss);
        emit log_named_uint("production-token 0.1 gwei gas wei", gasCost);
        emit log_named_uint("scenario initial pool ETH wei", poolEthDepth);
        emit log_named_uint("scenario initial pool BALANCE wei", poolTokenDepth);
        assertGt(manipulated - baseline, poolLoss + gasCost);
    }

    // promise: a Credit sale price quoted against the launch token cannot be discounted by holding a
    // manipulated pool price through one due refresh when the round trip costs less than the discount.
    function test_realLaunchTokenCrossRefreshCreditBuy() public {
        _setCreditSaleOn(true);
        _addToPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 baseline = ctl.creditPrice(id);
        ctl.buyCredit{value: baseline}(id);
        vm.revertToState(snap);

        uint256 tokenSold = 470 ether;
        uint256 beforeSwap = address(this).balance;
        uint256 gasStart = gasleft();
        router.swap(balanceKey, false, -int256(tokenSold), address(this));
        uint256 gasUsed = gasStart - gasleft();
        uint256 ethReceived = address(this).balance - beforeSwap;
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        gasStart = gasleft();
        ctl.refreshReference();
        gasUsed += gasStart - gasleft();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 discounted = ctl.creditPrice(id);
        gasStart = gasleft();
        ctl.buyCredit{value: discounted}(id);
        gasUsed += gasStart - gasleft();
        uint256 beforeReverse = address(this).balance;
        gasStart = gasleft();
        router.swap{value: 1 ether}(balanceKey, true, int256(tokenSold), address(this));
        gasUsed += gasStart - gasleft();
        uint256 poolLoss = beforeReverse - address(this).balance - ethReceived;
        uint256 gasCost = (gasUsed + 4 * 21_000) * TEST_GAS_PRICE;
        emit log_named_uint("production-token ordinary ask wei", baseline);
        emit log_named_uint("production-token discounted ask wei", discounted);
        emit log_named_uint("production-token buy pool loss wei", poolLoss);
        emit log_named_uint("production-token buy 0.1 gwei gas wei", gasCost);
        assertGt(baseline - discounted, poolLoss + gasCost);
    }

    // promise: the production pool's depth gate cannot be satisfied by liquidity present only at two refreshes.
    function test_realLaunchTokenTwoJitRefreshes() public {
        vm.prank(owner);
        ctl.setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 450,
            referenceMaxStale: 1 hours,
            referenceMinSeconds: 600,
            minLiquidity: uint128(BASE_LIQUIDITY * 2)
        }));
        TestLiquidityHelper jit = new TestLiquidityHelper();
        balance.approve(address(jit), type(uint256).max);
        (, bool before) = ctl.valuePerPoint(false);
        assertFalse(before);
        for (uint256 i; i < 2; ++i) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            jit.modify{value: 1 ether}(balanceKey, -887220, 887220, int256(BASE_LIQUIDITY));
            assertEq(PM.getLiquidity(balanceKey.toId()), BASE_LIQUIDITY * 2);
            assertTrue(ctl.refreshReference());
            jit.modify(balanceKey, -887220, 887220, -int256(BASE_LIQUIDITY));
            assertEq(PM.getLiquidity(balanceKey.toId()), BASE_LIQUIDITY);
        }
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        (, bool after_) = ctl.valuePerPoint(false);
        emit log_named_uint("production-token JIT min liquidity", BASE_LIQUIDITY * 2);
        emit log_named_uint("production-token JIT live liquidity", PM.getLiquidity(balanceKey.toId()));
        assertTrue(after_);
    }
}
