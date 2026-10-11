// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";

/// @notice probes of the statements the Core holds: no stranger can overprint or compose what the Core owns
contract ReviewStatementsTest is Fixture {
    address internal alice = makeAddr("rs_alice");
    address internal bob = makeAddr("rs_bob");

    function test_measure_transferGasOfTheRealStatements() public {
        (uint256 sid,) = _sellStatement(alice);
        assertEq(STATEMENTS.ownerOf(sid), alice);
        // transfer gas of a statement from a contract holder to a fresh account
        vm.prank(alice);
        uint256 g = gasleft();
        STATEMENTS.transferFrom(alice, bob, sid);
        emit log_named_uint("Statements.transferFrom gas", g - gasleft());
    }

    /// @dev a second statement, composed on top of the first
    function _composeSecond() internal returns (uint256 sid2) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        sid2 = STATEMENTS.supply() + 1;
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.ownerOf(sid2), address(core));
    }

    function test_probe_strangerCannotOverprintTheCoresStatements() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _composeSecond();
        assertEq(STATEMENTS.ownerOf(a), address(core));
        bytes memory call = abi.encodeWithSignature("overprint(uint256,uint256)", a, b);
        vm.prank(bob);
        (bool ok,) = address(STATEMENTS).call(call);
        assertFalse(ok);
        assertEq(STATEMENTS.ownerOf(b), address(core));
    }

    function test_probe_strangerCannotComposeTheCoresCredits() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.prank(bob);
        vm.expectRevert();
        STATEMENTS.compose(ids, 0);
    }
}
