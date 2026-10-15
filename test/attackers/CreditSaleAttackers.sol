// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICoreCreditSale {
    function sellCreditTo(uint256 id, address buyer) external payable;
}

interface IControllerCreditSale {
    function buyCredit(uint256 id) external payable;
}

/// a controller stand in that calls the core's `sellCreditTo` with whatever value a test gives it, so a test can prove
/// the core's own hard floor holds when the controller quotes below a credit's cost. the owner points the core at it
contract LowballCreditController {
    ICoreCreditSale public immutable CORE;

    constructor(address core) {
        CORE = ICoreCreditSale(core);
    }

    /// sell credit `id` to `buyer` forwarding `msg.value`, however small
    function sell(uint256 id, address buyer) external payable {
        CORE.sellCreditTo{value: msg.value}(id, buyer);
    }

    /// answers the core's controller probe. the pile is never composed through this stand in, so no page is ready
    function nextPage() external pure returns (bool ready, uint256[80] memory ids, uint8 format) {}

    receive() external payable {}
}

/// a buyer that reenters `buyCredit` from its eth refund callback. the controller's guard must refuse the second call,
/// so the whole purchase reverts
contract ReentrantCreditBuyer {
    IControllerCreditSale public immutable CTL;
    uint256 public reenterId;
    bool public armed;

    constructor(address controller) {
        CTL = IControllerCreditSale(controller);
    }

    function arm(uint256 id) external {
        reenterId = id;
        armed = true;
    }

    function buy(uint256 id, uint256 pay) external {
        CTL.buyCredit{value: pay}(id);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            CTL.buyCredit{value: msg.value}(reenterId);
        }
    }
}
