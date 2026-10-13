// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICreditScoreLensCredits {
    function seedOf(uint256 id) external view returns (bytes21);
    function timestampOf(uint256 id) external view returns (uint64);
}

interface ICreditScoreLensScorer {
    function scoreOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
    function rarityOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
    function traitsOf(bytes21 seed, uint64 paidAt)
        external
        view
        returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band);
}

interface ICreditScoreLensStatements {
    function creditScoreOf(uint256 id) external view returns (uint256);
}

/// @title CreditScoreLens
/// @notice Read credit scores, rarity, traits and statement scores by token id on Ethereum mainnet.
/// @dev Reads fixed Credits, CreditScore and Statements contracts. Holds no state or assets and has no admin.
///      Credit records remain readable after burn. Statement scores include overprinted pages and can change
///      when a page is overprinted. These reads do not establish current NFT ownership or redeemability.
contract CreditScoreLens {
    /// @dev A credit id has no mint record in Credits.
    /// @param creditId The unknown credit token id.
    error UnknownCredit(uint256 creditId);

    /// @dev Ethereum mainnet Credits. Mint records retain their seed and payment timestamp after burn.
    ICreditScoreLensCredits private constant CREDITS =
        ICreditScoreLensCredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
    /// @dev Ethereum mainnet CreditScore. Computes results from a credit's seed and payment timestamp.
    ICreditScoreLensScorer private constant CREDIT_SCORE =
        ICreditScoreLensScorer(0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7);
    /// @dev Ethereum mainnet Statements. Stores each page's total credit score, including overprints.
    ICreditScoreLensStatements private constant STATEMENTS =
        ICreditScoreLensStatements(0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b);

    /// @notice Get a credit's score, including a credit that has been burned.
    /// @dev Reverts with UnknownCredit(creditId) if the id was never minted. Source failures propagate.
    /// @param creditId The Credits token id.
    /// @return score Score in ten-thousandths of a point, from 800,000 to 8,000,000.
    ///         For example, 1,324,012 represents 132.4012 points.
    function creditScore(uint256 creditId) external view returns (uint256 score) {
        return _creditScore(creditId);
    }

    /// @notice Get credit scores in the input order, preserving duplicate ids.
    /// @dev Empty input returns an empty array. An unknown id or source failure reverts the entire call.
    ///      Work grows with the number of ids; callers must chunk requests to fit their RPC's call gas limit.
    /// @param creditIds The Credits token ids; burned credits are supported.
    /// @return scores Scores in ten-thousandths of a point, one entry per input id.
    function creditScores(uint256[] calldata creditIds) external view returns (uint256[] memory scores) {
        scores = new uint256[](creditIds.length);
        for (uint256 i = 0; i < creditIds.length; ++i) {
            scores[i] = _creditScore(creditIds[i]);
        }
    }

    /// @notice Get the sum of a credit's rarity trait points from CreditScore.
    /// @dev This is the source's raw rarity value, not a percentile or its 80-to-800 point score.
    ///      Reverts with UnknownCredit(creditId) if the id was never minted. Source failures propagate.
    /// @param creditId The Credits token id; burned credits are supported.
    /// @return rarity The sum of the source's trait points, including its doubled eights contribution.
    function creditRarity(uint256 creditId) external view returns (uint256 rarity) {
        (bytes21 seed, uint64 paidAt) = _creditInputs(creditId);
        return CREDIT_SCORE.rarityOf(seed, paidAt);
    }

    /// @notice Get the five traits used by CreditScore to compute a credit's rarity and score.
    /// @dev Returns the source's numeric values unchanged. Reverts with UnknownCredit(creditId) if the id
    ///      was never minted. Source failures propagate.
    /// @param creditId The Credits token id; burned credits are supported.
    /// @return mask The active plate bitmask, from 1 to 15.
    /// @return active The number of inked bits across the active plates.
    /// @return occupied The number of distinct inked raster cells after plate misregistration.
    /// @return eights The number of ASCII '8' characters in the credit's seed.
    /// @return band Registration band: 0 Registered, 1 Nudge, 2 Slip, 3 Skew, 4 Drift, 5 Loose.
    function creditTraits(uint256 creditId)
        external
        view
        returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band)
    {
        (bytes21 seed, uint64 paidAt) = _creditInputs(creditId);
        return CREDIT_SCORE.traitsOf(seed, paidAt);
    }

    /// @notice Get a statement's stored total credit score, including all overprinted pages.
    /// @dev Forwards Statements.creditScoreOf. Never-composed ids return zero. A page burned into another
    ///      page retains its historical score. Reads the current stored total, not an average or ownership check.
    ///      Source failures propagate.
    /// @param statementId The Statements token id.
    /// @return score Total score in ten-thousandths of a point. It may exceed a single credit's score range.
    function statementScore(uint256 statementId) external view returns (uint256 score) {
        return STATEMENTS.creditScoreOf(statementId);
    }

    /// @dev Reuse the same credit scoring path for single and batch reads.
    function _creditScore(uint256 creditId) private view returns (uint256) {
        (bytes21 seed, uint64 paidAt) = _creditInputs(creditId);
        return CREDIT_SCORE.scoreOf(seed, paidAt);
    }

    /// @dev Mint requires a nonzero timestamp; burn retains it. This checks historical existence without ownerOf.
    function _creditInputs(uint256 creditId) private view returns (bytes21 seed, uint64 paidAt) {
        paidAt = CREDITS.timestampOf(creditId);
        if (paidAt == 0) revert UnknownCredit(creditId);
        seed = CREDITS.seedOf(creditId);
    }
}
