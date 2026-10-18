// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {SystemResumer} from "../script/SystemResumer.sol";
import {ICoinRenderer} from "../src/interfaces/ICoinRenderer.sol";
import {Deployed} from "../script/SystemDeployer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice `script/SystemResumer.sol` on the pinned fork with the live v2 stack. the deployer is the factory owner and
/// the config owner. both libraries go through the deterministic deployer, so the tests send them there by hand
contract ResumeTest is Test, SystemResumer, ProdDeployer {
    V2Stack.Stack internal v2;
    IArtCoinsFactoryV2 internal FACTORY;
    address internal deployer;
    address internal creator;
    LaunchConfig internal base;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        else vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        // the test runner predeploys linked libraries across fork selection; reset their accounts to the mainnet state
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
        vm.etch(opsLibraryAddress(), "");
        vm.resetNonce(opsLibraryAddress());
        v2 = V2Stack.attach();
        deployer = v2.owner;
        creator = makeAddr("resume.creator");
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        vm.deal(deployer, 5 ether);
        base = defaultConfig();
        base.owner = deployer;
        base.creator = creator;
        base.artist = creator;
        base.payee = makeAddr("resume.payee");
        base.name = "Resume Coin";
        base.symbol = "RSM";
        base.image = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        base.description = "Resume Coin test description";
        base.salt = keccak256("resume");
        base.stack.hook = v2.hook;
        base.stack.factory = v2.factory;
        base.stack.locker = v2.locker;
        base.stack.escrow = v2.escrow;
        base.mevModule = v2.mev;
    }

    function _sendLibrary() internal {
        vm.prank(deployer);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(ok, "the library create2 failed");
        vm.prank(deployer);
        (ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreOpsLib.sol:CoreOpsLib")));
        assertTrue(ok, "the ops library create2 failed");
    }

    function resume(address who, LaunchConfig memory c, address core) external {
        // as in the script: the checks run outside the broadcast, the postflight after it
        resumeChecks(who, c, core);
        vm.startPrank(who);
        Deployed memory d = resumeSend(who, c);
        vm.stopPrank();
        resumePostflight(who, c, d);
    }

    function _assertLaunched(address core) internal {
        address coin = ICore(payable(core)).COIN();
        assertGt(coin.code.length, 0, "launched");
        assertEq(IArtCoinsTokenV2(coin).admin(), deployer);
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    // a deploy that stopped after the Core is finished: the controller, the adapters, the owner calls, the launch
    // promise: a deploy that stopped after the Core is finished: the controller, the adapters, the owner calls, the launch
    function test_resumeFinishesADeployStoppedAfterTheCore() public {
        _sendLibrary();
        vm.prank(deployer);
        address core = _newCore(base, deployer);
        assertEq(core, coreAddress(base, deployer));
        this.resume(deployer, base, core);
        _assertLaunched(core);
    }

    // a deploy that stopped before the launch sends only the launch
    // promise: a deploy that stopped before the launch sends only the launch
    function test_resumeSendsOnlyTheLaunchWhenTheRestIsOnChain() public {
        _sendLibrary();
        vm.startPrank(deployer);
        address core = _newCore(base, deployer);
        _newController(core, base);
        _newSeaportAdapter(core, base.seaportRecipients);
        _newStrategyAdapter();
        ICoinRenderer(_newRenderer(base)).setCore(ICore(payable(core)));
        ICore(payable(core)).setController(controllerAddress(core, base));
        ICore(payable(core)).addAdapter(seaportAdapterAddress(core, base.seaportRecipients));
        ICore(payable(core)).addAdapter(strategyAdapterAddress());
        vm.stopPrank();
        this.resume(deployer, base, core);
        for (uint256 i; i < 9; ++i) {
            assertEq(stepGas[i], 0, "a step on chain is skipped");
        }
        assertGt(stepGas[9], 0, "the launch is sent");
        _assertLaunched(core);
    }

    // a deploy that stopped after the renderer was created sends setCore, then the rest
    // promise: a deploy that stopped after the renderer was created sends setCore, then the rest
    function test_resumeBindsTheCoreOfACreatedRenderer() public {
        _sendLibrary();
        vm.startPrank(deployer);
        address core = _newCore(base, deployer);
        address r = _newRenderer(base);
        vm.stopPrank();
        assertEq(address(ICoinRenderer(r).core()), address(0), "unbound");
        this.resume(deployer, base, core);
        assertEq(stepGas[4], 0, "the renderer is on chain");
        assertGt(stepGas[5], 0, "setCore is sent");
        assertEq(address(ICoinRenderer(r).core()), core);
        _assertLaunched(core);
    }

    // a resume needs a Core of this config and deployer that exists and has no coin yet
    // promise: a resume needs a Core of this config and deployer that exists and has no coin yet
    function test_resumeRefusesWhatItCannotFinish() public {
        _sendLibrary();
        vm.expectRevert(abi.encodeWithSelector(NotStarted.selector));
        this.resume(deployer, base, coreAddress(base, deployer));

        vm.prank(deployer);
        address core = _newCore(base, deployer);
        LaunchConfig memory other = base;
        other.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, coreAddress(other, deployer), core));
        this.resume(deployer, other, core);

        this.resume(deployer, base, core);
        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector));
        this.resume(deployer, base, core);
    }

    function oneShotExt(address who, LaunchConfig memory c) external returns (Deployed memory d) {
        vm.startPrank(who);
        d = deploySystem(who, c);
        vm.stopPrank();
    }

    function deferExt(address who, LaunchConfig memory c) external returns (Deployed memory d) {
        vm.startPrank(who);
        d = deploySystemUntilLaunch(who, c);
        vm.stopPrank();
    }

    /// @dev what Resume.s.sol does under LAUNCH_ONLY=1
    function launchOnlyExt(address who, LaunchConfig memory c, address core) external returns (Deployed memory d) {
        return launchOnlyWith(who, c, core, FACTORY.tokenDeployer());
    }

    function launchOnlyWith(address who, LaunchConfig memory c, address core, address recordedDeployer)
        public
        returns (Deployed memory d)
    {
        this.guardsExt(who, c, core, recordedDeployer);
        vm.startPrank(who);
        d = resumeSend(who, c);
        vm.stopPrank();
    }

    function onlyChecksExt(address who, LaunchConfig memory c, address core, address recordedDeployer) external view {
        launchOnlyChecks(who, c, core, recordedDeployer);
    }

    function guardsExt(address who, LaunchConfig memory c, address core, address recordedDeployer) external {
        resumeChecks(who, c, core);
        launchOnlyChecks(who, c, core, recordedDeployer);
    }

    /// @dev addresses, runtime code hashes and the first storage words of the system contracts and the coin
    function _fingerprint(Deployed memory d) internal view returns (bytes32 h) {
        h = keccak256(abi.encode(d.core, d.coin, d.controller, d.seaportAdapter, d.strategyAdapter, d.renderer, d.poolId));
        address[8] memory all = [
            d.core, d.coin, d.controller, d.seaportAdapter, d.strategyAdapter, d.renderer,
            libraryAddress(), opsLibraryAddress()
        ];
        for (uint256 a; a < all.length; ++a) {
            h = keccak256(abi.encode(h, all[a].codehash));
            for (uint256 i; i < 48; ++i) {
                h = keccak256(abi.encode(h, vm.load(all[a], bytes32(i))));
            }
        }
    }

    function _clean() internal view {
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    // a deferred deploy followed by the launch step leaves the state of a one shot deploy
    // promise: a deferred deploy followed by the launch step leaves the state of a one shot deploy
    function test_deferredDeployThenLaunchEqualsOneShot() public {
        _sendLibrary();
        uint256 snap = vm.snapshotState();
        Deployed memory one = this.oneShotExt(deployer, base);
        bytes32 want = _fingerprint(one);
        postflightAs(base, one.core, deployer);
        _clean();
        vm.revertToState(snap);

        Deployed memory d = this.deferExt(deployer, base);
        assertEq(d.core, one.core, "same core");
        assertEq(d.coin, one.coin, "same predicted coin");
        assertEq(d.coin.code.length, 0, "the coin is not launched");
        for (uint256 i; i < 9; ++i) {
            assertGt(stepGas[i], 0, "every step before the launch is sent");
        }
        assertEq(stepGas[9], 0, "the launch is not sent");
        postflightDeferred(base, d.core, deployer);
        _clean();
        // record fields after step 1: the coin is the Core's COIN, not live, no launch block yet
        assertEq(d.coin, ICore(payable(d.core)).COIN(), "record coin");
        assertEq(d.coin.code.length, 0, "record coinLive false after step 1");

        delete stepGas;
        Deployed memory e = this.launchOnlyExt(deployer, base, d.core);
        for (uint256 i; i < 9; ++i) {
            assertEq(stepGas[i], 0, "the launch step sends only the launch");
        }
        assertGt(stepGas[9], 0, "the launch is sent");
        assertEq(_fingerprint(e), want, "state equals the one shot deploy");
        // record fields after step 2: coinLive true, launchBlock is the launch block
        assertTrue(e.coin.code.length != 0, "record coinLive after step 2");
        assertEq(e.coin, d.coin, "record coin is unchanged by the launch");
        assertGt(block.number, 0, "launchBlock present");
        postflightAs(base, e.core, deployer);
        _clean();
        // the deferred rows no longer hold once the coin exists
        postflightDeferred(base, e.core, deployer);
        (string memory list,) = _failed();
        assertTrue(bytes(list).length != 0, "the deferred postflight fails after the launch");
    }

    // the launch step refuses a missing step before the launch, another config, and a coin that has code
    // promise: the launch step refuses a missing step, another config and a launched coin
    function test_launchStepRefusals() public {
        _sendLibrary();
        vm.prank(deployer);
        address core = _newCore(base, deployer);
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "controller"));
        this.launchOnlyExt(deployer, base, core);

        Deployed memory d = this.deferExt(deployer, base);
        LaunchConfig memory other = base;
        other.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, coreAddress(other, deployer), core));
        this.launchOnlyExt(deployer, other, d.core);

        this.launchOnlyExt(deployer, base, d.core);
        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector));
        this.launchOnlyExt(deployer, base, d.core);
    }

    // half wired deploys: the launch step names the first missing owner call
    // promise: the launch step refuses a deploy with an owner call missing
    function test_launchStepRefusesHalfWiredDeploys() public {
        _sendLibrary();
        vm.startPrank(deployer);
        address core = _newCore(base, deployer);
        _newController(core, base);
        _newSeaportAdapter(core, base.seaportRecipients);
        _newStrategyAdapter();
        ICoinRenderer(_newRenderer(base)).setCore(ICore(payable(core)));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "setController"));
        this.launchOnlyExt(deployer, base, core);

        vm.startPrank(deployer);
        ICore(payable(core)).setController(controllerAddress(core, base));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "addAdapter seaport"));
        this.launchOnlyExt(deployer, base, core);

        vm.startPrank(deployer);
        ICore(payable(core)).addAdapter(seaportAdapterAddress(core, base.seaportRecipients));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(NotDeferred.selector, "addAdapter strategy"));
        this.launchOnlyExt(deployer, base, core);
    }

    // the factory settings of the deferred run: deprecated, token deployer and prediction
    // promise: the launch step refuses a factory that changed after the deferred run
    function test_launchStepRefusesAChangedFactory() public {
        _sendLibrary();
        Deployed memory d = this.deferExt(deployer, base);
        address recorded = FACTORY.tokenDeployer();
        vm.expectRevert(abi.encodeWithSelector(FactoryChanged.selector, "tokenDeployer"));
        this.onlyChecksExt(deployer, base, d.core, makeAddr("other deployer"));
        this.onlyChecksExt(deployer, base, d.core, recorded);

        vm.prank(deployer);
        FACTORY.setDeprecated(false);
        vm.expectRevert(abi.encodeWithSelector(FactoryChanged.selector, "deprecated"));
        this.onlyChecksExt(deployer, base, d.core, recorded);
        // the preflight rows of the launch step refuse the same factory too
        vm.expectRevert();
        this.launchOnlyWith(deployer, base, d.core, recorded);
    }

    function requireDeployerExt(address want, address got) external pure {
        _requireDeployer(want, got);
    }

    function deployExt(address who, LaunchConfig memory c) external {
        deploySystem(who, c);
    }

    // the signer is the deployer the operator named, the factory owner and the config owner
    // promise: the signer is the deployer the operator named, the factory owner and the config owner
    function test_signerGuards() public {
        this.requireDeployerExt(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, deployer, creator));
        this.requireDeployerExt(deployer, creator);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);

        address stranger = makeAddr("stranger");
        LaunchConfig memory c = base;
        c.owner = stranger;
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, stranger));
        this.deployExt(stranger, c);
        c = base;
        c.owner = creator;
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, deployer));
        this.deployExt(deployer, c);
    }
}
