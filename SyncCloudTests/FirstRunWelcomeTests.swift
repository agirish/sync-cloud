import Testing
@testable import SyncCloud

@Suite struct FirstRunWelcomeTests {

    @Test func testShowsOnlyUntilSeen() {
        #expect(FirstRunWelcome.shouldShow(hasSeenWelcome: false))
        #expect(!FirstRunWelcome.shouldShow(hasSeenWelcome: true))
    }

    @Test func testPrimaryActionRequiresTwoProviders() {
        // Below two providers a scan can't compare anything, so the front door is Settings ▸ Providers.
        #expect(FirstRunWelcome.primaryAction(providerCount: 0) == .chooseProviders)
        #expect(FirstRunWelcome.primaryAction(providerCount: 1) == .chooseProviders)
        #expect(FirstRunWelcome.primaryAction(providerCount: 2) == .scan)
        #expect(FirstRunWelcome.primaryAction(providerCount: 5) == .scan)
    }

    @Test func testDefaultsKeyIsStable() {
        // Persisted key — QA resets it by name, so renaming it would re-show the welcome
        // to every existing user.
        #expect(FirstRunWelcome.hasSeenDefaultsKey == "hasSeenFirstRunWelcome")
    }
}
