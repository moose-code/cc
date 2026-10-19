// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CoreLib, State} from "./CoreLib.sol";
import {Settings} from "../interfaces/Interfaces.sol";
import {SettingsBounds} from "./SettingsBounds.sol";
import {CreditBounds} from "./CreditBounds.sol";

/// The v2 hook refunds skim from a partially filled buyback swap to this Core.
struct SwapData {
    bytes mevModuleSwapData;
    bytes poolExtensionSwapData;
}

/// Delegated Core operations kept outside the size-constrained Core and pricing library.
library CoreOpsLib {
    error BadSwap();
    error BadRate();
    error ZeroAmount();
    error BadSetting(bytes32 field);
    error BadController();
    error NoBalanceModule();
    event PausedSet(bool paused);
    event RateSet(uint256 rate);
    event SettingsSet(Settings settings);
    event RedeemBurnReleased(uint256 amount);
    event AdapterSet(address indexed adapter, bool allowed);
    event CreditCostToPotBpsSet(uint16 bps);
    event ChosenComposeOnSet(bool on);
    event MinCcToChooseSet(uint96 min);
    event ControllerLocked();
    event BalanceModuleLocked();
    event AdaptersLocked();

    /// Freezes intake, composition, sales, Credit swaps and buybacks, then restarts both bid clocks on resume.
    /// The Core checkpoints the active ETH rate before calling this on pause entry.
    function setPaused(bool on) external {
        State storage s = CoreLib.state();
        if (on == s.paused) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 t = uint40(block.timestamp);
        if (on) {
            if (s.settings.valueModeOn) {
                s.balance.rateAtCheckpoint = IPauseRead(address(this)).sharedRate();
                s.balance.checkpointTime = t;
            }
            s.paused = true;
            s.pausedSince = t;
        } else {
            uint64 since = s.pausedSince;
            uint40 elapsed = t - s.pausedSince;
            uint64 ethPeak = s.anchor.peakTime;
            uint64 balancePeak = s.balance.anchor.peakTime;
            uint64 climbStart = s.climbRestartTime;
            uint64 ethFill = s.lastFillTime;
            uint64 balanceFill = s.balance.lastFillTime;
            s.anchor.peakTime = ethPeak < since ? ethPeak + elapsed : t;
            s.balance.anchor.peakTime = balancePeak < since ? balancePeak + elapsed : t;
            s.climbRestartTime = climbStart < since ? climbStart + elapsed : t;
            s.lastFillTime = ethFill < since ? ethFill + elapsed : t;
            s.balance.lastFillTime = balanceFill < since ? balanceFill + elapsed : t;
            s.paused = false;
            s.pausedTotal += elapsed;
            s.pausedSince = 0;
            s.checkpointTime = t;
            s.balance.checkpointTime = t;
        }
        emit PausedSet(on);
    }

    /// Restates the mode-off ETH rate and funded climb clock at the owner's chosen level.
    function setRate(uint256 rate) external {
        State storage s = CoreLib.state();
        if (!SettingsBounds.rateInBounds(rate) || rate > s.settings.rateCap) revert BadRate();
        _resetRate(s, rate);
    }

    /// restates the opening reference, its 3x cap and the live bid before the coin exists
    function setOpeningRate(uint256 rate) external {
        State storage s = CoreLib.state();
        if (!SettingsBounds.rateInBounds(rate) || rate > type(uint64).max / 3) revert BadRate();
        s.openingRate = rate;
        s.settings.rateCap = uint64(rate * 3);
        _resetRate(s, rate);
        emit SettingsSet(s.settings);
    }

    function _resetRate(State storage s, uint256 rate) private {
        s.anchor.lastFillRate = rate;
        s.anchor.peakRate = rate;
        // forge-lint: disable-start(unsafe-typecast)
        s.anchor.peakTime = uint64(block.timestamp);
        s.rateAtCheckpoint = rate;
        s.checkpointTime = uint64(block.timestamp);
        s.climbRestartTime = uint64(block.timestamp);
        // forge-lint: disable-end(unsafe-typecast)
        emit RateSet(rate);
    }

    /// Moves a capped amount from the redeem burn pot to the coin buyback pot.
    function releaseRedeemBurn(uint256 amount) external {
        State storage s = CoreLib.state();
        uint256 pot = s.ethRedeemBurn;
        uint256 move = amount < pot ? amount : pot;
        if (move == 0) revert ZeroAmount();
        s.ethRedeemBurn = pot - move;
        s.ethToBuyback += move;
        emit RedeemBurnReleased(move);
    }

    function removeAdapter(address a) external {
        CoreLib.state().allowedAdapter[a] = false;
        emit AdapterSet(a, false);
    }

    function setCreditCostToPotBps(uint16 v) external {
        if (!CreditBounds.costToPotBpsOk(v)) revert BadSetting("creditCostToPotBps");
        CoreLib.state().creditCostToPotBps = v;
        emit CreditCostToPotBpsSet(v);
    }

    function setChosenComposeOn(bool v) external {
        CoreLib.state().chosenComposeOn = v;
        emit ChosenComposeOnSet(v);
    }

    function setMinCcToChoose(uint96 v) external {
        CoreLib.state().minCcToChoose = v;
        emit MinCcToChooseSet(v);
    }

    function lockController() external {
        State storage s = CoreLib.state();
        if (s.controller == address(0)) revert BadController();
        s.controllerLocked = true;
        emit ControllerLocked();
    }

    function lockBalanceModule() external {
        State storage s = CoreLib.state();
        if (s.balanceModule == address(0)) revert NoBalanceModule();
        s.balanceModuleLocked = true;
        emit BalanceModuleLocked();
    }

    function lockAdapters() external {
        CoreLib.state().adaptersLocked = true;
        emit AdaptersLocked();
    }

    /// Executes the Core's canonical ETH-to-coin buyback swap inside the pool manager unlock callback.
    /// The settled ETH includes hook skim, and a partial fill's refund goes to the Core through hookData.
    function swapIn(address manager, address coin, uint24 fee, int24 spacing, address hook, uint256 amountIn)
        external
        returns (uint256 owed, uint256 bought)
    {
        IPoolManager pm = IPoolManager(manager);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        bytes memory hookData =
            abi.encode(SwapData({mevModuleSwapData: abi.encode(address(this)), poolExtensionSwapData: ""}));
        // forge-lint: disable-start(unsafe-typecast)
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookData
        );
        if (d.amount0() > 0 || d.amount1() < 0) revert BadSwap();
        owed = uint256(uint128(-d.amount0()));
        if (owed > amountIn) revert BadSwap();
        pm.settle{value: owed}();
        bought = uint256(uint128(d.amount1()));
        pm.take(key.currency1, address(this), bought);
        // forge-lint: disable-end(unsafe-typecast)
    }
}

interface IPauseRead {
    function sharedRate() external view returns (uint256);
}
