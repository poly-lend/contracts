// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendRepayTest is PolyLendTestHelper {
    uint256 loanId;
    uint256 rate;
    uint256 offerId;

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
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_minimumLoanAmount < _loanAmount);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_minimumDuration > 0);
        vm.assume(_minimumDuration <= _duration);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

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
        offerId =
            polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        loanId = polyLend.accept(offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();
    }

    function test_PolyLendRepayTest_repay(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);
        uint256 duration = bound(_minimumDuration, 1 days, 60 days);

        uint256 paybackTime = block.timestamp + duration;
        skip(duration);

        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);
        uint256 fee = (amountOwed - _loanAmount) / 10;

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        vm.expectEmit();
        emit LoanRepaid(loanId, offerId);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);

        assertEq(loan.borrower, address(0));
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(usdc.balanceOf(lender), amountOwed - fee);
        assertEq(conditionalTokens.balanceOf(address(polyLend), positionId0), 0);
        assertEq(conditionalTokens.balanceOf(address(borrower), positionId0), _collateralAmount);
    }

    function test_PolyLendRepayTest_repay_calledLoan(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint256 _auctionDuration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);

        uint256 duration = bound(_duration, _minimumDuration > 1 days ? _minimumDuration : 1 days, 90 days);
        uint256 auctionDuration = bound(_auctionDuration, 0, polyLend.AUCTION_DURATION());

        uint256 callTime = block.timestamp + duration;
        skip(duration);

        vm.startPrank(lender);
        polyLend.call(loanId);
        vm.stopPrank();

        skip(auctionDuration);
        uint256 amountOwed = polyLend.getAmountOwed(loanId, callTime);
        uint256 fee = (amountOwed - _loanAmount) / 10;

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        vm.expectEmit();
        emit LoanRepaid(loanId, offerId);
        polyLend.repay(loanId, callTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);

        assertEq(loan.borrower, address(0));
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(usdc.balanceOf(lender), amountOwed - fee);
        assertEq(conditionalTokens.balanceOf(address(polyLend), positionId0), 0);
        assertEq(conditionalTokens.balanceOf(address(borrower), positionId0), _collateralAmount);
    }

    function test_PolyLendRepayTest_repay_paybackBuffer(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint256 _repayTimestamp
    ) public {
        uint256 minDuration = bound(_minimumDuration, 1 days + polyLend.PAYBACK_BUFFER() + 1, 30 days);
        uint256 duration = bound(_duration, minDuration, 60 days);
        _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, minDuration);

        skip(duration);

        // repayTimestamp must be within PAYBACK_BUFFER of current time
        uint256 repayTimestamp = bound(_repayTimestamp, block.timestamp - polyLend.PAYBACK_BUFFER(), block.timestamp);
        uint256 amountOwed = polyLend.getAmountOwed(loanId, repayTimestamp);
        uint256 fee = (amountOwed - _loanAmount) / 10;

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, repayTimestamp);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);

        assertEq(loan.borrower, address(0));
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(usdc.balanceOf(lender), amountOwed - fee);
        assertEq(conditionalTokens.balanceOf(address(polyLend), positionId0), 0);
        assertEq(conditionalTokens.balanceOf(address(borrower), positionId0), _collateralAmount);
    }

    function test_revert_PolyLendRepayTest_repay_alreadyRepaid_OnlyBorrower(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);
        uint256 duration = bound(_duration, 1 days, 60 days);

        uint256 paybackTime = block.timestamp + duration;
        skip(duration);

        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);

        usdc.mint(borrower, amountOwed - usdc.balanceOf(borrower));
        usdc.approve(address(polyLend), amountOwed);
        vm.expectRevert(OnlyBorrower.selector);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();
    }

    function test_revert_PolyLendRepayTest_repay_OnlyBorrower(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration,
        uint256 _minimumDuration,
        address _caller
    ) public {
        vm.assume(_caller != borrower);

        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);

        vm.startPrank(_caller);
        vm.expectRevert(OnlyBorrower.selector);
        polyLend.repay(loanId, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Reverts if _repayTimestamp is too early for an uncalled loan
    function test_revert_PolyLendRepayTest_repay_timestampTooEarly_InvalidRepayTimestamp(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint32 _repayTimestamp
    ) public {
        uint256 minDuration = bound(_minimumDuration, 1 days + polyLend.PAYBACK_BUFFER() + 2, 30 days);
        uint256 duration = bound(_duration, minDuration, 60 days);
        _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, minDuration);

        skip(duration);

        // repayTimestamp is past MINIMUM_LOAN_DURATION but outside PAYBACK_BUFFER window
        uint256 minRepay = 1 + 1 days; // startTime(1) + MINIMUM_LOAN_DURATION
        uint256 maxRepay = block.timestamp - polyLend.PAYBACK_BUFFER() - 1;
        uint256 repayTimestamp = bound(_repayTimestamp, minRepay, maxRepay);

        vm.startPrank(borrower);
        vm.expectRevert(InvalidRepayTimestamp.selector);
        polyLend.repay(loanId, repayTimestamp);
        vm.stopPrank();
    }

    /// @dev Reverts if _repayTimestamp does not equal call time for a called loan
    function test_revert_PolyLendRepayTest_repay_doesNotEqualCallTime_InvalidRepayTimestamp(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint32 _repayTime
    ) public {
        uint256 minDuration = bound(_minimumDuration, 1 days, 30 days);
        uint256 duration = bound(_duration, minDuration, 60 days);
        _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, minDuration);

        uint256 callTime = block.timestamp + duration;

        // _repayTime must differ from callTime and pass MINIMUM_LOAN_DURATION check
        uint256 repayTime = bound(_repayTime, 1 + 1 days, type(uint32).max);
        vm.assume(repayTime != callTime);

        skip(duration);

        vm.startPrank(lender);
        vm.expectEmit();
        emit LoanCalled(loanId, block.timestamp);
        polyLend.call(loanId);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(InvalidRepayTimestamp.selector);
        polyLend.repay(loanId, repayTime);
        vm.stopPrank();
    }

    function test_revert_PolyLendRepayTest_repay_InsufficientAllowance(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint256 _allowance
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);
        uint256 duration = bound(_duration, 1 days, 60 days);

        uint256 paybackTime = block.timestamp + duration;
        skip(duration);

        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);
        uint256 allowance = bound(_allowance, 0, amountOwed - 1);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), allowance);
        vm.expectRevert(InsufficientAllowance.selector);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();
    }

    /// @dev Reverts if repay is attempted before MINIMUM_LOAN_DURATION
    function test_revert_PolyLendRepayTest_repay_MinimumLoanDurationNotMet(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, 0, _duration, _minimumDuration);

        // repay before minimum loan duration has passed
        uint256 paybackTime = block.timestamp;

        vm.startPrank(borrower);
        vm.expectRevert(MinimumLoanDurationNotMet.selector);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();
    }
}
