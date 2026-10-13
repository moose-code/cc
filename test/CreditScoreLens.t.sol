// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ICreditScoreLens} from "../src/interfaces/ICreditScoreLens.sol";
import {ICredits, IStatements, ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {DeployCreditScoreLens} from "../script/DeployCreditScoreLens.s.sol";

interface IScoreSource {
    function rarityOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
    function traitsOf(bytes21 seed, uint64 paidAt) external view returns (uint256, uint256, uint256, uint256, uint256);
}

interface ICreditRecords {
    function supply() external view returns (uint256);
    function isSealed() external view returns (bool);
    function burn(address holder, uint256[] calldata ids) external returns (bytes21[] memory);
}

interface IStatementRecords {
    function composedFrom(uint256 id) external view returns (uint32[80] memory);
    function score() external view returns (address);
    function overprint(uint256 baseId, uint256 topId) external;
}

contract CreditScoreLensTest is Test {
    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IScoreSource private constant SCORER = IScoreSource(Mainnet.CREDIT_SCORE);
    ICreditScoreLens private lens;

    function setUp() public {
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(26158000));
        require(blockNumber == 26158000, "test source pin");
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), blockNumber);
        assertEq(
            Mainnet.CREDITS.codehash,
            0x8ab17e09de9f492357738695c934fb72062a0f1aa0c66eaf388b3fcf659d57d4,
            "Credits source"
        );
        assertEq(
            Mainnet.CREDIT_SCORE.codehash,
            0xeea220f30cd748713b758d3cecf2a3c9e814381ace6d276390663d7e334ddf9d,
            "CreditScore source"
        );
        assertEq(
            Mainnet.STATEMENTS.codehash,
            0x6ea1df2fdef523d462711ac890c1be3df13badae863912f8453018251488f6ae,
            "Statements source"
        );
        assertTrue(ICreditRecords(Mainnet.CREDITS).isSealed());
        assertEq(IStatementRecords(Mainnet.STATEMENTS).score(), Mainnet.CREDIT_SCORE);
        lens = ICreditScoreLens(vm.deployCode("CreditScoreLens.sol:CreditScoreLens"));
    }

    function _assertCredit(uint256 id) private view {
        bytes21 seed = CREDITS.seedOf(id);
        uint64 paidAt = CREDITS.timestampOf(id);
        uint256 score = lens.creditScore(id);
        assertEq(score, ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(seed, paidAt));
        assertGe(score, 800_000);
        assertLe(score, 8_000_000);
        assertEq(lens.creditRarity(id), SCORER.rarityOf(seed, paidAt));
        (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band) = lens.creditTraits(id);
        (uint256 m, uint256 a, uint256 o, uint256 e, uint256 b) = SCORER.traitsOf(seed, paidAt);
        assertEq(mask, m);
        assertEq(active, a);
        assertEq(occupied, o);
        assertEq(eights, e);
        assertEq(band, b);
    }

    function test_creditOneRetainsFractionalScore() public view {
        assertEq(lens.creditScore(1), 1_324_012);
        _assertCredit(1);
    }

    function testFuzz_creditResultsEqualSource(uint256 rawId) public view {
        _assertCredit(bound(rawId, 1, ICreditRecords(Mainnet.CREDITS).supply()));
    }

    function test_burnedCreditRemainsReadable() public {
        uint32[80] memory ids = IStatementRecords(Mainnet.STATEMENTS).composedFrom(1);
        vm.expectRevert();
        CREDITS.ownerOf(ids[0]);
        _assertCredit(ids[0]);
    }

    function test_transferAndBurnPreserveCreditResults() public {
        uint256 id = CreditIds.at(0);
        uint256 score = lens.creditScore(id);
        uint256 rarity = lens.creditRarity(id);
        bytes32 traits = _traitsHash(id);
        address holder = makeAddr("CreditScoreLens credit holder");
        address previous = CREDITS.ownerOf(id);
        vm.prank(previous);
        CREDITS.transferFrom(previous, holder, id);
        _assertCredit(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(holder);
        ICreditRecords(Mainnet.CREDITS).burn(holder, ids);
        vm.expectRevert();
        CREDITS.ownerOf(id);
        _assertCredit(id);
        assertEq(lens.creditScore(id), score);
        assertEq(lens.creditRarity(id), rarity);
        assertEq(_traitsHash(id), traits);
    }

    function _traitsHash(uint256 id) private view returns (bytes32) {
        (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band) = lens.creditTraits(id);
        return keccak256(abi.encode(mask, active, occupied, eights, band));
    }

    function test_emptyCreditBatch() public view {
        assertEq(lens.creditScores(new uint256[](0)).length, 0);
    }

    function test_singleCreditBatch() public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory scores = lens.creditScores(ids);
        assertEq(scores.length, 1);
        assertEq(scores[0], 1_324_012);
    }

    function test_creditBatchPreservesOrderAndDuplicates() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = CreditIds.at(2);
        ids[1] = 1;
        ids[2] = CreditIds.at(0);
        ids[3] = ids[0];
        _assertBatch(ids);
    }

    function _assertBatch(uint256[] memory ids) private view {
        uint256[] memory scores = lens.creditScores(ids);
        assertEq(scores.length, ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(
                scores[i],
                ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(ids[i]), CREDITS.timestampOf(ids[i]))
            );
        }
    }

    function test_eightyCreditBatch() public view {
        uint256[] memory ids = new uint256[](80);
        for (uint256 i = 0; i < ids.length; ++i) {
            ids[i] = CreditIds.at(i);
        }
        _assertBatch(ids);
    }

    function _assertUnknownCredit(uint256 id) private {
        bytes memory reason = abi.encodeWithSelector(ICreditScoreLens.UnknownCredit.selector, id);
        vm.expectRevert(reason);
        lens.creditScore(id);
        vm.expectRevert(reason);
        lens.creditRarity(id);
        vm.expectRevert(reason);
        lens.creditTraits(id);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = id;
        ids[2] = CreditIds.at(0);
        vm.expectRevert(reason);
        lens.creditScores(ids);
    }

    function test_unknownCreditIdsRevertAcrossEveryCreditMethod() public {
        _assertUnknownCredit(0);
        _assertUnknownCredit(ICreditRecords(Mainnet.CREDITS).supply() + 1);
        _assertUnknownCredit(type(uint256).max);
    }

    function test_statementScoreMatchesStoredTotal() public view {
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 total = lens.statementScore(id);
            assertEq(total, STATEMENTS.creditScoreOf(id));
            assertGt(total, 8_000_000, "statement is not a single credit");
        }
    }

    function test_unknownStatementIdsReturnZero() public view {
        assertEq(lens.statementScore(0), 0);
        assertEq(lens.statementScore(STATEMENTS.supply() + 1), 0);
        assertEq(lens.statementScore(type(uint256).max), 0);
    }

    function test_nestedOverprintsUpdateTotalAndRetainBurnedPageScores() public {
        address holder = makeAddr("CreditScoreLens statement holder");
        uint256[3] memory ids = _takeStatements(holder);
        uint256 baseScore = lens.statementScore(ids[0]);
        uint256 topScore = lens.statementScore(ids[1]);
        uint256 thirdScore = lens.statementScore(ids[2]);
        vm.startPrank(holder);
        IStatementRecords(Mainnet.STATEMENTS).overprint(ids[1], ids[2]);
        assertEq(lens.statementScore(ids[1]), topScore + thirdScore);
        IStatementRecords(Mainnet.STATEMENTS).overprint(ids[0], ids[1]);
        vm.stopPrank();
        assertEq(lens.statementScore(ids[0]), baseScore + topScore + thirdScore);
        assertEq(lens.statementScore(ids[0]), STATEMENTS.creditScoreOf(ids[0]));
        assertEq(lens.statementScore(ids[1]), topScore + thirdScore);
        assertEq(lens.statementScore(ids[2]), thirdScore);
        vm.expectRevert();
        STATEMENTS.ownerOf(ids[1]);
        vm.expectRevert();
        STATEMENTS.ownerOf(ids[2]);
    }

    function _takeStatements(address holder) private returns (uint256[3] memory ids) {
        uint256 count = 0;
        for (uint256 id = 1; id <= STATEMENTS.supply() && count < 3; ++id) {
            try STATEMENTS.ownerOf(id) returns (address previous) {
                vm.prank(previous);
                STATEMENTS.transferFrom(previous, holder, id);
                ids[count++] = id;
            } catch {}
        }
        assertEq(count, 3, "three live statements at the pin");
    }

    function test_deploymentScriptDeploysTheCompiledHelper() public {
        address deployed = new DeployCreditScoreLens().run();
        assertEq(deployed.code, vm.getDeployedCode("CreditScoreLens.sol:CreditScoreLens"));
        assertEq(ICreditScoreLens(deployed).creditScore(1), 1_324_012);
        assertEq(ICreditScoreLens(deployed).statementScore(1), STATEMENTS.creditScoreOf(1));
    }

    function test_deploymentScriptRejectsAnotherChain() public {
        DeployCreditScoreLens deployer = new DeployCreditScoreLens();
        vm.chainId(2);
        vm.expectRevert(abi.encodeWithSelector(DeployCreditScoreLens.UnsupportedChain.selector, 2));
        deployer.run();
    }

    function test_gas_creditScoresOne() public {
        _measureBatch(1);
    }

    function test_gas_creditScoresTen() public {
        _measureBatch(10);
    }

    function test_gas_creditScoresEighty() public {
        _measureBatch(80);
    }

    function _measureBatch(uint256 count) private {
        uint256[] memory ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = CreditIds.at(i);
        }
        vm.cool(address(lens));
        vm.cool(Mainnet.CREDITS);
        vm.cool(Mainnet.CREDIT_SCORE);
        uint256 gasBefore = gasleft();
        lens.creditScores(ids);
        console2.log("Batch size", count);
        console2.log("Call execution gas", gasBefore - gasleft());
        console2.log("Runtime bytes", address(lens).code.length);
    }
}
