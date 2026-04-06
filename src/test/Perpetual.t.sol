// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan, Offer} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendPerpetualTest is PolyLendTestHelper {
    uint256 rate;
    uint256 offerId;

    function _setUp(uint128 _collateralAmount, uint128 _loanAmount, uint256 _rate, uint256 _duration)
        internal
        returns (uint256)
    {
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 2 days);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount * 3, positionId0);
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
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, true);
        vm.stopPrank();

        return offerId;
    }

    /// @dev Perpetual offer: after repay, borrowedAmount is decremented so borrower can borrow again
    function test_PolyLendPerpetualTest_repayRestoresBorrowedAmount(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        // borrower accepts
        vm.startPrank(borrower);
        uint256 loanId = polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();

        Offer memory offerAfterAccept = _getOffer(offerId);
        assertEq(offerAfterAccept.borrowedAmount, _loanAmount);

        // skip minimum loan duration before repaying
        skip(1 days);
        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        // borrowedAmount should be restored
        Offer memory offerAfterRepay = _getOffer(offerId);
        assertEq(offerAfterRepay.borrowedAmount, 0);
    }

    /// @dev Perpetual offer: after transfer, borrowedAmount is decremented
    function test_PolyLendPerpetualTest_transferRestoresBorrowedAmount(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        vm.assume(_duration > 1);
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        uint256 minimumDuration = 1;

        vm.startPrank(borrower);
        uint256 loanId = polyLend.accept(offerId, _collateralAmount, minimumDuration, positionId0, false);
        vm.stopPrank();

        Offer memory offerAfterAccept = _getOffer(offerId);
        assertEq(offerAfterAccept.borrowedAmount, _loanAmount);

        // skip past minimum duration, call the loan
        skip(minimumDuration);

        vm.startPrank(lender);
        polyLend.call(loanId);
        vm.stopPrank();

        // skip a bit into the auction so rate > ONE
        skip(1);

        // new lender transfers
        address newLender = vm.createWallet("newLender").addr;
        Loan memory loan = _getLoan(loanId);
        uint256 amountOwed = polyLend.getAmountOwed(loanId, loan.callTime);
        usdc.mint(newLender, amountOwed);

        // use a rate within the valid auction range
        uint256 passedDuration = block.timestamp - loan.callTime;
        uint256 currentRate =
            InterestLib.ONE + (passedDuration * InterestLib.ONE_THOUSAND_APY / polyLend.AUCTION_DURATION());
        uint256 newRate = currentRate;

        vm.startPrank(newLender);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.transfer(loanId, newRate);
        vm.stopPrank();

        // borrowedAmount should be restored for the perpetual offer
        Offer memory offerAfterTransfer = _getOffer(offerId);
        assertEq(offerAfterTransfer.borrowedAmount, 0);
    }

    /// @dev Perpetual offer allows re-borrowing after repay
    function test_PolyLendPerpetualTest_reBorrowAfterRepay(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        // first borrow
        vm.startPrank(borrower);
        uint256 loanId1 = polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();

        // skip minimum loan duration before repaying
        skip(1 days);
        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId1, paybackTime);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId1, paybackTime);
        vm.stopPrank();

        // lender needs to re-approve since USDC was sent back
        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        vm.stopPrank();

        // second borrow from the same perpetual offer should succeed
        vm.startPrank(borrower);
        uint256 loanId2 = polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();

        assertEq(loanId2, 1);
        Loan memory loan2 = _getLoan(loanId2);
        assertEq(loan2.borrower, borrower);
        assertEq(loan2.loanAmount, _loanAmount);
    }

    /// @dev Non-perpetual offer: borrowedAmount is NOT restored after repay
    function test_PolyLendPerpetualTest_nonPerpetualDoesNotRestore(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 2 days);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = _collateralAmount;
        uint256 nonPerpetualOfferId =
            polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, false);
        vm.stopPrank();

        vm.startPrank(borrower);
        uint256 loanId = polyLend.accept(nonPerpetualOfferId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();

        // skip minimum loan duration before repaying
        skip(1 days);
        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        // borrowedAmount should NOT be restored for non-perpetual
        Offer memory offerAfterRepay = _getOffer(nonPerpetualOfferId);
        assertEq(offerAfterRepay.borrowedAmount, _loanAmount);
    }
}
