// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {SystemResumer} from "../script/SystemResumer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice `script/SystemResumer.sol` on the pinned fork with the live v2 stack. the deployer is the factory owner and
/// the config owner. the library goes through the deterministic deployer, so the tests send it there by hand
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
        // the test runner predeploys the linked CoreLib at libraryAddress() and keeps it across fork selection. mainnet has
        // no code there, so the account is reset to the state the script sees
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
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
    }

    function resume(address who, LaunchConfig memory c, address core) external {
        // as in the script: the checks run outside the broadcast
        resumeChecks(who, c, core);
        vm.startPrank(who);
        resumeSend(who, c);
        vm.stopPrank();
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
        ICore(payable(core)).setController(controllerAddress(core, base));
        ICore(payable(core)).addAdapter(seaportAdapterAddress(core, base.seaportRecipients));
        ICore(payable(core)).addAdapter(strategyAdapterAddress());
        vm.stopPrank();
        this.resume(deployer, base, core);
        assertEq(stepGas[0] + stepGas[1] + stepGas[2] + stepGas[3] + stepGas[4] + stepGas[5] + stepGas[6], 0);
        assertGt(stepGas[7], 0, "the launch is sent");
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
