// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {PolyLendTestHelper, Offer} from "./PolyLendTestHelper.sol";

contract PolyLendOfferTest is PolyLendTestHelper {
    uint256 rate;


    function _setUp(
        uint128 _collateralAmount,
        uint256 _rate
    ) internal {
        rate = bound(_rate, 10 ** 18 + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();
    }

    function test_PolyLendOfferTest_offer(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectEmit();
        emit LoanOffered(0, lender, _loanAmount, rate);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        polyLend.offer(_loanAmount, rate, positionIds, _collateralAmount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        Offer memory offer = _getOffer(0);

        
        assertEq(offer.lender, lender);
        assertEq(offer.loanAmount, _loanAmount);
        assertEq(offer.rate, rate);

        assertEq(polyLend.nextOfferId(), 1);
    }

    function test_revert_PolyLendOfferTest_offer_InsufficientFunds(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration,
        uint128 _balance
    ) public {
        _setUp(_collateralAmount, _rate);

        uint256 balance = bound(_balance, 0, _loanAmount - 1);
        vm.startPrank(lender);
        usdc.mint(lender, balance);
        vm.expectRevert(InsufficientFunds.selector);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        polyLend.offer(_loanAmount, rate, positionIds, _collateralAmount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InsufficientAllowance(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration,
        uint128 _allowance
    ) public {
        _setUp(_collateralAmount, _rate);

        uint256 allowance = bound(_allowance, 0, _loanAmount - 1);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), allowance);
        vm.expectRevert(InsufficientAllowance.selector);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        polyLend.offer(_loanAmount, rate, positionIds, _collateralAmount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InvalidRate_tooLow(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _rate);

        rate = bound(_rate, 0, 10 ** 18);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(InvalidRate.selector);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        polyLend.offer(_loanAmount, rate, positionIds, _collateralAmount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InvalidRate_tooHigh(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint32 _minimumDuration
    ) public {
        _setUp(_collateralAmount, _rate);

        rate = bound(_rate, polyLend.MAX_INTEREST() + 1, type(uint64).max);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(InvalidRate.selector);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        polyLend.offer(_loanAmount, rate, positionIds, _collateralAmount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }
}
