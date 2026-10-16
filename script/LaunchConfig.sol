// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {
    Stack,
    Settings,
    Sale,
    Credit,
    Mainnet,
    RATE_START_MIN_WEI,
    RATE_START_MAX_WEI
} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {CreditBounds} from "../src/lib/CreditBounds.sol";

// the `constantsHash()` the master v2 stack reports (hook, factory, locker, escrow, mev module and the rest).
// preflight requires it of the hook and of the other four members the config names
bytes32 constant V2_CONSTANTS_HASH = 0x1b7deab81425bd850537efbb78d999939ab5fe16c424268886a5554d864e23d0;

// the runtime code hashes (`extcodehash`, immutables included) of the master v2 stack contracts. preflight requires
// the hash of each contract the config and the factory point at. script/config/v2-master.json holds the addresses
// and these hashes
uint256 constant V2_PIN_BLOCK = 26205064;
bytes32 constant V2_CODEHASH_HOOK = 0x6778602725c0d685c6444cdc70d6616d266939e09d283388a6b79b7bd496ebdc;
bytes32 constant V2_CODEHASH_FACTORY = 0xc81a73b9453ca0e93afd762d32b98e4a9e2b157cdccd05d28fda9080f98e0c65;
bytes32 constant V2_CODEHASH_LOCKER = 0x191e433101a918cc441bf7c143de216757b9a40ed2402131434a8747861c386a;
bytes32 constant V2_CODEHASH_ESCROW = 0xeb557e5be7ab0b29b0c77f8dc18aada8e1d17910ae9e3b92909a9126872b9975;
bytes32 constant V2_CODEHASH_MEV_MODULE = 0xe3bf485f62bf367feabe951d667032c6cea47a3089056ce0652df6edd145dc80;
bytes32 constant V2_CODEHASH_TOKEN_DEPLOYER = 0xaf3924c04e77f7e9ccb5949e977c2d67c2186076108e5676cbe99ecd08dfb043;
bytes32 constant V2_CODEHASH_ALLOWLIST = 0x7a98bacb16f0ec968f5d450c37e6a5a4ef213a8d48c61c666b2cea3e0f6318c4;
bytes32 constant V2_CODEHASH_FEE_CONTROLLER = 0x33ac026109644470a4feaf0c0960c41468adfc0029fe5bdca29fe0342ff85bae;
bytes32 constant V2_CODEHASH_BURN_ROUTER = 0x446c38e7f907b120416c06e90f92f966a20cca49df8ea19711c6b12c4a40edd9;

// the EIP 7702 delegation of the owner account, read at V2_PIN_BLOCK. the account runs the code of OWNER_DELEGATE
// (Uniswap Calibur, 24,504 bytes, no proxy). preflight requires the account code, the delegate code hash and an empty
// key registry (`keyCount()` 0), so no registered key can act as the owner. docs/reviews/REVIEW-sandwich-delegate.md section 2
bytes constant OWNER_DELEGATION_CODE = hex"ef0100612373d7003d694220f7800eeaf8e3924c0951d3";
address constant OWNER_DELEGATE = 0x612373D7003d694220f7800EeaF8E3924c0951D3;
bytes32 constant OWNER_DELEGATE_CODEHASH = 0xff0357b543bbb94845b6791a8becac5e87d467814f86538a62649c877227d631;

/// @notice everything a launch needs. one struct, loaded from script/config/mainnet.json by the scripts and built in
/// memory by the tests. nothing here is read by `src/`: the Core takes `stack`, `rateStart` and `settings` as constructor
/// arguments
struct LaunchConfig {
    // the artcoins stack. the only block that changes when a new artcoins version ships
    Stack stack;
    address mevModule;
    // launch inputs. the shipped config file holds the live stack and every field below. test/Config.t.sol asserts that
    // `unsetFields` is empty for it
    address owner;
    address creator;
    string name;
    string symbol;
    /// the coin's image url and description, set in the launch transaction (docs/DECISIONS.md decision 54). bytes are capped
    /// by the coin (`MAX_IMAGE_BYTES` 2048, `MAX_DESCRIPTION_BYTES` 4096). empty is allowed, the coin admin sets them
    /// later with `updateImage` and `updateDescription`
    string image;
    string description;
    bytes32 salt;
    // core
    uint256 rateStart;
    /// every economic setting at launch. owner adjustable afterwards, so the launch rules only check bounds
    Settings settings;
    /// the sale settings of the controller at launch (its constructor argument). owner adjustable afterwards
    Sale sale;
    /// the credit settings of the Core and the controller at launch (their constructor argument). owner adjustable
    /// afterwards
    Credit credit;
    // launch parameters
    uint256 supply;
    int24 startTick;
    int24 positionLower;
    int24 positionUpper;
    /// the baseline skim in bps of volume (1000 is 10 percent)
    uint24 baselineSkimBps;
    /// the engine's share of the baseline skim, bps. the protocol keeps the rest, `10_000 - bountyBps` at the baseline
    uint16 bountyBps;
    /// the anti sniper skim at the first block in bps of volume, falling to the baseline over `sniperSeconds`
    uint24 sniperStartBps;
    uint32 sniperSeconds;
    /// the coin is launched restricted (docs/DECISIONS.md 18) and the extra allowlist entries beyond the factory's own seeds.
    /// the Core is not listed (docs/DECISIONS.md 29)
    bool restricted;
    address[] allowed;
    /// the recipients of additional payouts that `SeaportBasicAdapter` accepts at launch. the OpenSea fee collector
    address[] seaportRecipients;
    /// the address the payee fee share (`settings.payeePpm`, 0 at launch) and the operator cut of nft sales
    /// (`settings.saleToOperatorBps`) are pushed to. the Core receives bountyBps / 10_000 of the baseline skim, 9_000 /
    /// 10_000 of 1000 bps is 900 bps of volume (9.0 points). the owner can raise the fee share with `Core.setPayee`
    address payee;
    /// the address the artist cut of nft sales (`settings.saleToArtistBps`) is pushed to, set by `Core.setArtist`
    address artist;
    // explicit overrides of pinned preflight rules. all false by default. each one is part of the config hash
    /// allow a bountyBps other than 9000
    bool allowBounty;
    /// allow launching while the factory is not deprecated (a future public factory)
    bool allowOpenFactory;
}

/// @notice reads and checks a `LaunchConfig`
abstract contract ConfigReader is CommonBase {
    string internal constant DEFAULT_CONFIG_FILE = "script/config/mainnet.json";
    /// @dev the master stack fork record. STACK=master repoints a launch config at it
    string internal constant MASTER_RECORD = "script/config/v2-master.json";
    /// @dev a json number does not fit the field it is cut into
    error ConfigOutOfRange(string key);

    /// @dev the bounds of the Core constructor argument, one shared definition with the Core, so they cannot drift
    uint256 internal constant RATE_START_MIN = RATE_START_MIN_WEI;
    uint256 internal constant RATE_START_MAX = RATE_START_MAX_WEI;

    /// @notice the default config in memory: the fixed mainnet parts and the launch parameters of
    /// docs/DECISIONS.md sections 10.1 and 10.6, with the v2 stack addresses, owner, creator, payees, name and salt left unset (the symbol is CC). tests fill them
    function defaultConfig() internal pure returns (LaunchConfig memory c) {
        c.stack = Mainnet.defaultStack();
        c.symbol = "CC";
        c.rateStart = 25_000_000_000_000_000;
        c.settings = Mainnet.defaultSettings();
        c.sale = Mainnet.defaultSale();
        c.credit = Mainnet.defaultCredit();
        c.supply = 1_000_000_000e18;
        c.startTick = -175_000;
        c.positionLower = -175_000;
        c.positionUpper = 887_200;
        c.baselineSkimBps = 1000;
        c.bountyBps = 9000;
        c.sniperStartBps = 9_000;
        c.sniperSeconds = 1800;
        c.restricted = true;
        c.seaportRecipients = new address[](1);
        c.seaportRecipients[0] = Mainnet.OPENSEA_FEE_COLLECTOR;
    }

    /// @notice parses a config file. a missing key reverts inside the cheatcode, a number that does not fit its field
    /// reverts with `ConfigOutOfRange`
    function loadConfig(string memory file) internal view returns (LaunchConfig memory) {
        return parseConfig(vm.readFile(file));
    }

    /// @notice parses a config given as json text
    function parseConfig(string memory j) internal view returns (LaunchConfig memory c) {
        c.stack = Stack({
            poolManager: vm.parseJsonAddress(j, ".stack.poolManager"),
            hook: vm.parseJsonAddress(j, ".stack.hook"),
            tickSpacing: _i24(j, ".stack.tickSpacing"),
            poolFee: _u24(j, ".stack.poolFee"),
            factory: vm.parseJsonAddress(j, ".stack.factory"),
            locker: vm.parseJsonAddress(j, ".stack.locker"),
            escrow: vm.parseJsonAddress(j, ".stack.escrow")
        });
        c.mevModule = vm.parseJsonAddress(j, ".stack.mevModule");
        c.owner = vm.parseJsonAddress(j, ".owner");
        c.creator = vm.parseJsonAddress(j, ".creator");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.image = vm.parseJsonString(j, ".image");
        c.description = vm.parseJsonString(j, ".description");
        c.salt = vm.parseJsonBytes32(j, ".salt");
        c.rateStart = vm.parseJsonUint(j, ".rateStart");
        _loadSettings(c, j);
        _loadSale(c, j);
        _loadCredit(c, j);
        _loadLaunch(c, j);
        // the overrides are optional, a missing key means false
        c.allowBounty = _flag(j, ".overrides.bounty");
        c.allowOpenFactory = _flag(j, ".overrides.openFactory");
        _applyStackSelector(c);
    }

    /// @notice STACK=master repoints the v2 members at the master stack fork record (script/config/v2-master.json) and
    /// the launch identities (owner, creator, payee) at the master stack owner, the anvil account that owns the fork
    /// deployment. the poolManager, tick spacing, pool fee, artist, name, salt and every other field stay. the default
    /// is the live stack already in the file
    function _applyStackSelector(LaunchConfig memory c) private view {
        if (keccak256(bytes(vm.envOr("STACK", string("")))) != keccak256("master")) return;
        string memory j = vm.readFile(MASTER_RECORD);
        c.stack.hook = vm.parseJsonAddress(j, ".hook");
        c.stack.factory = vm.parseJsonAddress(j, ".factory");
        c.stack.locker = vm.parseJsonAddress(j, ".locker");
        c.stack.escrow = vm.parseJsonAddress(j, ".escrow");
        c.mevModule = vm.parseJsonAddress(j, ".mevModule");
        address owner = vm.parseJsonAddress(j, ".owner");
        c.owner = owner;
        c.creator = owner;
        c.payee = owner;
    }

    function _loadSettings(LaunchConfig memory c, string memory j) private pure {
        Settings memory s = c.settings;
        s.dropPerCreditBps = _u16(j, ".settings.dropPerCreditBps");
        s.dropFloorBps = _u16(j, ".settings.dropFloorBps");
        s.climbPerMinBps = _u16(j, ".settings.climbPerMinBps");
        s.ceilBps = _u16(j, ".settings.ceilBps");
        s.idleLoosenBps = _u16(j, ".settings.idleLoosenBps");
        s.saleFloorBps = _u16(j, ".settings.saleFloorBps");
        s.saleToBuybackBps = _u16(j, ".settings.saleToBuybackBps");
        s.saleToArtistBps = _u16(j, ".settings.saleToArtistBps");
        s.saleToOperatorBps = _u16(j, ".settings.saleToOperatorBps");
        s.recoveryClimbPerMinBps = _u16(j, ".settings.recoveryClimbPerMinBps");
        s.recoveryGapBps = _u16(j, ".settings.recoveryGapBps");
        s.peakHalfLife = _u32(j, ".settings.peakHalfLife");
        s.buybackDelay = _u16(j, ".settings.buybackDelay");
        // forge-lint: disable-start(unsafe-typecast)
        s.redeemOn = vm.parseJsonBool(j, ".settings.redeemOn");
        s.balanceBidOn = vm.parseJsonBool(j, ".settings.balanceBidOn");
        s.redeemSlippageBps = _u16(j, ".settings.redeemSlippageBps");
        s.balanceBidMarginBps = _u16(j, ".settings.balanceBidMarginBps");
        s.redeemBurnBps = _u16(j, ".settings.redeemBurnBps");
        s.buybackSlice = uint128(_uint(j, ".settings.buybackSlice", type(uint128).max));
        s.keeperFee = uint64(_uint(j, ".settings.keeperFee", type(uint64).max));
        s.keeperMaxBaseFee = uint48(_uint(j, ".settings.keeperMaxBaseFee", type(uint48).max));
        s.rateCap = uint64(_uint(j, ".settings.rateCap", type(uint64).max));
        s.callerFee = uint64(_uint(j, ".settings.callerFee", type(uint64).max));
        s.callerMaxBaseFee = uint48(_uint(j, ".settings.callerMaxBaseFee", type(uint48).max));
        // forge-lint: disable-end(unsafe-typecast)
        s.feeToRedeemBurnBps = _u16(j, ".settings.feeToRedeemBurnBps");
        s.payeePpm = _u24(j, ".settings.payeePpm");
        s.refScore = _u32(j, ".settings.refScore");
        // forge-lint: disable-next-line(unsafe-typecast)
        s.swapFeeCc = uint96(_uint(j, ".settings.swapFeeCc", type(uint96).max));
        s.climbMultiplierCapBps = _u16(j, ".settings.climbMultiplierCapBps");
        s.spendCapBps = _u16(j, ".settings.spendCapBps");
        s.bucketSeconds = _u32(j, ".settings.bucketSeconds");
        s.balanceBidCapBps = _u32(j, ".settings.balanceBidCapBps");
        s.idleStepSeconds = _u32(j, ".settings.idleStepSeconds");
        s.sniperSeconds = _u32(j, ".settings.sniperSeconds");
    }

    function _loadSale(LaunchConfig memory c, string memory j) private pure {
        c.sale = Sale({
            markupBps: _u16(j, ".sale.markupBps"),
            startCapBps: _u32(j, ".sale.startCapBps"),
            decayHours: _u16(j, ".sale.decayHours"),
            anchorHalfLife: _u32(j, ".sale.anchorHalfLife"),
            anchorMinCost: _u128(j, ".sale.anchorMinCost"),
            anchorMoveBps: _u16(j, ".sale.anchorMoveBps")
        });
    }

    function _loadCredit(LaunchConfig memory c, string memory j) private pure {
        c.credit = Credit({
            costToPotBps: _u16(j, ".credit.costToPotBps"),
            chosenComposeOn: vm.parseJsonBool(j, ".credit.chosenComposeOn"),
            minCcToChoose: _u96(j, ".credit.minCcToChoose"),
            saleOn: vm.parseJsonBool(j, ".credit.saleOn"),
            window: _u32(j, ".credit.window"),
            floorBps: _u16(j, ".credit.floorBps"),
            startBps: _u32(j, ".credit.startBps")
        });
    }

    function _loadLaunch(LaunchConfig memory c, string memory j) private pure {
        // the supply is a decimal string, it does not fit a json number
        c.supply = vm.parseJsonUint(j, ".launch.supply");
        c.startTick = _i24(j, ".launch.startTick");
        c.positionLower = _i24(j, ".launch.positionLower");
        c.positionUpper = _i24(j, ".launch.positionUpper");
        c.baselineSkimBps = _u24(j, ".launch.baselineSkimBps");
        c.bountyBps = _u16(j, ".launch.bountyBps");
        c.sniperStartBps = _u24(j, ".launch.sniperStartBps");
        c.sniperSeconds = _u32(j, ".launch.sniperSeconds");
        c.restricted = vm.parseJsonBool(j, ".launch.restricted");
        c.allowed = vm.parseJsonAddressArray(j, ".launch.allowed");
        c.seaportRecipients = vm.parseJsonAddressArray(j, ".adapters.seaportRecipients");
        c.payee = vm.parseJsonAddress(j, ".payee.address");
        c.artist = vm.parseJsonAddress(j, ".artist");
    }

    // every narrowing below follows a bounds check, so the casts cannot truncate
    function _uint(string memory j, string memory key, uint256 max) private pure returns (uint256 v) {
        v = vm.parseJsonUint(j, key);
        if (v > max) revert ConfigOutOfRange(key);
    }

    function _u16(string memory j, string memory key) private pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(_uint(j, key, type(uint16).max));
    }

    function _u24(string memory j, string memory key) private pure returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(_uint(j, key, type(uint24).max));
    }

    function _u32(string memory j, string memory key) private pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(_uint(j, key, type(uint32).max));
    }

    function _u96(string memory j, string memory key) private pure returns (uint96) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(_uint(j, key, type(uint96).max));
    }

    function _u128(string memory j, string memory key) private pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(_uint(j, key, type(uint128).max));
    }

    function _i24(string memory j, string memory key) private pure returns (int24) {
        int256 v = vm.parseJsonInt(j, key);
        if (v < type(int24).min || v > type(int24).max) revert ConfigOutOfRange(key);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(v);
    }

    function _flag(string memory j, string memory key) private view returns (bool) {
        return vm.keyExistsJson(j, key) && vm.parseJsonBool(j, key);
    }

    /// @notice the placeholders every launch must fill: returns the names of those still unset
    function unsetFields(LaunchConfig memory c) internal pure returns (string[] memory out) {
        string[] memory tmp = new string[](13);
        uint256 n;
        if (c.owner == address(0)) tmp[n++] = "owner";
        if (c.creator == address(0)) tmp[n++] = "creator";
        if (c.artist == address(0) && c.settings.saleToArtistBps != 0) tmp[n++] = "artist";
        if (bytes(c.name).length == 0) tmp[n++] = "name";
        if (bytes(c.symbol).length == 0) tmp[n++] = "symbol";
        if (c.salt == bytes32(0)) tmp[n++] = "salt";
        if (c.payee == address(0)) tmp[n++] = "payee.address";
        // a config file that leaves a stack address at zero is refused
        if (c.stack.hook == address(0)) tmp[n++] = "stack.hook";
        if (c.stack.factory == address(0)) tmp[n++] = "stack.factory";
        if (c.stack.locker == address(0)) tmp[n++] = "stack.locker";
        if (c.stack.escrow == address(0)) tmp[n++] = "stack.escrow";
        if (c.mevModule == address(0)) tmp[n++] = "stack.mevModule";
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    function rateInBounds(LaunchConfig memory c) internal pure returns (bool) {
        return c.rateStart >= RATE_START_MIN && c.rateStart <= RATE_START_MAX && c.rateStart <= c.settings.rateCap;
    }

    /// @notice the name of the first launch sale setting outside the bounds the controller enforces, zero when all are inside
    function saleViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        Sale memory k = c.sale;
        if (k.markupBps < 10_000) return "markupBps";
        if (k.startCapBps < k.markupBps) return "startCapBps";
        if (k.decayHours < 1) return "decayHours";
        if (k.anchorHalfLife < 1) return "anchorHalfLife";
        if (k.anchorMoveBps > 10_000) return "anchorMoveBps";
        return bytes32(0);
    }

    /// @notice the name of the first launch setting outside the bounds the Core enforces, zero when all are inside
    function settingsViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        return SettingsBounds.firstViolation(c.settings);
    }

    /// @notice the name of the first launch credit setting outside the bounds the Core and the controller enforce,
    /// zero when all are inside
    function creditViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        return CreditBounds.firstViolation(c.credit);
    }
}
