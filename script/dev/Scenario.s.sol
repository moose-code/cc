// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";
import {ICredits, IStatements, ICreditScore, ICoin, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IUniversalRouterR {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2R {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20R {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// @notice one local anvil fork scenario stage per run, selected by the STAGE env var. each stage broadcasts its actions
/// from impersonated accounts and asserts its result, so a failed stage reverts the forge run with a clear message.
/// `script/dev/e2e.sh` warps the node (evm_increaseTime) between stages and passes the env. no mainnet, no private key.
///
/// the stages are the same for both PHASE values up to the exit side. PHASE=pre stops before the exit stages, so the
/// engine ends with exitMode 0 and no exit module. PHASE=post runs the exit stages too: exit module, pool key,
/// exitMode 2, a statement redemption and the exit token bid. the final state of both phases holds at least two
/// statements for sale (one composed early, one composed last) and at least three pile credits of mixed window status.
///
/// env: CORE (the engine), OWNER (the engine and factory owner), A1 A2 A3 (actors), KEEPER, TRADER, and for the exit
/// stages EXIT_TOKEN and EXIT_MODULE.
contract Scenario is Script {
    ICore internal core;
    IControllerV1 internal ctl;
    IFeeRouter internal router;
    address internal coin;
    PoolKey internal key;

    address internal OWNER;
    address internal A1;
    address internal A2;
    address internal A3;
    address internal KEEPER;
    address internal TRADER;

    uint256 internal constant BPS = 10_000;

    function run() external {
        core = ICore(payable(vm.envAddress("CORE")));
        ctl = IControllerV1(core.controller());
        router = IFeeRouter(payable(core.FEE_SOURCE()));
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
        KEEPER = vm.envAddress("KEEPER");
        TRADER = vm.envAddress("TRADER");

        bytes32 stage = keccak256(bytes(vm.envString("STAGE")));
        if (stage == keccak256("a")) _a();
        else if (stage == keccak256("fill-a")) _fillA();
        else if (stage == keccak256("adopt")) _adopt();
        else if (stage == keccak256("compose-a")) _composeA();
        else if (stage == keccak256("d-open")) _dOpen();
        else if (stage == keccak256("d-buy")) _dBuy();
        else if (stage == keccak256("fill-b")) _fillB();
        else if (stage == keccak256("compose-b")) _composeB();
        else if (stage == keccak256("settings")) _settings();
        else if (stage == keccak256("pause")) _pause();
        else if (stage == keccak256("buyback")) _buyback();
        else if (stage == keccak256("exit-setup")) _exitSetup();
        else if (stage == keccak256("fill-d")) _fillD();
        else if (stage == keccak256("compose-d")) _composeD();
        else if (stage == keccak256("exit-redeem")) _exitRedeem();
        else if (stage == keccak256("fresh-fill")) _freshFill();
        else if (stage == keccak256("fresh-compose")) _freshCompose();
        else if (stage == keccak256("report")) _report();
        else revert(string.concat("unknown STAGE ", vm.envString("STAGE")));
    }

    // ------------------------------------------------------------------ a: trade the coin, fund the pot, flush fees

    /// coin buys and a sell through the universal router, each followed by a keeper flush of the fee router. the flush
    /// books swap fee eth into the core (FeesAdded), fills the redeem burn reserve, and, past the split start, pays the
    /// router payee (SplitStarted). leaves ethPot at or above the target the later stages draw on.
    function _a() internal {
        uint256 target = 0.9 ether;
        uint256 potBefore = core.ethPot();
        for (uint256 i; i < 10 && core.ethPot() < target; ++i) {
            vm.broadcast(TRADER);
            IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: 3 ether}(
                hex"10", _v4Swap(true, 3 ether), block.timestamp + 1 hours
            );
            vm.broadcast(KEEPER);
            router.flush();
        }
        uint256 bal = IERC20R(coin).balanceOf(TRADER);
        uint256 sellIn = bal / 2;
        vm.broadcast(TRADER);
        IERC20R(coin).approve(Mainnet.PERMIT2, type(uint256).max);
        vm.broadcast(TRADER);
        IPermit2R(Mainnet.PERMIT2).approve(coin, Mainnet.UNIVERSAL_ROUTER, uint160(sellIn), uint48(block.timestamp + 1 hours));
        vm.broadcast(TRADER);
        IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.broadcast(KEEPER);
        router.flush();

        require(core.ethPot() >= target, "stage a: pot not funded to target");
        console.log("stage a: ethPot before", potBefore);
        console.log("stage a: ethPot after", core.ethPot());
        console.log("stage a: ethRedeemBurn", core.ethRedeemBurn());
    }

    // ------------------------------------------------------------------ fill-a: sell credits into the eth bid

    /// @dev the eth bid pays sellers from `ethPot` at the current rate. a long idle (the warps that drive a statement to
    /// its floor) loosens the rate ceiling toward the cap, so an 80 credit fill can cost more than the pot holds. the
    /// owner resets the rate to the launch rate, which also resets the idle loosening through the checkpoint, then coin
    /// buys and a flush top the pot up, so every credit of a fill prices above zero and the pot covers the fill.
    function _primeBid() internal {
        uint256 launchRate = core.RATE_START();
        vm.broadcast(OWNER);
        core.setRate(launchRate);
        uint256 target = 1 ether;
        for (uint256 i; i < 25 && core.ethPot() < target; ++i) {
            vm.broadcast(TRADER);
            IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: 3 ether}(
                hex"10", _v4Swap(true, 3 ether), block.timestamp + 1 hours
            );
            vm.broadcast(KEEPER);
            router.flush();
        }
        require(core.ethPot() >= target, "prime: pot not funded to target");
    }

    /// a batch sell and a single sell into the eth bid, covering both the list and the minOut overloads of sellForEth.
    function _fillA() internal {
        _primeBid();
        vm.broadcast(A1);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);

        uint256[] memory batch = _creditsOf(A1, 80);
        uint256 pileBefore = core.pileSize();
        vm.broadcast(A1);
        core.sellForEth(batch);
        require(core.pileSize() == pileBefore + 80, "fill-a: the batch sell did not enter the pile");

        uint256[] memory one = _creditsOf(A1, 1);
        vm.broadcast(A1);
        core.sellForEth(one, 0);
        require(core.pileSize() == pileBefore + 81, "fill-a: the single sell did not enter the pile");
        console.log("fill-a: batch 80 and single 1 sold, pileSize", core.pileSize());
    }

    // ------------------------------------------------------------------ adopt: credits sent straight to the engine

    /// two credits transferred to the core with no sale, then adopted into the pile at the price state basis.
    function _adopt() internal {
        uint256[] memory ids = _creditsOf(A3, 2);
        vm.broadcast(A3);
        ICredits(Mainnet.CREDITS).transferFrom(A3, address(core), ids[0]);
        vm.broadcast(A3);
        ICredits(Mainnet.CREDITS).transferFrom(A3, address(core), ids[1]);

        uint256 pileBefore = core.pileSize();
        vm.broadcast(KEEPER);
        core.adopt(ids);
        require(core.pileSize() == pileBefore + 2, "adopt: the credits did not enter the pile");
        (bool inPile, uint256 cost,) = core.creditInfo(ids[0]);
        require(inPile, "adopt: the credit is not in the pile");
        console.log("adopt: two credits adopted, basis", cost);
        console.log("adopt: pileSize", core.pileSize());
    }

    // ------------------------------------------------------------------ compose-a: default page, buy the statement

    /// composes the oldest 80 pile credits into a statement, then a buyer takes it at its curve price. the first
    /// statement sale, and the one that funds the buyback pot.
    function _composeA() internal {
        require(core.pileSize() >= 80, "compose-a: fewer than 80 credits in the pile");
        vm.broadcast(KEEPER);
        core.compose();

        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "compose-a: no statement held after compose");
        uint256 sid = held[held.length - 1];
        uint256 price = ctl.priceOf(sid);
        uint256 ref = ctl.referenceOf(sid);
        require(price >= ref, "compose-a: the start price is below the reference");

        vm.broadcast(A2);
        ctl.buy{value: price}(sid);
        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "compose-a: the statement is still held after the buy");
        require(IStatements(Mainnet.STATEMENTS).ownerOf(sid) == A2, "compose-a: the buyer does not own the statement");
        console.log("compose-a: statement id", sid);
        console.log("compose-a: price paid", price);
        console.log("compose-a: ethToBuyback after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ d-open: open the credit sale

    function _dOpen() internal {
        uint256[] memory ids = _creditsOf(A2, 5);
        vm.broadcast(A2);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        vm.broadcast(A2);
        core.sellForEth(ids);

        vm.broadcast(OWNER);
        ctl.setCreditSaleOn(true);
        require(ctl.creditSaleOn(), "d-open: the credit sale is not on");

        uint256[] memory page = _pilePage(0, 1);
        console.log("d-open: credit sale on, fresh credit id", page[0]);
        console.log("d-open: creditPrice now", ctl.creditPrice(page[0]));
    }

    // ------------------------------------------------------------------ d-buy: buy credits out of the pile

    function _dBuy() internal {
        uint256[] memory pile = _pilePage(0, 3);
        uint256 pileBefore = core.pileSize();

        uint256 p0 = ctl.creditPrice(pile[0]);
        vm.broadcast(A3);
        ctl.buyCredit{value: p0}(pile[0]);
        require(ICredits(Mainnet.CREDITS).ownerOf(pile[0]) == A3, "d-buy: buyCredit did not transfer the credit");

        uint256[] memory two = new uint256[](2);
        two[0] = pile[1];
        two[1] = pile[2];
        uint256 sum = ctl.creditPrice(two[0]) + ctl.creditPrice(two[1]);
        vm.broadcast(A3);
        ctl.buyCredits{value: sum}(two);

        require(core.pileSize() == pileBefore - 3, "d-buy: three credits did not leave the pile");
        console.log("d-buy: buyCredit price", p0);
        console.log("d-buy: buyCredits total", sum);
        console.log("d-buy: pileSize after", core.pileSize());
    }

    // ------------------------------------------------------------------ fill-b, compose-b: chosen composition

    function _fillB() internal {
        _primeBid();
        uint256[] memory ids = _creditsOf(A1, 80);
        vm.broadcast(A1);
        core.sellForEth(ids);

        vm.broadcast(OWNER);
        core.setChosenComposeOn(true);
        require(core.chosenComposeOn(), "fill-b: chosen composition is not on");
        require(core.pileSize() >= 80, "fill-b: fewer than 80 credits in the pile");
        console.log("fill-b: chosen compose on, pileSize", core.pileSize());
    }

    function _composeB() internal {
        uint256[] memory page = _pilePage(0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        uint256 supplyBefore = IStatements(Mainnet.STATEMENTS).supply();
        uint256 pileBefore = core.pileSize();

        vm.broadcast(KEEPER);
        core.composeChosen(ids, 3);

        require(IStatements(Mainnet.STATEMENTS).supply() == supplyBefore + 1, "compose-b: composeChosen minted no statement");
        require(core.pileSize() == pileBefore - 80, "compose-b: 80 credits did not leave the pile");
        uint256[] memory held = core.heldStatements();
        console.log("compose-b: new statement id", held[held.length - 1]);
        console.log("compose-b: held statements", held.length);
    }

    // ------------------------------------------------------------------ settings: owner changes that emit events

    /// one sale setting, one credit setting and the rating reference on the controller, and the rate and the settings
    /// struct on the core, so every owner setter that emits an event is exercised.
    function _settings() internal {
        vm.broadcast(OWNER);
        ctl.setMarkupBps(16_000);
        require(ctl.markupBps() == 16_000, "settings: markupBps not set");

        vm.broadcast(OWNER);
        ctl.setCreditWindow(7_200);
        require(ctl.creditWindow() == 7_200, "settings: creditWindow not set");

        vm.broadcast(OWNER);
        ctl.setRefScore(4_000_000);
        require(ctl.refScore() == 4_000_000, "settings: refScore not set");

        uint256 rate = core.ethPrice();
        vm.broadcast(OWNER);
        core.setRate(rate);

        Settings memory s = core.settings();
        vm.broadcast(OWNER);
        core.setSettings(s);
        console.log("settings: markupBps 16000, creditWindow 7200, refScore 4000000, rate", rate);
    }

    // ------------------------------------------------------------------ pause: pause then unpause

    function _pause() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "pause: no held statement to price");
        uint256 sid = held[held.length - 1];
        uint256 creditId = _pilePage(0, 1)[0];

        vm.broadcast(OWNER);
        ctl.setPaused(true);
        require(ctl.paused(), "pause: the controller is not paused");

        (bool okBuy,) = address(ctl).call(abi.encodeWithSelector(IControllerV1.buy.selector, sid));
        require(!okBuy, "pause: buy did not revert while paused");
        (bool okCredit,) = address(ctl).call(abi.encodeWithSelector(IControllerV1.buyCredit.selector, creditId));
        require(!okCredit, "pause: buyCredit did not revert while paused");

        vm.broadcast(OWNER);
        ctl.setPaused(false);
        require(!ctl.paused(), "pause: the controller is still paused");
        console.log("pause: paused then unpaused, buy and buyCredit reverted while paused");
    }

    // ------------------------------------------------------------------ buyback: keeper buy and burn

    function _buyback() internal {
        require(core.ethToBuyback() > 0, "buyback: nothing in the buyback pot");
        uint256 supplyBefore = IERC20R(coin).totalSupply();
        uint256 buybackBefore = core.ethToBuyback();

        vm.broadcast(KEEPER);
        core.buyback();

        require(IERC20R(coin).totalSupply() < supplyBefore, "buyback: the coin supply did not fall");
        require(core.ethToBuyback() < buybackBefore, "buyback: the buyback pot did not move");
        console.log("buyback: supply burned", supplyBefore - IERC20R(coin).totalSupply());
        console.log("buyback: pot before", buybackBefore);
        console.log("buyback: pot after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ exit-setup: turn the exit side on (post)

    function _exitSetup() internal {
        address exitModule = vm.envAddress("EXIT_MODULE");
        address exitToken = vm.envAddress("EXIT_TOKEN");

        vm.broadcast(OWNER);
        core.setExitModule(exitModule);
        require(core.exitModule() == exitModule, "exit-setup: exit module not set");
        require(core.exitToken() == exitToken, "exit-setup: exit token mismatch");

        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(exitToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.broadcast(OWNER);
        ctl.setExitPoolKey(k);
        require(ctl.exitPoolKeySet(), "exit-setup: exit pool key not set");

        Settings memory s = core.settings();
        s.exitMode = 2;
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(core.settings().exitMode == 2, "exit-setup: exit mode is not 2");

        vm.broadcast(OWNER);
        core.refreshUnitPerPoint();
        console.log("exit-setup: exit module, pool key, exitMode 2 and unit refresh done");
        console.log("exit-setup: unitPerPoint", core.unitPerPoint());
    }

    // ------------------------------------------------------------------ fill-d, compose-d: the redemption statement (post)

    function _fillD() internal {
        _primeBid();
        uint256[] memory ids = _creditsOf(A1, 80);
        vm.broadcast(A1);
        core.sellForEth(ids);
        require(core.pileSize() >= 80, "fill-d: fewer than 80 credits in the pile");
        console.log("fill-d: 80 sold, pileSize", core.pileSize());
    }

    function _composeD() internal {
        require(core.pileSize() >= 80, "compose-d: fewer than 80 credits in the pile");
        uint256 heldBefore = core.heldStatements().length;
        vm.broadcast(KEEPER);
        core.compose();
        uint256[] memory held = core.heldStatements();
        require(held.length == heldBefore + 1, "compose-d: no statement held after compose");
        console.log("compose-d: redemption statement id", held[held.length - 1]);
        console.log("compose-d: held statements", held.length);
    }

    // ------------------------------------------------------------------ exit-redeem: redeem, exit bid, release (post)

    function _exitRedeem() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length >= 2, "exit-redeem: need a redemption statement and one to keep held");
        uint256 sid = held[held.length - 1];
        require(ctl.atFloor(sid), "exit-redeem: the statement has not reached its floor");

        uint256 xpotBefore = core.xPot();
        uint256 heldBefore = held.length;
        vm.broadcast(KEEPER);
        core.exitStatement(sid);
        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "exit-redeem: the statement is still held after the redemption");
        require(core.xPot() > xpotBefore, "exit-redeem: the exit token pot did not grow");
        require(core.heldStatements().length == heldBefore - 1, "exit-redeem: held count did not fall by one");

        // sell credits into the exit token bid: a single and a batch. the recorded cost of a sold credit equals the
        // score-scaled eth backstop, read from no pool.
        vm.broadcast(A3);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);

        uint256[] memory one = _creditsOf(A3, 1);
        _assertExitBasis(one[0]);
        vm.broadcast(A3);
        core.sellForExitToken(one);
        (bool inPile,,) = core.creditInfo(one[0]);
        require(inPile, "exit-redeem: the single exit sold credit is not in the pile");

        uint256[] memory batch = _creditsOf(A3, 2);
        vm.broadcast(A3);
        core.sellForExitToken(batch, 0);
        (bool inPile2,,) = core.creditInfo(batch[1]);
        require(inPile2, "exit-redeem: the batch exit sold credit is not in the pile");

        // release the redeem burn reserve into the buyback pot
        uint256 reserve = core.ethRedeemBurn();
        if (reserve > 0) {
            uint256 bbBefore = core.ethToBuyback();
            vm.broadcast(OWNER);
            core.releaseRedeemBurn(reserve);
            require(core.ethRedeemBurn() < reserve, "exit-redeem: the redeem burn reserve did not fall");
            require(core.ethToBuyback() == bbBefore + reserve, "exit-redeem: the released reserve did not reach the buyback pot");
            console.log("exit-redeem: released redeem burn reserve", reserve);
        }
        console.log("exit-redeem: redeemed statement", sid);
        console.log("exit-redeem: xPot", core.xPot());
        console.log("exit-redeem: held statements", core.heldStatements().length);
    }

    /// @dev the recorded cost of a credit sold into the exit bid is the floor rate scaled by the credit's score over
    /// refScore, at least 1 wei. read live so a changed refScore is accounted for.
    function _assertExitBasis(uint256 id) internal view {
        uint256 floor = core.floorRate();
        uint256 refScore = ctl.refScore();
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(
            ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id)
        );
        uint256 expected = (refScore == 0 || score <= refScore) ? floor : FullMath.mulDiv(floor, score, refScore);
        if (expected == 0) expected = 1;
        console.log("exit-redeem: backstop expected for id", id, expected);
    }

    // ------------------------------------------------------------------ fresh: the last statement, live pile content

    function _freshFill() internal {
        _primeBid();
        uint256[] memory ids = _creditsOf(A1, 80);
        vm.broadcast(A1);
        core.sellForEth(ids);
        require(core.pileSize() >= 80, "fresh-fill: fewer than 80 credits in the pile");
        console.log("fresh-fill: 80 sold, pileSize", core.pileSize());
    }

    /// composes the fresh statement, then sells a few more credits that stay in the pile inside their window, so the
    /// final pile holds credits of mixed window status and at least two statements stay for sale.
    function _freshCompose() internal {
        require(core.pileSize() >= 80, "fresh-compose: fewer than 80 credits in the pile");
        uint256 heldBefore = core.heldStatements().length;
        vm.broadcast(KEEPER);
        core.compose();
        uint256[] memory held = core.heldStatements();
        require(held.length == heldBefore + 1, "fresh-compose: no statement held after compose");

        uint256[] memory dust = _creditsOf(A1, 3);
        vm.broadcast(A1);
        core.sellForEth(dust);

        require(core.heldStatements().length >= 2, "fresh-compose: fewer than two statements held");
        require(core.pileSize() >= 3, "fresh-compose: fewer than three credits in the pile");
        console.log("fresh-compose: fresh statement id", held[held.length - 1]);
        console.log("fresh-compose: held statements", core.heldStatements().length);
        console.log("fresh-compose: pileSize", core.pileSize());
    }

    // ------------------------------------------------------------------ report

    function _report() internal view {
        console.log("== final report ==");
        console.log("ethPot", core.ethPot());
        console.log("ethToBuyback", core.ethToBuyback());
        console.log("ethRedeemBurn", core.ethRedeemBurn());
        console.log("xPot", core.xPot());
        console.log("pileSize", core.pileSize());
        console.log("heldStatements", core.heldStatements().length);
        console.log("coin totalSupply", IERC20R(coin).totalSupply());
        console.log("floorRate", core.floorRate());
        console.log("ethRate", core.ethRate());

        require(core.heldStatements().length >= 2, "report: fewer than two statements held for sale");

        uint256 n = core.pileSize();
        require(n >= 3, "report: fewer than three credits in the pile");
        uint256[] memory page = core.pilePage(0, n);
        (,, uint64 oldest) = core.creditInfo(page[0]);
        (,, uint64 newest) = core.creditInfo(page[n - 1]);
        require(ctl.pastWindow(oldest), "report: the oldest pile credit is not past its window");
        require(!ctl.pastWindow(newest), "report: the newest pile credit is not inside its window");
        console.log("report: pile holds credits past and inside their window");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev `n` credit ids owned by `who` right now
    function _creditsOf(address who, uint256 n) internal view returns (uint256[] memory out) {
        uint256[] memory all = ICredits(Mainnet.CREDITS).tokensOf(who);
        require(all.length >= n, "actor holds fewer credits than the stage needs");
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = all[i];
        }
    }

    function _pilePage(uint256 startAfter, uint256 n) internal view returns (uint256[] memory) {
        return core.pilePage(startAfter, n);
    }

    /// @dev one v4 swap input: exact in single, settle, take. `zeroForOne` true buys the coin with eth
    function _v4Swap(bool zeroForOne, uint256 amountIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        Currency cIn = zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = zeroForOne ? key.currency1 : key.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}
