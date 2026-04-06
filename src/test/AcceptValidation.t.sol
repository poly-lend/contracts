// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Offer} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendAcceptValidationTest is PolyLendTestHelper {
    uint256 rate;
    uint256 offerId;
    uint256[] positionIds;
    uint256[] collateralAmounts;

    function _setUp(uint128 _collateralAmount, uint128 _loanAmount, uint256 _rate, uint256 _duration) internal {
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _collateralAmount, positionId0);
        usdc.mint(lender, _loanAmount);

        positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        collateralAmounts = new uint256[](2);
        collateralAmounts[0] = _collateralAmount;
        collateralAmounts[1] = _collateralAmount;

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, false);
        vm.stopPrank();
    }

    /// @dev Revert if collateral amount is zero
    function test_revert_accept_CollateralAmountIsZero(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.expectRevert(CollateralAmountIsZero.selector);
        polyLend.accept(offerId, 0, 0, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Revert if borrower has insufficient collateral
    function test_revert_accept_InsufficientCollateralBalance(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.expectRevert(InsufficientCollateralBalance.selector);
        polyLend.accept(offerId, uint256(_collateralAmount) + 1, 0, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Revert if collateral is not approved
    function test_revert_accept_CollateralIsNotApproved(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        // borrower does NOT approve
        vm.startPrank(borrower);
        vm.expectRevert(CollateralIsNotApproved.selector);
        polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Revert if position is not in the offer's position list
    function test_revert_accept_InvalidPosition(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        vm.assume(_collateralAmount > 0);
        vm.assume(_loanAmount > 1_000_000);
        vm.assume(_duration > 0);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());
        usdc.mint(lender, _loanAmount);

        // offer only for positionId0
        uint256[] memory singlePositionIds = new uint256[](1);
        singlePositionIds[0] = positionId0;
        uint256[] memory singleCollateralAmounts = new uint256[](1);
        singleCollateralAmounts[0] = _collateralAmount;

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        uint256 singleOfferId =
            polyLend.offer(_loanAmount, rate, singlePositionIds, singleCollateralAmounts, 0, _duration, false);
        vm.stopPrank();

        // mint positionId1 for borrower and try to use it
        _mintConditionalTokens(borrower, _collateralAmount, positionId1);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.expectRevert(InvalidPosition.selector);
        polyLend.accept(singleOfferId, _collateralAmount, 0, positionId1, false);
        vm.stopPrank();
    }

    /// @dev Revert if collateral amount exceeds offer's collateral amount for that position
    function test_revert_accept_InvalidCollateralAmount(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        // mint extra so borrower has enough
        _mintConditionalTokens(borrower, 1, positionId0);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.expectRevert(InvalidCollateralAmount.selector);
        polyLend.accept(offerId, uint256(_collateralAmount) + 1, 0, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Revert if minimum duration extends beyond offer duration
    function test_revert_accept_InvalidMinimumDuration(
        uint128 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.expectRevert(InvalidMinimumDuration.selector);
        polyLend.accept(offerId, _collateralAmount, _duration + 1, positionId0, false);
        vm.stopPrank();
    }

    /// @dev Revert if borrowing would exceed remaining offer capacity
    function test_revert_accept_LoanAmountExceedsLimit(
        uint64 _collateralAmount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration
    ) public {
        _setUp(_collateralAmount, _loanAmount, _rate, _duration);

        // first accept uses full amount
        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();

        // second accept should fail (offer fully borrowed)
        _mintConditionalTokens(borrower, _collateralAmount, positionId0);

        // lender needs balance + allowance for the check
        usdc.mint(lender, _loanAmount);
        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(LoanAmountExceedsLimit.selector);
        polyLend.accept(offerId, _collateralAmount, 0, positionId0, false);
        vm.stopPrank();
    }
}
