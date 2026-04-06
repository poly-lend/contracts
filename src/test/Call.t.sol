// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";

/// @title PolyLendCallTest
/// @notice Tests for calling loans (initiating the Dutch auction), access control,
/// @notice and interactions with minimum duration and loan state
contract PolyLendCallTest is PolyLendTestHelper {
    uint256 loanId;
    uint256 rate;

    /// @notice Creates an offer and accepts it, producing an active loan for call tests
    function _setUp(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) internal {
        vm.assume(_collateralAmount > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_minimumDuration > 0);
        vm.assume(_minimumDuration <= _duration);
        vm.assume(_minimumLoanAmount < _loanAmount);

        rate = bound(_rate, 10 ** 18 + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        uint256[] memory collateralAmounts = new uint256[](2);
        collateralAmounts[0] = _collateralAmount;
        collateralAmounts[1] = _collateralAmount;
        uint256 offerId =
            polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        loanId = polyLend.accept(offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Lender calls a loan after the minimum duration has passed;
    /// @dev verifies callTime is set and all other loan fields remain unchanged
    function test_PolyLendCallTest_call(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);

        vm.assume(_minimumDuration > 0);
        vm.assume(_minimumDuration <= _duration);

        uint256 duration = bound(_duration, _minimumDuration, type(uint128).max);

        skip(duration);

        vm.startPrank(lender);
        vm.expectEmit();
        emit LoanCalled(loanId, block.timestamp);
        polyLend.call(loanId);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);

        assertEq(loan.borrower, borrower);
        assertEq(loan.lender, lender);
        assertEq(loan.positionId, positionId0);
        assertEq(loan.collateralAmount, _collateralAmount);
        assertEq(loan.loanAmount, _loanAmount);
        assertEq(loan.rate, rate);
        assertEq(loan.startTime, 1);
        assertEq(loan.minimumDuration, _minimumDuration);
        assertEq(loan.callTime, block.timestamp);
    }

    /// @dev Reverts when a non-lender address attempts to call a loan
    function test_revert_PolyLendCallTest_call_OnlyLender(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration,
        address _caller
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);
        vm.assume(_caller != lender);

        vm.startPrank(_caller);
        vm.expectRevert(OnlyLender.selector);
        polyLend.call(loanId);
        vm.stopPrank();
    }

    /// @dev Reverts when the lender tries to call a loan before the minimum duration has elapsed
    function test_revert_PolyLendCallTest_call_MinimumDurationHasNotPassed(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) public {
        vm.assume(_minimumDuration > 0);
        uint256 duration = bound(_duration, 0, _minimumDuration - 1);

        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);

        skip(duration);

        vm.startPrank(lender);
        vm.expectRevert(MinimumDurationHasNotPassed.selector);
        polyLend.call(loanId);
        vm.stopPrank();
    }

    /// @dev Reverts when the lender tries to call a loan that is already called
    function test_revert_PolyLendCallTest_call_LoanIsCalled(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);

        skip(_minimumDuration);

        vm.startPrank(lender);
        polyLend.call(loanId);

        vm.expectRevert(LoanIsCalled.selector);
        polyLend.call(loanId);
        vm.stopPrank();
    }

    /// @dev Reverts when trying to call a loan that has already been repaid
    /// @dev (borrower field is zeroed after repay, so the loan is invalid)
    function test_revert_PolyLendCallTest_loanIsRepaid(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);
        uint256 duration = bound(_duration, _minimumDuration > 1 days ? _minimumDuration : 1 days, 60 days);

        uint256 paybackTime = block.timestamp + duration;
        skip(duration);

        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert(InvalidLoan.selector);
        polyLend.call(loanId);
        vm.stopPrank();
    }
}
