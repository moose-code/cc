// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Scenario, IUniversalRouterR, IPermit2R, IERC20R} from "./Scenario.s.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {
    ICredits,
    ICreditScore,
    IStatements,
    IBalanceModule,
    Mainnet,
    Settings,
    Quote,
    CreditSale
} from "../../src/interfaces/Interfaces.sol";
import {StatementBalanceModule} from "../../src/adapters/StatementBalanceModule.sol";
import {TestSwapRouter} from "../../test/utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "../../test/utils/TestLiquidityHelper.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";

interface IPermit2AllowanceR {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// the ConversionLineageWithdrawals surface the production balance wiring reads from the pinned artifact.
interface IUpstreamToken {
    function renderer() external view returns (address);
    function decimals() external view returns (uint8);
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

/// @notice the action half of `script/dev/e2e-real.sh`: one external function per step of the real launch end to end,
/// every write a broadcast from an impersonated account (forge --unlocked against an anvil --auto-impersonate node)
/// through the same doors and quotes the web and the keeper use. the shell warps the node and reads the assertions with
/// cast between the steps; the keeper binary is the only engine caller for the keeper doors. every function reverts the
/// forge run on a broken invariant, which the shell reports as a FAIL.
///
/// env: CORE, OWNER, A1 A2 A3, TRADER, and for the balance and value steps LAUNCH_CONFIG (default script/config/anvil.json).
interface IERC20Transfer {
    function transfer(address to, uint256 value) external returns (bool);
}

contract E2EReal is Scenario {
    using StateLibrary for IPoolManager;

    uint160 internal constant DEV_SQRT = uint160(11318308930609191084791992905142);
    int24 internal constant TICK_FULL = 887_220;

    function _boot() internal {
        core = ICore(payable(vm.envAddress("CORE")));
        ctl = IControllerV1(core.controller());
        coin = core.COIN();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        OWNER = vm.envAddress("OWNER");
        A1 = vm.envAddress("A1");
        A2 = vm.envAddress("A2");
        A3 = vm.envAddress("A3");
        TRADER = vm.envAddress("TRADER");
    }

    function _cfg() internal view returns (string memory) {
        return vm.readFile(vm.envOr("LAUNCH_CONFIG", string("script/config/anvil.json")));
    }

    // ------------------------------------------------------------------ phase 1: launch settings

    /// restates the opening rate and the cap on the Core as the owner (the launch config already sets them; this is the
    /// explicit SetSettings of the launch step). no fund, no pot.
    function phase1Settings() external {
        _boot();
        Settings memory s = core.settings();
        s.rateCap = 14_700_000_000_000_000; // 1.47e16
        vm.broadcast(OWNER);
        core.setSettings(s);
        vm.broadcast(OWNER);
        core.setRate(4_900_000_000_000_000); // 4.9e15
        console.log("phase1: RATE_START", core.RATE_START());
        console.log("phase1: rateCap", uint256(core.settings().rateCap));
    }

    // ------------------------------------------------------------------ phase 2: real fee income through the hook

    /// `buys` coin buys and `sells` coin sells through the universal router from the trader, all inside the sniper
    /// window. the hook pushes the fee skim to the Core; no door books, so the income waits above the pots.
    function phase2Swaps(uint256 buys, uint256 sells) external {
        _boot();
        // buys sized so the sniper window tax leaves the pot well under the uint64 reserveWei ceiling (phase 4)
        for (uint256 i; i < buys; ++i) {
            vm.broadcast(TRADER);
            IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
                hex"10", _v4Swap(true, 0.5 ether), _deadline()
            );
        }
        _approveCoinSell(TRADER);
        uint256 held = IERC20R(coin).balanceOf(TRADER);
        for (uint256 i; i < sells; ++i) {
            uint256 amt = held / (sells + 1);
            vm.broadcast(TRADER);
            IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute(hex"10", _v4Swap(false, amt), _deadline());
        }
        console.log("phase2: buys", buys);
        console.log("phase2: sells", sells);
        console.log("phase2: core balance", address(core).balance);
        console.log("phase2: ethPot", core.ethPot());
    }

    function _approveCoinSell(address who) internal {
        vm.broadcast(who);
        IERC20R(coin).approve(Mainnet.PERMIT2, type(uint256).max);
        vm.broadcast(who);
        IPermit2R(Mainnet.PERMIT2).approve(coin, Mainnet.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
    }

    // ------------------------------------------------------------------ phase 4: direct eth sells at the bid

    /// A1 sells one credit through `sellForEth` and the fill pays exactly `bidOf` at this block.
    function phase4DirectSell() external {
        _boot();
        _approveCredits(A1);
        uint256[] memory one = _creditsOf(A1, 1);
        uint256 bid = core.bidOf(one[0]);
        require(bid > 0, "phase4: bid is zero");
        uint256 before = A1.balance;
        vm.broadcast(A1);
        core.sellForEth(one);
        uint256 paid = A1.balance - before;
        require(paid == bid, "phase4: the eth sell did not pay bidOf");
        console.log("phase4: direct sell credit", one[0]);
        console.log("phase4: bid / paid", bid, paid);
    }

    function _approveCredits(address who) internal {
        if (!ICredits(Mainnet.CREDITS).isApprovedForAll(who, address(core))) {
            vm.broadcast(who);
            ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        }
    }

    // ------------------------------------------------------------------ phase 4: credit sale buyer and the return lock

    /// opens the credit sale if needed, then A2 buys the oldest pile credit at `creditPrice`. prints the bought id so the
    /// shell drives the return lock step with it.
    function phase4CreditBuy() external {
        _boot();
        if (!ctl.creditSaleOn()) {
            CreditSale memory cs = CreditSale({
                saleOn: true,
                window: ctl.creditWindow(),
                spreadBps: ctl.creditSpreadBps(),
                startBps: ctl.creditStartBps()
            });
            vm.broadcast(OWNER);
            ctl.setCredit(cs);
        }
        uint256 id = core.pilePage(0, 1)[0];
        uint256 price = ctl.creditPrice(id);
        vm.broadcast(A2);
        ctl.buyCredit{value: price}(id);
        require(ICredits(Mainnet.CREDITS).ownerOf(id) == A2, "phase4: credit sale did not deliver to A2");
        console.log("phase4: credit sale buyer A2 bought", id);
        console.log("phase4: creditPrice", price);
        console.log("BOUGHT_CREDIT", id);
    }

    /// the return lock: A2 cannot sell credit `id` back to the engine inside the lock, A3 can once A2 transfers it. the
    /// sends go through the direct RPC path (Scenario `_send`), so the multi sender sequence does not race the forge
    /// nonce tracker under --slow. needs E2E_RPC_URL set to the node.
    function phase4ReturnLock(uint256 id) external {
        _boot();
        sellBucketSeconds = 0;
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        _send(A2, Mainnet.CREDITS, abi.encodeCall(ICredits.setApprovalForAll, (address(core), true)), 0);
        vm.prank(A2);
        (bool ok, bytes memory err) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", one));
        require(!ok && bytes4(err) == ICore.ReturnLocked.selector, "phase4: the return lock did not refuse A2");
        console.log("phase4: return lock refused A2 reselling", id);

        _send(A2, Mainnet.CREDITS, abi.encodeCall(ICredits.transferFrom, (A2, A3, id)), 0);
        _send(A3, Mainnet.CREDITS, abi.encodeCall(ICredits.setApprovalForAll, (address(core), true)), 0);
        uint256 before = A3.balance;
        _send(A3, address(core), abi.encodeWithSignature("sellForEth(uint256[])", one), 0);
        require(A3.balance > before, "phase4: A3 could not sell the transferred credit");
        console.log("phase4: A3 sold the transferred credit after the lock released it", id);
    }

    /// the reserve: when `ethPot` is at or under the reserve (`reserveWei` or 1.5 times the queued caller payments),
    /// `sellForEth` reverts `PotTooSmall`. phase 2's sniper window income floods the pot far past any reachable drain,
    /// so the owner raises `reserveWei` above the live pot to put the pot under the reserve, exercises the refusal, then
    /// restores it. the refusal path is identical to a pot drained to the reserve: the bid reads zero.
    function phase4Reserve() external {
        _boot();
        _approveCredits(A1);
        uint256 pot = core.ethPot();
        Settings memory s = core.settings();
        uint64 saved = s.reserveWei;
        s.reserveWei = uint64(pot + 1 ether > type(uint64).max ? type(uint64).max : pot + 1 ether);
        // the pot can exceed uint64; if so push the reserve to its max and confirm the pot still sits under it
        require(pot <= s.reserveWei, "phase4: pot exceeds the max reserve, cannot place it under the reserve");
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(core.ethPot() <= core.reserve(), "phase4: pot not under the reserve");

        uint256[] memory last = _creditsOf(A1, 1);
        vm.prank(A1);
        (bool ok, bytes memory err) = address(core).call(abi.encodeWithSignature("sellForEth(uint256[])", last));
        require(!ok && bytes4(err) == ICore.PotTooSmall.selector, "phase4: the reserve did not refuse the sell");
        console.log("phase4: pot / reserve", core.ethPot(), core.reserve());

        s.reserveWei = saved;
        vm.broadcast(OWNER);
        core.setSettings(s);
        console.log("phase4: sellForEth refused with PotTooSmall at the reserve, reserve restored");
    }

    // ------------------------------------------------------------------ phase 5: fill a page, buy the statement

    /// primes the bid and pot, then sells 80 of A1's credits into the eth bid so the pile holds a composable page.
    /// reuses Scenario's fill through the bucketed Anvil sends (needs E2E_RPC_URL set to the node).
    function phase5FillPile() external {
        _boot();
        sellBucketSeconds = core.settings().bucketSeconds;
        vm.rpc("anvil_removeBlockTimestampInterval", "[]");
        _approveCredits(A1);
        _fill(A1, 80, "phase5");
        console.log("phase5: pileSize", core.pileSize());
    }

    /// A2 buys the newest held statement at `priceOf`; asserts the artist and operator cuts came off the payment and a
    /// share went to the buyback pot.
    function phase5Buy() external {
        _boot();
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "phase5: no held statement");
        uint256 sid = held[held.length - 1];
        uint256 price = ctl.priceOf(sid);
        Settings memory s = core.settings();
        uint256 art0 = core.artist().balance;
        uint256 op0 = core.payee().balance;
        uint256 bb0 = core.ethToBuyback();
        vm.broadcast(A2);
        ctl.buy{value: price}(sid);
        require(core.artist().balance - art0 == price * s.saleToArtistBps / 10_000, "phase5: artist cut");
        require(core.payee().balance - op0 == price * s.saleToOperatorBps / 10_000, "phase5: operator cut");
        require(core.ethToBuyback() > bb0, "phase5: no buyback share");
        console.log("phase5: statement", sid);
        console.log("phase5: price / buyback share", price, core.ethToBuyback() - bb0);
    }

    // ------------------------------------------------------------------ phase 7: the balance sell (value mode on)

    /// A1 sells one credit into the balance bid with value mode on. the fill pays `min(posted, cap)`: a positive amount
    /// at most `balanceBidOf`, and `balanceBidOf` never exceeds par (score times the module unit per point). works
    /// against the dev mock and the production module alike, reading the unit through `IBalanceModule`.
    function phase7BalanceSell() external {
        _boot();
        _approveCredits(A1);
        uint256[] memory one = _creditsOf(A1, 1);
        uint256 id = one[0];
        uint256 balBid = core.balanceBidOf(id);
        require(balBid > 0, "phase7: balance bid is zero");
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        uint256 unit = IBalanceModule(core.balanceModule()).unitPerPoint();
        require(balBid <= score * unit, "phase7: balance bid exceeds par");
        IERC20R token = IERC20R(core.balanceToken());
        uint256 before = token.balanceOf(A1);
        vm.broadcast(A1);
        core.sellForBalance(one);
        uint256 paid = token.balanceOf(A1) - before;
        require(paid > 0 && paid <= balBid, "phase7: balance fill outside (0, balanceBidOf]");
        console.log("phase7: balance sell credit", id);
        console.log("phase7: balanceBidOf / paid", balBid, paid);
        console.log("phase7: buyToArtistBps", core.settings().buyToArtistBps);
    }

    // ---------------------------------------------------- phase 6 production: Jack's pinned contracts (the artifact)

    /// the funder address that surrenders a page and retires Jack's launch supply on the fork
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;

    /// deploys Jack's `ConversionLineageWithdrawals` from `out/upstream-balance.json` exactly as the production-module test
    /// does: the funder receives 80 real Credits, the Statements owner registers the Balance renderer, the funder
    /// composes a page, withdraws and retires the launch supply, then the owner deploys `StatementBalanceModule`, sets
    /// it, sets the phase-two fee reserve share, initializes a native eth / token pool at the dev sqrt and points
    /// the controller at it. every write goes through the node directly (`_send` / `_sendCreate`) so the deployed token
    /// address is the one the node assigns, not a simulated one. `opensAt` is a constant timestamp; the shell advances
    /// node time to it before the redemption.
    function phase6ProdDeploy() external {
        _boot();
        sellBucketSeconds = 0;
        _seedFunder(80);

        bytes memory creation = vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object");
        uint8 format = uint8(IUpstreamStatements(Mainnet.STATEMENTS).formatCount());
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(Mainnet.STATEMENTS, format, FUNDER)
        );
        address token = _sendCreate(OWNER, init);
        require(token != address(0), "phase6prod: token deploy failed");

        address renderer = IUpstreamToken(token).renderer();
        address stOwner = IUpstreamStatements(Mainnet.STATEMENTS).owner();
        _send(stOwner, Mainnet.STATEMENTS, abi.encodeCall(IUpstreamStatements.addFormat, (renderer, "Balance")), 0);

        uint256[80] memory page = _funderPage();
        _send(FUNDER, Mainnet.CREDITS, abi.encodeCall(ICredits.setApprovalForAll, (Mainnet.STATEMENTS, true)), 0);
        _send(FUNDER, Mainnet.STATEMENTS, abi.encodeCall(IStatements.compose, (page, uint8(0))), 0);
        uint256 funderSid = IStatements(Mainnet.STATEMENTS).supply();
        _send(FUNDER, Mainnet.STATEMENTS, abi.encodeCall(IUpstreamStatements.approve, (token, funderSid)), 0);
        uint256 q = IUpstreamToken(token).quote(funderSid);
        _send(FUNDER, token, abi.encodeCall(IUpstreamToken.withdraw, (funderSid, q)), 0);
        _send(FUNDER, token, abi.encodeCall(IUpstreamToken.retireLaunchSupply, ()), 0);

        bytes memory moduleInit =
            abi.encodePacked(type(StatementBalanceModule).creationCode, abi.encode(address(core), token));
        address module = _sendCreate(OWNER, moduleInit);

        bytes memory initPool = abi.encodeCall(
            IPoolManager.initialize,
            (
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(token),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                }),
                DEV_SQRT
            )
        );
        _send(OWNER, Mainnet.POOL_MANAGER, initPool, 0);

        uint256 spot = FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, DEV_SQRT), FixedPoint96.Q96, DEV_SQRT);
        _send(OWNER, address(core), abi.encodeCall(ICore.setBalanceModule, (module)), 0);
        Settings memory s = core.settings();
        s.redeemOn = true;
        s.feeToRedeemBurnBps = 1_000;
        _send(OWNER, address(core), abi.encodeCall(ICore.setSettings, (s)), 0);
        _send(
            OWNER,
            address(ctl),
            abi.encodeCall(
                IControllerV1.setBalancePoolKey,
                (
                    IControllerV1.PoolKey({
                        currency0: IControllerV1.Currency.wrap(address(0)),
                        currency1: IControllerV1.Currency.wrap(token),
                        fee: 3000,
                        tickSpacing: 60,
                        hooks: address(0)
                    }),
                    spot
                )
            ),
            0
        );

        require(core.balanceModule() == module, "phase6prod: module not set");
        require(core.settings().feeToRedeemBurnBps == 1_000, "phase6prod: fee reserve share not set");
        // preflight: balance bid on, value mode off and a pool key set is the round trip hazard state
        Settings memory after_ = core.settings();
        require(
            !(after_.balanceBidOn && !after_.valueModeOn && ctl.balancePoolKeySet()),
            "phase6prod: balanceBidOn with value mode off and a pool key set"
        );
        console.log("== PRODUCTION MODULE: Jack's pinned ConversionLineageWithdrawals ==");
        console.log("BALANCE_TOKEN", token);
        console.log("BALANCE_MODULE", module);
        console.log("OPENS_AT", uint256(IUpstreamToken(token).opensAt()));
    }

    /// A1 sells 80 credits into the eth bid so the Core holds a composable page for the redemption
    function phase6ProdFill() external {
        _boot();
        sellBucketSeconds = core.settings().bucketSeconds;
        vm.rpc("anvil_removeBlockTimestampInterval", "[]");
        // approve through the node (not a deferred broadcast) so the sells in _fill, which also send on the node, see it
        if (!ICredits(Mainnet.CREDITS).isApprovedForAll(A1, address(core))) {
            _send(A1, Mainnet.CREDITS, abi.encodeCall(ICredits.setApprovalForAll, (address(core), true)), 0);
        }
        _fill(A1, 80, "phase6prod");
        console.log("phase6prod: pileSize", core.pileSize());
    }

    /// the Core composes a page into a held statement; prints its id for the floor warp and redemption
    function phase6ProdCompose() external {
        _boot();
        require(core.pileSize() >= 80, "phase6prod: fewer than 80 credits in the pile");
        vm.broadcast(OWNER);
        core.compose();
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "phase6prod: no held statement after compose");
        uint256 sid = held[held.length - 1];
        console.log("phase6prod: composed held statement", sid);
        console.log("REDEEM_SID", sid);
    }

    /// redeems the floor statement into the production module: the quote and the module gain equal `rating * 1e14`.
    function phase6ProdRedeem(uint256 sid) external {
        _boot();
        require(ctl.atFloor(sid), "phase6prod: statement not at its floor");
        IBalanceModule module = IBalanceModule(core.balanceModule());
        require(module.unitPerPoint() == 1e14, "phase6prod: unit per point is not 1e14");
        require(IUpstreamToken(core.balanceToken()).decimals() == 18, "phase6prod: token is not 18 decimals");
        uint256 owed = core.ratingOf(sid) * 1e14;
        require(IUpstreamToken(core.balanceToken()).quote(sid) == owed, "phase6prod: quote is not rating * 1e14");
        uint256 before = module.available();
        vm.broadcast(OWNER);
        core.redeemStatement(sid);
        require(module.available() == before + owed, "phase6prod: redeem did not pay rating * 1e14");
        console.log("phase6prod: redeemed statement", sid);
        console.log("phase6prod: owed (rating * 1e14) / module available", owed, module.available());
    }

    /// moves `n` real Credits from the CreditStrategy to the funder, skipping the strategy's live listings
    function _seedFunder(uint256 n) internal {
        uint256 got;
        uint256 cursor;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == 35377 || id == 28352 || id == 18683) continue; // the strategy's listings at the pin block
            // the fork sits past the CreditIds capture block, so some listed ids no longer exist; skip those and any the
            // strategy no longer holds
            try ICredits(Mainnet.CREDITS).ownerOf(id) returns (address holder) {
                if (holder != Mainnet.CREDIT_STRATEGY) continue;
            } catch {
                continue;
            }
            _send(
                Mainnet.CREDIT_STRATEGY,
                Mainnet.CREDITS,
                abi.encodeCall(ICredits.transferFrom, (Mainnet.CREDIT_STRATEGY, FUNDER, id)),
                0
            );
            ++got;
        }
    }

    /// the 80 Credits the funder now holds, for the surrender page
    function _funderPage() internal view returns (uint256[80] memory page) {
        uint256[] memory ids = _creditsOf(FUNDER, 80);
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
    }

    /// deploys `initcode` as a node transaction from `who` and returns the address the node assigned, then reselects the
    /// fork at the mined block. mirrors Scenario `_send` for a create (no `to`).
    function _sendCreate(address who, bytes memory initcode) internal returns (address deployed) {
        vm.rpc("evm_increaseTime", string.concat("[", vm.toString(sellBucketSeconds), "]"));
        bytes32 txHash = abi.decode(
            vm.rpc(
                "eth_sendTransaction",
                string.concat(
                    '[{"from":"', vm.toString(who), '","data":"', vm.toString(initcode), '","gas":"',
                    _quantity(MAINNET_TX_GAS_CAP), '"}]'
                )
            ),
            (bytes32)
        );
        vm.rpc("evm_mine", "[]");
        string memory receipt = _receipt(txHash);
        require(vm.parseJsonUint(receipt, ".status") == 1, "Anvil create reverted");
        require(vm.parseJsonUint(receipt, ".gasUsed") <= MAINNET_TX_GAS_CAP, "Anvil create exceeded gas cap");
        deployed = vm.parseJsonAddress(receipt, ".contractAddress");
        vm.createSelectFork(vm.envString("E2E_RPC_URL"), vm.parseJsonUint(receipt, ".blockNumber"));
    }

    // ------------------------------------------------------------------ phase 7: value mode

    /// sets the phase-two 203-bps credit spread and quote while the balance bid remains off. reference values are
    /// 1,200 bps/h, step 200, min 600 s, stale 3,600, tol 100, minLiquidity from the balance pool depth.
    function phase7Quote(uint128 minLiquidity) external {
        _boot();
        CreditSale memory credit = CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            spreadBps: 203,
            startBps: ctl.creditStartBps()
        });
        vm.broadcast(OWNER);
        ctl.setCredit(credit);
        vm.broadcast(OWNER);
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_200,
                referenceStepBps: 200,
                tolBps: 100,
                referenceMaxStale: 3_600,
                referenceMinSeconds: 600,
                minLiquidity: minLiquidity
            })
        );
        require(ctl.creditSpreadBps() == 203, "phase7: credit spread not set");
        require(!core.settings().valueModeOn && !core.settings().balanceBidOn, "phase7: bid opened before reference warmup");
    }

    /// opens the balance bid only after the configured reference answers from the seeded pool.
    function phase7Activate() external {
        _boot();
        (uint256 saleValue, bool ok) = ctl.valuePerPoint(true);
        require(ok && saleValue != 0, "phase7: reference not usable");
        vm.broadcast(OWNER);
        ctl.setAgeEligibilityOn(true);
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.balanceBidOn = true;
        s.balanceBidCapBps = 11_000;
        s.climbPerMinBps = 100;
        s.recoveryClimbPerMinBps = 100;
        s.saleFloorBps = 5_000;
        s.spendCapBps = 9_999;
        vm.broadcast(OWNER);
        core.setSettings(s);
        Settings memory after_ = core.settings();
        require(after_.valueModeOn && after_.balanceBidOn && after_.balanceBidCapBps == 11_000, "phase7: value bid not on");
        require(
            after_.feeToRedeemBurnBps == 1_000 && after_.spendCapBps == 9_999 && ctl.creditSpreadBps() == 203,
            "phase7: phase-two tuple changed"
        );
        console.log("phase7: value mode on, spread 203, referencePrice", ctl.referencePrice());
    }

    /// moves the balance pool spot up about 8 percent with real eth buys of the balance token through a swap router.
    function phase7MovePool(address token) external {
        _boot();
        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        (uint256 start,) = ctl.spotPrice();
        uint256 target = start * 108 / 100;
        TestSwapRouter swapRouter = new TestSwapRouter();
        // size the per-buy eth from the pool's eth reserve so the move is gentle at any liquidity. a full-range position
        // holds about L * Q96 / sqrtP in eth; buying 2 percent of that per step moves the spot a few percent, so the
        // loop reaches 8 percent in a handful of buys without overshooting the upper guard.
        IPoolManager pm = IPoolManager(Mainnet.POOL_MANAGER);
        uint128 liq = pm.getLiquidity(pool.toId());
        (uint160 sqrtP,,,) = pm.getSlot0(pool.toId());
        uint256 ethReserve = FullMath.mulDiv(uint256(liq), FixedPoint96.Q96, sqrtP);
        uint256 chunk = ethReserve / 50 + 1;
        // eth-in buys of the balance token, each lifting the spot a little, until it has moved about 8 percent
        for (uint256 i; i < 20; ++i) {
            (uint256 spot,) = ctl.spotPrice();
            if (spot >= target) break;
            vm.broadcast(TRADER);
            swapRouter.swap{value: chunk}(pool, true, -int256(chunk), TRADER);
        }
        (uint256 after_,) = ctl.spotPrice();
        require(after_ >= start * 105 / 100 && after_ <= start * 140 / 100, "phase7: pool spot not moved about 8 percent");
        console.log("phase7: pool spot start / after", start, after_);
    }

    /// switches value mode off as the owner, so the eth instance resets to the shared rate.
    function phase7ValueOff() external {
        _boot();
        Settings memory s = core.settings();
        s.valueModeOn = false;
        s.balanceBidOn = false;
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(!core.settings().valueModeOn && !core.settings().balanceBidOn, "phase7: value or balance bid still on");
        console.log("phase7: value mode off, ethRate", core.ethRate());
    }

    /// A1 sells one credit for eth in value mode; prints the quote and the paid amount so the shell asserts the fill
    /// sits inside the bands.
    function phase7ValueSell() external {
        _boot();
        _approveCredits(A1);
        uint256[] memory one = _creditsOf(A1, 1);
        uint256 bid = core.bidOf(one[0]);
        uint256 before = A1.balance;
        vm.broadcast(A1);
        core.sellForEth(one);
        uint256 paid = A1.balance - before;
        require(paid == bid, "phase7: value mode eth sell did not pay bidOf");
        console.log("phase7: value sell bid / paid", bid, paid);
    }

    /// builds real trading depth on Jack's balance pool. after `opensAt` the immutable funder moves part of
    /// its launch balance to the liquidity wallet (TRADER), which adds a full-range position to the native eth / token
    /// pool through the real pool manager. the move targets 2 percent of supply, capped at 95 percent of the funder
    /// balance when the funder holds less. prints the moved amount and the pool liquidity the manager reports.
    function phase7ProdLiquidity(address token) external {
        _boot();
        require(block.timestamp >= IUpstreamToken(token).opensAt(), "phase7: transfers not open");
        uint256 funderBal = IERC20R(token).balanceOf(FUNDER);
        require(funderBal > 0, "phase7: funder holds no balance");
        uint256 supply = IERC20R(token).totalSupply();
        uint256 twoPct = supply * 2 / 100;
        uint256 moved = funderBal < twoPct ? funderBal * 95 / 100 : twoPct;
        require(moved > 0, "phase7: nothing to move");

        vm.broadcast(FUNDER);
        IERC20Transfer(token).transfer(TRADER, moved);
        require(IERC20R(token).balanceOf(TRADER) >= moved, "phase7: liquidity wallet did not receive tokens");

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // deposit 99 percent of the moved tokens so the exact full-range token leg stays under the wallet balance
        uint256 liq = FullMath.mulDiv(moved * 99 / 100, FixedPoint96.Q96, DEV_SQRT);
        uint256 ethLeg = FullMath.mulDiv(liq, FixedPoint96.Q96, DEV_SQRT);

        vm.broadcast(TRADER);
        TestLiquidityHelper lp = new TestLiquidityHelper();
        vm.broadcast(TRADER);
        IERC20R(token).approve(address(lp), type(uint256).max);
        vm.broadcast(TRADER);
        lp.modify{value: ethLeg * 2 + 1 ether}(pool, -TICK_FULL, TICK_FULL, int256(liq));

        uint128 depth = IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(pool.toId());
        require(depth > 0, "phase7: no pool liquidity after modify");
        console.log("phase7: funder balance / supply", funderBal, supply);
        console.log("POOL_DEPTH", uint256(depth));
        console.log("MOVED_TOKENS", moved);
        console.log("ETH_LEG", ethLeg);
    }

    /// In a local simulation, swaps ETH into the balance token to lift the spot, reads the Credit bid, then swaps
    /// back in the same block. The bid view must stay fixed and the two pool swaps must lose value before gas. This
    /// probe does not execute a Credit sale or measure its payout, gas, or full transaction ordering.
    function phase7SameBlockSpotProbe(address token) external {
        _boot();
        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        uint128 depth = IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(pool.toId());
        require(depth > 0, "phase7spot: no pool liquidity");

        uint256 id = _creditsOf(A1, 1)[0];
        uint256 bidBefore = core.bidOf(id);

        TestSwapRouter router = new TestSwapRouter();
        // A dedicated EOA holds the simulated swaps because this script's address does not persist on the node.
        address atk = address(uint160(uint256(keccak256("e2e-real.spot-probe"))));
        vm.deal(atk, 100 ether);
        uint256 ethIn = 0.03 ether;
        uint256 tokBefore = IERC20R(token).balanceOf(atk);
        vm.prank(atk);
        router.swap{value: ethIn}(pool, true, -int256(ethIn), atk);
        uint256 bought = IERC20R(token).balanceOf(atk) - tokBefore;

        uint256 bidAfter = core.bidOf(id);

        vm.prank(atk);
        IERC20R(token).approve(address(router), type(uint256).max);
        uint256 ethBeforeRev = atk.balance;
        vm.prank(atk);
        router.swap(pool, false, -int256(bought), atk);
        uint256 recovered = atk.balance - ethBeforeRev;
        uint256 poolLoss = ethIn - recovered;

        require(bidAfter == bidBefore, "phase7spot: same-block spot move changed the eth bid");
        require(poolLoss > 0, "phase7spot: two swaps did not lose pool fees");
        console.log("SPOT_PROBE_BID", bidBefore);
        console.log("SPOT_PROBE_POOL_LOSS", poolLoss);
        console.log("SPOT_PROBE_DEPTH", uint256(depth));
    }

    receive() external payable {}
}
