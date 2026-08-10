// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CareLinkTypes.sol";

contract CareLinkUsers {
    address public Organiser;

    mapping(address => bool) public StaffWhiteList;
    address[] public StaffWhiteListArray;

    mapping(address => UserProfile) public Users;

    constructor() {
        Organiser = msg.sender;
    }

    modifier onlyOrganiser() {
        CheckOnlyOrganiser();
        _;
    }

    modifier onlyUnregisteredUser() {
        CheckOnlyUnregisteredUser();
        _;
    }

    function CheckOnlyOrganiser() internal view {
        if (msg.sender != Organiser) {
            revert NotOrganiser();
        }
    }

    function CheckOnlyUnregisteredUser() internal view {
        if (Users[msg.sender].IsRegistered) {
            revert AlreadyRegistered();
        }
    }

    function GetOrganiserProfile()
        public
        view
        returns (address organiserWallet, bool isCallerOrganiser)
    {
        return (Organiser, msg.sender == Organiser);
    }

    function ValidateUsername(string memory _username) internal pure {
        uint256 usernameLength = bytes(_username).length;

        if (usernameLength == 0) {
            revert EmptyUsername();
        }

        if (usernameLength > 120) {
            revert UsernameTooLong();
        }
    }

    function addStaffWallet(address _StaffWallet) public onlyOrganiser {
        if (_StaffWallet == address(0)) {
            revert InvalidWallet();
        }

        if (_StaffWallet == Organiser) {
            revert OrganiserCannotBeStaff();
        }

        if (StaffWhiteList[_StaffWallet]) {
            revert StaffAlreadyWhitelisted();
        }

        StaffWhiteList[_StaffWallet] = true;
        StaffWhiteListArray.push(_StaffWallet);
    }

    function RemoveStaffWallet(address _StaffWallet) public onlyOrganiser {
        if (_StaffWallet == address(0)) {
            revert InvalidWallet();
        }

        if (!StaffWhiteList[_StaffWallet]) {
            revert StaffNotWhitelisted();
        }

        delete StaffWhiteList[_StaffWallet];

        if (
            Users[_StaffWallet].IsRegistered &&
            Users[_StaffWallet].usertype == UserType.Staff
        ) {
            Users[_StaffWallet].usertype = UserType.Customer;
        }

        for (uint256 i = 0; i < StaffWhiteListArray.length; i++) {
            if (StaffWhiteListArray[i] == _StaffWallet) {
                for (uint256 j = i; j < StaffWhiteListArray.length - 1; j++) {
                    StaffWhiteListArray[j] = StaffWhiteListArray[j + 1];
                }

                StaffWhiteListArray.pop();
                break;
            }
        }
    }

    function GETALLSTAFFWALLET() public view returns (address[] memory) {
        return StaffWhiteListArray;
    }

    function RegisterAsStudent(
        string memory _username,
        School _school
    ) public onlyUnregisteredUser {
        if (msg.sender == Organiser) {
            revert OrganiserCannotRegister();
        }

        if (StaffWhiteList[msg.sender]) {
            revert WhitelistedStaffMustRegisterAsStaff();
        }

        if (_school == School.Others) {
            revert StudentCannotSelectOthers();
        }

        ValidateUsername(_username);

        Users[msg.sender] = UserProfile({
            WalletAddress: msg.sender,
            Username: _username,
            usertype: UserType.Student,
            school: _school,
            IsRegistered: true,
            RegisteredAt: block.timestamp
        });
    }

    function RegisterAsCustomer(
        string memory _username
    ) public onlyUnregisteredUser {
        if (msg.sender == Organiser) {
            revert OrganiserCannotRegister();
        }

        if (StaffWhiteList[msg.sender]) {
            revert WhitelistedStaffMustRegisterAsStaff();
        }

        ValidateUsername(_username);

        Users[msg.sender] = UserProfile({
            WalletAddress: msg.sender,
            Username: _username,
            usertype: UserType.Customer,
            school: School.Others,
            IsRegistered: true,
            RegisteredAt: block.timestamp
        });
    }

    function RegisterAsStaff(
        string memory _username,
        School _school
    ) public onlyUnregisteredUser {
        if (msg.sender == Organiser) {
            revert OrganiserCannotRegister();
        }

        if (!StaffWhiteList[msg.sender]) {
            revert StaffNotWhitelisted();
        }

        ValidateUsername(_username);

        Users[msg.sender] = UserProfile({
            WalletAddress: msg.sender,
            Username: _username,
            usertype: UserType.Staff,
            school: _school,
            IsRegistered: true,
            RegisteredAt: block.timestamp
        });
    }

    function UpgradeMyProfileToStaff(School _school) public {
        if (msg.sender == Organiser) {
            revert OrganiserCannotRegister();
        }

        if (!Users[msg.sender].IsRegistered) {
            revert WalletNotRegistered();
        }

        if (!StaffWhiteList[msg.sender]) {
            revert StaffNotWhitelisted();
        }

        if (
            Users[msg.sender].usertype != UserType.Student &&
            Users[msg.sender].usertype != UserType.Customer
        ) {
            revert NotStudentOrCustomer();
        }

        Users[msg.sender].usertype = UserType.Staff;
        Users[msg.sender].school = _school;
    }

    function GetMyProfile() public view returns (UserProfile memory) {
        if (!Users[msg.sender].IsRegistered) {
            revert WalletNotRegistered();
        }

        return Users[msg.sender];
    }

    function AuthenticateMyWallet()
        public
        view
        returns (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        )
    {
        bool staffWhitelisted = StaffWhiteList[msg.sender];

        if (msg.sender == Organiser) {
            return (
                msg.sender,
                "",
                true,
                true,
                false,
                false,
                UserType.None,
                School.Others,
                0
            );
        }

        if (Users[msg.sender].IsRegistered) {
            UserProfile memory profile = Users[msg.sender];

            return (
                msg.sender,
                profile.Username,
                true,
                false,
                true,
                staffWhitelisted,
                profile.usertype,
                profile.school,
                profile.RegisteredAt
            );
        }

        return (
            msg.sender,
            "",
            false,
            false,
            false,
            staffWhitelisted,
            UserType.None,
            School.Others,
            0
        );
    }

    // =============================================================== //
    // HELPER FUNCTIONS FOR OTHER CARELINK CONTRACTS
    // =============================================================== //

    function IsWalletRegistered(address _wallet) public view returns (bool) {
        return Users[_wallet].IsRegistered;
    }

    function IsWalletStaffWhitelisted(
        address _wallet
    ) public view returns (bool) {
        return StaffWhiteList[_wallet];
    }

    function GetWalletUserType(address _wallet) public view returns (UserType) {
        return Users[_wallet].usertype;
    }

    function GetWalletSchool(address _wallet) public view returns (School) {
        return Users[_wallet].school;
    }

    function GetUserProfileByWallet(
        address _wallet
    ) public view returns (UserProfile memory) {
        if (!Users[_wallet].IsRegistered) {
            revert WalletNotRegistered();
        }

        return Users[_wallet];
    }

    function UpdateMyUsername(string memory _newUsername) public {
        if (!Users[msg.sender].IsRegistered) {
            revert WalletNotRegistered();
        }

        ValidateUsername(_newUsername);

        Users[msg.sender].Username = _newUsername;
    }
}
