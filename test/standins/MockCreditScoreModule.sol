// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// test double for the controller's credit score module. answers `scoreOf(uint256)` with a per id score, in the stored
/// score units the engine uses for statement ratings. it can revert or burn its gas to test the controller's bounded read
contract MockCreditScoreModule {
    mapping(uint256 => uint256) internal _score;
    bool public doRevert;
    bool public burn;

    function set(uint256 id, uint256 score) external {
        _score[id] = score;
    }

    function setRevert(bool on) external {
        doRevert = on;
    }

    function setBurn(bool on) external {
        burn = on;
    }

    function scoreOf(uint256 id) external view returns (uint256) {
        if (doRevert) revert();
        if (burn) while (true) {}
        return _score[id];
    }
}
