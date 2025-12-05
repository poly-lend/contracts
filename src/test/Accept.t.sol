// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendAcceptTest is PolyLendTestHelper {
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
        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);
        vm.assume(_collateralAmount > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_minimumDuration <= 60 days);
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
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_PolyLendAcceptTest_accept(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);

        vm.startPrank(borrower);
        vm.expectEmit();
        emit LoanAccepted(0, offerId, borrower, block.timestamp);
        polyLend.accept(offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();

        Loan memory loan = _getLoan(0);

        assertEq(loan.borrower, borrower);
        assertEq(loan.lender, lender);
        assertEq(loan.positionId, positionId0);
        assertEq(loan.collateralAmount, _collateralAmount);
        assertEq(loan.loanAmount, _loanAmount);
        assertEq(loan.rate, rate);
        assertEq(loan.startTime, block.timestamp);
        assertEq(loan.minimumDuration, _minimumDuration);
        assertEq(loan.callTime, 0);

        assertEq(usdc.balanceOf(borrower), _loanAmount);
        assertEq(conditionalTokens.balanceOf(address(polyLend), positionId0), _collateralAmount);

        assertEq(polyLend.nextLoanId(), 1);
    }

    function test_revert_PolyLendAcceptTest_accept_InvalidOffer(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration,
        uint256 _offerId
    ) public {
        vm.assume(_offerId > 0);

        _setUp(_collateralAmount, _loanAmount, _rate, _minimumLoanAmount, _duration, _minimumDuration);

        vm.startPrank(borrower);
        vm.expectRevert(InvalidOffer.selector);
        polyLend.accept(_offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();
    }
}
