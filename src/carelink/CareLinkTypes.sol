// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================== //
// ENUMS
// =============================================================== //

enum UserType {
    None,
    Student,
    Staff,
    Customer
}

enum School {
    IIT,
    Business,
    Engineering,
    Design,
    Science,
    Humanities,
    Others
}

enum StallType {
    FoodAndBeverage,
    Games,
    Gifts,
    PreOwnedRecycling,
    Services,
    Performance,
    Others
}

enum StallStatus {
    Pending,
    Open,
    Closed,
    Rejected,
    Expired
}

enum ProductStatus {
    Available,
    Unavailable
}

enum PaymentStatus {
    Paid,
    Refunded,
    Withdrawn
}

enum TransactionHistoryType {
    PaidTransaction,
    RefundedTransaction,
    WithdrawalTransaction
}

// =============================================================== //
// STRUCTS
// =============================================================== //

struct UserProfile {
    address WalletAddress;
    string Username;
    UserType usertype;
    School school;
    bool IsRegistered;
    uint256 RegisteredAt;
}

struct CCNDay {
    uint256 CCNDayID;
    string CCNName;
    string CCNDescription;
    uint256 StartDateTime;
    uint256 EndDateTime;
    uint256 StallRegistrationStartDateTime;
    uint256 StallRegistrationEndDateTime;
    uint256 CreatedAt;
    address CreatedBy;
}

struct Stall {
    uint256 StallID;
    string StallName;
    string StallDescription;
    string StallImage;
    StallType stallType;
    address StallOwnerWallet;
    string StallLocation;
    School StallSchool;
    bool NeedElectricalPort;
    uint256 CreatedAt;
    StallStatus stallStatus;
    bool AllowedWithdrawal;
    uint256 CCNDayID;
    bool WithdrawalCompleted;
}

struct Product {
    uint256 ProductID;
    uint256 StallID;
    string ProductName;
    string ProductDescription;
    string ProductImage;
    uint256 ProductPriceSGDCents;
    ProductStatus productStatus;
}

struct Payment {
    uint256 PaymentID;
    uint256 StallID;
    uint256 CCNDayID;
    address CustomerWallet;
    address StallOwnerWallet;
    uint256 AmountPaid;
    uint256 PaidAt;
    uint256 RefundedAt;
    uint256 AmountPaidSGDCents;
    PaymentStatus paymentStatus;
}

struct Withdrawal {
    uint256 WithdrawalID;
    uint256 StallID;
    uint256 CCNDayID;
    address StallOwnerWallet;
    uint256 Amount;
    uint256 WithdrawnAt;
}

struct TransactionHistoryItem {
    uint256 PaymentID;
    uint256 WithdrawalID;
    uint256 StallID;
    uint256 CCNDayID;
    address CustomerWallet;
    address StallOwnerWallet;
    uint256 Amount;
    int256 SignedAmount;
    uint256 AmountSGDCents;
    int256 SignedAmountSGDCents;
    uint256 TransactionAt;
    TransactionHistoryType transactionType;
}

// =============================================================== //
// CUSTOM ERRORS
// =============================================================== //

error NotOrganiser();
error AlreadyRegistered();

error EmptyCCNName();
error EmptyCCNDescription();
error InvalidCCNDateRange();
error InvalidRegistrationDateRange();
error RegistrationEndsAfterCCNStart();
error EmptyEligibleSchools();
error DuplicateEligibleSchools();
error EligibleSchoolCannotBeOthers();

error EmptyStallName();
error EmptyStallDescription();
error EmptyStallImage();
error StallNameTooLong();
error StallDescriptionTooLong();

error EmptyUsername();
error UsernameTooLong();

error InvalidWallet();
error OrganiserCannotBeStaff();
error StaffAlreadyWhitelisted();
error StaffNotWhitelisted();

error OrganiserCannotRegister();
error WhitelistedStaffMustRegisterAsStaff();
error StudentCannotSelectOthers();
error WalletNotRegistered();
error NotStudentOrCustomer();

error CurrentCCNDayStillActive();
error CCNDayEndTimeInPast();
error NoCurrentCCNDay();
error CurrentCCNDayDeleted();
error InvalidCCNDayID();
error CCNDayDoesNotExist();
error CCNDayAlreadyStarted();
error CCNDayAlreadyEnded();
error CanOnlyEditCurrentCCNDay();
error CanOnlyDeleteCurrentCCNDay();

error OrganiserCannotCreateStall();
error NotStudentOrStaff();
error WalletAlreadyCreatedStall();
error CurrentCCNDayDoesNotExist();
error CurrentCCNDayNotActive();
error StallRegistrationNotOpen();
error SchoolNotEligible();

error StallDoesNotExist();
error OnlyPendingStallCanBeApproved();
error EmptyStallLocation();
error StallLocationTooLong();
error StallNotFromCurrentCCNDay();
error OnlyPendingStallCanBeRejected();
error OnlyPendingStallCanBeExpired();
error PendingStallDecisionWindowStillOpen();
error OnlyStallOwner();
error NotApprovedStallOwner();
error OnlyOpenOrClosedCanBeUpdated();
error OwnerCanOnlySetOpenOrClosed();
error WalletHasNotCreatedStall();
error OnlyOpenOrClosedCanBeDeleted();

error ProductDoesNotExist();
error EmptyProductName();
error EmptyProductDescription();
error EmptyProductImage();
error ProductNameTooLong();
error ProductDescriptionTooLong();
error ProductImageTooLong();
error ProductPriceMustBeMoreThanZero();

error InvalidPaymentAmount();
error StallNotOpenForPayment();
error PaymentDoesNotExist();
error PaymentNotPaid();
error NotPaymentReceiver();
error TransferFailed();
error CannotPayOwnStall();
error OrganiserCannotPay();
error StallNotReadyForWithdrawal();
error CCNDayNotEnded();
error WithdrawalAlreadyAllowed();
error NotAllowedToViewStallTransactions();
error CannotDeleteStallDuringCCNDay();
error StallHasUnsettledPaidPayments();
error NoWithdrawablePayments();
error WalletHasUnresolvedStall();
error NotPaymentContract();
