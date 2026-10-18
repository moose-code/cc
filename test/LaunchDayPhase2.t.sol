// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LaunchDayBase} from "./LaunchDay.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IBalanceModule} from "../src/interfaces/Interfaces.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice a launch day with the balance side on against Jack's pinned production contracts and the real
/// `StatementBalanceModule`: the renderer is registered, the funder retires the launch supply, a statement redeems once
/// transfers open, and a seller takes the balance bid. there is no dev-mock variant; the artifact from
/// `script/tools/upstream-balance.sh` is required (the test fails with the build instruction when it is absent).
contract LaunchDayPhase2Test is LaunchDayBase {
    /// @dev the balance pool sqrt the Seed post section and the e2e flows use (script/config/anvil.json .dev)
    uint160 internal constant DEV_SQRT = uint160(11318308930609191084791992905142);

    // promise: SPEC 4 the balance door against the pinned production module and Jack's token: the renderer is registered,
    // the funder retires the launch supply, a statement redeems once transfers open, and a seller then takes the balance bid.
    // the artifact comes from script/tools/upstream-balance.sh; the test fails with the build instruction when it is absent
    function test_phase2DayWithProductionModule() public {
        require(vm.exists("out/upstream-balance.json"), "run script/tools/upstream-balance.sh");
        (address token, address module, address funderWallet) = _deployProduction();
        IUpstreamToken up = IUpstreamToken(token);
        _registerAndRetire(up, funderWallet);

        // the module advertises nothing until a statement redeems into it and transfers open
        _skipSniperWindow();
        // fee income arrives unbooked through the hook; the keeper books once after the buys
        for (uint256 i; i < 4; ++i) _buyCoin(funder, 55 ether);
        assertEq(core.ethPot(), 0, "the buys leave the fees unbooked");
        _book();
        assertGe(core.ethPot(), 5 ether, "one keeper book funds the pot");
        assertEq(IBalanceModule(module).available(), 0, "no reserve before the first redemption");
        uint256 owed = _redeemAtOpening(up, IBalanceModule(module));
        _sellThroughModule(token, IBalanceModule(module), owed);
    }

    /// @dev the pinned upstream token and the StatementBalanceModule, wired the way test/UpstreamBalance.t.sol builds
    /// them, with the balance pool and the controller's pool key retargeted to the token
    function _deployProduction() internal returns (address token, address module, address funderWallet) {
        funderWallet = _user("phase2.upstreamFunder");
        bytes memory init = abi.encodePacked(
            vm.parseJsonBytes(vm.readFile("out/upstream-balance.json"), ".bytecode.object"),
            abi.encode(
                address(STATEMENTS),
                uint8(IUpstreamStatements(address(STATEMENTS)).formatCount()),
                funderWallet
            )
        );
        assembly ("memory-safe") {
            token := create(0, add(init, 32), mload(init))
        }
        require(token != address(0), "upstream deployment failed");
        module = vm.deployCode("StatementBalanceModule.sol:StatementBalanceModule", abi.encode(address(core), token));
        _setBalanceModule(module);
        _setSwitches(true, true);
        PM.initialize(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            DEV_SQRT
        );
        vm.prank(owner);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(token),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, DEV_SQRT), FixedPoint96.Q96, DEV_SQRT)
        );
    }

    /// @dev the upstream launch steps: the Statements owner registers the Balance renderer, then the funder surrenders
    /// a composed page and retires the launch supply
    function _registerAndRetire(IUpstreamToken up, address funderWallet) internal {
        IUpstreamStatements source = IUpstreamStatements(address(STATEMENTS));
        address renderer = up.renderer();
        vm.prank(source.owner());
        source.addFormat(renderer, "Balance");
        uint256[] memory ids = _credits(funderWallet, 80);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        vm.startPrank(funderWallet);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 funderSid = STATEMENTS.compose(page, 0);
        source.approve(address(up), funderSid);
        up.withdraw(funderSid, up.quote(funderSid));
        up.retireLaunchSupply();
        vm.stopPrank();
        assertEq(up.totalRetired(), up.launchRetirement(), "launch supply retired");
    }

    /// @dev composes and redeems one statement at the opening time; returns the token the module then holds
    function _redeemAtOpening(IUpstreamToken up, IBalanceModule module) internal returns (uint256 owed) {
        // close the credit sale so the fresh page composes without waiting out the sale window
        _setCreditSaleOn(false);
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        vm.warp(up.opensAt());
        owed = up.quote(sid);
        assertEq(owed, core.ratingOf(sid) * module.unitPerPoint(), "upstream quote is rating times unit");
        vm.prank(keeper);
        core.redeemStatement(sid);
        assertEq(module.available(), owed, "the redemption funds the module at par");
    }

    /// @dev the balance bid answers and pays through the real module
    function _sellThroughModule(address token, IBalanceModule module, uint256 owed) internal {
        uint256 id = _credits(seller, 1)[0];
        uint256 bid = core.balanceBidOf(id);
        assertGt(bid, 0, "the balance bid is live");
        assertLe(bid, _scoreOf(id) * module.unitPerPoint(), "the balance bid never exceeds par");
        uint256 before = IERC20Min(token).balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(_one(id));
        assertEq(IERC20Min(token).balanceOf(seller) - before, bid, "the balance fill equals balanceBidOf");
        assertEq(module.available(), owed - bid - bid * core.settings().buyToArtistBps / 10_000, "the module paid the fill and the artist royalty");
    }
}

interface IUpstreamToken {
    function renderer() external view returns (address);
    function quote(uint256) external view returns (uint256);
    function withdraw(uint256, uint256) external returns (uint256);
    function retireLaunchSupply() external;
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function opensAt() external view returns (uint64);
}

interface IUpstreamStatements {
    function owner() external view returns (address);
    function formatCount() external view returns (uint256);
    function addFormat(address, string calldata) external returns (uint8);
    function approve(address, uint256) external;
}
