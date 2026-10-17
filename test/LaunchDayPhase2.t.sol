// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LaunchDayBase} from "./LaunchDay.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, IBalanceModule} from "../src/interfaces/Interfaces.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice a launch day with the balance side on, wired the way the Seed post section does it (the dev balance token and
/// `MockBalanceModule`, not the private production artifact): a native eth / balance token pool at the dev sqrt price
/// with full range liquidity, the module holding the launch allocation, and both balance switches on. sellers take
/// `sellForBalance` when the balance quote beats the eth bid and `sellForEth` otherwise, a statement redeems at its
/// floor, the balance bid never exceeds par, and every balance fill equals `balanceBidOf`
contract LaunchDayPhase2Test is LaunchDayBase {
    /// @dev the dev config values the Seed post section uses (script/config/anvil.json .dev)
    uint256 internal constant DEV_UNIT = 100000000000000; // balanceUnitPerPoint
    uint160 internal constant DEV_SQRT = uint160(11318308930609191084791992905142); // balancePoolSqrtPriceX96
    uint256 internal constant DEV_MINT_TO_MODULE = 1e24;
    int24 internal constant TICK_FULL = 887_220;

    PoolKey internal balKey;
    TestLiquidityHelper internal lp;
    uint256 internal balanceFills;
    uint256 internal ethFills;

    function setUp() public override {
        super.setUp();
        autoBook = true; // book after each swap so the pot funds the bid and the composed page
        _wireBalanceSide();
    }

    /// wires the balance token, module and pool the way script/dev/Seed.s.sol's post section does: the module holds the
    /// launch allocation, a native eth / balance pool is initialized at the dev sqrt price with full range liquidity,
    /// the module and both switches are set, and the controller's pool key follows the token
    function _wireBalanceSide() internal {
        xt = new MockBalanceToken("Balance", "BALANCE");
        mod = new MockBalanceModule(address(xt), DEV_UNIT);
        xt.mint(address(mod), DEV_MINT_TO_MODULE);
        xt.mint(address(this), 1e24);

        balKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(balKey, DEV_SQRT);
        lp = new TestLiquidityHelper();
        xt.approve(address(lp), type(uint256).max);
        vm.deal(address(this), address(this).balance + 2_000 ether);
        lp.modify{value: 2_000 ether}(balKey, -TICK_FULL, TICK_FULL, int256(1e21));

        _setBalanceModule(address(mod));
        _setSwitches(true, true);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        uint256 spot = FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, DEV_SQRT), FixedPoint96.Q96, DEV_SQRT);
        vm.prank(owner);
        ctl.setBalancePoolKey(k, spot);
    }

    // promise: SPEC 4 the balance side on at launch: sellers choose the balance door when its eth value beats the eth
    // bid, the balance fill equals balanceBidOf, the balance bid never exceeds par, and a statement redeems at its floor
    function test_phase2DayWithDevModule() public {
        _phase2Day();
        assertGe(balanceFills, 1, "at least one sale went through the balance door while it beat the eth bid");
        console.log("balance fills:", balanceFills);
        console.log("eth fills:", ethFills);
    }

    /// @dev the balance day: fund the pot, then run organic sellers that pick the better of the two quotes across the
    /// day, and redeem a composed statement at its floor. the first sell lands at the opening eth bid (so the balance
    /// quote beats it); the eth bid climbs over the following hours, so the later sells flip to the eth door
    function _phase2Day() internal {
        _fundPot(5 ether); // funded in the opening block, before the eth bid has climbed

        uint256[3] memory waits = [uint256(0), 1 hours, 6 hours];
        for (uint256 i; i < waits.length; ++i) {
            if (waits[i] != 0) {
                vm.warp(block.timestamp + waits[i]);
                vm.roll(block.number + 1);
            }
            _sellBetterQuote(_credits(seller, 1)[0]);
        }

        // a composed statement redeems into the balance module once its curve reaches the floor
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        assertTrue(ctl.atFloor(sid), "the statement reached its redemption floor");
        uint256 holdBefore = _holding();
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertGt(_holding() - holdBefore, 0, "the redeem minted balance token into the module");
        _solvent();
    }

    /// @dev a seller of credit `id` compares the eth value of the balance quote with the eth bid and sells through the
    /// door that pays more. asserts the chosen fill equals its quote, and that the balance bid never exceeds par
    function _sellBetterQuote(uint256 id) internal {
        uint256 score = _scoreOf(id);
        uint256 unit = IBalanceModule(core.balanceModule()).unitPerPoint();
        uint256 balBid = core.balanceBidOf(id);
        assertLe(balBid, score * unit, "the balance bid never exceeds par");
        uint256 ethBid = core.bidOf(id);
        (uint256 spot,) = ctl.spotPrice();
        uint256 balEth = balBid * spot / 1e18;
        if (balEth >= ethBid) {
            uint256 before = IERC20Min(core.balanceToken()).balanceOf(seller);
            vm.prank(seller);
            core.sellForBalance(_one(id));
            assertEq(IERC20Min(core.balanceToken()).balanceOf(seller) - before, balBid, "the balance fill equals balanceBidOf");
            ++balanceFills;
        } else {
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(id));
            assertEq(seller.balance - before, ethBid, "the eth fill equals bidOf");
            ++ethFills;
        }
    }

    /// @dev the balance token the module holds
    function _holding() internal view returns (uint256) {
        return IERC20Min(core.balanceToken()).balanceOf(core.balanceModule());
    }

    // promise: SPEC 4 the balance door against the pinned production module and Jack's token: the renderer is registered,
    // the funder retires the launch supply, a statement redeems once transfers open, and a seller then takes the balance bid.
    // the artifact comes from script/tools/upstream-balance.sh; the test skips without it and fails when
    // REQUIRE_UPSTREAM_BALANCE=true
    function test_phase2DayWithProductionModule() public {
        if (!vm.exists("out/upstream-balance.json")) {
            require(!vm.envOr("REQUIRE_UPSTREAM_BALANCE", false), "run script/tools/upstream-balance.sh first");
            vm.skip(true);
            return;
        }
        (address token, address module, address funderWallet) = _deployProduction();
        IUpstreamToken up = IUpstreamToken(token);
        _registerAndRetire(up, funderWallet);

        // the module advertises nothing until a statement redeems into it and transfers open
        _skipSniperWindow();
        _fundPot(5 ether);
        assertEq(IBalanceModule(module).available(), 0, "no reserve before the first redemption");
        uint256 owed = _redeemAtOpening(up, IBalanceModule(module));
        _sellThroughModule(token, IBalanceModule(module), owed);
    }

    /// @dev the pinned upstream token and the StatementBalanceModule, wired the way test/UpstreamBalance.t.sol builds
    /// them, with the balance pool and the controller's pool key retargeted to the token
    function _deployProduction() internal returns (address token, address module, address funderWallet) {
        funderWallet = _user("phase2.upstreamFunder");
        bytes memory init = abi.encodePacked(
            vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object"),
            abi.encode(
                address(STATEMENTS),
                uint8(IUpstreamStatements(address(STATEMENTS)).formatCount()),
                uint64(block.number + 100),
                funderWallet,
                _user("phase2.upstreamAuction"),
                _user("phase2.upstreamLiquidity")
            )
        );
        assembly ("memory-safe") {
            token := create(0, add(init, 32), mload(init))
        }
        require(token != address(0), "upstream deployment failed");
        module = vm.deployCode("StatementBalanceModule.sol:StatementBalanceModule", abi.encode(address(core), token));
        _setBalanceModule(module);
        _setSwitches(true, true);
        PM.initialize(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            DEV_SQRT
        );
        vm.prank(owner);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, DEV_SQRT), FixedPoint96.Q96, DEV_SQRT)
        );
    }

    /// @dev the upstream launch steps: the Statements owner registers the Balance renderer, then the funder surrenders
    /// a composed page and retires the launch supply
    function _registerAndRetire(IUpstreamToken up, address funderWallet) internal {
        IUpstreamStatements source = IUpstreamStatements(address(STATEMENTS));
        address renderer = up.renderer();
        vm.prank(source.owner());
        source.addFormat(renderer, "Balance");
        uint256[] memory ids = _credits(funderWallet, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.startPrank(funderWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 funderSid = STATEMENTS.compose(page, 0);
        source.approve(address(up), funderSid);
        up.withdraw(funderSid, up.quote(funderSid));
        up.retireLaunchSupply();
        vm.stopPrank();
        assertEq(up.totalRetired(), up.launchRetirement(), "launch supply retired");
    }

    /// @dev composes and redeems one statement at the opening block; returns the token the module then holds
    function _redeemAtOpening(IUpstreamToken up, IBalanceModule module) internal returns (uint256 owed) {
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.roll(up.transfersOpenBlock());
        owed = up.quote(sid);
        assertEq(owed, core.ratingOf(sid) * module.unitPerPoint(), "upstream quote is rating times unit");
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(module.available(), owed, "the redemption funds the module at par");
    }

    /// @dev the balance bid answers and pays through the real module
    function _sellThroughModule(address token, IBalanceModule module, uint256 owed) internal {
        uint256 id = _credits(seller, 1)[0];
        uint256 bid = core.balanceBidOf(id);
        assertGt(bid, 0, "the balance bid is live");
        assertLe(bid, _scoreOf(id) * module.unitPerPoint(), "the balance bid never exceeds par");
        uint256 before = IERC20Min(token).balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(_one(id));
        assertEq(IERC20Min(token).balanceOf(seller) - before, bid, "the balance fill equals balanceBidOf");
        assertEq(module.available(), owed - bid, "the module paid the fill");
    }
}

interface IUpstreamToken {
    function renderer() external view returns (address);
    function quote(uint256) external view returns (uint256);
    function withdraw(uint256, uint256) external returns (uint256);
    function retireLaunchSupply() external;
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function transfersOpenBlock() external view returns (uint64);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address, string calldata) external returns (uint8);
    function approve(address, uint256) external;
}
