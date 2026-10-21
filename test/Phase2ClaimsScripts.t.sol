// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Phase2BalanceTokenStandin} from "./standins/Phase2BalanceTokenStandin.sol";
import {Phase2Claims} from "../script/Phase2Claims.s.sol";
import {Report} from "../script/Report.sol";

/// @dev the script with its environment replaced by arguments
contract Phase2ClaimsProbe is Phase2Claims {
    function go(Inputs memory i) external {
        execute(i, false);
    }
}

/// the post launch claim activation of decision 260 against the real Core on the pinned fork: phase 2 runs with
/// CC redemption off, then the claim reserve is funded and redemption turned on in separate reviewed steps
contract Phase2ClaimsScriptsTest is Fixture {
    Phase2BalanceTokenStandin internal token;
    IPhase2BalanceTreasury internal t;
    Phase2ClaimsProbe internal probe;

    function setUp() public override {
        super.setUp();
        token = new Phase2BalanceTokenStandin();
        address policy = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        t = IPhase2BalanceTreasury(
            vm.deployCode(
                "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                abi.encode(address(core), address(token), policy, address(0))
            )
        );
        _setBalanceModule(address(t));
        token.open();
        token.mint(address(t), 100 ether);
        token.mint(owner, 50 ether);
        // the launch state: conversions and working payments on, CC redemption off, no claims
        vm.prank(owner);
        t.setSwitches(true, true, false);
        probe = new Phase2ClaimsProbe();
        _buyCoin(_user("holder"), 1 ether);
    }

    function _inputs(string memory step, uint256 amount) internal view returns (Phase2Claims.Inputs memory) {
        return Phase2Claims.Inputs({treasury: address(t), step: step, amount: amount, allowEmpty: false});
    }

    // promise: decision 260 the launch runs with CC redemption off and the claim system is added afterwards: allocate moves working funds into the reserve, enable turns redemption on only once the reserve is funded, the treasury selected and transfers open, and a burn then quotes and executes; disable turns it off again
    function test_claimsAreAddedAfterLaunchInReviewedSteps() public {
        assertFalse(t.ccRedemptionEnabled());
        (,,,, bool exec) = t.quoteRedemption(1e18);
        assertFalse(exec, "nothing executes before enable");
        // enable with an empty reserve is refused
        Phase2Claims.Inputs memory i = _inputs("enable", 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector, "preview: claim reserve funded (ALLOW_EMPTY_CLAIMS=1 waives)"
            )
        );
        probe.go(i);
        // allocate 10 of the 100 working tokens
        probe.go(_inputs("allocate", 10 ether));
        assertEq(t.claimReserve(), 10 ether);
        assertEq(t.working(), 90 ether);
        assertFalse(t.ccRedemptionEnabled(), "a funding step leaves the switch alone");
        // fund 5 more from the owner's own balance
        probe.go(_inputs("fund", 5 ether));
        assertEq(t.claimReserve(), 15 ether);
        assertEq(token.balanceOf(owner), 45 ether);
        // enable
        probe.go(_inputs("enable", 0));
        assertTrue(t.ccRedemptionEnabled());
        (uint256 out,,,, bool live) = t.quoteRedemption(1e18);
        assertGt(out, 0);
        assertTrue(live);
        // disable
        probe.go(_inputs("disable", 0));
        assertFalse(t.ccRedemptionEnabled());
    }

    // promise: decision 260 the script refuses an allocation above the free working funds, a zero amount, an unknown step and a mismatched plan hash on a send, and its plan hash changes with the reserve it applies to
    function test_claimsScriptRefusals() public {
        uint256 free = t.freeWorking();
        Phase2Claims.Inputs memory i = _inputs("allocate", free + 1);
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: free working covers the amount"));
        probe.go(i);
        i = _inputs("allocate", 0);
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: amount given"));
        probe.go(i);
        i = _inputs("burn", 0);
        vm.expectRevert(
            abi.encodeWithSelector(Report.ChecksFailed.selector, "preview: step is allocate, fund, enable or disable")
        );
        probe.go(i);
        bytes32 before = probe.planHash(_inputs("allocate", 1 ether));
        probe.go(_inputs("allocate", 1 ether));
        assertTrue(probe.planHash(_inputs("allocate", 1 ether)) != before, "the hash follows the reserve");
        vm.setEnv("TREASURY", vm.toString(address(t)));
        vm.setEnv("STEP", "enable");
        vm.setEnv("SEND", "1");
        vm.setEnv("PHASE2_CLAIMS_PLAN_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert();
        probe.run();
        vm.setEnv("SEND", "0");
    }
}
