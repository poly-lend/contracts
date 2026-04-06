// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

/// @title PolyLendOverflowTest
/// @notice Tests that compound interest calculations do not overflow
/// @notice even under extreme conditions (10-year loans, max rates, large principals).
/// @notice Validates that _calculateAmountOwed and InterestLib.pow handle
/// @notice large exponents without reverting due to integer overflow.
contract PolyLendOverflowTest is PolyLendTestHelper {
    uint256 rate;
    uint256 offerId;
    uint256 loanId;

    /// @notice Helper to create a loan with the given parameters
    /// @notice Uses 1M conditional tokens as collateral for all test cases
    function _createLoan(uint128 _loanAmount, uint256 _rate, uint256 _duration) internal {
        uint128 collateralAmount = 1_000_000e6; // 1M tokens
        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = collateralAmount;

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration + 1 days, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        loanId = polyLend.accept(offerId, collateralAmount, 0, positionId0, false);
        vm.stopPrank();
    }

    /// @dev 10-year loan with 1M USDC at max interest rate (1000% APY).
    /// @dev At 1000% APY compounded per-second over 10 years, the interest
    /// @dev multiplier is approximately 11^10 ≈ 25.9 billion. Tests that
    /// @dev the pow() exponentiation by squaring and the final multiplication
    /// @dev do not overflow uint256 even at these extreme values.
    function test_tenYearLoan_maxRate() public {
        uint128 loanAmount = 1_000_000e6; // 1M USDC
        uint256 duration = 3650 days;

        _createLoan(loanAmount, polyLend.MAX_INTEREST(), duration);
        skip(duration);

        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        assertGt(amountOwed, loanAmount);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);
        assertEq(loan.borrower, address(0));
    }

    /// @dev 10-year loan with 1M USDC at a moderate interest rate (~10% APY).
    /// @dev Verifies that realistic long-duration loans with common DeFi rates
    /// @dev compute and settle correctly without overflow.
    function test_tenYearLoan_moderateRate() public {
        uint128 loanAmount = 1_000_000e6; // 1M USDC
        // ~10% APY per-second rate
        uint256 moderateRate = InterestLib.ONE + 3_022_265_980;
        uint256 duration = 3650 days;

        _createLoan(loanAmount, moderateRate, duration);
        skip(duration);

        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        assertGt(amountOwed, loanAmount);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);
        assertEq(loan.borrower, address(0));
    }

    /// @dev 10-year loan with a small principal (100 USDC) at max rate.
    /// @dev Tests the lower bound of loan amounts to ensure the interest
    /// @dev calculation does not lose precision or revert for small values
    /// @dev over long durations.
    function test_tenYearLoan_maxRate_smallPrincipal() public {
        uint128 loanAmount = 100e6; // 100 USDC
        uint256 duration = 3650 days;

        _createLoan(loanAmount, polyLend.MAX_INTEREST(), duration);
        skip(duration);

        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        assertGt(amountOwed, loanAmount);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);
        assertEq(loan.borrower, address(0));
    }
}
