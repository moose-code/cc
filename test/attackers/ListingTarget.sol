// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a `buyListing` target that keeps the whole payment, burns `burn` gas and delivers the credit it holds
contract ListingTarget {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);

    function fill(uint256 id, uint256 burn) external payable {
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) {}
        CREDITS.transferFrom(address(this), msg.sender, id);
    }
}
