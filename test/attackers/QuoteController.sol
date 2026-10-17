// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IControllerReads {
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format);
    function atFloor(uint256 sid) external view returns (bool);
    function pastWindow(uint64 acquiredAt) external view returns (bool);
    function priceOf(uint256 sid) external view returns (uint256);
}

/// a controller stand in whose `valuePerPoint` answers whatever a test sets, so a test can prove the Core bounds a hostile
/// quote: a huge value pays at most `rateCap`, a zero value or a false flag halts the eth bid, and neither reaches the
/// balance bid or conversion. every other read is forwarded to the real controller, so redemptions and composes run
contract QuoteController {
    IControllerReads public immutable REAL;
    uint256 public value;
    bool public ok;

    constructor(address, address real) {
        REAL = IControllerReads(real);
    }

    function setValue(uint256 v, bool ok_) external {
        value = v;
        ok = ok_;
    }

    function valuePerPoint(bool) external view returns (uint256, bool) {
        return (value, ok);
    }

    function nextPage() external view returns (bool, uint256[80] memory, uint8) {
        return REAL.nextPage();
    }

    function atFloor(uint256 sid) external view returns (bool) {
        return REAL.atFloor(sid);
    }

    function pastWindow(uint64 acquiredAt) external view returns (bool) {
        return REAL.pastWindow(acquiredAt);
    }

    function priceOf(uint256 sid) external view returns (uint256) {
        return REAL.priceOf(sid);
    }
}
