// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {ICredits, CreditSale, Settings, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";
import {MockBalanceToken} from "../../test/standins/MockBalanceToken.sol";
import {MockBalanceModule} from "../../test/standins/MockBalanceModule.sol";
import {TestLiquidityHelper} from "../../test/utils/TestLiquidityHelper.sol";

/// @notice seeds the anvil fork after `script/deploy.sh local`.
///
/// PHASE=pre moves real Credits from the CreditStrategy to A1, A2 and A3.
///
/// PHASE=post then deploys the balance token ("Balance") and `MockBalanceModule`, which mints `rating * unit` of the
/// token to the Core on `redeem`. The token is minted to the Core for the balance bid, a native eth / balance token v4
/// pool (hooks address zero, fee 3000, spacing 60) is initialized at `dev.balancePoolSqrtPriceX96` and given full range liquidity
/// by the trader. As owner it sets the module, books the token, switches `redeemOn` and `balanceBidOn` on, points the
/// controller at the pool, and switches the credit sale and chosen composition on.
///
/// pool price: the balance token is currency1, so the pool price is balance token base units per wei and
/// `sqrtPriceX96 = sqrt(price) * 2^96`. 100 points is 1,000,000 stored units, worth
/// `1,000,000 * dev.balanceUnitPerPoint` = 1e20 base units. At the opening bid `rateStart` = 4.9e15 wei,
/// `price = 1e20 / 4.9e15` = 20,408 and `sqrtPriceX96` = 11318308930609191084791992905142, so `valueOf` of a
/// 100 point credit equals the bid.
///
/// the dev wallet `dev.wallet` of the launch config also receives `dev.walletCredits` credits from the strategy in both
/// phases and, in post, `dev.walletBalance` of the balance token. its eth (`dev.walletEth`) is set by
/// `script/dev/e2e.sh` and its coin comes from the Scenario stage `dev-wallet`. a config without `dev.wallet` skips it.
///
/// env: A1 A2 A3, DEPLOYER (the owner), PHASE (pre or post, default post), and for post CORE and TRADER. optional
/// N1 N2 N3 (credits moved, default 330 10 10), LAUNCH_CONFIG (default script/config/anvil.json).
contract Seed is Script {
    /// @dev credits the CreditStrategy lists for sale at the pin block, skipped when credits are moved
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    /// @dev full range for tick spacing 60, the liquidity added, and the token and eth the trader provides for it
    int24 internal constant TICK_FULL = 887_220;
    uint256 internal constant LIQUIDITY = 1e21;
    uint256 internal constant LP_TOKENS = 1e24;
    uint256 internal constant LP_ETH = 10 ether;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;

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
        address trader = vm.envAddress("TRADER");

        vm.startBroadcast(owner);
        MockBalanceToken token = new MockBalanceToken("Balance", "BALANCE");
        MockBalanceModule module =
            new MockBalanceModule(address(token), vm.parseJsonUint(cfg, ".dev.balanceUnitPerPoint"));
        vm.stopBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.startBroadcast(trader);
        // the launch allocation mints to the module, which holds the balance token (the Core holds none)
        token.mint(address(module), vm.parseJsonUint(cfg, ".dev.balanceMintToModule"));
        token.mint(trader, LP_TOKENS);
        if (hasWallet) token.mint(wallet, vm.parseJsonUint(cfg, ".dev.walletBalance"));
        IPoolManager(Mainnet.POOL_MANAGER)
            .initialize(pool, uint160(vm.parseJsonUint(cfg, ".dev.balancePoolSqrtPriceX96")));
        TestLiquidityHelper lp = new TestLiquidityHelper();
        token.approve(address(lp), type(uint256).max);
        lp.modify{value: LP_ETH}(pool, -TICK_FULL, TICK_FULL, int256(LIQUIDITY));
        vm.stopBroadcast();

        IControllerV1 ctl = IControllerV1(core.controller());
        vm.startBroadcast(owner);
        core.setBalanceModule(address(module));
        Settings memory s = core.settings();
        s.redeemOn = true;
        s.balanceBidOn = true;
        core.setSettings(s);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(address(token)),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            })
        );
        ctl.setCredit(
            CreditSale({
                saleOn: true, window: ctl.creditWindow(), spreadBps: ctl.creditSpreadBps(), startBps: ctl.creditStartBps()
            })
        );
        core.setChosenComposeOn(true);
        vm.stopBroadcast();

        console.log("BALANCE_TOKEN", address(token));
        console.log("BALANCE_MODULE", address(module));
        console.log("module holding", token.balanceOf(address(module)));
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
