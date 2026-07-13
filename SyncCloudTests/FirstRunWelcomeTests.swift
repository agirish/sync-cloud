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
        // The tour leads with the welcome page (app icon + pane pill on the final page) and
        // carries feature pages after it.
        #expect(FirstRunWelcome.pages.first?.art == .welcome)
        #expect(FirstRunWelcome.pages.first?.title == "Welcome to SyncCloud")
        #expect(FirstRunWelcome.pages.count >= 2)
        // Every page needs a title and blurb to render.
        for page in FirstRunWelcome.pages {
            #expect(!page.title.isEmpty)
            #expect(!page.blurb.isEmpty)
        }
        // Each page's artwork is distinct, so no two pages render the same illustration.
        let arts = FirstRunWelcome.pages.map(\.art)
        #expect(Set(arts).count == arts.count)
    }
}
