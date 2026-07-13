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

    @Test func testTourStartsWithWelcomeAndHasFeaturePages() {
        // The view special-cases index 0 as the intro (app icon + pane pill), so the sequence
        // must lead with the welcome page and carry at least one feature page after it.
        #expect(FirstRunWelcome.pages.first?.title == "Welcome to SyncCloud")
        #expect(FirstRunWelcome.pages.count >= 2)
        // Every page needs a title and blurb to render; feature pages (index > 0) also need a symbol.
        for (i, page) in FirstRunWelcome.pages.enumerated() {
            #expect(!page.title.isEmpty)
            #expect(!page.blurb.isEmpty)
            if i > 0 { #expect(!page.systemImage.isEmpty) }
        }
    }
}
