// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper, Loan} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendOverflowTest is PolyLendTestHelper {
    uint256 rate;
    uint256 offerId;
    uint256 loanId;

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

    /// @dev 2-year loan at max interest rate (1000% APY)
    function test_twoYearLoan_maxRate() public {
        uint128 loanAmount = 1_000_000e6; // 1M USDC
        uint256 duration = 3650 days;

        _createLoan(loanAmount, polyLend.MAX_INTEREST(), duration);
        skip(duration);

        uint256 paybackTime = block.timestamp;
        uint256 amountOwed = polyLend.getAmountOwed(loanId, paybackTime);

        // 1000% APY for 2 years: principal * 11^2 = 121M USDC
        assertGt(amountOwed, loanAmount);

        vm.startPrank(borrower);
        usdc.mint(borrower, amountOwed);
        usdc.approve(address(polyLend), amountOwed);
        polyLend.repay(loanId, paybackTime);
        vm.stopPrank();

        Loan memory loan = _getLoan(loanId);
        assertEq(loan.borrower, address(0));
    }

    /// @dev 2-year loan at moderate interest rate (~10% APY)
    function test_twoYearLoan_moderateRate() public {
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

    /// @dev 2-year loan at max rate with small principal
    function test_twoYearLoan_maxRate_smallPrincipal() public {
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
