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
import {
    ICredits,
    IStatements,
    ICreditScore,
    IBalanceModule,
    Mainnet,
    Settings,
    Sale,
    CreditSale
} from "../../src/interfaces/Interfaces.sol";

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

/// @notice one stage of the anvil fork scenario per run, selected by the STAGE env var. each stage broadcasts from
/// impersonated accounts and asserts its result, so a failed stage reverts the forge run with a message.
/// `script/dev/e2e.sh` warps the node between stages. every door of the Core and the controller that a user or a keeper
/// calls runs at least once. `buyListing` is outside the scenario: the CreditStrategy lists at about four times the
/// rate cap and a Seaport order needs an external signature.
///
/// PHASE=pre runs the stages up to `buyback`, then `fresh-fill`, `fresh-compose` and `report`. PHASE=post adds
/// `fill-d`, `compose-d`, `redeem` and `balance-bid` before the fresh stages and needs the balance side from Seed.
///
/// env: CORE, OWNER, A1 A2 A3 (credit holders), KEEPER (calls keeper doors), TRADER (trades the coin and holds the CC that
/// `composeChosen` and `setHeldFormat` require), DEV_WALLET (stage `dev-wallet` only).
contract Scenario is Script {
    ICore internal core;
    IControllerV1 internal ctl;
    address internal coin;
    PoolKey internal key;

    address internal OWNER;
    address internal A1;
    address internal A2;
    address internal A3;
    address internal KEEPER;
    address internal TRADER;

    function run() external {
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
        KEEPER = vm.envAddress("KEEPER");
        TRADER = vm.envAddress("TRADER");

        bytes32 stage = keccak256(bytes(vm.envString("STAGE")));
        if (stage == keccak256("a")) _a();
        else if (stage == keccak256("dev-wallet")) _devWallet();
        else if (stage == keccak256("fill-a")) _fillA();
        else if (stage == keccak256("adopt")) _adopt();
        else if (stage == keccak256("compose-a")) _composeA();
        else if (stage == keccak256("claims")) _claims();
        else if (stage == keccak256("d-open")) _dOpen();
        else if (stage == keccak256("d-buy")) _dBuy();
        else if (stage == keccak256("fill-b")) _fillB();
        else if (stage == keccak256("compose-b")) _composeB();
        else if (stage == keccak256("format")) _format();
        else if (stage == keccak256("settings")) _settings();
        else if (stage == keccak256("pause")) _pause();
        else if (stage == keccak256("buyback")) _buyback();
        else if (stage == keccak256("fill-d")) _fill(A1, 80, "fill-d");
        else if (stage == keccak256("compose-d")) _composeD();
        else if (stage == keccak256("redeem")) _redeem();
        else if (stage == keccak256("balance-bid")) _balanceBid();
        else if (stage == keccak256("fresh-fill")) _fill(A1, 80, "fresh-fill");
        else if (stage == keccak256("fresh-compose")) _freshCompose();
        else if (stage == keccak256("report")) _report();
        else revert(string.concat("unknown STAGE ", vm.envString("STAGE")));
    }

    // ------------------------------------------------------------------ a: trade the coin, fees reach the pot

    /// coin buys by the trader, each followed by a keeper `book`, until the pot holds the target, then a sell of half
    /// the coin. the first `book` at or after the end of the anti sniper window latches the payee share.
    function _a() internal {
        uint256 target = 0.9 ether;
        uint256 potBefore = core.ethPot();
        for (uint256 i; i < 10 && core.ethPot() < target; ++i) {
            _buyCoin();
            vm.broadcast(KEEPER);
            core.book();
        }
        uint256 sellIn = IERC20R(coin).balanceOf(TRADER) / 2;
        vm.broadcast(TRADER);
        IERC20R(coin).approve(Mainnet.PERMIT2, type(uint256).max);
        vm.broadcast(TRADER);
        IPermit2R(Mainnet.PERMIT2).approve(coin, Mainnet.UNIVERSAL_ROUTER, uint160(sellIn), uint48(block.timestamp + 1 hours));
        vm.broadcast(TRADER);
        IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.broadcast(KEEPER);
        core.book();

        require(core.ethPot() >= target, "stage a: pot not funded to target");
        require(core.payeeOn(), "stage a: the payee share did not latch");
        console.log("stage a: ethPot before", potBefore);
        console.log("stage a: ethPot after", core.ethPot());
        console.log("stage a: ethRedeemBurn", core.ethRedeemBurn());
    }

    /// the dev wallet `DEV_WALLET` buys coin with `dev.walletCoinEth` of the launch config. the restricted coin moves only
    /// through the pool, so the wallet trades like any holder
    function _devWallet() internal {
        address wallet = vm.envAddress("DEV_WALLET");
        string memory cfg = vm.readFile(vm.envOr("LAUNCH_CONFIG", string("script/config/anvil.json")));
        uint256 eth = vm.parseJsonUint(cfg, ".dev.walletCoinEth");
        vm.broadcast(wallet);
        IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: eth}(hex"10", _v4Swap(true, eth), block.timestamp + 1 hours);
        require(IERC20R(coin).balanceOf(wallet) > 0, "dev-wallet: no coin bought");
        console.log("dev-wallet: coin", IERC20R(coin).balanceOf(wallet));
    }

    function _buyCoin() internal {
        vm.broadcast(TRADER);
        IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER).execute{value: 3 ether}(
            hex"10", _v4Swap(true, 3 ether), block.timestamp + 1 hours
        );
    }

    // ------------------------------------------------------------------ fill-a: sell credits into the eth bid

    /// @dev a long idle loosens the bid toward its cap, so an 80 credit fill could cost more than the pot holds. the
    /// owner restates the bid at the launch rate, then coin buys and `book` top the pot up to the target
    function _primeBid() internal {
        uint256 launchRate = core.RATE_START();
        vm.broadcast(OWNER);
        core.setRate(launchRate);
        uint256 target = 1 ether;
        for (uint256 i; i < 25 && core.ethPot() < target; ++i) {
            _buyCoin();
            vm.broadcast(KEEPER);
            core.book();
        }
        require(core.ethPot() >= target, "prime: pot not funded to target");
    }

    /// a batch sell and a single sell with `minOut`, the two overloads of `sellForEth`
    function _fillA() internal {
        _primeBid();
        vm.broadcast(A1);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);

        uint256 pileBefore = core.pileSize();
        uint256[] memory batch = _creditsOf(A1, 80);
        vm.broadcast(A1);
        core.sellForEth(batch);
        require(core.pileSize() == pileBefore + 80, "fill-a: the batch sell did not enter the pile");

        uint256[] memory one = _creditsOf(A1, 1);
        vm.broadcast(A1);
        core.sellForEth(one, 0);
        require(core.pileSize() == pileBefore + 81, "fill-a: the single sell did not enter the pile");
        console.log("fill-a: batch 80 and single 1 sold, pileSize", core.pileSize());
    }

    /// 80 credits of `who` sold into the eth bid after the bid is primed
    function _fill(address who, uint256 n, string memory name) internal {
        _primeBid();
        uint256[] memory ids = _creditsOf(who, n);
        vm.broadcast(who);
        core.sellForEth(ids);
        require(core.pileSize() >= n, string.concat(name, ": fewer credits in the pile than sold"));
        console.log(string.concat(name, ": sold, pileSize"), core.pileSize());
    }

    // ------------------------------------------------------------------ adopt: credits sent straight to the engine

    /// two credits transferred to the Core outside the doors, then adopted into the pile at the price state
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

    // ------------------------------------------------------------------ compose-a: system compose, buy the statement

    /// `compose()` takes the 80 oldest pile credits. a buyer takes the statement at `grossPriceOf`, the price plus the
    /// royalty, which is the first statement sale and the first buyback funding
    function _composeA() internal {
        require(core.pileSize() >= 80, "compose-a: fewer than 80 credits in the pile");
        vm.broadcast(KEEPER);
        core.compose();

        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "compose-a: no statement held after compose");
        uint256 sid = held[held.length - 1];
        require(core.composerOf(sid) == KEEPER, "compose-a: the composer is not recorded");
        uint256 price = ctl.priceOf(sid);
        uint256 gross = ctl.grossPriceOf(sid);
        require(price >= ctl.referenceOf(sid), "compose-a: the start price is below the reference");
        require(gross > price, "compose-a: the gross price carries no royalty");

        uint256 owedBefore = ctl.royaltyOwed();
        vm.broadcast(A2);
        ctl.buy{value: gross}(sid);
        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "compose-a: the statement is still held after the buy");
        require(IStatements(Mainnet.STATEMENTS).ownerOf(sid) == A2, "compose-a: the buyer does not own the statement");
        require(ctl.royaltyOwed() == owedBefore + (gross - price), "compose-a: the royalty was not booked");
        console.log("compose-a: statement id", sid);
        console.log("compose-a: price", price);
        console.log("compose-a: gross paid", gross);
        console.log("compose-a: ethToBuyback after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ claims: royalty and payee

    function _claims() internal {
        uint256 royalty = ctl.royaltyOwed();
        require(royalty > 0, "claims: no royalty owed");
        uint256 before = ctl.royaltyRecipient().balance;
        vm.broadcast(KEEPER);
        ctl.claimRoyalty();
        require(ctl.royaltyOwed() == 0, "claims: the royalty is still owed");
        require(ctl.royaltyRecipient().balance == before + royalty, "claims: the recipient was not paid");

        uint256 owed = core.payeeOwed();
        require(owed > 0, "claims: nothing owed to the payee");
        vm.broadcast(KEEPER);
        core.claimPayee();
        require(core.payeeOwed() == 0, "claims: the payee claim is still owed");
        console.log("claims: royalty paid", royalty);
        console.log("claims: payee paid", owed);
    }

    // ------------------------------------------------------------------ d-open: the credit sale window

    /// five credits sold into the pile, then the credit sale switched on if it is off
    function _dOpen() internal {
        vm.broadcast(A2);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);
        uint256[] memory ids = _creditsOf(A2, 5);
        vm.broadcast(A2);
        core.sellForEth(ids);

        if (!ctl.creditSaleOn()) {
            CreditSale memory cs = _credit();
            cs.saleOn = true;
            vm.broadcast(OWNER);
            ctl.setCredit(cs);
        }
        require(ctl.creditSaleOn(), "d-open: the credit sale is not on");
        uint256 id = core.pilePage(0, 1)[0];
        console.log("d-open: credit sale on, oldest pile credit", id);
        console.log("d-open: creditPrice now", ctl.creditPrice(id));
    }

    // ------------------------------------------------------------------ d-buy: buy credits out of the pile

    /// `buyCredit` at `grossCreditPrice` and `buyCredits` at the sum of the gross prices
    function _dBuy() internal {
        uint256[] memory pile = core.pilePage(0, 3);
        uint256 pileBefore = core.pileSize();

        uint256 g0 = ctl.grossCreditPrice(pile[0]);
        require(g0 > ctl.creditPrice(pile[0]), "d-buy: the gross credit price carries no royalty");
        vm.broadcast(A3);
        ctl.buyCredit{value: g0}(pile[0]);
        require(ICredits(Mainnet.CREDITS).ownerOf(pile[0]) == A3, "d-buy: buyCredit did not transfer the credit");

        uint256[] memory two = new uint256[](2);
        two[0] = pile[1];
        two[1] = pile[2];
        uint256 sum = ctl.grossCreditPrice(two[0]) + ctl.grossCreditPrice(two[1]);
        vm.broadcast(A3);
        ctl.buyCredits{value: sum}(two);

        require(core.pileSize() == pileBefore - 3, "d-buy: three credits did not leave the pile");
        console.log("d-buy: buyCredit gross", g0);
        console.log("d-buy: buyCredits gross", sum);
        console.log("d-buy: pileSize after", core.pileSize());
    }

    // ------------------------------------------------------------------ fill-b, compose-b: chosen composition

    function _fillB() internal {
        _fill(A1, 80, "fill-b");
        if (!core.chosenComposeOn()) {
            vm.broadcast(OWNER);
            core.setChosenComposeOn(true);
        }
        require(core.chosenComposeOn(), "fill-b: chosen composition is not on");
    }

    /// the trader holds the CC that `composeChosen` requires and names the 80 oldest pile credits with format 3
    function _composeB() internal {
        uint256[] memory page = core.pilePage(0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        uint256 supplyBefore = IStatements(Mainnet.STATEMENTS).supply();
        uint256 pileBefore = core.pileSize();

        vm.broadcast(TRADER);
        core.composeChosen(ids, 3);

        require(IStatements(Mainnet.STATEMENTS).supply() == supplyBefore + 1, "compose-b: composeChosen minted no statement");
        require(core.pileSize() == pileBefore - 80, "compose-b: 80 credits did not leave the pile");
        uint256[] memory held = core.heldStatements();
        uint256 sid = held[held.length - 1];
        require(IStatements(Mainnet.STATEMENTS).formatOf(sid) == 3, "compose-b: the format is not 3");
        require(core.composerOf(sid) == TRADER, "compose-b: the composer is not recorded");
        console.log("compose-b: new statement id", sid);
        console.log("compose-b: held statements", held.length);
    }

    /// the trader restyles the newest held statement
    function _format() internal {
        uint256[] memory held = core.heldStatements();
        uint256 sid = held[held.length - 1];
        vm.broadcast(TRADER);
        core.setHeldFormat(sid, 5);
        require(IStatements(Mainnet.STATEMENTS).formatOf(sid) == 5, "format: the format is not 5");
        console.log("format: statement restyled to 5", sid);
    }

    // ------------------------------------------------------------------ settings: owner setters, fund

    /// the sale struct and the credit struct on the controller, the rate and the settings on the Core, and a `fund`
    function _settings() internal {
        Sale memory sale = Sale({
            markupBps: ctl.markupBps(),
            startCapBps: ctl.startCapBps(),
            fastDecayBpsPerHour: ctl.fastDecayBpsPerHour(),
            kneeBps: ctl.kneeBps(),
            slowDecayBpsPerHour: ctl.slowDecayBpsPerHour(),
            anchorHalfLife: ctl.anchorHalfLife(),
            anchorMinCost: ctl.anchorMinCost()
        });
        sale.markupBps = 16_000;
        vm.broadcast(OWNER);
        ctl.setSale(sale);
        require(ctl.markupBps() == 16_000, "settings: markupBps not set");

        CreditSale memory cs = _credit();
        cs.window = 7_200;
        vm.broadcast(OWNER);
        ctl.setCredit(cs);
        require(ctl.creditWindow() == 7_200, "settings: window not set");

        uint256 rate = core.ethPrice();
        vm.broadcast(OWNER);
        core.setRate(rate);

        Settings memory s = core.settings();
        vm.broadcast(OWNER);
        core.setSettings(s);

        uint256 potBefore = core.ethPot();
        vm.broadcast(TRADER);
        core.fund{value: 0.05 ether}();
        require(core.ethPot() == potBefore + 0.05 ether, "settings: fund did not reach the pot");
        console.log("settings: markupBps 16000, window 7200, rate", rate);
    }

    // ------------------------------------------------------------------ pause

    /// buys revert `Paused` while the Core is paused
    function _pause() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length > 0, "pause: no held statement to price");
        uint256 sid = held[held.length - 1];
        uint256 creditId = core.pilePage(0, 1)[0];

        vm.broadcast(OWNER);
        core.setPaused(true);
        require(core.paused(), "pause: the Core is not paused");

        (bool okBuy, bytes memory buyErr) =
            address(ctl).call{value: ctl.grossPriceOf(sid)}(abi.encodeCall(IControllerV1.buy, (sid)));
        require(!okBuy && bytes4(buyErr) == ICore.Paused.selector, "pause: buy did not revert Paused while paused");
        (bool okCredit, bytes memory creditErr) =
            address(ctl).call{value: ctl.grossCreditPrice(creditId)}(abi.encodeCall(IControllerV1.buyCredit, (creditId)));
        require(!okCredit && bytes4(creditErr) == ICore.Paused.selector, "pause: buyCredit did not revert Paused while paused");

        vm.broadcast(OWNER);
        core.setPaused(false);
        require(!core.paused(), "pause: the Core is still paused");
        console.log("pause: paused then unpaused, buy and buyCredit reverted while paused");
    }

    // ------------------------------------------------------------------ buyback

    function _buyback() internal {
        require(core.ethToBuyback() > 0, "buyback: nothing in the buyback pot");
        uint256 supplyBefore = IERC20R(coin).totalSupply();
        uint256 potBefore = core.ethToBuyback();

        vm.broadcast(KEEPER);
        core.buyback();

        require(IERC20R(coin).totalSupply() < supplyBefore, "buyback: the coin supply did not fall");
        require(core.ethToBuyback() < potBefore, "buyback: the buyback pot did not move");
        console.log("buyback: supply burned", supplyBefore - IERC20R(coin).totalSupply());
        console.log("buyback: pot before", potBefore);
        console.log("buyback: pot after", core.ethToBuyback());
    }

    // ------------------------------------------------------------------ post: the balance side

    function _composeD() internal {
        require(core.pileSize() >= 80, "compose-d: fewer than 80 credits in the pile");
        uint256 heldBefore = core.heldStatements().length;
        vm.broadcast(KEEPER);
        core.compose(2);
        uint256[] memory held = core.heldStatements();
        require(held.length == heldBefore + 1, "compose-d: no statement held after compose");
        require(IStatements(Mainnet.STATEMENTS).formatOf(held[held.length - 1]) == 2, "compose-d: the format is not 2");
        console.log("compose-d: redemption statement id", held[held.length - 1]);
    }

    /// redeems the newest held statement, which e2e.sh warped to its floor, and releases the redeem burn reserve
    function _redeem() internal {
        uint256[] memory held = core.heldStatements();
        require(held.length >= 2, "redeem: need a statement to redeem and one to keep held");
        uint256 sid = held[held.length - 1];
        require(ctl.atFloor(sid), "redeem: the statement has not reached its floor");

        uint256 owed = core.ratingOf(sid) * IBalanceModule(core.balanceModule()).unitPerPoint();
        uint256 potBefore = IBalanceModule(core.balanceModule()).available();
        vm.broadcast(KEEPER);
        core.redeemStatement(sid);
        (bool stillHeld,,) = core.statementInfo(sid);
        require(!stillHeld, "redeem: the statement is still held");
        require(IBalanceModule(core.balanceModule()).available() >= potBefore + owed * 98 / 100, "redeem: the balance pot did not grow by the rating");
        require(core.heldStatements().length == held.length - 1, "redeem: held count did not fall by one");

        uint256 reserve = core.ethRedeemBurn();
        if (reserve > 0) {
            uint256 buybackBefore = core.ethToBuyback();
            vm.broadcast(OWNER);
            core.releaseRedeemBurn(reserve);
            require(core.ethToBuyback() == buybackBefore + reserve, "redeem: the reserve did not reach the buyback pot");
            console.log("redeem: released redeem burn reserve", reserve);
        }
        console.log("redeem: redeemed statement", sid);
        console.log("redeem: module holding", IBalanceModule(core.balanceModule()).available());
    }

    /// A3 sells credits into the balance bid, a single and a batch, and is paid in the balance token
    function _balanceBid() internal {
        IERC20R token = IERC20R(core.balanceToken());
        vm.broadcast(A3);
        ICredits(Mainnet.CREDITS).setApprovalForAll(address(core), true);

        uint256 paidBefore = token.balanceOf(A3);
        uint256[] memory one = _creditsOf(A3, 1);
        vm.broadcast(A3);
        core.sellForBalance(one);
        _requireBalanceCost(one[0]);

        uint256[] memory batch = _creditsOf(A3, 2);
        vm.broadcast(A3);
        core.sellForBalance(batch, 0);
        _requireBalanceCost(batch[1]);

        require(token.balanceOf(A3) > paidBefore, "balance-bid: the seller was not paid in the balance token");
        console.log("balance-bid: seller paid", token.balanceOf(A3) - paidBefore);
        console.log("balance-bid: module holding", IBalanceModule(core.balanceModule()).available());
    }

    /// the cost basis of a credit bought with the balance token is `score * pointRate`, at least 1 wei
    function _requireBalanceCost(uint256 id) internal view {
        (bool inPile, uint256 cost,) = core.creditInfo(id);
        require(inPile, "balance-bid: the credit is not in the pile");
        uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(
            ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id)
        );
        uint256 expected = score * ctl.pointRate();
        require(cost + score >= expected && cost <= expected + score, "balance-bid: the cost basis is not score * pointRate");
        console.log("balance-bid: credit cost basis", id, cost);
    }

    // ------------------------------------------------------------------ fresh: the last statement, live pile content

    /// composes the last statement, then sells credits that stay in the pile inside their window, so the final state
    /// holds a statement for sale and pile credits past and inside their window
    function _freshCompose() internal {
        require(core.pileSize() >= 80, "fresh-compose: fewer than 80 credits in the pile");
        uint256 heldBefore = core.heldStatements().length;
        vm.broadcast(KEEPER);
        core.compose();
        require(core.heldStatements().length == heldBefore + 1, "fresh-compose: no statement held after compose");

        uint256[] memory dust = _creditsOf(A1, 3);
        vm.broadcast(A1);
        core.sellForEth(dust);

        require(core.heldStatements().length >= 2, "fresh-compose: fewer than two statements held");
        require(core.pileSize() >= 3, "fresh-compose: fewer than three credits in the pile");
        console.log("fresh-compose: held statements", core.heldStatements().length);
        console.log("fresh-compose: pileSize", core.pileSize());
    }

    // ------------------------------------------------------------------ report

    function _report() internal view {
        console.log("== final report ==");
        console.log("ethPot", core.ethPot());
        console.log("ethToBuyback", core.ethToBuyback());
        console.log("ethRedeemBurn", core.ethRedeemBurn());
        console.log("module holding", IBalanceModule(core.balanceModule()).available());
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

    /// @dev the controller's credit sale settings as they are now
    function _credit() internal view returns (CreditSale memory) {
        return CreditSale({
            saleOn: ctl.creditSaleOn(),
            window: ctl.creditWindow(),
            floorBps: ctl.creditFloorBps(),
            startBps: ctl.creditStartBps(),
            royaltyBps: ctl.royaltyBps(),
            royaltyRecipient: ctl.royaltyRecipient()
        });
    }

    /// @dev `n` credit ids owned by `who` right now
    function _creditsOf(address who, uint256 n) internal view returns (uint256[] memory out) {
        uint256[] memory all = ICredits(Mainnet.CREDITS).tokensOf(who);
        require(all.length >= n, "actor holds fewer credits than the stage needs");
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = all[i];
        }
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
