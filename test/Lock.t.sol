// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Lock} from "../script/Lock.s.sol";
import {IArtCoinsHookV2} from "../src/interfaces/ArtCoinsV2.sol";

/// @dev the script with its environment replaced by fields, so parallel tests never share an environment variable
contract LockProbe is Lock {
    bytes internal config_;
    address internal core_;
    address internal signer_;
    bool internal send_;
    bool internal coinChanged_;

    function setCoinChanged(bool on) external {
        coinChanged_ = on;
    }

    function _coinChanged() internal view override returns (bool) {
        return coinChanged_;
    }

    function configure(LaunchConfig memory c, address core, address signer, bool send) external {
        config_ = abi.encode(c);
        core_ = core;
        signer_ = signer;
        send_ = send;
    }

    function _config() internal view override returns (LaunchConfig memory) {
        return abi.decode(config_, (LaunchConfig));
    }

    function _core() internal view override returns (address) {
        return core_;
    }

    function _send() internal view override returns (bool) {
        return send_;
    }

    function _startBroadcast() internal override returns (address) {
        vm.startBroadcast(signer_);
        return signer_;
    }
}

/// the owner command that freezes the fee recipients (docs/RUNBOOK.md section 4) and the postflight rows around it
contract LockTest is Fixture {
    LockProbe internal probe;
    bool internal coinChangedFlag;

    function setUp() public override {
        super.setUp();
        probe = new LockProbe();
    }

    function _coinChanged() internal view override returns (bool) {
        return coinChangedFlag;
    }

    /// a dry run prints the calldata and sends nothing
    // promise: a dry run prints the calldata and sends nothing
    function test_dryRunSendsNothing() public {
        probe.configure(lc, address(core), owner, false);
        probe.run();
        assertFalse(coin.locked());
    }

    /// the coin admin sends it and the recipients are frozen
    // promise: the coin admin sends it and the recipients are frozen
    function test_theCoinAdminLocksTheRecipients() public {
        probe.configure(lc, address(core), owner, true);
        probe.run();
        assertTrue(coin.locked());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("CoinLocked()"));
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(address(core)));
    }

    /// a signer that is not the coin admin is refused and nothing is locked
    // promise: a signer that is not the coin admin is refused and nothing is locked
    function test_aSignerThatIsNotTheCoinAdminIsRefused() public {
        probe.configure(lc, address(core), creator, true);
        vm.expectRevert(abi.encodeWithSelector(Lock.NotCoinAdmin.selector, owner, creator));
        probe.run();
        assertFalse(coin.locked());
    }

    /// COIN_CHANGED=1 relaxes the postflight row, and the lock still refuses a pool that pays another address
    // promise: COIN_CHANGED=1 relaxes the postflight row, and the lock still refuses a pool that pays another address
    function test_aRepointedBountyRecipientRefusesTheLockWhateverCoinChangedSays() public {
        address elsewhere = makeAddr("elsewhere");
        vm.prank(owner);
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(elsewhere));
        probe.setCoinChanged(true);
        probe.configure(lc, address(core), owner, true);
        vm.expectRevert(abi.encodeWithSelector(Lock.BountyRecipientNotCore.selector, elsewhere, address(core)));
        probe.run();
        assertFalse(coin.locked());
    }

    /// a second run finds the recipients locked and sends nothing
    // promise: a second run finds the recipients locked and sends nothing
    function test_aSecondRunIsANoOp() public {
        probe.configure(lc, address(core), owner, true);
        probe.run();
        probe.run();
        assertTrue(coin.locked());
    }

    /// the run stops before it sends when the postflight has a failed row
    // promise: the run stops before it sends when the postflight has a failed row
    function test_aFailedPostflightStopsTheLock() public {
        LaunchConfig memory c = lc;
        c.owner = creator;
        probe.configure(c, address(core), owner, true);
        vm.expectRevert();
        probe.run();
        assertFalse(coin.locked());
    }

    /// postflight prints the state of the recipients as an info row and passes before and after the lock
    // promise: postflight prints the state of the recipients as an info row and passes before and after the lock
    function test_thePostflightPassesBeforeAndAfterTheLock() public {
        postflightAs(lc, address(core), owner);
        (string memory failed, uint256 n) = _failed();
        assertEq(n, 0, failed);

        vm.prank(owner);
        coin.lock();
        postflightAs(lc, address(core), owner);
        (failed, n) = _failed();
        assertEq(n, 0, failed);
    }

    /// the bounty recipient row fails when the coin admin repointed it, and is a warning with COIN_CHANGED=1
    // promise: the bounty recipient row fails when the coin admin repointed it, and is a warning with COIN_CHANGED=1
    function test_theBountyRecipientRowIsSoft() public {
        vm.prank(owner);
        IArtCoinsHookV2(lc.stack.hook).setBountyRecipient(poolId, payable(makeAddr("elsewhere")));
        postflightAs(lc, address(core), owner);
        (string memory failed,) = _failed();
        assertTrue(vm.contains(failed, "hook: bounty recipient is the Core"), "fails without the flag");

        coinChangedFlag = true;
        postflightAs(lc, address(core), owner);
        (failed,) = _failed();
        assertFalse(vm.contains(failed, "hook: bounty recipient is the Core"), "a warning with the flag");
    }
}
