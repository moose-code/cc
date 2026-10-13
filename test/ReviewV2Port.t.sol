// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {FeeBase} from "./Fees.t.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ComposeCall} from "./utils/ComposeCall.sol";

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
        _skipToPayeeStart();
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
        _skipToPayeeStart();
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

/// F3. anyone chooses the gas of `claimPayee`: a claim with too little gas for the payee reverts whole and leaves the
/// share owed, a claim with enough pays all of it
contract ReviewClaimGasTest is FeeBase {
    HeavyPayee internal heavy;

    function setUp() public override {
        super.setUp();
        heavy = new HeavyPayee();
        _stock();
        vm.prank(owner);
        core.setPayee(address(heavy));
        _buyCoin(trader, 3 ether);
        assertGt(core.payeeOwed(), 0);
    }

    function _tryClaim(uint256 g) internal returns (bool ok) {
        (ok,) = address(core).call{gas: g}(abi.encodeCall(ICore.claimPayee, ()));
    }

    function test_OK_aNormalClaimPaysTheHeavyPayee() public {
        uint256 owed = core.payeeOwed();
        assertTrue(_tryClaim(1_000_000));
        assertEq(heavy.got(), owed, "paid in full");
        assertEq(core.payeeOwed(), 0);
    }

    /// the claimer picks the gas limit. a claim that starves the payee reverts as a whole and moves nothing: there is no
    /// gas limit at which the claim passes and the payee gets less than it is owed
    function test_OK_noGasLimitShortPaysThePayee() public {
        uint256 owed = core.payeeOwed();
        uint256 snap = vm.snapshotState();
        uint256 passes;
        for (uint256 g = 50_000; g <= 400_000; g += 2_500) {
            if (_tryClaim(g)) {
                ++passes;
                assertEq(heavy.got(), owed, "a passing claim paid it all");
                assertEq(core.payeeOwed(), 0);
            } else {
                assertEq(heavy.got(), 0, "a reverted claim paid nothing");
                assertEq(core.payeeOwed(), owed, "and left the share owed");
            }
            vm.revertToState(snap);
        }
        assertGt(passes, 0);
    }
}

/// calls a Core door and tries to book from its own `receive`, i.e. from inside the payout the door makes last
contract BookOnPayout {
    address public immutable CORE;
    bool public armed;
    uint256 public tried;
    uint256 public blocked;

    constructor(address core_) {
        CORE = core_;
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
            ++tried;
            (bool ok,) = CORE.call(abi.encodeCall(ICore.book, ()));
            if (!ok) ++blocked;
        }
    }
}

/// F4. a stranger books from inside the payout of every door that pays the caller. the doors pay last under the
/// reentrancy guard, so the nested book is refused, the door books the fees first and the books stay exact
contract ReviewBookInPayoutTest is FeeBase {
    BookOnPayout internal atk;

    function setUp() public override {
        super.setUp();
        atk = new BookOnPayout(address(core));
        _stock();
        autoBook = false;
    }

    function _queue() internal returns (uint256 held) {
        _buyCoin(trader, 4 ether);
        held = address(core).balance - _tracked();
        assertGt(held, 0.1 ether);
    }

    function _consistent() internal view {
        assertEq(address(core).balance, _tracked(), "every wei is booked");
    }

    function test_OK_bookInsideTheCompose() public {
        autoBook = true;
        _composeOnce(); // fills the pile and composes once; the state before is kept
        vm.revertToState(preComposeSnap);
        autoBook = false;
        vm.fee(composeBasefee);
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _payeeSplit(address(core).balance - _tracked());
        uint256 a0 = address(atk).balance;
        atk.go(address(core), ComposeCall.noArgs());
        assertEq(address(atk).balance, a0, "the compose pays the caller nothing");
        assertEq(atk.tried(), 0, "and has no payout to enter from");
        assertEq(core.ethPot(), pot0 + _toPot(toEngine), "pot = old + the booked fees");
        _consistent();
    }

    function test_OK_bookInsideTheBuybackTip() public {
        _fillEthBuyback();
        vm.roll(block.number + 30);
        _queue();
        uint256 bb0 = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        atk.go(address(core), abi.encodeCall(ICore.buyback, ()));
        _book(); // the skim of the swap reached the core inside the call
        assertLt(core.ethToBuyback(), bb0, "the slice left the buyback pot");
        assertGt(core.ethPot(), pot0, "the fees were booked on top");
        assertEq(atk.tried(), atk.blocked(), "the nested book was refused");
        _consistent();
    }

    function test_OK_bookInsideTheSellForEthPayout() public {
        autoBook = true;
        _fundPot(3 ether);
        autoBook = false;
        uint256[] memory ids = _credits(address(atk), 1);
        atk.approveAll(address(CREDITS), address(core));
        _queue();
        uint256 pot0 = core.ethPot();
        (, uint256 toEngine) = _payeeSplit(address(core).balance - _tracked());
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeWithSignature("sellForEth(uint256[])", ids));
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 price = address(atk).balance - a0;
        assertGt(price, 0);
        assertEq(atk.tried(), 1);
        assertEq(atk.blocked(), 1, "the nested book was refused");
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

/// F6. the stipend push, forced eth, who can launch, who the Core takes eth from
contract ReviewFeePathTest is FeeBase {
    function test_OK_stipendPushFromTheHookAndTheEscrowReachesTheCore() public {
        address[2] memory from = [lc.stack.hook, lc.stack.escrow];
        for (uint256 i; i < 2; ++i) {
            vm.deal(from[i], 1);
            vm.prank(from[i]);
            (bool ok,) = address(core).call{value: 1, gas: 2_300}("");
            assertTrue(ok, "the Core receive fits the stipend");
        }
        assertEq(core.ethPot(), 0, "and books nothing");
        assertEq(address(core).balance, 2);
        StipendPusher p = new StipendPusher();
        assertFalse(p.push{value: 1}(address(core)), "any other sender is refused");
    }

    function test_OK_forcedEthInTheCoreIsBookedExactlyOnce() public {
        _skipToPayeeStart();
        Forcer b = new Forcer{value: 1 ether}();
        b.boom(payable(address(core)));
        uint256 held = address(core).balance;
        assertGe(held, 1 ether);
        assertLe(held, 1 ether + 10, "1 eth plus launch dust");
        assertEq(core.ethPot(), 0, "the forced eth is not booked yet");
        _book(); // the first book after the window shares nothing
        assertEq(core.ethPot(), _toPot(held), "the forced eth was booked as fees");
        assertEq(core.ethRedeemBurn(), _toRedeemBurn(held), "and the redeem burn share to its reserve");
        assertEq(core.payeeOwed(), 0);
        uint256 pot = core.ethPot();
        _book();
        assertEq(core.ethPot(), pot, "a second book counts nothing");
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
