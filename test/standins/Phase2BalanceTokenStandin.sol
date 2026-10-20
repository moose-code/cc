// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Mainnet} from "../../src/interfaces/Interfaces.sol";

interface IStandinStatements {
    function creditScoreOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function getApproved(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface IStandinReentrant {
    function onTransfer(address to, uint256 amount) external;
}

/// stand in for the InterfaceAuctionWithdrawals balance token: a mintable erc20 with the two upstream gates the phase 2
/// treasury reads (finalized retirement for a withdrawal, funding phase 3 and the open block for ordinary transfers),
/// a `quote`/`withdraw` that takes the statement and mints its rating times the unit to the caller, and fault modes for
/// the payment paths. the token's own transfers (from itself) pass the lock as upstream does
contract Phase2BalanceTokenStandin is ERC20 {
    uint256 public constant SCORE_TO_TOKEN = 1e14;
    uint256 public constant launchRetirement = 2_386_7072 * 1e14;
    address public statements = Mainnet.STATEMENTS;
    uint8 private _decimals = 18;
    bool public ready = true;
    uint256 public totalRetired;
    uint8 public fundingPhase;
    uint64 public transfersOpenBlock;
    /// base units withheld from a withdrawal, to test the receipt rule
    uint256 public shortfall;
    /// 0 normal, 1 moves half then returns false, 2 reverts, 3 moves nothing and returns no data, 4 moves all then
    /// returns false, 5 moves nothing and returns true
    uint8 public mode;
    /// called inside every transfer when set, to test reentry
    address public reentrant;
    /// a recipient the token refuses
    address public banned;

    function name() public pure override returns (string memory) {
        return "Balances";
    }

    function symbol() public pure override returns (string memory) {
        return "BALANCE";
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ------------------------------------------------------------------ test controls

    function configure(address source, uint8 precision) external {
        statements = source;
        _decimals = precision;
    }

    function setReady(bool v) external {
        ready = v;
    }

    /// finalizes retirement (`retired` true) and opens or closes ordinary transfers
    function setGates(bool retired, uint8 phase, uint64 openBlock) external {
        totalRetired = retired ? launchRetirement : 0;
        fundingPhase = phase;
        transfersOpenBlock = openBlock;
    }

    /// everything open from this block
    function open() external {
        totalRetired = launchRetirement;
        fundingPhase = 3;
        transfersOpenBlock = uint64(block.number);
    }

    function setShortfall(uint256 v) external {
        shortfall = v;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setReentrant(address r) external {
        reentrant = r;
    }

    function setBanned(address a) external {
        banned = a;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // ------------------------------------------------------------------ the upstream surface

    function quote(uint256 id) public view returns (uint256) {
        return IStandinStatements(statements).creditScoreOf(id) * SCORE_TO_TOKEN;
    }

    /// takes the statement from the caller (the caller approved this token for it) and mints the quote less the
    /// shortfall. refused before retirement is finalized, as upstream `_checkWithdrawal`
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256 amount) {
        require(ready, "renderer not registered");
        require(totalRetired == launchRetirement, "launch supply not finalized");
        IStandinStatements source = IStandinStatements(statements);
        require(source.ownerOf(id) == msg.sender, "not statement owner");
        require(source.getApproved(id) == address(this), "statement not approved");
        require(expectedAmount == quote(id), "quote changed");
        source.safeTransferFrom(msg.sender, address(this), id);
        amount = expectedAmount - shortfall;
        _mint(msg.sender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ transfers under the gate and the fault modes

    function _locked(address from) private view returns (bool) {
        if (from == address(this) || from == address(0)) return false;
        return totalRetired != launchRetirement || fundingPhase != 3 || block.number < transfersOpenBlock;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!_locked(msg.sender), "transfers locked");
        if (to == banned) revert("banned recipient");
        if (mode == 2) revert("transfer reverts");
        if (mode == 3) {
            assembly {
                return(0, 0)
            }
        }
        uint256 moved = mode == 1 ? amount / 2 : (mode == 5 ? 0 : amount);
        if (moved != 0) super.transfer(to, moved);
        if (reentrant != address(0)) IStandinReentrant(reentrant).onTransfer(to, amount);
        return mode == 0 || mode == 5;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!_locked(from), "transfers locked");
        return super.transferFrom(from, to, amount);
    }
}
