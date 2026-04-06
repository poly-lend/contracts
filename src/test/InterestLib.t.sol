// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2 as console, stdStorage, StdStorage, stdError} from "../../lib/forge-std/src/Test.sol";
import {InterestLib} from "../InterestLib.sol";

/// @title InterestLibTest
/// @notice Tests for the InterestLib fixed-point exponentiation library,
/// @notice validating pow() correctness and MAX_INTEREST rate accuracy
contract InterestLibTest is Test {
    using InterestLib for uint256;

    /// @dev Verifies basic pow() operation: 2^3 = 8 in 18-decimal fixed-point
    function test_InterestLibTest_pow() public pure {
        uint256 base = 2 * InterestLib.ONE;
        uint256 exponent = 3;
        uint256 result = base.pow(exponent);

        assertEq(result, 8 * InterestLib.ONE);
    }

    /// @dev MAX_INTEREST should be within 0.00000001% of 1000% APY
    function test_InterestLibTest_maxInterest() public pure {
        uint256 perSecondRate = InterestLib.ONE + InterestLib.ONE_THOUSAND_APY;
        uint256 perYearRate = perSecondRate.pow(365 days);

        // 1000% APY is (1 + 1000/100) = 11
        assertApproxEqRel(perYearRate, 11 * 10 ** 18, 10 ** 8);
    }
}
