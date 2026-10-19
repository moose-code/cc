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
import {SettingsBounds} from "./SettingsBounds.sol";
import {CreditBounds} from "./CreditBounds.sol";

/// the hookData layout of an artcoins v2 swap: `mevModuleSwapData` carries the refund recipient of a partial fill (the
/// Core, which collects it through `collectEscrow`), `poolExtensionSwapData` is empty
struct SwapData {
    bytes mevModuleSwapData;
    bytes poolExtensionSwapData;
}

/// the Core's second linked library, run by delegatecall in the Core's storage: the pause transitions, setRate,
/// releaseRedeemBurn, removeAdapter, the credit setters, the three locks and the pool swap of buyback. the Core
/// wrappers keep the owner and reentrancy gates, so nothing here checks msg.sender
library CoreOpsLib {
    error BadSwap();
    error BadRate();
    error ZeroAmount();
    error BadSetting(bytes32 field);
    error BadController();
    error NoBalanceModule();
    event PausedSet(bool paused);
    event RateSet(uint256 rate);
    event RedeemBurnReleased(uint256 amount);
    event AdapterSet(address indexed adapter, bool allowed);
    event CreditCostToPotBpsSet(uint16 bps);
    event ChosenComposeOnSet(bool on);
    event MinCcToChooseSet(uint96 min);
    event ControllerLocked();
    event BalanceModuleLocked();
    event AdaptersLocked();

    /// the pause switch. on entry it stores the shared instance's climbed price state (the Core checkpoints the eth
    /// instance first) and records `pausedSince`. on resume every clock older than the pause (both peak times, the
    /// funded climb start, the shared instance's fill time) moves forward by the paused seconds, both checkpoints
    /// restart now and `pausedTotal` grows, so paused time is neither idle time nor decay time
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
            // the eth instance's fill time moves with its funded restart: the idle loosening anchors on the later of
            // the two, so leaving one behind would hand the ceiling the paused seconds
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

    /// restates the mode off eth price state and the funded climb clock at the owner's chosen level: the stored price
    /// state, the fill rate and the remembered peak become `rate`; the peak time, the checkpoint and the funded climb
    /// start become now
    function setRate(uint256 rate) external {
        State storage s = CoreLib.state();
        if (!SettingsBounds.rateInBounds(rate) || rate > s.settings.rateCap) revert BadRate();
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

    /// moves a capped amount from the redeem burn pot to the coin buyback pot
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

    /// executes the Core's eth to coin buyback swap inside the pool manager unlock callback. the settled eth includes
    /// the hook skim, and a partial fill's refund goes to the Core through hookData
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
