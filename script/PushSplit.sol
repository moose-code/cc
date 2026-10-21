// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

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

/// @notice the artist and operator split of decision 255 as a Splits v2.2 push split, shared by Phase2Deploy and
/// CreatePushSplit: `recipients` [artist, operator] at 833,333 and 166,667 of 1,000,000 (5/6 and 1/6), no
/// distribution incentive, the Core owner as the split's controller. the factory and its wallet implementation are
/// pinned by address and runtime code hash. the splits.org form creates pull splits only, whose `distribute` credits
/// the Splits warehouse instead of paying the recipients, so a split is accepted only after `probeSplitPush` paid both
/// recipients directly in simulation and took the Core's 50,000 gas push.
abstract contract PushSplitCreator is Script {
    /// @dev Splits v2.2 PushSplitFactory on Ethereum mainnet (0xSplits splits-contracts-monorepo deployments/1.json)
    address public constant PUSH_FACTORY = 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4;
    /// @dev the factory's `SPLIT_WALLET_IMPLEMENTATION` and its runtime code hash, read at block 26,238,176
    address public constant PUSH_IMPLEMENTATION = 0x1e2086A7e84a32482ac03000D56925F607CCB708;
    bytes32 public constant PUSH_IMPLEMENTATION_CODEHASH =
        0xd03d1b6c36959af2f2d340ac9e0996c528aa88bcc0bb41461929a6bb2ba064bb;
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
    /// @dev the split does not hold the expected hash or controller
    error SplitMismatch(address split);
    /// @dev the split did not push a distribution to both recipients, or refused the Core's gas bound
    error NotPush(address split);

    struct SplitPlan {
        address artist;
        address operator;
        address controller;
    }

    function splitConfig(address artist, address operator) public pure returns (SplitConfig memory cfg) {
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
    function splitHashOf(SplitConfig memory cfg) public pure returns (bytes32) {
        return keccak256(abi.encode(cfg));
    }

    function requireSplitPlan(SplitPlan memory p) public pure {
        if (p.artist == address(0) || p.operator == address(0) || p.controller == address(0) || p.artist == p.operator)
        {
            revert BadRecipient(p.artist, p.operator, p.controller);
        }
    }

    /// @dev creates the split at the pinned factory; the caller wraps it in a broadcast to send
    function createPushSplit(SplitPlan memory p, address creator) public returns (address) {
        requireSplitPlan(p);
        checkSplitFactory();
        return ISplitFactoryV2(PUSH_FACTORY).createSplit(splitConfig(p.artist, p.operator), p.controller, creator);
    }

    /// @dev the split holds the plan's hash and controller and pushes: the acceptance of a created or a given split
    function acceptSplit(address split, SplitPlan memory p) public {
        SplitConfig memory cfg = splitConfig(p.artist, p.operator);
        verifySplit(split, cfg, p.controller);
        probeSplitPush(split, cfg);
    }

    function verifySplit(address split, SplitConfig memory cfg, address controller) public view {
        if (split.code.length == 0) revert SplitMismatch(split);
        if (ISplitWalletV2(split).splitHash() != splitHashOf(cfg)) revert SplitMismatch(split);
        if (ISplitWalletV2(split).owner() != controller) revert SplitMismatch(split);
    }

    /// @dev simulation only: fund the split, distribute, require both recipients paid directly and the Core's push
    /// gas bound honored. the split keeps 1 wei of each token by design, so the distributed amount is amount - 1
    function probeSplitPush(address split, SplitConfig memory cfg) public {
        uint256 amount = 1 ether;
        vm.deal(split, amount);
        uint256 a0 = cfg.recipients[0].balance;
        uint256 o0 = cfg.recipients[1].balance;
        vm.prank(PROBE);
        ISplitWalletV2(split).distribute(cfg, NATIVE, PROBE);
        uint256 paidArtist = cfg.recipients[0].balance - a0;
        uint256 paidOperator = cfg.recipients[1].balance - o0;
        uint256 distributed = amount - 1;
        if (paidArtist != distributed * ARTIST_ALLOCATION / TOTAL_ALLOCATION) revert NotPush(split);
        if (paidOperator != distributed * OPERATOR_ALLOCATION / TOTAL_ALLOCATION) revert NotPush(split);
        vm.deal(PROBE, 1 ether);
        vm.prank(PROBE);
        (bool ok,) = split.call{value: 0.1 ether, gas: CORE_PUSH_GAS}("");
        if (!ok) revert NotPush(split);
        console.log("push probe: artist %s wei, operator %s wei of %s", paidArtist, paidOperator, distributed);
    }

    function checkSplitFactory() public view {
        address impl =
            PUSH_FACTORY.code.length == 0 ? address(0) : ISplitFactoryV2(PUSH_FACTORY).SPLIT_WALLET_IMPLEMENTATION();
        bytes32 codehash = impl == address(0) ? bytes32(0) : impl.codehash;
        if (impl != PUSH_IMPLEMENTATION || codehash != PUSH_IMPLEMENTATION_CODEHASH) {
            revert FactoryMismatch(PUSH_FACTORY, impl, codehash);
        }
    }

    /// @dev the lines the owner pastes: the settings patch input and the keeper's split configuration
    function printSplitLines(address split, SplitPlan memory p) public pure {
        console.log("PHASE2_ARTIST=%s", vm.toString(split));
        console.log("SPLIT_ADDRESS=%s", vm.toString(split));
        console.log("SPLIT_RECIPIENTS=%s,%s", vm.toString(p.artist), vm.toString(p.operator));
        console.log("SPLIT_ALLOCATIONS=%s,%s", vm.toString(ARTIST_ALLOCATION), vm.toString(OPERATOR_ALLOCATION));
        console.log("SPLIT_TOTAL_ALLOCATION=%s", vm.toString(TOTAL_ALLOCATION));
        console.log("SPLIT_DISTRIBUTION_INCENTIVE=0");
    }

    /// @dev the split's json for a deployment record
    function splitRecord(address split, SplitPlan memory p) public pure returns (string memory) {
        return string.concat(
            '"split":{"address":"',
            vm.toString(split),
            '","factory":"',
            vm.toString(PUSH_FACTORY),
            '","recipients":["',
            vm.toString(p.artist),
            '","',
            vm.toString(p.operator),
            '"],"allocations":[',
            vm.toString(ARTIST_ALLOCATION),
            ",",
            vm.toString(OPERATOR_ALLOCATION),
            '],"totalAllocation":',
            vm.toString(TOTAL_ALLOCATION),
            ',"distributionIncentive":0,"controller":"',
            vm.toString(p.controller),
            '"}'
        );
    }
}
