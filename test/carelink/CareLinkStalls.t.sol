// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CareLinkUsers} from "../../src/carelink/CareLinkUsers.sol";
import {CareLinkCCNDay} from "../../src/carelink/CareLinkCCNDay.sol";
import {CareLinkStalls} from "../../src/carelink/CareLinkStalls.sol";

import "../../src/carelink/CareLinkTypes.sol";

/*
 * CareLinkStalls asks CareLinkPayments whether a stall has
 * unsettled paid payments.
 *
 * This mock lets us choose whether the answer should be true or false.
 * It can also act as the authorised payment contract when testing
 * MarkStallWithdrawalCompleted().
 */
contract MockCareLinkPaymentsForStalls {
    mapping(uint256 => bool) internal unsettledPayments;

    function SetHasUnsettledPaidPayments(
        uint256 _stallId,
        bool _hasUnsettledPayments
    ) external {
        unsettledPayments[_stallId] = _hasUnsettledPayments;
    }

    function HasUnsettledPaidPayments(
        uint256 _stallId
    ) external view returns (bool) {
        return unsettledPayments[_stallId];
    }

    function MarkWithdrawalCompleted(
        CareLinkStalls _stallContract,
        uint256 _stallId
    ) external {
        _stallContract.MarkStallWithdrawalCompleted(_stallId);
    }
}

contract CareLinkStallsTest is Test {
    CareLinkUsers internal usersContract;
    CareLinkCCNDay internal ccnDayContract;
    CareLinkStalls internal stallsContract;

    MockCareLinkPaymentsForStalls internal mockPaymentContract;

    address internal organiser;
    address internal student;
    address internal studentTwo;
    address internal ineligibleStudent;
    address internal staff;
    address internal customer;
    address internal unregisteredWallet;
    address internal outsider;

    uint256 internal constant BASE_TIME = 2_000_000_000;

    uint256 internal constant REGISTRATION_START = BASE_TIME + 1 days;

    uint256 internal constant REGISTRATION_END = BASE_TIME + 2 days;

    uint256 internal constant CCN_START = BASE_TIME + 3 days;

    uint256 internal constant CCN_END = BASE_TIME + 4 days;

    uint256 internal constant SECOND_REGISTRATION_START = CCN_END + 1 days;

    uint256 internal constant SECOND_REGISTRATION_END = CCN_END + 2 days;

    uint256 internal constant SECOND_CCN_START = CCN_END + 3 days;

    uint256 internal constant SECOND_CCN_END = CCN_END + 4 days;

    function setUp() public {
        vm.warp(BASE_TIME);

        /*
         * The test contract deploys CareLinkUsers.
         * Therefore address(this) becomes its organiser.
         */
        organiser = address(this);

        student = makeAddr("student");
        studentTwo = makeAddr("studentTwo");
        ineligibleStudent = makeAddr("ineligibleStudent");
        staff = makeAddr("staff");
        customer = makeAddr("customer");
        unregisteredWallet = makeAddr("unregisteredWallet");
        outsider = makeAddr("outsider");

        usersContract = new CareLinkUsers();

        ccnDayContract = new CareLinkCCNDay(organiser);

        stallsContract = new CareLinkStalls(
            organiser,
            address(usersContract),
            address(ccnDayContract)
        );

        mockPaymentContract = new MockCareLinkPaymentsForStalls();

        stallsContract.SetPaymentContractAddress(address(mockPaymentContract));

        /*
         * This connection lets CareLinkCCNDay call
         * DeleteStallsByCCNDay() when a CCN Day is deleted.
         */
        ccnDayContract.SetStallContractAddress(address(stallsContract));

        _createDefaultCCNDay();

        _registerStudent(student, "Student One", School.IIT);

        _registerStudent(studentTwo, "Student Two", School.Business);

        /*
         * Design is intentionally excluded from the default
         * CCN Day eligible-school list.
         */
        _registerStudent(
            ineligibleStudent,
            "Ineligible Student",
            School.Design
        );

        _registerStaff(staff, "Staff User", School.Others);

        _createCustomer(customer, "Customer User", School.Others);
    }

    // ===============================================================
    // GENERAL HELPERS
    // ===============================================================

    function _defaultSchools() internal pure returns (School[] memory schools) {
        schools = new School[](3);

        schools[0] = School.IIT;
        schools[1] = School.Business;
        schools[2] = School.Engineering;
    }

    function _createDefaultCCNDay() internal {
        School[] memory schools = _defaultSchools();

        ccnDayContract.CreateNewCCNDay(
            "CareLink CCN Day",
            "Temasek Polytechnic CCN Day",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function _createSecondCCNDay() internal {
        vm.warp(CCN_END + 1);

        School[] memory schools = _defaultSchools();

        ccnDayContract.CreateNewCCNDay(
            "Second CareLink CCN Day",
            "The second CareLink event",
            SECOND_CCN_START,
            SECOND_CCN_END,
            SECOND_REGISTRATION_START,
            SECOND_REGISTRATION_END,
            schools
        );
    }

    function _registerStudent(
        address _wallet,
        string memory _username,
        School _school
    ) internal {
        vm.prank(_wallet);

        usersContract.RegisterAsStudent(_username, _school);
    }

    function _registerStaff(
        address _wallet,
        string memory _username,
        School _school
    ) internal {
        usersContract.addStaffWallet(_wallet);

        vm.prank(_wallet);

        usersContract.RegisterAsStaff(_username, _school);
    }

    function _createCustomer(
        address _wallet,
        string memory _username,
        School _school
    ) internal {
        _registerStaff(_wallet, _username, _school);

        usersContract.RemoveStaffWallet(_wallet);
    }

    function _createString(
        uint256 _length
    ) internal pure returns (string memory) {
        bytes memory characters = new bytes(_length);

        for (uint256 i = 0; i < _length; i++) {
            characters[i] = 0x61;
        }

        return string(characters);
    }

    function _assertStall(
        Stall memory stall,
        uint256 expectedStallID,
        string memory expectedName,
        string memory expectedDescription,
        string memory expectedImage,
        StallType expectedType,
        address expectedOwner,
        string memory expectedLocation,
        School expectedSchool,
        bool expectedNeedElectricalPort,
        uint256 expectedCreatedAt,
        StallStatus expectedStatus,
        bool expectedAllowedWithdrawal,
        uint256 expectedCCNDayID,
        bool expectedWithdrawalCompleted
    ) internal pure {
        assertEq(stall.StallID, expectedStallID);

        assertEq(stall.StallName, expectedName);

        assertEq(stall.StallDescription, expectedDescription);

        assertEq(stall.StallImage, expectedImage);

        assertEq(uint256(stall.stallType), uint256(expectedType));

        assertEq(stall.StallOwnerWallet, expectedOwner);

        assertEq(stall.StallLocation, expectedLocation);

        assertEq(uint256(stall.StallSchool), uint256(expectedSchool));

        assertEq(stall.NeedElectricalPort, expectedNeedElectricalPort);

        assertEq(stall.CreatedAt, expectedCreatedAt);

        assertEq(uint256(stall.stallStatus), uint256(expectedStatus));

        assertEq(stall.AllowedWithdrawal, expectedAllowedWithdrawal);

        assertEq(stall.CCNDayID, expectedCCNDayID);

        assertEq(stall.WithdrawalCompleted, expectedWithdrawalCompleted);
    }

    function _assertProduct(
        uint256 _productId,
        uint256 expectedStallID,
        string memory expectedName,
        string memory expectedDescription,
        string memory expectedImage,
        uint256 expectedPriceSGDCents,
        ProductStatus expectedStatus
    ) internal view {
        (
            uint256 storedProductID,
            uint256 storedStallID,
            string memory storedName,
            string memory storedDescription,
            string memory storedImage,
            uint256 storedPriceSGDCents,
            ProductStatus storedStatus
        ) = stallsContract.Products(_productId);

        assertEq(storedProductID, _productId);

        assertEq(storedStallID, expectedStallID);

        assertEq(storedName, expectedName);

        assertEq(storedDescription, expectedDescription);

        assertEq(storedImage, expectedImage);

        assertEq(storedPriceSGDCents, expectedPriceSGDCents);

        assertEq(uint256(storedStatus), uint256(expectedStatus));
    }

    function _assertDefaultPendingStall(
        Stall memory stall,
        uint256 expectedStallID,
        address expectedOwner
    ) internal pure {
        _assertStall(
            stall,
            expectedStallID,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            expectedOwner,
            "",
            School.Others,
            true,
            REGISTRATION_START,
            StallStatus.Pending,
            false,
            1,
            false
        );
    }

    function _assertDefaultApprovedStall(
        Stall memory stall,
        uint256 expectedStallID,
        address expectedOwner
    ) internal pure {
        _assertStall(
            stall,
            expectedStallID,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            expectedOwner,
            "Block 30 Level 2",
            School.IIT,
            true,
            REGISTRATION_START,
            StallStatus.Open,
            false,
            1,
            false
        );
    }

    function _createPendingStall(address _owner) internal returns (uint256) {
        vm.warp(REGISTRATION_START);

        vm.prank(_owner);

        return
            stallsContract.CreateStall(
                "CareLink Stall",
                "A stall created for unit testing",
                "stall-image",
                StallType.FoodAndBeverage,
                true
            );
    }

    function _createPendingStallWithDetails(
        address _owner,
        string memory _name,
        string memory _description,
        string memory _image,
        StallType _stallType,
        bool _needsElectricity
    ) internal returns (uint256) {
        vm.warp(REGISTRATION_START);

        vm.prank(_owner);

        return
            stallsContract.CreateStall(
                _name,
                _description,
                _image,
                _stallType,
                _needsElectricity
            );
    }

    function _approveStall(uint256 _stallId) internal {
        stallsContract.ApproveStall(_stallId, "Block 30 Level 2", School.IIT);
    }

    function _createApprovedStall(address _owner) internal returns (uint256) {
        uint256 stallId = _createPendingStall(_owner);

        _approveStall(stallId);

        return stallId;
    }

    function _createProduct(
        uint256 _stallId,
        address _stallOwner
    ) internal returns (uint256) {
        vm.prank(_stallOwner);

        return
            stallsContract.CreateProduct(
                _stallId,
                "Chicken Rice bruh",
                "Freshly prepared chicken rice",
                "chicken-rice-image",
                500,
                ProductStatus.Available
            );
    }

    // ===============================================================
    // CONSTRUCTOR
    // ===============================================================

    function test_ConstructorStoresContractAddresses() public view {
        assertEq(stallsContract.Organiser(), organiser);

        assertEq(
            address(stallsContract.userContract()),
            address(usersContract)
        );

        assertEq(
            address(stallsContract.ccnDayContract()),
            address(ccnDayContract)
        );

        assertEq(
            stallsContract.CCNDayContractAddress(),
            address(ccnDayContract)
        );
    }

    function test_ConstructorRevertsForZeroOrganiser() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkStalls(
            address(0),
            address(usersContract),
            address(ccnDayContract)
        );
    }

    function test_ConstructorRevertsForZeroUserContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkStalls(organiser, address(0), address(ccnDayContract));
    }

    function test_ConstructorRevertsForZeroCCNDayContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkStalls(organiser, address(usersContract), address(0));
    }

    // ===============================================================
    // PAYMENT CONTRACT CONFIGURATION
    // ===============================================================

    function test_OrganiserCanSetPaymentContractAddress() public {
        MockCareLinkPaymentsForStalls replacementMock = new MockCareLinkPaymentsForStalls();

        stallsContract.SetPaymentContractAddress(address(replacementMock));

        assertEq(
            address(stallsContract.paymentContract()),
            address(replacementMock)
        );
    }

    function test_SetPaymentContractRevertsForNonOrganiser() public {
        vm.expectRevert(NotOrganiser.selector);

        vm.prank(outsider);

        stallsContract.SetPaymentContractAddress(makeAddr("paymentContract"));
    }

    function test_SetPaymentContractRevertsForZeroAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        stallsContract.SetPaymentContractAddress(address(0));
    }

    // ===============================================================
    // INITIAL STATE AND EXISTENCE GETTERS
    // ===============================================================

    function test_InitialStallStateIsEmpty() public view {
        assertFalse(stallsContract.DoesStallExist(0));
        assertFalse(stallsContract.DoesStallExist(999));

        assertFalse(stallsContract.HasCreatedStall(student));

        assertEq(stallsContract.WalletStallID(student), 0);

        assertFalse(stallsContract.IsStallOwner(student));
    }

    function test_GetCCNDayStallCountInitiallyReturnsZero() public view {
        assertEq(stallsContract.GetCCNDayStallCount(1), 0);
    }

    function test_GetCCNDayStallCountRevertsForZeroID() public {
        vm.expectRevert(InvalidCCNDayID.selector);

        stallsContract.GetCCNDayStallCount(0);
    }

    // ===============================================================
    // CAN WALLET CREATE STALL
    // ===============================================================

    function test_CanWalletCreateStallReturnsTrueForEligibleStudent() public {
        vm.warp(REGISTRATION_START);

        assertTrue(stallsContract.CanWalletCreateStall(student));
    }

    function test_CanWalletCreateStallReturnsTrueForStaff() public {
        vm.warp(REGISTRATION_START);

        assertTrue(stallsContract.CanWalletCreateStall(staff));
    }

    function test_CanWalletCreateStallReturnsFalseForOrganiser() public {
        vm.warp(REGISTRATION_START);

        assertFalse(stallsContract.CanWalletCreateStall(organiser));
    }

    function test_CanWalletCreateStallReturnsFalseBeforeRegistration()
        public
        view
    {
        assertFalse(stallsContract.CanWalletCreateStall(student));
    }

    function test_CanWalletCreateStallReturnsFalseForUnregisteredWallet()
        public
    {
        vm.warp(REGISTRATION_START);

        assertFalse(stallsContract.CanWalletCreateStall(unregisteredWallet));
    }

    function test_CanWalletCreateStallReturnsFalseForCustomer() public {
        vm.warp(REGISTRATION_START);

        assertFalse(stallsContract.CanWalletCreateStall(customer));
    }

    function test_CanWalletCreateStallReturnsFalseForIneligibleStudent()
        public
    {
        vm.warp(REGISTRATION_START);

        assertFalse(stallsContract.CanWalletCreateStall(ineligibleStudent));
    }

    function test_CanWalletCreateStallReturnsFalseAfterCreatingStall() public {
        _createPendingStall(student);

        assertFalse(stallsContract.CanWalletCreateStall(student));
    }

    function test_CanWalletCreateStallReturnsFalseForOldUnresolvedStall()
        public
    {
        _createApprovedStall(student);

        _createSecondCCNDay();

        vm.warp(SECOND_REGISTRATION_START);

        assertFalse(stallsContract.CanWalletCreateStall(student));
    }

    // ===============================================================
    // CREATE STALL SUCCESS
    // ===============================================================

    function test_CreateStallStoresAllInformation() public {
        uint256 stallId = _createPendingStallWithDetails(
            student,
            "William's Food Stall",
            "Selling food during CCN Day",
            "ipfs://stall-image",
            StallType.FoodAndBeverage,
            true
        );

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        _assertStall(
            stall,
            1,
            "William's Food Stall",
            "Selling food during CCN Day",
            "ipfs://stall-image",
            StallType.FoodAndBeverage,
            student,
            "",
            School.Others,
            true,
            REGISTRATION_START,
            StallStatus.Pending,
            false,
            1,
            false
        );

        assertTrue(stallsContract.DoesStallExist(stallId));

        assertTrue(stallsContract.HasCreatedStall(student));

        assertEq(stallsContract.WalletStallID(student), stallId);

        assertEq(stallsContract.OwnerStallIDByCCNDay(student, 1), stallId);

        assertEq(stallsContract.GetWalletStallID(student), stallId);

        uint256[] memory ownerStallIds = stallsContract.GetOwnerStallIDs(
            student
        );

        assertEq(ownerStallIds.length, 1);
        assertEq(ownerStallIds[0], stallId);

        assertEq(stallsContract.CCNDayStallIDs(1, 0), stallId);

        assertEq(stallsContract.GetCCNDayStallCount(1), 1);
    }

    function test_StaffCanCreateStallRegardlessOfSchool() public {
        uint256 stallId = _createPendingStall(staff);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        _assertDefaultPendingStall(stall, stallId, staff);

        assertTrue(stallsContract.HasCreatedStall(staff));

        assertEq(stallsContract.GetWalletStallID(staff), stallId);
    }

    function test_CreateMultipleStallsAssignsSequentialIDs() public {
        uint256 firstStallId = _createPendingStall(student);

        uint256 secondStallId = _createPendingStall(studentTwo);

        assertEq(firstStallId, 1);
        assertEq(secondStallId, 2);

        assertEq(stallsContract.GetCCNDayStallCount(1), 2);
    }

    function test_CreateStallAcceptsMaximumNameAndDescriptionLengths() public {
        string memory maximumName = _createString(80);

        string memory maximumDescription = _createString(500);

        uint256 stallId = _createPendingStallWithDetails(
            student,
            maximumName,
            maximumDescription,
            "ipfs://boundary-image",
            StallType.Services,
            false
        );

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertEq(bytes(stall.StallName).length, 80);

        assertEq(bytes(stall.StallDescription).length, 500);

        _assertStall(
            stall,
            stallId,
            maximumName,
            maximumDescription,
            "ipfs://boundary-image",
            StallType.Services,
            student,
            "",
            School.Others,
            false,
            REGISTRATION_START,
            StallStatus.Pending,
            false,
            1,
            false
        );
    }

    function test_CreateStallSucceedsAtExactRegistrationEnd() public {
        vm.warp(REGISTRATION_END);

        vm.prank(student);

        uint256 stallId = stallsContract.CreateStall(
            "Boundary Stall",
            "Created exactly when registration closes",
            "ipfs://boundary",
            StallType.Services,
            false
        );

        assertTrue(stallsContract.DoesStallExist(stallId));

        assertEq(
            stallsContract.GetStallDetails(stallId).CreatedAt,
            REGISTRATION_END
        );
    }

    // ===============================================================
    // CREATE STALL REVERTS
    // ===============================================================

    function test_CreateStallRevertsForOrganiser() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(OrganiserCannotCreateStall.selector);

        stallsContract.CreateStall(
            "Organiser Stall",
            "Organiser should not create a stall",
            "ipfs://organiser",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsForUnregisteredWallet() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredWallet);

        stallsContract.CreateStall(
            "Unregistered Stall",
            "Should fail",
            "ipfs://unregistered",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForCustomerRole() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(NotStudentOrStaff.selector);

        vm.prank(customer);

        stallsContract.CreateStall(
            "Customer Stall",
            "Customers cannot apply",
            "ipfs://customer",
            StallType.Gifts,
            false
        );
    }

    function test_CreateStallRevertsWhenAlreadyCreatedForCurrentDay() public {
        _createPendingStall(student);

        vm.expectRevert(WalletAlreadyCreatedStall.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Second Stall",
            "Duplicate current stall",
            "ipfs://second",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForOldUnresolvedStall() public {
        _createApprovedStall(student);

        _createSecondCCNDay();

        vm.warp(SECOND_REGISTRATION_START);

        vm.expectRevert(WalletHasUnresolvedStall.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Second Event Stall",
            "Old stall remains unresolved",
            "ipfs://second-event",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsWhenNoCurrentCCNDay() public {
        CareLinkCCNDay emptyCCNDayContract = new CareLinkCCNDay(organiser);

        CareLinkStalls emptyStallsContract = new CareLinkStalls(
            organiser,
            address(usersContract),
            address(emptyCCNDayContract)
        );

        vm.expectRevert(NoCurrentCCNDay.selector);

        vm.prank(student);

        emptyStallsContract.CreateStall(
            "No CCN Stall",
            "No current CCN Day",
            "ipfs://none",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsWhenCCNDayInactive() public {
        vm.warp(CCN_END + 1);

        vm.expectRevert(CurrentCCNDayNotActive.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Late Stall",
            "CCN Day has ended",
            "ipfs://late",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsBeforeRegistrationOpens() public {
        vm.expectRevert(StallRegistrationNotOpen.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Early Stall",
            "Registration has not opened",
            "ipfs://early",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsAfterRegistrationCloses() public {
        vm.warp(REGISTRATION_END + 1);

        vm.expectRevert(StallRegistrationNotOpen.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Late Registration Stall",
            "Registration has closed",
            "ipfs://closed",
            StallType.Services,
            false
        );
    }

    function test_CreateStallRevertsForIneligibleSchool() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(SchoolNotEligible.selector);

        vm.prank(ineligibleStudent);

        stallsContract.CreateStall(
            "Design Stall",
            "Design is not eligible",
            "ipfs://design",
            StallType.Performance,
            false
        );
    }

    function test_CreateStallRevertsForEmptyName() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(EmptyStallName.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "",
            "Valid description",
            "ipfs://image",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForEmptyDescription() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(EmptyStallDescription.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Valid name",
            "",
            "ipfs://image",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForEmptyImage() public {
        vm.warp(REGISTRATION_START);

        vm.expectRevert(EmptyStallImage.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Valid name",
            "Valid description",
            "",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForLongName() public {
        string memory longName = _createString(81);

        vm.warp(REGISTRATION_START);

        vm.expectRevert(StallNameTooLong.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            longName,
            "Valid description",
            "ipfs://image",
            StallType.Games,
            false
        );
    }

    function test_CreateStallRevertsForLongDescription() public {
        string memory longDescription = _createString(501);

        vm.warp(REGISTRATION_START);

        vm.expectRevert(StallDescriptionTooLong.selector);

        vm.prank(student);

        stallsContract.CreateStall(
            "Valid name",
            longDescription,
            "ipfs://image",
            StallType.Games,
            false
        );
    }

    // ===============================================================
    // APPROVE STALL
    // ===============================================================

    function test_OrganiserCanApprovePendingStall() public {
        uint256 stallId = _createPendingStall(student);

        stallsContract.ApproveStall(stallId, "Block 30 Level 2", School.IIT);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        _assertDefaultApprovedStall(stall, stallId, student);

        assertTrue(stallsContract.IsStallOwner(student));

        assertTrue(stallsContract.IsWalletApprovedStallOwner(student));

        assertTrue(stallsContract.IsStallOpen(stallId));
    }

    function test_ApproveStallAcceptsMaximumLocationLength() public {
        uint256 stallId = _createPendingStall(student);

        string memory maximumLocation = _createString(120);

        stallsContract.ApproveStall(
            stallId,
            maximumLocation,
            School.Engineering
        );

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertEq(bytes(stall.StallLocation).length, 120);

        assertEq(uint256(stall.StallSchool), uint256(School.Engineering));

        assertEq(uint256(stall.stallStatus), uint256(StallStatus.Open));
    }

    function test_ApproveStallRevertsForNonOrganiser() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(outsider);

        stallsContract.ApproveStall(stallId, "Location", School.IIT);
    }

    function test_ApproveStallRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.ApproveStall(999, "Location", School.IIT);
    }

    function test_ApproveStallRevertsWhenNotPending() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyPendingStallCanBeApproved.selector);

        stallsContract.ApproveStall(stallId, "Different location", School.IIT);
    }

    function test_ApproveStallRevertsForEmptyLocation() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(EmptyStallLocation.selector);

        stallsContract.ApproveStall(stallId, "", School.IIT);
    }

    function test_ApproveStallRevertsForLongLocation() public {
        uint256 stallId = _createPendingStall(student);

        string memory longLocation = _createString(121);

        vm.expectRevert(StallLocationTooLong.selector);

        stallsContract.ApproveStall(stallId, longLocation, School.IIT);
    }

    function test_ApproveStallRevertsForOthersSchool() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(EligibleSchoolCannotBeOthers.selector);

        stallsContract.ApproveStall(stallId, "Location", School.Others);
    }

    function test_ApproveStallRevertsForOldCCNDayStall() public {
        uint256 stallId = _createPendingStall(student);

        _createSecondCCNDay();

        vm.expectRevert(StallNotFromCurrentCCNDay.selector);

        stallsContract.ApproveStall(stallId, "Location", School.IIT);
    }

    function test_ApproveStallRevertsWhenCurrentCCNDayInactive() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(CurrentCCNDayNotActive.selector);

        stallsContract.ApproveStall(stallId, "Location", School.IIT);
    }

    function test_ApproveStallRevertsAfterCCNDayStarts() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        vm.expectRevert(CCNDayAlreadyStarted.selector);

        stallsContract.ApproveStall(stallId, "Location", School.IIT);
    }

    // ===============================================================
    // REJECT STALL
    // ===============================================================

    function test_OrganiserCanRejectPendingStall() public {
        uint256 stallId = _createPendingStall(student);

        stallsContract.RejectStall(stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertEq(uint256(stall.stallStatus), uint256(StallStatus.Rejected));

        assertEq(stallsContract.WalletStallID(student), 0);

        assertFalse(stallsContract.HasCreatedStall(student));

        assertEq(stallsContract.OwnerStallIDByCCNDay(student, 1), 0);

        assertFalse(stallsContract.IsStallOwner(student));
    }

    function test_RejectStallRevertsForNonOrganiser() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(outsider);

        stallsContract.RejectStall(stallId);
    }

    function test_RejectStallRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.RejectStall(999);
    }

    function test_RejectStallRevertsWhenNotPending() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyPendingStallCanBeRejected.selector);

        stallsContract.RejectStall(stallId);
    }

    function test_RejectStallRevertsForOldCCNDayStall() public {
        uint256 stallId = _createPendingStall(student);

        _createSecondCCNDay();

        vm.expectRevert(StallNotFromCurrentCCNDay.selector);

        stallsContract.RejectStall(stallId);
    }

    function test_RejectStallRevertsAfterCCNDayStarts() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        vm.expectRevert(CCNDayAlreadyStarted.selector);

        stallsContract.RejectStall(stallId);
    }

    function test_RejectedStudentCanCreateReplacementStall() public {
        uint256 rejectedStallId = _createPendingStall(student);

        stallsContract.RejectStall(rejectedStallId);

        assertFalse(stallsContract.IsStallActiveOrUnresolved(rejectedStallId));

        assertTrue(stallsContract.CanWalletCreateStall(student));

        vm.prank(student);

        uint256 replacementStallId = stallsContract.CreateStall(
            "Replacement Stall",
            "Second application after rejection",
            "replacement-stall-image",
            StallType.Services,
            false
        );

        assertEq(replacementStallId, 2);

        assertTrue(stallsContract.DoesStallExist(replacementStallId));

        assertEq(
            stallsContract.OwnerStallIDByCCNDay(student, 1),
            replacementStallId
        );
    }

    // ===============================================================
    // EXPIRED PENDING STALLS
    // ===============================================================

    function test_PendingStallShowsEffectiveExpiredStatusAtStart() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertEq(uint256(stall.stallStatus), uint256(StallStatus.Expired));

        assertFalse(stallsContract.IsStallActiveOrUnresolved(stallId));
    }

    function test_OwnerCanCompleteExpiredPendingStall() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        vm.prank(student);

        stallsContract.CompleteMyExpiredPendingStall(stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertEq(uint256(stall.stallStatus), uint256(StallStatus.Expired));

        assertEq(stallsContract.WalletStallID(student), 0);

        assertFalse(stallsContract.HasCreatedStall(student));

        assertEq(stallsContract.OwnerStallIDByCCNDay(student, 1), 0);
    }

    function test_CompleteExpiredStallRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(student);

        stallsContract.CompleteMyExpiredPendingStall(999);
    }

    function test_CompleteExpiredStallRevertsForWrongOwner() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.CompleteMyExpiredPendingStall(stallId);
    }

    function test_CompleteExpiredStallRevertsWhenNotPending() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyPendingStallCanBeExpired.selector);

        vm.prank(student);

        stallsContract.CompleteMyExpiredPendingStall(stallId);
    }

    function test_CompleteExpiredStallRevertsBeforeStart() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(PendingStallDecisionWindowStillOpen.selector);

        vm.prank(student);

        stallsContract.CompleteMyExpiredPendingStall(stallId);
    }

    function test_GetWalletStallIDReturnsExpiredPendingStallUntilCompleted()
        public
    {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_START);

        assertEq(stallsContract.GetWalletActiveOrUnresolvedStallID(student), 0);

        assertEq(stallsContract.GetWalletStallID(student), stallId);

        vm.prank(student);

        Stall memory expiredStall = stallsContract.GetMyStall();

        _assertStall(
            expiredStall,
            stallId,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            student,
            "",
            School.Others,
            true,
            REGISTRATION_START,
            StallStatus.Expired,
            false,
            1,
            false
        );

        vm.prank(student);

        stallsContract.CompleteMyExpiredPendingStall(stallId);

        assertEq(stallsContract.GetWalletStallID(student), 0);
    }

    // ===============================================================
    // STALL STATUS MANAGEMENT
    // ===============================================================

    function test_StallOwnerCanCloseAndReopenStall() public {
        uint256 stallId = _createApprovedStall(student);

        vm.startPrank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);

        Stall memory closedStall = stallsContract.GetStallDetails(stallId);

        assertEq(uint256(closedStall.stallStatus), uint256(StallStatus.Closed));

        assertFalse(stallsContract.IsStallOpen(stallId));

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Open);

        Stall memory reopenedStall = stallsContract.GetStallDetails(stallId);

        vm.stopPrank();

        _assertDefaultApprovedStall(reopenedStall, stallId, student);

        assertTrue(stallsContract.IsStallOpen(stallId));
    }

    function test_UpdateStatusRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(999, StallStatus.Closed);
    }

    function test_UpdateStatusRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);
    }

    function test_UpdateStatusRevertsForUnapprovedOwner() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(NotApprovedStallOwner.selector);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);
    }

    function test_UpdateStatusRevertsForInvalidNewStatus() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OwnerCanOnlySetOpenOrClosed.selector);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Rejected);
    }

    function test_UpdateStatusRevertsAfterCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(CCNDayAlreadyEnded.selector);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);
    }

    function test_UpdateStatusRevertsWhenStatusIsUnchanged() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(StallStatusUnchanged.selector);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Open);
    }

    // ===============================================================
    // STALL VIEW FUNCTIONS
    // ===============================================================

    function test_GetStallDetailsRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.GetStallDetails(999);
    }

    function test_GetMyStallReturnsActiveStall() public {
        uint256 stallId = _createPendingStall(student);

        vm.prank(student);

        Stall memory stall = stallsContract.GetMyStall();

        assertEq(stall.StallID, stallId);
        assertEq(stall.StallOwnerWallet, student);
    }

    function test_GetMyStallRevertsWhenNoneExists() public {
        vm.expectRevert(WalletHasNotCreatedStall.selector);

        vm.prank(unregisteredWallet);

        stallsContract.GetMyStall();
    }

    function test_GetWalletActiveStallIDReturnsCurrentStall() public {
        uint256 stallId = _createPendingStall(student);

        assertEq(
            stallsContract.GetWalletActiveOrUnresolvedStallID(student),
            stallId
        );

        assertEq(stallsContract.GetWalletStallID(student), stallId);
    }

    function test_OldApprovedStallRemainsUnresolvedAfterCCNDay() public {
        uint256 stallId = _createApprovedStall(student);

        _createSecondCCNDay();

        assertTrue(stallsContract.HasUnresolvedStall(student));

        assertTrue(stallsContract.IsStallActiveOrUnresolved(stallId));

        assertEq(
            stallsContract.GetWalletActiveOrUnresolvedStallID(student),
            stallId
        );
    }

    function test_RejectedStallIsNotActiveOrUnresolved() public {
        uint256 stallId = _createPendingStall(student);

        stallsContract.RejectStall(stallId);

        assertFalse(stallsContract.IsStallActiveOrUnresolved(stallId));

        assertFalse(stallsContract.HasUnresolvedStall(student));
    }

    function test_IsStallCCNDayEndedReturnsCorrectResult() public {
        uint256 stallId = _createApprovedStall(student);

        assertFalse(stallsContract.IsStallCCNDayEnded(stallId));

        vm.warp(CCN_END + 1);

        assertTrue(stallsContract.IsStallCCNDayEnded(stallId));

        assertFalse(stallsContract.IsStallCCNDayEnded(999));
    }

    function test_GetCurrentCCNDayStallsReturnsCreatedStalls() public {
        uint256 firstStallId = _createPendingStall(student);

        uint256 secondStallId = _createPendingStall(studentTwo);

        Stall[] memory currentStalls = stallsContract.GetCurrentCCNDayStalls();

        assertEq(currentStalls.length, 2);
        assertEq(currentStalls[0].StallID, firstStallId);
        assertEq(currentStalls[1].StallID, secondStallId);
    }

    function test_GetCurrentCCNDayStallsRevertsWhenNoCurrentDay() public {
        CareLinkCCNDay emptyCCNDayContract = new CareLinkCCNDay(organiser);

        CareLinkStalls emptyStallsContract = new CareLinkStalls(
            organiser,
            address(usersContract),
            address(emptyCCNDayContract)
        );

        vm.expectRevert(NoCurrentCCNDay.selector);

        emptyStallsContract.GetCurrentCCNDayStalls();
    }

    function test_GetCCNDayStallsReturnsCorrectStalls() public {
        _createPendingStall(student);
        _createPendingStall(studentTwo);

        Stall[] memory ccnStalls = stallsContract.GetCCNDayStalls(1);

        assertEq(ccnStalls.length, 2);
        assertEq(ccnStalls[0].CCNDayID, 1);
        assertEq(ccnStalls[1].CCNDayID, 1);
    }

    function test_GetCCNDayStallsRevertsForZeroID() public {
        vm.expectRevert(InvalidCCNDayID.selector);

        stallsContract.GetCCNDayStalls(0);
    }

    function test_GetCCNDayStallsRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        stallsContract.GetCCNDayStalls(999);
    }

    function test_GetOwnerStallIDsReturnsOwnerHistory() public {
        uint256 stallId = _createPendingStall(student);

        uint256[] memory stallIds = stallsContract.GetOwnerStallIDs(student);

        assertEq(stallIds.length, 1);
        assertEq(stallIds[0], stallId);
    }

    // ===============================================================
    // PRODUCT CREATION
    // ===============================================================

    function test_ApprovedStallOwnerCanCreateProduct() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        assertTrue(stallsContract.DoesProductExist(productId));

        _assertProduct(
            productId,
            stallId,
            "Chicken Rice bruh",
            "Freshly prepared chicken rice",
            "chicken-rice-image",
            500,
            ProductStatus.Available
        );

        uint256[] memory productIds = stallsContract.GetProductIDsByStallID(
            stallId
        );

        assertEq(productIds.length, 1);
        assertEq(productIds[0], productId);
    }

    function test_ClosedStallOwnerCanCreateProduct() public {
        uint256 stallId = _createApprovedStall(student);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);

        uint256 productId = _createProduct(stallId, student);

        assertTrue(stallsContract.DoesProductExist(productId));
    }

    function test_CreateProductRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            999,
            "Product",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForPendingStall() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(NotApprovedStallOwner.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsAfterCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(CCNDayAlreadyEnded.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForEmptyName() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(EmptyProductName.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForEmptyDescription() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(EmptyProductDescription.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForEmptyImage() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(EmptyProductImage.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            "",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForLongName() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(ProductNameTooLong.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            _createString(81),
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForLongDescription() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(ProductDescriptionTooLong.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            _createString(501),
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForLongImage() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(ProductImageTooLong.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            _createString(301),
            100,
            ProductStatus.Available
        );
    }

    function test_CreateProductRevertsForZeroPrice() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(ProductPriceMustBeMoreThanZero.selector);

        vm.prank(student);

        stallsContract.CreateProduct(
            stallId,
            "Product",
            "Description",
            "ipfs://product",
            0,
            ProductStatus.Available
        );
    }

    function test_CreateProductAcceptsMaximumLengths() public {
        uint256 stallId = _createApprovedStall(student);

        string memory maximumName = _createString(80);

        string memory maximumDescription = _createString(500);

        string memory maximumImage = _createString(300);

        vm.prank(student);

        uint256 productId = stallsContract.CreateProduct(
            stallId,
            maximumName,
            maximumDescription,
            maximumImage,
            1,
            ProductStatus.Unavailable
        );

        assertTrue(stallsContract.DoesProductExist(productId));

        _assertProduct(
            productId,
            stallId,
            maximumName,
            maximumDescription,
            maximumImage,
            1,
            ProductStatus.Unavailable
        );
    }

    function testFuzz_CreateProductStoresPositivePrice(
        uint96 _rawPrice
    ) public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productPrice = bound(uint256(_rawPrice), 1, 1_000_000_000_000);

        vm.prank(student);

        uint256 productId = stallsContract.CreateProduct(
            stallId,
            "Fuzz Product",
            "Product created during fuzz testing",
            "fuzz-product-image",
            productPrice,
            ProductStatus.Available
        );

        _assertProduct(
            productId,
            stallId,
            "Fuzz Product",
            "Product created during fuzz testing",
            "fuzz-product-image",
            productPrice,
            ProductStatus.Available
        );
    }

    // ===============================================================
    // EDIT PRODUCT
    // ===============================================================

    function test_StallOwnerCanEditProduct() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.prank(student);

        stallsContract.EditProduct(
            productId,
            "Updated Chicken Rice",
            "Updated product description",
            "updated-product-image",
            650,
            ProductStatus.Unavailable
        );

        _assertProduct(
            productId,
            stallId,
            "Updated Chicken Rice",
            "Updated product description",
            "updated-product-image",
            650,
            ProductStatus.Unavailable
        );
    }

    function test_EditProductCanKeepSameAvailabilityStatus() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.prank(student);

        stallsContract.EditProduct(
            productId,
            "Renamed Product",
            "Renamed description",
            "renamed-product-image",
            700,
            ProductStatus.Available
        );

        _assertProduct(
            productId,
            stallId,
            "Renamed Product",
            "Renamed description",
            "renamed-product-image",
            700,
            ProductStatus.Available
        );
    }

    function test_EditProductRevertsForUnknownProduct() public {
        vm.expectRevert(ProductDoesNotExist.selector);

        vm.prank(student);

        stallsContract.EditProduct(
            999,
            "Product",
            "Description",
            "ipfs://product",
            100,
            ProductStatus.Available
        );
    }

    function test_EditProductRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.EditProduct(
            productId,
            "Changed",
            "Changed",
            "ipfs://changed",
            100,
            ProductStatus.Available
        );
    }

    function test_EditProductRevertsForZeroPrice() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.expectRevert(ProductPriceMustBeMoreThanZero.selector);

        vm.prank(student);

        stallsContract.EditProduct(
            productId,
            "Updated Product",
            "Updated description",
            "updated-product-image",
            0,
            ProductStatus.Unavailable
        );
    }

    function test_EditProductRevertsAfterCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(CCNDayAlreadyEnded.selector);

        vm.prank(student);

        stallsContract.EditProduct(
            productId,
            "Updated Product",
            "Updated description",
            "updated-product-image",
            600,
            ProductStatus.Available
        );
    }

    function test_InvalidProductEditDoesNotModifyProduct() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.expectRevert(ProductPriceMustBeMoreThanZero.selector);

        vm.prank(student);

        stallsContract.EditProduct(
            productId,
            "Invalid Changed Name",
            "Invalid changed description",
            "invalid-product-image",
            0,
            ProductStatus.Unavailable
        );

        _assertProduct(
            productId,
            stallId,
            "Chicken Rice bruh",
            "Freshly prepared chicken rice",
            "chicken-rice-image",
            500,
            ProductStatus.Available
        );
    }

    // ===============================================================
    // DELETE PRODUCT
    // ===============================================================

    function test_StallOwnerCanDeleteProduct() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.prank(student);

        stallsContract.DeleteProduct(productId);

        assertFalse(stallsContract.DoesProductExist(productId));

        uint256[] memory productIds = stallsContract.GetProductIDsByStallID(
            stallId
        );

        assertEq(productIds.length, 0);
    }

    function test_DeleteProductRemovesCorrectArrayEntry() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 firstProductId = _createProduct(stallId, student);

        vm.prank(student);

        uint256 secondProductId = stallsContract.CreateProduct(
            stallId,
            "Second Product",
            "Second description",
            "ipfs://second-product",
            200,
            ProductStatus.Available
        );

        vm.prank(student);

        stallsContract.DeleteProduct(firstProductId);

        uint256[] memory productIds = stallsContract.GetProductIDsByStallID(
            stallId
        );

        assertEq(productIds.length, 1);
        assertEq(productIds[0], secondProductId);

        assertFalse(stallsContract.DoesProductExist(firstProductId));

        assertTrue(stallsContract.DoesProductExist(secondProductId));
    }

    function test_DeleteProductRevertsForUnknownProduct() public {
        vm.expectRevert(ProductDoesNotExist.selector);

        vm.prank(student);

        stallsContract.DeleteProduct(999);
    }

    function test_DoesProductExistReturnsFalseForZeroAndUnknownProduct()
        public
        view
    {
        assertFalse(stallsContract.DoesProductExist(0));

        assertFalse(stallsContract.DoesProductExist(999));
    }

    function test_GetProductIDsRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.GetProductIDsByStallID(999);
    }

    function test_DeleteProductRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.DeleteProduct(productId);

        assertTrue(stallsContract.DoesProductExist(productId));

        _assertProduct(
            productId,
            stallId,
            "Chicken Rice bruh",
            "Freshly prepared chicken rice",
            "chicken-rice-image",
            500,
            ProductStatus.Available
        );
    }

    // ===============================================================
    // DELETE INDIVIDUAL STALL
    // ===============================================================

    function test_OrganiserCanDeleteStallAndItsProducts() public {
        uint256 stallId = _createApprovedStall(student);

        uint256 productId = _createProduct(stallId, student);

        vm.expectCall(
            address(mockPaymentContract),
            abi.encodeCall(
                MockCareLinkPaymentsForStalls.HasUnsettledPaidPayments,
                (stallId)
            )
        );

        stallsContract.DeleteStall(stallId);

        assertFalse(stallsContract.DoesStallExist(stallId));

        assertFalse(stallsContract.DoesProductExist(productId));

        assertEq(stallsContract.WalletStallID(student), 0);

        assertFalse(stallsContract.HasCreatedStall(student));

        assertFalse(stallsContract.IsStallOwner(student));

        assertEq(stallsContract.GetCCNDayStallCount(1), 0);
    }

    function test_DeleteStallRevertsForNonOrganiser() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(outsider);

        stallsContract.DeleteStall(stallId);
    }

    function test_DeleteStallRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.DeleteStall(999);
    }

    function test_DeleteStallRevertsAfterCCNDayStarts() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_START);

        vm.expectRevert(CCNDayAlreadyStarted.selector);

        stallsContract.DeleteStall(stallId);
    }

    function test_DeleteStallRevertsWithUnsettledPayments() public {
        uint256 stallId = _createApprovedStall(student);

        mockPaymentContract.SetHasUnsettledPaidPayments(stallId, true);

        vm.expectRevert(StallHasUnsettledPaidPayments.selector);

        stallsContract.DeleteStall(stallId);
    }

    function test_DeletionSucceedsWhenPaymentContractNotConfigured() public {
        CareLinkStalls noPaymentStalls = new CareLinkStalls(
            organiser,
            address(usersContract),
            address(ccnDayContract)
        );

        vm.warp(REGISTRATION_START);

        vm.prank(student);

        uint256 stallId = noPaymentStalls.CreateStall(
            "No Payment Contract Stall",
            "Tests the zero payment contract branch",
            "ipfs://no-payment",
            StallType.Services,
            false
        );

        noPaymentStalls.ApproveStall(stallId, "Location", School.IIT);

        noPaymentStalls.DeleteStall(stallId);

        assertFalse(noPaymentStalls.DoesStallExist(stallId));
    }

    // ===============================================================
    // OWNER DELETES OWN STALL
    // ===============================================================

    function test_ApprovedOwnerCanDeleteOwnStall() public {
        uint256 stallId = _createApprovedStall(student);

        vm.prank(student);

        stallsContract.DeleteMyStall(stallId);

        assertFalse(stallsContract.DoesStallExist(stallId));

        assertFalse(stallsContract.HasCreatedStall(student));
    }

    function test_DeleteMyStallRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(studentTwo);

        stallsContract.DeleteMyStall(stallId);
    }

    function test_DeleteMyStallRevertsForPendingStall() public {
        uint256 stallId = _createPendingStall(student);

        vm.expectRevert(NotApprovedStallOwner.selector);

        vm.prank(student);

        stallsContract.DeleteMyStall(stallId);
    }

    function test_DeleteMyStallRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(student);

        stallsContract.DeleteMyStall(999);
    }

    // ===============================================================
    // DELETE ALL STALLS THROUGH CCN DAY CONTRACT
    // ===============================================================

    function test_DeletingCCNDayDeletesAllRelatedStalls() public {
        uint256 firstStallId = _createApprovedStall(student);

        uint256 secondStallId = _createApprovedStall(studentTwo);

        ccnDayContract.DeleteCCNDay(1);

        assertFalse(stallsContract.DoesStallExist(firstStallId));

        assertFalse(stallsContract.DoesStallExist(secondStallId));

        assertFalse(ccnDayContract.DoesCCNDayExist(1));

        assertEq(ccnDayContract.GetCurrentCCNDayID(), 0);
    }

    function test_DirectDeleteByCCNDayRevertsForWrongCaller() public {
        vm.expectRevert(NotCCNDayContract.selector);

        vm.prank(outsider);

        stallsContract.DeleteStallsByCCNDay(1);
    }

    function test_DeletingCCNDayRollsBackWhenPaymentsUnsettled() public {
        uint256 stallId = _createApprovedStall(student);

        mockPaymentContract.SetHasUnsettledPaidPayments(stallId, true);

        vm.expectRevert(StallHasUnsettledPaidPayments.selector);

        ccnDayContract.DeleteCCNDay(1);

        assertTrue(stallsContract.DoesStallExist(stallId));
        assertTrue(ccnDayContract.DoesCCNDayExist(1));
    }

    // ===============================================================
    // WITHDRAWAL PERMISSION
    // ===============================================================

    function test_OrganiserCanAllowWithdrawalAfterCCNDay() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        _assertStall(
            stall,
            stallId,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            student,
            "Block 30 Level 2",
            School.IIT,
            true,
            REGISTRATION_START,
            StallStatus.Open,
            true,
            1,
            false
        );

        assertTrue(stallsContract.IsStallWithdrawalAllowed(stallId));
    }

    function test_ClosedStallCanReceiveWithdrawalPermission() public {
        uint256 stallId = _createApprovedStall(student);

        vm.prank(student);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);

        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(stallId);

        assertTrue(stallsContract.IsStallWithdrawalAllowed(stallId));
    }

    function test_AllowWithdrawalRevertsForNonOrganiser() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(outsider);

        stallsContract.AllowStallWithdrawal(stallId);
    }

    function test_AllowWithdrawalRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.AllowStallWithdrawal(999);
    }

    function test_AllowWithdrawalRevertsBeforeCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END);

        vm.expectRevert(CCNDayNotEnded.selector);

        stallsContract.AllowStallWithdrawal(stallId);
    }

    function test_AllowWithdrawalRevertsForPendingStall() public {
        uint256 stallId = _createPendingStall(student);

        vm.warp(CCN_END + 1);

        vm.expectRevert(StallNotReadyForWithdrawal.selector);

        stallsContract.AllowStallWithdrawal(stallId);
    }

    function test_AllowWithdrawalRevertsWhenAlreadyAllowed() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(stallId);

        vm.expectRevert(WithdrawalAlreadyAllowed.selector);

        stallsContract.AllowStallWithdrawal(stallId);
    }

    function test_WithdrawalGetterRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.IsStallWithdrawalAllowed(999);
    }

    // ===============================================================
    // MARK WITHDRAWAL COMPLETED AND ARCHIVE
    // ===============================================================

    function test_PaymentContractCanMarkWithdrawalCompleted() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(stallId);

        mockPaymentContract.MarkWithdrawalCompleted(stallsContract, stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        _assertStall(
            stall,
            stallId,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            student,
            "Block 30 Level 2",
            School.IIT,
            true,
            REGISTRATION_START,
            StallStatus.Open,
            true,
            1,
            true
        );

        assertEq(stallsContract.WalletStallID(student), 0);

        assertFalse(stallsContract.HasCreatedStall(student));

        assertTrue(stallsContract.IsStallArchived(stallId));

        assertFalse(stallsContract.IsWalletApprovedStallOwner(student));
    }

    function test_MarkWithdrawalCompletedRevertsForWrongCaller() public {
        uint256 stallId = _createApprovedStall(student);

        vm.expectRevert(NotPaymentContract.selector);

        vm.prank(outsider);

        stallsContract.MarkStallWithdrawalCompleted(stallId);
    }

    function test_MarkWithdrawalCompletedRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        mockPaymentContract.MarkWithdrawalCompleted(stallsContract, 999);
    }

    function test_GetMyStallHistoryReturnsArchivedStall() public {
        uint256 stallId = _createApprovedStall(student);

        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(stallId);

        mockPaymentContract.MarkWithdrawalCompleted(stallsContract, stallId);

        vm.prank(student);

        Stall[] memory history = stallsContract.GetMyStallHistory();

        assertEq(history.length, 1);

        _assertStall(
            history[0],
            stallId,
            "CareLink Stall",
            "A stall created for unit testing",
            "stall-image",
            StallType.FoodAndBeverage,
            student,
            "Block 30 Level 2",
            School.IIT,
            true,
            REGISTRATION_START,
            StallStatus.Open,
            true,
            1,
            true
        );
    }

    function test_GetMyStallHistoryInitiallyReturnsEmpty() public {
        _createApprovedStall(student);

        vm.prank(student);

        Stall[] memory history = stallsContract.GetMyStallHistory();

        assertEq(history.length, 0);
    }

    // ===============================================================
    // PAYMENT HELPER GETTERS
    // ===============================================================

    function test_PaymentHelperGettersReturnStallInformation() public {
        uint256 stallId = _createApprovedStall(student);

        assertEq(stallsContract.GetStallOwnerWallet(stallId), student);

        assertEq(stallsContract.GetStallCCNDayID(stallId), 1);

        assertTrue(stallsContract.IsStallOpen(stallId));

        assertTrue(stallsContract.IsWalletApprovedStallOwner(student));

        assertFalse(stallsContract.IsWalletApprovedStallOwner(outsider));
    }

    function test_GetStallOwnerRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.GetStallOwnerWallet(999);
    }

    function test_GetStallCCNDayIDRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        stallsContract.GetStallCCNDayID(999);
    }

    function test_IsStallOpenReturnsFalseForUnknownStall() public view {
        assertFalse(stallsContract.IsStallOpen(999));
    }
}
