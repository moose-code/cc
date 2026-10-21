// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";

/// @dev the Splits v2 split configuration (SplitV2Lib.Split); the split stores only its hash
struct SplitConfig {
    address[] recipients;
    uint256[] allocations;
    uint256 totalAllocation;
    uint16 distributionIncentive;
}

interface ISplitFactoryV2 {
    function SPLIT_WALLET_IMPLEMENTATION() external view returns (address);
    function createSplit(SplitConfig calldata splitParams, address owner, address creator) external returns (address);
}

interface ISplitWalletV2 {
    function splitHash() external view returns (bytes32);
    function owner() external view returns (address);
    function distribute(SplitConfig calldata split, address token, address distributor) external;
}

/// @notice creates the artist and operator split of decision 255 as a Splits v2.2 push split: the splits.org form only
/// creates pull splits, whose `distribute` credits the Splits warehouse instead of paying the recipients. the split is
/// `recipients` [artist, operator] at 833,333 and 166,667 of 1,000,000 (5/6 and 1/6, the form's 83.3333 and
/// 16.6667 percent), no distribution incentive, the Core owner as the split's controller. the factory and its wallet
/// implementation are pinned by address and runtime code hash; the preview creates the split in simulation, funds it
/// and distributes once to prove the push (the recipients' balances rise, the split keeps 1 wei by design), and prints
/// the keeper's `SPLIT_*` lines and the `PHASE2_ARTIST` value. nothing is sent without `SEND=1 --broadcast`.
/// inputs: `CORE` (default the mainnet Core) for the artist, the operator (its `payee`) and the controller (its
/// `owner`); `SPLIT_ARTIST`, `SPLIT_OPERATOR`, `SPLIT_CONTROLLER` override each.
/// `forge script script/CreatePushSplit.s.sol --rpc-url $MAINNET_RPC_URL` (add `SEND=1 --broadcast` and a signer)
contract CreatePushSplit is Script {
    /// @dev Splits v2.2 PushSplitFactory on Ethereum mainnet (0xSplits splits-contracts-monorepo deployments/1.json)
    address public constant PUSH_FACTORY = 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4;
    /// @dev the factory's `SPLIT_WALLET_IMPLEMENTATION` and its runtime code hash, read at block 26,238,176
    address public constant PUSH_IMPLEMENTATION = 0x1e2086A7e84a32482ac03000D56925F607CCB708;
    bytes32 public constant PUSH_IMPLEMENTATION_CODEHASH =
        0xd03d1b6c36959af2f2d340ac9e0996c528aa88bcc0bb41461929a6bb2ba064bb;
    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    /// @dev the Splits warehouse's native token key; the push split pays ETH under it
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant ARTIST_ALLOCATION = 833_333;
    uint256 public constant OPERATOR_ALLOCATION = 166_667;
    uint256 public constant TOTAL_ALLOCATION = 1_000_000;
    /// @dev the Core pushes ETH to the artist with this gas bound (Core.PUSH_GAS)
    uint256 public constant CORE_PUSH_GAS = 50_000;
    /// @dev the simulated distributor and payer of the push probe
    address public constant PROBE = 0x00000000000000000000000000000000000Fab1e;

    /// @dev the factory or its implementation is not the pinned push factory
    error FactoryMismatch(address factory, address implementation, bytes32 codehash);
    /// @dev the artist, operator or controller is zero, or the artist equals the operator
    error BadRecipient(address artist, address operator, address controller);
    /// @dev the created split does not hold the expected hash or controller
    error SplitMismatch(address split);
    /// @dev the created split did not push a distribution to both recipients, or refused the Core's gas bound
    error NotPush(address split);

    struct Inputs {
        address artist;
        address operator;
        address controller;
    }

    function run() external {
        Inputs memory i = inputs();
        SplitConfig memory cfg = config(i.artist, i.operator);
        console.log("push factory", PUSH_FACTORY);
        console.log("artist (5/6)", i.artist);
        console.log("operator (1/6)", i.operator);
        console.log("controller", i.controller);
        console.log("expected split hash");
        console.logBytes32(hashOf(cfg));
        _checkFactory();
        address split;
        if (_send()) {
            vm.startBroadcast();
            split = ISplitFactoryV2(PUSH_FACTORY).createSplit(cfg, i.controller, msg.sender);
            vm.stopBroadcast();
        } else {
            split = ISplitFactoryV2(PUSH_FACTORY).createSplit(cfg, i.controller, msg.sender);
        }
        verify(split, cfg, i.controller);
        probePush(split, cfg);
        console.log("split", split);
        console.log(_send() ? "created" : "preview only. add SEND=1 and --broadcast with a signer to create");
        console.log("PHASE2_ARTIST=%s", vm.toString(split));
        console.log("SPLIT_ADDRESS=%s", vm.toString(split));
        console.log("SPLIT_RECIPIENTS=%s,%s", vm.toString(i.artist), vm.toString(i.operator));
        console.log("SPLIT_ALLOCATIONS=%s,%s", vm.toString(ARTIST_ALLOCATION), vm.toString(OPERATOR_ALLOCATION));
        console.log("SPLIT_TOTAL_ALLOCATION=%s", vm.toString(TOTAL_ALLOCATION));
        console.log("SPLIT_DISTRIBUTION_INCENTIVE=0");
    }

    /// @dev the artist, operator and controller: environment overrides, else the Core's artist, payee and owner
    function inputs() public view returns (Inputs memory i) {
        ICore core = ICore(payable(vm.envOr("CORE", MAINNET_CORE)));
        i.artist = vm.envOr("SPLIT_ARTIST", core.artist());
        i.operator = vm.envOr("SPLIT_OPERATOR", core.payee());
        i.controller = vm.envOr("SPLIT_CONTROLLER", core.owner());
        if (i.artist == address(0) || i.operator == address(0) || i.controller == address(0) || i.artist == i.operator)
        {
            revert BadRecipient(i.artist, i.operator, i.controller);
        }
    }

    function config(address artist, address operator) public pure returns (SplitConfig memory cfg) {
        cfg.recipients = new address[](2);
        cfg.recipients[0] = artist;
        cfg.recipients[1] = operator;
        cfg.allocations = new uint256[](2);
        cfg.allocations[0] = ARTIST_ALLOCATION;
        cfg.allocations[1] = OPERATOR_ALLOCATION;
        cfg.totalAllocation = TOTAL_ALLOCATION;
        cfg.distributionIncentive = 0;
    }

    /// @dev SplitV2Lib.getHash: keccak256(abi.encode(split))
    function hashOf(SplitConfig memory cfg) public pure returns (bytes32) {
        return keccak256(abi.encode(cfg));
    }

    function verify(address split, SplitConfig memory cfg, address controller) public view {
        if (split.code.length == 0) revert SplitMismatch(split);
        if (ISplitWalletV2(split).splitHash() != hashOf(cfg)) revert SplitMismatch(split);
        if (ISplitWalletV2(split).owner() != controller) revert SplitMismatch(split);
    }

    /// @dev simulation only: fund the split, distribute, require both recipients paid directly and the Core's push
    /// gas bound honored
    function probePush(address split, SplitConfig memory cfg) public {
        uint256 amount = 1 ether;
        vm.deal(split, amount);
        uint256 a0 = cfg.recipients[0].balance;
        uint256 o0 = cfg.recipients[1].balance;
        vm.prank(PROBE);
        ISplitWalletV2(split).distribute(cfg, NATIVE, PROBE);
        uint256 paidArtist = cfg.recipients[0].balance - a0;
        uint256 paidOperator = cfg.recipients[1].balance - o0;
        // the split keeps 1 wei of each token as a gas optimization, so the distributed amount is amount - 1
        uint256 distributed = amount - 1;
        if (paidArtist != distributed * ARTIST_ALLOCATION / TOTAL_ALLOCATION) revert NotPush(split);
        if (paidOperator != distributed * OPERATOR_ALLOCATION / TOTAL_ALLOCATION) revert NotPush(split);
        vm.deal(PROBE, 1 ether);
        vm.prank(PROBE);
        (bool ok,) = split.call{value: 0.1 ether, gas: CORE_PUSH_GAS}("");
        if (!ok) revert NotPush(split);
        console.log("push probe: artist %s wei, operator %s wei of %s", paidArtist, paidOperator, distributed);
    }

    function _checkFactory() internal view {
        address impl =
            PUSH_FACTORY.code.length == 0 ? address(0) : ISplitFactoryV2(PUSH_FACTORY).SPLIT_WALLET_IMPLEMENTATION();
        bytes32 codehash = impl == address(0) ? bytes32(0) : impl.codehash;
        if (impl != PUSH_IMPLEMENTATION || codehash != PUSH_IMPLEMENTATION_CODEHASH) {
            revert FactoryMismatch(PUSH_FACTORY, impl, codehash);
        }
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }
}
