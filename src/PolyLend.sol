// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "../lib/solady/src/tokens/ERC20.sol";
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
}

/// @notice Request struct
struct Request {
    uint256 requestId;
    address borrower;
    address borrowerWallet;
    uint256 positionId;
    uint256 collateralAmount;
    uint256 minimumDuration;
}

/// @notice Offer struct
struct Offer {
    uint256 offerId;
    uint256 requestId;
    address lender;
    uint256 loanAmount;
    uint256 rate;
}

/// @title PolyLendEE
/// @notice PolyLend events and errors
interface IPolyLend {
    event LoanAccepted(uint256 indexed id, uint256 indexed requestId, uint256 indexed offerId, uint256 startTime);
    event LoanCalled(uint256 indexed id, uint256 callTime);
    event LoanOffered(uint256 indexed id, uint256 indexed requestId, address indexed lender, uint256 loanAmount, uint256 rate);
    event LoanRepaid(uint256 indexed id);
    event LoanRequested(
        uint256 indexed id, 
        address indexed borrower,
        address indexed borrowerWallet, 
        uint256 positionId, 
        uint256 collateralAmount, 
        uint256 minimumDuration
    );
    event LoanTransferred(uint256 indexed oldId, uint256 indexed newId, address indexed newLender, uint256 newRate);
    event LoanReclaimed(uint256 indexed id);
    event LoanRequestCanceled(uint256 indexed id);
    event LoanOfferCanceled(uint256 indexed id);

    error CollateralAmountIsZero();
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

    /// @notice requests mapping
    mapping(uint256 => Request) public requests;

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

    /*//////////////////////////////////////////////////////////////
                                REQUEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a request for loan offers
    /// @param _positionId The conditional token position id
    /// @param _collateralAmount The amount of collateral
    /// @param _minimumDuration The minimum duration of the loan
    /// @return The request id
    function request(uint256 _positionId, uint256 _collateralAmount, uint256 _minimumDuration, bool _useProxy)
        external
        returns (uint256)
    {
        if (_collateralAmount == 0) {
            revert CollateralAmountIsZero();
        }

        address borrowerWallet = _useProxy ? safeProxyFactory.computeProxyAddress(msg.sender) : msg.sender;
        
        if (conditionalTokens.balanceOf(borrowerWallet, _positionId) < _collateralAmount) {
            revert InsufficientCollateralBalance();
        }

        if (!conditionalTokens.isApprovedForAll(borrowerWallet, address(this))) {
            revert CollateralIsNotApproved();
        }

        uint256 requestId = nextRequestId;
        nextRequestId += 1;

        requests[requestId] = Request(requestId, msg.sender, borrowerWallet, _positionId, _collateralAmount, _minimumDuration);
        emit LoanRequested(requestId, msg.sender, borrowerWallet, _positionId, _collateralAmount, _minimumDuration);

        return requestId;
    }

    /// @notice Cancel a loan request
    /// @param _requestId The request id
    function cancelRequest(uint256 _requestId) public {
        Request storage _request = requests[_requestId];
        if (_request.borrower != msg.sender) {
            revert OnlyBorrower();
        }

        _request.borrower = address(0);

        emit LoanRequestCanceled(_requestId);
    }

    /*//////////////////////////////////////////////////////////////
                                 OFFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a loan offer for a request
    /// @param _requestId The request id
    /// @param _loanAmount The usdc amount of the loan
    /// @param _rate The interest rate of the loan
    /// @return The offer id
    function offer(uint256 _requestId, uint256 _loanAmount, uint256 _rate) external returns (uint256) {
        Request storage _request = requests[_requestId];
        if (_request.borrower == address(0)) {
            revert InvalidRequest();
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

        uint256 offerId = nextOfferId;
        nextOfferId += 1;

        offers[offerId] = Offer(offerId, _requestId, msg.sender, _loanAmount, _rate);

        emit LoanOffered(offerId, _requestId, msg.sender, _loanAmount, _rate);

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
    function accept(uint256 _offerId) external returns (uint256) {
        Offer storage _offer = offers[_offerId];
        uint256 requestId = _offer.requestId;
        Request storage _request = requests[requestId];
        address borrower = _request.borrower;
        address borrowerWallet = _request.borrowerWallet;
        address lender = _offer.lender;

        if (borrower != msg.sender) {
            revert OnlyBorrower();
        }

        if (lender == address(0)) {
            revert InvalidOffer();
        }

        uint256 loanId = nextLoanId;
        nextLoanId += 1;

        uint256 positionId = _request.positionId;
        uint256 collateralAmount = _request.collateralAmount;
        uint256 loanAmount = _offer.loanAmount;


        // create new loan
        loans[loanId] = Loan({
            loanId: loanId,
            borrower: borrower,
            borrowerWallet: borrowerWallet,
            lender: lender,
            positionId: positionId,
            collateralAmount: collateralAmount,
            loanAmount: loanAmount,
            rate: _offer.rate,
            startTime: block.timestamp,
            minimumDuration: _request.minimumDuration,
            callTime: 0
        });

        // invalidate the request
        _request.borrower = address(0);

        // invalidate the offer
        _offer.lender = address(0);

        // transfer the borrowers collateral to address(this)
        conditionalTokens.safeTransferFrom(borrowerWallet, address(this), positionId, collateralAmount, "");

        // transfer usdc from the lender to the borrower
        usdc.transferFrom(lender, msg.sender, loanAmount);

        emit LoanAccepted(loanId, requestId, _offerId, block.timestamp);

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
        uint256 fee = _calcualteFee(loanAmount, amountOwed);
        uint256 lenderAmount = amountOwed - fee;

        // transfer usdc from the borrower to the lender and fee recipient
        usdc.transferFrom(msg.sender, loan.lender, lenderAmount);
        usdc.transferFrom(msg.sender, feeRecipient, fee);

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
            callTime: 0
        });

        // cancel the old loan
        loan.borrower = address(0);

        // transfer usdc from the new lender to the old lender and pay fees
        uint256 fee = _calcualteFee(loanAmount, amountOwed);
        uint256 lenderAmount = amountOwed - fee;
        
        usdc.transferFrom(msg.sender, loan.lender, lenderAmount);
        usdc.transferFrom(msg.sender, feeRecipient, fee);

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
    function _calcualteFee(uint256 _loanAmount,uint256 _amountOwed)
        internal
        pure
        returns (uint256)
    {
        uint256 yield = _amountOwed - _loanAmount;
        return (yield * FEE_PERCENT) / ONE_HUNDRED_PERCENT;
    }
}
