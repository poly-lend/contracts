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
    /// @notice The unique identifier for this loan
    uint256 loanId;
    /// @notice The borrower's address (set to address(0) when loan is closed)
    address borrower;
    /// @notice The wallet holding the borrower's collateral (may be a Safe proxy)
    address borrowerWallet;
    /// @notice The lender's address
    address lender;
    /// @notice The conditional token position id used as collateral
    uint256 positionId;
    /// @notice The amount of conditional tokens locked as collateral
    uint256 collateralAmount;
    /// @notice The USDC amount of the loan
    uint256 loanAmount;
    /// @notice The per-second compound interest rate
    uint256 rate;
    /// @notice The timestamp when the loan was created
    uint256 startTime;
    /// @notice The minimum duration before the lender can call the loan
    uint256 minimumDuration;
    /// @notice The timestamp when the loan was called (0 if not called)
    uint256 callTime;
    /// @notice The id of the offer this loan was created from
    uint256 offerId;
    /// @notice Whether this loan was created via a transfer (not the original offer)
    bool isTransfered;
}

/// @notice Offer struct
struct Offer {
    /// @notice The unique identifier for this offer
    uint256 offerId;
    /// @notice The lender's address (set to address(0) when offer is canceled)
    address lender;
    /// @notice The maximum USDC amount available to borrow
    uint256 loanAmount;
    /// @notice The per-second compound interest rate
    uint256 rate;
    /// @notice The minimum USDC amount a borrower must take per loan
    uint256 minimumLoanAmount;
    /// @notice The duration window (in seconds) during which the offer can be accepted
    uint256 duration;
    /// @notice The timestamp when the offer was created
    uint256 startTime;
    /// @notice The total USDC amount currently borrowed from this offer
    uint256 borrowedAmount;
    /// @notice The conditional token position ids accepted as collateral
    uint256[] positionIds;
    /// @notice The maximum collateral amount for each position id (determines loan-to-collateral ratio)
    uint256[] collateralAmounts;
    /// @notice Whether the offer replenishes after loans are repaid
    bool perpetual;
}

/// @title PolyLendEE
/// @notice PolyLend events and errors
interface IPolyLend {
    event LoanAccepted(uint256 indexed id, uint256 indexed offerId, address indexed borrower, uint256 startTime);
    event LoanCalled(uint256 indexed id, uint256 callTime);
    event LoanOffered(uint256 indexed id, address indexed lender, uint256 loanAmount, uint256 rate);
    event LoanRepaid(uint256 indexed id, uint256 indexed offerId);
    event LoanTransferred(
        uint256 indexed oldId, uint256 indexed newId, address indexed newLender, uint256 offerId, uint256 newRate
    );
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
    error MinimumLoanDurationNotMet();
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

    /// @notice minimum loan duration before repay is allowed
    uint256 public constant MINIMUM_LOAN_DURATION = 1 days;

    /// @notice protocol fee from lenders yield in basis points
    uint256 public constant FEE_PERCENT = 10_00;

    /// @notice hundred percent in basis points
    uint256 public constant ONE_HUNDRED_PERCENT = 100_00;

    /// @notice The conditional tokens contract
    IConditionalTokens public immutable conditionalTokens;

    /// @notice The Safe proxy factory contract for computing proxy addresses
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

    constructor(address _conditionalTokens, address _usdc, address _safeProxyFactory, address _feeRecipient) {
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        usdc = ERC20(_usdc);
        safeProxyFactory = ISafeProxyFactory(_safeProxyFactory);
        feeRecipient = _feeRecipient;
    }

    /// @notice Get the amount owed on a loan
    /// @param _loanId The id of the loan
    /// @param _paybackTime The time at which the loan will be paid back
    /// @return The amount owed on the loan
    function getAmountOwed(uint256 _loanId, uint256 _paybackTime) external view returns (uint256) {
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

    /// @notice Submit a loan offer
    /// @param _loanAmount The maximum USDC amount available to borrow
    /// @param _rate The per-second compound interest rate (must be > ONE and <= MAX_INTEREST)
    /// @param _positionIds Array of conditional token position IDs accepted as collateral
    /// @param _collateralAmounts Array of maximum collateral amounts corresponding to each position
    /// @param _minimumLoanAmount The minimum USDC amount a borrower must take per loan
    /// @param _duration The time window (in seconds) during which the offer can be accepted
    /// @param _perpetual Whether the offer replenishes its capacity after loans are repaid
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

        if (_loanAmount == 0) {
            revert InvalidLoanAmount();
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

        if (_positionIds.length == 0) {
            revert InvalidPositionList();
        }

        if (_positionIds.length != _collateralAmounts.length) {
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

    /// @notice Cancel a loan offer by zeroing the lender address
    /// @notice Only the lender who created the offer can cancel it
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

    /// @notice Accept a loan offer by depositing collateral and receiving USDC
    /// @notice The loan amount is proportional to collateral provided vs the offer's collateral amount
    /// @param _offerId The offer id
    /// @param _collateralAmount The amount of conditional tokens to deposit as collateral
    /// @param _minimumDuration The minimum time (in seconds) before the lender can call the loan
    /// @param _positionId The conditional token position id to use as collateral
    /// @param _useProxy Whether the borrower's collateral is held in a Safe proxy wallet
    /// @return The loan id
    function accept(
        uint256 _offerId,
        uint256 _collateralAmount,
        uint256 _minimumDuration,
        uint256 _positionId,
        bool _useProxy
    ) external returns (uint256) {
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

        // find the position in the offer's accepted positions list
        bool positionFound = false;
        uint256 positionIndex = 0;

        uint256[] memory positionIds = _offer.positionIds;
        for (uint256 i = 0; i < positionIds.length; i++) {
            positionFound = positionFound || positionIds[i] == _positionId;
            positionIndex = i;
            if (positionFound) {
                break;
            }
        }

        if (!positionFound) {
            revert InvalidPosition();
        }

        // collateral must not exceed the offer's max for this position
        uint256 offerCollateralAmount = _offer.collateralAmounts[positionIndex];

        if (offerCollateralAmount < _collateralAmount) {
            revert InvalidCollateralAmount();
        }

        // minimum duration must not extend beyond the offer's time window
        if (block.timestamp + _minimumDuration > _offer.startTime + _offer.duration) {
            revert InvalidMinimumDuration();
        }

        // calculate loan amount proportional to collateral provided
        uint256 loanAmount = (_collateralAmount * _offer.loanAmount) / offerCollateralAmount;

        if (loanAmount < _offer.minimumLoanAmount) {
            revert InvalidLoanAmount();
        }

        // ensure enough capacity remains in the offer
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

        // track borrowed amount against the offer's capacity
        _offer.borrowedAmount += loanAmount;

        // transfer the borrower's collateral to this contract
        conditionalTokens.safeTransferFrom(borrowerWallet, address(this), _positionId, _collateralAmount, "");

        // transfer usdc from the lender to the borrower
        SafeTransferLib.safeTransferFrom(address(usdc), lender, msg.sender, loanAmount);

        emit LoanAccepted(loanId, _offerId, msg.sender, block.timestamp);

        return loanId;
    }

    /*//////////////////////////////////////////////////////////////
                                  CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Call a loan, starting the auction for transfer or reclaim
    /// @notice Only the lender can call, and only after the minimum duration has passed
    /// @notice Once called, the borrower can repay at the call time rate, or a new lender
    /// @notice can transfer the loan during the AUCTION_DURATION window
    /// @param _loanId The id of the loan
    function call(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];

        // loan must exist (borrower != address(0) means active)
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        if (loan.lender != msg.sender) {
            revert OnlyLender();
        }

        // lender must wait for the agreed minimum duration before calling
        if (block.timestamp < loan.startTime + loan.minimumDuration) {
            revert MinimumDurationHasNotPassed();
        }

        // loan can only be called once
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

        // loan must have existed for at least MINIMUM_LOAN_DURATION
        if (_repayTimestamp < loan.startTime + MINIMUM_LOAN_DURATION) {
            revert MinimumLoanDurationNotMet();
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

        // restore perpetual offer capacity if this is the original loan (not transferred)
        if (!loan.isTransfered) {
            Offer storage loanOffer = offers[loan.offerId];
            if (loanOffer.perpetual) {
                loanOffer.borrowedAmount -= loan.loanAmount;
            }
        }

        if (usdc.allowance(msg.sender, address(this)) < amountOwed) {
            revert InsufficientAllowance();
        }

        // cancel loan before external calls (CEI pattern)
        loan.borrower = address(0);

        // pay the lender (minus protocol fee) and the fee recipient
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, loan.lender, lenderAmount);
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, feeRecipient, fee);

        // return the borrower's collateral
        conditionalTokens.safeTransferFrom(
            address(this), loan.borrowerWallet, loan.positionId, loan.collateralAmount, ""
        );

        emit LoanRepaid(_loanId, loan.offerId);
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer a called loan to a new lender via Dutch auction
    /// @notice The auction starts at the call time and lasts AUCTION_DURATION
    /// @notice The acceptable interest rate increases linearly from ONE to MAX_INTEREST
    /// @notice over the auction window, allowing new lenders to bid as the rate rises
    /// @param _loanId The loan id
    /// @param _newRate The new interest rate for the transferred loan
    function transfer(uint256 _loanId, uint256 _newRate) external {
        Loan storage loan = loans[_loanId];

        // loan must exist
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        // loan must have been called to start the auction
        if (loan.callTime == 0) {
            revert LoanIsNotCalled();
        }

        // auction must still be active
        if (block.timestamp > loan.callTime + AUCTION_DURATION) {
            revert AuctionHasEnded();
        }

        // new rate must be within valid bounds (must be > ONE, matching offer validation)
        if (_newRate <= InterestLib.ONE || _newRate > MAX_INTEREST) {
            revert InvalidRate();
        }

        // compute the current auction rate (increases linearly over the auction window)
        uint256 currentInterestRate = InterestLib.ONE
            + ((block.timestamp - loans[_loanId].callTime) * (MAX_INTEREST - InterestLib.ONE) / AUCTION_DURATION);

        // new lender must offer a rate at or below the current auction rate
        if (_newRate > currentInterestRate) {
            revert InvalidRate();
        }

        // calculate amount owed on the loan as of callTime (interest stops accruing at call)
        uint256 loanAmount = loan.loanAmount;
        uint256 amountOwed = _calculateAmountOwed(loanAmount, loan.rate, loan.callTime - loan.startTime);

        uint256 loanId = nextLoanId;
        nextLoanId += 1;

        // cache values before modifying storage
        address borrower = loan.borrower;
        address borrowerWallet = loan.borrowerWallet;
        bool isTransfered = loan.isTransfered;

        // create new loan with the new lender and rate
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

        // restore perpetual offer capacity if this is the original loan (not already transferred)
        if (!isTransfered) {
            Offer storage loanOffer = offers[loan.offerId];
            if (loanOffer.perpetual) {
                loanOffer.borrowedAmount -= loan.loanAmount;
            }
        }

        // cancel the old loan before external calls (CEI pattern)
        loan.borrower = address(0);

        // pay the old lender (minus protocol fee) from the new lender
        uint256 fee = _calculateFee(loanAmount, amountOwed);
        uint256 lenderAmount = amountOwed - fee;

        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, loan.lender, lenderAmount);
        SafeTransferLib.safeTransferFrom(address(usdc), msg.sender, feeRecipient, fee);

        emit LoanTransferred(_loanId, loanId, msg.sender, loan.offerId, _newRate);
    }

    /*//////////////////////////////////////////////////////////////
                                RECLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Reclaim a called loan after the auction ends without a transfer
    /// @notice The lender seizes the borrower's collateral as compensation
    /// @notice Only callable after AUCTION_DURATION has passed since the call
    /// @param _loanId The loan id
    /// @param _useProxy Whether to send collateral to the lender's Safe proxy wallet
    function reclaim(uint256 _loanId, bool _useProxy) external {
        Loan storage loan = loans[_loanId];

        // loan must exist
        if (loan.borrower == address(0)) {
            revert InvalidLoan();
        }

        if (loan.lender != msg.sender) {
            revert OnlyLender();
        }

        // loan must have been called
        if (loan.callTime == 0) {
            revert LoanIsNotCalled();
        }

        // auction must have ended without a transfer
        if (block.timestamp <= loan.callTime + AUCTION_DURATION) {
            revert AuctionHasNotEnded();
        }

        // cancel the loan before external calls (CEI pattern)
        loan.borrower = address(0);

        address lenderWallet = _useProxy ? safeProxyFactory.computeProxyAddress(msg.sender) : msg.sender;

        // transfer the borrower's collateral to the lender as compensation
        conditionalTokens.safeTransferFrom(address(this), lenderWallet, loan.positionId, loan.collateralAmount, "");

        emit LoanReclaimed(_loanId);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the amount owed on a loan using compound interest
    /// @notice Uses exponentiation by squaring via InterestLib.pow
    /// @param _loanAmount The initial USDC amount of the loan
    /// @param _rate The per-second compound interest rate
    /// @param _loanDuration The duration of the loan in seconds
    /// @return The total amount owed (principal + accrued interest)
    function _calculateAmountOwed(uint256 _loanAmount, uint256 _rate, uint256 _loanDuration)
        internal
        pure
        returns (uint256)
    {
        uint256 interestMultiplier = _rate.pow(_loanDuration);
        return _loanAmount * interestMultiplier / InterestLib.ONE;
    }

    /// @notice Calculate the protocol fee as a percentage of yield (interest earned)
    /// @notice Returns 0 if there is no yield (amountOwed <= loanAmount)
    /// @param _loanAmount The initial USDC amount of the loan
    /// @param _amountOwed The total amount owed on the loan (principal + interest)
    /// @return The protocol fee amount
    function _calculateFee(uint256 _loanAmount, uint256 _amountOwed) internal pure returns (uint256) {
        if (_amountOwed <= _loanAmount) return 0;
        uint256 yield = _amountOwed - _loanAmount;
        return (yield * FEE_PERCENT) / ONE_HUNDRED_PERCENT;
    }
}
