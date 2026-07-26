// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CareLinkTypes.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface ICareLinkUsersForPayments {
    function IsWalletRegistered(address _wallet) external view returns (bool);
}

interface ICareLinkCCNDayForPayments {
    function GetCurrentCCNDayID() external view returns (uint256);

    function GetCurrentCCNDay() external view returns (CCNDay memory);
}

interface ICareLinkStallsForPayments {
    function DoesStallExist(uint256 _stallId) external view returns (bool);

    function GetStallOwnerWallet(
        uint256 _stallId
    ) external view returns (address);

    function GetStallCCNDayID(uint256 _stallId) external view returns (uint256);

    function IsStallOpen(uint256 _stallId) external view returns (bool);

    function GetProductPaymentDetails(
        uint256 _productId
    )
        external
        view
        returns (
            uint256 stallId,
            uint256 productPriceSGDCents,
            ProductStatus productStatus
        );

    function IsWalletApprovedStallOwner(
        address _wallet
    ) external view returns (bool);

    function IsStallWithdrawalAllowed(
        uint256 _stallId
    ) external view returns (bool);

    function GetWalletStallID(address _wallet) external view returns (uint256);

    function GetWalletActiveOrUnresolvedStallID(
        address _wallet
    ) external view returns (uint256);

    function MarkStallWithdrawalCompleted(uint256 _stallId) external;
}

contract CareLinkPayments {
    error CCNDayPaymentNotStarted();
    error CCNDayPaymentEnded();
    error StallHasWithdrawablePayments();
    error InvalidOraclePrice();
    error StaleOraclePrice();
    error ProductNotAvailable();
    error IncorrectPaymentAmount(uint256 RequiredWei, uint256 SentWei);

    address public Organiser;

    ICareLinkUsersForPayments public userContract;
    ICareLinkCCNDayForPayments public ccnDayContract;
    ICareLinkStallsForPayments public stallContract;

    AggregatorV3Interface public ethUsdPriceFeed;

    // Example: 1 USD = S$1.29
    // Stored as 129000000 with 8 decimals.
    uint256 public constant USD_TO_SGD_RATE_8_DECIMALS = 129000000;

    // 7 Days. If the oracle price is older than this, do not use it.
    uint256 public constant ORACLE_STALE_TIME_LIMIT = 7 days;

    uint256 private LastPaymentID;
    mapping(uint256 => Payment) public Payments;

    uint256 private LastWithdrawalID;
    mapping(uint256 => Withdrawal) public Withdrawals;

    mapping(address => uint256[]) private CustomerPaymentIDs;
    mapping(address => uint256[]) private OwnerPaymentIDs;
    mapping(uint256 => uint256[]) private StallPaymentIDs;
    mapping(address => uint256[]) private OwnerWithdrawalIDs;
    mapping(uint256 => uint256[]) private StallWithdrawalIDs;

    event PaymentCreated(
        uint256 indexed PaymentID,
        uint256 indexed StallID,
        address CustomerWallet,
        uint256 AmountPaid,
        uint256 AmountPaidSGDCents
    );

    event PaymentRefunded(
        uint256 indexed PaymentID,
        address indexed CustomerWallet,
        uint256 AmountRefunded
    );

    event WithdrawalCreated(
        uint256 indexed WithdrawalID,
        address indexed StallOwnerWallet,
        uint256 Amount
    );

    event StallCompletedWithoutWithdrawal(
        uint256 indexed StallID,
        address indexed StallOwnerWallet
    );

    constructor(
        address _organiserWallet,
        address _userContractAddress,
        address _ccnDayContractAddress,
        address _stallContractAddress,
        address _ethUsdPriceFeedAddress
    ) {
        if (
            _organiserWallet == address(0) ||
            _userContractAddress == address(0) ||
            _ccnDayContractAddress == address(0) ||
            _stallContractAddress == address(0) ||
            _ethUsdPriceFeedAddress == address(0)
        ) {
            revert InvalidWallet();
        }

        Organiser = _organiserWallet;
        userContract = ICareLinkUsersForPayments(_userContractAddress);
        ccnDayContract = ICareLinkCCNDayForPayments(_ccnDayContractAddress);
        stallContract = ICareLinkStallsForPayments(_stallContractAddress);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeedAddress);
    }

    function DoesPaymentExist(uint256 _paymentId) public view returns (bool) {
        return _paymentId != 0 && Payments[_paymentId].PaymentID != 0;
    }

    function CheckCurrentCCNDayPaymentOpen() internal view {
        CCNDay memory currentCCNDay = ccnDayContract.GetCurrentCCNDay();

        if (block.timestamp < currentCCNDay.StartDateTime) {
            revert CCNDayPaymentNotStarted();
        }

        if (block.timestamp > currentCCNDay.EndDateTime) {
            revert CCNDayPaymentEnded();
        }
    }

    function CheckStallCanReceivePayment(uint256 _stallId) internal view {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (
            stallContract.GetStallCCNDayID(_stallId) !=
            ccnDayContract.GetCurrentCCNDayID()
        ) {
            revert StallNotFromCurrentCCNDay();
        }

        CheckCurrentCCNDayPaymentOpen();

        if (!stallContract.IsStallOpen(_stallId)) {
            revert StallNotOpenForPayment();
        }
    }

    function GetLatestETHUSDPrice() public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = ethUsdPriceFeed
            .latestRoundData();

        if (price <= 0) {
            revert InvalidOraclePrice();
        }

        if (
            updatedAt == 0 ||
            block.timestamp - updatedAt > ORACLE_STALE_TIME_LIMIT
        ) {
            revert StaleOraclePrice();
        }

        return uint256(price);
    }

    function CalculateRequiredWeiFromSGDCents(
        uint256 _amountSGDCents
    ) public view returns (uint256) {
        if (_amountSGDCents == 0) {
            revert InvalidPaymentAmount();
        }

        uint256 ethUsdPrice = GetLatestETHUSDPrice();

        uint256 ethSgdPrice = (ethUsdPrice * USD_TO_SGD_RATE_8_DECIMALS) / 1e8;

        return (_amountSGDCents * 1e8 * 1 ether) / ethSgdPrice / 100;
    }

    function CheckExactSGDPayment(
        uint256 _amountSGDCents
    ) internal view returns (uint256) {
        uint256 requiredWei = CalculateRequiredWeiFromSGDCents(_amountSGDCents);

        if (msg.value != requiredWei) {
            revert IncorrectPaymentAmount(requiredWei, msg.value);
        }

        return requiredWei;
    }

    function GetRequiredWeiForProduct(
        uint256 _productId
    )
        public
        view
        returns (
            uint256 stallId,
            uint256 productPriceSGDCents,
            uint256 requiredWei
        )
    {
        ProductStatus productStatus;

        (stallId, productPriceSGDCents, productStatus) = stallContract
            .GetProductPaymentDetails(_productId);

        if (productStatus != ProductStatus.Available) {
            revert ProductNotAvailable();
        }

        requiredWei = CalculateRequiredWeiFromSGDCents(productPriceSGDCents);

        return (stallId, productPriceSGDCents, requiredWei);
    }

    function SavePayment(
        uint256 _stallId,
        uint256 _amountPaidSGDCents
    ) internal returns (uint256) {
        if (msg.sender == Organiser) {
            revert OrganiserCannotPay();
        }

        if (!userContract.IsWalletRegistered(msg.sender)) {
            revert WalletNotRegistered();
        }

        if (msg.value == 0) {
            revert InvalidPaymentAmount();
        }

        address stallOwnerWallet = stallContract.GetStallOwnerWallet(_stallId);

        if (msg.sender == stallOwnerWallet) {
            revert CannotPayOwnStall();
        }

        LastPaymentID++;
        uint256 newPaymentID = LastPaymentID;

        Payments[newPaymentID] = Payment({
            PaymentID: newPaymentID,
            StallID: _stallId,
            CCNDayID: stallContract.GetStallCCNDayID(_stallId),
            CustomerWallet: msg.sender,
            StallOwnerWallet: stallOwnerWallet,
            AmountPaid: msg.value,
            AmountPaidSGDCents: _amountPaidSGDCents,
            PaidAt: block.timestamp,
            RefundedAt: 0,
            paymentStatus: PaymentStatus.Paid
        });

        CustomerPaymentIDs[msg.sender].push(newPaymentID);
        OwnerPaymentIDs[stallOwnerWallet].push(newPaymentID);
        StallPaymentIDs[_stallId].push(newPaymentID);

        emit PaymentCreated(
            newPaymentID,
            _stallId,
            msg.sender,
            msg.value,
            _amountPaidSGDCents
        );

        return newPaymentID;
    }

    function PayToStall(uint256 _stallId) public payable returns (uint256) {
        CheckStallCanReceivePayment(_stallId);

        return SavePayment(_stallId, 0);
    }

    function PaySGDToStall(
        uint256 _stallId,
        uint256 _amountSGDCents
    ) public payable returns (uint256) {
        CheckStallCanReceivePayment(_stallId);

        CheckExactSGDPayment(_amountSGDCents);

        return SavePayment(_stallId, _amountSGDCents);
    }

    function PayForProduct(
        uint256 _productId
    ) public payable returns (uint256) {
        (
            uint256 stallId,
            uint256 productPriceSGDCents,
            ProductStatus productStatus
        ) = stallContract.GetProductPaymentDetails(_productId);

        if (productStatus != ProductStatus.Available) {
            revert ProductNotAvailable();
        }

        CheckStallCanReceivePayment(stallId);

        CheckExactSGDPayment(productPriceSGDCents);

        return SavePayment(stallId, productPriceSGDCents);
    }

    function RefundPayment(uint256 _paymentId) public {
        if (!DoesPaymentExist(_paymentId)) {
            revert PaymentDoesNotExist();
        }

        Payment storage payment = Payments[_paymentId];

        if (payment.StallOwnerWallet != msg.sender) {
            revert NotPaymentReceiver();
        }

        if (payment.paymentStatus != PaymentStatus.Paid) {
            revert PaymentNotPaid();
        }

        payment.paymentStatus = PaymentStatus.Refunded;
        payment.RefundedAt = block.timestamp;

        (bool success, ) = payable(payment.CustomerWallet).call{
            value: payment.AmountPaid
        }("");

        if (!success) {
            revert TransferFailed();
        }

        emit PaymentRefunded(
            _paymentId,
            payment.CustomerWallet,
            payment.AmountPaid
        );
    }

    function CalculateStallWithdrawableBalance(
        uint256 _stallId
    ) internal view returns (uint256) {
        uint256[] memory paymentIds = StallPaymentIDs[_stallId];
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < paymentIds.length; i++) {
            Payment memory payment = Payments[paymentIds[i]];

            if (payment.paymentStatus == PaymentStatus.Paid) {
                totalAmount += payment.AmountPaid;
            }
        }

        return totalAmount;
    }

    function GetStallWithdrawableBalance(
        uint256 _stallId
    ) public view returns (uint256) {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (
            msg.sender != Organiser &&
            stallContract.GetStallOwnerWallet(_stallId) != msg.sender
        ) {
            revert NotAllowedToViewStallTransactions();
        }

        return CalculateStallWithdrawableBalance(_stallId);
    }

    function WithdrawStallPayments(uint256 _stallId) public {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (stallContract.GetStallOwnerWallet(_stallId) != msg.sender) {
            revert OnlyStallOwner();
        }

        if (!stallContract.IsWalletApprovedStallOwner(msg.sender)) {
            revert NotApprovedStallOwner();
        }

        if (!stallContract.IsStallWithdrawalAllowed(_stallId)) {
            revert StallNotReadyForWithdrawal();
        }

        uint256 totalAmount = 0;
        uint256[] memory paymentIds = StallPaymentIDs[_stallId];

        for (uint256 i = 0; i < paymentIds.length; i++) {
            Payment storage payment = Payments[paymentIds[i]];

            if (payment.paymentStatus == PaymentStatus.Paid) {
                payment.paymentStatus = PaymentStatus.Withdrawn;
                totalAmount += payment.AmountPaid;
            }
        }

        if (totalAmount == 0) {
            revert NoWithdrawablePayments();
        }

        LastWithdrawalID++;
        uint256 newWithdrawalID = LastWithdrawalID;

        Withdrawals[newWithdrawalID] = Withdrawal({
            WithdrawalID: newWithdrawalID,
            StallID: _stallId,
            CCNDayID: stallContract.GetStallCCNDayID(_stallId),
            StallOwnerWallet: msg.sender,
            Amount: totalAmount,
            WithdrawnAt: block.timestamp
        });

        OwnerWithdrawalIDs[msg.sender].push(newWithdrawalID);
        StallWithdrawalIDs[_stallId].push(newWithdrawalID);

        stallContract.MarkStallWithdrawalCompleted(_stallId);

        (bool success, ) = payable(msg.sender).call{value: totalAmount}("");

        if (!success) {
            revert TransferFailed();
        }

        emit WithdrawalCreated(newWithdrawalID, msg.sender, totalAmount);
    }

    function CompleteStallWithoutWithdrawal(uint256 _stallId) public {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (stallContract.GetStallOwnerWallet(_stallId) != msg.sender) {
            revert OnlyStallOwner();
        }

        if (!stallContract.IsWalletApprovedStallOwner(msg.sender)) {
            revert NotApprovedStallOwner();
        }

        if (!stallContract.IsStallWithdrawalAllowed(_stallId)) {
            revert StallNotReadyForWithdrawal();
        }

        uint256 withdrawableBalance = CalculateStallWithdrawableBalance(
            _stallId
        );

        if (withdrawableBalance > 0) {
            revert StallHasWithdrawablePayments();
        }

        stallContract.MarkStallWithdrawalCompleted(_stallId);

        emit StallCompletedWithoutWithdrawal(_stallId, msg.sender);
    }

    function HasUnsettledPaidPayments(
        uint256 _stallId
    ) public view returns (bool) {
        uint256[] memory paymentIds = StallPaymentIDs[_stallId];

        for (uint256 i = 0; i < paymentIds.length; i++) {
            if (Payments[paymentIds[i]].paymentStatus == PaymentStatus.Paid) {
                return true;
            }
        }

        return false;
    }

    function BuildTransactionHistory(
        uint256[] memory _paymentIds,
        bool _walletPerspective
    ) internal view returns (TransactionHistoryItem[] memory) {
        uint256 historyCount = _paymentIds.length;

        for (uint256 i = 0; i < _paymentIds.length; i++) {
            if (
                Payments[_paymentIds[i]].paymentStatus == PaymentStatus.Refunded
            ) {
                historyCount++;
            }
        }

        TransactionHistoryItem[] memory history = new TransactionHistoryItem[](
            historyCount
        );

        uint256 currentIndex = 0;

        for (uint256 i = 0; i < _paymentIds.length; i++) {
            Payment memory payment = Payments[_paymentIds[i]];
            int256 amountAsInt = int256(payment.AmountPaid);
            int256 amountSGDCentsAsInt = int256(payment.AmountPaidSGDCents);

            int256 paidSignedAmount;
            int256 refundedSignedAmount;
            int256 paidSignedAmountSGDCents;
            int256 refundedSignedAmountSGDCents;

            if (_walletPerspective) {
                paidSignedAmount = -amountAsInt;
                refundedSignedAmount = amountAsInt;
                paidSignedAmountSGDCents = -amountSGDCentsAsInt;
                refundedSignedAmountSGDCents = amountSGDCentsAsInt;
            } else {
                paidSignedAmount = amountAsInt;
                refundedSignedAmount = -amountAsInt;
                paidSignedAmountSGDCents = amountSGDCentsAsInt;
                refundedSignedAmountSGDCents = -amountSGDCentsAsInt;
            }

            history[currentIndex] = TransactionHistoryItem({
                PaymentID: payment.PaymentID,
                WithdrawalID: 0,
                StallID: payment.StallID,
                CCNDayID: payment.CCNDayID,
                CustomerWallet: payment.CustomerWallet,
                StallOwnerWallet: payment.StallOwnerWallet,
                Amount: payment.AmountPaid,
                SignedAmount: paidSignedAmount,
                AmountSGDCents: payment.AmountPaidSGDCents,
                SignedAmountSGDCents: paidSignedAmountSGDCents,
                TransactionAt: payment.PaidAt,
                transactionType: TransactionHistoryType.PaidTransaction
            });

            currentIndex++;

            if (payment.paymentStatus == PaymentStatus.Refunded) {
                history[currentIndex] = TransactionHistoryItem({
                    PaymentID: payment.PaymentID,
                    WithdrawalID: 0,
                    StallID: payment.StallID,
                    CCNDayID: payment.CCNDayID,
                    CustomerWallet: payment.CustomerWallet,
                    StallOwnerWallet: payment.StallOwnerWallet,
                    Amount: payment.AmountPaid,
                    SignedAmount: refundedSignedAmount,
                    AmountSGDCents: payment.AmountPaidSGDCents,
                    SignedAmountSGDCents: refundedSignedAmountSGDCents,
                    TransactionAt: payment.RefundedAt,
                    transactionType: TransactionHistoryType.RefundedTransaction
                });

                currentIndex++;
            }
        }

        return history;
    }

    function BuildWalletTransactionHistoryWithWithdrawals(
        uint256[] memory _paymentIds,
        uint256[] memory _withdrawalIds
    ) internal view returns (TransactionHistoryItem[] memory) {
        TransactionHistoryItem[]
            memory paymentHistory = BuildTransactionHistory(_paymentIds, true);

        uint256 totalHistoryCount = paymentHistory.length +
            _withdrawalIds.length;

        TransactionHistoryItem[]
            memory fullHistory = new TransactionHistoryItem[](
                totalHistoryCount
            );

        uint256 currentIndex = 0;

        for (uint256 i = 0; i < paymentHistory.length; i++) {
            fullHistory[currentIndex] = paymentHistory[i];
            currentIndex++;
        }

        for (uint256 i = 0; i < _withdrawalIds.length; i++) {
            Withdrawal memory withdrawal = Withdrawals[_withdrawalIds[i]];
            int256 withdrawalAmountAsInt = int256(withdrawal.Amount);

            fullHistory[currentIndex] = TransactionHistoryItem({
                PaymentID: 0,
                WithdrawalID: withdrawal.WithdrawalID,
                StallID: withdrawal.StallID,
                CCNDayID: withdrawal.CCNDayID,
                CustomerWallet: address(0),
                StallOwnerWallet: withdrawal.StallOwnerWallet,
                Amount: withdrawal.Amount,
                SignedAmount: withdrawalAmountAsInt,
                AmountSGDCents: 0,
                SignedAmountSGDCents: 0,
                TransactionAt: withdrawal.WithdrawnAt,
                transactionType: TransactionHistoryType.WithdrawalTransaction
            });

            currentIndex++;
        }

        return fullHistory;
    }

    function BuildStallTransactionHistoryWithWithdrawals(
        uint256[] memory _paymentIds,
        uint256[] memory _withdrawalIds
    ) internal view returns (TransactionHistoryItem[] memory) {
        TransactionHistoryItem[]
            memory paymentHistory = BuildTransactionHistory(_paymentIds, false);

        uint256 totalHistoryCount = paymentHistory.length +
            _withdrawalIds.length;

        TransactionHistoryItem[]
            memory fullHistory = new TransactionHistoryItem[](
                totalHistoryCount
            );

        uint256 currentIndex = 0;

        for (uint256 i = 0; i < paymentHistory.length; i++) {
            fullHistory[currentIndex] = paymentHistory[i];
            currentIndex++;
        }

        for (uint256 i = 0; i < _withdrawalIds.length; i++) {
            Withdrawal memory withdrawal = Withdrawals[_withdrawalIds[i]];
            int256 withdrawalAmountAsInt = int256(withdrawal.Amount);

            fullHistory[currentIndex] = TransactionHistoryItem({
                PaymentID: 0,
                WithdrawalID: withdrawal.WithdrawalID,
                StallID: withdrawal.StallID,
                CCNDayID: withdrawal.CCNDayID,
                CustomerWallet: address(0),
                StallOwnerWallet: withdrawal.StallOwnerWallet,
                Amount: withdrawal.Amount,
                SignedAmount: -withdrawalAmountAsInt,
                AmountSGDCents: 0,
                SignedAmountSGDCents: 0,
                TransactionAt: withdrawal.WithdrawnAt,
                transactionType: TransactionHistoryType.WithdrawalTransaction
            });

            currentIndex++;
        }

        return fullHistory;
    }

    // function GetMyPurchasePaymentIDs() public view returns (uint256[] memory) {
    //     return CustomerPaymentIDs[msg.sender];
    // }

    // function GetMyReceivedPaymentIDs() public view returns (uint256[] memory) {
    //     return OwnerPaymentIDs[msg.sender];
    // }

    function GetStallPaymentIDs(
        uint256 _stallId
    ) public view returns (uint256[] memory) {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        return StallPaymentIDs[_stallId];
    }

    // Dont Delete First
    // function CanMyWalletWithdraw()
    //     public
    //     view
    //     returns (
    //         bool canWithdraw,
    //         uint256 stallId,
    //         uint256 withdrawableBalance,
    //         bool isApprovedStallOwner,
    //         bool allowedWithdrawal
    //     )
    // {
    //     stallId = stallContract.GetWalletStallID(msg.sender);
    //     withdrawableBalance = GetMyWithdrawableBalance();
    //     isApprovedStallOwner = stallContract.IsWalletApprovedStallOwner(
    //         msg.sender
    //     );
    //
    //     if (stallId == 0) {
    //         return (
    //             false,
    //             stallId,
    //             withdrawableBalance,
    //             isApprovedStallOwner,
    //             false
    //         );
    //     }
    //
    //     if (!stallContract.DoesStallExist(stallId)) {
    //         return (
    //             false,
    //             stallId,
    //             withdrawableBalance,
    //             isApprovedStallOwner,
    //             false
    //         );
    //     }
    //
    //     allowedWithdrawal = stallContract.IsStallWithdrawalAllowed(stallId);
    //
    //     canWithdraw =
    //         stallContract.GetStallOwnerWallet(stallId) == msg.sender &&
    //         isApprovedStallOwner &&
    //         allowedWithdrawal &&
    //         withdrawableBalance > 0;
    //
    //     return (
    //         canWithdraw,
    //         stallId,
    //         withdrawableBalance,
    //         isApprovedStallOwner,
    //         allowedWithdrawal
    //     );
    // }

    function GetMyWithdrawableBalance() public view returns (uint256) {
        uint256 stallId = stallContract.GetWalletActiveOrUnresolvedStallID(
            msg.sender
        );

        if (stallId == 0) {
            return 0;
        }

        if (!stallContract.DoesStallExist(stallId)) {
            return 0;
        }

        if (stallContract.GetStallOwnerWallet(stallId) != msg.sender) {
            return 0;
        }

        return CalculateStallWithdrawableBalance(stallId);
    }

    function GetMyWalletTransactionHistory()
        public
        view
        returns (TransactionHistoryItem[] memory)
    {
        if (!userContract.IsWalletRegistered(msg.sender)) {
            revert WalletNotRegistered();
        }

        uint256[] memory paymentIds = CustomerPaymentIDs[msg.sender];
        uint256[] memory withdrawalIds = OwnerWithdrawalIDs[msg.sender];

        return
            BuildWalletTransactionHistoryWithWithdrawals(
                paymentIds,
                withdrawalIds
            );
    }

    function GetMyStallTransactionHistory()
        public
        view
        returns (TransactionHistoryItem[] memory)
    {
        uint256 stallId = stallContract.GetWalletActiveOrUnresolvedStallID(
            msg.sender
        );

        if (stallId == 0) {
            revert WalletHasNotCreatedStall();
        }

        if (!stallContract.DoesStallExist(stallId)) {
            revert StallDoesNotExist();
        }

        uint256[] memory paymentIds = StallPaymentIDs[stallId];
        uint256[] memory withdrawalIds = StallWithdrawalIDs[stallId];

        return
            BuildStallTransactionHistoryWithWithdrawals(
                paymentIds,
                withdrawalIds
            );
    }

    function GetStallTransactionHistory(
        uint256 _stallId
    ) public view returns (TransactionHistoryItem[] memory) {
        if (!stallContract.DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (
            msg.sender != Organiser &&
            stallContract.GetStallOwnerWallet(_stallId) != msg.sender
        ) {
            revert NotAllowedToViewStallTransactions();
        }

        uint256[] memory paymentIds = StallPaymentIDs[_stallId];
        uint256[] memory withdrawalIds = StallWithdrawalIDs[_stallId];

        return
            BuildStallTransactionHistoryWithWithdrawals(
                paymentIds,
                withdrawalIds
            );
    }
}
