// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {FeeBase} from "./Fees.t.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";

/// independent review of the v2 port (REVIEW-v2port.md, git history before packet 0). `test_FINDING_*` asserts a real defect as it behaves
/// today. `test_FIXED_*` proves a finding is closed, `test_ACCEPTED_*` pins a behavior the owner accepted, `test_OK_*`
/// confirms a property that holds. real contracts on the pinned fork, attacker contracts only where a third party needs code

/// F2. the buyback has no min out. FLOW 10.1 and ARCHITECTURE item 17 say a sandwich of a slice loses money after both
/// skims. at the v2 skim of 6.9 points that failed at the old 5 eth bound (V2R-2). the bound is now 2 eth
contract ReviewSandwichTest is FeeBase {
    function _sandwich(uint256 slice, uint256 mult) internal returns (int256 net) {
        uint256 snap = vm.snapshotState();
        vm.deal(address(core), address(core).balance + slice);
        vm.store(address(core), bytes32(uint256(7)), bytes32(slice));
        assertEq(core.ethToBuyback(), slice, "slot 7 is ethToBuyback");
        _forceSlice(slice);
        vm.roll(block.number + 100);
        address mev = _user("mev");
        uint256 front = slice * mult;
        uint256 got = _buyCoin(mev, front);
        vm.prank(keeper);
        core.buyback();
        uint256 back = _sellCoin(mev, got);
        net = int256(back) - int256(front);
        vm.revertToState(snap);
    }

    /// writes `buybackSlice` (bits 0 to 127 of the second settings word) and `buybackDelay` 1 (bits 176 to 191 of the
    /// first word) straight into storage, so a slice above the bound can be simulated
    function _forceSlice(uint256 slice) internal {
        bytes32 at0 = bytes32(uint256(keccak256("credits.core.settings.v1")));
        bytes32 at1 = bytes32(uint256(at0) + 1);
        uint256 w = uint256(vm.load(address(core), at1));
        uint256 m128 = type(uint128).max;
        w = (w & ~m128) | slice;
        vm.store(address(core), at1, bytes32(w));
        // buybackDelay: bits 176 to 191 of the first settings word, after nine uint16 fields and `peakHalfLife`
        uint256 w0 = uint256(vm.load(address(core), at0));
        w0 = (w0 & ~(uint256(type(uint16).max) << 176)) | (uint256(1) << 176);
        vm.store(address(core), at0, bytes32(w0));
        assertEq(core.settings().buybackSlice, slice, "slice written");
        assertEq(core.settings().buybackDelay, 1, "delay written");
    }

    function _best(uint256 slice) internal returns (int256 best) {
        uint256[6] memory m = [uint256(1), 2, 3, 4, 6, 8];
        best = type(int256).min;
        for (uint256 i; i < 6; ++i) {
            int256 r = _sandwich(slice, m[i]);
            emit log_named_int(string.concat(vm.toString(slice / 1 ether), " eth slice, front x", vm.toString(m[i])), r);
            if (r > best) best = r;
        }
    }

    /// V2R-2 fixed: the bound is 1 eth (FLOW decision 51), and a sandwich of a slice at the bound loses for every front run size
    function test_FIXED_sandwichOfTheSliceAtTheBoundLosesAtTheLaunchSkim() public {
        _skipToSplitStart();
        Settings memory s = core.settings();
        s.buybackSlice = 1 ether + 1;
        vm.prank(core.owner());
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("buybackSlice")));
        core.setSettings(s);
        assertLt(_best(0.5 ether), 0, "the 0.5 eth launch slice loses");
        assertLt(_best(1 ether), 0, "the 1 eth slice at the bound loses");
    }

    /// why the bound is not higher: a 3 eth slice (inside the old 5 eth bound) profited at the same state
    function test_OK_aThreeEthSliceWouldHaveProfited() public {
        _skipToSplitStart();
        assertGt(_best(3 ether), 0, "3 eth slice profits, so it stays out of bounds");
    }
}


/// a payee that does real work on receipt (a splitter: three cold storage writes, about 70k gas)
contract HeavyPayee {
    uint256 public a;
    uint256 public b;
    uint256 public got;

    receive() external payable {
        got += msg.value;
        a = 1;
        b = 1;
    }
}

/// F3. anyone chooses the gas of `flush`
contract ReviewRouterGasTest is FeeBase {
    HeavyPayee internal heavy;

    function setUp() public override {
        super.setUp();
        heavy = new HeavyPayee();
        _skipToSplitStart();
        autoFlush = false;
        _buyCoin(trader, 3 ether);
        _flush(); // the first flush at the start turns the split on
        assertTrue(feeRouter.splitOn());
        address[] memory who = new address[](1);
        who[0] = address(heavy);
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 112_778;
        vm.prank(owner);
        feeRouter.setPayees(who, ppm);
    }

    function _tryFlush(uint256 g) internal returns (bool ok) {
        vm.prank(flusher);
        (ok,) = address(feeRouter).call{gas: g}(abi.encodeCall(IFeeRouter.flush, ()));
    }

    function test_OK_aNormalFlushPaysTheHeavyPayeeDirectly() public {
        _buyCoin(trader, 3 ether);
        assertTrue(_tryFlush(1_000_000));
        assertGt(heavy.got(), 0, "paid within the 100k cap");
        assertEq(feeRouter.owed(address(heavy)), 0);
    }

    /// the flusher picks the gas limit. starving the payee call burns the 63/64 it was given, which leaves too little
    /// for the engine call, so the flush reverts as a whole: there is no gas limit at which the flush passes and the payee
    /// is credited instead of paid
    function test_OK_noGasLimitDivertsAPayeeIntoOwedWhileTheFlushPasses() public {
        _buyCoin(trader, 3 ether);
        uint256 snap = vm.snapshotState();
        uint256 passes;
        for (uint256 g = 100_000; g <= 400_000; g += 2_500) {
            if (_tryFlush(g)) {
                ++passes;
                assertEq(feeRouter.owed(address(heavy)), 0, "a passing flush paid the payee");
                assertGt(heavy.got(), 0);
            } else {
                assertEq(heavy.got(), 0, "a reverted flush paid nothing");
            }
            vm.revertToState(snap);
        }
        assertGt(passes, 0);
    }
}

/// calls a Core door and flushes the router once from its own `receive`, i.e. from inside the payout the door makes last
contract FlushOnPayout {
    IFeeRouter public immutable ROUTER;
    bool public armed;

    constructor(address router_) {
        ROUTER = IFeeRouter(payable(router_));
    }

    function go(address target, bytes calldata data) external {
        armed = true;
        (bool ok, bytes memory why) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(why, 0x20), mload(why))
            }
        }
    }

    function approveAll(address nft, address op) external {
        (bool ok,) = nft.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        require(ok);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            ROUTER.flush();
        }
    }
}

/// F4. a stranger flushes the router from inside the payout of every door that pays the caller. the doors pay last, so
/// the booking lands on final state and the books stay exact
contract ReviewFlushInPayoutTest is FeeBase {
    FlushOnPayout internal atk;

    function setUp() public override {
        super.setUp();
        atk = new FlushOnPayout(address(feeRouter));
        _stock();
        autoFlush = false;
    }

    function _queue() internal returns (uint256 held) {
        _buyCoin(trader, 4 ether);
        held = address(feeRouter).balance;
        assertGt(held, 0.1 ether);
    }

    function _consistent() internal view {
        assertEq(
            address(core).balance, core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(), "every wei is booked"
        );
        assertEq(address(feeRouter).balance, 0, "the router was flushed");
    }

    function test_OK_flushInsideTheCompose() public {
        autoFlush = true;
        _composeOnce(); // fills the pile and composes once; the state before is kept
        vm.revertToState(preComposeSnap);
        autoFlush = false;
        vm.fee(composeBasefee);
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeCall(ICore.compose, ()));
        assertEq(address(atk).balance, a0, "the compose pays the caller nothing");
        assertEq(core.ethPot(), pot0 + _toPot(toEngine), "pot = old + the booked fees");
        _consistent();
    }

    function test_OK_flushInsideTheBuybackTip() public {
        _fillEthBuyback();
        vm.roll(block.number + 30);
        _queue();
        uint256 bb0 = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        atk.go(address(core), abi.encodeCall(ICore.buyback, ()));
        assertLt(core.ethToBuyback(), bb0, "the slice left the buyback pot");
        assertGt(core.ethPot(), pot0, "the flushed fees were booked on top");
        _consistent();
    }

    function test_OK_flushInsideTheSellForEthPayout() public {
        autoFlush = true;
        _fundPot(3 ether);
        autoFlush = false;
        uint256[] memory ids = _credits(address(atk), 1);
        atk.approveAll(address(CREDITS), address(core));
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeWithSignature("sellForEth(uint256[])", ids));
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 price = address(atk).balance - a0;
        assertGt(price, 0);
        assertEq(core.ethPot(), pot0 - price + _toPot(toEngine), "pot = old - price + the booked fees");
        _consistent();
    }
}

/// pushes eth with the 2,300 gas stipend only (call with zero gas and a value), like the v2 hook does
contract StipendPusher {
    function push(address to) external payable returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(0, to, callvalue(), 0, 0, 0, 0)
        }
    }
}

/// sends its balance to `to` by selfdestruct, which no `receive` can refuse
contract Forcer {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

/// F6. the stipend push, forced eth, who can launch, who the Core books
contract ReviewFeePathTest is FeeBase {
    function test_OK_stipendPushReachesTheRouterTheCoreAndEveryStackSender() public {
        StipendPusher p = new StipendPusher();
        assertTrue(p.push{value: 1}(address(feeRouter)), "router receive fits the stipend");
        assertTrue(p.push{value: 1}(address(core)), "the Core receive fits the stipend for a non source sender");
        assertEq(core.ethPot(), 0, "and books nothing");
        assertEq(address(feeRouter).balance, 1);
    }

    function test_OK_forcedEthInTheRouterAndTheCoreIsBookedExactlyOnce() public {
        _skipToSplitStart();
        Forcer a = new Forcer{value: 2 ether}();
        a.boom(payable(address(feeRouter)));
        Forcer b = new Forcer{value: 1 ether}();
        b.boom(payable(address(core)));
        uint256 held = address(feeRouter).balance;
        assertGe(held, 2 ether);
        assertLe(held, 2 ether + 10, "2 eth plus launch dust");
        (, uint256 toEngine) = _routerSplit(held);
        _flush(); // the first flush at the split start: everything to the engine
        uint256 toPot = _toPot(toEngine);
        assertEq(core.ethPot(), toPot, "the forced router eth was booked as fees");
        assertEq(core.ethRedeemBurn(), _toRedeemBurn(toEngine), "and the redeem burn share to its reserve");
        assertEq(address(core).balance, toEngine + 1 ether, "the forced Core eth is not booked yet");
        core.skim();
        assertEq(core.ethPot(), toPot + 1 ether);
        core.skim();
        assertEq(core.ethPot(), toPot + 1 ether, "a second skim books nothing");
        _solvent();
    }

    function test_OK_onlyTheFactoryOwnerCanLaunchAndTheFactoryIsDeprecated() public {
        assertTrue(FACTORY.deprecated());
        address stranger = _user("stranger");
        vm.deal(stranger, 1 ether);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(owner, creator, "S", "S", keccak256("s"));
        uint256 fee = FACTORY.deployFee();
        vm.prank(stranger);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, 2000);
        vm.prank(stranger);
        vm.expectRevert();
        FACTORY.deployToken{value: fee}(cfg);
    }
}
