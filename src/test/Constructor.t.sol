// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2 as console, stdStorage, StdStorage} from "../../lib/forge-std/src/Test.sol";
import {PolyLend} from "../PolyLend.sol";

/// @title PolyLendConstructorTest
/// @notice Fuzz tests for PolyLend constructor and immutable state initialization
contract PolyLendConstructorTest is Test {
    /// @dev Deploys PolyLend with fuzzed addresses and verifies that
    /// @dev the USDC and ConditionalTokens immutables are set correctly
    function test_PolyLendConstructorTest_constructor(address _conditionalTokens, address _usdc) public {
        PolyLend polyLend = new PolyLend(
            _conditionalTokens,
            _usdc,
            0x0000000000000000000000000000000000000000,
            0x0000000000000000000000000000000000000000
        );

        vm.assertEq(address(polyLend.usdc()), _usdc);
        vm.assertEq(address(polyLend.conditionalTokens()), _conditionalTokens);
    }
}
