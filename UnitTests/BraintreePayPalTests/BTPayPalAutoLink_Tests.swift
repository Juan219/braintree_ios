import XCTest
@testable import BraintreePayPal
@testable import BraintreeTestShared
@testable import BraintreeCore

class BTPayPalAutoLink_Tests: XCTestCase {

    var mockAPIClient: MockAPIClient!
    var payPalClient: BTPayPalClient!
    var mockPendingStore: MockPendingStore!
    var mockWebAuthenticationSession: MockWebAuthenticationSession!
    var fakeApplication: FakeApplication!
    let authorization = "development_testing_integration_merchant_id"

    let nonceResponseBody = BTJSON(value: [
        "paypalAccounts": [["nonce": "a-nonce", "type": "PayPalAccount"]]
    ] as [String: Any])

    let hermesResponseBody = BTJSON(value: [
        "paymentResource": ["redirectUrl": "http://fakeURL.com"]
    ] as [String: Any])

    override func setUp() {
        super.setUp()

        mockAPIClient = MockAPIClient(authorization: "development_tokenization_key")
        mockAPIClient.cannedConfigurationResponseBody = BTJSON(value: [
            "paypalEnabled": true,
            "paypal": ["environment": "offline"],
            "merchantId": "testMerchantId"
        ] as [String: Any])

        payPalClient = BTPayPalClient(authorization: authorization, universalLink: URL(string: "https://www.paypal.com")!)
        payPalClient.apiClient = mockAPIClient

        mockWebAuthenticationSession = MockWebAuthenticationSession()
        payPalClient.webAuthenticationSession = mockWebAuthenticationSession

        mockPendingStore = MockPendingStore()
        BTPayPalClient.pendingStore = mockPendingStore

        fakeApplication = FakeApplication()
        payPalClient.application = fakeApplication
    }

    override func tearDown() {
        BTPayPalClient.payPalClient = nil
        BTPayPalClient.pendingStore = BTPayPalInMemoryPendingStore()
        super.tearDown()
    }

    // MARK: - Helpers

    func makeValidSession(paymentType: BTPayPalPaymentType = .vault) -> BTPayPalAppSwitchSession {
        BTPayPalAppSwitchSession(paymentType: paymentType, startedAt: Date())
    }

    func makeExpiredSession() -> BTPayPalAppSwitchSession {
        BTPayPalAppSwitchSession(
            paymentType: .vault,
            startedAt: Date(timeIntervalSinceNow: -(BTPayPalAppSwitchSession.ttl + 1))
        )
    }

    func setPendingSession(_ session: BTPayPalAppSwitchSession?) async {
        await mockPendingStore.setStoredSession(session)
    }

    func assertStoreCallCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let storeCallCount = await mockPendingStore.storeCallCount
        XCTAssertEqual(storeCallCount, expected, file: file, line: line)
    }

    func assertClearCallCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let clearCallCount = await mockPendingStore.clearCallCount
        XCTAssertEqual(clearCallCount, expected, file: file, line: line)
    }

    func assertPendingSessionNil(file: StaticString = #filePath, line: UInt = #line) async {
        let storedSession = await mockPendingStore.storedSession
        XCTAssertNil(storedSession, file: file, line: line)
    }

    func assertPendingSessionNotNil(file: StaticString = #filePath, line: UInt = #line) async {
        let storedSession = await mockPendingStore.storedSession
        XCTAssertNotNil(storedSession, file: file, line: line)
    }

    func assertPendingSessionPaymentType(
        _ expected: BTPayPalPaymentType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let storedSession = await mockPendingStore.storedSession
        XCTAssertEqual(storedSession?.paymentType, expected, file: file, line: line)
    }

    func configureActiveAppSwitchContext(
        contextID: String = "BA-123",
        correlationID: String? = "corr-id"
    ) {
        BTPayPalClient.payPalClient = payPalClient
        payPalClient.contextID = contextID

        if let correlationID {
            payPalClient.clientMetadataIDs[contextID] = correlationID
        } else {
            payPalClient.clientMetadataIDs.removeValue(forKey: contextID)
        }
    }

    func makeHTTPURLResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.braintreegateway.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - Persist before app switch (launchPayPalApp)

    func testLaunchPayPalApp_whenVaultRequest_storesPendingSession() async {
        mockAPIClient.cannedResponseBody = BTJSON(value: [
            "agreementSetup": ["paypalAppApprovalUrl": "https://paypal.com/some-path?ba_token=BA-ABC"]
        ] as [String: Any])

        let vaultRequest = BTPayPalVaultRequest(enablePayPalAppSwitch: true, userAuthenticationEmail: "user@test.com")
        let expectation = expectation(description: "tokenize called")
        expectation.isInverted = true

        payPalClient.tokenize(vaultRequest) { _, _ in expectation.fulfill() }

        await fulfillment(of: [expectation], timeout: 1)

        await assertStoreCallCount(1)
        await assertPendingSessionPaymentType(.vault)
    }

    func testLaunchPayPalApp_whenCheckoutRequest_doesNotStorePendingSession() async {
        mockAPIClient.cannedResponseBody = BTJSON(value: [
            "paymentResource": [
                "redirectUrl": "https://paypal.com/checkout?token=EC-123",
                "launchPayPalApp": true
            ]
        ] as [String: Any])

        let checkoutRequest = BTPayPalCheckoutRequest(amount: "10.00")
        let expectation = expectation(description: "tokenize called")
        expectation.isInverted = true

        payPalClient.tokenize(checkoutRequest) { _, _ in expectation.fulfill() }

        await fulfillment(of: [expectation], timeout: 1)

        await assertStoreCallCount(0)
    }

    func testLaunchPayPalApp_activeClientStoresCorrectCorrelationID() async {
        mockAPIClient.cannedResponseBody = BTJSON(value: [
            "agreementSetup": ["paypalAppApprovalUrl": "https://paypal.com/some-path?ba_token=BA-ABC"]
        ] as [String: Any])

        let vaultRequest = BTPayPalVaultRequest(
            enablePayPalAppSwitch: true,
            riskCorrelationID: "fake-correlation-id",
            userAuthenticationEmail: "user@test.com"
        )
        let expectation = expectation(description: "tokenize called")
        expectation.isInverted = true

        payPalClient.tokenize(vaultRequest) { _, _ in expectation.fulfill() }

        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(payPalClient.clientMetadataIDs["BA-ABC"], "fake-correlation-id")
    }

    // MARK: - Path 1: applicationDidBecomeActive guard

    func testApplicationDidBecomeActive_whenNotActiveClient_doesNotAttemptAutoLink() async {
        BTPayPalClient.payPalClient = nil
        await setPendingSession(makeValidSession())

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        let expectation = expectation(description: "No auto-link POST should fire")
        expectation.isInverted = true
        await fulfillment(of: [expectation], timeout: 0.5)

        XCTAssertEqual(mockAPIClient.lastPOSTPath, "")
        await assertClearCallCount(0)
    }

    func testApplicationDidBecomeActive_whenNoPendingSession_doesNotPostToPayPalAccounts() async {
        BTPayPalClient.payPalClient = payPalClient
        await setPendingSession(nil)

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        let expectation = expectation(description: "No POST should fire")
        expectation.isInverted = true
        await fulfillment(of: [expectation], timeout: 0.5)

        XCTAssertEqual(mockAPIClient.lastPOSTPath, "")
    }

    func testApplicationDidBecomeActive_whenExpiredSession_clearsPendingStoreAndDoesNotPost() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeExpiredSession())

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        let expectation = expectation(description: "No POST should fire after expiry clear")
        expectation.isInverted = true
        await fulfillment(of: [expectation], timeout: 0.5)

        await assertClearCallCount(1)
        XCTAssertEqual(mockAPIClient.lastPOSTPath, "")
    }

    func testApplicationDidBecomeActive_whenValidSession_andBTGWSucceeds_deliversNonceViaAppSwitchCompletion() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let expectation = expectation(description: "Nonce delivered via appSwitchCompletion")
        payPalClient.appSwitchCompletion = { nonce, error in
            XCTAssertNotNil(nonce)
            XCTAssertNil(error)
            expectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 2)
    }

    func testApplicationDidBecomeActive_whenValidSession_andBTGWSucceeds_clearsPendingStore() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let expectation = expectation(description: "Store cleared after success")
        payPalClient.appSwitchCompletion = { _, _ in expectation.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 2)

        await assertPendingSessionNil()
    }

    func testApplicationDidBecomeActive_whenValidSession_andBTGWFails_doesNotCompleteAndKeepsPendingStore() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseError = NSError(domain: "com.test", code: 1)

        let expectation = expectation(description: "Auto-link failure should not complete merchant callback")
        expectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in
            expectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 0.5)

        await assertPendingSessionNotNil()
        await assertClearCallCount(0)
    }

    func testApplicationDidBecomeActive_whenBTGWReturns202_doesNotCompleteAndKeepsPendingStore() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody
        mockAPIClient.cannedHTTPURLResponse = makeHTTPURLResponse(statusCode: 202)

        let expectation = expectation(description: "Pending auto-link should not complete merchant callback")
        expectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in
            expectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 0.5)

        await assertPendingSessionNotNil()
        await assertClearCallCount(0)
        XCTAssertTrue(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkFailed))
    }

    func testApplicationDidBecomeActive_whenBTGWReturns202_thenSucceedsOnNextForeground_deliversNonce() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody
        mockAPIClient.cannedHTTPURLResponse = makeHTTPURLResponse(statusCode: 202)

        let firstAttemptExpectation = expectation(description: "Pending auto-link should not complete merchant callback")
        firstAttemptExpectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in
            firstAttemptExpectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [firstAttemptExpectation], timeout: 0.5)

        await assertPendingSessionNotNil()
        await assertClearCallCount(0)

        mockAPIClient.cannedHTTPURLResponse = makeHTTPURLResponse(statusCode: 200)

        let secondAttemptExpectation = expectation(description: "Second auto-link attempt succeeds")
        payPalClient.appSwitchCompletion = { nonce, error in
            XCTAssertNotNil(nonce)
            XCTAssertNil(error)
            secondAttemptExpectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [secondAttemptExpectation], timeout: 2)

        await assertPendingSessionNil()
        await assertClearCallCount(1)
        XCTAssertTrue(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkSucceeded))
    }

    func testApplicationDidBecomeActive_whenBTGWFails_thenSucceedsOnNextForeground_deliversNonce() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseError = NSError(domain: "com.test", code: 1)

        let firstAttemptExpectation = expectation(description: "First auto-link failure should not complete merchant callback")
        firstAttemptExpectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in
            firstAttemptExpectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [firstAttemptExpectation], timeout: 0.5)

        await assertPendingSessionNotNil()

        mockAPIClient.cannedResponseError = nil
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let secondAttemptExpectation = expectation(description: "Second auto-link attempt succeeds")
        payPalClient.appSwitchCompletion = { nonce, error in
            XCTAssertNotNil(nonce)
            XCTAssertNil(error)
            secondAttemptExpectation.fulfill()
        }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [secondAttemptExpectation], timeout: 2)

        await assertPendingSessionNil()
    }

    func testApplicationDidBecomeActive_whenAlreadyAutoTokenizing_doesNotDuplicateRequest() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let firstCompletion = expectation(description: "First auto-link completes")
        payPalClient.appSwitchCompletion = { _, _ in firstCompletion.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))
        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [firstCompletion], timeout: 2)

        await assertClearCallCount(1)
    }

    // MARK: - Path 1: Analytics

    func testApplicationDidBecomeActive_whenValidSession_sendsAutoLinkStartedAnalytic() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let expectation = expectation(description: "Auto-link completes")
        payPalClient.appSwitchCompletion = { _, _ in expectation.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertTrue(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkStarted))
    }

    func testApplicationDidBecomeActive_whenBTGWSucceeds_sendsAutoLinkSucceededAnalytic() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let expectation = expectation(description: "Auto-link completes")
        payPalClient.appSwitchCompletion = { _, _ in expectation.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertTrue(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkSucceeded))
    }

    func testApplicationDidBecomeActive_whenBTGWFails_sendsAutoLinkFailedAnalytic() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseError = NSError(domain: "com.test", code: 1)

        let expectation = expectation(description: "Auto-link failure should not complete merchant callback")
        expectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in expectation.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [expectation], timeout: 0.5)

        XCTAssertTrue(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkFailed))
    }

    // MARK: - Path 2: Next button tap

    @MainActor
    func testTokenizeVault_whenValidPendingSession_postsToPayPalAccountsNotHermes() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try? await payPalClient.tokenize(vaultRequest)

        XCTAssertEqual(mockAPIClient.lastPOSTPath, "/v1/payment_methods/paypal_accounts")
    }

    @MainActor
    func testTokenizeVault_whenValidPendingSession_andBTGWSucceeds_returnsNonce() async throws {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        let nonce = try await payPalClient.tokenize(vaultRequest)

        XCTAssertEqual(nonce.nonce, "a-nonce")
    }

    @MainActor
    func testTokenizeVault_whenValidPendingSession_andBTGWSucceeds_clearsPendingStore() async throws {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try await payPalClient.tokenize(vaultRequest)

        await assertPendingSessionNil()
    }

    @MainActor
    func testTokenizeVault_whenValidPendingSession_andBTGWFails_clearsPendingStoreAndFallsThrough() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = hermesResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try? await payPalClient.tokenize(vaultRequest)

        await assertClearCallCount(1)
        XCTAssertEqual(mockAPIClient.lastPOSTPath, "v1/paypal_hermes/setup_billing_agreement")
    }

    @MainActor
    func testTokenizeVault_whenExpiredPendingSession_clearsPendingStoreAndProceedsToHermes() async {
        await setPendingSession(makeExpiredSession())
        mockAPIClient.cannedResponseBody = hermesResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try? await payPalClient.tokenize(vaultRequest)

        await assertClearCallCount(1)
        XCTAssertEqual(mockAPIClient.lastPOSTPath, "v1/paypal_hermes/setup_billing_agreement")
    }

    @MainActor
    func testTokenizeCheckout_whenPendingSessionExists_ignoresPendingStoreAndPostsToHermes() async {
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = BTJSON(value: [
            "paymentResource": ["redirectUrl": "http://fakeURL.com"]
        ] as [String: Any])

        let checkoutRequest = BTPayPalCheckoutRequest(amount: "10.00")
        _ = try? await payPalClient.tokenize(checkoutRequest)

        await assertStoreCallCount(0)
        XCTAssertEqual(mockAPIClient.lastPOSTPath, "v1/paypal_hermes/create_payment_resource")
    }

    // MARK: - Path 2: POST body for auto-link

    @MainActor
    func testTokenizeVault_whenValidPendingSession_sendsBATokenInPostBody() async {
        configureActiveAppSwitchContext(contextID: "BA-SPECIFIC")
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try? await payPalClient.tokenize(vaultRequest)

        let lastPostParameters = mockAPIClient.lastPOSTParameters!
        let paypalAccount = lastPostParameters["paypal_account"] as! [String: Any]
        XCTAssertEqual(paypalAccount["billing_agreement_token"] as? String, "BA-SPECIFIC")
    }

    @MainActor
    func testTokenizeVault_whenValidPendingSession_sendsCorrelationIDInPostBody() async {
        configureActiveAppSwitchContext(contextID: "BA-123", correlationID: "my-correlation")
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody

        let vaultRequest = BTPayPalVaultRequest()
        _ = try? await payPalClient.tokenize(vaultRequest)

        let lastPostParameters = mockAPIClient.lastPOSTParameters!
        let paypalAccount = lastPostParameters["paypal_account"] as! [String: Any]
        XCTAssertEqual(paypalAccount["correlation_id"] as? String, "my-correlation")
    }

    // MARK: - handleReturnURL race prevention

    func testHandleReturnURL_clearsPendingStoreBeforeTokenizing() async {
        await setPendingSession(makeValidSession())

        let expectation = expectation(description: "Handle return completes")
        payPalClient.appSwitchCompletion = { _, _ in expectation.fulfill() }

        payPalClient.handleReturnURL(URL(string: "https://mycoolwebsite.com/braintree-payments/success")!)

        await fulfillment(of: [expectation], timeout: 2)

        await assertClearCallCount(1)
    }

    func testHandleReturnURL_whenCalledWithValidURL_doesNotFireAutoLink() async {
        configureActiveAppSwitchContext()
        await setPendingSession(makeValidSession())
        mockAPIClient.cannedResponseBody = nonceResponseBody
        payPalClient.payPalRequest = BTPayPalVaultRequest()

        let handleReturnExpectation = expectation(description: "Handle return completes")
        payPalClient.appSwitchCompletion = { _, _ in handleReturnExpectation.fulfill() }

        payPalClient.handleReturnURL(URL(string: "https://mycoolwebsite.com/braintree-payments/success")!)

        await fulfillment(of: [handleReturnExpectation], timeout: 2)

        let autoLinkExpectation = expectation(description: "Auto-link should NOT fire")
        autoLinkExpectation.isInverted = true
        payPalClient.appSwitchCompletion = { _, _ in autoLinkExpectation.fulfill() }

        payPalClient.applicationDidBecomeActive(notification: Notification(name: UIApplication.didBecomeActiveNotification))

        await fulfillment(of: [autoLinkExpectation], timeout: 0.5)

        XCTAssertFalse(mockAPIClient.postedAnalyticsEvents.contains(BTPayPalAnalytics.autoLinkStarted))
    }
}
