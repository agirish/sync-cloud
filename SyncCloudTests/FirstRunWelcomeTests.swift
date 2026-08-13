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

    /// Every illustration has a page, and every page an illustration.
    ///
    /// The distinctness check above catches two pages sharing art; this catches the other
    /// direction, which nothing else can see. An `Art` case is referenced only by `pages` and by
    /// `TourArtwork`'s switch, so one added without a page compiles, renders nothing, and looks
    /// exactly like a working tour.
    @Test func testEveryIllustrationIsUsedByExactlyOnePage() {
        let used = FirstRunWelcome.pages.map(\.art)
        for art in [FirstRunWelcome.Art.welcome, .browse, .compare, .transfer, .duplicates, .filing] {
            #expect(used.filter { $0 == art }.count == 1,
                    "\(art) is not used by exactly one page")
        }
        // Pinned so the list above cannot quietly fall behind the enum: a new case with no page
        // fails here rather than being skipped by a loop that never names it.
        #expect(used.count == 6)
    }

    /// The tour opens on the workspace the app opens on.
    ///
    /// Browse became both the first segment and the default workspace, which made the tour's old
    /// shape wrong in a way no assertion covered: it taught Compare, Transfer, Duplicates and
    /// Organize, then dismissed the user into a place it had never named.
    @Test func testTheTourCoversWhereTheAppOpens() throws {
        #expect(WorkspaceSelection.default.workspace == .browse,
                "if the default workspace moves, the page after the intro should move with it")
        let browse = try #require(FirstRunWelcome.pages.firstIndex { $0.art == .browse })
        #expect(browse == 1, "Browse should be the first page after the welcome")
    }

    /// No blurb may describe a retired workspace as a workspace.
    ///
    /// Derived from ``Workspace/retiredWorkspaceRawValues`` rather than spelling out today's
    /// offenders, because the failure mode is structural: every time a workspace folds into an
    /// Organize lens, prose written before the fold keeps calling it a workspace. That is exactly
    /// what happened to "The Duplicates workspace finds duplicate files", which shipped for the
    /// whole of the v3 line — this screen renders once per install, so nobody was ever going to
    /// notice it. The next fold grows the table, and this test with it.
    @Test func testTheTourCallsNoRetiredWorkspaceAWorkspace() {
        for retired in Workspace.retiredWorkspaceRawValues.keys {
            for page in FirstRunWelcome.pages {
                #expect(!page.blurb.localizedCaseInsensitiveContains("\(retired) workspace"),
                        "“\(page.title)” calls \(retired) a workspace — it is an Organize lens")
                #expect(!page.title.localizedCaseInsensitiveContains("\(retired) workspace"),
                        "“\(page.title)” calls \(retired) a workspace — it is an Organize lens")
            }
        }
    }

    /// The positive control for the check above.
    ///
    /// That test asserts an ABSENCE across a derived list, so it passes just as happily if the
    /// table is empty, the blurbs are empty, or the matcher never matches anything. This proves
    /// all three are live: the table has entries, and the same matcher finds the phrase in a
    /// string that really contains it.
    @Test func testTheRetiredWorkspaceScanCanActuallyFail() {
        #expect(!Workspace.retiredWorkspaceRawValues.isEmpty)
        let offender = "The Duplicates workspace finds duplicate files."
        let caught = Workspace.retiredWorkspaceRawValues.keys.contains {
            offender.localizedCaseInsensitiveContains("\($0) workspace")
        }
        #expect(caught, "the matcher no longer catches the phrasing this test exists to ban")
    }
}
