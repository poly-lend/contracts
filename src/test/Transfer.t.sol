// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendTransferTest is PolyLendTestHelper {
    address newLender;
    uint256 rate;
    uint256 offerId;

    function setUp() public override {
        super.setUp();
        newLender = vm.createWallet("newLender").addr;
    }

    function _setUp(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration
    ) internal returns (uint256) {

        vm.assume(_loanAmount > 0);
        vm.assume(_minimumLoanAmount < _loanAmount);
        vm.assume(_collateralAmount > 0);
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
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        uint256 loanId = polyLend.accept(offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();

        skip(_duration);

        vm.startPrank(lender);
        polyLend.call(loanId);
        vm.stopPrank();

        return loanId;
    }

    function test_PolyLendTransferTest_transfer(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint32 _minimumDuration,
        uint256 _duration,
        uint256 _auctionLength,
        uint256 _newRate
    ) public {

        uint256 loanId;
        uint256 callTime;
        vm.assume(_minimumDuration < 60 days);

        {
            uint256 duration = bound(_duration, _minimumDuration, 60 days);
            uint256 auctionLength = bound(_auctionLength, 0, polyLend.AUCTION_DURATION());
            loanId = _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, _minimumDuration);

            callTime = block.timestamp;
            skip(auctionLength);
        }

        uint256 newRate = bound(_newRate, InterestLib.ONE, _getNewRate(callTime));
        uint256 newLoanId = loanId + 1;

        uint256 amountOwed = polyLend.getAmountOwed(loanId, callTime);
        //uint256 fee = (amountOwed - _loanAmount) / 10 ;
        usdc.mint(newLender, amountOwed);

        vm.startPrank(newLender);
        usdc.approve(address(polyLend), amountOwed);
        vm.expectEmit();
        emit LoanTransferred(loanId, newLoanId, newLender, offerId, newRate);
        polyLend.transfer(loanId, newRate);
        vm.stopPrank();

        Loan memory newLoan = _getLoan(newLoanId);

        assertEq(newLoan.borrower, borrower);
        assertEq(newLoan.lender, newLender);
        assertEq(newLoan.positionId, positionId0);
        assertEq(newLoan.collateralAmount, _collateralAmount);
        //assertEq(newLoan.loanAmount, amountOwed);
        assertEq(newLoan.rate, newRate);
        assertEq(newLoan.startTime, block.timestamp);
        assertEq(newLoan.minimumDuration, 0);
        assertEq(newLoan.callTime, 0);

        //assertEq(usdc.balanceOf(lender), amountOwed - fee);
        //assertEq(usdc.balanceOf(newLender), 0);
    }

    function test_revert_PolyLendTransferTest_transfer_InvalidLoan(uint256 _loanId, uint256 _newRate) public {
        vm.assume(_loanId != 0);

        vm.startPrank(newLender);
        vm.expectRevert(InvalidLoan.selector);
        polyLend.transfer(_loanId, _newRate);
        vm.stopPrank();
    }

    function test_revert_PolyLendTransferTest_transfer_LoanIsNotCalled(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        uint256 _minimumDuration,
        uint256 _newRate
    ) public {
        newLender = vm.createWallet("oracle").addr;

        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 0);
        vm.assume(_rate > 0);
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
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectEmit();
        emit LoanAccepted(0, 0, borrower, block.timestamp);
        uint256 loanId = polyLend.accept(offerId, _collateralAmount, _minimumDuration, positionId0, false);
        vm.stopPrank();

        vm.startPrank(newLender);
        vm.expectRevert(LoanIsNotCalled.selector);
        polyLend.transfer(loanId, _newRate);
        vm.stopPrank();
    }

    function test_revert_PolyLendTransferTest_transfer_AuctionHasEnded(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint32 _minimumDuration,
        uint256 _duration,
        uint256 _auctionLength,
        uint256 _newRate
    ) public {
        vm.assume(_minimumDuration <= 60 days);

        uint256 loanId;
        uint256 callTime;

        uint256 duration = bound(_duration, _minimumDuration, 60 days);
        uint256 auctionLength = bound(_auctionLength, polyLend.AUCTION_DURATION() + 1, type(uint32).max);
        loanId = _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, _minimumDuration);

        callTime = block.timestamp;
        skip(auctionLength);

        uint256 newRate = bound(_newRate, 0, _getNewRate(callTime));

        vm.startPrank(newLender);
        vm.expectRevert(AuctionHasEnded.selector);
        polyLend.transfer(loanId, newRate);
        vm.stopPrank();
    }

    function test_revert_PolyLendTransferTest_transfer_InvalidRate(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumDuration,
        uint256 _duration,
        uint256 _auctionLength,
        uint256 _newRate
    ) public {
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 0);
        vm.assume(_rate > 0);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);
        vm.assume(_minimumDuration > 0);
        vm.assume(_minimumDuration <= _duration);

        uint256 loanId;
        uint256 callTime;

        {
            uint256 duration = bound(_duration, _minimumDuration, 60 days);
            uint256 auctionLength = bound(_auctionLength, 0, polyLend.AUCTION_DURATION());
            loanId = _setUp(_collateralAmount, _loanAmount, _rate, 0, duration, _minimumDuration);
            skip(auctionLength);
        }

        Loan memory loan = _getLoan(loanId);
        callTime = loan.callTime;
        uint256 newRate = bound(_newRate, _getNewRate(callTime) + 1, type(uint64).max);

        uint256 amountOwed = polyLend.getAmountOwed(loanId, callTime);
        usdc.mint(newLender, amountOwed);

        vm.startPrank(newLender);
        usdc.approve(address(polyLend), amountOwed);
        vm.expectRevert(InvalidRate.selector);
        polyLend.transfer(loanId, newRate);
        vm.stopPrank();
    }
}
