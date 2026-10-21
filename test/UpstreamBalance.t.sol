// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IBalanceModule} from "../src/interfaces/Interfaces.sol";

interface IReserveMigration {
    function migrateReserve() external returns (uint256);
}

interface IOwedModule {
    function owed(address) external view returns (uint256);
    function totalOwed() external view returns (uint256);
    function claim(address) external returns (uint256);
    function pay(address, uint256) external;
}

interface IUpstreamToken {
    function renderer() external view returns (address);
    function decimals() external view returns (uint8);
    function ready() external view returns (bool);
    function quote(uint256) external view returns (uint256);
    function withdraw(uint256, uint256) external returns (uint256);
    function retireLaunchSupply() external;
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function opensAt() external view returns (uint64);
    function balanceOf(address) external view returns (uint256);
    function receipts(uint256) external view returns (address, uint256);
    function withdrawnCount() external view returns (uint256);
    function totalReleased() external view returns (uint256);
    function inkOf(address) external view returns (uint256[4] memory);
    function transfer(address, uint256) external returns (bool);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address, string calldata) external returns (uint8);
    function approve(address, uint256) external;
}

/// Real upstream creation bytecode (solc 0.8.28), real engine and mainnet NFTs.
/// Build the private-source artifact with script/tools/upstream-balance.sh. It pins the upstream commit and the code hashes.
/// this is a deploy-mechanics test of a fresh system, not the live Core: it builds a fresh engine, so it never reads
/// or mutates the live Core.
contract UpstreamBalanceTest is Fixture {
    IUpstreamToken private balanceToken;
    IBalanceModule private balanceModule;
    address private funderWallet;
    uint8 private nextFormat;
    uint256 private constant UNIT_PER_SCORE = 1e14;

    function setUp() public override {
        if (!vm.exists("out/upstream-balance.json")) {
            require(!vm.envOr("REQUIRE_UPSTREAM_BALANCE", false), "run script/tools/upstream-balance.sh first");
            vm.skip(true);
            return;
        }
        string memory artifact = vm.readFile("out/upstream-balance.json");
        bytes memory creation = vm.parseJsonBytes(artifact, ".bytecode.object");
        assertEq(sha256(creation), 0xecc7afbffdcebc9004e25f2e767e932fe697f266d28c33330862065ff00e98ae);
        super.setUp();
        funderWallet = _user("upstreamFunder");
        nextFormat = uint8(IUpstreamStatements(address(STATEMENTS)).formatCount());
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(
address(STATEMENTS), nextFormat, funderWallet)
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        require(deployed != address(0), "upstream deployment failed");
        balanceToken = IUpstreamToken(deployed);
        balanceModule = IBalanceModule(
            vm.deployCode("StatementBalanceModule.sol:StatementBalanceModule", abi.encode(address(core), deployed))
        );
        _setBalanceModule(address(balanceModule));
        _setSwitches(true, true);
    }

    function _register() private {
        IUpstreamStatements source = IUpstreamStatements(address(STATEMENTS));
        address renderer = balanceToken.renderer();
        vm.prank(source.owner());
        assertEq(source.addFormat(renderer, "Balance"), nextFormat);
        assertTrue(balanceToken.ready());
    }

    function _retire() private {
        uint256[] memory ids = _credits(funderWallet, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.startPrank(funderWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 sid = STATEMENTS.compose(page, 0);
        IUpstreamStatements(address(STATEMENTS)).approve(address(balanceToken), sid);
        balanceToken.withdraw(sid, balanceToken.quote(sid));
        balanceToken.retireLaunchSupply();
        vm.stopPrank();
        assertEq(balanceToken.totalRetired(), balanceToken.launchRetirement());
    }

    function _readyStatement() private returns (uint256 sid) {
        sid = _composeOnce().sid;
        _makeEligible(sid);
        assertTrue(ctl.atFloor(sid));
    }

    // Scores differ by Credit; select a real affordable page rather than assume any 80 have equal value.
    function _affordablePage() private returns (uint256[] memory ids) {
        uint256[] memory candidates = new uint256[](160);
        uint256[] memory scores = new uint256[](160);
        uint256 got;
        while (got < 160) {
            uint256 id = _nextCredit();
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            // The recent fork can include sales after this fixture list was captured.
            if (CREDITS.ownerOf(id) != STRATEGY) continue;
            candidates[got] = id;
            scores[got++] = _scoreOf(id);
        }
        for (uint256 i; i < 80; ++i) {
            for (uint256 j = i + 1; j < 160; ++j) {
                if (scores[j] < scores[i]) {
                    (candidates[i], candidates[j]) = (candidates[j], candidates[i]);
                    (scores[i], scores[j]) = (scores[j], scores[i]);
                }
            }
        }
        ids = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = candidates[i];
            vm.prank(STRATEGY);
            CREDITS.transferFrom(STRATEGY, seller, ids[i]);
        }
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(core), true);
    }

    function _assertUnchanged(uint256 sid, uint256 released, uint256 count) private view {
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(balanceToken.balanceOf(address(core)), 0);
        assertEq(balanceToken.balanceOf(address(balanceModule)), 0);
        (address holder,) = balanceToken.receipts(sid);
        assertEq(holder, address(0));
        assertEq(balanceToken.totalReleased(), released);
        assertEq(balanceToken.withdrawnCount(), count);
    }

    // promise: missing upstream renderer registration rolls back Core ownership and upstream receipts
    function test_registrationFailureRollsBackCustody() public {
        uint256 sid = _readyStatement();
        vm.expectRevert(bytes4(keccak256("RendererNotRegistered()")));
        core.redeemStatement(sid);
        _assertUnchanged(sid, 0, 0);
    }

    // promise: reaching the opening block cannot bypass Jack's creator retirement gate
    function test_retirementRequiredEvenAfterOpening() public {
        _register();
        uint256 sid = _readyStatement();
        vm.warp(balanceToken.opensAt());
        vm.expectRevert(bytes4(keccak256("LaunchSupplyNotFinalized()")));
        core.redeemStatement(sid);
        _assertUnchanged(sid, 0, 0);
    }

    // promise: redemption reverts ConversionNotOpen before opensAt and fills the module after it
    function test_redemptionClosedBeforeOpening() public {
        _register();
        _retire();
        uint256 sid = _readyStatement();
        uint256 owed = balanceToken.quote(sid);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x93d19510), balanceToken.opensAt()));
        core.redeemStatement(sid);
        assertEq(balanceToken.balanceOf(address(balanceModule)), 0);
        assertEq(balanceModule.available(), 0);
        vm.warp(balanceToken.opensAt());
        core.redeemStatement(sid);
        assertEq(balanceToken.balanceOf(address(balanceModule)), owed);
        assertEq(balanceModule.available(), owed);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForBalance(ids, 1, address(balanceToken));
        assertGt(balanceToken.balanceOf(seller), 0);
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    // promise: Jack's real bytecode funds a complete current-main redeem, buy 80 Credits, compose, redeem cycle
    function test_exactOpeningRedeemsAndRecyclesIntoCredits() public {
        _register();
        _retire();
        uint256 sid = _readyStatement();
        assertEq(balanceToken.decimals(), 18);
        assertEq(balanceModule.unitPerPoint(), UNIT_PER_SCORE);
        uint256 owed = core.ratingOf(sid) * UNIT_PER_SCORE;
        assertEq(balanceToken.quote(sid), owed);
        vm.warp(balanceToken.opensAt());
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(balanceToken));
        assertEq(balanceModule.available(), owed);
        assertEq(balanceToken.balanceOf(address(core)), 0);
        (address holder, uint256 amount) = balanceToken.receipts(sid);
        assertEq(holder, address(balanceModule));
        assertEq(amount, owed);
        uint256[4] memory ink = balanceToken.inkOf(address(balanceModule));
        assertEq(ink[0] + ink[1] + ink[2] + ink[3], owed);

        uint256[] memory ids = _affordablePage();
        uint256 score;
        uint256 postedTotal;
        uint256 royaltyTotal;
        uint256 parTotal;
        for (uint256 i; i < ids.length; ++i) {
            uint256 points = _scoreOf(ids[i]);
            score += points;
            parTotal += points * UNIT_PER_SCORE;
            // the posted payout per credit, 10_000 - balanceDiscountBps of par, and its artist royalty on top, both from
            // the module (decisions 163, 164)
            uint256 perCredit = points * UNIT_PER_SCORE * (10_000 - core.settings().balanceDiscountBps) / 10_000;
            postedTotal += perCredit;
            royaltyTotal += perCredit * core.settings().buyToArtistBps / 10_000;
        }
        assertLe(parTotal, owed, "first redemption funds this complete page at par");
        vm.prank(seller);
        core.sellForBalance(ids, postedTotal, address(balanceToken));
        uint256 paid = balanceToken.balanceOf(seller);
        assertEq(paid, postedTotal, "the seller receives the posted total exactly");
        assertLe(paid, parTotal);
        // the royalty transfer to the cold artist wallet fits ARTIST_PAY_GAS and lands directly
        assertEq(balanceToken.balanceOf(core.artist()), royaltyTotal);
        assertEq(IOwedModule(address(balanceModule)).owed(core.artist()), 0);
        assertEq(balanceModule.available(), owed - paid - royaltyTotal);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), address(core));
        }
        assertEq(core.pileSize(), 80);
        vm.warp(block.timestamp + ctl.creditWindow());
        core.compose();
        uint256 next = STATEMENTS.supply();
        assertEq(core.ratingOf(next), score);
        _makeEligible(next);
        core.redeemStatement(next);
        assertEq(STATEMENTS.ownerOf(next), address(balanceToken));
        assertEq(balanceModule.available(), owed - paid - royaltyTotal + score * UNIT_PER_SCORE);
        assertEq(balanceToken.balanceOf(address(core)), 0);
        vm.expectRevert(ICore.NotHeld.selector);
        core.redeemStatement(sid);
    }

    function _fundedModule() private returns (uint256 funded) {
        _register();
        _retire();
        uint256 sid = _readyStatement();
        vm.warp(balanceToken.opensAt());
        core.redeemStatement(sid);
        funded = balanceModule.available();
    }

    function _oneCredit() private returns (uint256[] memory one) {
        uint256[] memory ids = _affordablePage();
        one = new uint256[](1);
        one[0] = ids[0];
    }

    // promise: a one credit sale to a cold artist wallet pays the seller in full and the royalty transfers to the artist
    // directly inside ARTIST_PAY_GAS, with nothing recorded as owed
    function test_oneCreditColdArtistRoyaltyIsPaidDirectly() public {
        uint256 funded = _fundedModule();
        uint256[] memory one = _oneCredit();
        uint256 posted = _scoreOf(one[0]) * UNIT_PER_SCORE * (10_000 - core.settings().balanceDiscountBps) / 10_000;
        uint256 royalty = posted * core.settings().buyToArtistBps / 10_000;
        address art = core.artist();
        assertEq(balanceToken.balanceOf(art), 0, "cold artist");
        vm.prank(seller);
        core.sellForBalance(one, posted, address(balanceToken));
        assertEq(balanceToken.balanceOf(seller), posted);
        assertEq(balanceToken.balanceOf(art), royalty);
        assertEq(IOwedModule(address(balanceModule)).owed(art), 0);
        assertEq(balanceModule.available(), funded - posted - royalty);
        assertEq(IOwedModule(address(balanceModule)).totalOwed(), 0);
    }

    // promise: with full gas the payment transfers directly; logs the measured gas of a cold and a warm recipient
    function test_directPayWarmAndColdMeasure() public {
        _fundedModule();
        address cold = _user("coldWallet");
        uint256 amount = 1e18;
        vm.startPrank(address(core));
        uint256 g = gasleft();
        IOwedModule(address(balanceModule)).pay(cold, amount);
        uint256 coldGas = g - gasleft();
        g = gasleft();
        IOwedModule(address(balanceModule)).pay(cold, amount);
        uint256 warmGas = g - gasleft();
        vm.stopPrank();
        assertGt(coldGas, 200_000, "a cold transfer exceeds the former 200k bound");
        assertLt(coldGas, 600_000, "a cold transfer fits the ARTIST_PAY_GAS bound");
        assertLt(warmGas, coldGas);
        assertEq(balanceToken.balanceOf(cold), 2 * amount);
        assertEq(IOwedModule(address(balanceModule)).owed(cold), 0);
    }

    // promise: a payment whose transfer cannot finish inside the gas given is recorded as owed, excluded from available(),
    // unspendable by a later payment, and settled in full by claim
    function test_boundedPayAccruesAndClaimSettles() public {
        uint256 funded = _fundedModule();
        IOwedModule m = IOwedModule(address(balanceModule));
        address to = _user("starvedArtist");
        uint256 amount = 5e18;
        vm.prank(address(core));
        m.pay{gas: 100_000}(to, amount);
        assertEq(m.owed(to), amount, "accrued");
        assertEq(m.totalOwed(), amount);
        assertEq(balanceToken.balanceOf(to), 0);
        address direct = _user("directArtist");
        vm.prank(address(core));
        m.pay{gas: 1_000_000}(direct, amount);
        assertEq(balanceToken.balanceOf(direct), amount, "paid directly");
        assertEq(m.owed(direct), 0);
        funded -= amount;
        assertEq(balanceModule.available(), funded - amount, "owed is outside available");
        vm.prank(address(core));
        vm.expectRevert();
        m.pay(seller, funded - amount + 1);
        vm.prank(address(core));
        m.pay(seller, funded - amount);
        assertEq(balanceToken.balanceOf(seller), funded - amount);
        assertEq(balanceModule.available(), 0);
        assertEq(balanceToken.balanceOf(address(balanceModule)), amount, "the owed amount stays in the module");
        assertEq(m.claim(to), amount);
        assertEq(balanceToken.balanceOf(to), amount);
        assertEq(m.owed(to), 0);
        assertEq(m.totalOwed(), 0);
        assertEq(m.claim(to), 0);
    }

    // promise: real Core retirement moves existing and later real BALANCE proceeds only to the successor module
    function test_retirementMigratesReserveAndLaterRedemption() public {
        _register();
        _retire();
        uint256 sid = _readyStatement();
        uint256 owed = balanceToken.quote(sid);
        vm.warp(balanceToken.opensAt());
        core.redeemStatement(sid);
        ICore nextCore = _successorCore(address(0), core.RATE_START(), core.settings());
        IBalanceModule nextModule = IBalanceModule(
            vm.deployCode(
                "StatementBalanceModule.sol:StatementBalanceModule",
                abi.encode(address(nextCore), address(balanceToken))
            )
        );
        vm.prank(owner);
        nextCore.setBalanceModule(address(nextModule));
        uint256[] memory ids = _affordablePage();
        vm.prank(seller);
        core.sellForBalance(ids, 1, address(balanceToken));
        vm.warp(block.timestamp + ctl.creditWindow());
        core.compose();
        uint256 late = STATEMENTS.supply();
        _makeEligible(late);
        vm.startPrank(owner);
        core.setSuccessor(address(nextCore));
        core.migrate(0);
        vm.stopPrank();
        assertTrue(core.retired());
        uint256 remaining = balanceModule.available();
        assertGt(remaining, 0);
        assertLt(remaining, owed);
        assertEq(IReserveMigration(address(balanceModule)).migrateReserve(), remaining);
        assertEq(balanceModule.available(), 0);
        assertEq(nextModule.available(), remaining);
        uint256 lateOwed = balanceToken.quote(late);
        core.redeemStatement(late);
        assertEq(balanceModule.available(), lateOwed);
        assertEq(IReserveMigration(address(balanceModule)).migrateReserve(), lateOwed);
        assertEq(balanceModule.available(), 0);
        assertEq(nextModule.available(), remaining + lateOwed);
        assertEq(balanceToken.balanceOf(address(core)), 0);
        assertEq(balanceToken.balanceOf(address(nextCore)), 0);
    }
}
