// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoinRenderer} from "../src/interfaces/ICoinRenderer.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {ICredits, ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {SystemDeployer, Deployed} from "../script/SystemDeployer.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

interface IUniversalRouterR {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2R {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice the launch rehearsal. forks mainnet at the LATEST block (read from the rpc, not the pinned one), runs the
/// preflight, the real deploy path as the factory owner, the postflight, and a short smoke: a buy and a sell through the
/// universal router, a book of the fees at the Core that pushes the payee share once the owner raises `payeePpm` (the `FeesAdded` amount) and a real credit sold into the bid. it skips cleanly unless the env var
/// REHEARSAL is set, so the default suite stays pinned and fast. it reads the config file named by LAUNCH_CONFIG, like the
/// scripts do, and defaults to script/config/rehearsal.json, whose `image` and `description` hold the placeholder marker:
/// the preflight metadata row (`METADATA_ROW`) is expected to fail before and
/// after the owner command. a file with real values is rehearsed as it is and every row must pass. the launch goes through the live v2
/// factory (the config owner is its owner, impersonated on the fork). it measures the gas of every transaction of the deploy and asserts each
/// one fits under the per transaction gas cap
/// `set -a; . ./.env; set +a; REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`
contract RehearsalTest is Test, ProdDeployer {
    string internal constant REHEARSAL_CONFIG_FILE = "script/config/rehearsal.json";

    LaunchConfig internal c;
    Deployed internal d;
    address internal deployer;
    address internal trader;

    function _user(string memory label) internal returns (address a) {
        a = makeAddr(string.concat("rehearsal.", label, ".7d3a"));
        assertEq(a.code.length, 0, "account has code on the fork");
    }

    // promise: rehearsal
    function test_rehearsal() public {
        if (bytes(vm.envOr("REHEARSAL", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        console.log("rehearsal at block", block.number, "timestamp", block.timestamp);

        // the exact file the operator will launch with: LAUNCH_CONFIG, as the scripts read it. a placeholder the file
        // leaves unset gets a rehearsal value, a placeholder it fills is rehearsed as it is
        string memory file = vm.envOr("LAUNCH_CONFIG", REHEARSAL_CONFIG_FILE);
        console.log("rehearsing the config file", file);
        c = loadConfig(file);
        if (c.owner == address(0)) c.owner = _user("owner");
        if (c.creator == address(0)) c.creator = _user("creator");
        if (c.payee == address(0)) c.payee = _user("payee");
        if (bytes(c.name).length == 0) c.name = "Rehearsal Coin";
        if (bytes(c.symbol).length == 0) c.symbol = "REH";
        if (c.salt == bytes32(0)) c.salt = keccak256("credits engine rehearsal");
        deployer = c.owner;
        trader = _user("trader");
        _stack();
        console.log("config hash");
        console.logBytes32(configHash(c));
        vm.deal(deployer, 5 ether);
        vm.deal(trader, 20 ether);

        _preflight();
        _deploy();
        postflightAs(c, d.core, deployer);
        _print("postflight after the launch");
        assertEq(_failedNames(), "", "postflight");
        _smoke();
    }

    /// @dev the v2 stack of the config. a file that leaves the stack at zero gets the live stack of
    /// script/config/v2-mainnet.json. the config owner is the factory owner and the deployer
    function _stack() internal {
        if (c.stack.factory != address(0)) {
            console.log("v2 stack from the config file, factory", c.stack.factory);
            return;
        }
        console.log("the config leaves the v2 stack at zero: the live stack of script/config/v2-mainnet.json");
        V2Stack.Stack memory v2 = V2Stack.live();
        c.stack.hook = v2.hook;
        c.stack.factory = v2.factory;
        c.stack.locker = v2.locker;
        c.stack.escrow = v2.escrow;
        c.mevModule = v2.mev;
    }

    /// @dev the metadata row fails on chain id 1 when the config's image and description do not pass the shared rule
    /// (blank, a placeholder marker, or an image without a scheme), as the rehearsal file does with its PLACEHOLDER
    /// values. it is the first row of the preflight table. uses the one rule in `script/Checks.sol`
    function _marked() internal view returns (bool) {
        return !metadataRowPasses(c.image, c.description);
    }

    function _metadataRowOnly() internal view returns (string memory) {
        return _marked() ? METADATA_ROW : "";
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
    }

    function _preflight() internal {
        // master launches need no factory owner command: the deployer is the factory owner, the simulate row passes
        // and the only expected failure is the metadata row when the config holds placeholder values
        preflight(c, deployer);
        _print("preflight");
        assertEq(_failedNames(), _metadataRowOnly(), "preflight");
    }

    /// @dev gas of one creation through the deterministic deployer, from a call frame of its own. the frame of the test
    /// holds the memory of the preflight, so a measurement inside it also pays the expansion of that memory
    function createGas(bytes memory init, bytes32 salt) external returns (uint256 used) {
        bytes memory data = abi.encodePacked(salt, init);
        uint256 g = gasleft();
        (bool ok,) = CREATE2_DEPLOYER.call(data);
        used = g - gasleft();
        require(ok, "create2 failed");
    }

    /// @dev gas of the six creations (the library, the core, the controller, the two adapters and the renderer) with
    /// the calldata and the intrinsic gas of their transactions, each from a clean frame
    function _creationGas(Deployed memory first) internal returns (uint256[6] memory tx_) {
        bytes32[6] memory salts = [
            bytes32(uint256(1)),
            CORE_SALT,
            CONTROLLER_SALT,
            SEAPORT_ADAPTER_SALT,
            STRATEGY_ADAPTER_SALT,
            rendererSalt(c)
        ];
        bytes[6] memory inits = [
            vm.getCode("CoreLib.sol:CoreLib"),
            coreInitCode(c, deployer),
            abi.encodePacked(vm.getCode("ControllerV1.sol:ControllerV1"), abi.encode(first.core, c.sale, c.credit, c.quote)),
            abi.encodePacked(
                vm.getCode("SeaportBasicAdapter.sol:SeaportBasicAdapter"), abi.encode(first.core, c.seaportRecipients)
            ),
            vm.getCode("CreditStrategyAdapter.sol:CreditStrategyAdapter"),
            abi.encodePacked(vm.getCode("CoinRenderer.sol:CoinRenderer"), abi.encode(c.owner))
        ];
        for (uint256 i; i < 6; ++i) {
            // 21000 intrinsic and the calldata (4 gas per zero byte, 16 per other byte)
            tx_[i] = this.createGas(inits[i], salts[i]) + 21_000 + _calldataGas(abi.encodePacked(salts[i], inits[i]));
        }
    }

    function _deploy() internal {
        uint256 balBefore = deployer.balance;
        // the linked library is deployed first, once, by the same deployer
        address lib = deployCode("CoreLib.sol:CoreLib");
        uint256 snap = vm.snapshotState();
        vm.startPrank(deployer);
        d = deploySystem(deployer, c);
        vm.stopPrank();
        uint256[10] memory used = stepGas;
        Deployed memory first = d;
        // the creations are measured again from a clean frame on the state before the deploy; the deploy then continues
        // from there (the contracts that exist are skipped)
        vm.revertToState(snap);
        uint256[11] memory txGas;
        {
            uint256[6] memory cg = _creationGas(first);
            for (uint256 i; i < 6; ++i) {
                txGas[i] = cg[i];
            }
        }
        vm.startPrank(deployer);
        d = deploySystem(deployer, c);
        vm.stopPrank();
        assertEq(d.core, first.core);
        assertEq(d.coin, first.coin);
        ICore core = ICore(payable(d.core));
        txGas[6] = used[5] + 21_000 + _calldataGas(abi.encodeCall(ICoinRenderer.setCore, (core)));
        txGas[7] = used[6] + 21_000 + _calldataGas(abi.encodeCall(core.setController, (d.controller)));
        txGas[8] = used[7] + 21_000 + _calldataGas(abi.encodeCall(core.addAdapter, (d.seaportAdapter)));
        txGas[9] = used[8] + 21_000 + _calldataGas(abi.encodeCall(core.addAdapter, (d.strategyAdapter)));
        txGas[10] = used[9] + 21_000
            + _calldataGas(abi.encodeCall(IArtCoinsFactoryV2.deployToken, (buildConfig(c, c.owner, d.core))));
        string[11] memory names = [
            "1 library CoreLib (create2 deployer)",
            "2 core (create2 deployer)",
            "3 controller (create2 deployer)",
            "4 seaport adapter (create2 deployer)",
            "5 strategy adapter (create2 deployer)",
            "6 coin renderer (create2 deployer)",
            "7 setCore on the renderer",
            "8 setController",
            "9 addAdapter seaport adapter",
            "10 addAdapter strategy adapter",
            "11 launch through the factory (deployToken)"
        ];
        uint256 total;
        for (uint256 i; i < 11; ++i) {
            total += txGas[i];
            console.log(string.concat("deploy gas, tx ", names[i]), txGas[i]);
            assertLt(txGas[i], TX_GAS_CAP, string.concat("over the per transaction gas cap: ", names[i]));
        }
        uint256 fee = IArtCoinsFactoryV2(c.stack.factory).deployFee();
        // the preflight balance row prices the deploy at this many gas: the measured total must fit under it
        assertLe(total, DEPLOY_GAS_ESTIMATE, "the measured deploy gas is above DEPLOY_GAS_ESTIMATE");
        console.log("DEPLOY_GAS_ESTIMATE", DEPLOY_GAS_ESTIMATE);
        console.log("library at", lib);
        console.log("total deploy gas, eleven transactions", total);
        console.log("per transaction gas cap", TX_GAS_CAP);
        console.log("factory deploy fee (wei, sent as value of tx 11)", fee);
        uint256[3] memory gwei_ = [uint256(1), 5, 20];
        for (uint256 i; i < 3; ++i) {
            uint256 cost = total * gwei_[i] * 1 gwei;
            console.log(
                string.concat("deployer needs at ", vm.toString(gwei_[i]), " gwei: gas ", _eth(cost), " eth, plus fee"),
                _eth(cost + fee)
            );
        }
        console.log("deployer paid wei (the fee only, the test gas price is 0)", balBefore - deployer.balance);
        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("renderer", d.renderer);
    }

    /// @dev wei as a decimal eth string with five places
    function _eth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1 ether;
        uint256 frac = (weiAmount % 1 ether) / 1e13;
        string memory f = vm.toString(frac);
        while (bytes(f).length < 5) {
            f = string.concat("0", f);
        }
        return string.concat(vm.toString(whole), ".", f);
    }

    /// @dev what a creation transaction costs beyond the measured constructor run: intrinsic 21000, the create 32000,
    /// 200 per byte of runtime code deposit, and the calldata of the creation code. the pranked `deployCode` of the
    /// measured steps does not meter the deposit, so it is added here
    function _createGas(string memory artifact) internal view returns (uint256) {
        return 21_000 + 32_000 + 200 * vm.getDeployedCode(artifact).length + _calldataGas(vm.getCode(artifact));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    // ------------------------------------------------------------------ smoke

    function _v4Swap(bool zeroForOne, uint256 amountIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        PoolKey memory k = d.launchKey;
        Currency cIn = zeroForOne ? k.currency0 : k.currency1;
        Currency cOut = zeroForOne ? k.currency1 : k.currency0;
        bytes[] memory params = new bytes[](3);
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(k, zeroForOne, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _smoke() internal {
        ICore core = ICore(payable(d.core));
        IArtCoinsTokenV2 coin = IArtCoinsTokenV2(d.coin);
        IUniversalRouterR ur = IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER);
        // past the anti sniper window, so the skim is the 6.9 point baseline
        vm.warp(block.timestamp + c.sniperSeconds + 1);

        uint256 pot = core.ethPot();
        uint256 bal = d.core.balance;
        vm.prank(trader);
        ur.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 bought = coin.balanceOf(trader);
        assertGt(bought, 0, "bought coin through the universal router");
        // the baseline skim of the config (bps of volume) times the bounty share of it
        uint256 want = uint256(1 ether) * c.baselineSkimBps / 10_000 * c.bountyBps / 10_000;
        assertEq(d.core.balance - bal, want, "the bounty share of the baseline skim reached the Core");
        assertEq(core.ethPot(), pot, "nothing reaches the pot before the book");
        address keeper = _user("keeper");
        uint256 payeeAtStart = c.payee.balance;
        vm.prank(keeper);
        core.book();
        assertEq(keeper.balance, 0, "the caller of book is paid nothing");
        // the book that starts the payee share shares nothing: the whole income splits by the fee share
        {
            uint256 reserve = want * c.settings.feeToRedeemBurnBps / 10_000;
            assertEq(core.ethPot() - pot, want - reserve, "the rest of the income reached the pot");
            assertEq(core.ethRedeemBurn(), reserve, "the redeem burn share reached the reserve");
            assertEq(
                core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn(),
                address(core).balance,
                "the tracked eth equals the balance"
            );
        }
        // the payee share starts with the first book after the window
        assertTrue(core.payeeOn(), "the first book after the window starts the payee share");
        assertEq(c.payee.balance, payeeAtStart, "that book pushed the payee nothing");

        uint256 deadBefore = coin.balanceOf(Mainnet.DEAD);
        uint256 sellIn = bought / 2;
        pot = core.ethPot();
        vm.startPrank(trader);
        coin.approve(Mainnet.PERMIT2, type(uint256).max);
        IPermit2R(Mainnet.PERMIT2).approve(d.coin, address(ur), uint160(sellIn), uint48(block.timestamp + 1 hours));
        uint256 ethBefore = trader.balance;
        ur.execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(trader.balance, ethBefore, "sold coin for eth");
        vm.prank(keeper);
        core.book();
        assertGt(core.ethPot(), pot, "the sell skim reached the pot too");
        assertEq(coin.balanceOf(Mainnet.DEAD), deadBefore, "no tax and no burn on canonical swaps");

        // payeePpm is 0 at launch (decision 120); the owner raises it, as it would later, to prove the push path
        _raisePayeePpm(core, c.owner, 90_909);
        // from the book after that the payee is pushed its parts per million of the fee income
        uint256 payee0 = c.payee.balance;
        bal = d.core.balance;
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        ur.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 gross = d.core.balance - bal;
        vm.prank(keeper);
        core.book();
        assertEq(c.payee.balance - payee0, gross * 90_909 / 1e6, "exactly its share pushed to the payee");

        _sellRealCredit(core);
    }

    /// finds a real credit held by an account without code and sells it into the bid
    /// the owner raises `payeePpm` to `v` (it is 0 at launch), in its own frame to keep `_rehearsal`'s stack shallow
    function _raisePayeePpm(ICore core_, address owner_, uint24 v) internal {
        Settings memory sp = core_.settings();
        sp.payeePpm = v;
        vm.prank(owner_);
        core_.setSettings(sp);
    }

    function _sellRealCredit(ICore core) internal {
        assertGt(core.ethPot(), 0, "the pot holds the fees");
        // the price state starts at the config rate. the read is clamped by a thin pot
        assertGe(core.ethPrice(), c.rateStart, "the price state never starts below the config start");
        ICredits credits = ICredits(Mainnet.CREDITS);
        uint256 cap = core.ethPot();
        for (uint256 id = 1; id < 2000; ++id) {
            address who;
            try credits.ownerOf(id) returns (address o) {
                who = o;
            } catch {
                continue;
            }
            if (who.code.length != 0 || core.ethRate() > cap) continue;
            // the per-point payout: the rate scaled by the credit's score over refScore (Core.bidOf, by hand)
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(credits.seedOf(id), credits.timestampOf(id));
            uint256 pay = (core.ethRate() * score) / RATE_SCORE;
            uint256 pot = core.ethPot();
            uint256 before = who.balance;
            vm.startPrank(who);
            credits.setApprovalForAll(address(core), true);
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            core.sellForEth(ids);
            vm.stopPrank();
            assertEq(credits.ownerOf(id), address(core), "the core holds the credit");
            assertEq(who.balance - before, pay, "the seller was paid the rate scaled by score over refScore");
            assertEq(pot - core.ethPot(), pay, "the pot paid it");
            assertEq(core.pileSize(), 1);
            console.log("sold credit", id, "for wei", pay);
            return;
        }
        revert("no sellable real credit found");
    }
}
