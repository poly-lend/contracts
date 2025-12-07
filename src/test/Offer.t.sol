// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Offer} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendOfferTest is PolyLendTestHelper {
    uint256 rate;
    uint256[] allPositionIds;
    uint256[] allCollateralAmounts;


    function _setUp(
        uint128 _collateralAmount,
        uint256 _rate
    ) internal {
        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        allPositionIds = new uint256[](2);
        allPositionIds[0] = positionId0;
        allPositionIds[1] = positionId1;
        allCollateralAmounts = new uint256[](2);
        allCollateralAmounts[0] = _collateralAmount;
        allCollateralAmounts[1] = _collateralAmount;
    }

    function test_PolyLendOfferTest_offer(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _rate);
        
        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_collateralAmount > 0);

        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        
        vm.expectEmit();
        emit LoanOffered(0, lender, _loanAmount, rate);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        Offer memory offer = _getOffer(0);
        
        assertEq(offer.lender, lender);
        assertEq(offer.loanAmount, _loanAmount);
        assertEq(offer.rate, rate);
        assertEq(offer.minimumLoanAmount, _minimumLoanAmount);
        assertEq(offer.duration, _duration);
        assertEq(offer.perpetual, false);
        assertEq(offer.borrowedAmount, 0);
        assertEq(offer.startTime, block.timestamp);

        assertEq(offer.positionIds.length, 2);
        assertEq(offer.positionIds[0], positionId0);
        assertEq(offer.positionIds[1], positionId1);
        assertEq(offer.collateralAmounts.length, 2);
        assertEq(offer.collateralAmounts[0], _collateralAmount);
        assertEq(offer.collateralAmounts[1], _collateralAmount);
    }


    function test_revert_PolyLendOfferTest_offer_InvalidDuration_and_LoanAmount(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint128 _balance,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);
        vm.assume(_collateralAmount > 0);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);

        uint256 balance = bound(_balance, 0, _loanAmount - 1);
        
        vm.startPrank(lender);
        usdc.mint(lender, balance);
        vm.stopPrank();

        vm.expectRevert(InvalidDuration.selector);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, 0, false);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert(InvalidLoanAmount.selector);
        polyLend.offer(0, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InsufficientFunds(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint128 _balance
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.assume(_loanAmount > 0);
        vm.assume(_duration > 0);

        uint256 balance = bound(_balance, 0, _loanAmount - 1);
        vm.startPrank(lender);
        usdc.mint(lender, balance);
        vm.expectRevert(InsufficientFunds.selector);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InsufficientAllowance(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint128 _allowance
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.assume(_loanAmount > 0);
        vm.assume(_duration > 0);

        uint256 allowance = bound(_allowance, 0, _loanAmount - 1);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), allowance);
        vm.expectRevert(InsufficientAllowance.selector);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InvalidRate_tooLow(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);

        rate = bound(_rate, 0, InterestLib.ONE);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(InvalidRate.selector);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendOfferTest_offer_InvalidRate_tooHigh(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _rate);

        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);

        rate = bound(_rate, polyLend.MAX_INTEREST() + 1, type(uint64).max);
        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(InvalidRate.selector);
        polyLend.offer(_loanAmount, rate, allPositionIds, allCollateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }
}
