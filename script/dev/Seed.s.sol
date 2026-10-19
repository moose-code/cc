// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {ICredits, IStatements, CreditSale, Settings, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {StatementBalanceModule} from "../../src/adapters/StatementBalanceModule.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";

/// the ConversionLineageWithdrawals surface the production balance wiring reads from the pinned artifact.
interface IUpstreamToken {
    function renderer() external view returns (address);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
    function retireLaunchSupply() external;
    function opensAt() external view returns (uint64);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address renderer, string calldata name) external returns (uint8);
    function approve(address to, uint256 id) external;
}

/// @notice seeds the anvil fork after `script/deploy.sh local`.
///
/// PHASE=pre moves real Credits from the CreditStrategy to A1, A2 and A3.
///
/// PHASE=post then wires Jack's balance side from the pinned artifact `out/upstream-balance.json`
/// (`script/tools/upstream-balance.sh`), which is required: there is no mock fallback. It deploys Jack's
/// `ConversionLineageWithdrawals` through the deterministic CREATE2 factory, gives a funder 80 real Credits, registers the
/// Balance renderer as the Statements owner, has the funder compose a page, withdraw and retire the launch supply, then
/// deploys `StatementBalanceModule` and initializes a native eth / balance token v4 pool (hooks address zero, fee 3000,
/// spacing 60) at `dev.balancePoolSqrtPriceX96` with no trading depth (Jack's token reaches the module only through
/// redemptions, which the scenario drives). As owner it sets the module, switches `redeemOn` and `balanceBidOn` on,
/// points the controller at the pool, and switches the credit sale and chosen composition on.
///
/// pool price: the balance token is currency1, so the pool price is balance token base units per wei and
/// `sqrtPriceX96 = sqrt(price) * 2^96`. 100 points is 1,000,000 stored units, worth
/// `1,000,000 * dev.balanceUnitPerPoint` = 1e20 base units. At the opening bid `rateStart` = 4.65e15 wei,
/// `price = 1e20 / 4.65e15` is about 21,505 and `sqrtPriceX96` = 11618581461159793320010313039067, so `valueOf` of a
/// 100 point credit is approximately the bid.
///
/// the dev wallet `dev.wallet` of the launch config also receives `dev.walletCredits` credits from the strategy in both
/// phases. its eth (`dev.walletEth`) is set by `script/dev/e2e.sh` and its coin comes from the Scenario stage
/// `dev-wallet`. a config without `dev.wallet` skips it. Jack's balance token is not freely mintable, so the dev wallet
/// holds none; it receives balance token only by selling Credits into the balance bid.
///
/// env: A1 A2 A3, DEPLOYER (the owner), PHASE (pre or post, default post), and for post CORE and TRADER. optional
/// N1 N2 N3 (credits moved, default 330 10 10), LAUNCH_CONFIG (default script/config/anvil.json).
contract Seed is Script {
    /// @dev credits the CreditStrategy lists for sale at the pin block, skipped when credits are moved
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;

    /// the funder that surrenders a page and retires Jack's launch supply on the fork (production post only)
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;
    /// Arachnid's deterministic deployment proxy, present on the mainnet fork
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal cursor;

    function run() external {
        address owner = vm.envAddress("DEPLOYER");
        string memory cfg = vm.readFile(vm.envOr("LAUNCH_CONFIG", string("script/config/anvil.json")));
        bool hasWallet = vm.keyExistsJson(cfg, ".dev.wallet");
        address wallet = hasWallet ? vm.parseJsonAddress(cfg, ".dev.wallet") : address(0);
        _move(vm.envAddress("A1"), vm.envOr("N1", uint256(330)));
        _move(vm.envAddress("A2"), vm.envOr("N2", uint256(10)));
        _move(vm.envAddress("A3"), vm.envOr("N3", uint256(10)));
        if (hasWallet) _move(wallet, vm.parseJsonUint(cfg, ".dev.walletCredits"));
        if (keccak256(bytes(vm.envOr("PHASE", string("post")))) == keccak256("pre")) return;

        ICore core = ICore(payable(vm.envAddress("CORE")));
        uint160 poolSqrt = uint160(vm.parseJsonUint(cfg, ".dev.balancePoolSqrtPriceX96"));

        // the artifact is required: no mock fallback on the phase 2 path (owner directive)
        require(vm.exists("out/upstream-balance.json"), "run script/tools/upstream-balance.sh");
        console.log("== PRODUCTION MODULE (Seed post): Jack's pinned ConversionLineageWithdrawals ==");
        (address token, address module) = _deployProduction(owner, poolSqrt);

        IControllerV1 ctl = IControllerV1(core.controller());
        vm.startBroadcast(owner);
        core.setBalanceModule(module);
        Settings memory s = core.settings();
        s.redeemOn = true;
        // the balance bid opens after value mode (docs/RUNBOOK.md). ALLOW_MODE_OFF_BALANCE_BID=1 is the dev opt-in for
        // scenarios that sell for balance with value mode off
        s.balanceBidOn = vm.envOr("ALLOW_MODE_OFF_BALANCE_BID", false);
        core.setSettings(s);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            // the expected eth spot, wei per 1e18 base units, from the pool sqrt the script just initialized
            FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, poolSqrt), FixedPoint96.Q96, poolSqrt)
        );
        ctl.setCredit(
            CreditSale({
                saleOn: true, window: ctl.creditWindow(), spreadBps: ctl.creditSpreadBps(), startBps: ctl.creditStartBps()
            })
        );
        core.setChosenComposeOn(true);
        vm.stopBroadcast();

        // preflight: balance bid on, value mode off and a pool key set is the round trip hazard state
        Settings memory after_ = core.settings();
        require(
            !(after_.balanceBidOn && !after_.valueModeOn && ctl.balancePoolKeySet()),
            "preflight: balanceBidOn with value mode off and a pool key set"
        );

        console.log("BALANCE_TOKEN", token);
        console.log("BALANCE_MODULE", module);
        console.log("OPENS_AT", uint256(IUpstreamToken(token).opensAt()));
    }

    /// @dev Jack's `ConversionLineageWithdrawals` from the pinned artifact, wired the way the production-module test does:
    /// the funder receives 80 real Credits, the Statements owner registers the renderer, the funder composes a page,
    /// withdraws and retires the launch supply, then the module is deployed and the pool is initialized at the config
    /// sqrt with no trading depth (Jack's token reaches the module only through redemptions, which the scenario drives).
    /// the token is deployed through the deterministic CREATE2 factory so its address is the same in simulation and on
    /// the node under `--broadcast`.
    function _deployProduction(address owner, uint160 poolSqrt) internal returns (address token, address module) {
        _moveToFunder(80);

        bytes memory creation = vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object");
        uint8 format = uint8(IUpstreamStatements(Mainnet.STATEMENTS).formatCount());
        bytes memory init = abi.encodePacked(
            creation,
            abi.encode(
                Mainnet.STATEMENTS,
                format,
                FUNDER
            )
        );
        bytes32 salt = bytes32(0);
        token = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_PROXY, salt, keccak256(init))))));
        vm.broadcast(owner);
        (bool ok,) = CREATE2_PROXY.call(abi.encodePacked(salt, init));
        require(ok, "seed: token CREATE2 failed");
        require(token.code.length != 0, "seed: token not deployed at the computed address");

        address renderer = IUpstreamToken(token).renderer();
        vm.broadcast(IUpstreamStatements(Mainnet.STATEMENTS).owner());
        IUpstreamStatements(Mainnet.STATEMENTS).addFormat(renderer, "Balance");

        uint256[80] memory page;
        uint256[] memory ids = CREDITS.tokensOf(FUNDER);
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.broadcast(FUNDER);
        CREDITS.setApprovalForAll(Mainnet.STATEMENTS, true);
        vm.broadcast(FUNDER);
        uint256 funderSid = IStatements(Mainnet.STATEMENTS).compose(page, 0);
        vm.broadcast(FUNDER);
        IUpstreamStatements(Mainnet.STATEMENTS).approve(token, funderSid);
        uint256 q = IUpstreamToken(token).quote(funderSid);
        vm.broadcast(FUNDER);
        IUpstreamToken(token).withdraw(funderSid, q);
        vm.broadcast(FUNDER);
        IUpstreamToken(token).retireLaunchSupply();

        vm.broadcast(owner);
        module = address(new StatementBalanceModule(address(ICore(payable(vm.envAddress("CORE")))), token));

        vm.broadcast(owner);
        IPoolManager(Mainnet.POOL_MANAGER).initialize(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            poolSqrt
        );
        console.log("module holding starts at 0 until the first redemption");
    }

    /// @dev moves `n` real Credits from the strategy to the funder, skipping the strategy's listings
    function _moveToFunder(uint256 n) internal {
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            // the fork can sit past the CreditIds capture block, so some listed ids no longer exist; skip those and any
            // the strategy no longer holds
            try CREDITS.ownerOf(id) returns (address holder) {
                if (holder != STRATEGY) continue;
            } catch {
                continue;
            }
            vm.broadcast(STRATEGY);
            CREDITS.transferFrom(STRATEGY, FUNDER, id);
            ++got;
        }
    }

    /// @dev moves `n` real credits from the strategy to `to`, skipping the listed ids
    function _move(address to, uint256 n) internal {
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            if (CREDITS.ownerOf(id) != STRATEGY) continue;
            vm.broadcast(STRATEGY);
            CREDITS.transferFrom(STRATEGY, to, id);
            ++got;
        }
        console.log("seeded credits", to, n);
    }
}
