// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HandlerBase, Wiring} from "./HandlerBase.sol";
import {HandlerSale} from "./HandlerSale.sol";

/// @notice the handler of the invariant suites: the pool, credit, compose, exit and buyback actions of `HandlerBase`,
/// the adversarial owner of `HandlerOwner` and the sale and owner door actions of `HandlerSale`. `Wiring` is declared
/// next to the base
contract Handler is HandlerSale {
    constructor(Wiring memory w) HandlerBase(w) {}
}
