// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICreditScoreLens} from "../src/interfaces/ICreditScoreLens.sol";
import {ICredits, IStatements, ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";

interface ICreditScoreVerificationSource {
    function rarityOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
    function traitsOf(bytes21 seed, uint64 paidAt) external view returns (uint256, uint256, uint256, uint256, uint256);
}

/// @notice Check CreditScoreLens bytecode and all five views against their Ethereum mainnet sources.
/// @dev Read-only. Set LENS_ADDRESS to the deployed helper; no signer or broadcast is needed.
contract VerifyCreditScoreLens is Script {
    error UnsupportedChain(uint256 chainId);
    error CodeMismatch(address target);
    error ResultMismatch(string method);

    bytes32 private constant RUNTIME_HASH = 0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058;

    /// @notice Verify the deployed helper at LENS_ADDRESS and print its native-unit results.
    function run() external view {
        verify(vm.envAddress("LENS_ADDRESS"));
    }

    /// @notice Verify a helper's identity and compare its outputs with the deployed source contracts.
    /// @param helper The Ethereum mainnet CreditScoreLens address.
    function verify(address helper) public view {
        if (block.chainid != 1) revert UnsupportedChain(block.chainid);
        _code(helper, RUNTIME_HASH);
        if (keccak256(vm.getDeployedCode("CreditScoreLens.sol:CreditScoreLens")) != RUNTIME_HASH) {
            revert CodeMismatch(helper);
        }
        _code(Mainnet.CREDITS, 0x8ab17e09de9f492357738695c934fb72062a0f1aa0c66eaf388b3fcf659d57d4);
        _code(Mainnet.CREDIT_SCORE, 0xeea220f30cd748713b758d3cecf2a3c9e814381ace6d276390663d7e334ddf9d);
        _code(Mainnet.STATEMENTS, 0x6ea1df2fdef523d462711ac890c1be3df13badae863912f8453018251488f6ae);

        ICreditScoreLens lens = ICreditScoreLens(helper);
        ICredits credits = ICredits(Mainnet.CREDITS);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256[] memory scores = lens.creditScores(ids);
        if (scores.length != ids.length) revert ResultMismatch("creditScores length");
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 source =
                ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(credits.seedOf(ids[i]), credits.timestampOf(ids[i]));
            if (lens.creditScore(ids[i]) != source) revert ResultMismatch("creditScore");
            if (scores[i] != source) revert ResultMismatch("creditScores");
        }
        bytes21 seed = credits.seedOf(1);
        uint64 paidAt = credits.timestampOf(1);
        uint256 rarity = lens.creditRarity(1);
        if (rarity != ICreditScoreVerificationSource(Mainnet.CREDIT_SCORE).rarityOf(seed, paidAt)) {
            revert ResultMismatch("creditRarity");
        }
        _traits(lens, seed, paidAt);
        uint256 statementScore = lens.statementScore(1);
        if (statementScore != IStatements(Mainnet.STATEMENTS).creditScoreOf(1)) {
            revert ResultMismatch("statementScore");
        }
        console.log("Verified CreditScoreLens", helper);
        console.log("Mainnet block", block.number);
        console.log("creditScore(1)", scores[0]);
        console.log("creditScores([1,2,3])", scores[0], scores[1], scores[2]);
        console.log("creditRarity(1)", rarity);
        console.log("statementScore(1)", statementScore);
    }

    function _traits(ICreditScoreLens lens, bytes21 seed, uint64 paidAt) private view {
        (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band) = lens.creditTraits(1);
        (uint256 m, uint256 a, uint256 o, uint256 e, uint256 b) =
            ICreditScoreVerificationSource(Mainnet.CREDIT_SCORE).traitsOf(seed, paidAt);
        if (keccak256(abi.encode(mask, active, occupied, eights, band)) != keccak256(abi.encode(m, a, o, e, b))) {
            revert ResultMismatch("creditTraits");
        }
        console.log("creditTraits.mask", mask);
        console.log("creditTraits.active", active);
        console.log("creditTraits.occupied", occupied);
        console.log("creditTraits.eights", eights);
        console.log("creditTraits.band", band);
    }

    function _code(address target, bytes32 expected) private view {
        if (target.codehash != expected) revert CodeMismatch(target);
    }
}
