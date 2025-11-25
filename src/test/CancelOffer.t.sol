// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {PolyLendTestHelper, Offer} from "./PolyLendTestHelper.sol";

contract PolyLendCancelOfferTest is PolyLendTestHelper {
    uint256 rate;
    uint256 requestId;
    uint256 offerId;

    function _setUp(uint128 _amount, uint128 _loanAmount, uint256 _rate, uint256 _minimumLoanAmount, uint256 _duration) internal {
        vm.assume(_amount > 0);
        vm.assume(_duration <= 60 days);

        rate = bound(_rate, 10 ** 18 + 1, polyLend.MAX_INTEREST());

        _mintConditionalTokens(borrower, _amount, positionId0);
        usdc.mint(lender, _loanAmount);

        vm.startPrank(borrower);
        conditionalTokens.setApprovalForAll(address(polyLend), true);
        vm.stopPrank();

        vm.startPrank(lender);
        usdc.approve(address(polyLend), _loanAmount);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = positionId0;
        positionIds[1] = positionId1;
        offerId = polyLend.offer(_loanAmount, rate, positionIds, _amount, _minimumLoanAmount, _duration, false);
        vm.stopPrank();
    }

    function test_PolyLendCancelOfferTest_cancelOffer(
        uint128 _amount,
        uint128 _loanAmount,
        uint256 _rate,
        uint256 _minimumLoanAmount,
        uint256 _duration
    ) public {
        _setUp(_amount, _loanAmount, _rate, _minimumLoanAmount, _duration);

        vm.startPrank(lender);
        polyLend.cancelOffer(offerId);
        vm.stopPrank();

        Offer memory offer = _getOffer(0);

        assertEq(offer.lender, address(0));
        assertEq(offer.loanAmount, _loanAmount);
        assertEq(offer.rate, rate);
    }

    function test_revert_PolyLendCancelOfferTest_cancelOffer_OnlyLender(
        uint128 _amount,
        uint128 _loanAmount,
        uint256 _rate,
        uint32 _minimumDuration,
        address _caller
    ) public {
        vm.assume(_caller != lender);
        _setUp(_amount, _loanAmount, _rate, 0, _minimumDuration);

        vm.startPrank(_caller);
        vm.expectRevert(OnlyLender.selector);
        polyLend.cancelOffer(offerId);
        vm.stopPrank();
    }

    function test_revert_PolyLendCancelOfferTest_accept_InvalidOffer(
        uint128 _amount,
        uint128 _loanAmount,
        uint256 _rate,
        uint32 _minimumDuration
    ) public {
        _setUp(_amount, _loanAmount, _rate, 0, _minimumDuration);

        vm.startPrank(lender);
        polyLend.cancelOffer(offerId);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(InvalidOffer.selector);
        polyLend.accept(offerId, _amount, _minimumDuration, positionId0, false);
        vm.stopPrank();
    }

    function test_revert_PolyLendCancelOfferTest_cancelRequest_alreadyCanceled(
        uint128 _amount,
        uint128 _loanAmount,
        uint256 _rate,
        uint32 _minimumDuration
    ) public {
        _setUp(_amount, _loanAmount, _rate, 0, _minimumDuration);

        vm.startPrank(lender);
        polyLend.cancelOffer(offerId);
        vm.expectRevert(OnlyLender.selector);
        polyLend.cancelOffer(offerId);
        vm.stopPrank();
    }
}
