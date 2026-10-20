// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, ICreditStrategy, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2, IArtCoinsMevSkimV2} from "../src/interfaces/ArtCoinsV2.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";

/// In-process only: existing mainnet Core, simulated missing launch, test-funded traders and buyer, real Credits
/// provisioned by impersonating their Strategy owner. No Fixture deployment, mocked scores, Core donation or settings edit.
contract PrecoinLifecycleTest is SeaportBase {
    uint256 internal constant PINNED_BLOCK = 26_230_720;

    // Inherit only the real-order encoding and Credit provisioning helpers; never deploy a fixture Core.
    function setUp() public override {}

    // promise: the canonical deferred Core and final launch tuple support real swap income, adapter intake,
    // composition, Statement sale and CC buyback burn, while redemption stays closed without a BALANCE module.
    function test_precoinCanonicalPhaseOneLifecycle() public {
        if (!vm.envOr("PRECOIN_LIFECYCLE", false)) vm.skip(true);
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        assertEq(rpc, "https://mainnet.gateway.tenderly.co", "explicit approved fork RPC");
        vm.createSelectFork(rpc, PINNED_BLOCK);
        assertEq(block.chainid, 1);
        assertEq(block.number, PINNED_BLOCK);
        lc = loadConfig("script/config/mainnet.json");
        _bindRecordedCore();
        _simulateMissingLaunch();
        _realSwapIncome();
        _adapterIntake();
        console.log("before synthetic page: pot wei", core.ethPot());
        console.log("before synthetic page: acquired credits", core.pileSize());
        _provisionPage();
        uint256 sid = _composeRecordedPage();
        _sellStatement(sid);
        _burnBuyback();
        _solvent();
    }

    function _bindRecordedCore() internal {
        string memory record = vm.readFile("deployments/1.json");
        assertEq(vm.parseJsonUint(record, ".chainId"), 1);
        assertFalse(vm.parseJsonBool(record, ".coinLive"), "record is pre-coin");
        assertEq(vm.parseJsonBytes32(record, ".configHash"), configHash(lc), "original deployment config");
        owner = vm.parseJsonAddress(record, ".owner");
        assertEq(owner, lc.owner);
        core = ICore(payable(vm.parseJsonAddress(record, ".core")));
        coin = IArtCoinsTokenV2(vm.parseJsonAddress(record, ".coin"));
        ctl = IControllerV1(vm.parseJsonAddress(record, ".controller"));
        seaportAdapter = vm.parseJsonAddress(record, ".seaportAdapter");
        strategyAdapter = vm.parseJsonAddress(record, ".strategyAdapter");
        renderer = vm.parseJsonAddress(record, ".renderer");
        FACTORY = IArtCoinsFactoryV2(lc.stack.factory);
        assertEq(coreAddress(lc, owner), address(core), "canonical Core derivation");
        assertEq(controllerAddress(address(core), lc), address(ctl));
        assertEq(seaportAdapterAddress(address(core), lc.seaportRecipients), seaportAdapter);
        assertEq(strategyAdapterAddress(), strategyAdapter);
        assertEq(rendererAddress(lc), renderer);
        assertGt(address(core).code.length, 0);
        assertEq(address(coin).code.length, 0, "only the coin launch is missing");
        assertEq(core.COIN(), address(coin));
        assertEq(core.controller(), address(ctl));
        assertEq(core.owner(), owner);
        assertTrue(core.allowedAdapter(seaportAdapter));
        assertTrue(core.allowedAdapter(strategyAdapter));
        assertEq(FACTORY.tokenDeployer(), vm.parseJsonAddress(record, ".tokenDeployer"));
        _requireOwner(lc, owner);
        uint256 liveRate = core.RATE_START();
        console.log("fork opening rate wei per 100 points", liveRate);
        // A real prelaunch reset retains the constructor config; its existing separate rate/hash signoff is required.
        uint256 expectedRate = _approvedOpeningRate(lc);
        assertEq(liveRate, expectedRate, "live rate needs the explicit prelaunch reset tuple if changed");
        assertEq(expectedRate, 0.0097 ether, "owner-approved live opening rate");
        assertEq(core.rateAtCheckpoint(), expectedRate);
        Settings memory expected = abi.decode(abi.encode(lc.settings), (Settings));
        if (expectedRate != lc.rateStart) expected.rateCap = uint64(expectedRate * 3);
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(expected)), "exact live settings");
        assertEq(lc.rateStart, 0.0056 ether, "original constructor opening rate");
        assertEq(lc.settings.rateCap, 0.0168 ether, "original constructor cap");
        assertEq(core.settings().rateCap, expectedRate * 3);
        assertEq(core.settings().rateCap, 0.0291 ether, "owner-approved live 3x cap");
        assertEq(lc.sniperStartBps, 6900);
        assertEq(lc.sniperSeconds, 4140);
        assertEq(core.settings().sniperSeconds, 4140);
        assertTrue(core.settings().redeemOn);
        assertFalse(core.settings().balanceBidOn);
        assertFalse(core.settings().valueModeOn);
        assertEq(core.balanceModule(), address(0));
        assertEq(core.balanceToken(), address(0));
        assertFalse(core.controllerLocked(), "phase-two replacement remains possible");
        assertEq(core.ethPot(), 0);
        assertEq(core.ethToBuyback(), 0);
        assertEq(core.ethRedeemBurn(), 0);
        assertEq(address(core).balance, 0);
        assertEq(core.pileSize(), 0);
        (maker, makerKey) = makeAddrAndKey("precoin.synthetic.Seaport.maker");
        keeper = _user("precoin.keeper");
        seller = _user("precoin.seller");
        funder = _user("precoin.trader");
        feeTaker = lc.seaportRecipients[0];
        vm.fee(0.2 gwei);
    }

    function _simulateMissingLaunch() internal {
        uint256 fee = FACTORY.deployFee();
        vm.deal(owner, owner.balance + fee);
        vm.startPrank(owner);
        address launched = _launch(lc, address(coin), address(core));
        vm.stopPrank();
        assertEq(launched, address(coin));
        assertTrue(FACTORY.isCoin(launched));
        assertGt(launched.code.length, 0);
        launchKey = poolKeyOf(launched, lc.stack);
        poolId = keccak256(abi.encode(launchKey));
        assertEq(coin.canonicalPoolId(), poolId);
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = FACTORY.deploymentInfo(launched);
        assertEq(info.poolId, poolId);
        assertEq(info.hook, lc.stack.hook);
        launchTime = info.launchedAt;
        assertEq(launchTime, block.timestamp);
        IArtCoinsMevSkimV2.SkimSchedule memory schedule = IArtCoinsMevSkimV2(lc.mevModule).schedule(poolId);
        assertEq(schedule.startingSkimBps, 6900);
        assertEq(schedule.endSkimBps, 690);
        assertEq(schedule.windowSeconds, 4140);
        router = new TestSwapRouter();
        autoBook = false;
    }

    function _realSwapIncome() internal {
        assertGt(_buyCoin(funder, 5 ether), 0, "test-funded buy received real coin");
        assertGt(address(core).balance, 0, "initial 69-percent hook fee reached Core");
        assertEq(core.ethPot(), 0, "swap fees are initially unbooked");
        _bookAndCheck();
        assertFalse(core.payeeOn(), "no early payee latch");
        vm.warp(launchTime + lc.sniperSeconds + 1);
        (uint24 skim, bool active) = IArtCoinsMevSkimV2(lc.mevModule).currentSkimBps(poolId);
        assertEq(skim, 690);
        assertFalse(active);
        assertGt(_buyCoin(funder, 1 ether), 0);
        _bookAndCheck();
        assertTrue(core.payeeOn(), "post-window income latches the payee");
        assertGt(_sellCoin(funder, coin.balanceOf(funder) / 4), 0, "real pool sell delivered ETH");
        _bookAndCheck();
        assertGt(core.ethPot(), core.reserve(), "fees funded real buying room");
    }

    function _bookAndCheck() internal {
        uint256 pot = core.ethPot();
        uint256 burnReserve = core.ethRedeemBurn();
        uint256 pending = address(core).balance - pot - core.ethToBuyback() - burnReserve;
        assertGt(pending, 0);
        Settings memory settings = core.settings();
        uint256 payeePart = core.payeeOn() ? pending * settings.payeePpm / 1_000_000 : 0;
        uint256 reservePart = (pending - payeePart) * settings.feeToRedeemBurnBps / 10_000;
        uint256 payeeBefore = core.payee().balance;
        vm.prank(keeper);
        core.book();
        assertEq(core.payee().balance - payeeBefore, payeePart);
        assertEq(core.ethRedeemBurn(), burnReserve + reservePart);
        assertEq(core.ethPot(), pot + pending - payeePart - reservePart);
        _solvent();
    }

    function _adapterIntake() internal {
        // Strategy availability is mutable. Prior same-record Strategy proof is retained if these current asks are gone.
        vm.warp(block.timestamp + 24 hours);
        uint256[2] memory candidates = [uint256(22357), uint256(35377)];
        bool strategyFilled;
        for (uint256 i; i < candidates.length; ++i) {
            uint256 id = candidates[i];
            uint256 price = ICreditStrategy(STRATEGY).nftForSale(id);
            if (price == 0 || CREDITS.ownerOf(id) != STRATEGY || core.bidOf(id) <= price + 0.001 ether) continue;
            uint256 artistBefore = core.artist().balance;
            uint256 potBefore = core.ethPot();
            uint256 rewardBefore = keeper.balance;
            vm.prank(keeper);
            core.buyListing(strategyAdapter, id, "");
            uint256 royalty = price * core.settings().buyToArtistBps / 10_000;
            assertEq(CREDITS.ownerOf(id), address(core));
            assertEq(core.artist().balance - artistBefore, royalty);
            assertEq(potBefore - core.ethPot(), price + royalty + keeper.balance - rewardBefore);
            strategyFilled = true;
            console.log("current pinned Strategy acquisition", id);
            break;
        }
        console.log("current pinned Strategy fill available", strategyFilled);
        uint256 id = _credits(maker, 1)[0];
        vm.prank(maker);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        uint256 ask = core.bidOf(id) / 2;
        assertGt(ask, 0);
        uint256 fee = ask * 250 / 10_000;
        uint256 makerBefore = maker.balance;
        uint256 feeBefore = feeTaker.balance;
        uint256 artistBefore = core.artist().balance;
        _buy(id, _basicData(_open(id, ask - fee, fee)), ask);
        assertEq(maker.balance - makerBefore, ask - fee);
        assertEq(feeTaker.balance - feeBefore, fee);
        assertEq(core.artist().balance - artistBefore, ask * core.settings().buyToArtistBps / 10_000);
    }

    function _provisionPage() internal {
        // Synthetic supply only: impersonated Strategy transfers provision real, unmodified Credits to a test seller.
        uint256[] memory ids = _credits(seller, 80 - core.pileSize());
        for (uint256 i; i < ids.length; ++i) {
            uint256 bid = core.bidOf(ids[i]);
            assertGt(bid, 0, "real onchain score and funded bid");
            uint256 artistBefore = core.artist().balance;
            uint256 sellerBefore = seller.balance;
            uint256 potBefore = core.ethPot();
            uint256 royalty = bid * core.settings().buyToArtistBps / 10_000;
            assertGe(potBefore, core.reserve() + bid + royalty, "synthetic trade fees must fund this real-score NFT");
            vm.prank(seller);
            core.sellForEth(_one(ids[i]), bid);
            assertEq(seller.balance - sellerBefore, bid);
            assertEq(core.artist().balance - artistBefore, royalty);
            assertEq(potBefore - core.ethPot(), bid + royalty);
        }
        assertEq(core.pileSize(), 80);
        _solvent();
    }

    function _composeRecordedPage() internal returns (uint256 sid) {
        console.log("before compose: pot wei", core.ethPot());
        (bool ready,,) = ctl.nextPage();
        assertFalse(ready, "fresh page observes the actual sale window");
        vm.warp(block.timestamp + ctl.creditWindow() + 1);
        vm.roll(block.number + 1);
        (ready,,) = ctl.nextPage();
        assertTrue(ready);
        uint256 before = STATEMENTS.supply();
        uint256 potBefore = core.ethPot();
        uint256 rewardBefore = keeper.balance;
        vm.prank(keeper);
        core.compose();
        sid = before + 1;
        assertEq(STATEMENTS.supply(), sid);
        assertEq(core.pileSize(), 0);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(core.composerOf(sid), keeper);
        assertEq(potBefore - core.ethPot(), keeper.balance - rewardBefore);
        vm.expectRevert(ICore.NoBalanceModule.selector);
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "failed redemption preserves custody");
    }

    function _sellStatement(uint256 sid) internal {
        console.log("before Statement sale: pot wei", core.ethPot());
        Settings memory settings = core.settings();
        uint256 price = ctl.priceOf(sid);
        uint256 artistBefore = core.artist().balance;
        uint256 payeeBefore = core.payee().balance;
        uint256 buybackBefore = core.ethToBuyback();
        uint256 potBefore = core.ethPot();
        address buyer = _user("precoin.statementBuyer");
        _buy(buyer, sid);
        uint256 artistPart = price * settings.saleToArtistBps / 10_000;
        uint256 operatorPart = price * settings.saleToOperatorBps / 10_000;
        uint256 remainder = price - artistPart - operatorPart;
        uint256 buybackPart = remainder * settings.saleToBuybackBps / 10_000;
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(core.artist().balance - artistBefore, artistPart);
        assertEq(core.payee().balance - payeeBefore, operatorPart);
        assertEq(core.ethToBuyback() - buybackBefore, buybackPart);
        assertEq(core.ethPot() - potBefore, remainder - buybackPart);
    }

    function _burnBuyback() internal {
        console.log("before buyback: pot wei", core.ethPot());
        console.log("before buyback: buyback wei", core.ethToBuyback());
        vm.roll(block.number + core.settings().buybackDelay + 1);
        uint256 supplyBefore = coin.totalSupply();
        uint256 buybackBefore = core.ethToBuyback();
        assertGt(buybackBefore, 0);
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supplyBefore, "canonical pool purchase burned real coin");
        assertLt(core.ethToBuyback(), buybackBefore);
        _bookAndCheck();
    }
}
