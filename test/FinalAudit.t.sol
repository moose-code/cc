// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ValueBase} from "./ValueMode.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {IUpstreamToken, IUpstreamStatements} from "./UpstreamBalance.t.sol";
import {Test} from "forge-std/Test.sol";

contract FinalAuditRoyaltyTest is Fixture {
    address internal sellerA;
    address internal sellerB;

    function setUp() public override {
        super.setUp();
        _enterPhase2();
        sellerA = _user("audit.royalty.sellerA");
        sellerB = _user("audit.royalty.sellerB");
    }

    // promise: an unpaid artist royalty remains reserved until recovery, even if a later small bid fits the module.
    function test_failedArtistRoyaltyCanFundTheNextSeller() public {
        uint256 idA = _credits(sellerA, 1)[0];
        uint256 idB = _credits(sellerB, 1)[0];
        uint256 firstPay = core.balanceBidOf(idA);
        uint256 firstRoyalty = firstPay * core.settings().buyToArtistBps / 10_000;
        assertGt(firstRoyalty, 0);

        // Leave exactly one payout and its royalty in the module. Its available() is its entire token holding.
        mod.pay(address(this), _moduleHolding() - firstPay - firstRoyalty);
        address artist = _user("audit.royalty.bannedArtist");
        _setArtist(artist);
        xt.setBanned(artist);
        vm.prank(sellerA);
        core.sellForBalance(_one(idA));
        assertEq(_moduleHolding(), firstRoyalty, "the failed royalty remains in available funds");
        assertEq(xt.balanceOf(artist), 0, "the artist was not paid");

        // Lower the posted bid so a second seller can be paid out of the first artist's unpaid royalty.
        Settings memory s = core.settings();
        s.balanceDiscountBps = 9_999;
        _setSettings(s);
        uint256 secondPay = core.balanceBidOf(idB);
        assertGt(secondPay, 0);
        assertLt(secondPay + secondPay * s.buyToArtistBps / 10_000, firstRoyalty);
        uint256 sellerBefore = xt.balanceOf(sellerB);
        vm.prank(sellerB);
        core.sellForBalance(_one(idB));
        assertEq(xt.balanceOf(sellerB) - sellerBefore, secondPay, "seller B consumes the unpaid artist reserve");
        assertLt(_moduleHolding(), firstRoyalty, "the royalty has no reserved balance");
        emit log_named_uint("unpaid first royalty token wei", firstRoyalty);
        emit log_named_uint("second seller payout token wei", secondPay);
        emit log_named_uint("module remainder token wei", _moduleHolding());
    }
}

contract FinalAuditValueTest is ValueBase {
    // promise: the value-mode balance route can operate from a funded module without an ETH pot.
    function test_fundedBalanceModuleCannotBuyWithoutEthPot() public {
        _valueOn();
        address user = _user("audit.value.zeroPotSeller");
        uint256 id = _credits(user, 1)[0];
        uint256 moduleFunds = _moduleHolding();
        uint256 posted = _scoreOf(id) * UNIT * core.balanceRate() / 10_000;
        assertGt(moduleFunds, posted, "module has much more than one posted payout");
        assertEq(core.ethPot(), 0, "no ETH has entered the engine");
        assertEq(core.balanceBidOf(id), 0, "the ETH pot zeroes the independent balance bid");
        emit log_named_uint("funded module token wei", moduleFunds);
        emit log_named_uint("posted payout token wei", posted);
        vm.prank(user);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForBalance(_one(id));
    }

    // promise: a value-mode quote outage does not restore the uncapped balance payout after a protected sale.
    function test_poolLiquidityOutageRestoresUncappedBalancePayout() public {
        uint256 id = _fillEthPile(1)[0];
        _valueOn();
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);

        uint256 highSpot = _swapToSpot(ctl.referencePrice() * 355 / 100);
        address buyer = _user("audit.value.buyer");
        address receiver = _user("audit.value.receiver");
        uint256 price = ctl.creditPrice(id);
        vm.deal(buyer, price);
        vm.prank(buyer);
        ctl.buyCredit{value: price}(id);
        vm.prank(buyer);
        CREDITS.transferFrom(buyer, receiver, id);

        // Let a healthy prior-block sample catch the higher spot and confirm that decision 165 clamps this payout.
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.roll(block.number + 1);
        uint256 posted = _scoreOf(id) * UNIT * core.balanceRate() / 10_000;
        uint256 capped = core.balanceBidOf(id);
        assertLt(capped, posted, "a healthy quote protects the balance payout");

        // The attacker owns this pool's liquidity. One more scheduled sample sees no depth and disables the quote.
        _addFullRange(-int256(uint256(POOL_LIQ)));
        assertEq(_liquidityNow(), 0, "owner-controlled liquidity leaves the pool");
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        (, bool ok) = ctl.balanceClampFor(_scoreOf(id), posted);
        assertFalse(ok, "the newest zero-liquidity sample disables the value quote");
        uint256 paid = core.balanceBidOf(id);
        assertEq(paid, posted, "quote outage restores the uncapped posted payout");
        vm.startPrank(receiver);
        CREDITS.setApprovalForAll(address(core), true);
        core.sellForBalance(_one(id));
        vm.stopPrank();
        assertEq(xt.balanceOf(receiver), paid, "second wallet bypasses the buyer-only return lock");
        assertGt(paid * highSpot / 1e18, price, "tokens are worth more at pre-outage spot than sale price");
        emit log_named_uint("Credit sale price wei", price);
        emit log_named_uint("healthy quote capped token payout", capped);
        emit log_named_uint("uncapped token payout", paid);
        emit log_named_uint("payout marked at pre-outage spot wei", paid * highSpot / 1e18);
        emit log_named_uint("pre-outage spot wei per token", highSpot);
    }
}

contract FinalAuditRealRoyaltyTest is Fixture {
    function setUp() public override {
        require(vm.exists("out/upstream-balance.json"), "run script/tools/upstream-balance.sh");
        bytes memory creation = vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object");
        assertEq(sha256(creation), 0x980130b1bedb50d2f226fce4509ed80011780ff04d0641eafbdae4e6aeb89a08);
        super.setUp();
        address funderWallet = _user("upstreamFunder");
        uint8 fmt = uint8(IUpstreamStatements(address(STATEMENTS)).formatCount());
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(
                address(STATEMENTS), fmt, uint64(block.number + 100), funderWallet,
                _user("upstreamAuction"), _user("upstreamLiquidity")
            )
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        require(deployed != address(0), "upstream deployment failed");
        address module = vm.deployCode(
            "StatementBalanceModule.sol:StatementBalanceModule", abi.encode(address(core), deployed)
        );
        _setBalanceModule(module);
        _setSwitches(true, true);
    }

    // promise: the production module pays the artist when one real Jack-token balance fill succeeds.
    function test_oneCreditArtistRoyaltyFailsWithJackToken() public {
        IUpstreamToken token = IUpstreamToken(core.balanceToken());
        IUpstreamStatements source = IUpstreamStatements(address(STATEMENTS));
        uint8 fmt = uint8(source.formatCount());
        address renderer = token.renderer();
        vm.prank(source.owner());
        source.addFormat(renderer, "Balance");

        address retireWallet = _user("upstreamFunder");
        uint256[] memory retirementIds = _credits(retireWallet, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) page[i] = retirementIds[i];
        vm.startPrank(retireWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 retiredStatement = STATEMENTS.compose(page, fmt);
        source.approve(address(token), retiredStatement);
        token.withdraw(retiredStatement, token.quote(retiredStatement));
        token.retireLaunchSupply();
        vm.stopPrank();

        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.roll(token.transfersOpenBlock());
        core.redeemStatement(sid);
        address singleSeller = _user("audit.realRoyalty.singleSeller");
        uint256 id = _credits(singleSeller, 1)[0];
        uint256 pay = core.balanceBidOf(id);
        uint256 expectedRoyalty = pay * core.settings().buyToArtistBps / 10_000;
        address artist = core.artist();
        uint256 beforeModule = token.balanceOf(core.balanceModule());
        vm.prank(singleSeller);
        core.sellForBalance(_one(id));
        assertEq(token.balanceOf(singleSeller), pay, "seller receives the balance bid");
        assertEq(token.balanceOf(artist), 0, "artist royalty transfer failed under the gas stipend");
        assertEq(token.balanceOf(core.balanceModule()), beforeModule - pay, "unpaid royalty stays spendable");
        emit log_named_uint("one-credit seller payout token wei", pay);
        emit log_named_uint("unpaid royalty token wei", expectedRoyalty);
    }
}

contract FinalAuditDocsTest is Test {
    function _count(string memory body, string memory word) private pure returns (uint256 n) {
        bytes memory a = bytes(body);
        bytes memory b = bytes(word);
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool hit = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) { hit = false; break; }
            }
            if (hit) ++n;
        }
    }

    // promise: the published specification gives one balance bid rule, matching the implemented flat 90 percent rate.
    function test_specStillStatesBothRisingAndFlatBalanceRules() public {
        string memory spec = vm.readFile("docs/SPEC.md");
        assertGt(_count(spec, "rises like the eth bid"), 0);
        assertGt(_count(spec, "flat posted price"), 0);
        emit log_named_uint("old rising statement count", _count(spec, "rises like the eth bid"));
    }

    // promise: the integration guide names current controller methods and events, not removed pricing interfaces.
    function test_integrationStillNamesRemovedObserveAndBalanceFill() public {
        string memory guide = vm.readFile("docs/INTEGRATION.md");
        assertGt(_count(guide, "controller.observe()"), 0);
        assertGt(_count(guide, "BalanceRateFill"), 0);
        assertEq(_count(vm.readFile("src/interfaces/IControllerV1.sol"), "function observe("), 0);
        assertEq(_count(vm.readFile("src/Core.sol"), "event BalanceRateFill"), 0);
        emit log_named_uint("obsolete observe reference count", _count(guide, "controller.observe()"));
        emit log_named_uint("obsolete BalanceRateFill reference count", _count(guide, "BalanceRateFill"));
    }

    // promise: the release status identifies the exact merged candidate state before a launch gate is evaluated.
    function test_statusCallsBuiltRoyaltyAndFlatBidUnmerged() public {
        string memory status = vm.readFile("docs/STATUS.md");
        assertGt(_count(status, "not merged (decisions 163 and 164)"), 0);
        assertGt(_count(vm.readFile("src/lib/CoreLib.sol"), "buyToArtistBps"), 0);
        assertGt(_count(vm.readFile("src/lib/CoreLib.sol"), "balanceDiscountBps"), 0);
    }

    // promise: the phase-two launch day leaves market fees unbooked until the keeper chooses a book call.
    function test_phaseTwoLaunchFixtureStillAutoBooks() public {
        string memory day = vm.readFile("test/LaunchDayPhase2.t.sol");
        assertGt(_count(day, "autoBook = true"), 0);
        emit log_named_uint("immediate-book fixture assignments", _count(day, "autoBook = true"));
    }

    // promise: the release gate names the exact candidate and finished checks before it can pass.
    function test_freezeTableStillNamesAnOlderPendingCandidate() public {
        string memory status = vm.readFile("docs/STATUS.md");
        assertGt(_count(status, "pending issue 23"), 0);
        assertEq(_count(status, "1db4a9f | frozen"), 0);
    }

    // promise: production comments explain live rules without relying on a reader's decision-log history.
    function test_productionCommentsCarryDecisionHistory() public {
        uint256 coreN = _count(vm.readFile("src/Core.sol"), "decision ");
        uint256 libN = _count(vm.readFile("src/lib/CoreLib.sol"), "decision ");
        uint256 ctlN = _count(vm.readFile("src/ControllerV1.sol"), "decision ");
        assertGt(coreN, 0);
        assertGt(libN, 0);
        assertGt(ctlN, 0);
        emit log_named_uint("Core decision citations", coreN);
        emit log_named_uint("CoreLib decision citations", libN);
        emit log_named_uint("Controller decision citations", ctlN);
    }

    // promise: user-facing royalty copy matches the real BALANCE-token royalty outcome.
    function test_webClaimsEveryPurchasePaysArtist() public {
        assertGt(_count(vm.readFile("web/app/sell/page.tsx"), "engine pays the artist"), 0);
    }
}
