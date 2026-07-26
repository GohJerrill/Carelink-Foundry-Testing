//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CareLinkTypes.sol";

interface ICareLinkUsersForStalls {
    function IsWalletRegistered(address _wallet) external view returns (bool);
    function GetWalletUserType(
        address _wallet
    ) external view returns (UserType);
    function GetWalletSchool(address _wallet) external view returns (School);
}

interface ICareLinkCCNDayForStalls {
    function GetCurrentCCNDayID() external view returns (uint256);
    function DoesCCNDayExist(uint256 _ccnDayId) external view returns (bool);
    function IsCurrentCCNDayActive() external view returns (bool);
    function IsStallRegistrationOpen() external view returns (bool);
    function IsSchoolEligibleForCurrentCCNDay(
        School _school
    ) external view returns (bool);
    function GetCCNDayStartTime(
        uint256 _ccnDayId
    ) external view returns (uint256);
    function GetCCNDayEndTime(
        uint256 _ccnDayId
    ) external view returns (uint256);
}

interface ICareLinkPaymentsForStalls {
    function HasUnsettledPaidPayments(
        uint256 _stallId
    ) external view returns (bool);
}

contract CareLinkStalls {
    address public Organiser;
    address public CCNDayContractAddress;

    ICareLinkUsersForStalls public userContract;
    ICareLinkCCNDayForStalls public ccnDayContract;
    ICareLinkPaymentsForStalls public paymentContract;

    uint256 private LastStallID;
    mapping(uint256 => Stall) private Stalls;
    uint256[] private StallIDList;

    uint256 private LastProductID;
    mapping(uint256 => Product) public Products;

    mapping(address => bool) public IsStallOwner;
    mapping(address => bool) public HasCreatedStall;
    mapping(address => uint256) public WalletStallID;

    mapping(address => uint256[]) private OwnerStallIDs;
    mapping(address => mapping(uint256 => uint256)) public OwnerStallIDByCCNDay;

    mapping(uint256 => uint256[]) public StallProductIDs;
    mapping(uint256 => uint256[]) public CCNDayStallIDs;

    event StallCreated(
        uint256 indexed StallID,
        uint256 indexed CCNDayID,
        address indexed StallOwnerWallet
    );

    event StallApproved(
        uint256 indexed StallID,
        address indexed StallOwnerWallet
    );

    event StallRejected(uint256 indexed StallID);

    // event StallExpired(
    //     uint256 indexed StallID,
    //     address indexed StallOwnerWallet
    // );

    event StallStatusUpdated(
        uint256 indexed StallID,
        StallStatus OldStatus,
        StallStatus NewStatus
    );

    event StallDeleted(uint256 indexed StallID, address DeleteBy);

    event ProductCreated(uint256 indexed ProductId, uint256 StallID);

    event ProductUpdated(uint256 indexed ProductID);

    event ProductAvailabilityUpdated(
        uint256 indexed ProductID,
        ProductStatus NewStatus
    );

    event ProductDeleted(uint256 indexed ProductID, uint256 indexed StallID);

    event StallWithdrawalAllowed(
        uint256 indexed StallID,
        address indexed StallOwnerWallet
    );

    event StallWithdrawalCompleted(
        uint256 indexed StallID,
        address indexed StallOwnerWallet
    );

    constructor(
        address _organiserWallet,
        address _userContractAddress,
        address _ccnDayContractAddress
    ) {
        if (
            _organiserWallet == address(0) ||
            _userContractAddress == address(0) ||
            _ccnDayContractAddress == address(0)
        ) {
            revert InvalidWallet();
        }

        Organiser = _organiserWallet;
        userContract = ICareLinkUsersForStalls(_userContractAddress);
        ccnDayContract = ICareLinkCCNDayForStalls(_ccnDayContractAddress);
        CCNDayContractAddress = _ccnDayContractAddress;
    }

    modifier onlyOrganiser() {
        CheckOnlyOrganiser();
        _;
    }

    function CheckOnlyPaymentContract() internal view {
        if (msg.sender != address(paymentContract)) {
            revert NotPaymentContract();
        }
    }

    modifier onlyCCNDayContract() {
        if (msg.sender != CCNDayContractAddress) {
            revert NotOrganiser();
        }
        _;
    }

    function CheckOnlyOrganiser() internal view {
        if (msg.sender != Organiser) {
            revert NotOrganiser();
        }
    }

    function SetPaymentContractAddress(
        address _paymentContractAddress
    ) public onlyOrganiser {
        if (_paymentContractAddress == address(0)) {
            revert InvalidWallet();
        }

        paymentContract = ICareLinkPaymentsForStalls(_paymentContractAddress);
    }

    function DoesStallExist(uint256 _stallId) public view returns (bool) {
        return _stallId != 0 && Stalls[_stallId].StallID != 0;
    }

    // function GenerateRandomStallID(
    //     string memory _stallName,
    //     address _stallOwnerWallet
    // ) internal returns (uint256) {
    //     StallRandomNonce++;
    //
    //     return
    //         uint256(
    //             keccak256(
    //                 abi.encodePacked(
    //                     block.timestamp,
    //                     block.prevrandao,
    //                     msg.sender,
    //                     CurrentCCNDayID,
    //                     _stallName,
    //                     _stallOwnerWallet,
    //                     StallRandomNonce
    //                 )
    //             )
    //         );
    // }

    function ValidateStallInputs(
        string memory _stallName,
        string memory _stallDescription,
        string memory _stallImage
    ) internal pure {
        if (bytes(_stallName).length == 0) {
            revert EmptyStallName();
        }

        if (bytes(_stallDescription).length == 0) {
            revert EmptyStallDescription();
        }

        if (bytes(_stallImage).length == 0) {
            revert EmptyStallImage();
        }

        if (bytes(_stallName).length > 80) {
            revert StallNameTooLong();
        }

        if (bytes(_stallDescription).length > 500) {
            revert StallDescriptionTooLong();
        }
    }

    function CanWalletCreateStall(address _wallet) public view returns (bool) {
        if (_wallet == Organiser) {
            return false;
        }

        if (HasCreatedStallForCurrentCCNDay(_wallet)) {
            return false;
        }

        if (HasUnresolvedStall(_wallet)) {
            return false;
        }

        if (!ccnDayContract.IsStallRegistrationOpen()) {
            return false;
        }

        if (!userContract.IsWalletRegistered(_wallet)) {
            return false;
        }

        UserType userType = userContract.GetWalletUserType(_wallet);

        if (userType == UserType.Staff) {
            return true;
        }

        if (userType != UserType.Student) {
            return false;
        }

        School userSchool = userContract.GetWalletSchool(_wallet);

        return ccnDayContract.IsSchoolEligibleForCurrentCCNDay(userSchool);
    }

    function GetCCNDayStallCount(
        uint256 _ccnDayId
    ) public view returns (uint256) {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        uint256[] memory stallIds = CCNDayStallIDs[_ccnDayId];
        uint256 validStallCount = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (DoesStallExist(stallIds[i])) {
                validStallCount++;
            }
        }

        return validStallCount;
    }

    function HasCreatedStallForCurrentCCNDay(
        address _wallet
    ) public view returns (bool) {
        uint256 currentCCNDayID = ccnDayContract.GetCurrentCCNDayID();

        if (currentCCNDayID == 0) {
            return false;
        }

        uint256 stallId = OwnerStallIDByCCNDay[_wallet][currentCCNDayID];

        return DoesStallExist(stallId);
    }

    function IsStallCCNDayEnded(uint256 _stallId) public view returns (bool) {
        if (!DoesStallExist(_stallId)) {
            return false;
        }

        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
            return false;
        }

        return block.timestamp > ccnDayContract.GetCCNDayEndTime(ccnDayId);
    }

    function IsPendingStallExpired(
        uint256 _stallId
    ) internal view returns (bool) {
        if (
            !DoesStallExist(_stallId) ||
            Stalls[_stallId].stallStatus != StallStatus.Pending
        ) {
            return false;
        }

        return
            block.timestamp >=
            ccnDayContract.GetCCNDayStartTime(Stalls[_stallId].CCNDayID);
    }

    function GetEffectiveStallStatus(
        uint256 _stallId
    ) internal view returns (StallStatus) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (IsPendingStallExpired(_stallId)) {
            return StallStatus.Expired;
        }

        return Stalls[_stallId].stallStatus;
    }

    function IsStallArchived(uint256 _stallId) public view returns (bool) {
        if (!DoesStallExist(_stallId)) {
            return false;
        }

        return
            IsStallCCNDayEnded(_stallId) &&
            Stalls[_stallId].WithdrawalCompleted;
    }

    function IsStallActiveOrUnresolved(
        uint256 _stallId
    ) public view returns (bool) {
        if (!DoesStallExist(_stallId)) {
            return false;
        }

        if (Stalls[_stallId].WithdrawalCompleted) {
            return false;
        }

        if (Stalls[_stallId].stallStatus == StallStatus.Rejected) {
            return false;
        }

        if (Stalls[_stallId].stallStatus == StallStatus.Expired) {
            return false;
        }

        if (IsPendingStallExpired(_stallId)) {
            return false;
        }

        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
            return false;
        }

        if (ccnDayId == ccnDayContract.GetCurrentCCNDayID()) {
            return true;
        }

        return IsStallCCNDayEnded(_stallId);
    }

    function HasUnresolvedStall(address _wallet) public view returns (bool) {
        uint256[] memory stallIds = OwnerStallIDs[_wallet];

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (IsStallActiveOrUnresolved(stallIds[i])) {
                return true;
            }
        }

        return false;
    }

    function GetWalletActiveOrUnresolvedStallID(
        address _wallet
    ) public view returns (uint256) {
        uint256 currentCCNDayID = ccnDayContract.GetCurrentCCNDayID();

        if (currentCCNDayID != 0) {
            uint256 currentStallId = OwnerStallIDByCCNDay[_wallet][
                currentCCNDayID
            ];

            if (IsStallActiveOrUnresolved(currentStallId)) {
                return currentStallId;
            }
        }

        uint256[] memory stallIds = OwnerStallIDs[_wallet];

        for (uint256 i = stallIds.length; i > 0; i--) {
            uint256 stallId = stallIds[i - 1];

            if (IsStallActiveOrUnresolved(stallId)) {
                return stallId;
            }
        }

        return 0;
    }

    function CompleteMyExpiredPendingStall(uint256 _stallId) public {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        Stall storage stall = Stalls[_stallId];

        if (stall.StallOwnerWallet != msg.sender) {
            revert OnlyStallOwner();
        }

        if (stall.stallStatus != StallStatus.Pending) {
            revert OnlyPendingStallCanBeExpired();
        }

        uint256 ccnDayId = stall.CCNDayID;

        if (block.timestamp < ccnDayContract.GetCCNDayStartTime(ccnDayId)) {
            revert PendingStallDecisionWindowStillOpen();
        }

        stall.stallStatus = StallStatus.Expired;

        if (WalletStallID[msg.sender] == _stallId) {
            delete WalletStallID[msg.sender];
            HasCreatedStall[msg.sender] = false;
        }

        if (OwnerStallIDByCCNDay[msg.sender][ccnDayId] == _stallId) {
            delete OwnerStallIDByCCNDay[msg.sender][ccnDayId];
        }

        emit StallStatusUpdated(
            _stallId,
            StallStatus.Pending,
            StallStatus.Expired
        );
    }

    function DeleteStallData(uint256 _stallId) internal {
        address stallOwnerWallet = Stalls[_stallId].StallOwnerWallet;

        uint256[] memory productIds = StallProductIDs[_stallId];

        for (uint256 i = 0; i < productIds.length; i++) {
            delete Products[productIds[i]];
        }

        delete StallProductIDs[_stallId];

        if (WalletStallID[stallOwnerWallet] == _stallId) {
            delete WalletStallID[stallOwnerWallet];
            HasCreatedStall[stallOwnerWallet] = false;
            IsStallOwner[stallOwnerWallet] = false;
        }

        delete Stalls[_stallId];
    }

    // function IsStallCCNDayOngoing(
    //     uint256 _stallId
    // ) internal view returns (bool) {
    //     uint256 ccnDayId = Stalls[_stallId].CCNDayID;

    //     if (ccnDayId == 0) {
    //         return false;
    //     }

    //     if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
    //         return false;
    //     }

    //     return
    //         block.timestamp >= ccnDayContract.GetCCNDayStartTime(ccnDayId) &&
    //         block.timestamp <= ccnDayContract.GetCCNDayEndTime(ccnDayId);
    // }

    function HasUnsettledPaidPayments(
        uint256 _stallId
    ) internal view returns (bool) {
        if (address(paymentContract) == address(0)) {
            return false;
        }

        return paymentContract.HasUnsettledPaidPayments(_stallId);
    }

    function ValidateStallCanBeDeleted(uint256 _stallId) internal view {
        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        if (block.timestamp >= ccnDayContract.GetCCNDayStartTime(ccnDayId)) {
            revert CCNDayAlreadyStarted();
        }

        if (HasUnsettledPaidPayments(_stallId)) {
            revert StallHasUnsettledPaidPayments();
        }
    }

    function DoesProductExist(uint256 _productId) public view returns (bool) {
        return _productId != 0 && Products[_productId].ProductID != 0;
    }

    function ValidateProductInputs(
        string memory _productName,
        string memory _productDescription,
        string memory _productImage,
        uint256 _productPriceSGDCents
    ) internal pure {
        if (bytes(_productName).length == 0) {
            revert EmptyProductName();
        }

        if (bytes(_productDescription).length == 0) {
            revert EmptyProductDescription();
        }

        if (bytes(_productImage).length == 0) {
            revert EmptyProductImage();
        }

        if (bytes(_productName).length > 80) {
            revert ProductNameTooLong();
        }

        if (bytes(_productDescription).length > 500) {
            revert ProductDescriptionTooLong();
        }

        if (bytes(_productImage).length > 300) {
            revert ProductImageTooLong();
        }

        if (_productPriceSGDCents == 0) {
            revert ProductPriceMustBeMoreThanZero();
        }
    }

    function CheckCanManageStallProduct(uint256 _stallId) internal view {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (Stalls[_stallId].StallOwnerWallet != msg.sender) {
            revert OnlyStallOwner();
        }

        if (!IsStallOwner[msg.sender]) {
            revert NotApprovedStallOwner();
        }

        if (
            Stalls[_stallId].stallStatus != StallStatus.Open &&
            Stalls[_stallId].stallStatus != StallStatus.Closed
        ) {
            revert OnlyOpenOrClosedCanBeUpdated();
        }

        if (IsStallCCNDayEnded(_stallId)) {
            revert CCNDayAlreadyEnded();
        }
    }

    function RemoveProductIDFromStall(
        uint256 _stallId,
        uint256 _productId
    ) internal {
        uint256[] storage productIds = StallProductIDs[_stallId];

        for (uint256 i = 0; i < productIds.length; i++) {
            if (productIds[i] == _productId) {
                productIds[i] = productIds[productIds.length - 1];
                productIds.pop();
                break;
            }
        }
    }

    function CreateStall(
        string memory _stallName,
        string memory _stallDescription,
        string memory _stallImage,
        StallType _stallType,
        bool _needElectricalPort
    ) public returns (uint256) {
        if (msg.sender == Organiser) {
            revert OrganiserCannotCreateStall();
        }

        if (!userContract.IsWalletRegistered(msg.sender)) {
            revert WalletNotRegistered();
        }

        UserType userType = userContract.GetWalletUserType(msg.sender);

        if (userType != UserType.Student && userType != UserType.Staff) {
            revert NotStudentOrStaff();
        }

        if (HasCreatedStallForCurrentCCNDay(msg.sender)) {
            revert WalletAlreadyCreatedStall();
        }

        if (HasUnresolvedStall(msg.sender)) {
            revert WalletHasUnresolvedStall();
        }

        uint256 currentCCNDayID = ccnDayContract.GetCurrentCCNDayID();

        if (currentCCNDayID == 0) {
            revert NoCurrentCCNDay();
        }

        if (!ccnDayContract.DoesCCNDayExist(currentCCNDayID)) {
            revert CurrentCCNDayDoesNotExist();
        }

        if (!ccnDayContract.IsCurrentCCNDayActive()) {
            revert CurrentCCNDayNotActive();
        }

        if (!ccnDayContract.IsStallRegistrationOpen()) {
            revert StallRegistrationNotOpen();
        }

        if (userType == UserType.Student) {
            School userSchool = userContract.GetWalletSchool(msg.sender);

            if (!ccnDayContract.IsSchoolEligibleForCurrentCCNDay(userSchool)) {
                revert SchoolNotEligible();
            }
        }

        ValidateStallInputs(_stallName, _stallDescription, _stallImage);

        LastStallID++;
        uint256 newStallID = LastStallID;

        Stalls[newStallID] = Stall({
            StallID: newStallID,
            StallName: _stallName,
            StallDescription: _stallDescription,
            StallImage: _stallImage,
            stallType: _stallType,
            StallOwnerWallet: msg.sender,
            StallLocation: "",
            StallSchool: School.Others,
            NeedElectricalPort: _needElectricalPort,
            CreatedAt: block.timestamp,
            stallStatus: StallStatus.Pending,
            AllowedWithdrawal: false,
            CCNDayID: currentCCNDayID,
            WithdrawalCompleted: false
        });

        StallIDList.push(newStallID);
        CCNDayStallIDs[currentCCNDayID].push(newStallID);

        OwnerStallIDs[msg.sender].push(newStallID);
        OwnerStallIDByCCNDay[msg.sender][currentCCNDayID] = newStallID;

        HasCreatedStall[msg.sender] = true;
        WalletStallID[msg.sender] = newStallID;

        emit StallCreated(newStallID, currentCCNDayID, msg.sender);

        return newStallID;
    }

    function ApproveStall(
        uint256 _stallId,
        string memory _stallLocation,
        School _stallSchool
    ) public onlyOrganiser {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (Stalls[_stallId].stallStatus != StallStatus.Pending) {
            revert OnlyPendingStallCanBeApproved();
        }

        if (bytes(_stallLocation).length == 0) {
            revert EmptyStallLocation();
        }

        if (bytes(_stallLocation).length > 120) {
            revert StallLocationTooLong();
        }

        if (_stallSchool == School.Others) {
            revert EligibleSchoolCannotBeOthers();
        }

        if (Stalls[_stallId].CCNDayID != ccnDayContract.GetCurrentCCNDayID()) {
            revert StallNotFromCurrentCCNDay();
        }

        if (!ccnDayContract.IsCurrentCCNDayActive()) {
            revert CurrentCCNDayNotActive();
        }

        ValidateStallDecisionWindow(_stallId);

        Stalls[_stallId].StallLocation = _stallLocation;
        Stalls[_stallId].StallSchool = _stallSchool;
        Stalls[_stallId].stallStatus = StallStatus.Open;

        IsStallOwner[Stalls[_stallId].StallOwnerWallet] = true;

        emit StallApproved(_stallId, Stalls[_stallId].StallOwnerWallet);
    }

    function AllowStallWithdrawal(uint256 _stallId) public onlyOrganiser {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        if (block.timestamp <= ccnDayContract.GetCCNDayEndTime(ccnDayId)) {
            revert CCNDayNotEnded();
        }

        if (
            Stalls[_stallId].stallStatus != StallStatus.Open &&
            Stalls[_stallId].stallStatus != StallStatus.Closed
        ) {
            revert StallNotReadyForWithdrawal();
        }

        if (Stalls[_stallId].AllowedWithdrawal) {
            revert WithdrawalAlreadyAllowed();
        }

        Stalls[_stallId].AllowedWithdrawal = true;

        emit StallWithdrawalAllowed(
            _stallId,
            Stalls[_stallId].StallOwnerWallet
        );
    }

    function MarkStallWithdrawalCompleted(uint256 _stallId) public {
        CheckOnlyPaymentContract();

        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        Stalls[_stallId].WithdrawalCompleted = true;

        address stallOwnerWallet = Stalls[_stallId].StallOwnerWallet;

        uint256 replacementStallId = GetWalletActiveOrUnresolvedStallID(
            stallOwnerWallet
        );

        if (replacementStallId == 0) {
            delete WalletStallID[stallOwnerWallet];
            HasCreatedStall[stallOwnerWallet] = false;
        } else {
            WalletStallID[stallOwnerWallet] = replacementStallId;
            HasCreatedStall[stallOwnerWallet] = true;
        }

        emit StallWithdrawalCompleted(_stallId, stallOwnerWallet);
    }

    function RejectStall(uint256 _stallId) public onlyOrganiser {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (Stalls[_stallId].stallStatus != StallStatus.Pending) {
            revert OnlyPendingStallCanBeRejected();
        }

        if (Stalls[_stallId].CCNDayID != ccnDayContract.GetCurrentCCNDayID()) {
            revert StallNotFromCurrentCCNDay();
        }

        ValidateStallDecisionWindow(_stallId);

        address stallOwnerWallet = Stalls[_stallId].StallOwnerWallet;

        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        Stalls[_stallId].stallStatus = StallStatus.Rejected;

        if (OwnerStallIDByCCNDay[stallOwnerWallet][ccnDayId] == _stallId) {
            delete OwnerStallIDByCCNDay[stallOwnerWallet][ccnDayId];
        }

        if (WalletStallID[stallOwnerWallet] == _stallId) {
            uint256 replacementStallId = GetWalletActiveOrUnresolvedStallID(
                stallOwnerWallet
            );

            if (replacementStallId == 0) {
                delete WalletStallID[stallOwnerWallet];
                HasCreatedStall[stallOwnerWallet] = false;
            } else {
                WalletStallID[stallOwnerWallet] = replacementStallId;
                HasCreatedStall[stallOwnerWallet] = true;
            }
        }

        IsStallOwner[stallOwnerWallet] = IsWalletApprovedStallOwner(
            stallOwnerWallet
        );

        emit StallRejected(_stallId);
    }

    function UpdateMyStallOpenStatus(
        uint256 _stallId,
        StallStatus _newStatus
    ) public {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (Stalls[_stallId].StallOwnerWallet != msg.sender) {
            revert OnlyStallOwner();
        }

        if (!IsStallOwner[msg.sender]) {
            revert NotApprovedStallOwner();
        }

        if (
            Stalls[_stallId].stallStatus != StallStatus.Open &&
            Stalls[_stallId].stallStatus != StallStatus.Closed
        ) {
            revert OnlyOpenOrClosedCanBeUpdated();
        }

        if (
            _newStatus != StallStatus.Open && _newStatus != StallStatus.Closed
        ) {
            revert OwnerCanOnlySetOpenOrClosed();
        }

        if (IsStallCCNDayEnded(_stallId)) {
            revert CCNDayAlreadyEnded();
        }

        StallStatus oldStatus = Stalls[_stallId].stallStatus;
        Stalls[_stallId].stallStatus = _newStatus;

        emit StallStatusUpdated(_stallId, oldStatus, _newStatus);
    }

    function GetStallDetails(
        uint256 _stallId
    ) public view returns (Stall memory) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        Stall memory stall = Stalls[_stallId];
        stall.stallStatus = GetEffectiveStallStatus(_stallId);

        return stall;
    }

    function GetMyStall() public view returns (Stall memory) {
        uint256 stallId = GetWalletActiveOrUnresolvedStallID(msg.sender);

        if (stallId == 0) {
            revert WalletHasNotCreatedStall();
        }

        if (!DoesStallExist(stallId)) {
            revert StallDoesNotExist();
        }

        return Stalls[stallId];
    }

    function GetMyStallHistory() public view returns (Stall[] memory) {
        uint256[] memory stallIds = OwnerStallIDs[msg.sender];
        uint256 historyCount = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (IsStallArchived(stallIds[i])) {
                historyCount++;
            }
        }

        Stall[] memory historyStalls = new Stall[](historyCount);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (IsStallArchived(stallIds[i])) {
                historyStalls[currentIndex] = Stalls[stallIds[i]];
                currentIndex++;
            }
        }

        return historyStalls;
    }

    function GetCurrentCCNDayStalls() public view returns (Stall[] memory) {
        uint256 currentCCNDayID = ccnDayContract.GetCurrentCCNDayID();

        if (currentCCNDayID == 0) {
            revert NoCurrentCCNDay();
        }

        if (!ccnDayContract.DoesCCNDayExist(currentCCNDayID)) {
            revert CurrentCCNDayDoesNotExist();
        }

        uint256[] memory stallIds = CCNDayStallIDs[currentCCNDayID];

        uint256 validStallCount = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (DoesStallExist(stallIds[i])) {
                validStallCount++;
            }
        }

        Stall[] memory currentStalls = new Stall[](validStallCount);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (DoesStallExist(stallIds[i])) {
                Stall memory stall = Stalls[stallIds[i]];
                stall.stallStatus = GetEffectiveStallStatus(stallIds[i]);

                currentStalls[currentIndex] = stall;
                currentIndex++;
            }
        }

        return currentStalls;
    }

    function GetCCNDayStalls(
        uint256 _ccnDayId
    ) public view returns (Stall[] memory) {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        if (!ccnDayContract.DoesCCNDayExist(_ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        uint256[] memory stallIds = CCNDayStallIDs[_ccnDayId];

        uint256 validStallCount = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (DoesStallExist(stallIds[i])) {
                validStallCount++;
            }
        }

        Stall[] memory ccnDayStalls = new Stall[](validStallCount);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < stallIds.length; i++) {
            if (DoesStallExist(stallIds[i])) {
                Stall memory stall = Stalls[stallIds[i]];
                stall.stallStatus = GetEffectiveStallStatus(stallIds[i]);

                ccnDayStalls[currentIndex] = stall;
                currentIndex++;
            }
        }

        return ccnDayStalls;
    }

    function ValidateStallDecisionWindow(uint256 _stallId) internal view {
        uint256 ccnDayId = Stalls[_stallId].CCNDayID;

        if (!ccnDayContract.DoesCCNDayExist(ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        if (block.timestamp >= ccnDayContract.GetCCNDayStartTime(ccnDayId)) {
            revert CCNDayAlreadyStarted();
        }
    }

    // function GetAllStalls() public view returns (Stall[] memory) {
    //     uint256 validStallCount = 0;
    //
    //     for (uint256 i = 0; i < StallIDList.length; i++) {
    //         if (DoesStallExist(StallIDList[i])) {
    //             validStallCount++;
    //         }
    //     }
    //
    //     Stall[] memory allStalls = new Stall[](validStallCount);
    //     uint256 currentIndex = 0;
    //
    //     for (uint256 i = 0; i < StallIDList.length; i++) {
    //         if (DoesStallExist(StallIDList[i])) {
    //             allStalls[currentIndex] = Stalls[StallIDList[i]];
    //             currentIndex++;
    //         }
    //     }
    //
    //     return allStalls;
    // }

    function DeleteStall(uint256 _stallId) public onlyOrganiser {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        ValidateStallCanBeDeleted(_stallId);

        DeleteStallData(_stallId);

        emit StallDeleted(_stallId, msg.sender);
    }

    function DeleteMyStall(uint256 _stallId) public {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        if (Stalls[_stallId].StallOwnerWallet != msg.sender) {
            revert OnlyStallOwner();
        }

        if (!IsStallOwner[msg.sender]) {
            revert NotApprovedStallOwner();
        }

        if (
            Stalls[_stallId].stallStatus != StallStatus.Open &&
            Stalls[_stallId].stallStatus != StallStatus.Closed
        ) {
            revert OnlyOpenOrClosedCanBeDeleted();
        }

        ValidateStallCanBeDeleted(_stallId);

        DeleteStallData(_stallId);

        emit StallDeleted(_stallId, msg.sender);
    }

    function DeleteStallsByCCNDay(
        uint256 _ccnDayId
    ) external onlyCCNDayContract {
        uint256[] memory stallIds = CCNDayStallIDs[_ccnDayId];

        for (uint256 i = 0; i < stallIds.length; i++) {
            uint256 stallId = stallIds[i];

            if (DoesStallExist(stallId)) {
                ValidateStallCanBeDeleted(stallId);
                DeleteStallData(stallId);
                emit StallDeleted(stallId, msg.sender);
            }
        }

        delete CCNDayStallIDs[_ccnDayId];
    }

    function CreateProduct(
        uint256 _stallId,
        string memory _productName,
        string memory _productDescription,
        string memory _productImage,
        uint256 _productPriceSGDCents,
        ProductStatus _productStatus
    ) public returns (uint256) {
        CheckCanManageStallProduct(_stallId);

        ValidateProductInputs(
            _productName,
            _productDescription,
            _productImage,
            _productPriceSGDCents
        );

        LastProductID++;
        uint256 newProductID = LastProductID;

        Products[newProductID] = Product({
            ProductID: newProductID,
            StallID: _stallId,
            ProductName: _productName,
            ProductDescription: _productDescription,
            ProductImage: _productImage,
            ProductPriceSGDCents: _productPriceSGDCents,
            productStatus: _productStatus
        });

        StallProductIDs[_stallId].push(newProductID);

        emit ProductCreated(newProductID, _stallId);

        return newProductID;
    }

    function EditProduct(
        uint256 _productId,
        string memory _productName,
        string memory _productDescription,
        string memory _productImage,
        uint256 _productPriceSGDCents,
        ProductStatus _productStatus
    ) public {
        if (!DoesProductExist(_productId)) {
            revert ProductDoesNotExist();
        }

        uint256 stallId = Products[_productId].StallID;

        CheckCanManageStallProduct(stallId);

        ValidateProductInputs(
            _productName,
            _productDescription,
            _productImage,
            _productPriceSGDCents
        );

        ProductStatus oldProductStatus = Products[_productId].productStatus;

        Products[_productId].ProductName = _productName;
        Products[_productId].ProductDescription = _productDescription;
        Products[_productId].ProductImage = _productImage;
        Products[_productId].ProductPriceSGDCents = _productPriceSGDCents;
        Products[_productId].productStatus = _productStatus;

        emit ProductUpdated(_productId);

        if (oldProductStatus != _productStatus) {
            emit ProductAvailabilityUpdated(_productId, _productStatus);
        }
    }

    // function GetAllProductsByStallID(
    //     uint256 _stallId
    // ) public view returns (Product[] memory) {
    //     if (!DoesStallExist(_stallId)) {
    //         revert StallDoesNotExist();
    //     }
    //
    //     uint256[] memory productIds = StallProductIDs[_stallId];
    //
    //     Product[] memory stallProducts = new Product[](productIds.length);
    //
    //     for (uint256 i = 0; i < productIds.length; i++) {
    //         stallProducts[i] = Products[productIds[i]];
    //     }
    //
    //     return stallProducts;
    // }

    function GetProductIDsByStallID(
        uint256 _stallId
    ) public view returns (uint256[] memory) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        return StallProductIDs[_stallId];
    }

    function GetProductPaymentDetails(
        uint256 _productId
    )
        public
        view
        returns (
            uint256 stallId,
            uint256 productPriceSGDCents,
            ProductStatus productStatus
        )
    {
        if (!DoesProductExist(_productId)) {
            revert ProductDoesNotExist();
        }

        Product memory product = Products[_productId];

        return (
            product.StallID,
            product.ProductPriceSGDCents,
            product.productStatus
        );
    }

    // function SetProductAvailability(
    //     uint256 _productId,
    //     ProductStatus _productStatus
    // ) public {
    //     if (!DoesProductExist(_productId)) {
    //         revert ProductDoesNotExist();
    //     }

    //     uint256 stallId = Products[_productId].StallID;

    //     CheckCanManageStallProduct(stallId);

    //     Products[_productId].productStatus = _productStatus;

    //     emit ProductAvailabilityUpdated(_productId, _productStatus);
    // }

    function DeleteProduct(uint256 _productId) public {
        if (!DoesProductExist(_productId)) {
            revert ProductDoesNotExist();
        }

        uint256 stallId = Products[_productId].StallID;

        CheckCanManageStallProduct(stallId);

        RemoveProductIDFromStall(stallId, _productId);

        delete Products[_productId];

        emit ProductDeleted(_productId, stallId);
    }

    // =============================================================== //
    // HELPER FUNCTIONS FOR PAYMENT CONTRACT
    // =============================================================== //

    function GetStallOwnerWallet(
        uint256 _stallId
    ) public view returns (address) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        return Stalls[_stallId].StallOwnerWallet;
    }

    function GetStallCCNDayID(uint256 _stallId) public view returns (uint256) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        return Stalls[_stallId].CCNDayID;
    }

    function IsStallOpen(uint256 _stallId) public view returns (bool) {
        return
            DoesStallExist(_stallId) &&
            Stalls[_stallId].stallStatus == StallStatus.Open;
    }

    function IsWalletApprovedStallOwner(
        address _wallet
    ) public view returns (bool) {
        uint256[] memory stallIds = OwnerStallIDs[_wallet];

        for (uint256 i = 0; i < stallIds.length; i++) {
            uint256 stallId = stallIds[i];

            if (
                DoesStallExist(stallId) &&
                Stalls[stallId].StallOwnerWallet == _wallet &&
                !Stalls[stallId].WithdrawalCompleted &&
                (Stalls[stallId].stallStatus == StallStatus.Open ||
                    Stalls[stallId].stallStatus == StallStatus.Closed)
            ) {
                return true;
            }
        }

        return false;
    }

    function IsStallWithdrawalAllowed(
        uint256 _stallId
    ) public view returns (bool) {
        if (!DoesStallExist(_stallId)) {
            revert StallDoesNotExist();
        }

        return Stalls[_stallId].AllowedWithdrawal;
    }

    function GetWalletStallID(address _wallet) public view returns (uint256) {
        return GetWalletActiveOrUnresolvedStallID(_wallet);
    }

    function GetOwnerStallIDs(
        address _wallet
    ) public view returns (uint256[] memory) {
        return OwnerStallIDs[_wallet];
    }
}
