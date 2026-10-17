// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
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
import {CreditIds} from "../../test/utils/CreditIds.sol";

interface IPermit2AllowanceR {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// the AuctionLineageWithdrawals surface the production balance wiring reads from the pinned artifact.
interface IUpstreamToken {
    function renderer() external view returns (address);
    function decimals() external view returns (uint8);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
    function retireLaunchSupply() external;
    function transfersOpenBlock() external view returns (uint64);
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
contract E2EReal is Scenario {
    uint160 internal constant DEV_SQRT = uint160(11318308930609191084791992905142);

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

    // ------------------------------------------------------------------ phase 6: the balance side (owner's real calls)

    /// A1 sells one credit into the balance bid; the fill pays exactly `balanceBidOf` and the balance bid never exceeds
    /// par (score times the module unit per point). works against the dev mock and the production module alike, reading
    /// the unit through `IBalanceModule`.
    function phase6BalanceSell() external {
        _boot();
        _approveCredits(A1);
        uint256[] memory one = _creditsOf(A1, 1);
        uint256 id = one[0];
        uint256 balBid = core.balanceBidOf(id);
        require(balBid > 0, "phase6: balance bid is zero");
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
        uint256 unit = IBalanceModule(core.balanceModule()).unitPerPoint();
        require(balBid <= score * unit, "phase6: balance bid exceeds par");
        IERC20R token = IERC20R(core.balanceToken());
        uint256 before = token.balanceOf(A1);
        vm.broadcast(A1);
        core.sellForBalance(one);
        require(token.balanceOf(A1) - before == balBid, "phase6: balance fill not balanceBidOf");
        console.log("phase6: balance sell credit", id);
        console.log("phase6: balanceBidOf / paid", balBid, token.balanceOf(A1) - before);
    }

    // ---------------------------------------------------- phase 6 production: Jack's pinned contracts (the artifact)

    /// the funder address that surrenders a page and retires Jack's launch supply on the fork
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;

    /// deploys Jack's `AuctionLineageWithdrawals` from `out/upstream-balance.json` exactly as the production-module test
    /// does: the funder receives 80 real Credits, the Statements owner registers the Balance renderer, the funder
    /// composes a page, withdraws and retires the launch supply, then the owner deploys `StatementBalanceModule`, sets
    /// it, switches `redeemOn` and `balanceBidOn` on, initializes a native eth / token pool at the dev sqrt and points
    /// the controller at it. every write goes through the node directly (`_send` / `_sendCreate`) so the deployed token
    /// address is the one the node assigns, not a simulated one. `opensAt` is set past the current block so the shell
    /// mines to it before the redemption, mirroring Jack's opening gate.
    function phase6ProdDeploy() external {
        _boot();
        sellBucketSeconds = 0;
        _seedFunder(80);

        bytes memory creation = vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object");
        uint8 format = uint8(IUpstreamStatements(Mainnet.STATEMENTS).formatCount());
        uint64 opensAt = uint64(block.number + 50);
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(Mainnet.STATEMENTS, format, opensAt, FUNDER, _prodAddr("auction"), _prodAddr("liquidity"))
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
        s.balanceBidOn = true;
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
        console.log("== PRODUCTION MODULE: Jack's pinned AuctionLineageWithdrawals ==");
        console.log("BALANCE_TOKEN", token);
        console.log("BALANCE_MODULE", module);
        console.log("TRANSFERS_OPEN_BLOCK", uint256(IUpstreamToken(token).transfersOpenBlock()));
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

    /// a distinct deterministic address for a constructor role the e2e flow does not exercise
    function _prodAddr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("e2e-real.prod.", label)))));
    }

    /// deploys `initcode` as a node transaction from `who` and returns the address the node assigned, then reselects the
    /// fork at the mined block. mirrors Scenario `_send` for a create (no `to`).
    function _sendCreate(address who, bytes memory initcode) internal returns (address deployed) {
        vm.rpc("evm_increaseTime", string.concat("[", vm.toString(sellBucketSeconds), "]"));
        bytes32 txHash = abi.decode(
            vm.rpc(
                "eth_sendTransaction",
                string.concat(
                    '[{"from":"', vm.toString(who), '","data":"', vm.toString(initcode), '","gas":"0x17d7840"}]'
                )
            ),
            (bytes32)
        );
        vm.rpc("evm_mine", "[]");
        string memory receipt = vm.rpcJson("eth_getTransactionReceipt", string.concat('["', vm.toString(txHash), '"]'));
        require(vm.parseJsonUint(receipt, ".status") == 1, "Anvil create reverted");
        deployed = vm.parseJsonAddress(receipt, ".contractAddress");
        vm.createSelectFork(vm.envString("E2E_RPC_URL"), vm.parseJsonUint(receipt, ".blockNumber"));
    }

    // ------------------------------------------------------------------ phase 7: value mode

    /// sets the value quote and switches value mode on with the eth spend cap active, as the owner. reference values
    /// 1,200 bps/h, step 200, min 600 s, stale 3,600, tol 0, minLiquidity from the balance pool depth.
    function phase7Quote(uint128 minLiquidity) external {
        _boot();
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
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.spendCapBps = 1_000;
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(core.settings().valueModeOn, "phase7: value mode not on");
        console.log("phase7: value mode on, spendCapBps 1000, referencePrice", ctl.referencePrice());
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
        // small eth-in buys of the balance token, each lifting the spot a little, until it has moved about 8 percent
        for (uint256 i; i < 40; ++i) {
            (uint256 spot,) = ctl.spotPrice();
            if (spot >= target) break;
            vm.deal(TRADER, TRADER.balance + 1 ether);
            vm.broadcast(TRADER);
            swapRouter.swap{value: 0.02 ether}(pool, true, -int256(0.02 ether), TRADER);
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
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(!core.settings().valueModeOn, "phase7: value mode still on");
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
}
