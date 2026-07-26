// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CareLinkUsers} from "../../src/carelink/CareLinkUsers.sol";
import {CareLinkCCNDay} from "../../src/carelink/CareLinkCCNDay.sol";
import {CareLinkStalls} from "../../src/carelink/CareLinkStalls.sol";

import {CareLinkPayments, AggregatorV3Interface} from "../../src/carelink/CareLinkPayments.sol";

import "../../src/carelink/CareLinkTypes.sol";

// ===============================================================
// MOCK CHAINLINK ETH/USD PRICE FEED
// ===============================================================

/*
 * CareLinkPayments normally reads ETH/USD from Chainlink.
 *
 * During unit testing, we should not depend on Sepolia, RPC
 * connections or real oracle updates. This mock allows each test
 * to control:
 *
 * - The ETH/USD price
 * - The oracle update timestamp
 * - The oracle decimal count
 */
contract MockETHUSDPriceFeed is AggregatorV3Interface {
    uint8 internal feedDecimals;
    int256 internal currentAnswer;
    uint256 internal currentUpdatedAt;

    constructor(uint8 _decimals, int256 _answer, uint256 _updatedAt) {
        feedDecimals = _decimals;
        currentAnswer = _answer;
        currentUpdatedAt = _updatedAt;
    }

    function SetRoundData(int256 _answer, uint256 _updatedAt) external {
        currentAnswer = _answer;
        currentUpdatedAt = _updatedAt;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, currentAnswer, currentUpdatedAt, currentUpdatedAt, 1);
    }
}

// ===============================================================
// REJECTING ETH RECEIVER
// ===============================================================

/*
 * This contract rejects all incoming ETH.
 *
 * It allows us to test the TransferFailed error during:
 *
 * - RefundPayment()
 * - WithdrawStallPayments()
 */
contract RejectEtherReceiver {
    receive() external payable {
        revert("ETH rejected");
    }
}

// ===============================================================
// PAYMENT TEST HARNESS
// ===============================================================

/*
 * Payments and Withdrawals are public mappings, but Solidity's
 * generated mapping getters return large tuples.
 *
 * This test harness inherits CareLinkPayments and exposes each
 * record as its original struct, making the assertions clearer.
 *
 * It does not modify the production payment logic.
 */
contract CareLinkPaymentsHarness is CareLinkPayments {
    constructor(
        address _organiserWallet,
        address _userContractAddress,
        address _ccnDayContractAddress,
        address _stallContractAddress,
        address _ethUsdPriceFeedAddress
    )
        CareLinkPayments(
            _organiserWallet,
            _userContractAddress,
            _ccnDayContractAddress,
            _stallContractAddress,
            _ethUsdPriceFeedAddress
        )
    {}

    function GetPaymentStruct(
        uint256 _paymentId
    ) external view returns (Payment memory) {
        return Payments[_paymentId];
    }

    function GetWithdrawalStruct(
        uint256 _withdrawalId
    ) external view returns (Withdrawal memory) {
        return Withdrawals[_withdrawalId];
    }
}

// ===============================================================
// MAIN TEST CONTRACT
// ===============================================================

contract CareLinkPaymentsTest is Test {
    CareLinkUsers internal usersContract;
    CareLinkCCNDay internal ccnDayContract;
    CareLinkStalls internal stallsContract;
    CareLinkPaymentsHarness internal paymentsContract;
    MockETHUSDPriceFeed internal priceFeed;

    address internal organiser;
    address internal stallOwner;
    address internal secondStallOwner;
    address internal customer;
    address internal secondCustomer;
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

    int256 internal constant ETH_USD_PRICE = 3000e8;

    uint256 internal constant DIRECT_PAYMENT_AMOUNT = 1 ether;
    uint256 internal constant PRODUCT_PRICE_SGD_CENTS = 500;

    // These declarations allow vm.expectEmit() to compare events.
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

    function setUp() public {
        vm.warp(BASE_TIME);

        /*
         * CareLinkUsers sets its deployer as the organiser.
         *
         * Since this test contract deploys CareLinkUsers,
         * address(this) is the organiser.
         */
        organiser = address(this);

        stallOwner = makeAddr("stallOwner");
        secondStallOwner = makeAddr("secondStallOwner");
        customer = makeAddr("customer");
        secondCustomer = makeAddr("secondCustomer");
        unregisteredWallet = makeAddr("unregisteredWallet");
        outsider = makeAddr("outsider");

        vm.deal(organiser, 100 ether);
        vm.deal(stallOwner, 100 ether);
        vm.deal(secondStallOwner, 100 ether);
        vm.deal(customer, 100 ether);
        vm.deal(secondCustomer, 100 ether);
        vm.deal(unregisteredWallet, 100 ether);
        vm.deal(outsider, 100 ether);

        usersContract = new CareLinkUsers();

        ccnDayContract = new CareLinkCCNDay(organiser);

        stallsContract = new CareLinkStalls(
            organiser,
            address(usersContract),
            address(ccnDayContract)
        );

        /*
         * The mock initially returns:
         *
         * ETH/USD = 3000.00000000
         * Updated at BASE_TIME
         */
        priceFeed = new MockETHUSDPriceFeed(8, ETH_USD_PRICE, BASE_TIME);

        paymentsContract = new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed)
        );

        /*
         * Connect the contracts in both directions.
         */
        stallsContract.SetPaymentContractAddress(address(paymentsContract));

        ccnDayContract.SetStallContractAddress(address(stallsContract));

        _createDefaultCCNDay();

        _registerStudent(stallOwner, "Stall Owner", School.IIT);

        _registerStudent(
            secondStallOwner,
            "Second Stall Owner",
            School.Business
        );

        _registerStudent(customer, "Customer", School.IIT);

        _registerStudent(secondCustomer, "Second Customer", School.Business);
    }

    // ===============================================================
    // TEST HELPERS
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
            "CareLink payment testing event",
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
            "Second CareLink payment event",
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

    function _createApprovedStall(address _owner) internal returns (uint256) {
        vm.warp(REGISTRATION_START);

        vm.prank(_owner);

        uint256 stallId = stallsContract.CreateStall(
            "CareLink Test Stall",
            "A stall used for payment unit testing",
            "ipfs://payment-test-stall",
            StallType.FoodAndBeverage,
            false
        );

        stallsContract.ApproveStall(stallId, "IIT Concourse", School.IIT);

        return stallId;
    }

    function _createProduct(
        uint256 _stallId,
        address _owner,
        ProductStatus _status
    ) internal returns (uint256) {
        vm.prank(_owner);

        return
            stallsContract.CreateProduct(
                _stallId,
                "Chicken Rice",
                "Freshly prepared chicken rice",
                "ipfs://chicken-rice",
                PRODUCT_PRICE_SGD_CENTS,
                _status
            );
    }

    function _payDirect(
        uint256 _stallId,
        address _buyer,
        uint256 _amount
    ) internal returns (uint256) {
        vm.prank(_buyer);

        return paymentsContract.PayToStall{value: _amount}(_stallId);
    }

    function _paySGD(
        uint256 _stallId,
        address _buyer,
        uint256 _amountSGDCents
    ) internal returns (uint256 paymentId) {
        uint256 requiredWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            _amountSGDCents
        );

        vm.prank(_buyer);

        paymentId = paymentsContract.PaySGDToStall{value: requiredWei}(
            _stallId,
            _amountSGDCents
        );
    }

    function _payForProduct(
        uint256 _productId,
        address _buyer
    ) internal returns (uint256 paymentId) {
        (, , uint256 requiredWei) = paymentsContract.GetRequiredWeiForProduct(
            _productId
        );

        vm.prank(_buyer);

        paymentId = paymentsContract.PayForProduct{value: requiredWei}(
            _productId
        );
    }

    function _allowWithdrawal(uint256 _stallId) internal {
        vm.warp(CCN_END + 1);

        stallsContract.AllowStallWithdrawal(_stallId);
    }

    // ===============================================================
    // CONSTRUCTOR
    // ===============================================================

    function test_ConstructorStoresAllContractAddresses() public view {
        assertEq(paymentsContract.Organiser(), organiser);

        assertEq(
            address(paymentsContract.userContract()),
            address(usersContract)
        );

        assertEq(
            address(paymentsContract.ccnDayContract()),
            address(ccnDayContract)
        );

        assertEq(
            address(paymentsContract.stallContract()),
            address(stallsContract)
        );

        assertEq(
            address(paymentsContract.ethUsdPriceFeed()),
            address(priceFeed)
        );
    }

    function test_ConstructorRevertsForZeroOrganiser() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            address(0),
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed)
        );
    }

    function test_ConstructorRevertsForZeroUserContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(0),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed)
        );
    }

    function test_ConstructorRevertsForZeroCCNDayContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(0),
            address(stallsContract),
            address(priceFeed)
        );
    }

    function test_ConstructorRevertsForZeroStallContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(0),
            address(priceFeed)
        );
    }

    function test_ConstructorRevertsForZeroOracleAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(0)
        );
    }

    // ===============================================================
    // ORACLE PRICE TESTS
    // ===============================================================

    function test_GetLatestETHUSDPriceReturnsValidPrice() public view {
        assertEq(
            paymentsContract.GetLatestETHUSDPrice(),
            uint256(ETH_USD_PRICE)
        );
    }

    function test_GetLatestETHUSDPriceRevertsForZeroPrice() public {
        priceFeed.SetRoundData(0, BASE_TIME);

        vm.expectRevert(CareLinkPayments.InvalidOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceRevertsForNegativePrice() public {
        priceFeed.SetRoundData(-1, BASE_TIME);

        vm.expectRevert(CareLinkPayments.InvalidOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceRevertsForZeroUpdateTime() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, 0);

        vm.expectRevert(CareLinkPayments.StaleOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceAcceptsExactStaleLimit() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, BASE_TIME - 7 days);

        assertEq(
            paymentsContract.GetLatestETHUSDPrice(),
            uint256(ETH_USD_PRICE)
        );
    }

    function test_GetLatestETHUSDPriceRevertsAfterStaleLimit() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, BASE_TIME - 7 days - 1);

        vm.expectRevert(CareLinkPayments.StaleOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    // ===============================================================
    // SGD TO WEI CONVERSION
    // ===============================================================

    function test_CalculateRequiredWeiUsesExpectedFormula() public view {
        uint256 amountSGDCents = 1000;

        uint256 ethSgdPrice = (uint256(ETH_USD_PRICE) *
            paymentsContract.USD_TO_SGD_RATE_8_DECIMALS()) / 1e8;

        uint256 expectedWei = (amountSGDCents * 1e8 * 1 ether) /
            ethSgdPrice /
            100;

        uint256 actualWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            amountSGDCents
        );

        assertEq(actualWei, expectedWei);
        assertGt(actualWei, 0);
    }

    function test_CalculateRequiredWeiRevertsForZeroSGDCents() public {
        vm.expectRevert(InvalidPaymentAmount.selector);

        paymentsContract.CalculateRequiredWeiFromSGDCents(0);
    }

    function test_HigherSGDAmountRequiresMoreWei() public view {
        uint256 smallerAmount = paymentsContract
            .CalculateRequiredWeiFromSGDCents(500);

        uint256 largerAmount = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000);

        assertGt(largerAmount, smallerAmount);
    }

    function test_HigherETHPriceRequiresLessWei() public {
        uint256 originalRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000);

        priceFeed.SetRoundData(4000e8, BASE_TIME);

        uint256 newRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000);

        assertLt(newRequiredWei, originalRequiredWei);
    }

    function testFuzz_CalculateRequiredWeiForPositiveSGDAmount(
        uint96 _amountSGDCents
    ) public view {
        uint256 boundedAmount = bound(
            uint256(_amountSGDCents),
            1,
            1_000_000_000_000
        );

        uint256 requiredWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            boundedAmount
        );

        assertGt(requiredWei, 0);
    }

    // ===============================================================
    // PAYMENT EXISTENCE
    // ===============================================================

    function test_DoesPaymentExistReturnsFalseForZeroAndUnknownID()
        public
        view
    {
        assertFalse(paymentsContract.DoesPaymentExist(0));

        assertFalse(paymentsContract.DoesPaymentExist(999));
    }

    // ===============================================================
    // DIRECT PAYMENT SUCCESS
    // ===============================================================

    function test_PayToStallCreatesPaymentAndStoresInformation() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit PaymentCreated(1, stallId, customer, DIRECT_PAYMENT_AMOUNT, 0);

        vm.prank(customer);

        uint256 paymentId = paymentsContract.PayToStall{
            value: DIRECT_PAYMENT_AMOUNT
        }(stallId);

        assertEq(paymentId, 1);

        assertTrue(paymentsContract.DoesPaymentExist(paymentId));

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.PaymentID, paymentId);
        assertEq(payment.StallID, stallId);
        assertEq(payment.CCNDayID, 1);
        assertEq(payment.CustomerWallet, customer);
        assertEq(payment.StallOwnerWallet, stallOwner);

        assertEq(payment.AmountPaid, DIRECT_PAYMENT_AMOUNT);

        assertEq(payment.AmountPaidSGDCents, 0);
        assertEq(payment.PaidAt, CCN_START);
        assertEq(payment.RefundedAt, 0);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));

        assertEq(address(paymentsContract).balance, DIRECT_PAYMENT_AMOUNT);
    }

    function test_PaymentSucceedsAtExactCCNStartBoundary() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        assertTrue(paymentsContract.DoesPaymentExist(paymentId));
    }

    function test_PaymentSucceedsAtExactCCNEndBoundary() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_END);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        assertTrue(paymentsContract.DoesPaymentExist(paymentId));
    }

    function test_MultiplePaymentsReceiveSequentialIDs() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 firstPaymentId = _payDirect(stallId, customer, 1 ether);

        uint256 secondPaymentId = _payDirect(stallId, secondCustomer, 2 ether);

        assertEq(firstPaymentId, 1);
        assertEq(secondPaymentId, 2);

        uint256[] memory paymentIds = paymentsContract.GetStallPaymentIDs(
            stallId
        );

        assertEq(paymentIds.length, 2);
        assertEq(paymentIds[0], firstPaymentId);
        assertEq(paymentIds[1], secondPaymentId);
    }

    // ===============================================================
    // PAYMENT TIME AND STALL VALIDATION
    // ===============================================================

    function test_PayToStallRevertsBeforeCCNDayStarts() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.expectRevert(CareLinkPayments.CCNDayPaymentNotStarted.selector);

        vm.prank(customer);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    function test_PayToStallRevertsAfterCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_END + 1);

        vm.expectRevert(CareLinkPayments.CCNDayPaymentEnded.selector);

        vm.prank(customer);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    function test_PayToStallRevertsForUnknownStall() public {
        vm.warp(CCN_START);

        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(customer);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(999);
    }

    function test_PayToStallRevertsWhenStallIsClosed() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.prank(stallOwner);

        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);

        vm.warp(CCN_START);

        vm.expectRevert(StallNotOpenForPayment.selector);

        vm.prank(customer);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    function test_PayToStallRevertsForOldCCNDayStall() public {
        uint256 oldStallId = _createApprovedStall(stallOwner);

        _createSecondCCNDay();

        vm.warp(SECOND_CCN_START);

        vm.expectRevert(StallNotFromCurrentCCNDay.selector);

        vm.prank(customer);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(oldStallId);
    }

    // ===============================================================
    // PAYMENT CALLER VALIDATION
    // ===============================================================

    function test_PayToStallRevertsForOrganiser() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectRevert(OrganiserCannotPay.selector);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    function test_PayToStallRevertsForUnregisteredWallet() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredWallet);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    function test_PayToStallRevertsForZeroETH() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectRevert(InvalidPaymentAmount.selector);

        vm.prank(customer);

        paymentsContract.PayToStall(stallId);
    }

    function test_PayToStallRevertsWhenOwnerPaysOwnStall() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectRevert(CannotPayOwnStall.selector);

        vm.prank(stallOwner);

        paymentsContract.PayToStall{value: DIRECT_PAYMENT_AMOUNT}(stallId);
    }

    // ===============================================================
    // SGD PAYMENT
    // ===============================================================

    function test_PaySGDToStallStoresSGDCentsAndExactWei() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 amountSGDCents = 1250;

        uint256 requiredWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            amountSGDCents
        );

        uint256 paymentId = _paySGD(stallId, customer, amountSGDCents);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.StallID, stallId);
        assertEq(payment.CustomerWallet, customer);
        assertEq(payment.AmountPaid, requiredWei);

        assertEq(payment.AmountPaidSGDCents, amountSGDCents);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));
    }

    function test_PaySGDToStallRevertsForIncorrectWei() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 amountSGDCents = 1000;

        uint256 requiredWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            amountSGDCents
        );

        uint256 sentWei = requiredWei + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CareLinkPayments.IncorrectPaymentAmount.selector,
                requiredWei,
                sentWei
            )
        );

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: sentWei}(stallId, amountSGDCents);
    }

    function test_PaySGDToStallRevertsForZeroSGDAmount() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.expectRevert(InvalidPaymentAmount.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall(stallId, 0);
    }

    // ===============================================================
    // PRODUCT PAYMENT DETAILS
    // ===============================================================

    function test_GetRequiredWeiForAvailableProduct() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        uint256 productId = _createProduct(
            stallId,
            stallOwner,
            ProductStatus.Available
        );

        (
            uint256 returnedStallId,
            uint256 priceSGDCents,
            uint256 requiredWei
        ) = paymentsContract.GetRequiredWeiForProduct(productId);

        assertEq(returnedStallId, stallId);

        assertEq(priceSGDCents, PRODUCT_PRICE_SGD_CENTS);

        assertEq(
            requiredWei,
            paymentsContract.CalculateRequiredWeiFromSGDCents(
                PRODUCT_PRICE_SGD_CENTS
            )
        );
    }

    function test_GetRequiredWeiRevertsForUnavailableProduct() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        uint256 productId = _createProduct(
            stallId,
            stallOwner,
            ProductStatus.Unavailable
        );

        vm.expectRevert(CareLinkPayments.ProductNotAvailable.selector);

        paymentsContract.GetRequiredWeiForProduct(productId);
    }

    function test_GetRequiredWeiRevertsForUnknownProduct() public {
        vm.expectRevert(ProductDoesNotExist.selector);

        paymentsContract.GetRequiredWeiForProduct(999);
    }

    // ===============================================================
    // PAY FOR PRODUCT
    // ===============================================================

    function test_PayForProductCreatesCorrectPayment() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        uint256 productId = _createProduct(
            stallId,
            stallOwner,
            ProductStatus.Available
        );

        vm.warp(CCN_START);

        uint256 expectedWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            PRODUCT_PRICE_SGD_CENTS
        );

        uint256 paymentId = _payForProduct(productId, customer);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.StallID, stallId);
        assertEq(payment.CustomerWallet, customer);
        assertEq(payment.StallOwnerWallet, stallOwner);
        assertEq(payment.AmountPaid, expectedWei);

        assertEq(payment.AmountPaidSGDCents, PRODUCT_PRICE_SGD_CENTS);
    }

    function test_PayForProductRevertsWhenUnavailable() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        uint256 productId = _createProduct(
            stallId,
            stallOwner,
            ProductStatus.Unavailable
        );

        vm.warp(CCN_START);

        vm.expectRevert(CareLinkPayments.ProductNotAvailable.selector);

        vm.prank(customer);

        paymentsContract.PayForProduct(productId);
    }

    function test_PayForProductRevertsForIncorrectWei() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        uint256 productId = _createProduct(
            stallId,
            stallOwner,
            ProductStatus.Available
        );

        vm.warp(CCN_START);

        uint256 requiredWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            PRODUCT_PRICE_SGD_CENTS
        );

        uint256 sentWei = requiredWei + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CareLinkPayments.IncorrectPaymentAmount.selector,
                requiredWei,
                sentWei
            )
        );

        vm.prank(customer);

        paymentsContract.PayForProduct{value: sentWei}(productId);
    }

    function test_PayForProductRevertsForUnknownProduct() public {
        vm.warp(CCN_START);

        vm.expectRevert(ProductDoesNotExist.selector);

        vm.prank(customer);

        paymentsContract.PayForProduct(999);
    }

    // ===============================================================
    // FULL REFUND
    // ===============================================================

    function test_StallOwnerCanFullyRefundPayment() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        uint256 customerBalanceBeforeRefund = customer.balance;

        vm.warp(CCN_START + 1);

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit PaymentRefunded(paymentId, customer, DIRECT_PAYMENT_AMOUNT);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(
            uint256(payment.paymentStatus),
            uint256(PaymentStatus.Refunded)
        );

        assertEq(payment.RefundedAt, CCN_START + 1);

        assertEq(
            customer.balance,
            customerBalanceBeforeRefund + DIRECT_PAYMENT_AMOUNT
        );

        assertEq(address(paymentsContract).balance, 0);

        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));
    }

    function test_RefundRevertsForUnknownPayment() public {
        vm.expectRevert(PaymentDoesNotExist.selector);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(999);
    }

    function test_RefundRevertsForNonPaymentReceiver() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        vm.expectRevert(NotPaymentReceiver.selector);

        vm.prank(outsider);

        paymentsContract.RefundPayment(paymentId);
    }

    function test_PaymentCannotBeRefundedTwice() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        vm.expectRevert(PaymentNotPaid.selector);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);
    }

    function test_RefundTransferFailureRollsBackState() public {
        RejectEtherReceiver rejectingCustomer = new RejectEtherReceiver();

        _registerStudent(
            address(rejectingCustomer),
            "Rejecting Customer",
            School.IIT
        );

        vm.deal(address(rejectingCustomer), 10 ether);

        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        vm.prank(address(rejectingCustomer));

        uint256 paymentId = paymentsContract.PayToStall{
            value: DIRECT_PAYMENT_AMOUNT
        }(stallId);

        vm.expectRevert(TransferFailed.selector);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        /*
         * The failed refund transaction must roll back:
         *
         * - Status remains Paid
         * - RefundedAt remains zero
         * - ETH remains in the payment contract
         */
        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));

        assertEq(payment.RefundedAt, 0);

        assertEq(address(paymentsContract).balance, DIRECT_PAYMENT_AMOUNT);
    }

    // ===============================================================
    // WITHDRAWABLE BALANCE
    // ===============================================================

    function test_GetStallWithdrawableBalanceReturnsPaidTotal() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, 1 ether);

        _payDirect(stallId, secondCustomer, 2 ether);

        vm.prank(stallOwner);

        uint256 ownerView = paymentsContract.GetStallWithdrawableBalance(
            stallId
        );

        uint256 organiserView = paymentsContract.GetStallWithdrawableBalance(
            stallId
        );

        assertEq(ownerView, 3 ether);
        assertEq(organiserView, 3 ether);
    }

    function test_RefundedPaymentsAreExcludedFromWithdrawableBalance() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 refundedPaymentId = _payDirect(stallId, customer, 1 ether);

        _payDirect(stallId, secondCustomer, 2 ether);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(refundedPaymentId);

        vm.prank(stallOwner);

        uint256 withdrawableBalance = paymentsContract
            .GetStallWithdrawableBalance(stallId);

        assertEq(withdrawableBalance, 2 ether);

        assertEq(address(paymentsContract).balance, 2 ether);
    }

    function test_GetStallWithdrawableBalanceRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        paymentsContract.GetStallWithdrawableBalance(999);
    }

    function test_GetStallWithdrawableBalanceRevertsForOutsider() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.expectRevert(NotAllowedToViewStallTransactions.selector);

        vm.prank(outsider);

        paymentsContract.GetStallWithdrawableBalance(stallId);
    }

    function test_GetMyWithdrawableBalanceReturnsZeroWithoutStall() public {
        vm.prank(customer);

        assertEq(paymentsContract.GetMyWithdrawableBalance(), 0);
    }

    function test_GetMyWithdrawableBalanceReturnsPaidAmount() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        vm.prank(stallOwner);

        assertEq(
            paymentsContract.GetMyWithdrawableBalance(),
            DIRECT_PAYMENT_AMOUNT
        );
    }

    // ===============================================================
    // UNSETTLED PAYMENT STATUS
    // ===============================================================

    function test_HasUnsettledPaidPaymentsTracksPaymentLifecycle() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        assertTrue(paymentsContract.HasUnsettledPaidPayments(stallId));

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));
    }

    // ===============================================================
    // WITHDRAW PAYMENTS
    // ===============================================================

    function test_StallOwnerCanWithdrawPayments() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        _allowWithdrawal(stallId);

        uint256 ownerBalanceBefore = stallOwner.balance;

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit WithdrawalCreated(1, stallOwner, DIRECT_PAYMENT_AMOUNT);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(
            uint256(payment.paymentStatus),
            uint256(PaymentStatus.Withdrawn)
        );

        Withdrawal memory withdrawal = paymentsContract.GetWithdrawalStruct(1);

        assertEq(withdrawal.WithdrawalID, 1);
        assertEq(withdrawal.StallID, stallId);
        assertEq(withdrawal.CCNDayID, 1);

        assertEq(withdrawal.StallOwnerWallet, stallOwner);

        assertEq(withdrawal.Amount, DIRECT_PAYMENT_AMOUNT);

        assertEq(withdrawal.WithdrawnAt, CCN_END + 1);

        assertEq(
            stallOwner.balance,
            ownerBalanceBefore + DIRECT_PAYMENT_AMOUNT
        );

        assertEq(address(paymentsContract).balance, 0);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertTrue(stall.WithdrawalCompleted);

        assertFalse(stallsContract.IsWalletApprovedStallOwner(stallOwner));

        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));
    }

    function test_WithdrawalOnlyIncludesStillPaidPayments() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 refundedPaymentId = _payDirect(stallId, customer, 1 ether);

        uint256 paidPaymentId = _payDirect(stallId, secondCustomer, 2 ether);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(refundedPaymentId);

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);

        Payment memory refundedPayment = paymentsContract.GetPaymentStruct(
            refundedPaymentId
        );

        Payment memory withdrawnPayment = paymentsContract.GetPaymentStruct(
            paidPaymentId
        );

        assertEq(
            uint256(refundedPayment.paymentStatus),
            uint256(PaymentStatus.Refunded)
        );

        assertEq(
            uint256(withdrawnPayment.paymentStatus),
            uint256(PaymentStatus.Withdrawn)
        );

        Withdrawal memory withdrawal = paymentsContract.GetWithdrawalStruct(1);

        assertEq(withdrawal.Amount, 2 ether);
    }

    function test_WithdrawRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(999);
    }

    function test_WithdrawRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(secondStallOwner);

        paymentsContract.WithdrawStallPayments(stallId);
    }

    function test_WithdrawRevertsBeforePermissionIsGranted() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        vm.expectRevert(StallNotReadyForWithdrawal.selector);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);
    }

    function test_WithdrawRevertsWhenNoPaymentsExist() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.expectRevert(NoWithdrawablePayments.selector);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);
    }

    function test_WithdrawRevertsWhenOwnerIsNoLongerApproved() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);

        vm.expectRevert(NotApprovedStallOwner.selector);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);
    }

    function test_WithdrawalTransferFailureRollsBackAllContracts() public {
        RejectEtherReceiver rejectingOwner = new RejectEtherReceiver();

        _registerStudent(
            address(rejectingOwner),
            "Rejecting Stall Owner",
            School.IIT
        );

        vm.deal(address(rejectingOwner), 10 ether);

        uint256 stallId = _createApprovedStall(address(rejectingOwner));

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        _allowWithdrawal(stallId);

        vm.expectRevert(TransferFailed.selector);

        vm.prank(address(rejectingOwner));

        paymentsContract.WithdrawStallPayments(stallId);

        /*
         * The failed ETH transfer reverts the complete transaction,
         * including state changes made in CareLinkStalls.
         */
        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));

        Withdrawal memory withdrawal = paymentsContract.GetWithdrawalStruct(1);

        assertEq(withdrawal.WithdrawalID, 0);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertFalse(stall.WithdrawalCompleted);

        assertEq(address(paymentsContract).balance, DIRECT_PAYMENT_AMOUNT);
    }

    // ===============================================================
    // COMPLETE WITHOUT WITHDRAWAL
    // ===============================================================

    function test_OwnerCanCompleteStallWithoutPayments() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit StallCompletedWithoutWithdrawal(stallId, stallOwner);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertTrue(stall.WithdrawalCompleted);
    }

    function test_CompleteWithoutWithdrawalRevertsWhenPaymentsExist() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        _allowWithdrawal(stallId);

        vm.expectRevert(CareLinkPayments.StallHasWithdrawablePayments.selector);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);
    }

    function test_CompleteWithoutWithdrawalSucceedsAfterFullRefund() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertTrue(stall.WithdrawalCompleted);
    }

    function test_CompleteWithoutWithdrawalRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(999);
    }

    function test_CompleteWithoutWithdrawalRevertsForWrongOwner() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.expectRevert(OnlyStallOwner.selector);

        vm.prank(secondStallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);
    }

    function test_CompleteWithoutWithdrawalRevertsBeforePermission() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.expectRevert(StallNotReadyForWithdrawal.selector);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);
    }

    function test_CompleteWithoutWithdrawalRevertsAfterCompletion() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);

        vm.expectRevert(NotApprovedStallOwner.selector);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);
    }

    // ===============================================================
    // STALL PAYMENT IDS
    // ===============================================================

    function test_GetStallPaymentIDsReturnsCorrectIDs() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 firstPaymentId = _payDirect(stallId, customer, 1 ether);

        uint256 secondPaymentId = _payDirect(stallId, secondCustomer, 2 ether);

        uint256[] memory paymentIds = paymentsContract.GetStallPaymentIDs(
            stallId
        );

        assertEq(paymentIds.length, 2);
        assertEq(paymentIds[0], firstPaymentId);
        assertEq(paymentIds[1], secondPaymentId);
    }

    function test_GetStallPaymentIDsRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        paymentsContract.GetStallPaymentIDs(999);
    }

    // ===============================================================
    // CUSTOMER WALLET TRANSACTION HISTORY
    // ===============================================================

    function test_GetMyWalletHistoryReturnsPaidAndRefundEntries() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 amountSGDCents = 500;

        uint256 paymentId = _paySGD(stallId, customer, amountSGDCents);

        Payment memory paymentBeforeRefund = paymentsContract.GetPaymentStruct(
            paymentId
        );

        vm.warp(CCN_START + 1);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        vm.prank(customer);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetMyWalletTransactionHistory();

        assertEq(history.length, 2);

        // Customer paid entry: negative from customer perspective.
        assertEq(history[0].PaymentID, paymentId);
        assertEq(history[0].WithdrawalID, 0);
        assertEq(history[0].StallID, stallId);

        assertEq(history[0].Amount, paymentBeforeRefund.AmountPaid);

        assertEq(
            history[0].SignedAmount,
            -int256(paymentBeforeRefund.AmountPaid)
        );

        assertEq(history[0].AmountSGDCents, amountSGDCents);

        assertEq(history[0].SignedAmountSGDCents, -int256(amountSGDCents));

        assertEq(
            uint256(history[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        // Refund entry: positive from customer perspective.
        assertEq(history[1].PaymentID, paymentId);

        assertEq(
            history[1].SignedAmount,
            int256(paymentBeforeRefund.AmountPaid)
        );

        assertEq(history[1].SignedAmountSGDCents, int256(amountSGDCents));

        assertEq(history[1].TransactionAt, CCN_START + 1);

        assertEq(
            uint256(history[1].transactionType),
            uint256(TransactionHistoryType.RefundedTransaction)
        );
    }

    function test_GetMyWalletHistoryReturnsEmptyForRegisteredUser() public {
        vm.prank(customer);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetMyWalletTransactionHistory();

        assertEq(history.length, 0);
    }

    function test_GetMyWalletHistoryRevertsForUnregisteredWallet() public {
        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredWallet);

        paymentsContract.GetMyWalletTransactionHistory();
    }

    // ===============================================================
    // STALL OWNER TRANSACTION HISTORY
    // ===============================================================

    function test_GetMyStallHistoryUsesOwnerPerspective() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        uint256 paymentId = _payDirect(
            stallId,
            customer,
            DIRECT_PAYMENT_AMOUNT
        );

        vm.warp(CCN_START + 1);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        vm.prank(stallOwner);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetMyStallTransactionHistory();

        assertEq(history.length, 2);

        // Payment received is positive for the stall.
        assertEq(history[0].SignedAmount, int256(DIRECT_PAYMENT_AMOUNT));

        assertEq(
            uint256(history[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        // Refund sent is negative for the stall.
        assertEq(history[1].SignedAmount, -int256(DIRECT_PAYMENT_AMOUNT));

        assertEq(
            uint256(history[1].transactionType),
            uint256(TransactionHistoryType.RefundedTransaction)
        );
    }

    function test_GetMyStallHistoryRevertsWhenWalletHasNoStall() public {
        vm.expectRevert(WalletHasNotCreatedStall.selector);

        vm.prank(customer);

        paymentsContract.GetMyStallTransactionHistory();
    }

    // ===============================================================
    // WITHDRAWAL TRANSACTION HISTORY
    // ===============================================================

    function test_WithdrawalAppearsInWalletAndStallHistories() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);

        paymentsContract.WithdrawStallPayments(stallId);

        /*
         * The stall owner's general wallet history contains the
         * withdrawal as a positive amount because ETH entered
         * the owner's wallet.
         */
        vm.prank(stallOwner);

        TransactionHistoryItem[] memory walletHistory = paymentsContract
            .GetMyWalletTransactionHistory();

        assertEq(walletHistory.length, 1);

        assertEq(walletHistory[0].WithdrawalID, 1);

        assertEq(walletHistory[0].SignedAmount, int256(DIRECT_PAYMENT_AMOUNT));

        assertEq(
            uint256(walletHistory[0].transactionType),
            uint256(TransactionHistoryType.WithdrawalTransaction)
        );

        /*
         * Stall history contains:
         *
         * 1. Payment received: positive
         * 2. Withdrawal from contract: negative
         */
        vm.prank(stallOwner);

        TransactionHistoryItem[] memory stallHistory = paymentsContract
            .GetStallTransactionHistory(stallId);

        assertEq(stallHistory.length, 2);

        assertEq(stallHistory[0].SignedAmount, int256(DIRECT_PAYMENT_AMOUNT));

        assertEq(
            uint256(stallHistory[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        assertEq(stallHistory[1].SignedAmount, -int256(DIRECT_PAYMENT_AMOUNT));

        assertEq(
            uint256(stallHistory[1].transactionType),
            uint256(TransactionHistoryType.WithdrawalTransaction)
        );
    }

    // ===============================================================
    // STALL TRANSACTION HISTORY PERMISSIONS
    // ===============================================================

    function test_OrganiserCanViewAnyStallTransactionHistory() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetStallTransactionHistory(stallId);

        assertEq(history.length, 1);
    }

    function test_StallOwnerCanViewOwnTransactionHistory() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _payDirect(stallId, customer, DIRECT_PAYMENT_AMOUNT);

        vm.prank(stallOwner);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetStallTransactionHistory(stallId);

        assertEq(history.length, 1);
    }

    function test_OutsiderCannotViewStallTransactionHistory() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.expectRevert(NotAllowedToViewStallTransactions.selector);

        vm.prank(outsider);

        paymentsContract.GetStallTransactionHistory(stallId);
    }

    function test_GetStallHistoryRevertsForUnknownStall() public {
        vm.expectRevert(StallDoesNotExist.selector);

        paymentsContract.GetStallTransactionHistory(999);
    }
}
