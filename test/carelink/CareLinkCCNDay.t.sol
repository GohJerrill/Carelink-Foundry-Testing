// To test without the test files: forge coverage --exclude-tests
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CareLinkCCNDay} from "../../src/carelink/CareLinkCCNDay.sol";
import "../../src/carelink/CareLinkTypes.sol";

/*
 * This mock replaces CareLinkStalls during the CCN Day unit tests.
 *
 * CareLinkCCNDay only needs to call:
 * DeleteStallsByCCNDay(uint256)
 *
 * The mock records whether the function was called and which
 * CCN Day ID was supplied.
 */
contract MockCareLinkStallsForCCNDay {
    uint256 public deleteCallCount;
    uint256 public lastDeletedCCNDayID;

    bool public shouldRevert;

    error MockDeleteStallsFailed();

    function SetShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function DeleteStallsByCCNDay(uint256 _ccnDayId) external {
        if (shouldRevert) {
            revert MockDeleteStallsFailed();
        }

        deleteCallCount++;
        lastDeletedCCNDayID = _ccnDayId;
    }
}

contract CareLinkCCNDayTest is Test {
    CareLinkCCNDay internal ccnDayContract;
    MockCareLinkStallsForCCNDay internal mockStallContract;

    address internal organiser;
    address internal nonOrganiser;
    address internal replacementStallContract;

    /*
     * We use a fixed timestamp so every test is deterministic.
     *
     * Timeline:
     *
     * BASE_TIME
     *      |
     *      +-- Registration opens after 1 day
     *      +-- Registration closes after 2 days
     *      +-- CCN Day starts after 3 days
     *      +-- CCN Day ends after 4 days
     */
    uint256 internal constant BASE_TIME = 2_000_000_000;

    uint256 internal constant REGISTRATION_START = BASE_TIME + 1 days;

    uint256 internal constant REGISTRATION_END = BASE_TIME + 2 days;

    uint256 internal constant CCN_START = BASE_TIME + 3 days;

    uint256 internal constant CCN_END = BASE_TIME + 4 days;

    function setUp() public {
        vm.warp(BASE_TIME);

        organiser = makeAddr("organiser");
        nonOrganiser = makeAddr("nonOrganiser");
        replacementStallContract = makeAddr("replacementStallContract");

        ccnDayContract = new CareLinkCCNDay(organiser);
        mockStallContract = new MockCareLinkStallsForCCNDay();
    }

    function test_OrganiserCanUpdateStallContractAddress() public {
        vm.startPrank(organiser);

        ccnDayContract.SetStallContractAddress(address(mockStallContract));

        assertEq(
            address(ccnDayContract.stallContract()),
            address(mockStallContract)
        );

        ccnDayContract.SetStallContractAddress(replacementStallContract);

        vm.stopPrank();

        assertEq(
            address(ccnDayContract.stallContract()),
            replacementStallContract
        );
    }

    // ===============================================================
    // TEST HELPERS
    // ===============================================================

    /*
     * Returns the usual eligible-school list used by most tests.
     */
    function _defaultSchools() internal pure returns (School[] memory schools) {
        schools = new School[](3);

        schools[0] = School.IIT;
        schools[1] = School.Business;
        schools[2] = School.Engineering;
    }

    /*
     * Returns a different list used when testing EditCCNDay.
     */
    function _editedSchools() internal pure returns (School[] memory schools) {
        schools = new School[](2);

        schools[0] = School.Design;
        schools[1] = School.Science;
    }

    function _assertCCNDay(
        CCNDay memory ccnDay,
        uint256 expectedID,
        string memory expectedName,
        string memory expectedDescription,
        uint256 expectedStart,
        uint256 expectedEnd,
        uint256 expectedRegistrationStart,
        uint256 expectedRegistrationEnd,
        uint256 expectedCreatedAt,
        address expectedCreatedBy
    ) internal pure {
        assertEq(ccnDay.CCNDayID, expectedID);
        assertEq(ccnDay.CCNName, expectedName);
        assertEq(ccnDay.CCNDescription, expectedDescription);
        assertEq(ccnDay.StartDateTime, expectedStart);
        assertEq(ccnDay.EndDateTime, expectedEnd);
        assertEq(
            ccnDay.StallRegistrationStartDateTime,
            expectedRegistrationStart
        );
        assertEq(ccnDay.StallRegistrationEndDateTime, expectedRegistrationEnd);
        assertEq(ccnDay.CreatedAt, expectedCreatedAt);
        assertEq(ccnDay.CreatedBy, expectedCreatedBy);
    }

    /*
     * Creates one normal valid CCN Day as the organiser.
     */
    function _createDefaultCCNDay() internal {
        School[] memory schools = _defaultSchools();

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "CareLink CCN Day",
            "Temasek Polytechnic CCN Day event",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    /*
     * Creates a custom CCN Day.
     *
     * This makes it easier to create a second CCN Day later
     * without repeating the full function call.
     */
    function _createCustomCCNDay(
        string memory ccnName,
        string memory ccnDescription,
        uint256 startDateTime,
        uint256 endDateTime,
        uint256 registrationStartDateTime,
        uint256 registrationEndDateTime,
        School[] memory schools
    ) internal {
        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            ccnName,
            ccnDescription,
            startDateTime,
            endDateTime,
            registrationStartDateTime,
            registrationEndDateTime,
            schools
        );
    }

    /*
     * Creates a second CCN Day after the first has ended.
     *
     * This is used for history and "only current CCN Day"
     * validation tests.
     */
    function _createSecondCCNDay() internal returns (uint256) {
        vm.warp(CCN_END + 1);

        uint256 secondRegistrationStart = block.timestamp + 1 days;

        uint256 secondRegistrationEnd = block.timestamp + 2 days;

        uint256 secondStart = block.timestamp + 3 days;

        uint256 secondEnd = block.timestamp + 4 days;

        School[] memory schools = _editedSchools();

        _createCustomCCNDay(
            "Second CCN Day",
            "Second CareLink CCN Day event",
            secondStart,
            secondEnd,
            secondRegistrationStart,
            secondRegistrationEnd,
            schools
        );

        return ccnDayContract.GetCurrentCCNDayID();
    }

    // ===============================================================
    // CONSTRUCTOR
    // ===============================================================

    function test_ConstructorSetsOrganiser() public view {
        assertEq(ccnDayContract.Organiser(), organiser);
    }

    function test_ConstructorRevertsForZeroOrganiser() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkCCNDay(address(0));
    }

    // ===============================================================
    // INITIAL STATE
    // ===============================================================

    function test_InitialStateHasNoCurrentCCNDay() public view {
        assertEq(ccnDayContract.GetCurrentCCNDayID(), 0);
        assertFalse(ccnDayContract.IsCurrentCCNDayActive());
        assertFalse(ccnDayContract.IsStallRegistrationOpen());
    }

    function test_GetAllCCNDaysInitiallyReturnsEmptyArray() public view {
        CCNDay[] memory allCCNDays = ccnDayContract.GetAllCCNDays();

        assertEq(allCCNDays.length, 0);
    }

    function test_DoesCCNDayExistReturnsFalseForZeroID() public view{
        assertFalse(ccnDayContract.DoesCCNDayExist(0));
    }

    function test_DoesCCNDayExistReturnsFalseForUnknownID() public view {
        assertFalse(ccnDayContract.DoesCCNDayExist(999));
    }

    function test_IsSchoolEligibleForCurrentCCNDayReturnsFalseWhenNoneExists()
        public view
    {
        assertFalse(
            ccnDayContract.IsSchoolEligibleForCurrentCCNDay(School.IIT)
        );
    }

    // ===============================================================
    // SET STALL CONTRACT ADDRESS
    // ===============================================================

    function test_SetStallContractAddressRevertsForNonOrganiser() public {
        vm.expectRevert(NotOrganiser.selector);

        vm.prank(nonOrganiser);

        ccnDayContract.SetStallContractAddress(address(mockStallContract));
    }

    function test_SetStallContractAddressRevertsForZeroAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        vm.prank(organiser);

        ccnDayContract.SetStallContractAddress(address(0));
    }

    // ===============================================================
    // SUCCESSFUL CCN DAY CREATION
    // ===============================================================

    function test_CreateNewCCNDayStoresAllDetails() public {
        _createDefaultCCNDay();

        CCNDay memory currentCCNDay = ccnDayContract.GetCurrentCCNDay();

        assertEq(currentCCNDay.CCNDayID, 1);
        assertEq(currentCCNDay.CCNName, "CareLink CCN Day");

        assertEq(
            currentCCNDay.CCNDescription,
            "Temasek Polytechnic CCN Day event"
        );

        assertEq(currentCCNDay.StartDateTime, CCN_START);
        assertEq(currentCCNDay.EndDateTime, CCN_END);

        assertEq(
            currentCCNDay.StallRegistrationStartDateTime,
            REGISTRATION_START
        );

        assertEq(currentCCNDay.StallRegistrationEndDateTime, REGISTRATION_END);

        assertEq(currentCCNDay.CreatedAt, BASE_TIME);
        assertEq(currentCCNDay.CreatedBy, organiser);

        assertEq(ccnDayContract.GetCurrentCCNDayID(), 1);
        assertTrue(ccnDayContract.DoesCCNDayExist(1));
    }

    function test_CreateNewCCNDayStoresEligibleSchools() public {
        _createDefaultCCNDay();

        School[] memory eligibleSchools = ccnDayContract
            .GetCCNDayEligibleSchools(1);

        assertEq(eligibleSchools.length, 3);

        assertEq(uint256(eligibleSchools[0]), uint256(School.IIT));

        assertEq(uint256(eligibleSchools[1]), uint256(School.Business));

        assertEq(uint256(eligibleSchools[2]), uint256(School.Engineering));

        assertTrue(ccnDayContract.IsSchoolEligibleForCurrentCCNDay(School.IIT));

        assertTrue(
            ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Business)
        );

        assertFalse(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Design));
    }

    function test_GetCCNDayByIDReturnsCreatedCCNDay() public {
        _createDefaultCCNDay();

        CCNDay memory storedCCNDay = ccnDayContract.GetCCNDayByID(1);

        assertEq(storedCCNDay.CCNDayID, 1);
        assertEq(storedCCNDay.CCNName, "CareLink CCN Day");
        assertEq(storedCCNDay.CreatedBy, organiser);
    }

    function test_GetCCNDayStartAndEndTimes() public {
        _createDefaultCCNDay();

        assertEq(ccnDayContract.GetCCNDayStartTime(1), CCN_START);

        assertEq(ccnDayContract.GetCCNDayEndTime(1), CCN_END);
    }

    // ===============================================================
    // CREATE ACCESS CONTROL
    // ===============================================================

    function test_CreateNewCCNDayRevertsForNonOrganiser() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(nonOrganiser);

        ccnDayContract.CreateNewCCNDay(
            "Unauthorised CCN Day",
            "This should not be created",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsWhileCurrentDayActive() public {
        _createDefaultCCNDay();

        School[] memory schools = _editedSchools();

        vm.expectRevert(CurrentCCNDayStillActive.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Second CCN Day",
            "Cannot be created while the first remains active",
            CCN_END + 3 days,
            CCN_END + 4 days,
            CCN_END + 1 days,
            CCN_END + 2 days,
            schools
        );
    }

    function test_CreateNewCCNDayCanBeCreatedAfterPreviousDayEnds() public {
        _createDefaultCCNDay();

        uint256 secondCCNDayID = _createSecondCCNDay();

        assertEq(secondCCNDayID, 2);
        assertTrue(ccnDayContract.DoesCCNDayExist(1));
        assertTrue(ccnDayContract.DoesCCNDayExist(2));

        CCNDay memory currentCCNDay = ccnDayContract.GetCurrentCCNDay();

        assertEq(currentCCNDay.CCNDayID, 2);
        assertEq(currentCCNDay.CCNName, "Second CCN Day");
    }

    // ===============================================================
    // CREATE INPUT VALIDATION
    // ===============================================================

    function test_CreateNewCCNDayRevertsWhenEndTimeIsNotFuture() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(CCNDayEndTimeInPast.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Invalid CCN Day",
            "The end time is not in the future",
            BASE_TIME + 1 days,
            BASE_TIME,
            BASE_TIME - 2 days,
            BASE_TIME - 1 days,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsForEmptyName() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(EmptyCCNName.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "",
            "Valid description",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsForEmptyDescription() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(EmptyCCNDescription.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Valid name",
            "",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsForInvalidCCNDateRange() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(InvalidCCNDateRange.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Invalid dates",
            "Start and end are equal",
            CCN_END,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsForInvalidRegistrationRange() public {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(InvalidRegistrationDateRange.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Invalid registration",
            "Registration dates are invalid",
            CCN_START,
            CCN_END,
            REGISTRATION_END,
            REGISTRATION_START,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsWhenRegistrationEndsAfterCCNStart()
        public
    {
        School[] memory schools = _defaultSchools();

        vm.expectRevert(RegistrationEndsAfterCCNStart.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Late registration",
            "Registration closes after the event starts",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            CCN_START + 1,
            schools
        );
    }

    function test_CreateNewCCNDayAllowsRegistrationToEndExactlyAtCCNStart()
        public
    {
        School[] memory schools = _defaultSchools();

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Boundary CCN Day",
            "Registration closes exactly when CCN Day starts",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            CCN_START,
            schools
        );

        CCNDay memory createdCCNDay = ccnDayContract.GetCurrentCCNDay();

        assertEq(createdCCNDay.StallRegistrationEndDateTime, CCN_START);

        assertEq(createdCCNDay.StartDateTime, CCN_START);
    }

    function test_CreateNewCCNDayRevertsForEmptyEligibleSchools() public {
        School[] memory schools = new School[](0);

        vm.expectRevert(EmptyEligibleSchools.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "No schools",
            "No eligible schools were selected",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsForDuplicateSchools() public {
        School[] memory schools = new School[](2);

        schools[0] = School.IIT;
        schools[1] = School.IIT;

        vm.expectRevert(DuplicateEligibleSchools.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Duplicate schools",
            "IIT was selected twice",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_CreateNewCCNDayRevertsWhenOthersIsEligible() public {
        School[] memory schools = new School[](2);

        schools[0] = School.IIT;
        schools[1] = School.Others;

        vm.expectRevert(EligibleSchoolCannotBeOthers.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Invalid eligible school",
            "Others cannot be an eligible CCN Day school",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            schools
        );
    }

    function test_FailedCCNDayCreationDoesNotConsumeID() public {
        School[] memory invalidSchools = new School[](0);

        vm.expectRevert(EmptyEligibleSchools.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Failed CCN Day",
            "This creation should revert",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            invalidSchools
        );

        assertEq(ccnDayContract.GetCurrentCCNDayID(), 0);
        assertFalse(ccnDayContract.DoesCCNDayExist(1));

        _createDefaultCCNDay();

        CCNDay memory createdCCNDay = ccnDayContract.GetCurrentCCNDay();

        assertEq(createdCCNDay.CCNDayID, 1);
    }

    // ===============================================================
    // ACTIVE STATUS AND TIME BOUNDARIES
    // ===============================================================

    function test_IsCurrentCCNDayActiveUntilEndTime() public {
        _createDefaultCCNDay();

        /*
         * Your implementation treats the current CCN Day as active
         * before it starts, provided its end time has not passed.
         */
        assertTrue(ccnDayContract.IsCurrentCCNDayActive());

        vm.warp(CCN_END);

        assertTrue(ccnDayContract.IsCurrentCCNDayActive());

        vm.warp(CCN_END + 1);

        assertFalse(ccnDayContract.IsCurrentCCNDayActive());
    }

    function test_EndedCCNDayRemainsCurrentUntilReplacedOrDeleted() public {
        _createDefaultCCNDay();

        vm.warp(CCN_END + 1);

        assertFalse(ccnDayContract.IsCurrentCCNDayActive());

        assertEq(ccnDayContract.GetCurrentCCNDayID(), 1);

        CCNDay memory endedCCNDay = ccnDayContract.GetCurrentCCNDay();

        assertEq(endedCCNDay.CCNDayID, 1);
        assertEq(endedCCNDay.CCNName, "CareLink CCN Day");
    }

    function test_StallRegistrationOpenAtInclusiveBoundaries() public {
        _createDefaultCCNDay();

        assertFalse(ccnDayContract.IsStallRegistrationOpen());

        vm.warp(REGISTRATION_START);

        assertTrue(ccnDayContract.IsStallRegistrationOpen());

        vm.warp(REGISTRATION_END);

        assertTrue(ccnDayContract.IsStallRegistrationOpen());

        vm.warp(REGISTRATION_END + 1);

        assertFalse(ccnDayContract.IsStallRegistrationOpen());
    }

    function test_StallRegistrationClosedAfterCCNDayEnds() public {
        _createDefaultCCNDay();

        vm.warp(CCN_END + 1);

        assertFalse(ccnDayContract.IsStallRegistrationOpen());
    }

    // ===============================================================
    // GETTER REVERT TESTS
    // ===============================================================

    function test_GetCurrentCCNDayRevertsWhenNoneExists() public {
        vm.expectRevert(NoCurrentCCNDay.selector);

        ccnDayContract.GetCurrentCCNDay();
    }

    function test_GetCCNDayByIDRevertsForZeroID() public {
        vm.expectRevert(InvalidCCNDayID.selector);

        ccnDayContract.GetCCNDayByID(0);
    }

    function test_GetCCNDayByIDRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        ccnDayContract.GetCCNDayByID(999);
    }

    function test_GetEligibleSchoolsRevertsForZeroID() public {
        vm.expectRevert(InvalidCCNDayID.selector);

        ccnDayContract.GetCCNDayEligibleSchools(0);
    }

    function test_GetEligibleSchoolsRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        ccnDayContract.GetCCNDayEligibleSchools(999);
    }

    function test_GetStartTimeRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        ccnDayContract.GetCCNDayStartTime(999);
    }

    function test_IsSchoolEligibleForUnknownCCNDayReturnsFalse() public view {
        assertFalse(ccnDayContract.IsSchoolEligibleForCCNDay(999, School.IIT));
    }

    function test_GetEndTimeRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        ccnDayContract.GetCCNDayEndTime(999);
    }

    function test_CreateNewCCNDayRevertsWhenStartTimeIsInPast() public {
        School[] memory eligibleSchools = new School[](1);
        eligibleSchools[0] = School.IIT;

        uint256 ccnStartTime = block.timestamp - 1;
        uint256 ccnEndTime = block.timestamp + 1 days;

        uint256 registrationStartTime = block.timestamp - 3 days;
        uint256 registrationEndTime = block.timestamp - 2 days;

        vm.expectRevert(CCNDayStartTimeNotFuture.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Past Start CCN Day",
            "This CCN Day should not be created.",
            ccnStartTime,
            ccnEndTime,
            registrationStartTime,
            registrationEndTime,
            eligibleSchools
        );
    }

    function test_CreateNewCCNDayRevertsWhenStartTimeEqualsCurrentTime()
        public
    {
        School[] memory eligibleSchools = new School[](1);
        eligibleSchools[0] = School.IIT;

        uint256 ccnStartTime = block.timestamp;
        uint256 ccnEndTime = block.timestamp + 1 days;

        uint256 registrationStartTime = block.timestamp - 2 days;
        uint256 registrationEndTime = block.timestamp - 1 days;

        vm.expectRevert(CCNDayStartTimeNotFuture.selector);

        vm.prank(organiser);

        ccnDayContract.CreateNewCCNDay(
            "Current Start CCN Day",
            "This CCN Day should not be created.",
            ccnStartTime,
            ccnEndTime,
            registrationStartTime,
            registrationEndTime,
            eligibleSchools
        );
    }

    // ===============================================================
    // GET ALL CCN DAYS
    // ===============================================================

    function test_GetAllCCNDaysReturnsMultipleExistingDays() public {
        _createDefaultCCNDay();
        _createSecondCCNDay();

        CCNDay[] memory allCCNDays = ccnDayContract.GetAllCCNDays();

        assertEq(allCCNDays.length, 2);

        assertEq(allCCNDays[0].CCNDayID, 1);
        assertEq(allCCNDays[0].CCNName, "CareLink CCN Day");

        assertEq(allCCNDays[1].CCNDayID, 2);
        assertEq(allCCNDays[1].CCNName, "Second CCN Day");
    }

    // ===============================================================
    // EDIT CCN DAY
    // ===============================================================

    function test_OrganiserCanEditCurrentCCNDay() public {
        _createDefaultCCNDay();

        School[] memory newSchools = _editedSchools();

        uint256 newRegistrationStart = BASE_TIME + 2 days;

        uint256 newRegistrationEnd = BASE_TIME + 3 days;

        uint256 newStart = BASE_TIME + 4 days;

        uint256 newEnd = BASE_TIME + 5 days;

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            1,
            "Updated CCN Day",
            "Updated CCN Day description",
            newStart,
            newEnd,
            newRegistrationStart,
            newRegistrationEnd,
            newSchools
        );

        CCNDay memory updatedCCNDay = ccnDayContract.GetCCNDayByID(1);

        assertEq(updatedCCNDay.CCNName, "Updated CCN Day");

        assertEq(updatedCCNDay.CCNDescription, "Updated CCN Day description");

        assertEq(updatedCCNDay.StartDateTime, newStart);
        assertEq(updatedCCNDay.EndDateTime, newEnd);

        assertEq(
            updatedCCNDay.StallRegistrationStartDateTime,
            newRegistrationStart
        );

        assertEq(
            updatedCCNDay.StallRegistrationEndDateTime,
            newRegistrationEnd
        );

        /*
         * Editing should not replace the original creation details.
         */
        assertEq(updatedCCNDay.CreatedAt, BASE_TIME);
        assertEq(updatedCCNDay.CreatedBy, organiser);

        /*
         * Old school eligibility must be removed.
         */
        assertFalse(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.IIT));

        assertFalse(
            ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Business)
        );

        assertFalse(
            ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Engineering)
        );

        /*
         * New school eligibility must be stored.
         */
        assertTrue(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Design));

        assertTrue(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Science));

        School[] memory storedSchools = ccnDayContract.GetCCNDayEligibleSchools(
            1
        );

        assertEq(storedSchools.length, 2);

        assertEq(uint256(storedSchools[0]), uint256(School.Design));

        assertEq(uint256(storedSchools[1]), uint256(School.Science));
    }

    function test_EditCCNDayRevertsForNonOrganiser() public {
        _createDefaultCCNDay();

        School[] memory newSchools = _editedSchools();

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(nonOrganiser);

        ccnDayContract.EditCCNDay(
            1,
            "Unauthorised edit",
            "This edit must fail",
            BASE_TIME + 4 days,
            BASE_TIME + 5 days,
            BASE_TIME + 2 days,
            BASE_TIME + 3 days,
            newSchools
        );
    }

    function test_EditCCNDayRevertsForZeroID() public {
        School[] memory newSchools = _editedSchools();

        vm.expectRevert(InvalidCCNDayID.selector);

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            0,
            "Invalid edit",
            "Zero ID",
            BASE_TIME + 4 days,
            BASE_TIME + 5 days,
            BASE_TIME + 2 days,
            BASE_TIME + 3 days,
            newSchools
        );
    }

    function test_EditCCNDayRevertsForUnknownID() public {
        School[] memory newSchools = _editedSchools();

        vm.expectRevert(CCNDayDoesNotExist.selector);

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            999,
            "Invalid edit",
            "Unknown ID",
            BASE_TIME + 4 days,
            BASE_TIME + 5 days,
            BASE_TIME + 2 days,
            BASE_TIME + 3 days,
            newSchools
        );
    }

    function test_EditCCNDayRevertsForNonCurrentCCNDay() public {
        _createDefaultCCNDay();
        _createSecondCCNDay();

        School[] memory newSchools = _defaultSchools();

        uint256 newRegistrationStart = block.timestamp + 1 days;

        uint256 newRegistrationEnd = block.timestamp + 2 days;

        uint256 newStart = block.timestamp + 3 days;

        uint256 newEnd = block.timestamp + 4 days;

        vm.expectRevert(CanOnlyEditCurrentCCNDay.selector);

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            1,
            "Old CCN Day",
            "Attempt to edit an old CCN Day",
            newStart,
            newEnd,
            newRegistrationStart,
            newRegistrationEnd,
            newSchools
        );
    }

    function test_EditCCNDayRevertsWhenEndTimeIsNotFuture() public {
        _createDefaultCCNDay();

        School[] memory newSchools = _editedSchools();

        vm.expectRevert(CCNDayEndTimeInPast.selector);

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            1,
            "Invalid edited CCN Day",
            "The edited end time is not future",
            BASE_TIME - 100,
            BASE_TIME,
            BASE_TIME - 300,
            BASE_TIME - 200,
            newSchools
        );
    }

    function test_InvalidEditDoesNotModifyExistingCCNDay() public {
        _createDefaultCCNDay();

        School[] memory duplicateSchools = new School[](2);

        duplicateSchools[0] = School.Design;
        duplicateSchools[1] = School.Design;

        vm.expectRevert(DuplicateEligibleSchools.selector);

        vm.prank(organiser);

        ccnDayContract.EditCCNDay(
            1,
            "Invalid Updated Name",
            "This edit should completely revert",
            BASE_TIME + 4 days,
            BASE_TIME + 5 days,
            BASE_TIME + 2 days,
            BASE_TIME + 3 days,
            duplicateSchools
        );

        CCNDay memory unchangedCCNDay = ccnDayContract.GetCCNDayByID(1);

        _assertCCNDay(
            unchangedCCNDay,
            1,
            "CareLink CCN Day",
            "Temasek Polytechnic CCN Day event",
            CCN_START,
            CCN_END,
            REGISTRATION_START,
            REGISTRATION_END,
            BASE_TIME,
            organiser
        );

        assertTrue(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.IIT));

        assertTrue(
            ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Business)
        );

        assertTrue(
            ccnDayContract.IsSchoolEligibleForCCNDay(1, School.Engineering)
        );
    }

    // ===============================================================
    // DELETE CCN DAY
    // ===============================================================

    function test_OrganiserCanDeleteCurrentCCNDay() public {
        _createDefaultCCNDay();

        vm.prank(organiser);

        ccnDayContract.SetStallContractAddress(address(mockStallContract));

        vm.expectCall(
            address(mockStallContract),
            abi.encodeCall(
                MockCareLinkStallsForCCNDay.DeleteStallsByCCNDay,
                (1)
            )
        );

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(1);

        assertFalse(ccnDayContract.DoesCCNDayExist(1));
        assertEq(ccnDayContract.GetCurrentCCNDayID(), 0);
        assertFalse(ccnDayContract.IsCurrentCCNDayActive());

        assertEq(mockStallContract.deleteCallCount(), 1);

        assertEq(mockStallContract.lastDeletedCCNDayID(), 1);

        /*
         * Eligible school mappings should also be cleared.
         */
        assertFalse(ccnDayContract.CCNEligibleSchools(1, School.IIT));
    }

    function test_DeleteCCNDayRevertsForNonOrganiser() public {
        _createDefaultCCNDay();

        vm.expectRevert(NotOrganiser.selector);

        vm.prank(nonOrganiser);

        ccnDayContract.DeleteCCNDay(1);
    }

    function test_DeleteCCNDayRevertsForZeroID() public {
        vm.expectRevert(InvalidCCNDayID.selector);

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(0);
    }

    function test_DeleteCCNDayRevertsForUnknownID() public {
        vm.expectRevert(CCNDayDoesNotExist.selector);

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(999);
    }

    function test_DeleteCCNDayRevertsForNonCurrentCCNDay() public {
        _createDefaultCCNDay();
        _createSecondCCNDay();

        vm.expectRevert(CanOnlyDeleteCurrentCCNDay.selector);

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(1);
    }

    function test_DeleteCCNDayRevertsWhenStallContractNotSet() public {
        _createDefaultCCNDay();

        vm.expectRevert(InvalidWallet.selector);

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(1);

        /*
         * The whole transaction should roll back.
         *
         * Even though ClearEligibleSchools runs before the error,
         * the revert restores all previous state.
         */
        assertTrue(ccnDayContract.DoesCCNDayExist(1));
        assertEq(ccnDayContract.GetCurrentCCNDayID(), 1);

        assertTrue(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.IIT));

        School[] memory schools = ccnDayContract.GetCCNDayEligibleSchools(1);

        assertEq(schools.length, 3);
    }

    function test_DeleteCCNDayRollsBackWhenStallDeletionFails() public {
        _createDefaultCCNDay();

        mockStallContract.SetShouldRevert(true);

        vm.prank(organiser);

        ccnDayContract.SetStallContractAddress(address(mockStallContract));

        vm.expectRevert(
            MockCareLinkStallsForCCNDay.MockDeleteStallsFailed.selector
        );

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(1);

        // CCN Day still exists.
        assertTrue(ccnDayContract.DoesCCNDayExist(1));

        // It is still the current CCN Day.
        assertEq(ccnDayContract.GetCurrentCCNDayID(), 1);

        // Eligible schools are restored because the
        // entire transaction reverted.
        assertTrue(ccnDayContract.IsSchoolEligibleForCCNDay(1, School.IIT));

        School[] memory schools = ccnDayContract.GetCCNDayEligibleSchools(1);

        assertEq(schools.length, 3);

        // Mock state also rolled back.
        assertEq(mockStallContract.deleteCallCount(), 0);
    }

    function test_GetAllCCNDaysSkipsDeletedDays() public {
        _createDefaultCCNDay();

        vm.prank(organiser);

        ccnDayContract.SetStallContractAddress(address(mockStallContract));

        vm.prank(organiser);

        ccnDayContract.DeleteCCNDay(1);

        /*
         * The next ID should be 2 because LastCCNDayID is not reset.
         */
        School[] memory newSchools = _editedSchools();

        _createCustomCCNDay(
            "Replacement CCN Day",
            "Created after deleting CCN Day 1",
            BASE_TIME + 4 days,
            BASE_TIME + 5 days,
            BASE_TIME + 2 days,
            BASE_TIME + 3 days,
            newSchools
        );

        CCNDay[] memory allCCNDays = ccnDayContract.GetAllCCNDays();

        assertEq(allCCNDays.length, 1);
        assertEq(allCCNDays[0].CCNDayID, 2);

        assertEq(allCCNDays[0].CCNName, "Replacement CCN Day");

        assertFalse(ccnDayContract.DoesCCNDayExist(1));
        assertTrue(ccnDayContract.DoesCCNDayExist(2));
    }
}
