// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "../lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {ISafeProxyFactory} from "./interfaces/ISafeProxyFactory.sol";
import {ERC1155TokenReceiver} from "./ERC1155TokenReceiver.sol";
import {InterestLib} from "./InterestLib.sol";

/// @notice Loan struct
struct Loan {
    uint256 loanId;
    address borrower;
    address borrowerWallet;
    address lender;
    uint256 positionId;
    uint256 collateralAmount;
    uint256 loanAmount;
    uint256 rate;
    uint256 startTime;
    uint256 minimumDuration;
    uint256 callTime;
    uint256 offerId;
    bool isTransfered;
}


/// @notice Offer struct
struct Offer {
    uint256 offerId;
    address lender;
    uint256 loanAmount;
    uint256 rate;
    uint256 minimumLoanAmount;
    uint256 duration;
    uint256 startTime;
    uint256 borrowedAmount;
    uint256[] positionIds;
    uint256[] collateralAmounts;
    bool perpetual;
}

/// @title PolyLendEE
/// @notice PolyLend events and errors
interface IPolyLend {
    event LoanAccepted(uint256 indexed id, uint256 indexed offerId, uint256 startTime);
    event LoanCalled(uint256 indexed id, uint256 callTime);
    event LoanOffered(uint256 indexed id, address indexed lender, uint256 loanAmount, uint256 rate);
    event LoanRepaid(uint256 indexed id);
    event LoanTransferred(uint256 indexed oldId, uint256 indexed newId, address indexed newLender, uint256 newRate);
    event LoanReclaimed(uint256 indexed id);
    event LoanOfferCanceled(uint256 indexed id);

    error InvalidDuration();
    error CollateralAmountIsZero();
    error InvalidPositionList();
    error InvalidCollateralAmounts();
    error InvalidCollateralAmount();
    error InvalidMinimumDuration();
    error InvalidMinimumLoanAmount();
    error InvalidLoanAmount();
    error InvalidPosition();
    error EmptyPositionList();
    error LoanAmountExceedsLimit();
    error InsufficientCollateralBalance();
    error CollateralIsNotApproved();
    error OnlyBorrower();
    error OnlyLender();
    error InvalidRequest();
    error InvalidOffer();
    error InvalidLoan();
    error InsufficientFunds();
    error InsufficientAllowance();
    error InvalidRate();
    error InvalidRepayTimestamp();
    error LoanIsNotCalled();
    error LoanIsCalled();
    error MinimumDurationHasNotPassed();
    error AuctionHasEnded();
    error AuctionHasNotEnded();
}

/// @title PolyLend
/// @notice A contract for lending USDC using conditional tokens as collateral
/// @author mike@polymarket.com
contract PolyLend is IPolyLend, ERC1155TokenReceiver {
    using InterestLib for uint256;

    /// @notice per second rate equal to roughly 1000% APY
    uint256 public constant MAX_INTEREST = InterestLib.ONE + InterestLib.ONE_THOUSAND_APY;

    /// @notice duration of the auction for transferring a loan
    uint256 public constant AUCTION_DURATION = 1 days;

    /// @notice buffer for payback time
    uint256 public constant PAYBACK_BUFFER = 1 minutes;

    /// @notice protocol fee from lenders yield in basis points 
    uint256 public constant FEE_PERCENT = 10_00;

    /// @notice hundred percent in basis points 
    uint256 public constant ONE_HUNDRED_PERCENT = 100_00;

    /// @notice The conditional tokens contract
    IConditionalTokens public immutable conditionalTokens;

    /// @notice The conditional tokens contract
    ISafeProxyFactory public immutable safeProxyFactory;

    /// @notice The USDC token contract
    ERC20 public immutable usdc;

    /// @notice Fee recipient
    address public immutable feeRecipient;

    /// @notice The next id for a loan
    uint256 public nextLoanId = 0;

    /// @notice The next id for a request
    uint256 public nextRequestId = 0;

    /// @notice The next id for an offer
    uint256 public nextOfferId = 0;

    /// @notice loans mapping
    mapping(uint256 => Loan) public loans;

    /// @notice offers mapping
    mapping(uint256 => Offer) public offers;

    constructor(
            address _conditionalTokens,
            address _usdc, 
            address _safeProxyFactory,
            address _feeRecipient
    ) {
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        usdc = ERC20(_usdc);
        safeProxyFactory = ISafeProxyFactory(_safeProxyFactory);
        feeRecipient = _feeRecipient;
    }

    /// @notice Get the amount owed on a loan
    /// @param _loanId The id of the loan
    /// @param _paybackTime The time at which the loan will be paid back
    /// @return The amount owed on the loan
    function getAmountOwed(uint256 _loanId, uint256 _paybackTime) public view returns (uint256) {
        Loan memory loan = loans[_loanId];
        uint256 loanDuration = _paybackTime - loan.startTime;
        return _calculateAmountOwed(loan.loanAmount, loan.rate, loanDuration);
    }

    /// @notice Get the position ids for an offer
    /// @param _offerId The id of the offer
    /// @return The position ids
    function getOfferPositionIds(uint256 _offerId) external view returns (uint256[] memory) {
        return offers[_offerId].positionIds;
    }

    /// @notice Get the collateral amounts for an offer
    /// @param _offerId The id of the offer
    /// @return The collateral amounts
    function getOfferCollateralAmounts(uint256 _offerId) external view returns (uint256[] memory) {
        return offers[_offerId].collateralAmounts;
    }

    /*//////////////////////////////////////////////////////////////
                                 OFFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a loan offer for a request
    /// @param _loanAmount The usdc amount of the loan
    /// @param _rate The interest rate of the loan
    /// @param _positionIds Array of position IDs
    /// @param _collateralAmounts Array of collateral amounts
    /// @param _minimumLoanAmount Minimum amount to borrow from this offer
    /// @param _duration Duration to what time the loan could be borrowed
    /// @param _perpetual IF the offer can be used again
    /// @return The offer id
    function offer(
        uint256 _loanAmount,
        uint256 _rate,
        uint256[] calldata _positionIds,
        uint256[] calldata _collateralAmounts,
        uint256 _minimumLoanAmount,
        uint256 _duration,
        bool _perpetual
    ) external returns (uint256) {

        if (_duration == 0) {
            revert InvalidDuration();
        }

        if (usdc.balanceOf(msg.sender) < _loanAmount) {
            revert InsufficientFunds();
        }

        if (usdc.allowance(msg.sender, address(this)) < _loanAmount) {
            revert InsufficientAllowance();
        }

        if (_rate <= InterestLib.ONE || _rate > MAX_INTEREST) {
            revert InvalidRate();
        }

        if (_loanAmount == 0) {
            revert InvalidLoanAmount();
        }

        if (_positionIds.length == 0) {
            revert InvalidPositionList();
        }

        if (_collateralAmounts.length != _positionIds.length) {
            revert InvalidCollateralAmounts();
        }

        for (uint256 i = 0; i < _collateralAmounts.length; i++) {
            if (_collateralAmounts[i] == 0) {
                revert CollateralAmountIsZero();
            }
        }

        if (_loanAmount < _minimumLoanAmount) {
            revert InvalidMinimumLoanAmount();
        }

        if(_positionIds.length == 0) {
            revert EmptyPositionList();
        }

        uint256 offerId = nextOfferId;
        nextOfferId += 1;

        offers[offerId] = Offer({
            offerId: offerId,
            lender: msg.sender, 
            loanAmount: _loanAmount, 
            rate: _rate,
            positionIds: _positionIds,
            collateralAmounts: _collateralAmounts,
            minimumLoanAmount: _minimumLoanAmount,
            duration: _duration,
            startTime: block.timestamp,
            borrowedAmount: 0,
            perpetual: _perpetual 
        });

        emit LoanOffered(offerId, msg.sender, _loanAmount, _rate);

        return offerId;
    }

    /// @notice Cancel a loan offer
    /// @param _id The offer id
    function cancelOffer(uint256 _id) public {
        Offer storage _offer = offers[_id];
        if (_offer.lender != msg.sender) {
            revert OnlyLender();
        }

        _offer.lender = address(0);

        emit LoanOfferCanceled(_id);
    }

    /*//////////////////////////////////////////////////////////////
                                 ACCEPT
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept a loan offer
    /// @param _offerId The offer id
    /// @return The loan id
    function accept(uint256 _offerId, uint256 _collateralAmount, uint256 _minimumDuration, uint256 _positionId, bool _useProxy) external returns (uint256) {
        Offer storage _offer = offers[_offerId];

        address borrowerWallet = _useProxy ? safeProxyFactory.computeProxyAddress(msg.sender) : msg.sender;
        address lender = _offer.lender;
        
        if (_collateralAmount == 0) {
            revert CollateralAmountIsZero();
        }

        if (conditionalTokens.balanceOf(borrowerWallet, _positionId) < _collateralAmount) {
            revert InsufficientCollateralBalance();
        }

        if (!conditionalTokens.isApprovedForAll(borrowerWallet, address(this))) {
            revert CollateralIsNotApproved();
        }
 
        if (lender == address(0)) {
            revert InvalidOffer();
        }

        bool positionFound = false;
        uint256 positionIndex = 0;

        uint256[] memory positionIds = _offer.positionIds;
        for (uint256 i =0; i < positionIds.length; i++) {
            positionFound = positionFound || positionIds[i] == _positionId;
            positionIndex = i;
            if (positionFound) {
                break;
            }
        }

        if (!positionFound) {
            revert InvalidPosition();
        }

        uint256 offerCollateralAmount = _offer.collateralAmounts[positionIndex];

        if (offerCollateralAmount < _collateralAmount) {
            revert InvalidCollateralAmount();
        }

        if (block.timestamp + _minimumDuration > _offer.startTime + _offer.duration) {
            revert InvalidMinimumDuration();
        }

        uint256 loanAmount = (_collateralAmount * _offer.loanAmount) / offerCollateralAmount;

        if (loanAmount < _offer.minimumLoanAmount || loanAmount > _offer.loanAmount) {
            revert InvalidLoanAmount();
        }

        if (loanAmount > _offer.loanAmount - _offer.borrowedAmount) {
            revert LoanAmountExceedsLimit();
        }

        uint256 loanId = nextLoanId;
        nextLoanId += 1;

        // create new loan
        loans[loanId] = Loan({
            loanId: loanId,
            borrower: msg.sender,
            borrowerWallet: borrowerWallet,
            lender: lender,
            positionId: _positionId,
            collateralAmount: _collateralAmount,
            loanAmount: loanAmount,
            rate: _offer.rate,
            startTime: block.timestamp,
            minimumDuration: _minimumDuration,
            callTime: 0,
            offerId: _offerId,
            isTransfered: false
        });

        _offer.borrowedAmount += loanAmount;

        // transfer the borrowers collateral to address(this)
        conditionalTokens.safeTransferFrom(borrowerWallet, address(this), _positionId, _collateralAmount, "");

        // transfer usdc from the lender to the borrower
        SafeTransferLib.safeTransferFrom(address(usdc), lender, msg.sender, loanAmount);

        emit LoanAccepted(loanId, _offerId, block.timestamp);

        return loanId;
    }

    /*//////////////////////////////////////////////////////////////
                                  CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Call a loan
    /// @param _loanId The id of the loan
    function call(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        if (loan.lender != msg.sender) {
            revert OnlyLender();
        }

        if (block.timestamp < loan.startTime + loan.minimumDuration) {
            revert MinimumDurationHasNotPassed();
        }

        if (loan.callTime != 0) {
            revert LoanIsCalled();
        }

        loan.callTime = block.timestamp;

        emit LoanCalled(_loanId, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                 REPAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Repay a loan
    /// @notice It is possible that the the block.timestamp will differ
    /// @notice from the time that the transaction is submitted to the
    /// @notice block when it is mined.
    /// @param _loanId The loan id
    /// @param _repayTimestamp The time at which the loan will be paid back
    function repay(uint256 _loanId, uint256 _repayTimestamp) external {
        Loan storage loan = loans[_loanId];
        if (loan.borrower != msg.sender) {
            revert OnlyBorrower();
        }

        // if the loan has not been called,
        // _repayTimestamp can be up to PAYBACK_BUFFER seconds in the past
        if (loan.callTime == 0) {
            if (_repayTimestamp + PAYBACK_BUFFER < block.timestamp) {
                revert InvalidRepayTimestamp();
            }
        }
        // otherwise, the payback time must be the call time
        else {
            if (loan.callTime != _repayTimestamp) {
                revert InvalidRepayTimestamp();
            }
        }

        // compute accrued interest and fee
        uint256 loanAmount = loan.loanAmount;
        uint256 loanDuration = _repayTimestamp - loan.startTime;
        uint256 amountOwed = _calculateAmountOwed(loanAmount, loan.rate, loanDuration);
        uint256 fee = _calculateFee(loanAmount, amountOwed);
        uint256 lenderAmount = amountOwed - fee;

        
        if (!loan.isTransfered) {
            Offer storage loanOffer = offers[loan.offerId];
            if  (loanOffer.perpetual) {
                loanOffer.borrowedAmount -= loan.loanAmount;
            }
        }

        // transfer usdc from the borrower to the lender and fee recipient
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, loan.lender, lenderAmount);
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, feeRecipient, fee);

        // transfer the borrowers collateral back to the borrower's wallet
        conditionalTokens.safeTransferFrom(
            address(this), loan.borrowerWallet, loan.positionId, loan.collateralAmount, ""
        );

        // cancel loan
        loan.borrower = address(0);

        emit LoanRepaid(_loanId);
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer a called loan to a new lender
    /// @notice The new lender must offer a rate less than or equal to the current rate
    /// @param _loanId The loan id
    /// @param _newRate The new interest rate
    function transfer(uint256 _loanId, uint256 _newRate) external {
        Loan storage loan = loans[_loanId];
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        if (loan.callTime == 0) {
            revert LoanIsNotCalled();
        }

        if (block.timestamp > loan.callTime + AUCTION_DURATION) {
            revert AuctionHasEnded();
        }

        if (_newRate < InterestLib.ONE || _newRate > MAX_INTEREST) {
            revert InvalidRate();
        }

        uint256 currentInterestRate = (block.timestamp - loan.callTime) * InterestLib.ONE_THOUSAND_APY / AUCTION_DURATION + InterestLib.ONE;

        // _newRate must be less than or equal to the current offered rate
        if (_newRate > currentInterestRate) {
            revert InvalidRate();
        }

        // calculate amount owed on the loan as of callTime
        uint256 loanAmount = loan.loanAmount;
        uint256 amountOwed = _calculateAmountOwed(
            loanAmount, loan.rate, loan.callTime - loan.startTime
        );

        uint256 loanId = nextLoanId;
        nextLoanId += 1;

        address borrower = loan.borrower;
        address borrowerWallet = loan.borrowerWallet;
        bool isTransfered = loan.isTransfered;

        // create new loan
        loans[loanId] = Loan({
            loanId: loanId,
            borrower: borrower,
            borrowerWallet: borrowerWallet,
            lender: msg.sender,
            positionId: loan.positionId,
            collateralAmount: loan.collateralAmount,
            loanAmount: amountOwed,
            rate: _newRate,
            startTime: block.timestamp,
            minimumDuration: 0,
            callTime: 0,
            offerId: loan.offerId,
            isTransfered: true
        });

        if (!isTransfered) {
            Offer storage loanOffer = offers[loan.offerId];
            if  (loanOffer.perpetual) {
                loanOffer.borrowedAmount -= loan.loanAmount;
            }
        }

        // cancel the old loan
        loan.borrower = address(0);

        // transfer usdc from the new lender to the old lender and pay fees
        uint256 fee = _calculateFee(loanAmount, amountOwed);
        uint256 lenderAmount = amountOwed - fee;
        
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, loan.lender, lenderAmount);
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, feeRecipient, fee);

        emit LoanTransferred(_loanId, loanId, msg.sender, _newRate);
    }

    /*//////////////////////////////////////////////////////////////
                                RECLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Reclaim a called loan after the auction ends
    /// @notice and the loan has not been transferred
    /// @notice The lender will receive the borrower's collateral
    /// @param _loanId The loan id
    function reclaim(uint256 _loanId, bool _useProxy) external {
        Loan storage loan = loans[_loanId];
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        if (loan.lender != msg.sender) {
            revert OnlyLender();
        }

        if (loan.callTime == 0) {
            revert LoanIsNotCalled();
        }

        if (block.timestamp <= loan.callTime + AUCTION_DURATION) {
            revert AuctionHasNotEnded();
        }

        // cancel the loan
        loan.borrower = address(0);

        address lenderWallet = _useProxy ? safeProxyFactory.computeProxyAddress(msg.sender) : msg.sender;

        // transfer the borrower's collateral to the lender
        conditionalTokens.safeTransferFrom(
            address(this), lenderWallet, loan.positionId, loan.collateralAmount, ""
        );

        emit LoanReclaimed(_loanId);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the amount owed on a loan
    /// @param _loanAmount The initial usdc amount of the loan
    /// @param _rate The interest rate of the loan
    /// @param _loanDuration The duration of the loan
    /// @return The total amount owed on the loan
    function _calculateAmountOwed(uint256 _loanAmount, uint256 _rate, uint256 _loanDuration)
        internal
        pure
        returns (uint256)
    {
        uint256 interestMultiplier = _rate.pow(_loanDuration);
        return _loanAmount * interestMultiplier / InterestLib.ONE;
    }

    /// @notice Calculate the fee amount
    /// @param _loanAmount The initial usdc amount of the loan
    /// @param _amountOwed The total amount owed on the loan
    function _calculateFee(uint256 _loanAmount,uint256 _amountOwed)
        internal
        pure
        returns (uint256)
    {
        if (_amountOwed <= _loanAmount) return 0;
        uint256 yield = _amountOwed - _loanAmount;
        return (yield * FEE_PERCENT) / ONE_HUNDRED_PERCENT;
    }
}
