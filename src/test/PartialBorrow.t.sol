// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan, Offer} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

/// @title PolyLendPartialBorrowTest
/// @notice Tests for partial collateral borrowing, verifying proportional loan amounts
/// @notice and minimum loan amount enforcement
contract PolyLendPartialBorrowTest is PolyLendTestHelper {
    uint256 rate;
    uint256 offerId;

    /// @notice Creates an offer with a single accepted position for partial borrow tests
    function _setUp(uint128 _collateralAmount, uint128 _loanAmount, uint256 _rate, uint256 _duration) internal {
        vm.assume(_collateralAmount > 1);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = _collateralAmount;

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, false);
        vm.stopPrank();
    }

    /// @dev Borrow with half the collateral should get half the loan amount
    function test_partialBorrow_halfCollateral(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        uint256 halfCollateral = uint256(_collateralAmount) / 2;
        vm.assume(halfCollateral > 0);

        uint256 expectedLoanAmount = (halfCollateral * _loanAmount) / _collateralAmount;
        vm.assume(expectedLoanAmount > 0);

        vm.startPrank(borrower);
        uint256 loanId = polyLend.accept(offerId, halfCollateral, 0, positionId0, false);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);
        assertEq(loan.loanAmount, expectedLoanAmount);
        assertEq(loan.collateralAmount, halfCollateral);

        // offer should track borrowed amount
        Offer memory offerAfter = _getOffer(offerId);
        assertEq(offerAfter.borrowedAmount, expectedLoanAmount);
    }

    /// @dev Revert when partial borrow amount is below minimumLoanAmount
    function test_revert_partialBorrow_belowMinimum(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        vm.assume(_collateralAmount > 1);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = _collateralAmount;

        // set minimumLoanAmount to full loanAmount so any partial borrow fails
        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        uint256 strictOfferId =
            polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _loanAmount, _duration, false);
        vm.stopPrank();

        uint256 halfCollateral = uint256(_collateralAmount) / 2;
        vm.assume(halfCollateral > 0);
        uint256 partialLoan = (halfCollateral * _loanAmount) / _collateralAmount;
        vm.assume(partialLoan < _loanAmount);

        vm.startPrank(borrower);
        vm.expectRevert(InvalidLoanAmount.selector);
        polyLend.accept(strictOfferId, halfCollateral, 0, positionId0, false);
        vm.stopPrank();
    }
}
