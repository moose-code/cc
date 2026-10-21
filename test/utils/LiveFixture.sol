// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./Fixture.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IArtCoinsTokenV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";

/// @notice the owner rule of the phase 2 live fork work: a contract that exists on mainnet is bound at its live
/// address with its live code and state, never redeployed. this fixture forks mainnet at a recent pinned block and
/// binds the live Core, its live ControllerV1, its live coin and the live BALANCE token, so the phase 2 suites run
/// against the real system. only the phase 2 contracts that are not yet on mainnet (Phase2BalanceTreasury,
/// ProRataRedemptionPolicy, ControllerV2, the push split) are created fresh by the suites.
///
/// it reuses the `Fixture` helper surface: `_credits`, `_fundPot`, `_buyCoin`, `_composeOnce`, `_fillEthPile`,
/// `_setSettings`, `_setBalanceModule` and the rest read live mainnet contracts (the CreditStrategy, Credits,
/// Statements, the pool manager) exactly as they do on any mainnet fork, so binding the live Core in `setUp` is enough.
/// the helpers that only the fresh deploy path needs (`predictCoin`, `_launchCore`, `buildConfig`) read `lc`/`v2`,
/// which this fixture leaves unset; the phase 2 suites never call them.
///
/// the live BALANCE token carries an "ink" rule: a balance written by `deal` reverts (`EmptyInk`), so balances must
/// arrive by a real transfer or release. `_fundBalance` impersonates a real holder and transfers, the only way to
/// place live BALANCE on a test account or a fresh treasury.
abstract contract LiveFixture is Fixture {
    // ------------------------------------------------------------------ live mainnet addresses

    address internal constant LIVE_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    address internal constant LIVE_BALANCE_TOKEN = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant LIVE_SEAPORT_ADAPTER = 0x40302D497436bcC03e0Af2138Ec325C68DF3B0c8;
    address internal constant LIVE_STRATEGY_ADAPTER = 0x5757788D0A6dF507dba064d66532F0b630Be1dc9;
    address internal constant LIVE_RENDERER = 0x0D2022F8D780884A1B46de156CBfc4f36423504c;

    /// the live BALANCE token runtime code hash, asserted in `setUp` so a token that changed between pinning and the
    /// run fails loudly instead of running against the wrong code
    bytes32 internal constant LIVE_BALANCE_TOKEN_CODEHASH =
        0x83c6085628758fb522e28b5abb7c24253b6d8667a8b2b23d2c3542deabc25de7;

    /// @dev the pinned fork block, overridable by `LIVE_FORK_BLOCK`. post launch with the BALANCE token live and its
    /// ordinary transfers already open. re-pinned to a recent block before each owner send, since the public gateway
    /// serves state only within a proof window behind its head
    uint256 internal constant LIVE_FORK_BLOCK = 26242107;

    /// a real BALANCE holder, used by `_fundBalance` to place live tokens respecting the token's ink rule. an auction
    /// withdrawer seen in the launch logs; overridable by `LIVE_BALANCE_HOLDER`
    address internal constant LIVE_BALANCE_HOLDER = 0x5F7a8fb8cc29e795ba19191Dd74D69A90cDADB88;

    /// the live BALANCE token, the module's payout and conversion asset
    address internal liveBalanceToken;

    function setUp() public virtual override {
        uint256 forkBlock = vm.envOr("LIVE_FORK_BLOCK", LIVE_FORK_BLOCK);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        core = ICore(payable(LIVE_CORE));
        ctl = IControllerV1(core.controller());
        coin = IArtCoinsTokenV2(core.COIN());
        owner = core.owner();
        liveBalanceToken = LIVE_BALANCE_TOKEN;

        assertGt(LIVE_CORE.code.length, 0, "the live Core has code at the pin");
        assertGt(address(ctl).code.length, 0, "the live controller has code");
        assertGt(address(coin).code.length, 0, "the live coin has code");
        assertTrue(owner != address(0), "the live Core has an owner");
        assertGt(liveBalanceToken.code.length, 0, "the live BALANCE token has code");
        assertEq(
            liveBalanceToken.codehash, LIVE_BALANCE_TOKEN_CODEHASH, "the live BALANCE token runtime equals the pin"
        );

        // the launch adapters and the renderer the Core approves, bound live for the build identity checks
        seaportAdapter = LIVE_SEAPORT_ADAPTER;
        strategyAdapter = LIVE_STRATEGY_ADAPTER;
        renderer = LIVE_RENDERER;

        // namespaced accounts with no code on the fork, as the Fixture helpers expect
        deployer = _user("deployer");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        router = new TestSwapRouter();
        vm.deal(owner, owner.balance + 1 ether);

        // the live coin pool key (native eth / coin under the coin hook), the route `_buyCoin` and `_fundPot` swap
        launchKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        poolId = keccak256(abi.encode(launchKey));
        launchTime = block.timestamp;
    }

    // ------------------------------------------------------------------ live BALANCE funding (the ink rule)

    /// @notice places `amount` of live BALANCE on `to` by impersonating a real holder, the only way to fund an account
    /// or a fresh treasury: a balance written by `deal` reverts on this token (`EmptyInk`). transfers are open at the
    /// pin, so the holder's transfer passes the token's lock. the treasury reads `custody()` as its own token balance,
    /// so a transfer into it funds its working balance directly, the same as a mint on the stand in did
    function _fundBalance(address to, uint256 amount) internal {
        address holder = vm.envOr("LIVE_BALANCE_HOLDER", LIVE_BALANCE_HOLDER);
        require(IERC20Lite(liveBalanceToken).balanceOf(holder) >= amount, "the BALANCE holder is short for the test");
        vm.prank(holder);
        IERC20Lite(liveBalanceToken).transfer(to, amount);
    }

    /// @notice the balance of `who` in the live BALANCE token
    function _balanceOf(address who) internal view returns (uint256) {
        return IERC20Lite(liveBalanceToken).balanceOf(who);
    }

    // ------------------------------------------------------------------ live statements and credits

    /// @notice a Statement the live Core holds that the live controller finds eligible (`atFloor`), so a conversion
    /// through a selected treasury runs without composing a fresh page. the live Core holds a steady set of these at
    /// the pin; the first eligible one is returned
    function _eligibleHeldStatement() internal view returns (uint256 sid) {
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            if (ctl.atFloor(held[i])) return held[i];
        }
        revert("no eligible held Statement at the pin: re-pin LIVE_FORK_BLOCK");
    }
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}
