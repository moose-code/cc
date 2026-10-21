// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {ICredits, IStatements, CreditSale, Settings, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {StatementBalanceModule} from "../../src/adapters/StatementBalanceModule.sol";
import {Phase2BalanceTreasury} from "../../src/adapters/Phase2BalanceTreasury.sol";
import {ProRataRedemptionPolicy} from "../../src/adapters/ProRataRedemptionPolicy.sol";
import {ControllerV2} from "../../src/ControllerV2.sol";
import {Quote} from "../../src/interfaces/Interfaces.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";
import {Phase2BalanceTokenStandin} from "../../test/standins/Phase2BalanceTokenStandin.sol";
import {StandingBidPolicy} from "../../src/adapters/StandingBidPolicy.sol";
import {TestLiquidityHelper} from "../../test/utils/TestLiquidityHelper.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// the ConversionLineageWithdrawals surface the production balance wiring reads from the pinned artifact.
interface IUpstreamToken {
    function renderer() external view returns (address);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
    function retireLaunchSupply() external;
    function opensAt() external view returns (uint64);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address renderer, string calldata name) external returns (uint8);
    function approve(address to, uint256 id) external;
}

/// @notice seeds the anvil fork after `script/deploy.sh local`.
///
/// PHASE=pre moves real Credits from the CreditStrategy to A1, A2 and A3.
///
/// PHASE=post then wires Jack's balance side from the pinned artifact `out/upstream-balance.json`
/// (`script/tools/upstream-balance.sh`), which is required: there is no mock fallback. It deploys Jack's
/// `ConversionLineageWithdrawals` through the deterministic CREATE2 factory, gives a funder 80 real Credits, registers the
/// Balance renderer as the Statements owner, has the funder compose a page, withdraw and retire the launch supply, then
/// deploys `StatementBalanceModule` and initializes a native eth / balance token v4 pool (hooks address zero, fee 3000,
/// spacing 60) at `dev.balancePoolSqrtPriceX96` with no trading depth (Jack's token reaches the module only through
/// redemptions, which the scenario drives). As owner it sets the module, switches `redeemOn` and `balanceBidOn` on,
/// points the controller at the pool, and switches the credit sale and chosen composition on.
///
/// pool price: the balance token is currency1, so the pool price is balance token base units per wei and
/// `sqrtPriceX96 = sqrt(price) * 2^96`. 100 points is 1,000,000 stored units, worth
/// `1,000,000 * dev.balanceUnitPerPoint` = 1e20 base units. At the opening bid `rateStart` = 4.65e15 wei,
/// `price = 1e20 / 4.65e15` is about 21,505 and `sqrtPriceX96` = 11618581461159793320010313039067, so `valueOf` of a
/// 100 point credit is approximately the bid.
///
/// the dev wallet `dev.wallet` of the launch config also receives `dev.walletCredits` credits from the strategy in both
/// phases. its eth (`dev.walletEth`) is set by `script/dev/e2e.sh` and its coin comes from the Scenario stage
/// `dev-wallet`. a config without `dev.wallet` skips it. Jack's balance token is not freely mintable, so the dev wallet
/// holds none; it receives balance token only by selling Credits into the balance bid.
///
/// PHASE=phase2 wires the phase 2 stack (decisions 245 to 252) for the local UI: the standin balance token
/// (`test/standins/Phase2BalanceTokenStandin.sol`, every upstream gate open, mintable; the real auction token cannot
/// open its transfer gate on a fork without its auction), `ProRataRedemptionPolicy`, `Phase2BalanceTreasury` and
/// `ControllerV2` from the production sources. As owner it selects the treasury and ControllerV2, sets
/// `creditCostToPotBps` 10,000 and the three buyback shares to 0, turns `redeemOn` on and, with no pool key set (so no
/// hazard state), `balanceBidOn` on, funds the treasury with `PHASE2_WORKING` (default 50,000) BALANCE of working funds
/// and allocates `PHASE2_CLAIMS` (default 10,000) to claims, turns every treasury switch and statement sales on. The
/// dev wallet gets CC from the Scenario `dev-wallet` stage, so `/exchange` can sell Credits and burn CC locally.
///
/// PHASE=phase2 with BID=1 adds the standing bid (decision 258): a native eth / standin pool with full range liquidity
/// priced so the bid per CC sits at `BID_SHARE_MULTIPLE` times the proportional share of the claim reserve, ControllerV2's
/// pool key and quote on it, `StandingBidPolicy` installed on the treasury (the switches set again, since
/// `setRedemptionPolicy` turns CC redemption off) with its own quote inside its bounds, and a bid budget of `BID_BUDGET_PER_DAY` and
/// `BID_BUDGET_MAX` (default 10 and 30 BALANCE). the policy's CC reference cannot be seeded here: the coin pool has
/// no active liquidity before its first buy, so the Scenario stage `standing-bid` seeds it after stage `a`. with the
/// pool key set, `balanceBidOn` on and value mode off the node sits in the hazard state of docs/RUNBOOK.md (a balance
/// token priced above the curve opens a round trip); that is a local dev state like ALLOW_MODE_OFF_BALANCE_BID.
///
/// env: A1 A2 A3, DEPLOYER (the owner), PHASE (pre, post or phase2, default post), and for post and phase2 CORE and
/// TRADER. optional N1 N2 N3 (credits moved, default 330 10 10), LAUNCH_CONFIG (default script/config/anvil.json),
/// BID (phase2 only, 1 adds the standing bid).
contract Seed is Script {
    /// @dev credits the CreditStrategy lists for sale at the pin block, skipped when credits are moved
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;

    /// the funder that surrenders a page and retires Jack's launch supply on the fork (production post only)
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;
    /// Arachnid's deterministic deployment proxy, present on the mainnet fork
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal cursor;

    function run() external {
        address owner = vm.envAddress("DEPLOYER");
        string memory cfg = vm.readFile(vm.envOr("LAUNCH_CONFIG", string("script/config/anvil.json")));
        bool hasWallet = vm.keyExistsJson(cfg, ".dev.wallet");
        address wallet = hasWallet ? vm.parseJsonAddress(cfg, ".dev.wallet") : address(0);
        _move(vm.envAddress("A1"), vm.envOr("N1", uint256(330)));
        _move(vm.envAddress("A2"), vm.envOr("N2", uint256(10)));
        _move(vm.envAddress("A3"), vm.envOr("N3", uint256(10)));
        if (hasWallet) _move(wallet, vm.parseJsonUint(cfg, ".dev.walletCredits"));
        bytes32 phase = keccak256(bytes(vm.envOr("PHASE", string("post"))));
        if (phase == keccak256("pre")) return;
        if (phase == keccak256("phase2")) {
            _seedPhase2(owner, ICore(payable(vm.envAddress("CORE"))));
            return;
        }

        ICore core = ICore(payable(vm.envAddress("CORE")));
        uint160 poolSqrt = uint160(vm.parseJsonUint(cfg, ".dev.balancePoolSqrtPriceX96"));

        // the artifact is required: no mock fallback on the phase 2 path (owner directive)
        require(vm.exists("out/upstream-balance.json"), "run script/tools/upstream-balance.sh");
        console.log("== PRODUCTION MODULE (Seed post): Jack's pinned ConversionLineageWithdrawals ==");
        (address token, address module) = _deployProduction(owner, poolSqrt);

        IControllerV1 ctl = IControllerV1(core.controller());
        vm.startBroadcast(owner);
        core.setBalanceModule(module);
        Settings memory s = core.settings();
        s.redeemOn = true;
        // the balance bid opens after value mode (docs/RUNBOOK.md). ALLOW_MODE_OFF_BALANCE_BID=1 is the dev opt-in for
        // scenarios that sell for balance with value mode off
        s.balanceBidOn = vm.envOr("ALLOW_MODE_OFF_BALANCE_BID", false);
        core.setSettings(s);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            // the expected eth spot, wei per 1e18 base units, from the pool sqrt the script just initialized
            FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, poolSqrt), FixedPoint96.Q96, poolSqrt)
        );
        ctl.setCredit(
            CreditSale({
                saleOn: true,
                window: ctl.creditWindow(),
                spreadBps: ctl.creditSpreadBps(),
                startBps: ctl.creditStartBps()
            })
        );
        core.setChosenComposeOn(true);
        vm.stopBroadcast();

        // preflight: balance bid on, value mode off and a pool key set is the round trip hazard state
        Settings memory after_ = core.settings();
        require(
            !(after_.balanceBidOn && !after_.valueModeOn && ctl.balancePoolKeySet()),
            "preflight: balanceBidOn with value mode off and a pool key set"
        );

        console.log("BALANCE_TOKEN", token);
        console.log("BALANCE_MODULE", module);
        console.log("OPENS_AT", uint256(IUpstreamToken(token).opensAt()));
    }

    /// @dev the phase 2 stack on the standin token, every switch on, for the local web and keeper
    function _seedPhase2(address owner, ICore core) internal {
        console.log("== PHASE 2 (Seed phase2): standin balance token, treasury, pro rata policy, ControllerV2 ==");
        uint256 workingFunds = vm.envOr("PHASE2_WORKING", uint256(50_000 ether));
        uint256 claims = vm.envOr("PHASE2_CLAIMS", uint256(10_000 ether));
        IControllerV1 ctl = IControllerV1(core.controller());
        CreditSale memory credit = CreditSale({
            saleOn: true, window: ctl.creditWindow(), spreadBps: ctl.creditSpreadBps(), startBps: ctl.creditStartBps()
        });
        Quote memory none;

        vm.startBroadcast(owner);
        Phase2BalanceTokenStandin token = new Phase2BalanceTokenStandin();
        token.open();
        ProRataRedemptionPolicy policy = new ProRataRedemptionPolicy();
        Phase2BalanceTreasury treasury =
            new Phase2BalanceTreasury(address(core), address(token), address(policy), address(0));
        ControllerV2 v2 = new ControllerV2(address(core), credit, none, 15_000, 3_600);
        token.mint(address(treasury), workingFunds + claims);

        core.setBalanceModule(address(treasury));
        core.setController(address(v2));
        core.setCreditCostToPotBps(10_000);
        Settings memory s = core.settings();
        s.redeemOn = true;
        s.saleToBuybackBps = 0;
        s.feeToRedeemBurnBps = 0;
        s.redeemBurnBps = 0;
        // no pool key is set on ControllerV2, so the bid on with value mode off is not the hazard state; the local
        // exchange sells Credits at the posted 90 percent
        s.balanceBidOn = true;
        core.setSettings(s);
        core.setChosenComposeOn(true);
        treasury.setSwitches(true, true, true);
        treasury.allocateToClaims(claims);
        v2.setStatementSales(true);
        vm.stopBroadcast();

        require(!v2.balancePoolKeySet(), "phase2: no pool key expected");
        require(treasury.available() == workingFunds, "phase2: available is the working funds");
        require(treasury.claimReserve() == claims, "phase2: claims allocated");
        console.log("BALANCE_TOKEN", address(token));
        console.log("BALANCE_MODULE", address(treasury));
        console.log("CONTROLLER_V2", address(v2));
        console.log("POLICY", address(policy));
        if (keccak256(bytes(vm.envOr("BID", string("0")))) == keccak256("1")) {
            _seedStandingBid(owner, treasury, v2, token);
        }
    }

    /// full range for tick spacing 60, a multiple of 60
    int24 internal constant TICK_FULL = 887_220;
    /// the bid per CC over the proportional share of the claim reserve at seed, so the local panel quotes the bid
    uint256 internal constant BID_SHARE_MULTIPLE = 4;
    /// the eth leg of the standin pool's full range position; the token leg follows from the price
    uint256 internal constant BID_POOL_ETH = 1 ether;

    /// @dev the standing bid on the standin: its pool, ControllerV2's reference on it, the policy and the budget
    function _seedStandingBid(
        address owner,
        Phase2BalanceTreasury treasury,
        ControllerV2 v2,
        Phase2BalanceTokenStandin token
    ) internal {
        console.log("== STANDING BID (Seed phase2, BID=1): eth/standin pool, ControllerV2 reference, policy, budget ==");
        uint256 perDay = vm.envOr("BID_BUDGET_PER_DAY", uint256(10 ether));
        uint256 max = vm.envOr("BID_BUDGET_MAX", uint256(30 ether));
        // ControllerV2's reference on the standin pool at the value mode settings the tests use; the policy's own
        // bounds are tighter (tolBps at most 100, the rate at most 1,000 per hour), so it gets its own quote
        Quote memory q = Quote({
            referenceRateBpsPerHour: 1_000,
            referenceStepBps: 500,
            tolBps: 450,
            referenceMaxStale: 1 days,
            referenceMinSeconds: 0,
            minLiquidity: 1
        });
        Quote memory bidQuote = Quote({
            referenceRateBpsPerHour: 200,
            referenceStepBps: 100,
            tolBps: 0,
            referenceMaxStale: 1 days,
            referenceMinSeconds: 0,
            minLiquidity: 1
        });

        vm.broadcast(owner);
        StandingBidPolicy bid = new StandingBidPolicy(address(treasury));

        // the standin's eth price from the two live reads: the coin pool spot (initialized at launch, priced before its
        // first buy) and the share per CC, so `bidPerCC` lands at BID_SHARE_MULTIPLE times the share
        (uint256 ccSpot, bool priced) = bid.ccSpot();
        require(priced && ccSpot != 0, "bid: the coin pool has no price");
        (uint256 sharePerCC,,) = treasury.redemptionTerms(1e18);
        require(sharePerCC != 0, "bid: no share per CC");
        uint256 balSpot = FullMath.mulDiv(
            ccSpot * (10_000 + bid.premiumBps()), 1e18, 10_000 * sharePerCC * BID_SHARE_MULTIPLE
        );
        // sqrtPriceX96 = 2^96 * sqrt(1e18 / spot), the inverse of the spot read within its rounding
        uint160 sqrt = uint160(FullMath.mulDiv(FixedPoint96.Q96, FixedPointMathLib.sqrt(1e36 / balSpot), 1e9));
        uint256 spot = FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, sqrt), FixedPoint96.Q96, sqrt);
        // full range liquidity with BID_POOL_ETH on the eth leg: amount0 is about liq * 2^96 / sqrt and amount1 about
        // liq * sqrt / 2^96; the helper pulls the token leg and refunds the eth it does not need
        uint128 liq = uint128(FullMath.mulDiv(BID_POOL_ETH, sqrt, FixedPoint96.Q96));
        uint256 tokens = FullMath.mulDivRoundingUp(liq, sqrt, FixedPoint96.Q96) + 1;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.startBroadcast(owner);
        IPoolManager(Mainnet.POOL_MANAGER).initialize(key, sqrt);
        TestLiquidityHelper lp = new TestLiquidityHelper();
        token.mint(owner, tokens);
        token.approve(address(lp), tokens);
        lp.modify{value: BID_POOL_ETH * 105 / 100}(key, -TICK_FULL, TICK_FULL, int256(uint256(liq)));
        v2.setBalancePoolKey(key, spot);
        v2.setQuote(q);
        // the policy quotes the floor until its reference is seeded, so the install probe passes at any pool price;
        // installing turns CC redemption off, so the switches are set again
        treasury.setRedemptionPolicy(address(bid));
        treasury.setSwitches(true, true, true);
        bid.setQuote(bidQuote);
        treasury.setBidBudget(uint128(perDay), uint128(max));
        vm.stopBroadcast();

        require(v2.balancePoolKeySet(), "bid: ControllerV2 pool key not set");
        require(treasury.redemptionPolicy() == address(bid), "bid: policy not installed");
        require(treasury.ccRedemptionEnabled(), "bid: CC redemption off after the install");
        require(treasury.bidBudgetMax() == max, "bid: budget not set");
        (uint256 value, bool ok) = v2.valuePerPoint(true);
        require(ok && value != 0, "bid: the balance leg is unusable");
        (uint256 perCC, bool usable) = bid.bidPerCC();
        console.log("STANDING_BID_POLICY", address(bid));
        console.log("standin pool spot, wei per 1e18 BALANCE", spot);
        console.log("standin pool liquidity", uint256(liq));
        console.log("share per CC at seed", sharePerCC);
        console.log("bidPerCC at seed (0 until stage standing-bid seeds the CC reference)", perCC, usable);
        console.log("bidCapacity at seed", bid.bidCapacity());
    }

    /// @dev Jack's `ConversionLineageWithdrawals` from the pinned artifact, wired the way the production-module test does:
    /// the funder receives 80 real Credits, the Statements owner registers the renderer, the funder composes a page,
    /// withdraws and retires the launch supply, then the module is deployed and the pool is initialized at the config
    /// sqrt with no trading depth (Jack's token reaches the module only through redemptions, which the scenario drives).
    /// the token is deployed through the deterministic CREATE2 factory so its address is the same in simulation and on
    /// the node under `--broadcast`.
    function _deployProduction(address owner, uint160 poolSqrt) internal returns (address token, address module) {
        _moveToFunder(80);

        bytes memory creation = vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object");
        uint8 format = uint8(IUpstreamStatements(Mainnet.STATEMENTS).formatCount());
        bytes memory init = abi.encodePacked(creation, abi.encode(Mainnet.STATEMENTS, format, FUNDER));
        bytes32 salt = bytes32(0);
        token =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_PROXY, salt, keccak256(init))))));
        vm.broadcast(owner);
        (bool ok,) = CREATE2_PROXY.call(abi.encodePacked(salt, init));
        require(ok, "seed: token CREATE2 failed");
        require(token.code.length != 0, "seed: token not deployed at the computed address");

        address renderer = IUpstreamToken(token).renderer();
        vm.broadcast(IUpstreamStatements(Mainnet.STATEMENTS).owner());
        IUpstreamStatements(Mainnet.STATEMENTS).addFormat(renderer, "Balance");

        uint256[80] memory page;
        uint256[] memory ids = CREDITS.tokensOf(FUNDER);
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.broadcast(FUNDER);
        CREDITS.setApprovalForAll(Mainnet.STATEMENTS, true);
        vm.broadcast(FUNDER);
        uint256 funderSid = IStatements(Mainnet.STATEMENTS).compose(page, 0);
        vm.broadcast(FUNDER);
        IUpstreamStatements(Mainnet.STATEMENTS).approve(token, funderSid);
        uint256 q = IUpstreamToken(token).quote(funderSid);
        vm.broadcast(FUNDER);
        IUpstreamToken(token).withdraw(funderSid, q);
        vm.broadcast(FUNDER);
        IUpstreamToken(token).retireLaunchSupply();

        vm.broadcast(owner);
        module = address(new StatementBalanceModule(address(ICore(payable(vm.envAddress("CORE")))), token));

        vm.broadcast(owner);
        IPoolManager(Mainnet.POOL_MANAGER)
            .initialize(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(token),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                }),
                poolSqrt
            );
        console.log("module holding starts at 0 until the first redemption");
    }

    /// @dev moves `n` real Credits from the strategy to the funder, skipping the strategy's listings
    function _moveToFunder(uint256 n) internal {
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            // the fork can sit past the CreditIds capture block, so some listed ids no longer exist; skip those and any
            // the strategy no longer holds
            try CREDITS.ownerOf(id) returns (address holder) {
                if (holder != STRATEGY) continue;
            } catch {
                continue;
            }
            vm.broadcast(STRATEGY);
            CREDITS.transferFrom(STRATEGY, FUNDER, id);
            ++got;
        }
    }

    /// @dev moves `n` real credits from the strategy to `to`, skipping the listed ids
    function _move(address to, uint256 n) internal {
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            if (CREDITS.ownerOf(id) != STRATEGY) continue;
            vm.broadcast(STRATEGY);
            CREDITS.transferFrom(STRATEGY, to, id);
            ++got;
        }
        console.log("seeded credits", to, n);
    }
}
