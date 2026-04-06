// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PolyLendTestHelper} from "./PolyLendTestHelper.sol";
import {InterestLib} from "../InterestLib.sol";

contract PolyLendOfferValidationTest is PolyLendTestHelper {
    /// @dev Revert if any collateral amount in the array is zero
    function test_revert_offer_CollateralAmountIsZero(uint128 _loanAmount, uint256 _rate, uint256 _duration) public {
        vm.assume(_loanAmount > 0);
        vm.assume(_duration > 0);

        uint256 rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        uint256[] memory collateralAmounts = new uint256[](2);
        collateralAmounts[0] = 100;
        collateralAmounts[1] = 0; // zero

        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(CollateralAmountIsZero.selector);
        polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, false);
        vm.stopPrank();
    }

    /// @dev Revert if minimumLoanAmount > loanAmount
    function test_revert_offer_InvalidMinimumLoanAmount(
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _duration,
        uint128 _minimumLoanAmount
    ) public {
        vm.assume(_loanAmount > 0);
        vm.assume(_duration > 0);
        vm.assume(_minimumLoanAmount > _loanAmount);

        uint256 rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = 100;

        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        vm.expectRevert(InvalidMinimumLoanAmount.selector);
        polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    /// @dev Perpetual offer is created with perpetual=true
    function test_offer_perpetual(uint128 _loanAmount, uint256 _rate, uint256 _duration) public {
        vm.assume(_loanAmount > 0);
        vm.assume(_duration > 0);

        uint256 rate = bound(_rate, InterestLib.ONE + 1, polyLend.MAX_INTEREST());

        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = positionId0;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = 100;

        vm.startPrank(lender);
        usdc.mint(lender, _loanAmount);
        usdc.approve(address(polyLend), _loanAmount);
        uint256 offerId = polyLend.offer(_loanAmount, rate, positionIds, collateralAmounts, 0, _duration, true);
        vm.stopPrank();

        (,,,,,,,, bool perpetual) = polyLend.offers(offerId);
        assertTrue(perpetual);
    }
}
