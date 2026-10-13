// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IBalanceModule, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./ScriptedController.sol";
import {MockBalanceToken} from "../standins/MockBalanceToken.sol";

/// a scripted controller that can also sell: it is the one address `sellTo` accepts once the owner installs it. it
/// forwards a sale as it is told and can try the sale twice or from inside a reentry
contract SellingController is ScriptedController {
    ICore public immutable CORE;
    bool public lastOk;
    bytes public lastWhy;

    constructor(ICore core_) {
        CORE = core_;
    }

    receive() external payable {}

    function sell(uint256 sid, address buyer) external payable {
        CORE.sellTo{value: msg.value}(sid, buyer);
    }

    /// sells, then tries the same statement again and a second statement with the rest of the value. records what the
    /// second call did
    function sellTwice(uint256 sid, address buyer, uint256 first, uint256 second) external payable {
        CORE.sellTo{value: first}(sid, buyer);
        try CORE.sellTo{value: second}(sid, buyer) {
            lastOk = true;
        } catch (bytes memory why) {
            lastOk = false;
            lastWhy = why;
        }
    }
}

/// a buyer of a statement through the controller that tries to re enter on the refund of its excess
contract ReentrantBuyer {
    IControllerV1 public immutable CTL;
    ICore public immutable CORE;
    /// the statement the reentry tries to buy
    uint256 public other;
    uint256 public reentries;
    bool public buyBlocked;
    bool public sellBlocked;
    bool public redeemBlocked;
    bytes4 public buySel;

    constructor(IControllerV1 ctl_, ICore core_) {
        CTL = ctl_;
        CORE = core_;
    }

    function setOther(uint256 other_) external {
        other = other_;
    }

    function buy(uint256 sid) external payable {
        CTL.buy{value: msg.value}(sid);
    }

    receive() external payable {
        if (reentries++ != 0) return;
        try CTL.buy{value: address(this).balance}(other) {}
        catch (bytes memory why) {
            buyBlocked = true;
            buySel = bytes4(why);
        }
        try CORE.sellTo{value: 0}(other, address(this)) {}
        catch {
            sellBlocked = true;
        }
        try CORE.redeemStatement(other) {}
        catch {
            redeemBlocked = true;
        }
        try CORE.skim() {} catch {}
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// a buyer that cannot take an eth refund
contract RefundRefuser {
    IControllerV1 public immutable CTL;

    constructor(IControllerV1 ctl_) {
        CTL = ctl_;
    }

    function buy(uint256 sid) external payable {
        CTL.buy{value: msg.value}(sid);
    }

    receive() external payable {
        revert("no refunds");
    }
}

/// a balance module that behaves like the stand in (pays rating times unit) and can burn gas or call out while the core
/// is inside `redeemStatement`. the call out is how a hostile module tries the core and the controller mid redemption
contract HostileModule is IBalanceModule {
    address public immutable balanceToken;
    uint256 public unit;
    /// gas to burn inside `redeem`
    uint256 public burn;
    /// a target and calldata to call inside `redeem`, and what happened
    address public target;
    bytes public data;
    bool public called;
    bool public calledOk;
    bytes public calledOut;
    /// pay this share of the owed amount, bps
    uint256 public payBps = 10_000;

    constructor(address balanceToken_, uint256 unit_) {
        balanceToken = balanceToken_;
        unit = unit_;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function setBurn(uint256 gas_) external {
        burn = gas_;
    }

    function setPayBps(uint256 bps) external {
        payBps = bps;
    }

    function setCall(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function redeem(uint256 sid) external returns (uint256 out) {
        uint256 rating = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid);
        out = rating * unit * payBps / 10_000;
        MockBalanceToken(balanceToken).mint(msg.sender, out);
        if (target != address(0)) {
            called = true;
            (calledOk, calledOut) = target.call(data);
        }
        uint256 end = gasleft() > burn ? gasleft() - burn : 0;
        // forge-lint: disable-next-line(asm-keccak256)
        while (gasleft() > end && burn != 0) {}
    }
}

/// the caller of `redeemStatement` that is repaid in eth and tries every door of the core from its `receive`
contract RepaidCaller {
    ICore public immutable CORE;
    uint256 public other;
    uint256 public hits;
    uint256 public blocked;
    uint256 public ok;
    uint256 public repaid;

    constructor(ICore core_) {
        CORE = core_;
    }

    function redeem(uint256 sid, uint256 other_) external {
        other = other_;
        CORE.redeemStatement(sid);
    }

    function compose(uint256 other_) external {
        other = other_;
        CORE.compose();
    }

    function _try(bytes memory data) private {
        (bool success, bytes memory out) = address(CORE).call(data);
        if (success) {
            ok++;
        } else if (out.length >= 4 && bytes4(out) == bytes4(0xab143c06)) {
            blocked++;
        }
    }

    receive() external payable {
        repaid += msg.value;
        if (hits++ != 0) return;
        _try(abi.encodeCall(ICore.redeemStatement, (other)));
        _try(abi.encodeWithSignature("compose()"));
        _try(abi.encodeCall(ICore.skim, ()));
        _try(abi.encodeCall(ICore.buyback, ()));
    }
}
