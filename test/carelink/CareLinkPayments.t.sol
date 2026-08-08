// To test without the test files: forge coverage --exclude-tests
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CareLinkUsers} from "../../src/carelink/CareLinkUsers.sol";
import {CareLinkCCNDay} from "../../src/carelink/CareLinkCCNDay.sol";
import {CareLinkStalls} from "../../src/carelink/CareLinkStalls.sol";

import {CareLinkPayments, AggregatorV3Interface} from "../../src/carelink/CareLinkPayments.sol";

import "../../src/carelink/CareLinkTypes.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

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

    function SetDecimals(uint8 _decimals) external {
        feedDecimals = _decimals;
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
// MOCK PYTH USD/SGD PRICE FEED
// ===============================================================

contract MockPyth {
    PythStructs.Price internal currentPrice;

    uint256 public updateFee;
    uint256 public updateCallCount;
    uint256 public lastUpdateFeePaid;

    bool public shouldRevertOnUpdate;

    error MockPythPriceTooOld();
    error MockPythUpdateFailed();

    constructor(
        int64 _price,
        uint64 _confidence,
        int32 _expo,
        uint256 _publishTime,
        uint256 _updateFee
    ) {
        currentPrice = PythStructs.Price({
            price: _price,
            conf: _confidence,
            expo: _expo,
            publishTime: _publishTime
        });

        updateFee = _updateFee;
    }

    function SetPrice(
        int64 _price,
        uint64 _confidence,
        int32 _expo,
        uint256 _publishTime
    ) external {
        currentPrice = PythStructs.Price({
            price: _price,
            conf: _confidence,
            expo: _expo,
            publishTime: _publishTime
        });
    }

    function SetUpdateFee(uint256 _updateFee) external {
        updateFee = _updateFee;
    }

    function SetShouldRevertOnUpdate(bool _shouldRevert) external {
        shouldRevertOnUpdate = _shouldRevert;
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        if (shouldRevertOnUpdate) {
            revert MockPythUpdateFailed();
        }

        updateCallCount++;
        lastUpdateFeePaid = msg.value;

        /*
         * Simulate a successful fresh Pyth update.
         */
        currentPrice.publishTime = block.timestamp;
    }

    function getPriceNoOlderThan(
        bytes32,
        uint256 _age
    ) external view returns (PythStructs.Price memory) {
        /*
         * Real Pyth rejects prices older than the requested age.
         *
         * We intentionally allow future/zero timestamps through here
         * because CareLinkPayments itself checks those conditions.
         */
        if (
            currentPrice.publishTime != 0 &&
            currentPrice.publishTime <= block.timestamp &&
            block.timestamp - currentPrice.publishTime > _age
        ) {
            revert MockPythPriceTooOld();
        }

        return currentPrice;
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
        address _ethUsdPriceFeedAddress,
        address _pythContractAddress
    )
        CareLinkPayments(
            _organiserWallet,
            _userContractAddress,
            _ccnDayContractAddress,
            _stallContractAddress,
            _ethUsdPriceFeedAddress,
            _pythContractAddress
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

    function ExposedConvertPythPriceTo8Decimals(
        PythStructs.Price memory _price
    ) external pure returns (uint256) {
        return ConvertPythPriceTo8Decimals(_price);
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
    MockPyth internal mockPyth;

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

    int64 internal constant PYTH_USD_SGD_PRICE = 125000;
    int32 internal constant PYTH_USD_SGD_EXPO = -5;
    uint64 internal constant PYTH_CONFIDENCE = 100;

    /*
     * 125000 × 10^-5 = 1.25 SGD/USD
     *
     * Converted into CareLink's 8-decimal format:
     * 1.25 = 125000000
     */
    uint256 internal constant USD_SGD_PRICE_8_DECIMALS = 125000000;

    uint256 internal constant PYTH_UPDATE_FEE = 0.000001 ether;

    uint256 internal constant DEFAULT_PAYMENT_SGD_CENTS = 500;
    uint256 internal constant SECOND_PAYMENT_SGD_CENTS = 1000;

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

        mockPyth = new MockPyth(
            PYTH_USD_SGD_PRICE,
            PYTH_CONFIDENCE,
            PYTH_USD_SGD_EXPO,
            BASE_TIME,
            PYTH_UPDATE_FEE
        );

        paymentsContract = new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed),
            address(mockPyth)
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

    function _validPythUpdate()
        internal
        pure
        returns (bytes[] memory priceUpdate)
    {
        priceUpdate = new bytes[](1);

        /*
         * The mock does not need a real signed Pyth VAA.
         *
         * It only needs non-empty bytes because we're testing
         * CareLink's interaction logic, not Pyth's cryptography.
         */
        priceUpdate[0] = hex"123456";
    }

    function _refreshChainlinkPrice() internal {
        priceFeed.SetRoundData(ETH_USD_PRICE, block.timestamp);
    }

    function _calculateRequiredWei(
        uint256 _amountSGDCents
    ) internal view returns (uint256) {
        return
            paymentsContract.CalculateRequiredWeiFromSGDCents(
                _amountSGDCents,
                USD_SGD_PRICE_8_DECIMALS
            );
    }

    function _paySGD(
        uint256 _stallId,
        address _buyer,
        uint256 _amountSGDCents
    ) internal returns (uint256 paymentId, uint256 requiredWei) {
        _refreshChainlinkPrice();

        requiredWei = _calculateRequiredWei(_amountSGDCents);

        bytes[] memory priceUpdate = _validPythUpdate();

        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;

        vm.prank(_buyer);

        paymentId = paymentsContract.PaySGDToStall{value: totalRequiredWei}(
            _stallId,
            _amountSGDCents,
            priceUpdate
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

        assertEq(address(paymentsContract.pyth()), address(mockPyth));

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
            address(priceFeed),
            address(mockPyth)
        );
    }

    function test_ConstructorRevertsForZeroUserContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(0),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed),
            address(mockPyth)
        );
    }

    function test_ConstructorRevertsForZeroCCNDayContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(0),
            address(stallsContract),
            address(priceFeed),
            address(mockPyth)
        );
    }

    function test_ConstructorRevertsForZeroStallContract() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(0),
            address(priceFeed),
            address(mockPyth)
        );
    }

    function test_ConstructorRevertsForZeroOracleAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(0),
            address(mockPyth)
        );
    }

    function test_ConstructorRevertsForZeroPythAddress() public {
        vm.expectRevert(InvalidWallet.selector);

        new CareLinkPaymentsHarness(
            organiser,
            address(usersContract),
            address(ccnDayContract),
            address(stallsContract),
            address(priceFeed),
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

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceRevertsForNegativePrice() public {
        priceFeed.SetRoundData(-1, BASE_TIME);

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceRevertsForZeroUpdateTime() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, 0);

        vm.expectRevert(StaleOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceAcceptsExactStaleLimit() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, BASE_TIME - 2 hours);

        assertEq(
            paymentsContract.GetLatestETHUSDPrice(),
            uint256(ETH_USD_PRICE)
        );
    }

    function test_GetLatestETHUSDPriceRevertsAfterStaleLimit() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, BASE_TIME - 2 hours - 1);

        vm.expectRevert(StaleOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    function test_GetLatestETHUSDPriceRevertsForFutureTimestamp() public {
        priceFeed.SetRoundData(ETH_USD_PRICE, BASE_TIME + 1);

        vm.expectRevert(StaleOraclePrice.selector);

        paymentsContract.GetLatestETHUSDPrice();
    }

    // ===============================================================
    // PYTH USD/SGD ORACLE TESTS
    // ===============================================================

    function test_GetLatestUSDSGDPriceReturnsValidPrice() public view {
        assertEq(
            paymentsContract.GetLatestUSDSGDPrice8Decimals(),
            USD_SGD_PRICE_8_DECIMALS
        );
    }

    function test_GetPythUpdateFeeReturnsExpectedFee() public view {
        bytes[] memory priceUpdate = _validPythUpdate();

        assertEq(
            paymentsContract.GetPythUpdateFee(priceUpdate),
            PYTH_UPDATE_FEE
        );
    }

    function test_GetLatestUSDSGDPriceRevertsForZeroPrice() public {
        mockPyth.SetPrice(0, PYTH_CONFIDENCE, PYTH_USD_SGD_EXPO, BASE_TIME);

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.GetLatestUSDSGDPrice8Decimals();
    }

    function test_GetLatestUSDSGDPriceRevertsForNegativePrice() public {
        mockPyth.SetPrice(-1, PYTH_CONFIDENCE, PYTH_USD_SGD_EXPO, BASE_TIME);

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.GetLatestUSDSGDPrice8Decimals();
    }

    function test_GetLatestUSDSGDPriceRevertsForZeroPublishTime() public {
        mockPyth.SetPrice(
            PYTH_USD_SGD_PRICE,
            PYTH_CONFIDENCE,
            PYTH_USD_SGD_EXPO,
            0
        );

        vm.expectRevert(StaleOraclePrice.selector);

        paymentsContract.GetLatestUSDSGDPrice8Decimals();
    }

    function test_GetLatestUSDSGDPriceRevertsForFuturePublishTime() public {
        mockPyth.SetPrice(
            PYTH_USD_SGD_PRICE,
            PYTH_CONFIDENCE,
            PYTH_USD_SGD_EXPO,
            BASE_TIME + 1
        );

        vm.expectRevert(StaleOraclePrice.selector);

        paymentsContract.GetLatestUSDSGDPrice8Decimals();
    }

    function test_GetLatestUSDSGDPriceRejectsPriceOlderThan4Days() public {
        mockPyth.SetPrice(
            PYTH_USD_SGD_PRICE,
            PYTH_CONFIDENCE,
            PYTH_USD_SGD_EXPO,
            BASE_TIME - 4 days - 1
        );

        vm.expectRevert(MockPyth.MockPythPriceTooOld.selector);

        paymentsContract.GetLatestUSDSGDPrice8Decimals();
    }

    function test_GetLatestUSDSGDPriceAcceptsExactFourDayLimit() public {
        mockPyth.SetPrice(
            PYTH_USD_SGD_PRICE,
            PYTH_CONFIDENCE,
            PYTH_USD_SGD_EXPO,
            BASE_TIME - 4 days
        );

        assertEq(
            paymentsContract.GetLatestUSDSGDPrice8Decimals(),
            USD_SGD_PRICE_8_DECIMALS
        );
    }

    function test_ConvertPythPriceWithMinus5Exponent() public view {
        PythStructs.Price memory price = PythStructs.Price({
            price: 127885,
            conf: 100,
            expo: -5,
            publishTime: BASE_TIME
        });

        uint256 converted = paymentsContract.ExposedConvertPythPriceTo8Decimals(
            price
        );

        /*
         * 127885 × 10^-5 = 1.27885
         *
         * 8 decimals:
         * 1.27885000 = 127885000
         */
        assertEq(converted, 127885000);
    }

    function test_ConvertPythPriceAlreadyAt8Decimals() public view {
        PythStructs.Price memory price = PythStructs.Price({
            price: 127885000,
            conf: 100,
            expo: -8,
            publishTime: BASE_TIME
        });

        assertEq(
            paymentsContract.ExposedConvertPythPriceTo8Decimals(price),
            127885000
        );
    }

    function test_ConvertPythPriceWithMoreThan8Decimals() public view {
        PythStructs.Price memory price = PythStructs.Price({
            price: 12788500000,
            conf: 100,
            expo: -10,
            publishTime: BASE_TIME
        });

        assertEq(
            paymentsContract.ExposedConvertPythPriceTo8Decimals(price),
            127885000
        );
    }

    function test_ConvertPythPriceWithZeroExponent() public view {
        PythStructs.Price memory price = PythStructs.Price({
            price: 2,
            conf: 100,
            expo: 0,
            publishTime: BASE_TIME
        });

        assertEq(
            paymentsContract.ExposedConvertPythPriceTo8Decimals(price),
            200000000
        );
    }

    function test_ConvertPythPriceRejectsExponentAbove18() public {
        PythStructs.Price memory price = PythStructs.Price({
            price: 1,
            conf: 100,
            expo: 19,
            publishTime: BASE_TIME
        });

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.ExposedConvertPythPriceTo8Decimals(price);
    }

    function test_ConvertPythPriceRejectsExponentBelowMinus18() public {
        PythStructs.Price memory price = PythStructs.Price({
            price: 1,
            conf: 100,
            expo: -19,
            publishTime: BASE_TIME
        });

        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.ExposedConvertPythPriceTo8Decimals(price);
    }

    // ===============================================================
    // SGD TO WEI CONVERSION
    // ===============================================================

    function test_CalculateRequiredWeiReturnsExpectedKnownConversion()
        public
        view
    {
        /*
         * ETH/USD = 3000
         * USD/SGD = 1.25
         *
         * Therefore:
         * 1 ETH = 3750 SGD
         *
         * 1500 cents = 15 SGD
         *
         * 15 / 3750 = 0.004 ETH
         *            = 4,000,000,000,000,000 Wei
         */
        uint256 actualWei = paymentsContract.CalculateRequiredWeiFromSGDCents(
            1500,
            USD_SGD_PRICE_8_DECIMALS
        );

        assertEq(actualWei, 4_000_000_000_000_000);
    }

    function test_CalculateRequiredWeiRevertsForZeroSGDCents() public {
        vm.expectRevert(InvalidPaymentAmount.selector);

        paymentsContract.CalculateRequiredWeiFromSGDCents(
            0,
            USD_SGD_PRICE_8_DECIMALS
        );
    }

    function test_CalculateRequiredWeiRevertsForZeroUSDSGDPrice() public {
        vm.expectRevert(InvalidOraclePrice.selector);

        paymentsContract.CalculateRequiredWeiFromSGDCents(500, 0);
    }

    function test_CalculateRequiredWeiRevertsForUnsupportedChainlinkDecimals()
        public
    {
        priceFeed.SetDecimals(19);

        vm.expectRevert(
            abi.encodeWithSelector(UnsupportedOracleDecimals.selector, 19)
        );

        paymentsContract.CalculateRequiredWeiFromSGDCents(
            500,
            USD_SGD_PRICE_8_DECIMALS
        );
    }

    function test_HigherUSDSGDRateRequiresLessWei() public view {
        uint256 lowerRateRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000, 120000000);

        uint256 higherRateRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000, 140000000);

        assertLt(higherRateRequiredWei, lowerRateRequiredWei);
    }

    function test_HigherSGDAmountRequiresMoreWei() public view {
        uint256 smallerAmount = paymentsContract
            .CalculateRequiredWeiFromSGDCents(500, USD_SGD_PRICE_8_DECIMALS);

        uint256 largerAmount = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000, USD_SGD_PRICE_8_DECIMALS);

        assertGt(largerAmount, smallerAmount);
    }

    function test_HigherETHPriceRequiresLessWei() public {
        uint256 originalRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000, USD_SGD_PRICE_8_DECIMALS);

        priceFeed.SetRoundData(4000e8, BASE_TIME);

        uint256 newRequiredWei = paymentsContract
            .CalculateRequiredWeiFromSGDCents(1000, USD_SGD_PRICE_8_DECIMALS);

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
            boundedAmount,
            USD_SGD_PRICE_8_DECIMALS
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
    // SGD PAYMENT SUCCESS AND PYTH UPDATE
    // ===============================================================

    function test_PaySGDToStallCreatesCompletePayment() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();

        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit PaymentCreated(
            1,
            stallId,
            customer,
            requiredWei,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        vm.prank(customer);

        uint256 paymentId = paymentsContract.PaySGDToStall{
            value: totalRequiredWei
        }(stallId, DEFAULT_PAYMENT_SGD_CENTS, priceUpdate);

        assertEq(paymentId, 1);
        assertTrue(paymentsContract.DoesPaymentExist(paymentId));

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.PaymentID, 1);
        assertEq(payment.StallID, stallId);
        assertEq(payment.CCNDayID, 1);

        assertEq(payment.CustomerWallet, customer);

        assertEq(payment.StallOwnerWallet, stallOwner);

        assertEq(payment.AmountPaid, requiredWei);

        assertEq(payment.AmountPaidSGDCents, DEFAULT_PAYMENT_SGD_CENTS);

        assertEq(payment.PaidAt, CCN_START);
        assertEq(payment.RefundedAt, 0);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));

        /*
         * Pyth received its own fee.
         */
        assertEq(mockPyth.lastUpdateFeePaid(), PYTH_UPDATE_FEE);

        assertEq(mockPyth.updateCallCount(), 1);

        /*
         * CRITICAL ACCOUNTING TEST:
         *
         * CareLink retains ONLY stall payment.
         * Pyth fee must not enter AmountPaid.
         */
        assertEq(address(paymentsContract).balance, requiredWei);

        assertEq(address(mockPyth).balance, PYTH_UPDATE_FEE);
    }

    function test_PaySGDToStallRevertsForEmptyPythUpdate() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        bytes[] memory emptyUpdate = new bytes[](0);

        vm.expectRevert(InvalidOraclePrice.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            emptyUpdate
        );
    }

    function test_PaySGDToStallRevertsWhenValueDoesNotExceedPythFee() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(InvalidPaymentAmount.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: PYTH_UPDATE_FEE}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsWhenPythUpdateFails() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        mockPyth.SetShouldRevertOnUpdate(true);

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(MockPyth.MockPythUpdateFailed.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: requiredWei + PYTH_UPDATE_FEE}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );

        assertFalse(paymentsContract.DoesPaymentExist(1));

        assertEq(mockPyth.updateCallCount(), 0);
    }

    // ===============================================================
    // PAYMENT TIME AND STALL VALIDATION
    // ===============================================================

    function test_PaySGDToStallRevertsBeforeCCNDayStarts() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(CCNDayPaymentNotStarted.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsAfterCCNDayEnds() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_END + 1);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(CCNDayPaymentEnded.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsForUnknownStall() public {
        vm.warp(CCN_START);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(StallDoesNotExist.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            999,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsWhenStallIsClosed() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.prank(stallOwner);
        stallsContract.UpdateMyStallOpenStatus(stallId, StallStatus.Closed);

        vm.warp(CCN_START);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(StallNotOpenForPayment.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsForOldCCNDayStall() public {
        uint256 oldStallId = _createApprovedStall(stallOwner);

        _createSecondCCNDay();

        vm.warp(SECOND_CCN_START);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(StallNotFromCurrentCCNDay.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: 1 ether}(
            oldStallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );
    }

    // ===============================================================
    // PAYMENT BOUNDARY SUCCESS
    // ===============================================================

    function test_PaymentSucceedsAtExactCCNStartBoundary() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        assertTrue(paymentsContract.DoesPaymentExist(paymentId));

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.PaidAt, CCN_START);
        assertEq(payment.AmountPaid, amountPaidWei);
        assertEq(payment.AmountPaidSGDCents, DEFAULT_PAYMENT_SGD_CENTS);
    }

    function test_PaymentSucceedsAtExactCCNEndBoundary() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_END);

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        assertTrue(paymentsContract.DoesPaymentExist(paymentId));

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(payment.PaidAt, CCN_END);
        assertEq(payment.AmountPaid, amountPaidWei);
    }

    function test_MultiplePaymentsReceiveSequentialIDs() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 firstPaymentId, uint256 firstAmountWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        (uint256 secondPaymentId, uint256 secondAmountWei) = _paySGD(
            stallId,
            secondCustomer,
            SECOND_PAYMENT_SGD_CENTS
        );

        assertEq(firstPaymentId, 1);
        assertEq(secondPaymentId, 2);

        uint256[] memory paymentIds = paymentsContract.GetStallPaymentIDs(
            stallId
        );

        assertEq(paymentIds.length, 2);
        assertEq(paymentIds[0], firstPaymentId);
        assertEq(paymentIds[1], secondPaymentId);

        assertEq(
            address(paymentsContract).balance,
            firstAmountWei + secondAmountWei
        );

        assertEq(address(mockPyth).balance, PYTH_UPDATE_FEE * 2);
    }

    // ===============================================================
    // PAYMENT CALLER VALIDATION
    // ===============================================================

    function test_PaySGDToStallRevertsForOrganiser() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();
        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;

        vm.expectRevert(OrganiserCannotPay.selector);

        paymentsContract.PaySGDToStall{value: totalRequiredWei}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );

        // The later revert rolls the Pyth update back too.
        assertEq(mockPyth.updateCallCount(), 0);
        assertEq(address(mockPyth).balance, 0);
    }

    function test_PaySGDToStallRevertsForUnregisteredWallet() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();
        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;

        vm.expectRevert(WalletNotRegistered.selector);

        vm.prank(unregisteredWallet);

        paymentsContract.PaySGDToStall{value: totalRequiredWei}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );

        assertEq(mockPyth.updateCallCount(), 0);
        assertEq(address(mockPyth).balance, 0);
    }

    function test_PaySGDToStallRevertsWhenOwnerPaysOwnStall() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();
        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;

        vm.expectRevert(CannotPayOwnStall.selector);

        vm.prank(stallOwner);

        paymentsContract.PaySGDToStall{value: totalRequiredWei}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );

        assertEq(mockPyth.updateCallCount(), 0);
        assertEq(address(mockPyth).balance, 0);
    }

    function test_PaySGDToStallRevertsForZeroSGDAmount() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        bytes[] memory priceUpdate = _validPythUpdate();

        vm.expectRevert(InvalidPaymentAmount.selector);

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: PYTH_UPDATE_FEE + 1}(
            stallId,
            0,
            priceUpdate
        );
    }

    function test_PaySGDToStallRevertsForIncorrectWei() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _refreshChainlinkPrice();

        uint256 requiredWei = _calculateRequiredWei(DEFAULT_PAYMENT_SGD_CENTS);

        bytes[] memory priceUpdate = _validPythUpdate();
        uint256 totalRequiredWei = requiredWei + PYTH_UPDATE_FEE;
        uint256 sentWei = totalRequiredWei + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IncorrectPaymentAmount.selector,
                totalRequiredWei,
                sentWei
            )
        );

        vm.prank(customer);

        paymentsContract.PaySGDToStall{value: sentWei}(
            stallId,
            DEFAULT_PAYMENT_SGD_CENTS,
            priceUpdate
        );

        // Pyth update happened before exact-value checking, but rollback is atomic.
        assertEq(mockPyth.updateCallCount(), 0);
        assertEq(address(mockPyth).balance, 0);
    }

    // ===============================================================
    // FULL REFUND
    // ===============================================================

    function test_StallOwnerCanFullyRefundPayment() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        uint256 customerBalanceBeforeRefund = customer.balance;

        vm.warp(CCN_START + 1);

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit PaymentRefunded(paymentId, customer, amountPaidWei);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(
            uint256(payment.paymentStatus),
            uint256(PaymentStatus.Refunded)
        );
        assertEq(payment.RefundedAt, CCN_START + 1);
        assertEq(payment.AmountPaid, amountPaidWei);
        assertEq(payment.AmountPaidSGDCents, DEFAULT_PAYMENT_SGD_CENTS);

        // Only the actual stall payment is refunded; Pyth keeps its fee.
        assertEq(customer.balance, customerBalanceBeforeRefund + amountPaidWei);
        assertEq(address(paymentsContract).balance, 0);
        assertEq(address(mockPyth).balance, PYTH_UPDATE_FEE);

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

        (uint256 paymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        vm.expectRevert(NotPaymentReceiver.selector);

        vm.prank(outsider);

        paymentsContract.RefundPayment(paymentId);
    }

    function test_PaymentCannotBeRefundedTwice() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 paymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
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

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            address(rejectingCustomer),
            DEFAULT_PAYMENT_SGD_CENTS
        );

        vm.expectRevert(TransferFailed.selector);

        vm.prank(stallOwner);

        paymentsContract.RefundPayment(paymentId);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));
        assertEq(payment.RefundedAt, 0);
        assertEq(address(paymentsContract).balance, amountPaidWei);
    }

    // ===============================================================
    // WITHDRAWABLE BALANCE
    // ===============================================================

    function test_GetStallWithdrawableBalanceReturnsPaidTotal() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (, uint256 firstAmountWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        (, uint256 secondAmountWei) = _paySGD(
            stallId,
            secondCustomer,
            SECOND_PAYMENT_SGD_CENTS
        );

        vm.prank(stallOwner);

        uint256 ownerView = paymentsContract.GetStallWithdrawableBalance(
            stallId
        );

        uint256 organiserView = paymentsContract.GetStallWithdrawableBalance(
            stallId
        );

        uint256 expectedTotal = firstAmountWei + secondAmountWei;

        assertEq(ownerView, expectedTotal);
        assertEq(organiserView, expectedTotal);
    }

    function test_RefundedPaymentsAreExcludedFromWithdrawableBalance() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 refundedPaymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        (, uint256 paidAmountWei) = _paySGD(
            stallId,
            secondCustomer,
            SECOND_PAYMENT_SGD_CENTS
        );

        vm.prank(stallOwner);
        paymentsContract.RefundPayment(refundedPaymentId);

        vm.prank(stallOwner);

        uint256 withdrawableBalance = paymentsContract
            .GetStallWithdrawableBalance(stallId);

        assertEq(withdrawableBalance, paidAmountWei);
        assertEq(address(paymentsContract).balance, paidAmountWei);
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

        (, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        vm.prank(stallOwner);

        assertEq(paymentsContract.GetMyWithdrawableBalance(), amountPaidWei);
    }

    // ===============================================================
    // UNSETTLED PAYMENT STATUS
    // ===============================================================

    function test_HasUnsettledPaidPaymentsTracksPaymentLifecycle() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));

        vm.warp(CCN_START);

        (uint256 paymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
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

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        _allowWithdrawal(stallId);

        uint256 ownerBalanceBefore = stallOwner.balance;

        vm.expectEmit(true, true, false, true, address(paymentsContract));

        emit WithdrawalCreated(1, stallOwner, amountPaidWei);

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
        assertEq(withdrawal.Amount, amountPaidWei);
        assertEq(withdrawal.WithdrawnAt, CCN_END + 1);

        assertEq(stallOwner.balance, ownerBalanceBefore + amountPaidWei);

        // Pyth fee is never withdrawable by the stall owner.
        assertEq(address(paymentsContract).balance, 0);
        assertEq(address(mockPyth).balance, PYTH_UPDATE_FEE);

        Stall memory stall = stallsContract.GetStallDetails(stallId);

        assertTrue(stall.WithdrawalCompleted);
        assertFalse(stallsContract.IsWalletApprovedStallOwner(stallOwner));
        assertFalse(paymentsContract.HasUnsettledPaidPayments(stallId));
    }

    function test_WithdrawalOnlyIncludesStillPaidPayments() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 refundedPaymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        (uint256 paidPaymentId, uint256 paidAmountWei) = _paySGD(
            stallId,
            secondCustomer,
            SECOND_PAYMENT_SGD_CENTS
        );

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

        assertEq(withdrawal.Amount, paidAmountWei);
        assertEq(address(mockPyth).balance, PYTH_UPDATE_FEE * 2);
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

        _paySGD(stallId, customer, DEFAULT_PAYMENT_SGD_CENTS);

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

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        _allowWithdrawal(stallId);

        vm.expectRevert(TransferFailed.selector);

        vm.prank(address(rejectingOwner));

        paymentsContract.WithdrawStallPayments(stallId);

        Payment memory payment = paymentsContract.GetPaymentStruct(paymentId);

        assertEq(uint256(payment.paymentStatus), uint256(PaymentStatus.Paid));

        Withdrawal memory withdrawal = paymentsContract.GetWithdrawalStruct(1);
        assertEq(withdrawal.WithdrawalID, 0);

        Stall memory stall = stallsContract.GetStallDetails(stallId);
        assertFalse(stall.WithdrawalCompleted);

        assertEq(address(paymentsContract).balance, amountPaidWei);
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

        _paySGD(stallId, customer, DEFAULT_PAYMENT_SGD_CENTS);

        _allowWithdrawal(stallId);

        vm.expectRevert(StallHasWithdrawablePayments.selector);

        vm.prank(stallOwner);

        paymentsContract.CompleteStallWithoutWithdrawal(stallId);
    }

    function test_CompleteWithoutWithdrawalSucceedsAfterFullRefund() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        (uint256 paymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
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

        (uint256 firstPaymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        (uint256 secondPaymentId, ) = _paySGD(
            stallId,
            secondCustomer,
            SECOND_PAYMENT_SGD_CENTS
        );

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

        (uint256 paymentId, ) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

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

        // Customer payment: negative.
        assertEq(history[0].PaymentID, paymentId);
        assertEq(history[0].WithdrawalID, 0);
        assertEq(history[0].StallID, stallId);
        assertEq(history[0].CCNDayID, 1);
        assertEq(history[0].CustomerWallet, customer);
        assertEq(history[0].StallOwnerWallet, stallOwner);
        assertEq(history[0].Amount, paymentBeforeRefund.AmountPaid);
        assertEq(
            history[0].SignedAmount,
            -int256(paymentBeforeRefund.AmountPaid)
        );
        assertEq(history[0].AmountSGDCents, DEFAULT_PAYMENT_SGD_CENTS);
        assertEq(
            history[0].SignedAmountSGDCents,
            -int256(DEFAULT_PAYMENT_SGD_CENTS)
        );
        assertEq(history[0].TransactionAt, CCN_START);
        assertEq(
            uint256(history[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        // Customer refund: positive.
        assertEq(history[1].PaymentID, paymentId);
        assertEq(history[1].Amount, paymentBeforeRefund.AmountPaid);
        assertEq(
            history[1].SignedAmount,
            int256(paymentBeforeRefund.AmountPaid)
        );
        assertEq(history[1].AmountSGDCents, DEFAULT_PAYMENT_SGD_CENTS);
        assertEq(
            history[1].SignedAmountSGDCents,
            int256(DEFAULT_PAYMENT_SGD_CENTS)
        );
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

        (uint256 paymentId, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        vm.warp(CCN_START + 1);

        vm.prank(stallOwner);
        paymentsContract.RefundPayment(paymentId);

        vm.prank(stallOwner);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetMyStallTransactionHistory();

        assertEq(history.length, 2);

        // Payment received: positive from stall perspective.
        assertEq(history[0].SignedAmount, int256(amountPaidWei));
        assertEq(
            history[0].SignedAmountSGDCents,
            int256(DEFAULT_PAYMENT_SGD_CENTS)
        );
        assertEq(
            uint256(history[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        // Refund sent: negative from stall perspective.
        assertEq(history[1].SignedAmount, -int256(amountPaidWei));
        assertEq(
            history[1].SignedAmountSGDCents,
            -int256(DEFAULT_PAYMENT_SGD_CENTS)
        );
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

        (, uint256 amountPaidWei) = _paySGD(
            stallId,
            customer,
            DEFAULT_PAYMENT_SGD_CENTS
        );

        _allowWithdrawal(stallId);

        vm.prank(stallOwner);
        paymentsContract.WithdrawStallPayments(stallId);

        // Wallet history: withdrawal is positive.
        vm.prank(stallOwner);

        TransactionHistoryItem[] memory walletHistory = paymentsContract
            .GetMyWalletTransactionHistory();

        assertEq(walletHistory.length, 1);
        assertEq(walletHistory[0].PaymentID, 0);
        assertEq(walletHistory[0].WithdrawalID, 1);
        assertEq(walletHistory[0].StallID, stallId);
        assertEq(walletHistory[0].StallOwnerWallet, stallOwner);
        assertEq(walletHistory[0].Amount, amountPaidWei);
        assertEq(walletHistory[0].SignedAmount, int256(amountPaidWei));
        assertEq(walletHistory[0].AmountSGDCents, 0);
        assertEq(walletHistory[0].SignedAmountSGDCents, 0);
        assertEq(
            uint256(walletHistory[0].transactionType),
            uint256(TransactionHistoryType.WithdrawalTransaction)
        );

        // Historical stall view by ID still works after completion.
        vm.prank(stallOwner);

        TransactionHistoryItem[] memory stallHistory = paymentsContract
            .GetStallTransactionHistory(stallId);

        assertEq(stallHistory.length, 2);

        assertEq(stallHistory[0].SignedAmount, int256(amountPaidWei));
        assertEq(
            stallHistory[0].SignedAmountSGDCents,
            int256(DEFAULT_PAYMENT_SGD_CENTS)
        );
        assertEq(
            uint256(stallHistory[0].transactionType),
            uint256(TransactionHistoryType.PaidTransaction)
        );

        assertEq(stallHistory[1].SignedAmount, -int256(amountPaidWei));
        assertEq(stallHistory[1].AmountSGDCents, 0);
        assertEq(stallHistory[1].SignedAmountSGDCents, 0);
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

        _paySGD(stallId, customer, DEFAULT_PAYMENT_SGD_CENTS);

        TransactionHistoryItem[] memory history = paymentsContract
            .GetStallTransactionHistory(stallId);

        assertEq(history.length, 1);
    }

    function test_StallOwnerCanViewOwnTransactionHistory() public {
        uint256 stallId = _createApprovedStall(stallOwner);

        vm.warp(CCN_START);

        _paySGD(stallId, customer, DEFAULT_PAYMENT_SGD_CENTS);

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
