// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// local copies of the artcoins v2 structs and of the interface members this repo calls (v2 repo commit 6d099486,
/// src/v2/interfaces); members no src, script or test file calls are left out. artcoins is not a dependency. the
/// field order must match the v2 abi exactly, so do not reorder anything. members the v2 interface files lack but the
/// v2 contracts expose are marked. pool ids are bytes32 here; the v2 abi types them as PoolId, which is bytes32 and
/// shares the function selector.

interface IArtCoinsFactoryV2 {
    struct TokenConfigV2 {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string description;
        uint256 totalSupply;
        address renderer;
    }

    struct PoolConfigV2 {
        address hook;
        int24 tickIfToken0IsCoin;
        int24 tickSpacing;
        address extension;
        bytes extensionData;
    }

    struct FeeConfigV2 {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        address payable bountyRecipient;
        uint24 referralBps;
    }

    struct LockerConfigV2 {
        address locker;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    struct MevConfigV2 {
        address module;
        uint24 startingSkimBps;
        uint32 windowSeconds;
    }

    struct RestrictionConfigV2 {
        bool restricted;
        address[] allowed;
    }

    struct ExtensionConfigV2 {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct DeploymentConfigV2 {
        TokenConfigV2 token;
        PoolConfigV2 pool;
        FeeConfigV2 fee;
        LockerConfigV2 locker;
        MevConfigV2 mev;
        RestrictionConfigV2 restriction;
        ExtensionConfigV2[] extensions;
    }

    struct DeploymentInfoV2 {
        address token;
        address hook;
        address locker;
        address mevModule;
        address escrow;
        bytes32 poolId;
        bytes32 configHash;
        uint16 version;
        uint40 launchedAt;
        bool restricted;
        address[] extensions;
    }

    function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);
    function predictToken(address sender, DeploymentConfigV2 calldata c) external view returns (address);

    function STACK_VERSION() external view returns (uint16);
    function owner() external view returns (address);
    function poolManager() external view returns (address);
    function tokenDeployer() external view returns (address);
    function isCoin(address token) external view returns (bool);
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory);
    function deprecated() external view returns (bool);
    function deployFee() external view returns (uint256);
    function protocolRecipient() external view returns (address payable);
    function teamFeeRecipient() external view returns (address);
    function enabledHooks(address hook) external view returns (bool);
    function enabledLockers(address locker) external view returns (bool);
    function enabledMevModules(address module) external view returns (bool);

    function setHook(address hook, bool enabled) external;
    function setLocker(address locker, bool enabled) external;
    function setMevModule(address module, bool enabled) external;
    function setDeprecated(bool deprecated_) external;
    function setDeployFee(uint256 fee) external;
}

interface IArtCoinsHookV2 {
    struct PoolInfo {
        uint16 version;
        bool restricted;
        uint40 createdAt;
        address launcher;
        address token;
        address locker;
        address mevModule;
        address extension;
    }

    struct SkimConfig {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        address payable bountyRecipient;
        address payable protocolRecipient;
        uint24 referralBps;
    }

    struct HookGlobals {
        address feeEscrow;
        address extensionAllowlist;
    }

    function poolInfo(bytes32 poolId) external view returns (PoolInfo memory);
    function isOfficialPool(bytes32 poolId) external view returns (bool);
    function skimConfig(bytes32 poolId) external view returns (SkimConfig memory);
    function globals() external view returns (HookGlobals memory);
    function isLauncher(address launcher) external view returns (bool);
    function constantsHash() external pure returns (bytes32);
    function poolManager() external view returns (address); // BaseHook getter, not in the v2 interface file
    function STACK_VERSION() external view returns (uint16);
    function setBountyRecipient(bytes32 poolId, address payable newRecipient) external;
    function lowerBaselineSkim(bytes32 poolId, uint24 bps) external;
}

interface IArtCoinsTokenV2 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function restricted() external view returns (bool);
    function locked() external view returns (bool);
    function isAllowed(address account) external view returns (bool);
    function transferAllowance() external view returns (uint256);
    function canonicalHook() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
    function poolManager() external view returns (address);
    function admin() external view returns (address);
    function launcher() external view returns (address);
    function setAllowed(address account, bool allowed) external;
    function unrestrict() external;
    function lock() external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function imageUrl() external view returns (string memory);
    function description() external view returns (string memory);
    function metadataRenderer() external view returns (address);
    function tokenURI() external view returns (string memory);
}

interface IArtCoinsLpLockerV2 {
    struct LockedLiquidity {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
    }

    function lockedLiquidity(address token) external view returns (LockedLiquidity memory);
    function isLauncher(address launcher) external view returns (bool);
}

interface IArtCoinsFeeEscrowV2 {
    function claim(address feeOwner, address token) external;
    function claimTo(address feeOwner, address token, address payable recipient) external;
    function balances(address feeOwner, address token) external view returns (uint256);
    function totalOwed(address token) external view returns (uint256);
    function selfClaimOnly(address feeOwner) external view returns (bool);
    function isDepositor(address depositor) external view returns (bool);
    function isCoreDepositor(address depositor) external view returns (bool);
}

interface IArtCoinsMevSkimV2 {
    /// the frozen per pool schedule. `schedule` is on the contract, not in the v2 interface file
    struct SkimSchedule {
        uint24 startingSkimBps;
        uint24 endSkimBps;
        uint32 windowSeconds;
        uint40 startTime;
    }

    function schedule(bytes32 poolId) external view returns (SkimSchedule memory);
    function currentSkimBps(bytes32 poolId) external view returns (uint24 skimBps, bool active);
    function hook() external view returns (address);
}

/// @dev OpenZeppelin Ownable2Step surface of the v2 escrow, hook, locker, factory, controller, router
interface IOwnable2StepV2 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
