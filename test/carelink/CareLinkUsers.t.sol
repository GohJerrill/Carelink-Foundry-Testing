// To test without the test files: forge coverage --exclude-tests
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CareLinkUsers} from "../../src/carelink/CareLinkUsers.sol";
import "../../src/carelink/CareLinkTypes.sol";

contract CareLinkUsersTest is Test {
    CareLinkUsers internal usersContract;

    address internal organiser;
    address internal student;
    address internal studentTwo;
    address internal staff;
    address internal staffTwo;
    address internal staffThree;
    address internal unregisteredUser;
    address internal customer;

    uint256 internal constant TEST_TIMESTAMP = 1_800_000_000;

    function setUp() public {
        vm.warp(TEST_TIMESTAMP);

        organiser = address(this);
        student = makeAddr("student");
        studentTwo = makeAddr("studentTwo");
        staff = makeAddr("staff");
        staffTwo = makeAddr("staffTwo");
        staffThree = makeAddr("staffThree");
        unregisteredUser = makeAddr("unregisteredUser");
        customer = makeAddr("customer");

        usersContract = new CareLinkUsers();
    }

    // ===============================================================
    // INTERNAL TEST HELPERS
    // ===============================================================

    function _registerStudent(
        address wallet,
        string memory username,
        School school
    ) internal {
        vm.prank(wallet);
        usersContract.RegisterAsStudent(username, school);
    }

    function _whitelistStaff(address wallet) internal {
        usersContract.addStaffWallet(wallet);
    }

    function _registerStaff(
        address wallet,
        string memory username,
        School school
    ) internal {
        _whitelistStaff(wallet);

        vm.prank(wallet);
        usersContract.RegisterAsStaff(username, school);
    }

    function _registerCustomer(
        address wallet,
        string memory username
    ) internal {
        vm.prank(wallet);
        usersContract.RegisterAsCustomer(username);
    }

    function _createString(
        uint256 length
    ) internal pure returns (string memory) {
        bytes memory characters = new bytes(length);

        for (uint256 i = 0; i < length; i++) {
            characters[i] = 0x61;
        }

        return string(characters);
    }

    function _assertUserProfile(
        UserProfile memory profile,
        address expectedWallet,
        string memory expectedUsername,
        UserType expectedUserType,
        School expectedSchool,
        uint256 expectedRegisteredAt
    ) internal pure {
        assertEq(profile.WalletAddress, expectedWallet);
        assertEq(profile.Username, expectedUsername);
        assertEq(uint256(profile.usertype), uint256(expectedUserType));
        assertEq(uint256(profile.school), uint256(expectedSchool));
        assertTrue(profile.IsRegistered);
        assertEq(profile.RegisteredAt, expectedRegisteredAt);
    }

    function _assertStudentProfile(
        UserProfile memory profile,
        address expectedWallet,
        string memory expectedUsername,
        School expectedSchool
    ) internal pure {
        _assertUserProfile(
            profile,
            expectedWallet,
            expectedUsername,
            UserType.Student,
            expectedSchool,
            TEST_TIMESTAMP
        );
    }

    function _assertStaffProfile(
        UserProfile memory profile,
        address expectedWallet,
        string memory expectedUsername,
        School expectedSchool
    ) internal pure {
        _assertUserProfile(
            profile,
            expectedWallet,
            expectedUsername,
            UserType.Staff,
            expectedSchool,
            TEST_TIMESTAMP
        );
    }

    function _assertCustomerProfile(
        UserProfile memory profile,
        address expectedWallet,
        string memory expectedUsername,
        School expectedSchool
    ) internal pure {
        _assertUserProfile(
            profile,
            expectedWallet,
            expectedUsername,
            UserType.Customer,
            expectedSchool,
            TEST_TIMESTAMP
        );
    }

    function _createCustomer(
        address wallet,
        string memory username,
        School school
    ) internal {
        _registerStaff(wallet, username, school);

        usersContract.RemoveStaffWallet(wallet);
    }

    // ===============================================================
    // CONSTRUCTOR AND ORGANISER PROFILE
    // ===============================================================

    function test_ConstructorSetsOrganiser() public view {
        assertEq(usersContract.Organiser(), organiser);
    }

    function test_GetOrganiserProfile_ReturnsOrganiserForOrganiser()
        public
        view
    {
        (address organiserWallet, bool isCallerOrganiser) = usersContract
            .GetOrganiserProfile();

        assertEq(organiserWallet, organiser);
        assertTrue(isCallerOrganiser);
    }

    function test_GetOrganiserProfile_ReturnsFalseForNonOrganiser() public {
        vm.prank(student);

        (address organiserWallet, bool isCallerOrganiser) = usersContract
            .GetOrganiserProfile();

        assertEq(organiserWallet, organiser);
        assertFalse(isCallerOrganiser);
    }

    // ===============================================================
    // ADD STAFF WALLET
    // ===============================================================

    function test_AddStaffWallet_OrganiserCanAddStaff() public {
        usersContract.addStaffWallet(staff);

        assertTrue(usersContract.StaffWhiteList(staff));

        address[] memory staffWallets = usersContract.GETALLSTAFFWALLET();

        assertEq(staffWallets.length, 1);
        assertEq(staffWallets[0], staff);
    }

    function test_AddStaffWallet_CanAddMultipleStaffWallets() public {
        usersContract.addStaffWallet(staff);
        usersContract.addStaffWallet(staffTwo);
        usersContract.addStaffWallet(staffThree);

        address[] memory staffWallets = usersContract.GETALLSTAFFWALLET();

        assertEq(staffWallets.length, 3);
        assertEq(staffWallets[0], staff);
        assertEq(staffWallets[1], staffTwo);
        assertEq(staffWallets[2], staffThree);

        assertTrue(usersContract.StaffWhiteList(staff));
        assertTrue(usersContract.StaffWhiteList(staffTwo));
        assertTrue(usersContract.StaffWhiteList(staffThree));
    }

    function test_AddStaffWallet_RevertsForNonOrganiser() public {
        vm.expectRevert(NotOrganiser.selector);

        vm.prank(customer);
        usersContract.addStaffWallet(staff);
    }

    function test_AddStaffWallet_RevertsForZeroAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        usersContract.addStaffWallet(address(0));
    }

    function test_AddStaffWallet_RevertsForOrganiserAddress() public {
        vm.expectRevert(OrganiserCannotBeStaff.selector);

        usersContract.addStaffWallet(organiser);
    }

    function test_AddStaffWallet_RevertsForDuplicateWallet() public {
        usersContract.addStaffWallet(staff);

        vm.expectRevert(StaffAlreadyWhitelisted.selector);

        usersContract.addStaffWallet(staff);
    }

    // ===============================================================
    // REMOVE STAFF WALLET
    // ===============================================================

    function test_RemoveStaffWallet_OrganiserCanRemoveStaff() public {
        usersContract.addStaffWallet(staff);

        usersContract.RemoveStaffWallet(staff);

        assertFalse(usersContract.StaffWhiteList(staff));

        address[] memory staffWallets = usersContract.GETALLSTAFFWALLET();

        assertEq(staffWallets.length, 0);
    }

    function test_RemoveStaffWallet_ShiftsArrayCorrectly() public {
        usersContract.addStaffWallet(staff);
        usersContract.addStaffWallet(staffTwo);
        usersContract.addStaffWallet(staffThree);

        usersContract.RemoveStaffWallet(staffTwo);

        address[] memory staffWallets = usersContract.GETALLSTAFFWALLET();

        assertEq(staffWallets.length, 2);
        assertEq(staffWallets[0], staff);
        assertEq(staffWallets[1], staffThree);

        assertTrue(usersContract.StaffWhiteList(staff));
        assertFalse(usersContract.StaffWhiteList(staffTwo));
        assertTrue(usersContract.StaffWhiteList(staffThree));
    }

    function test_RemoveStaffWallet_RevertsForNonOrganiser() public {
        usersContract.addStaffWallet(staff);

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(customer);
        usersContract.RemoveStaffWallet(staff);
    }

    function test_RemoveStaffWallet_RevertsForZeroAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        usersContract.RemoveStaffWallet(address(0));
    }

    function test_RemoveStaffWallet_RevertsWhenNotWhitelisted() public {
        vm.expectRevert(StaffNotWhitelisted.selector);

        usersContract.RemoveStaffWallet(staff);
    }

    function test_RemoveStaffWallet_ChangesRegisteredStaffToCustomer() public {
        _registerStaff(staff, "Staff Member", School.Others);

        usersContract.RemoveStaffWallet(staff);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            staff
        );

        assertFalse(usersContract.StaffWhiteList(staff));
        assertTrue(profile.IsRegistered);
        assertEq(profile.WalletAddress, staff);
        assertEq(profile.Username, "Staff Member");
        assertEq(uint256(profile.usertype), uint256(UserType.Customer));
        assertEq(uint256(profile.school), uint256(School.Others));
        assertEq(profile.RegisteredAt, TEST_TIMESTAMP);
    }

    function test_RemoveStaffWallet_DoesNotChangeRegisteredStudentRole()
        public
    {
        _registerStudent(student, "Student User", School.IIT);

        usersContract.addStaffWallet(student);
        usersContract.RemoveStaffWallet(student);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        assertFalse(usersContract.StaffWhiteList(student));
        assertEq(uint256(profile.usertype), uint256(UserType.Student));
        assertEq(uint256(profile.school), uint256(School.IIT));
    }

    function test_RemoveStaffWallet_RemovedWalletCanBeReAddedWithoutDuplicate()
        public
    {
        usersContract.addStaffWallet(staff);
        usersContract.addStaffWallet(staffTwo);

        usersContract.RemoveStaffWallet(staff);

        assertFalse(usersContract.StaffWhiteList(staff));

        address[] memory afterRemoval = usersContract.GETALLSTAFFWALLET();

        assertEq(afterRemoval.length, 1);
        assertEq(afterRemoval[0], staffTwo);

        usersContract.addStaffWallet(staff);

        address[] memory afterReAdding = usersContract.GETALLSTAFFWALLET();

        assertEq(afterReAdding.length, 2);
        assertEq(afterReAdding[0], staffTwo);
        assertEq(afterReAdding[1], staff);

        assertTrue(usersContract.StaffWhiteList(staff));
    }

    // ===============================================================
    // STUDENT REGISTRATION
    // ===============================================================

    function test_RegisterAsStudent_RegistersValidStudent() public {
        _registerStudent(student, "William Student", School.IIT);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        _assertStudentProfile(profile, student, "William Student", School.IIT);

        assertTrue(usersContract.IsWalletRegistered(student));
    }

    function test_RegisterAsStudent_AcceptsMaximumUsernameLength() public {
        string memory maximumUsername = _createString(120);

        _registerStudent(student, maximumUsername, School.Business);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        assertEq(bytes(profile.Username).length, 120);
        assertTrue(profile.IsRegistered);
    }

    function test_RegisterAsStudent_RevertsForOrganiser() public {
        vm.expectRevert(OrganiserCannotRegister.selector);

        usersContract.RegisterAsStudent("Organiser", School.IIT);
    }

    function test_RegisterAsStudent_RevertsForWhitelistedStaff() public {
        usersContract.addStaffWallet(staff);

        vm.expectRevert(WhitelistedStaffMustRegisterAsStaff.selector);

        vm.prank(staff);
        usersContract.RegisterAsStudent("Staff Student", School.IIT);
    }

    function test_RegisterAsStudent_RevertsForOthersSchool() public {
        vm.expectRevert(StudentCannotSelectOthers.selector);

        vm.prank(student);
        usersContract.RegisterAsStudent("Student User", School.Others);
    }

    function test_RegisterAsStudent_RevertsForEmptyUsername() public {
        vm.expectRevert(EmptyUsername.selector);

        vm.prank(student);
        usersContract.RegisterAsStudent("", School.IIT);
    }

    function test_RegisterAsStudent_RevertsForLongUsername() public {
        string memory longUsername = _createString(121);

        vm.expectRevert(UsernameTooLong.selector);

        vm.prank(student);
        usersContract.RegisterAsStudent(longUsername, School.IIT);
    }

    function test_RegisterAsStudent_RevertsWhenAlreadyRegistered() public {
        _registerStudent(student, "First Username", School.IIT);

        vm.expectRevert(AlreadyRegistered.selector);

        vm.prank(student);
        usersContract.RegisterAsStudent("Second Username", School.Business);
    }

    function test_RegisterAsStudent_StoresCurrentBlockTimestamp() public {
        uint256 registrationTimestamp = TEST_TIMESTAMP + 3 days;

        vm.warp(registrationTimestamp);

        _registerStudent(student, "Timed Student", School.IIT);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        _assertUserProfile(
            profile,
            student,
            "Timed Student",
            UserType.Student,
            School.IIT,
            registrationTimestamp
        );
    }

    // ===============================================================
    // CUSTOMER REGISTRATION
    // ===============================================================

    function test_RegisterAsCustomer_RegistersValidCustomer() public {
        _registerCustomer(customer, "CareLink Customer");

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            customer
        );

        _assertCustomerProfile(
            profile,
            customer,
            "CareLink Customer",
            School.Others
        );

        assertTrue(usersContract.IsWalletRegistered(customer));
        assertFalse(usersContract.StaffWhiteList(customer));
    }

    function test_RegisterAsCustomer_AcceptsMaximumUsernameLength() public {
        string memory maximumUsername = _createString(120);

        _registerCustomer(customer, maximumUsername);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            customer
        );

        assertEq(bytes(profile.Username).length, 120);

        _assertCustomerProfile(
            profile,
            customer,
            maximumUsername,
            School.Others
        );
    }

    function test_RegisterAsCustomer_RevertsForOrganiser() public {
        vm.expectRevert(OrganiserCannotRegister.selector);

        usersContract.RegisterAsCustomer("Organiser Customer");
    }

    function test_RegisterAsCustomer_RevertsForWhitelistedStaff() public {
        usersContract.addStaffWallet(customer);

        vm.expectRevert(WhitelistedStaffMustRegisterAsStaff.selector);

        vm.prank(customer);
        usersContract.RegisterAsCustomer("Whitelisted Customer");
    }

    function test_RegisterAsCustomer_RevertsForEmptyUsername() public {
        vm.expectRevert(EmptyUsername.selector);

        vm.prank(customer);
        usersContract.RegisterAsCustomer("");
    }

    function test_RegisterAsCustomer_RevertsForLongUsername() public {
        string memory longUsername = _createString(121);

        vm.expectRevert(UsernameTooLong.selector);

        vm.prank(customer);
        usersContract.RegisterAsCustomer(longUsername);
    }

    function test_RegisterAsCustomer_RevertsWhenAlreadyRegistered() public {
        _registerCustomer(customer, "First Customer");

        vm.expectRevert(AlreadyRegistered.selector);

        vm.prank(customer);
        usersContract.RegisterAsCustomer("Second Customer");
    }

    function test_RegisterAsCustomer_CannotLaterRegisterAsStudent() public {
        _registerCustomer(customer, "Customer User");

        vm.expectRevert(AlreadyRegistered.selector);

        vm.prank(customer);
        usersContract.RegisterAsStudent("Trying To Become Student", School.IIT);
    }

    // ===============================================================
    // STAFF REGISTRATION
    // ===============================================================

    function test_RegisterAsStaff_RegistersWhitelistedStaff() public {
        _registerStaff(staff, "CareLink Staff", School.Others);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            staff
        );

        assertEq(profile.WalletAddress, staff);
        assertEq(profile.Username, "CareLink Staff");
        assertEq(uint256(profile.usertype), uint256(UserType.Staff));
        assertEq(uint256(profile.school), uint256(School.Others));
        assertTrue(profile.IsRegistered);
        assertEq(profile.RegisteredAt, TEST_TIMESTAMP);
        assertTrue(usersContract.StaffWhiteList(staff));
    }

    function test_RegisterAsStaff_RevertsForOrganiser() public {
        vm.expectRevert(OrganiserCannotRegister.selector);

        usersContract.RegisterAsStaff("Organiser", School.Others);
    }

    function test_RegisterAsStaff_RevertsWhenNotWhitelisted() public {
        vm.expectRevert(StaffNotWhitelisted.selector);

        vm.prank(staff);
        usersContract.RegisterAsStaff("Unapproved Staff", School.Others);
    }

    function test_RegisterAsStaff_RevertsForEmptyUsername() public {
        usersContract.addStaffWallet(staff);

        vm.expectRevert(EmptyUsername.selector);

        vm.prank(staff);
        usersContract.RegisterAsStaff("", School.Others);
    }

    function test_RegisterAsStaff_RevertsForLongUsername() public {
        usersContract.addStaffWallet(staff);

        string memory longUsername = _createString(121);

        vm.expectRevert(UsernameTooLong.selector);

        vm.prank(staff);
        usersContract.RegisterAsStaff(longUsername, School.Others);
    }

    function test_RegisterAsStaff_RevertsWhenAlreadyRegistered() public {
        _registerStaff(staff, "First Staff Username", School.Others);

        vm.expectRevert(AlreadyRegistered.selector);

        vm.prank(staff);
        usersContract.RegisterAsStaff(
            "Second Staff Username",
            School.Engineering
        );
    }

    function test_RegisterAsStaff_AcceptsMaximumUsernameLength() public {
        string memory maximumUsername = _createString(120);

        _registerStaff(staff, maximumUsername, School.Engineering);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            staff
        );

        assertEq(bytes(profile.Username).length, 120);

        _assertStaffProfile(
            profile,
            staff,
            maximumUsername,
            School.Engineering
        );
    }

    // ===============================================================
    // UPGRADE PROFILE TO STAFF
    // ===============================================================

    function test_UpgradeMyProfileToStaff_UpgradesStudentAndPreservesProfile()
        public
    {
        _registerStudent(student, "Student User", School.IIT);

        usersContract.addStaffWallet(student);

        vm.prank(student);
        usersContract.UpgradeMyProfileToStaff(School.Others);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        _assertStaffProfile(profile, student, "Student User", School.Others);

        assertTrue(usersContract.StaffWhiteList(student));
    }

    function test_UpgradeMyProfileToStaff_UpgradesCustomerAndPreservesProfile()
        public
    {
        _registerCustomer(customer, "Customer User");

        UserProfile memory customerProfile = usersContract
            .GetUserProfileByWallet(customer);

        _assertCustomerProfile(
            customerProfile,
            customer,
            "Customer User",
            School.Others
        );

        usersContract.addStaffWallet(customer);

        vm.prank(customer);
        usersContract.UpgradeMyProfileToStaff(School.Business);

        UserProfile memory upgradedProfile = usersContract
            .GetUserProfileByWallet(customer);

        _assertStaffProfile(
            upgradedProfile,
            customer,
            "Customer User",
            School.Business
        );

        assertTrue(usersContract.StaffWhiteList(customer));
    }

    function test_UpgradeMyProfileToStaff_RevertsForOrganiser() public {
        vm.expectRevert(OrganiserCannotRegister.selector);

        usersContract.UpgradeMyProfileToStaff(School.Others);
    }

    function test_UpgradeMyProfileToStaff_RevertsWhenUnregistered() public {
        usersContract.addStaffWallet(staff);

        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(staff);
        usersContract.UpgradeMyProfileToStaff(School.Others);
    }

    function test_UpgradeMyProfileToStaff_RevertsWhenNotWhitelisted() public {
        _registerStudent(student, "Student User", School.IIT);

        vm.expectRevert(StaffNotWhitelisted.selector);

        vm.prank(student);
        usersContract.UpgradeMyProfileToStaff(School.Others);
    }

    function test_UpgradeMyProfileToStaff_RevertsWhenAlreadyStaff() public {
        _registerStaff(staff, "Staff User", School.Others);

        vm.expectRevert(NotStudentOrCustomer.selector);

        vm.prank(staff);
        usersContract.UpgradeMyProfileToStaff(School.Business);
    }

    function test_UserRoleLifecycle_StudentToStaffToCustomerToStaff() public {
        // STEP 1 — Student
        _registerStudent(student, "William User", School.IIT);

        UserProfile memory studentProfile = usersContract
            .GetUserProfileByWallet(student);

        _assertStudentProfile(
            studentProfile,
            student,
            "William User",
            School.IIT
        );

        // STEP 2 — Student becomes Staff
        usersContract.addStaffWallet(student);

        vm.startPrank(student);

        usersContract.UpgradeMyProfileToStaff(School.Engineering);

        UserProfile memory firstStaffProfile = usersContract.GetMyProfile();

        vm.stopPrank();

        _assertStaffProfile(
            firstStaffProfile,
            student,
            "William User",
            School.Engineering
        );

        // STEP 3 — Staff loses whitelist and becomes Customer
        usersContract.RemoveStaffWallet(student);

        UserProfile memory customerProfile = usersContract
            .GetUserProfileByWallet(student);

        _assertCustomerProfile(
            customerProfile,
            student,
            "William User",
            School.Engineering
        );

        assertFalse(usersContract.StaffWhiteList(student));

        // STEP 4 — Customer is approved as Staff again
        usersContract.addStaffWallet(student);

        vm.prank(student);
        usersContract.UpgradeMyProfileToStaff(School.Business);

        UserProfile memory finalStaffProfile = usersContract
            .GetUserProfileByWallet(student);

        _assertStaffProfile(
            finalStaffProfile,
            student,
            "William User",
            School.Business
        );

        assertTrue(usersContract.StaffWhiteList(student));
    }

    // ===============================================================
    // GET MY PROFILE
    // ===============================================================

    function test_GetMyProfile_ReturnsCallerProfile() public {
        _registerStudent(student, "Student Profile", School.Design);

        vm.prank(student);
        UserProfile memory profile = usersContract.GetMyProfile();

        _assertStudentProfile(
            profile,
            student,
            "Student Profile",
            School.Design
        );
    }

    function test_GetMyProfile_RevertsWhenUnregistered() public {
        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredUser);
        usersContract.GetMyProfile();
    }

    // ===============================================================
    // AUTHENTICATION
    // ===============================================================

    function test_AuthenticateMyWallet_ReturnsOrganiserData() public view {
        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, organiser);
        assertEq(username, "");
        assertTrue(isAuthenticated);
        assertTrue(isOrganiser);
        assertFalse(isRegisteredUser);
        assertFalse(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.None));
        assertEq(uint256(school), uint256(School.Others));
        assertEq(registeredAt, 0);
    }

    function test_AuthenticateMyWallet_ReturnsRegisteredStudentData() public {
        _registerStudent(student, "Authenticated Student", School.IIT);

        vm.prank(student);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, student);
        assertEq(username, "Authenticated Student");
        assertTrue(isAuthenticated);
        assertFalse(isOrganiser);
        assertTrue(isRegisteredUser);
        assertFalse(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.Student));
        assertEq(uint256(school), uint256(School.IIT));
        assertEq(registeredAt, TEST_TIMESTAMP);
    }

    function test_AuthenticateMyWallet_ReturnsRegisteredStaffData() public {
        _registerStaff(staff, "Authenticated Staff", School.Others);

        vm.prank(staff);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, staff);
        assertEq(username, "Authenticated Staff");
        assertTrue(isAuthenticated);
        assertFalse(isOrganiser);
        assertTrue(isRegisteredUser);
        assertTrue(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.Staff));
        assertEq(uint256(school), uint256(School.Others));
        assertEq(registeredAt, TEST_TIMESTAMP);
    }

    function test_AuthenticateMyWallet_ReturnsWhitelistedUnregisteredData()
        public
    {
        usersContract.addStaffWallet(staff);

        vm.prank(staff);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, staff);
        assertEq(username, "");
        assertFalse(isAuthenticated);
        assertFalse(isOrganiser);
        assertFalse(isRegisteredUser);
        assertTrue(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.None));
        assertEq(uint256(school), uint256(School.Others));
        assertEq(registeredAt, 0);
    }

    function test_AuthenticateMyWallet_ReturnsUnregisteredData() public {
        vm.prank(unregisteredUser);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, unregisteredUser);
        assertEq(username, "");
        assertFalse(isAuthenticated);
        assertFalse(isOrganiser);
        assertFalse(isRegisteredUser);
        assertFalse(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.None));
        assertEq(uint256(school), uint256(School.Others));
        assertEq(registeredAt, 0);
    }

    function test_AuthenticateMyWallet_ReturnsRegisteredCustomerData() public {
        _registerCustomer(customer, "Customer User");

        vm.prank(customer);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, customer);
        assertEq(username, "Customer User");
        assertTrue(isAuthenticated);
        assertFalse(isOrganiser);
        assertTrue(isRegisteredUser);
        assertFalse(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.Customer));
        assertEq(uint256(school), uint256(School.Others));
        assertEq(registeredAt, TEST_TIMESTAMP);
    }

    function test_AuthenticateMyWallet_WhitelistedStudentRemainsStudentUntilUpgrade()
        public
    {
        _registerStudent(student, "Future Staff", School.IIT);

        usersContract.addStaffWallet(student);

        vm.prank(student);

        (
            address walletAddress,
            string memory username,
            bool isAuthenticated,
            bool isOrganiser,
            bool isRegisteredUser,
            bool isStaffWhitelisted,
            UserType usertype,
            School school,
            uint256 registeredAt
        ) = usersContract.AuthenticateMyWallet();

        assertEq(walletAddress, student);
        assertEq(username, "Future Staff");
        assertTrue(isAuthenticated);
        assertFalse(isOrganiser);
        assertTrue(isRegisteredUser);

        // Important:
        assertTrue(isStaffWhitelisted);
        assertEq(uint256(usertype), uint256(UserType.Student));

        assertEq(uint256(school), uint256(School.IIT));
        assertEq(registeredAt, TEST_TIMESTAMP);
    }

    function test_GetMyProfile_ReturnsCustomerProfile() public {
        _registerCustomer(customer, "Customer Profile");

        vm.prank(customer);
        UserProfile memory profile = usersContract.GetMyProfile();

        _assertCustomerProfile(
            profile,
            customer,
            "Customer Profile",
            School.Others
        );
    }

    // ===============================================================
    // HELPER GETTERS
    // ===============================================================

    function test_HelperGetters_ReturnCorrectStudentInformation() public {
        _registerStudent(student, "Helper Student", School.Science);

        assertTrue(usersContract.IsWalletRegistered(student));
        assertFalse(usersContract.IsWalletStaffWhitelisted(student));

        assertEq(
            uint256(usersContract.GetWalletUserType(student)),
            uint256(UserType.Student)
        );

        assertEq(
            uint256(usersContract.GetWalletSchool(student)),
            uint256(School.Science)
        );
    }

    function test_HelperGetters_ReturnCorrectStaffInformation() public {
        _registerStaff(staff, "Helper Staff", School.Others);

        assertTrue(usersContract.IsWalletRegistered(staff));
        assertTrue(usersContract.IsWalletStaffWhitelisted(staff));

        assertEq(
            uint256(usersContract.GetWalletUserType(staff)),
            uint256(UserType.Staff)
        );

        assertEq(
            uint256(usersContract.GetWalletSchool(staff)),
            uint256(School.Others)
        );
    }

    function test_HelperGetters_ReturnFalseForUnregisteredWallet() public view {
        assertFalse(usersContract.IsWalletRegistered(unregisteredUser));

        assertFalse(usersContract.IsWalletStaffWhitelisted(unregisteredUser));

        assertEq(
            uint256(usersContract.GetWalletUserType(unregisteredUser)),
            uint256(UserType.None)
        );
    }

    function test_GetUserProfileByWallet_ReturnsProfile() public {
        _registerStudent(student, "Profile Lookup", School.Humanities);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        _assertStudentProfile(
            profile,
            student,
            "Profile Lookup",
            School.Humanities
        );
    }

    function test_GetUserProfileByWallet_RevertsWhenUnregistered() public {
        vm.expectRevert(WalletNotRegistered.selector);

        usersContract.GetUserProfileByWallet(unregisteredUser);
    }

    function test_HelperGetters_ReturnCorrectCustomerInformation() public {
        _registerCustomer(customer, "Customer User");

        assertTrue(usersContract.IsWalletRegistered(customer));

        assertFalse(usersContract.IsWalletStaffWhitelisted(customer));

        assertEq(
            uint256(usersContract.GetWalletUserType(customer)),
            uint256(UserType.Customer)
        );

        assertEq(
            uint256(usersContract.GetWalletSchool(customer)),
            uint256(School.Others)
        );
    }

    // ===============================================================
    // UPDATE USERNAME
    // ===============================================================

    function test_UpdateMyUsername_UpdatesRegisteredUser() public {
        _registerStudent(student, "Old Username", School.IIT);

        vm.prank(student);
        usersContract.UpdateMyUsername("New Username");

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        assertEq(profile.Username, "New Username");
        assertEq(profile.WalletAddress, student);
        assertEq(uint256(profile.usertype), uint256(UserType.Student));
        assertEq(uint256(profile.school), uint256(School.IIT));
        assertTrue(profile.IsRegistered);
    }

    function test_UpdateMyUsername_AcceptsMaximumLength() public {
        _registerStudent(student, "Original Username", School.IIT);

        string memory maximumUsername = _createString(120);

        vm.prank(student);
        usersContract.UpdateMyUsername(maximumUsername);

        UserProfile memory profile = usersContract.GetUserProfileByWallet(
            student
        );

        assertEq(bytes(profile.Username).length, 120);
    }

    function test_UpdateMyUsername_RevertsWhenUnregistered() public {
        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredUser);
        usersContract.UpdateMyUsername("New Username");
    }

    function test_UpdateMyUsername_RevertsForEmptyUsername() public {
        _registerStudent(student, "Original Username", School.IIT);

        vm.expectRevert(EmptyUsername.selector);

        vm.prank(student);
        usersContract.UpdateMyUsername("");
    }

    function test_UpdateMyUsername_RevertsForLongUsername() public {
        _registerStudent(student, "Original Username", School.IIT);

        string memory longUsername = _createString(121);

        vm.expectRevert(UsernameTooLong.selector);

        vm.prank(student);
        usersContract.UpdateMyUsername(longUsername);
    }
}
