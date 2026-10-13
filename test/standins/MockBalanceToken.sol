// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// plain mintable erc20 for tests.
contract MockBalanceToken is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// 0 transfers, 1 reverts, 2 returns false without moving anything
    uint8 public transferMode;

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferMode == 1) revert("transfer refused");
        if (transferMode == 2) return false;
        return super.transfer(to, amount);
    }

    /// mints to any address.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
