// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {IArtCoinsTokenV2} from "../../src/interfaces/ArtCoinsV2.sol";

/// a stranger holding coin that calls the Core's `buyback` and, in the same transaction, tries to spend the transfer
/// allowance the hook granted for the buyback's take. the Core is not on the allowlist, so the take consumes the whole allowance
contract LeftoverSpender {
    IArtCoinsTokenV2 public immutable COIN;
    ICore public immutable CORE;
    address public immutable POOL_MANAGER;
    uint256 public leftover;
    bool public spent;

    constructor(address coin_, address core_, address pm_) {
        COIN = IArtCoinsTokenV2(coin_);
        CORE = ICore(payable(core_));
        POOL_MANAGER = pm_;
    }

    function run(uint256 amount) external {
        CORE.buyback();
        leftover = COIN.transferAllowance();
        // a wallet to pool manager move is allowed only against that allowance
        try COIN.transfer(POOL_MANAGER, amount) returns (bool ok) {
            spent = ok;
        } catch {}
    }

    receive() external payable {}
}
