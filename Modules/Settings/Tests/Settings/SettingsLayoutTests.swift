import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import Settings

/// `view`'s height at `width`, laid out for real. Shared by every suite here that measures a page.
/// The text scale is pinned: `scaledFont` reads it from the environment, so an unpinned
/// measurement would report whatever text size the machine has set.
@MainActor
func laidOutHeight(_ view: some View, width: CGFloat = SettingsSheetMetrics.contentWidth(textScale: 1),
                   scale: CGFloat = 1) -> CGFloat {
    let host = NSHostingView(rootView: view.environment(\.appFontScale, scale).frame(width: width))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

/// Pins the sidebar layout's promise: the must-fit pages fit their opening without scrolling, and
/// the sheet never outgrows the window it is centered in. Heights come from the laid-out view
/// (`NSHostingView.fittingSize`), not from the constants that feed it. The exempt pages and their
/// reasons live in ``SettingsView/SettingsTab/exemptFromFitGuard``. General is measurable because
/// its SMAppService reads are in `.task`, which an offscreen host never fires; a fixture passing
/// `nil` measures the empty state, which is why Name Checks is exempt.
@Suite struct SettingsLayoutTests {

    /// The content column: the sheet minus the rail and the divider between them.
    private static var contentWidth: CGFloat {
        SettingsSheetMetrics.contentWidth(textScale: 1)
    }

    /// The width a view wants when nothing constrains it, its intrinsic width. Unconstrained,
    /// unlike `laidOutHeight`, so it can be compared with the column it must fit: constrained, it
    /// would agree with the constraint however wide the text was.
    @MainActor
    private func laidOutWidth(_ view: some View, scale: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, scale))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The margin Appearance has left at one text size; positive means it fits.
    @MainActor
    private func appearanceMargin(at scale: CGFloat) -> CGFloat {
        let height = laidOutHeight(AppearanceSettingsTab(),
                                   width: SettingsSheetMetrics.contentWidth(textScale: scale),
                                   scale: scale)
        return SettingsSheetMetrics.pageOpening(textScale: scale) - height
    }

    /// The smallest margin any must-fit page has over its own opening, whichever page that is.
    /// Named for the property, not a page, because which page is tightest changes as pages are
    /// reorganized, and a helper naming one would keep passing while measuring the wrong page.
    @MainActor
    private func tightestMustFitMargin(at scale: CGFloat) -> CGFloat {
        let test = TestDefaults("tallest-\(scale)")
        let settings = test.manager()
        return mustFitPages(settings)
            .map { place, view in
                SettingsSheetMetrics.opening(for: place, textScale: scale)
                    - laidOutHeight(view, width: SettingsSheetMetrics.contentWidth(textScale: scale), scale: scale)
            }
            .min() ?? 0
    }

    /// A 1280×800-class display's window: 800pt less 24pt of menu bar and ~36pt of title bar, which
    /// `ContentView.settingsOverlay` hands to `SettingsView` as `availableSize`. The Dock is excluded;
    /// with a bottom Dock the answer is the scroll fallback (`residualOverflowIsAbsorbedByScrolling`).
    private static let smallDisplayWindow = CGSize(width: 1280, height: 800 - 24 - 36)

    /// The window's own content floor, mirroring `ContentView`'s `.frame(minWidth:minHeight:)`. A
    /// literal because Settings can't see `MacApp`; a floor raised there only gives the sheet more room.
    private static let windowFloor = CGSize(width: 804, height: 560)

    /// Mirrors `project.yml`'s `CFBundleShortVersionString` (`RELEASE.md` updates it per release). A
    /// literal because under `swift test` `Bundle.main` is the test host and has no version.
    private static let versionMarker = "7.2-dev"

    /// The margin Appearance has left at one text size with a chosen accent hue, set through the
    /// tab's `@AppStorage` via `.defaultAppStorage`, so nothing is inherited from
    /// `UserDefaults.standard` or a neighbouring test.
    @MainActor
    private func appearanceMargin(hue: LiquidGlassHue,
                                  at scale: CGFloat,
                                  available: CGSize? = nil) -> CGFloat {
        let test = TestDefaults("hue-\(hue.rawValue)-\(scale)")
        test.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)

        let height = laidOutHeight(AppearanceSettingsTab().defaultAppStorage(test.defaults),
                                   width: SettingsSheetMetrics.contentWidth(textScale: scale, available: available),
                                   scale: scale)
        return SettingsSheetMetrics.pageOpening(textScale: scale, available: available) - height
    }

    /// The upper bound on `baseSize`: the opening clears the tightest must-fit page with room for a
    /// copy edit and no more. Two copy edits of slack is the limit; past that, lower `baseSize`,
    /// don't widen this bound.
    @MainActor
    @Test func theSheetIsSizedAgainstTheTightestPageItMustFit() async throws {
        let margin = tightestMustFitMargin(at: 1)

        // Measured over every must-fit page rather than a named one, since which page is tightest
        // moves as pages change.
        #expect(margin <= 30,
                "The tightest must-fit page has \(margin)pt to spare — baseSize has stopped being sized against that measurement.")
        // The other half, so a `baseSize` lowered too far fails here rather than in a fit test
        // somewhere else: the tightest page still has to clear its opening with a copy edit spare.
        #expect(margin >= 15,
                "The tightest must-fit page clears its opening by only \(margin)pt — one copy edit from scrolling.")
    }

    /// The fit at every text size. Only the type scales, not padding or control heights, so a sheet
    /// scaled down by the full `FontSize.scale` would clip the last control; `resolvedSize` floors
    /// the scale at 1.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func appearanceFitsEveryTextSize(_ size: FontSize) async throws {
        let margin = appearanceMargin(at: size.scale)

        #expect(margin >= 15,
                "Appearance has \(margin)pt of slack at \(size.percent)% (scale \(size.scale)).")
    }

    /// Text & Spacing fits a 1280×800 display at every text size: it exists for large text, and its
    /// tiles, detent labels and preview all grow with it. The margin is comfortable; don't treat this
    /// as a tight bound and trim the tab for it.
    @MainActor
    @Test func readabilityFitsASmallDisplayAtEveryTextSize() async throws {
        let fitting = FontSize.allCases.filter { size in
            let height = laidOutHeight(
                ReadabilitySettingsTab(),
                width: SettingsSheetMetrics.contentWidth(textScale: size.scale,
                                                        available: Self.smallDisplayWindow),
                scale: size.scale)
            return height <= SettingsSheetMetrics.pageOpening(textScale: size.scale,
                                                              available: Self.smallDisplayWindow)
        }

        #expect(fitting == FontSize.allCases,
                """
                Readability fits a 1280×800 display at \(fitting.map { "\($0.percent)%" }) — the tab \
                that exists for large text does not survive its own largest setting.
                """)
    }

    /// Every accent hue, because the Tint caption changes with the hue (under `.none` it asks for an
    /// accent). Raw values because `LiquidGlassHue` isn't `Sendable` and can't be a test argument.
    @MainActor
    @Test(arguments: LiquidGlassHue.allCases.map(\.rawValue))
    func appearanceFitsEveryAccentHue(_ rawValue: String) async throws {
        let hue = try #require(LiquidGlassHue(rawValue: rawValue))

        let margin = appearanceMargin(hue: hue, at: 1)
        #expect(margin >= 15,
                "Appearance has \(margin)pt of slack with the \(rawValue) accent — a caption is costing a line.")

        let clamped = appearanceMargin(hue: hue, at: 1, available: Self.smallDisplayWindow)
        #expect(clamped >= 0,
                "Appearance overflows a 1280×800 display's clamped opening by \(-clamped)pt with the \(rawValue) accent.")
    }

    /// The clamped opening at every text size, which `appearanceFitsEveryTextSize` (`available: nil`)
    /// can't fail. Outgrowing a small display at large text would be a floor, not a bug: `SettingsPage`
    /// scrolls. Asserted as the exact list of sizes that fit, so a change either way is deliberate.
    @MainActor
    @Test func theClampedOpeningFitsEveryTextSize() async throws {
        let fitting = FontSize.allCases.filter { size in
            let height = laidOutHeight(AppearanceSettingsTab(),
                                       width: SettingsSheetMetrics.contentWidth(textScale: size.scale,
                                                                                available: Self.smallDisplayWindow),
                                       scale: size.scale)
            return height <= SettingsSheetMetrics.pageOpening(textScale: size.scale,
                                                              available: Self.smallDisplayWindow)
        }

        #expect(fitting.contains(.medium),
                "Appearance scrolls on a 1280×800 display at the default size — a regression, not a floor")
        // Every size fits at today's `baseSize`. An equality, not "at least these", so it can't go
        // vacuous: if a section is added and Largest stops fitting, this fails.
        #expect(fitting == FontSize.allCases,
                "Appearance fits a 1280×800 display at \(fitting.map { "\($0.percent)%" }) — the residual recorded on this test is out of date.")
    }

    /// Overflow degrades by scrolling, not clipping, which a fit test can't say. `SettingsPage`
    /// scrolls, but a sheet outgrowing the window would put the overflow past the screen edge where
    /// no scroll reaches. `resolvedSize` prevents that at every text size on a small display.
    @Test func residualOverflowIsAbsorbedByScrolling() {
        for size in FontSize.allCases {
            let sheet = SettingsSheetMetrics.resolvedSize(textScale: size.scale,
                                                          available: Self.smallDisplayWindow)

            #expect(sheet.height <= Self.smallDisplayWindow.height,
                    "at \(size.percent)% the sheet is \(sheet.height)pt in a \(Self.smallDisplayWindow.height)pt window — the overflow is off-screen, not scrollable.")
            #expect(sheet.width <= Self.smallDisplayWindow.width)
            #expect(SettingsSheetMetrics.pageOpening(textScale: size.scale,
                                                     available: Self.smallDisplayWindow) > 0,
                    "at \(size.percent)% the title row and the sub-tab strip have eaten the whole sheet.")
        }
    }

    /// The rule the case above rests on, stated directly so a regression names the cause: the
    /// sheet grows with the text setting and never shrinks below its base size.
    @Test func theSheetNeverShrinksBelowItsBaseSize() {
        for size in FontSize.allCases {
            let resolved = SettingsSheetMetrics.resolvedSize(textScale: size.scale, available: nil)

            #expect(resolved.width >= SettingsSheetMetrics.baseSize.width)
            #expect(resolved.height >= SettingsSheetMetrics.baseSize.height,
                    "\(size.percent)% shrank the sheet to \(resolved.height)pt.")
        }
    }

    /// Key & Spending lays out without reading the Anthropic key from the Keychain: `CloudKeyRow`'s
    /// `onAppear` runs for every visitor, and a read would block this host and, in the app, put a
    /// password prompt on screen. If that read comes back, this test stops finishing. Safe only
    /// because `AnthropicKeychain.isConfigured` checks existence without reading the secret.
    @MainActor
    @Test func keyAndSpendingLaysOutWithoutReachingForTheKeychain() async throws {
        let height = laidOutHeight(IntelligenceSettingsTab(page: .keyAndSpending), width: Self.contentWidth)

        #expect(height > 0)
    }

    // MARK: - The other pages

    /// The pages that must fit, and the view each is measured as. Hand-built, since a fixture can't
    /// be derived from its case, but `everyPageIsEitherFitTestedOrExplicitlyExempt` holds it to every
    /// page minus `SettingsTab.exemptFromFitGuard`. A `nil` dependency measures the empty state: fine
    /// for Suggestions and Advanced, whose rows don't grow with the user's data; ask that of a new
    /// entry. Edit ▸ PDF is measured without its saved signatures (at most six and six, a row each).
    @MainActor
    private func mustFitPages(_ settings: SettingsManager) -> [(SettingsPlace, AnyView)] {
        // Non-nil closures, or sections go unmeasured: the setup, reset, rules and help buttons are
        // drawn only when their closure is there.
        [(SettingsPlace(.general), AnyView(GeneralSettingsTab().environmentObject(settings))),
         (SettingsPlace(.look), AnyView(AppearanceSettingsTab())),
         (SettingsPlace(.textAndSpacing), AnyView(ReadabilitySettingsTab())),
         (SettingsPlace(.panes), AnyView(BrowseSettingsTab(page: .panes, onCustomizePaneBar: {},
                                                           confirmReleasingColumnWidths: { _ in false })
            .environmentObject(settings))),
         (SettingsPlace(.window), AnyView(BrowseSettingsTab(page: .window).environmentObject(settings))),
         (SettingsPlace(.differences), AnyView(SyncSettingsTab(page: .differences, syncManager: nil).environmentObject(settings))),
         (SettingsPlace(.suggestions), AnyView(OrganizeSuggestionsPage(syncManager: nil, onOpenHelp: { _ in },
                                                                     onJump: { _ in }))),
         (SettingsPlace(.duplicates), AnyView(DuplicatesSettingsTab())),
         (SettingsPlace(.text), AnyView(EditSettingsTab(page: .text))),
         (SettingsPlace(.pdf), AnyView(EditSettingsTab(page: .pdf))),
         (SettingsPlace(.claudeGeneral), AnyView(IntelligenceSettingsTab(page: .claudeGeneral))),
         (SettingsPlace(.keyAndSpending), AnyView(IntelligenceSettingsTab(page: .keyAndSpending))),
         (SettingsPlace(.advanced), AnyView(AdvancedSettingsTab(syncManager: nil, onResetAllSettings: {},
                                                                onRunSetup: {}, onResetSetup: {})))]
    }

    /// Every page there is: each one-page tab, and each sub-tab.
    private static var allPages: Set<SettingsPlace> {
        Set(SettingsView.SettingsTab.allCases.filter(\.subTabs.isEmpty).map { SettingsPlace($0) }
            + SettingsSubTab.allCases.map { SettingsPlace($0) })
    }

    // MARK: - Name Checks: the page whose height is its user's data

    /// Sources ▸ Name Checks carrying `count` allowed names, through the real store the page reads.
    /// Scratch `TestDefaults`, because `KeptNamesStore` persists to whatever it is handed and
    /// `.standard` would inherit the machine's kept names.
    @MainActor
    private func nameChecksPage(allowedNames count: Int,
                                _ body: (AnyView) -> Void) {
        let test = TestDefaults("keptNames-\(count)")

        let store = KeptNamesStore(userDefaults: test.defaults)
        // Short, single-line names: a wrapping name would cost more than a row, and the claim is
        // about the row count.
        for index in 0..<count { store.keep("kept name \(index).pdf") }
        let manager = FileSyncManager()
        manager.keptNamesStore = store
        let settings = test.manager()

        body(AnyView(ProvidersSettingsTab(page: .nameChecks, syncManager: manager).environmentObject(settings)))
    }

    /// Name Checks' fixed chrome fits with nothing allowed: the rule, both captions and the header.
    /// Built through a real store, not `syncManager: nil`, so it uses the app's branch.
    @MainActor
    @Test func theNameChecksPageFitsItsOpeningWithNothingAllowed() async throws {
        let opening = SettingsSheetMetrics.pageOpening(textScale: 1, available: Self.smallDisplayWindow)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1, available: Self.smallDisplayWindow)

        nameChecksPage(allowedNames: 0) { page in
            let height = laidOutHeight(page, width: width)

            #expect(height <= opening,
                    "Name Checks with nothing allowed lays out at \(height)pt in a 1280×800 display's \(opening)pt opening — its fixed chrome alone now scrolls.")
        }
    }

    /// With a plausible number of allowed names the page outgrows its opening, so Name Checks'
    /// exemption is a measurement. If the list is ever bounded, this fails: drop the exemption and
    /// fit-test the page, don't raise the number.
    @MainActor
    @Test func theNameChecksPageOutgrowsItsOpeningOnceNamesAreAllowed() async throws {
        let opening = SettingsSheetMetrics.pageOpening(textScale: 1, available: Self.smallDisplayWindow)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1, available: Self.smallDisplayWindow)

        var populated: CGFloat = 0
        nameChecksPage(allowedNames: 30) { page in populated = laidOutHeight(page, width: width) }

        #expect(populated > opening,
                "Name Checks with 30 allowed names lays out at \(populated)pt and fits the \(opening)pt opening — the list must have been bounded; drop its exemption and fit-test it.")

        var doubled: CGFloat = 0
        nameChecksPage(allowedNames: 60) { page in doubled = laidOutHeight(page, width: width) }

        #expect(doubled > populated,
                "60 allowed names lay out at \(doubled)pt against 30 names' \(populated)pt — the list has stopped growing with the data, so the page's height is no longer the user's.")
    }

    /// Every page is either measured or explicitly exempted, never both. A new page that joins
    /// neither list fails here by name; one in both is a stale exemption and fails too.
    @MainActor
    @Test func everyPageIsEitherFitTestedOrExplicitlyExempt() async throws {
        let test = TestDefaults()
        let settings = test.manager()
        let fitTested = Set(mustFitPages(settings).map { $0.0 })
        let exempt = SettingsView.SettingsTab.exemptFromFitGuard

        let doubleCounted = fitTested.intersection(exempt)
        #expect(doubleCounted.isEmpty,
                "\(doubleCounted.map(\.name).sorted()) are measured by mustFitPages AND named in exemptFromFitGuard — the exemption is stale, drop it.")

        let unaccounted = Self.allPages.subtracting(fitTested).subtracting(exempt)
        #expect(unaccounted.isEmpty,
                "\(unaccounted.map(\.name).sorted()) are neither fit-tested in mustFitPages nor exempted in SettingsTab.exemptFromFitGuard — decide, and record the decision.")
        // And nothing names a page that isn't one, such as a paged tab without its sub-tab.
        #expect(fitTested.union(exempt).isSubset(of: Self.allPages))
    }

    /// Every must-fit page, against the opening a 1280×800 display gives, so shrinking the sheet for
    /// one page can't make another scroll unnoticed.
    @MainActor
    @Test func everyMustFitPageFitsTheClampedOpening() async throws {
        let test = TestDefaults()
        let settings = test.manager()
        let width = SettingsSheetMetrics.contentWidth(textScale: 1, available: Self.smallDisplayWindow)

        for (place, view) in mustFitPages(settings) {
            let opening = SettingsSheetMetrics.opening(for: place, textScale: 1, available: Self.smallDisplayWindow)
            let height = laidOutHeight(view, width: width)

            #expect(height <= opening,
                    "\(place.name) lays out at \(height)pt in a 1280×800 display's \(opening)pt opening — it scrolls.")
        }
    }

    /// Every paged tab's strip fits the narrowest content column the sheet offers, at the largest
    /// text size: Organize's four labels are the longest.
    @MainActor
    @Test func everySubTabStripFitsTheNarrowestColumnAtTheLargestText() {
        let scale = FontSize.allCases.map(\.scale).max() ?? 1
        let column = SettingsSheetMetrics.contentWidth(textScale: scale, available: Self.windowFloor)
        for tab in SettingsView.SettingsTab.allCases where !tab.subTabs.isEmpty {
            let strip = SettingsSubTabStrip(tab: tab, selection: .constant(tab.subTabs[0]), hue: .blue)
            let width = laidOutWidth(strip.fixedSize(), scale: scale)
            #expect(width <= column - 2 * SettingsSheetMetrics.pagePaddingH,
                    "\(tab.displayName)'s strip is \(width)pt wide in a \(column)pt column at the largest text")
        }
    }

    // MARK: - Sizing

    @Test func sheetGrowsWithTheTextSetting() {
        // The sheet is sized in points and its contents in scaled type. If the sheet didn't grow
        // with the type, Larger would put the taller tabs straight back into scrolling.
        let base = SettingsSheetMetrics.resolvedSize(textScale: 1, available: nil)
        let larger = SettingsSheetMetrics.resolvedSize(textScale: 1.3, available: nil)

        #expect(base == SettingsSheetMetrics.baseSize)
        #expect(larger.width > base.width)
        #expect(larger.height > base.height)
    }

    /// At the window floor the sheet is clamped to the space it has, in both axes. Whether width
    /// clamps depends on `windowFloor − hostMargin` against `baseSize.width`, so the test derives it.
    @Test func sheetClampsToTheSpaceTheHostHas() {
        let available = Self.windowFloor
        let cramped = SettingsSheetMetrics.resolvedSize(textScale: 1, available: available)
        let roomForWidth = available.width - SettingsSheetMetrics.hostMargin
        let roomForHeight = available.height - SettingsSheetMetrics.hostMargin

        // The invariant, in both axes and whichever way the comparison above goes.
        #expect(cramped.width <= roomForWidth,
                "the sheet is wider than the narrowest window can hold and is not being clamped to it")
        #expect(cramped.height <= roomForHeight,
                "the sheet is taller than the narrowest window and is not being clamped to it")

        // Height always clamps at the floor: the sheet is taller than 512 at every text size.
        #expect(cramped.height == roomForHeight)

        // Width follows the floor, asserted as a derivation so a flip is reported, not failed on.
        if roomForWidth < SettingsSheetMetrics.baseSize.width {
            #expect(cramped.width == roomForWidth,
                    "the floor is narrower than the sheet's natural width and the width clamp is not biting")
        } else {
            #expect(cramped.width == SettingsSheetMetrics.baseSize.width,
                    "the floor leaves room for the sheet's natural width, but it is being clamped anyway")
        }

        // And the width clamp works at a window narrow enough to need it, whatever the floor.
        let narrow = CGSize(width: 700, height: available.height)
        let squeezed = SettingsSheetMetrics.resolvedSize(textScale: 1, available: narrow)
        #expect(squeezed.width == narrow.width - SettingsSheetMetrics.hostMargin)
    }

    @Test func sheetStopsShrinkingAtItsFloor() {
        // Below the floor the rail plus a usable content column stops being possible. The sheet
        // stops shrinking and its content scrolls: overflowing a tiny window beats a sheet too
        // small to use.
        let tiny = SettingsSheetMetrics.resolvedSize(textScale: 1, available: CGSize(width: 200, height: 200))

        #expect(tiny == SettingsSheetMetrics.floorSize)
    }

    @Test func aRoomySpaceLeavesTheSheetAtItsIdealSize() {
        let roomy = SettingsSheetMetrics.resolvedSize(textScale: 1, available: CGSize(width: 1600, height: 1000))

        #expect(roomy == SettingsSheetMetrics.baseSize)
    }

    @Test func theContentOpeningAccountsForTheHeaderAndDivider() {
        #expect(SettingsSheetMetrics.contentOpening(textScale: 1)
                == SettingsSheetMetrics.baseSize.height - SettingsSheetMetrics.headerHeight - 1)
    }

    // MARK: - The rail

    /// The rail fits its opening on a 1280×800 display at every text size, so every tab is reachable
    /// without scrolling. The tabs sit in a `ScrollView`, which accepts any height, so the rail's own
    /// `fittingSize` would pass by construction: this measures `SettingsRail.TabList` against
    /// `SettingsRail.tabListOpening`, with the search field and version line laid out for real.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theRailFitsItsOpening(_ size: FontSize) async throws {
        let margin = tabListMargin(at: size.scale, available: Self.smallDisplayWindow)

        #expect(margin >= 0,
                """
                The tab list overruns its opening by \(-margin)pt on a 1280×800 display at \
                \(size.percent)% — \(SettingsView.SettingsTab.allCases.count) tabs in \
                \(SettingsView.SettingsTab.railGroups.count) groups no longer fit, and the rail \
                has to scroll on the display it is budgeted against.
                """)
    }

    /// The rail at the window's content floor (`windowFloor`), its real worst case. Asserted as the
    /// exact list of sizes that fit, so a change either way fails and the list is updated.
    @MainActor
    @Test func theRailFitsTheWindowFloorAtEveryTextSize() async throws {
        let fitting = FontSize.allCases.filter {
            tabListMargin(at: $0.scale, available: Self.windowFloor) >= 0
        }

        #expect(fitting == FontSize.allCases,
                """
                At the window's own floor (\(Self.windowFloor.width)×\(Self.windowFloor.height)) \
                the tab list fits at \(fitting.map { "\($0.percent)%" }) — the boundary recorded on \
                this test is out of date.
                """)
    }

    /// Where the rail binds, recorded rather than trimmed away: at `floorSize`, for a host smaller
    /// than the main window can be, the tab list overruns at every text size, so the rail scrolls
    /// (`.basedOnSize`) instead of dropping its bottom rows.
    @MainActor
    @Test func theRailIsWhatTheFloorSizedSheetRunsOutOf() async throws {
        // Smaller than `floorSize` in both axes, so `resolvedSize` returns the floor itself.
        let tinyWindow = CGSize(width: 300, height: 300)
        #expect(SettingsSheetMetrics.resolvedSize(textScale: 1, available: tinyWindow)
                == SettingsSheetMetrics.floorSize,
                "this window no longer clamps to the floor — the test has lost its subject")

        let fitting = FontSize.allCases.filter { tabListMargin(at: $0.scale, available: tinyWindow) >= 0 }
        let margins = FontSize.allCases.map { size in
            "\(size.percent)% \(tabListMargin(at: size.scale, available: tinyWindow))pt"
        }

        #expect(fitting.isEmpty,
                """
                At the sheet's floor the tab list now fits at \(fitting.map { "\($0.percent)%" }) with \
                \(SettingsView.SettingsTab.allCases.count) tabs — the residual recorded on this \
                test is out of date. Margins now: \(margins.joined(separator: ", ")).
                """)
    }

    /// The premise the rail tests rest on: the tab list's height is driven by the tab count.
    /// Deleting the `ForEach` in `SettingsRail.TabList` must fail here.
    @MainActor
    @Test func theRailGrowsWithTheTabCount() async throws {
        let measured = tabListHeight(at: 1)
        let rows = CGFloat(SettingsView.SettingsTab.allCases.count)

        // A row is a `.callout` line (13pt) plus 7pt of inset above and below plus the 2pt gap,
        // ~30pt at least. Much less means the rows aren't being laid out as rows.
        #expect(measured >= rows * 30,
                "the tab list lays out at \(measured)pt for \(Int(rows)) tabs — its rows are not being measured.")
    }

    /// Every tab belongs to exactly one group in `railGroups`. The rail's `ForEach` walks the
    /// groups, not `allCases`, so a tab in no group would have a name, symbol, search entries and
    /// content and still be unreachable by clicking.
    @Test func railGroupsCoverEveryTab() {
        let grouped = SettingsView.SettingsTab.railGroups.flatMap { $0 }

        #expect(Set(grouped) == Set(SettingsView.SettingsTab.allCases),
                """
                \(Set(SettingsView.SettingsTab.allCases).subtracting(grouped).map(\.rawValue)) are \
                in the enum but in no rail group, so the rail never draws them.
                """)
        #expect(grouped.count == SettingsView.SettingsTab.allCases.count,
                "a tab appears in more than one rail group: \(grouped.map(\.rawValue))")
        // Rail order is the enum's order; a group list that reordered them would move rows with no
        // other test noticing.
        #expect(grouped == SettingsView.SettingsTab.allCases,
                "the rail's group order no longer matches `allCases` — the rail rows are reordered")
    }

    /// The separators are drawn and cost height. `railGroupsCoverEveryTab` passes against a rail
    /// that ignores the grouping and draws one flat run, so the grouping's cost is measured here.
    @MainActor
    @Test func theGroupSeparatorsAreReallyDrawn() {
        let grouped = tabListHeight(at: 1)
        let flat = laidOutHeight(FlatTabList(), width: SettingsRail.width, scale: 1)

        #expect(grouped > flat,
                """
                The grouped tab list (\(grouped)pt) is no taller than the same rows drawn flat \
                (\(flat)pt) — the separators between `railGroups` are not being drawn.
                """)
    }

    /// The same rows the rail draws, without the group separators, for
    /// `theGroupSeparatorsAreReallyDrawn`. Duplicates `TabList`'s stack rather than adding a flag
    /// to it, which would let the real rail pass with its separators switched off.
    private struct FlatTabList: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsView.SettingsTab.allCases, id: \.self) { tab in
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbolName).frame(width: 16).scaledFont(.callout)
                        Text(tab.displayName).scaledFont(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                }
            }
            .frame(width: SettingsRail.width, alignment: .leading)
        }
    }

    /// The version line fits the fixed-width, non-scrolling rail. It has no `lineLimit`, so a string
    /// too wide wraps, growing the rail and splitting "SyncCloud" from its number. The intrinsic
    /// width says how close to the edge it is; the rail height says whether it wrapped.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theVersionLineFitsTheRailOnOneLine(_ size: FontSize) async throws {
        let line = Text("SyncCloud \(Self.versionMarker)").scaledFont(.caption2)
        let intrinsic = laidOutWidth(line, scale: size.scale)

        #expect(intrinsic <= SettingsRail.versionTextWidth,
                """
                "SyncCloud \(Self.versionMarker)" wants \(intrinsic)pt at \(size.percent)% in \
                a \(SettingsRail.versionTextWidth)pt column — the rail is fixed-width and does \
                not scroll, so the line wraps onto a second row.
                """)

        // The symptom: a wrap adds one bare `.caption2` line over a one-character baseline; under
        // half of that is layout jitter. Not an equality: the search field's height varies under load.
        let unwrapped = railHeight(at: size.scale, version: "1")
        let oneLine = versionLineHeight(at: size.scale)
        let extra = railHeight(at: size.scale) - unwrapped

        #expect(extra < oneLine / 2,
                """
                At \(size.percent)% the rail is \(extra)pt taller with "\(Self.versionMarker)" \
                than with a one-character version, and a line of this type is \(oneLine)pt — the \
                version line has wrapped onto a second row.
                """)
    }

    /// Keeps `theVersionLineFitsTheRailOnOneLine` from going vacuous: a marker too wide must clear
    /// the same `oneLine / 2` threshold from the other side, or the height check passes for any string.
    @MainActor
    @Test func aVersionTooWideForTheRailReallyDoesWrapIt() async throws {
        let overlong = "9.9-dev-and-then-some"
        #expect(laidOutWidth(Text("SyncCloud \(overlong)").scaledFont(.caption2), scale: 1)
                > SettingsRail.versionTextWidth,
                "the probe no longer overflows the column — it has stopped probing anything")

        let unwrapped = railHeight(at: 1, version: "1")
        let oneLine = versionLineHeight(at: 1)
        let extra = railHeight(at: 1, version: overlong) - unwrapped

        #expect(extra >= oneLine / 2,
                """
                A version far too wide for the rail adds only \(extra)pt to it against a \
                \(oneLine)pt line — `fittingSize.height` is not seeing the wrap, so the height \
                half of `theVersionLineFitsTheRailOnOneLine` proves nothing.
                """)
    }

    /// The seam: the version line renders because `versionText` says so. Re-inlining the
    /// `Bundle.main` read into `body` would leave both tests above green, measuring a rail with no
    /// version line in a host that has no version.
    @MainActor
    @Test func theRailDrawsNoVersionLineWithoutOne() async throws {
        #expect(railHeight(at: 1, version: nil) < railHeight(at: 1),
                """
                The rail is the same height with and without a version — `versionText` is not \
                what puts the line on screen, so injecting it measures nothing.
                """)
    }

    /// What a wrap costs: one bare `.caption2` line, without the rail's padding. With the padding in,
    /// half the threshold would sit inside the couple of points the search field varies by under
    /// load, and a real wrap could read as none (`docs/flaky-tests.md`).
    @MainActor
    private func versionLineHeight(at scale: CGFloat) -> CGFloat {
        laidOutHeight(Text("SyncCloud 1").scaledFont(.caption2),
                      width: SettingsRail.versionTextWidth, scale: scale)
    }

    /// The rail as the app lays it out, including the version line, which the test host can't
    /// produce and is therefore injected.
    @MainActor
    private func railHeight(at scale: CGFloat, version: String? = Self.versionMarker) -> CGFloat {
        let rail = SettingsRail(selection: .constant(.general), query: .constant(""),
                                hue: .blue, versionText: version)
        return laidOutHeight(rail, width: SettingsRail.width, scale: scale)
    }

    /// The tab rows' own height, which the rail's scroller keeps `railHeight` from reporting. Laid
    /// out at the rail's real width, since the rows are fixed to it.
    @MainActor
    private func tabListHeight(at scale: CGFloat) -> CGFloat {
        let list = SettingsRail.TabList(selection: .constant(.general), query: .constant(""),
                                        hue: .blue)
        return laidOutHeight(list, width: SettingsRail.width, scale: scale)
    }

    /// How much room the tab list has left in a given window; positive means every tab is
    /// reachable without scrolling. The search field and version line are measured, not estimated,
    /// because a hand-estimated allowance can be wrong in either direction.
    @MainActor
    private func tabListMargin(at scale: CGFloat, available: CGSize) -> CGFloat {
        let searchField = laidOutHeight(SettingsSearchField(query: .constant("")),
                                        width: SettingsRail.versionTextWidth, scale: scale)
        let versionLine = laidOutHeight(Text("SyncCloud \(Self.versionMarker)").scaledFont(.caption2)
                                            .padding(.top, 8).padding(.bottom, 2),
                                        width: SettingsRail.versionTextWidth, scale: scale)
        // The premise: both really laid out. A zero would silently inflate every margin.
        #expect(searchField > 0 && versionLine > 0,
                "the rail's search field or version line measured 0pt — this margin is fiction")

        let opening = SettingsRail.tabListOpening(
            in: SettingsSheetMetrics.contentOpening(textScale: scale, available: available),
            searchFieldHeight: searchField,
            versionLineHeight: versionLine)
        return opening - tabListHeight(at: scale)
    }

    @Test func everyTabHasARailSymbol() {
        // A tab without a symbol would render an empty slot rather than fail to build: SF Symbol
        // names are strings.
        for tab in SettingsView.SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil) != nil,
                    "\(tab.rawValue) has no SF Symbol named \(tab.symbolName)")
        }
    }

    // MARK: The widest segmented row

    /// Readability's text size row (`SizePresetRow`) fits the narrowest column the sheet can offer,
    /// or its labels truncate. Measured unconstrained (`fittingSize`), so the number is what the
    /// control wants, not what a frame told it.
    @MainActor
    @Test func theTextSizeRowFitsTheNarrowestColumnTheSheetCanOffer() {
        // `floorSize` is where the sheet stops shrinking, so this window produces the narrowest
        // column that can ever exist.
        let tinyWindow = CGSize(width: SettingsSheetMetrics.floorSize.width
                                    + SettingsSheetMetrics.hostMargin,
                                height: SettingsSheetMetrics.floorSize.height
                                    + SettingsSheetMetrics.hostMargin)
        let column = SettingsSheetMetrics.contentWidth(textScale: 1, available: tinyWindow)
        // The premise: this really is the floored column, not the roomy unclamped one.
        #expect(column < SettingsSheetMetrics.contentWidth(textScale: 1),
                "the fixture window did not clamp the sheet — this would measure the easy case")
        let available = column - 2 * SettingsSheetMetrics.pagePaddingH

        // Measured at the largest size: the preset row is SwiftUI-drawn and grows with the text
        // size it sets, so the worst case a user can reach is the one to measure.
        let wanted = laidOutSizePresetRowWidth(at: .extraLarge)
        #expect(wanted > 0, "the row laid out to nothing — the fixture measured no control")

        // The row shrinks its labels rather than truncating them, so the bar is that the ideal
        // width fits once the labels use their allowed scaling (`SizePresetRow.minimumLabelScale`).
        // The ideal alone would fail a control that renders fine.
        let floor = wanted * SizePresetRow.minimumLabelScale
        #expect(floor <= available,
                """
                The size preset row wants \(wanted)pt at \(FontSize.extraLarge.percent)% and can \
                shrink to \(floor)pt, but the floored content column offers only \(available)pt \
                — its tile labels will truncate.
                """)
    }

    /// A segmented picker's width doesn't follow the app's text size: `NSSegmentedControl` ignores
    /// the SwiftUI font, even an explicit `.font(.system(size: 24))`. Only `controlSize` moves it,
    /// and the tab doesn't set one. The Row spacing picker relies on this; the preset row doesn't
    /// have it, which is why the fit test above measures at the largest size.
    @MainActor
    @Test func theSegmentedRowSpacingWidthDoesNotFollowTheAppTextSize() {
        let sizes = Set(FontSize.allCases.map { laidOutRowSpacingPickerWidth(at: $0) })
        #expect(sizes.count == 1,
                """
                The Row spacing picker now measures \(sizes.sorted()) across the four named text \
                sizes. It used to be font-invariant — anything measuring it at one size has to be \
                re-measured at \(FontSize.extraLarge.percent)%.
                """)
        // The fixture can see a font change, so the agreement above is the control's, not the
        // harness's: a plain Text through the same path grows.
        let plain = { (size: FontSize) -> CGFloat in
            let host = NSHostingView(rootView: Text("Comfortable Compact").appFontSize(size))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        #expect(plain(.extraLarge) > plain(.medium) + 5,
                "the fixture does not scale anything at all — the invariance above proves nothing")
    }

    /// A stored size outside the selectable range never reaches the slider. Asserts what the
    /// slider is fed, not what `FontSize` would clamp to, which holds whatever the control does;
    /// reverting the getter to the raw stored value must fail.
    @MainActor
    @Test func aStoredSizeOutsideTheRangeIsClampedBeforeItReachesTheControls() async throws {
        for stored in [-40, 0, 89, 200, 10_000] {
            let test = TestDefaults("out-of-range-\(stored)")
            test.defaults.set(stored, forKey: FontSize.defaultsKey)

            let fed = ReadabilitySettingsTab.sliderValue(forStored: stored)
            #expect(fed >= Double(FontSize.minimumPercent),
                    "the slider is fed \(fed) for a stored \(stored) — below its own range")
            #expect(fed <= Double(FontSize.maximumPercent),
                    "the slider is fed \(fed) for a stored \(stored) — above its own range")

            // And the tab lays out rather than trapping or measuring nothing on such a value.
            let height = laidOutHeight(
                ReadabilitySettingsTab().defaultAppStorage(test.defaults), width: Self.contentWidth)
            #expect(height > 0, "Readability laid out to nothing with \(stored) stored")
        }

        // The write direction too: a slider position never stores a value outside the range.
        for position in [-10.0, 89.4, 137.6, 5_000] {
            let stored = ReadabilitySettingsTab.storedValue(forSlider: position)
            #expect(stored >= FontSize.minimumPercent && stored <= FontSize.maximumPercent,
                    "a slider at \(position) stored \(stored)")
        }
    }

    /// The slider actually uses the clamping seam. The pure functions above would keep passing if
    /// the closure went back to reading `@AppStorage` raw.
    @Test func theSliderReadsAndWritesThroughTheClamp() throws {
        let source = try settingsSource("SettingsView.swift")

        let tab = try #require(source.range(of: "struct ReadabilitySettingsTab"))
        let body = String(source[tab.lowerBound...])

        #expect(body.contains("get: { Self.sliderValue(forStored: fontSizePercent) }"),
                "the text-size slider no longer reads through sliderValue(forStored:)")
        #expect(body.contains("set: { fontSizePercent = Self.storedValue(forSlider: $0) }"),
                "the text-size slider no longer writes through storedValue(forSlider:)")
    }

    /// The preset row follows the app's text size, the premise the fit test leans on; otherwise
    /// `theTextSizeRowFitsTheNarrowestColumn…` at Largest would measure the Default number.
    @MainActor
    @Test func thePresetRowGrowsWithTheTextSizeItSets() {
        let small = laidOutSizePresetRowWidth(at: .small)
        let largest = laidOutSizePresetRowWidth(at: .extraLarge)
        #expect(largest > small,
                """
                The preset row measured \(small)pt and \(largest)pt — it is not scaling, so the \
                fit test's worst case is not a worst case.
                """)
    }

    /// Readability's Row spacing row as it ships (labels hidden, the app accent on the selection),
    /// laid out at `size` with no width constraint.
    @MainActor
    private func laidOutRowSpacingPickerWidth(at size: FontSize) -> CGFloat {
        struct RowSpacingRow: View {
            @State private var raw = ListDensity.comfortable.rawValue
            var body: some View {
                Picker("Row spacing", selection: $raw) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.displayName).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(.blue)
            }
        }
        let host = NSHostingView(rootView: RowSpacingRow().appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Readability's size preset row as it ships (five tiles, the named style), laid out at `size`
    /// with no width constraint.
    @MainActor
    private func laidOutSizePresetRowWidth(at size: FontSize) -> CGFloat {
        struct PresetRow: View {
            @State private var fontSize = FontSize.medium
            @State private var density = ListDensity.comfortable
            var body: some View {
                SizePresetRow(fontSize: $fontSize, density: $density, style: .named)
            }
        }
        let host = NSHostingView(rootView: PresetRow().appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
}
