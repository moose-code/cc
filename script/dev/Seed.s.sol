// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {CreditIds} from "../../test/utils/CreditIds.sol";
import {MockExitToken} from "../../test/standins/MockExitToken.sol";
import {MockExitModule} from "../../test/standins/MockExitModule.sol";

/// @notice seeds the local anvil fork after `script/deploy.sh local`. separate from the deploy. it
/// moves real Credits from the CreditStrategy to the scenario actors, deploys the exit token and exit module stand ins,
/// and initializes a native eth / exit token v4 pool at a cheap exit token price. it does NOT set the exit module, the
/// pool key or exitMode on the system: the scenario does that at its exit stage. it prints EXIT_TOKEN and EXIT_MODULE so
/// `script/dev/e2e.sh` can write them into deployments/31337.json.
///
/// env: A1 A2 A3 (actor addresses), N1 N2 N3 (credit counts, defaults 170 20 10), DEPLOYER (the sender that deploys the
/// stand ins), EXIT_UNIT (exit token base units per stored score unit, default 1e10).
contract Seed is Script {
    /// @dev credits the CreditStrategy lists for sale at the pin block, never handed out as plain credits
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;

    uint256 internal cursor;

    function run() external {
        address a1 = vm.envAddress("A1");
        address a2 = vm.envAddress("A2");
        address a3 = vm.envAddress("A3");
        uint256 n1 = vm.envOr("N1", uint256(170));
        uint256 n2 = vm.envOr("N2", uint256(20));
        uint256 n3 = vm.envOr("N3", uint256(10));
        address deployer = vm.envAddress("DEPLOYER");
        uint256 unit = vm.envOr("EXIT_UNIT", uint256(1e10));

        _move(a1, n1);
        _move(a2, n2);
        _move(a3, n3);
        console.log("seeded credits: A1", n1);
        console.log("seeded credits: A2", n2);
        console.log("seeded credits: A3", n3);

        vm.startBroadcast(deployer);
        MockExitToken xt = new MockExitToken("Exit Token", "XT");
        MockExitModule mod = new MockExitModule(address(xt), unit);
        vm.stopBroadcast();

        // native eth / exit token v4 pool, no hook, 0.3 percent fee, spacing 60. the sqrt price makes the exit token
        // cheap in eth (reuses the fixture `_setExitPoolFor` price), so the exit side value floor sits below the sale
        // curve. the scenario points the controller at this key at its exit stage
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.broadcast(deployer);
        IPoolManager(Mainnet.POOL_MANAGER).initialize(vk, uint160((uint256(1) << 96) * 1000));

        console.log("EXIT_TOKEN", address(xt));
        console.log("EXIT_MODULE", address(mod));
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
    }
}
