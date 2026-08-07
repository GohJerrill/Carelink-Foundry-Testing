// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CareLinkTypes.sol";

interface ICareLinkStallsForCCNDay {
    function DeleteStallsByCCNDay(uint256 _ccnDayId) external;
}

contract CareLinkCCNDay {
    address public Organiser;

    ICareLinkStallsForCCNDay public stallContract;

    mapping(uint256 => mapping(School => bool)) public CCNEligibleSchools;
    mapping(uint256 => School[]) public CCNEligibleSchoolList;

    uint256 public CurrentCCNDayID;
    uint256 private LastCCNDayID;
    mapping(uint256 => CCNDay) public CCNDays;

    constructor(address _organiserWallet) {
        if (_organiserWallet == address(0)) {
            revert InvalidWallet();
        }

        Organiser = _organiserWallet;
    }

    modifier onlyOrganiser() {
        CheckOnlyOrganiser();
        _;
    }

    function CheckOnlyOrganiser() internal view {
        if (msg.sender != Organiser) {
            revert NotOrganiser();
        }
    }

    function SetStallContractAddress(
        address _stallContractAddress
    ) public onlyOrganiser {
        if (_stallContractAddress == address(0)) {
            revert InvalidWallet();
        }

        stallContract = ICareLinkStallsForCCNDay(_stallContractAddress);
    }

    function IsCurrentCCNDayActive() public view returns (bool) {
        if (CurrentCCNDayID == 0) {
            return false;
        }

        if (CCNDays[CurrentCCNDayID].CCNDayID == 0) {
            return false;
        }

        return block.timestamp <= CCNDays[CurrentCCNDayID].EndDateTime;
    }

    function DoesCCNDayExist(uint256 _ccnDayId) public view returns (bool) {
        return _ccnDayId != 0 && CCNDays[_ccnDayId].CCNDayID != 0;
    }

    function HasDuplicateSchools(
        School[] memory _eligibleSchools
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < _eligibleSchools.length; i++) {
            for (uint256 j = i + 1; j < _eligibleSchools.length; j++) {
                if (_eligibleSchools[i] == _eligibleSchools[j]) {
                    return true;
                }
            }
        }

        return false;
    }

    function ValidateCCNDayInputs(
        string memory _ccnName,
        string memory _ccnDescription,
        uint256 _startDateTime,
        uint256 _endDateTime,
        uint256 _stallRegistrationStartDateTime,
        uint256 _stallRegistrationEndDateTime,
        School[] memory _eligibleSchools
    ) internal pure {
        if (bytes(_ccnName).length == 0) {
            revert EmptyCCNName();
        }

        if (bytes(_ccnDescription).length == 0) {
            revert EmptyCCNDescription();
        }

        if (_startDateTime >= _endDateTime) {
            revert InvalidCCNDateRange();
        }

        if (_stallRegistrationStartDateTime >= _stallRegistrationEndDateTime) {
            revert InvalidRegistrationDateRange();
        }

        if (_stallRegistrationEndDateTime > _startDateTime) {
            revert RegistrationEndsAfterCCNStart();
        }

        if (_eligibleSchools.length == 0) {
            revert EmptyEligibleSchools();
        }

        if (HasDuplicateSchools(_eligibleSchools)) {
            revert DuplicateEligibleSchools();
        }

        for (uint256 i = 0; i < _eligibleSchools.length; i++) {
            if (_eligibleSchools[i] == School.Others) {
                revert EligibleSchoolCannotBeOthers();
            }
        }
    }

    function ClearEligibleSchools(uint256 _ccnDayId) internal {
        School[] memory oldEligibleSchools = CCNEligibleSchoolList[_ccnDayId];

        for (uint256 i = 0; i < oldEligibleSchools.length; i++) {
            CCNEligibleSchools[_ccnDayId][oldEligibleSchools[i]] = false;
        }

        delete CCNEligibleSchoolList[_ccnDayId];
    }

    function SaveEligibleSchools(
        uint256 _ccnDayId,
        School[] memory _eligibleSchools
    ) internal {
        for (uint256 i = 0; i < _eligibleSchools.length; i++) {
            CCNEligibleSchools[_ccnDayId][_eligibleSchools[i]] = true;
            CCNEligibleSchoolList[_ccnDayId].push(_eligibleSchools[i]);
        }
    }

    function IsStallRegistrationOpen() public view returns (bool) {
        if (!IsCurrentCCNDayActive()) {
            return false;
        }

        CCNDay memory currentCCNDay = CCNDays[CurrentCCNDayID];

        return
            block.timestamp >= currentCCNDay.StallRegistrationStartDateTime &&
            block.timestamp <= currentCCNDay.StallRegistrationEndDateTime;
    }

    function CreateNewCCNDay(
        string memory _ccnName,
        string memory _ccnDescription,
        uint256 _startDateTime,
        uint256 _endDateTime,
        uint256 _stallRegistrationStartDateTime,
        uint256 _stallRegistrationEndDateTime,
        School[] memory _eligibleSchools
    ) public onlyOrganiser {
        if (IsCurrentCCNDayActive()) {
            revert CurrentCCNDayStillActive();
        }

        if (_startDateTime <= block.timestamp) {
            revert CCNDayStartTimeNotFuture();
        }

        if (_endDateTime <= block.timestamp) {
            revert CCNDayEndTimeInPast();
        }

        ValidateCCNDayInputs(
            _ccnName,
            _ccnDescription,
            _startDateTime,
            _endDateTime,
            _stallRegistrationStartDateTime,
            _stallRegistrationEndDateTime,
            _eligibleSchools
        );

        LastCCNDayID++;
        uint256 newCCNDayID = LastCCNDayID;

        CurrentCCNDayID = newCCNDayID;

        CCNDays[newCCNDayID] = CCNDay({
            CCNDayID: newCCNDayID,
            CCNName: _ccnName,
            CCNDescription: _ccnDescription,
            StartDateTime: _startDateTime,
            EndDateTime: _endDateTime,
            StallRegistrationStartDateTime: _stallRegistrationStartDateTime,
            StallRegistrationEndDateTime: _stallRegistrationEndDateTime,
            CreatedAt: block.timestamp,
            CreatedBy: msg.sender
        });

        SaveEligibleSchools(newCCNDayID, _eligibleSchools);
    }

    function GetCurrentCCNDay() public view returns (CCNDay memory) {
        if (CurrentCCNDayID == 0) {
            revert NoCurrentCCNDay();
        }

        if (CCNDays[CurrentCCNDayID].CCNDayID == 0) {
            revert CurrentCCNDayDeleted();
        }

        return CCNDays[CurrentCCNDayID];
    }

    function GetCCNDayByID(
        uint256 _ccnDayId
    ) public view returns (CCNDay memory) {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        if (CCNDays[_ccnDayId].CCNDayID == 0) {
            revert CCNDayDoesNotExist();
        }

        return CCNDays[_ccnDayId];
    }

    function GetAllCCNDays() public view returns (CCNDay[] memory) {
        uint256 validCCNDayCount = 0;

        for (uint256 i = 1; i <= LastCCNDayID; i++) {
            if (CCNDays[i].CCNDayID != 0) {
                validCCNDayCount++;
            }
        }

        CCNDay[] memory allCCNDays = new CCNDay[](validCCNDayCount);
        uint256 currentIndex = 0;

        for (uint256 i = 1; i <= LastCCNDayID; i++) {
            if (CCNDays[i].CCNDayID != 0) {
                allCCNDays[currentIndex] = CCNDays[i];
                currentIndex++;
            }
        }

        return allCCNDays;
    }

    function GetCCNDayEligibleSchools(
        uint256 _ccnDayId
    ) public view returns (School[] memory) {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        if (CCNDays[_ccnDayId].CCNDayID == 0) {
            revert CCNDayDoesNotExist();
        }

        return CCNEligibleSchoolList[_ccnDayId];
    }

    function EditCCNDay(
        uint256 _ccnDayId,
        string memory _ccnName,
        string memory _ccnDescription,
        uint256 _startDateTime,
        uint256 _endDateTime,
        uint256 _stallRegistrationStartDateTime,
        uint256 _stallRegistrationEndDateTime,
        School[] memory _eligibleSchools
    ) public onlyOrganiser {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        if (CCNDays[_ccnDayId].CCNDayID == 0) {
            revert CCNDayDoesNotExist();
        }

        if (_ccnDayId != CurrentCCNDayID) {
            revert CanOnlyEditCurrentCCNDay();
        }

        if (_endDateTime <= block.timestamp) {
            revert CCNDayEndTimeInPast();
        }

        ValidateCCNDayInputs(
            _ccnName,
            _ccnDescription,
            _startDateTime,
            _endDateTime,
            _stallRegistrationStartDateTime,
            _stallRegistrationEndDateTime,
            _eligibleSchools
        );

        ClearEligibleSchools(_ccnDayId);
        SaveEligibleSchools(_ccnDayId, _eligibleSchools);

        CCNDays[_ccnDayId].CCNName = _ccnName;
        CCNDays[_ccnDayId].CCNDescription = _ccnDescription;
        CCNDays[_ccnDayId].StartDateTime = _startDateTime;
        CCNDays[_ccnDayId].EndDateTime = _endDateTime;
        CCNDays[_ccnDayId]
            .StallRegistrationStartDateTime = _stallRegistrationStartDateTime;
        CCNDays[_ccnDayId]
            .StallRegistrationEndDateTime = _stallRegistrationEndDateTime;
    }

    function DeleteCCNDay(uint256 _ccnDayId) public onlyOrganiser {
        if (_ccnDayId == 0) {
            revert InvalidCCNDayID();
        }

        if (CCNDays[_ccnDayId].CCNDayID == 0) {
            revert CCNDayDoesNotExist();
        }

        if (_ccnDayId != CurrentCCNDayID) {
            revert CanOnlyDeleteCurrentCCNDay();
        }

        ClearEligibleSchools(_ccnDayId);

        if (address(stallContract) == address(0)) {
            revert InvalidWallet();
        }

        stallContract.DeleteStallsByCCNDay(_ccnDayId);

        delete CCNDays[_ccnDayId];

        CurrentCCNDayID = 0;
    }

    // =============================================================== //
    // HELPER FUNCTIONS FOR OTHER CARELINK CONTRACTS
    // =============================================================== //

    function GetCurrentCCNDayID() public view returns (uint256) {
        return CurrentCCNDayID;
    }

    function IsSchoolEligibleForCurrentCCNDay(
        School _school
    ) public view returns (bool) {
        return CCNEligibleSchools[CurrentCCNDayID][_school];
    }

    function IsSchoolEligibleForCCNDay(
        uint256 _ccnDayId,
        School _school
    ) public view returns (bool) {
        return CCNEligibleSchools[_ccnDayId][_school];
    }

    function GetCCNDayStartTime(
        uint256 _ccnDayId
    ) public view returns (uint256) {
        if (!DoesCCNDayExist(_ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        return CCNDays[_ccnDayId].StartDateTime;
    }

    function GetCCNDayEndTime(uint256 _ccnDayId) public view returns (uint256) {
        if (!DoesCCNDayExist(_ccnDayId)) {
            revert CCNDayDoesNotExist();
        }

        return CCNDays[_ccnDayId].EndDateTime;
    }
}
