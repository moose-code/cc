// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {Prod} from "./utils/Prod.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {Deployed} from "../script/SystemDeployer.sol";
import {SystemResumer, Stage} from "../script/SystemResumer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

/// @notice `script/SystemResumer.sol` on the pinned fork with the live v2 stack: a deploy stopped after each of
/// the transactions (the library, the controller, the core, the launch) is finished by sending only the missing steps,
/// as the original deployer, who is
/// the factory owner and the config owner. the library goes through the deterministic deployer in a broadcast and takes
/// one deployer nonce, so the tests send it through that deployer too and bump the nonce by hand (a test prank sends no
/// transaction)
contract ResumeTest is Test, SystemResumer, ProdDeployer {
    bool internal scriptMode;
    /// @dev the operator flags as bools here, so parallel tests never share an environment variable
    bool internal changedFlag;
    bool internal ownerFlag;

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    function _ownerChanged() internal view override returns (bool) {
        return ownerFlag;
    }

    function _scriptContext() internal view override returns (bool) {
        return scriptMode;
    }

    V2Stack.Stack internal v2;
    IArtCoinsFactoryV2 internal FACTORY;
    /// @dev the deployer is the factory owner and the config owner
    address internal deployer;
    address internal owner;
    address internal creator;
    LaunchConfig internal base;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // forge test predeploys the linked CoreLib at libraryAddress() and keeps it across fork selection. mainnet has no
        // code there, so the account is reset to the state the script sees
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
        v2 = V2Stack.attach();
        deployer = v2.owner;
        owner = deployer;
        creator = makeAddr("resume.creator");
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        vm.startPrank(owner);
        FACTORY.setMinProtocolSkimShareBps(362);
        vm.stopPrank();
        vm.deal(deployer, 5 ether);
        base = defaultConfig();
        base.owner = owner;
        base.creator = creator;
        base.credit.royaltyRecipient = creator;
        base.payee = makeAddr("resume.payee");
        base.name = "Resume Coin";
        base.symbol = "RSM";
        // a launch ready config: the tracked mainnet.json leaves both strings empty for the owner to fill
        base.image = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
        base.description = "Resume Coin test description";
        base.salt = keccak256("resume");
        base.stack.hook = v2.hook;
        base.stack.factory = v2.factory;
        base.stack.locker = v2.locker;
        base.stack.escrow = v2.escrow;
        base.mevModule = v2.mev;
    }

    /// @dev the first `n` of the transactions, by hand, as the deployer: 1 library, 2 controller, 3 core, 4 launch
    /// @dev the lens is sent between the core and the launch, as `deploySystem` does. `skipLens` leaves it out of a
    /// deploy that went on to the launch, `lensEarly` sends it in a deploy that stopped right after it
    bool internal skipLens;
    bool internal lensEarly;
    /// @dev `skipAdapters` leaves the two adapters out of a deploy that went on to the launch
    bool internal skipAdapters;

    function _steps(uint256 n) internal returns (address core, address coin) {
        scriptMode = true;
        if (n >= 1) _sendLibrary();
        uint64 nonce = vm.getNonce(deployer);
        core = vm.computeCreateAddress(deployer, nonce + 1);
        vm.startPrank(deployer);
        address controller;
        if (n >= 2) controller = address(Prod.newController(core, base.sale, base.credit));
        if (n >= 3) {
            Prod.newCore(
                owner,
                buildConfig(base, owner, address(0)),
                deployer,
                controller,
                base.payee,
                base.stack,
                base.rateStart,
                base.settings,
                base.credit,
                launchAdapters(core, base)
            );
        }
        if ((n >= 4 && !skipLens) || (n >= 3 && lensEarly)) Prod.newLens(core, LENS_SALT, CREATE2_DEPLOYER);
        if (n >= 4 && !skipAdapters) {
            Prod.newSeaportAdapter(core, base.seaportRecipients, SEAPORT_ADAPTER_SALT, CREATE2_DEPLOYER);
            Prod.newStrategyAdapter(STRATEGY_ADAPTER_SALT, CREATE2_DEPLOYER);
        }
        if (n >= 4) coin = _launch(base, ICore(payable(core)).COIN(), core);
        vm.stopPrank();
        scriptMode = false;
    }

    /// @dev the first transaction of a broadcast: the library through the deterministic deployer, from the deployer
    function _sendLibrary() internal {
        assertTrue(_libraryTxPending(), "the library is not on chain yet");
        vm.prank(deployer);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(ok, "the library create2 failed");
        vm.setNonce(deployer, vm.getNonce(deployer) + 1);
        assertFalse(_libraryTxPending(), "the library is on chain now");
    }

    function stageOf(address core) external view returns (Stage) {
        return detectStage(base, core);
    }

    function resume(address who, LaunchConfig memory c, address core) external returns (Stage from) {
        // as in the script: the checks simulate the launch on a snapshot and run outside the broadcast
        from = resumeChecks(who, c, core);
        vm.startPrank(who);
        resumeSend(who, c, core, from);
        vm.stopPrank();
    }

    function _assertDone(address core, Stage expectFrom) internal {
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(expectFrom), "stage found");
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
        address coin = ICore(payable(core)).COIN();
        assertEq(IArtCoinsTokenV2(coin).admin(), owner, "the owner is the token admin");
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    /// a run that stopped right after the core: the lens is the next transaction, then the launch
    function test_resumeCreatesAMissingLensBeforeTheLaunch() public {
        (address core,) = _steps(3);
        address lensAt = lensAddress(core);
        assertTrue(lensAt != address(0) && lensAt.code.length == 0, "no lens yet");
        _assertDone(core, Stage.CoreOnly);
        assertGt(lensAt.code.length, 0, "the lens sits at the derived address");
    }

    /// a run that stopped after the lens and before the launch finds the lens and leaves it as it is
    function test_resumeKeepsTheLensItFinds() public {
        lensEarly = true;
        (address core,) = _steps(3);
        address lensAt = lensAddress(core);
        assertGt(lensAt.code.length, 0);
        bytes32 hash = lensAt.code.length == 0 ? bytes32(0) : keccak256(lensAt.code);
        _assertDone(core, Stage.CoreOnly);
        assertEq(keccak256(lensAt.code), hash, "the lens is the one that was there");
    }

    /// a system launched without a lens, with the deployer nonce moved on: the lens is created at the same address
    /// because the address depends on the Core only
    function test_resumeCreatesTheLensAfterTheLaunchAndTheNonceMovedOn() public {
        skipLens = true;
        (address core,) = _steps(4);
        address lensAt = lensAddress(core);
        assertEq(lensAt.code.length, 0);
        _assertDone(core, Stage.Done);
        assertGt(lensAt.code.length, 0);
    }

    /// a system launched without the adapters: the resume creates them at the addresses the Core already approved
    function test_resumeCreatesTheAdaptersAfterTheLaunch() public {
        skipAdapters = true;
        (address core,) = _steps(4);
        address seaportAt = seaportAdapterAddress(core, base.seaportRecipients);
        address strategyAt = strategyAdapterAddress();
        assertEq(seaportAt.code.length + strategyAt.code.length, 0);
        assertTrue(ICore(payable(core)).allowedAdapter(seaportAt) && ICore(payable(core)).allowedAdapter(strategyAt));
        _assertDone(core, Stage.Done);
        assertGt(seaportAt.code.length, 0);
        assertGt(strategyAt.code.length, 0);
    }

    function test_resumeAfterTheLaunch() public {
        (address core,) = _steps(4);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Done));
        _assertDone(core, Stage.Done);
    }

    /// a finished deploy: nothing is sent, the nonce does not move
    function test_resumeWhenDoneSendsNothing() public {
        (address core,) = _steps(4);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Done));
        uint64 nonce = vm.getNonce(deployer);
        uint256 bal = deployer.balance;
        _assertDone(core, Stage.Done);
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(deployer.balance, bal);
    }

    function test_resumeRefusesWhatItCannotFinish() public {
        // no core
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, makeAddr("nothing"));

        (address core,) = _steps(3);
        // a core built from another config
        LaunchConfig memory c = base;
        c.owner = creator;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "owner (OWNER_CHANGED=1 after a handover)"));
        this.resume(deployer, c, core);
        c = base;
        c.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "rateStart"));
        this.resume(deployer, c, core);
        // another name changes the coin prediction
        c = base;
        c.name = "Other";
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "coin prediction (config or deployer)"));
        this.resume(deployer, c, core);
        // another stack address
        c = base;
        c.stack.escrow = Mainnet.PERMIT2;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "stack"));
        this.resume(deployer, c, core);
        // a stranger is not the deployer of the run: the prediction does not hold
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "coin prediction (config or deployer)"));
        this.resume(stranger, base, core);
        // the real deployer still finishes it
        _assertDone(core, Stage.CoreOnly);
    }

    /// the launch step needs the deployer to still be the factory owner
    function test_resumeLaunchNeedsTheFactoryOwner() public {
        (address core,) = _steps(3);
        address next = makeAddr("next factory owner");
        vm.prank(deployer);
        IArtCoinsFactoryV2Owner(address(FACTORY)).transferOwnership(next);
        vm.prank(next);
        IArtCoinsFactoryV2Owner(address(FACTORY)).acceptOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector,
                "factory: owner is the config owner, factory: owner is the deployer, factory: deployTokenAsOwner accepts the config (simulated)"
            )
        );
        this.resume(deployer, base, core);
        // the owner path is the owner's: it is the factory owner again
        vm.prank(next);
        IArtCoinsFactoryV2Owner(address(FACTORY)).transferOwnership(deployer);
        vm.prank(deployer);
        IArtCoinsFactoryV2Owner(address(FACTORY)).acceptOwnership();
        _assertDone(core, Stage.CoreOnly);
    }

    /// the factory floor of the protocol skim share is the owner command: the launch step names the failed row when it
    /// is above 362
    function test_resumeLaunchNeedsTheMinProtocolSkimShareAt362() public {
        (address core,) = _steps(3);
        vm.prank(deployer);
        FACTORY.setMinProtocolSkimShareBps(1_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector,
                "factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)"
            )
        );
        this.resume(deployer, base, core);
        vm.prank(deployer);
        FACTORY.setMinProtocolSkimShareBps(362);
        _assertDone(core, Stage.CoreOnly);
    }

    /// S-6 of the old review, ported: the owner moved on after the launch. OWNER_CHANGED=1 says so
    function test_resumeOwnerChangedFinishesAndWarns() public {
        (address core,) = _steps(4);
        _assertDone(core, Stage.Done);
        address next = makeAddr("resume.next");
        vm.startPrank(owner);
        ICore(payable(core)).transferOwnership(next);
        vm.stopPrank();
        vm.prank(next);
        ICore(payable(core)).acceptOwnership();
        ownerFlag = true;
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Done), "nothing is sent");
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight reports the handover as warnings only");
    }

    function requireDeployerExt(address want, address got) external pure {
        _requireDeployer(want, got);
    }

    /// the core is on chain at the first resume point
    function test_theCoreExistsAtTheFirstResumePoint() public {
        (address core,) = _steps(3);
        assertTrue(core.code.length != 0, "no core");
        _assertDone(core, Stage.CoreOnly);
    }

    /// resume point 0: only the library is on chain. nothing to resume (no core), rerunning Deploy is safe: the library
    /// is skipped and takes no second nonce, so the addresses of a rerun are the ones preflight predicts now
    function test_libraryOnlyThenRerunDeploy() public {
        _steps(1);
        address someCore = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, someCore);
        scriptMode = true;
        assertFalse(_libraryTxPending(), "a rerun skips the library");
        assertEq(_controllerNonce(deployer), vm.getNonce(deployer), "and takes no nonce");
        scriptMode = false;
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        assertEq(d.core, someCore, "the rerun lands where the preflight said");
    }

    /// resume point 0b: the controller is on chain, the core is not. it is inert. no resume, the way on is a rerun of
    /// Deploy (new controller, core)
    function test_orphanControllerIsInert() public {
        (address core,) = _steps(2);
        assertEq(core.code.length, 0, "no core");
        address controller = vm.computeCreateAddress(deployer, vm.getNonce(deployer) - 1);
        assertEq(address(IControllerV1(controller).CORE()), core, "it points at the core that never came");
        assertEq(controller.balance, 0);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, core);
        // sending the saved core creation at the next nonce gives the predicted core, and Resume goes on from there
        vm.startPrank(deployer);
        address c2 = address(
            Prod.newCore(
                owner,
                buildConfig(base, owner, address(0)),
                deployer,
                controller,
                base.payee,
                base.stack,
                base.rateStart,
                base.settings,
                base.credit,
                launchAdapters(core, base)
            )
        );
        vm.stopPrank();
        assertEq(c2, core, "the saved creation lands on the predicted core");
        _assertDone(core, Stage.CoreOnly);
    }

    /// the owner can call setSettings the moment the core exists: Resume does not finish a core whose settings are not
    /// the signed ones unless the operator says so
    function test_resumeRefusesChangedSettings() public {
        (address core,) = _steps(4);
        Settings memory s = ICore(payable(core)).settings();
        s.saleFloorBps = 8_000;
        vm.prank(owner);
        ICore(payable(core)).setSettings(s);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "settings (SETTINGS_CHANGED=1 if the owner changed them)")
        );
        this.resume(deployer, base, core);
        // on purpose: the rest is sent, and postflight reads the difference as a warning
        changedFlag = true;
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Done));
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
    }

    /// the signer must be the deployer the operator named
    function test_deployerMustBeTheNamedOne() public {
        this.requireDeployerExt(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, owner, creator));
        this.requireDeployerExt(owner, creator);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);
    }

    /// the deploy itself refuses a sender that is not the factory owner and the config owner
    function test_deployRefusesANonFactoryOwner() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 5 ether);
        LaunchConfig memory c = base;
        c.owner = stranger;
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, stranger));
        this.deployExt(stranger, c);
        vm.stopPrank();
        // the factory owner with another config owner is refused too
        c = base;
        c.owner = creator;
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, deployer));
        this.deployExt(deployer, c);
        vm.stopPrank();
    }

    function deployExt(address who, LaunchConfig memory c) external {
        deploySystem(who, c);
    }
}

interface IArtCoinsFactoryV2Owner {
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
