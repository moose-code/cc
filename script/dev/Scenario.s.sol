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
/// env: CORE (the engine), OWNER (the engine and factory owner), A1 A2 A3 (actors), KEEPER, TRADER, and for the exit
/// stage EXIT_TOKEN and EXIT_MODULE.
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
        else if (stage == keccak256("b")) _b();
        else if (stage == keccak256("c")) _c();
        else if (stage == keccak256("d-open")) _dOpen();
        else if (stage == keccak256("d-buy")) _dBuy();
        else if (stage == keccak256("e-fill")) _eFill();
        else if (stage == keccak256("e-compose")) _eCompose();
        else if (stage == keccak256("f")) _f();
        else if (stage == keccak256("g")) _g();
        else if (stage == keccak256("h-setup")) _hSetup();
        else if (stage == keccak256("h-redeem")) _hRedeem();
        else if (stage == keccak256("report")) _report();
        else revert(string.concat("unknown STAGE ", vm.envString("STAGE")));
    }

    // ------------------------------------------------------------------ a: trade the coin, fund the pot

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
        // sell half the trader's coin back, which skims the other side too
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

    // ------------------------------------------------------------------ b: sell 80 credits into the eth bid

    function _b() internal {
        uint256[] memory ids = _creditsOf(A1, 80);
        uint256 floorBefore = core.floorRate();
        uint256 priceBefore = core.ethPrice();
        uint256 pileBefore = core.pileSize();

        vm.broadcast(A1);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        vm.broadcast(A1);
        core.sellForEth(ids);

        require(core.pileSize() == pileBefore + 80, "stage b: 80 credits did not enter the pile");
        require(core.ethPrice() < priceBefore, "stage b: the eth price did not fall after the sell walk");
        require(core.floorRate() >= floorBefore, "stage b: the floor rate did not hold at the peak");
        console.log("stage b: ethPrice before", priceBefore);
        console.log("stage b: ethPrice after", core.ethPrice());
        console.log("stage b: floorRate before", floorBefore);
        console.log("stage b: floorRate after", core.floorRate());
        console.log("stage b: pileSize", core.pileSize());
    }

    // ------------------------------------------------------------------ c: compose, buy the statement

    function _c() internal {
        require(core.pileSize() >= 80, "stage c: fewer than 80 credits in the pile");
        vm.broadcast(KEEPER);
        core.compose();

        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "stage c: no statement held after compose");
        uint256 sid = held[held.length - 1];
        uint256 price = ctl.priceOf(sid);
        uint256 ref = ctl.referenceOf(sid);
        require(price >= ref, "stage c: the start price is below the reference");

        vm.broadcast(A2);
        ctl.buy{value: price}(sid);

        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "stage c: the statement is still held after the buy");
        require(IStatements(Mainnet.STATEMENTS).ownerOf(sid) == A2, "stage c: the buyer does not own the statement");
        console.log("stage c: statement id", sid);
        console.log("stage c: reference", ref);
        console.log("stage c: price paid", price);
        console.log("stage c: ethToBuyback after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ d: credit sale window

    function _dOpen() internal {
        uint256[] memory ids = _creditsOf(A2, 5);
        vm.broadcast(A2);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        vm.broadcast(A2);
        core.sellForEth(ids);

        vm.broadcast(OWNER);
        ctl.setCreditSaleOn(true);
        require(ctl.creditSaleOn(), "stage d: the credit sale is not on");

        // a fresh credit is still inside its window, so compose waits for it
        (, , uint64 acquiredAt) = core.creditInfo(ids[0]);
        require(!ctl.pastWindow(acquiredAt), "stage d: a fresh credit should still be inside its window");
        console.log("stage d: credit sale on, fresh credit id", ids[0]);
        console.log("stage d: creditPrice now", ctl.creditPrice(ids[0]));
    }

    function _dBuy() internal {
        uint256[] memory pile = _pilePage(0, 3);
        uint256 pileBefore = core.pileSize();

        uint256 p0 = ctl.creditPrice(pile[0]);
        vm.broadcast(A3);
        ctl.buyCredit{value: p0}(pile[0]);
        require(ICredits(Mainnet.CREDITS).ownerOf(pile[0]) == A3, "stage d: buyCredit did not transfer the credit");

        uint256[] memory two = new uint256[](2);
        two[0] = pile[1];
        two[1] = pile[2];
        uint256 sum = ctl.creditPrice(two[0]) + ctl.creditPrice(two[1]);
        vm.broadcast(A3);
        ctl.buyCredits{value: sum}(two);

        require(core.pileSize() == pileBefore - 3, "stage d: three credits did not leave the pile");
        console.log("stage d: buyCredit price", p0);
        console.log("stage d: buyCredits total", sum);
        console.log("stage d: pileSize after", core.pileSize());
    }

    // ------------------------------------------------------------------ e: chosen composition

    function _eFill() internal {
        uint256[] memory ids = _creditsOf(A1, 80);
        vm.broadcast(A1);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        vm.broadcast(A1);
        core.sellForEth(ids);

        vm.broadcast(OWNER);
        core.setChosenComposeOn(true);
        require(core.chosenComposeOn(), "stage e: chosen composition is not on");
        require(core.pileSize() >= 80, "stage e: fewer than 80 credits in the pile");
        console.log("stage e: chosen compose on, pileSize", core.pileSize());
    }

    function _eCompose() internal {
        uint256[] memory page = _pilePage(0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        uint256 supplyBefore = IStatements(Mainnet.STATEMENTS).supply();
        uint256 pileBefore = core.pileSize();
        uint8 format = 3;

        vm.broadcast(KEEPER);
        core.composeChosen(ids, format);

        require(IStatements(Mainnet.STATEMENTS).supply() == supplyBefore + 1, "stage e: composeChosen minted no statement");
        require(core.pileSize() == pileBefore - 80, "stage e: 80 credits did not leave the pile");
        uint256[] memory held = core.heldStatements();
        console.log("stage e: new statement id", held[held.length - 1]);
        console.log("stage e: pileSize after", core.pileSize());
    }

    // ------------------------------------------------------------------ f: pause

    function _f() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "stage f: no held statement to price");
        uint256 sid = held[held.length - 1];
        uint256 creditId = _pilePage(0, 1)[0];

        vm.broadcast(OWNER);
        ctl.setPaused(true);
        require(ctl.paused(), "stage f: the controller is not paused");

        (bool okBuy,) = address(ctl).call(abi.encodeWithSelector(IControllerV1.buy.selector, sid));
        require(!okBuy, "stage f: buy did not revert while paused");
        (bool okCredit,) = address(ctl).call(abi.encodeWithSelector(IControllerV1.buyCredit.selector, creditId));
        require(!okCredit, "stage f: buyCredit did not revert while paused");

        vm.broadcast(OWNER);
        ctl.setPaused(false);
        require(!ctl.paused(), "stage f: the controller is still paused");
        console.log("stage f: paused then unpaused, buy and buyCredit reverted while paused");
    }

    // ------------------------------------------------------------------ g: keeper buyback

    function _g() internal {
        require(core.ethToBuyback() > 0, "stage g: nothing in the buyback pot");
        uint256 supplyBefore = IERC20R(coin).totalSupply();
        uint256 buybackBefore = core.ethToBuyback();

        vm.broadcast(KEEPER);
        core.buyback();

        require(IERC20R(coin).totalSupply() < supplyBefore, "stage g: the coin supply did not fall");
        require(core.ethToBuyback() < buybackBefore, "stage g: the buyback pot did not move");
        console.log("stage g: supply burned", supplyBefore - IERC20R(coin).totalSupply());
        console.log("stage g: buyback pot before", buybackBefore);
        console.log("stage g: buyback pot after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ h: exit side

    function _hSetup() internal {
        address exitModule = vm.envAddress("EXIT_MODULE");
        address exitToken = vm.envAddress("EXIT_TOKEN");

        vm.broadcast(OWNER);
        core.setExitModule(exitModule);
        require(core.exitModule() == exitModule, "stage h: exit module not set");
        require(core.exitToken() == exitToken, "stage h: exit token mismatch");

        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(exitToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.broadcast(OWNER);
        ctl.setExitPoolKey(k);
        require(ctl.exitPoolKeySet(), "stage h: exit pool key not set");

        Settings memory s = core.settings();
        s.exitMode = 2;
        vm.broadcast(OWNER);
        core.setSettings(s);
        require(core.settings().exitMode == 2, "stage h: exit mode is not 2");
        console.log("stage h: exit module, pool key and exitMode 2 set");
    }

    function _hRedeem() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "stage h: no held statement to redeem");
        uint256 sid = held[held.length - 1];
        require(ctl.atFloor(sid), "stage h: the statement has not reached its floor");

        uint256 xpotBefore = core.xPot();
        vm.broadcast(KEEPER);
        core.exitStatement(sid);
        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "stage h: the statement is still held after the redemption");
        require(core.xPot() > xpotBefore, "stage h: the exit token pot did not grow");

        // sellForExitToken from an actor, then check the recorded eth cost basis equals the score-scaled backstop
        uint256[] memory ids = _creditsOf(A3, 1);
        uint256 id = ids[0];
        uint256 floor = core.floorRate();
        uint256 refScore = ctl.refScore();
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(
            ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id)
        );
        uint256 expected = (refScore == 0 || score <= refScore) ? floor : FullMath.mulDiv(floor, score, refScore);
        if (expected == 0) expected = 1;

        vm.broadcast(A3);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        vm.broadcast(A3);
        core.sellForExitToken(ids);

        (bool inPile, uint256 cost,) = core.creditInfo(id);
        require(inPile, "stage h: the exit sold credit is not in the pile");
        require(cost == expected, "stage h: recorded cost does not equal the score-scaled backstop");
        console.log("stage h: redeemed statement", sid);
        console.log("stage h: floorRate", floor);
        console.log("stage h: exit sold credit recorded cost", cost);
        console.log("stage h: backstop expected", expected);

        // release the redeem burn reserve into the buyback pot
        uint256 reserve = core.ethRedeemBurn();
        if (reserve > 0) {
            uint256 bbBefore = core.ethToBuyback();
            vm.broadcast(OWNER);
            core.releaseRedeemBurn(reserve);
            require(core.ethRedeemBurn() < reserve, "stage h: the redeem burn reserve did not fall");
            require(core.ethToBuyback() == bbBefore + reserve, "stage h: the released reserve did not reach the buyback pot");
            console.log("stage h: released redeem burn reserve", reserve);
        }
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
