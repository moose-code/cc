// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ITreasury} from "./Phase2Treasury.t.sol";

/// the InterfaceAuctionWithdrawals surface this test drives
interface IAuctionToken {
    function renderer() external view returns (address);
    function ready() external view returns (bool);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
    function retireLaunchSupply() external;
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function fundingPhase() external view returns (uint8);
    function transfersOpenBlock() external view returns (uint64);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address, string calldata) external returns (uint8);
    function approve(address, uint256) external;
}

/// a contract with code, standing in for the upstream launcher and strategy the token's constructor checks for code
contract CodeStub {}

/// the permanent lock the token's constructor asks for its token
contract LockStub {
    address public token;

    constructor(address token_) {
        token = token_;
    }
}

/// the phase 2 treasury against the real InterfaceAuctionWithdrawals creation bytecode (solc 0.8.28, the upstream
/// profile) on the pinned fork with the real Statements and the real engine. the artifact comes from
/// script/tools/upstream-auction-balance.sh, which pins the upstream commit and the code hashes. the auction, funding
/// phases and the open block are not driven here: this file proves the pre opening path, a conversion that releases the
/// token's own reserve to the treasury while ordinary transfers stay locked, and that the lock holds the funds in.
/// this is a deploy-mechanics test of a fresh system, not the live Core: it builds a fresh engine and treasury, so it
/// never reads or mutates the live Core.
contract Phase2UpstreamBalanceTest is Fixture {
    IAuctionToken private token;
    ITreasury private t;
    address private funderWallet;
    uint8 private nextFormat;

    function setUp() public override {
        if (!vm.exists("out/upstream-auction-balance.json")) {
            require(!vm.envOr("REQUIRE_UPSTREAM_BALANCE", false), "run script/tools/upstream-auction-balance.sh first");
            vm.skip(true);
            return;
        }
        string memory artifact = vm.readFile("out/upstream-auction-balance.json");
        bytes memory creation = vm.parseJsonBytes(artifact, ".bytecode.object");
        assertEq(sha256(creation), 0xf706ace186e444c8bf927d4c6661ce70064757aa6bab615a3abb85d5b5862248);
        super.setUp();
        funderWallet = _user("upstreamFunder");
        nextFormat = uint8(IUpstreamStatements(address(STATEMENTS)).formatCount());
        address launcher = address(new CodeStub());
        address strategy = address(new CodeStub());
        // the lock must name the token, which does not exist yet: predict the token's address one nonce ahead
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address lock = address(new LockStub(predicted));
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(
                address(STATEMENTS), nextFormat, funderWallet, launcher, strategy, lock, uint64(block.number + 100_000)
            )
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        require(deployed == predicted, "upstream deployment failed or landed elsewhere");
        token = IAuctionToken(deployed);
        address policy = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = ITreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), deployed, policy, address(0))
            )
        );
        _register();
        _setBalanceModule(address(t));
        vm.prank(owner);
        t.setSwitches(true, false, false);
    }

    function _register() private {
        IUpstreamStatements source = IUpstreamStatements(address(STATEMENTS));
        address renderer = token.renderer();
        address statementsOwner = source.owner();
        vm.prank(statementsOwner);
        assertEq(source.addFormat(renderer, "Balance"), nextFormat);
        assertTrue(token.ready());
    }

    /// the funder surrenders a page for its balance and retires the launch supply, as upstream requires before any other
    /// holder can surrender
    function _retire() private {
        uint256[] memory ids = _credits(funderWallet, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.startPrank(funderWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 sid = STATEMENTS.compose(page, 0);
        IUpstreamStatements(address(STATEMENTS)).approve(address(token), sid);
        token.withdraw(sid, token.quote(sid));
        token.retireLaunchSupply();
        vm.stopPrank();
        assertEq(token.totalRetired(), token.launchRetirement());
    }

    function _eligible() private returns (uint256 sid) {
        sid = _composeOnce().sid;
        _makeEligible(sid);
    }

    // promise: SPEC phase 2 with the real auction token, a conversion before retirement is refused upstream and the treasury reports it not ready
    function test_conversionWaitsForRetirement() public {
        assertFalse(t.conversionReady(), "retirement not finalized");
        uint256 sid = _eligible();
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("LaunchSupplyNotFinalized()")));
        core.redeemStatement(sid);
        assertTrue(_isHeld(sid));
    }

    // promise: SPEC phase 2 with the real auction token, a conversion releases the token's own reserve to the treasury while ordinary transfers are locked; the Core's receipt check passes, the earmark is kept, nothing is available and nothing can leave
    function test_realTokenReleasesToTheTreasuryBeforeTransfersOpen() public {
        _retire();
        assertTrue(t.conversionReady());
        assertFalse(t.transfersReady(), "funding phase 0, no open block");
        assertEq(token.fundingPhase(), 0);
        assertEq(token.transfersOpenBlock(), 0);
        uint256 sid = _eligible();
        uint256 rating = core.ratingOf(sid);
        uint256 supplyBefore = token.totalSupply();
        vm.expectEmit(address(core));
        emit ICore.StatementRedeemed(sid, rating * 1e14);
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(t.custody(), rating * 1e14, "the token released its reserve to the treasury");
        assertEq(token.totalSupply(), supplyBefore, "a withdrawal moves the reserve, it does not mint");
        assertEq(t.claimReserve(), rating * 1e14 * 1_000 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), address(token));
        assertEq(t.available(), 0, "no working payment while transfers are locked");
        // the lock holds the funds in: the token refuses the owner's withdrawal (AuctionTransfersLocked upstream,
        // surfaced as the safe transfer's TransferFailed) and a burner cannot redeem
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("TransferFailed()")));
        t.withdrawWorking(owner, 1);
        vm.prank(owner);
        t.setSwitches(true, true, true);
        assertEq(t.available(), 0);
        uint64 epoch = t.configEpoch();
        vm.expectRevert(ITreasury.RedemptionOff.selector);
        t.redeemCC(1e18, address(this), 0, block.timestamp, epoch);
        (,,,, bool exec) = t.quoteRedemption(1e18);
        assertFalse(exec);
        assertTrue(t.solvent());
    }
}
