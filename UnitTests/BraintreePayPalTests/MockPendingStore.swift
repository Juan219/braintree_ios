import Foundation
@testable import BraintreePayPal

actor MockPendingStore: BTPayPalPendingStoreProtocol {

    var storedSession: BTPayPalAppSwitchSession?
    var storeCallCount = 0
    var clearCallCount = 0

    func store(_ session: BTPayPalAppSwitchSession) async {
        storedSession = session
        storeCallCount += 1
    }

    func read() async -> BTPayPalAppSwitchSession? {
        storedSession
    }

    func clear() async {
        storedSession = nil
        clearCallCount += 1
    }

    func setStoredSession(_ session: BTPayPalAppSwitchSession?) {
        storedSession = session
    }
}
