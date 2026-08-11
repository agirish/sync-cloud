import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import Settings

/// Pins the promise the sidebar layout was built to keep: the Appearance tab fits its opening
/// without scrolling, and the sheet never outgrows the window it is centered in.
///
/// The height is measured from the LAID-OUT view (`NSHostingView.fittingSize`), not computed
/// from the constants that feed it — the constants agreeing with each other proves nothing about
/// what SwiftUI actually lays out. The shipped grouped-Form version measured 884pt into a 436pt
/// opening, which is how a control ended up cut in half by the sheet's bottom edge.
///
/// Appearance carries the detailed budget — it is the tab that motivated the change and the
/// tallest one that can be made to fit (`appearanceIsTheTallestTabThatMustFit`), and it reads
/// nothing but `@AppStorage`, so its height is a property of the layout rather than of the
/// machine's data. But it is no longer the only tab with a fit assertion: the sheet shrank 58pt
/// for every tab, so General, Sync, Organize, Duplicates and Advanced are checked too
/// (`everyMustFitTabFitsTheClampedOpening`).
///
/// Three tabs are excluded, for reasons that are properties of those tabs: Providers grows with
/// the Mac's provider list and People with the household roster, and Intelligence is long by
/// nature and expected to scroll — see `intelligenceLaysOutWithoutReachingForTheKeychain`, which
/// is here for a different reason again. General was previously excluded as well, on the grounds
/// that it "reaches for SMAppService on appear, which a `swift test` host can block on".
/// Measured, that does not bite in this harness: the reads are in `.task`, which an offscreen
/// `NSHostingView` driven only by `layoutSubtreeIfNeeded` never fires. It is measured here like
/// the rest.
///
/// The RAIL is measured as well (`theRailFitsItsOpening`). It shares the tabs' opening but is
/// sized by the tab COUNT rather than by any tab's contents, so every assertion above is blind
/// to it — which is exactly how Tidy could split into two rail rows without a single test moving.
/// Since the rail gained a scroller, what that test measures is `SettingsRail.TabList` rather
/// than the rail itself; the reason is on the test.
@Suite struct SettingsLayoutTests {

    /// The content column: the sheet minus the rail and the divider between them.
    private static var contentWidth: CGFloat {
        SettingsSheetMetrics.contentWidth(textScale: 1)
    }

    @MainActor
    private func laidOutHeight(_ view: some View, width: CGFloat, scale: CGFloat = 1) -> CGFloat {
        // The text scale is pinned rather than inherited: `scaledFont` reads it from the
        // environment, so an unpinned measurement would silently report whatever text size the
        // machine running the test happens to have set.
        let host = NSHostingView(rootView: view.environment(\.appFontScale, scale).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The width a view wants when nothing constrains it — its intrinsic width. Deliberately
    /// unconstrained, unlike `laidOutHeight`: the question is how wide the text WANTS to be, so
    /// that it can be compared against the column it has to fit in. Constraining it first would
    /// make the measurement agree with the constraint no matter how wide the text was.
    @MainActor
    private func laidOutWidth(_ view: some View, scale: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, scale))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The margin Appearance has left at one text size — positive means it fits.
    @MainActor
    private func appearanceMargin(at scale: CGFloat) -> CGFloat {
        let height = laidOutHeight(AppearanceSettingsTab(),
                                   width: SettingsSheetMetrics.contentWidth(textScale: scale),
                                   scale: scale)
        return SettingsSheetMetrics.contentOpening(textScale: scale) - height
    }

    /// A 1280×800-class display's window, spelled out so the fixture is an argument rather than
    /// a magic number: an 800pt-tall screen loses 24pt to the menu bar and ~36pt to the window's
    /// title bar, leaving ~740pt of window content — which is what `ContentView.settingsOverlay`'s
    /// `GeometryReader` hands to `SettingsView` as `availableSize`.
    ///
    /// **The Dock is deliberately excluded, and that limits what every test using this can
    /// claim.** With a default bottom Dock (~75pt) the window is ~665pt, the opening ~572pt, and
    /// Appearance's 634pt tab scrolls even at the default text size. So what is pinned here is
    /// "a 1280×800 display with the Dock hidden or side-parked", not "a 1280×800 display".
    /// Trimming the tab for the smallest configuration conceivable was rejected — the fix for a
    /// bottom-Dock user is the scroll fallback, which `residualOverflowIsAbsorbedByScrolling`
    /// checks degrades gracefully.
    private static let smallDisplayWindow = CGSize(width: 1280, height: 800 - 24 - 36)

    /// The window's own content floor — `ContentView`'s `.frame(minWidth: 760, minHeight: 560)`,
    /// which `.windowResizability(.contentMinSize)` makes the smallest window there is. Repeated
    /// as a literal because the Settings module cannot see `MacApp`; the same arrangement
    /// `sheetClampsToTheSpaceTheHostHas` has always used, and the direction is safe — a floor
    /// raised in `ContentView` without updating this only ever gives the sheet more room.
    private static let windowFloor = CGSize(width: 760, height: 560)

    /// The version string this branch's builds actually carry, mirroring `project.yml`'s
    /// `CFBundleShortVersionString`. Kept in step by the release procedure in `CLAUDE.md`, which
    /// makes updating it part of cutting a release.
    ///
    /// It is written down rather than read from `Bundle.main` because under `swift test`
    /// `Bundle.main` is the test host and has no version at all — the very blindness that let
    /// the app ship "1.0" for twenty-odd releases with a green suite. A literal that a human
    /// must change is the point: it is what gives `theVersionLineFitsTheRailOnOneLine` something
    /// real to measure.
    private static let versionMarker = "4.0-dev"

    /// The margin Appearance has left at one text size against a chosen accent hue, measured
    /// through the tab's own `@AppStorage` via `.defaultAppStorage` — `UserDefaults.standard` is
    /// never touched, so nothing is inherited from the machine or from a neighbouring test.
    @MainActor
    private func appearanceMargin(hue: LiquidGlassHue,
                                  at scale: CGFloat,
                                  available: CGSize? = nil) -> CGFloat {
        let test = TestDefaults("hue-\(hue.rawValue)-\(scale)")
        defer { test.wipe() }
        test.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)

        let height = laidOutHeight(AppearanceSettingsTab().defaultAppStorage(test.defaults),
                                   width: SettingsSheetMetrics.contentWidth(textScale: scale, available: available),
                                   scale: scale)
        return SettingsSheetMetrics.contentOpening(textScale: scale, available: available) - height
    }

    @MainActor
    @Test func appearanceFitsItsOpeningWithoutScrolling() async throws {
        let height = laidOutHeight(AppearanceSettingsTab(), width: Self.contentWidth)
        let opening = SettingsSheetMetrics.contentOpening(textScale: 1)

        #expect(height <= opening,
                "Appearance lays out at \(height)pt in a \(opening)pt opening — it scrolls again.")
    }

    /// The early warning the flat "does it fit" check can't give: a caption gaining one line is
    /// ~15pt, so a tab sitting 5pt under its opening is one copy edit from scrolling. If this
    /// trips, either trim the tab or raise `SettingsSheetMetrics.baseSize.height` deliberately.
    @MainActor
    @Test func appearanceKeepsRoomForACopyEdit() async throws {
        let margin = appearanceMargin(at: 1)

        #expect(margin >= 15, "Only \(margin)pt of slack left below the last control.")
    }

    /// The UPPER bound on `baseSize` — the half of the 1280×800 fix that nothing pinned.
    ///
    /// `appearanceFitsA1280x800Display` cannot see this constant: on that fixture window both
    /// the old 758 and the new 700 clamp to the same 692pt sheet, so the clamped opening is
    /// identical either way and only the tab's chrome trims are guarded there. Reverting
    /// `baseSize` to 758 left the whole suite green.
    ///
    /// `baseSize`'s own comment says the height is "chosen against a measurement, not a round
    /// number": the opening clears the tallest must-fit tab with room for a copy edit and *no
    /// more*. A lower bound alone (`appearanceKeepsRoomForACopyEdit`) only makes that half a
    /// sentence — it is satisfied by any sheet large enough, including one so large it overflows
    /// the displays real people use. 758 carried 79pt of dead air over a 634pt tab, and that
    /// dead air is exactly what pushed the sheet past a 1280×800 ceiling.
    ///
    /// Two copy edits of slack is the limit. Past that the sheet is being sized by a round
    /// number again, and the right response is to lower `baseSize` — not to widen this bound.
    @MainActor
    @Test func theSheetIsSizedAgainstTheTallestTabItMustFit() async throws {
        let margin = appearanceMargin(at: 1)

        #expect(margin <= 30,
                "The opening carries \(margin)pt over Appearance's laid-out height — baseSize has stopped being sized against that measurement.")
    }

    /// The fit at EVERY text size, not just the default — the gap that let the clipping this
    /// layout was built to fix come back.
    ///
    /// A tab's height is not proportional to the text scale: only the type scales, while the
    /// padding, spacing and control heights are fixed points. So a sheet scaled by the full
    /// `FontSize.scale` shrinks faster than its contents do. At Small (0.9) the sheet gave up 69pt
    /// of opening while Appearance gave back 12, and the tab measured 592pt into 578.6 — the last
    /// control cut in half, exactly the failure the rail replaced a grouped `Form` to stop.
    /// `resolvedSize` floors the scale at 1 for that reason; this is what proves it.
    ///
    /// Asserted per size rather than at the extremes: the two ends are not the only rungs, and a
    /// failure names which one broke.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func appearanceFitsEveryTextSize(_ size: FontSize) async throws {
        let margin = appearanceMargin(at: size.scale)

        #expect(margin >= 15,
                "Appearance has \(margin)pt of slack at \(size.displayName) (scale \(size.scale)).")
    }

    /// The fit against a SMALL display's CLAMPED opening — the assertion whose absence let the
    /// 688 → 758 raise ship a regression: every other fit test here passes `available: nil`, so
    /// the sheet they measure against grows in lockstep with `baseSize` and no raise can ever
    /// fail them. On a 1280×800-class display the sheet cannot grow; `resolvedSize` clamps it to
    /// the window, and at 758 the Appearance tab (674pt) scrolled inside the ~647pt opening that
    /// clamp produces. This is the upper bound: however `baseSize` moves, the tab must fit the
    /// opening a small display can actually give it.
    ///
    /// The arithmetic, spelled out so the fixture is an argument rather than a magic number:
    /// an 800pt-tall screen loses 24pt to the menu bar and ~36pt to the window's title bar,
    /// leaving ~740pt of window content — which is what `ContentView.settingsOverlay`'s
    /// `GeometryReader` hands to `SettingsView` as `availableSize`. `resolvedSize` then keeps
    /// `hostMargin` (48pt) of air around the sheet, and the opening loses the title row and its
    /// divider. Dock excluded deliberately: hidden or side-parked docks are common on 800pt
    /// panels, and a bottom dock only shrinks the window further — the fix for that user is the
    /// scroll fallback, not a sheet trimmed for the smallest configuration conceivable.
    @MainActor
    @Test func appearanceFitsA1280x800Display() async throws {
        let window = Self.smallDisplayWindow
        let opening = SettingsSheetMetrics.contentOpening(textScale: 1, available: window)
        // The premise that gives this test teeth: the small display genuinely clamps the sheet,
        // so this opening is NOT the unclamped one every other fit test measures against.
        #expect(opening < SettingsSheetMetrics.contentOpening(textScale: 1),
                "a 1280×800 window no longer clamps the sheet — this test has lost its subject")

        let width = SettingsSheetMetrics.contentWidth(textScale: 1, available: window)
        let height = laidOutHeight(AppearanceSettingsTab(), width: width)

        #expect(height <= opening,
                "Appearance lays out at \(height)pt but a 1280×800 display's clamped opening is \(opening)pt — it scrolls on small screens.")
    }

    /// Every accent hue, because the caption is part of the layout and one hue's is longer.
    ///
    /// `AppearanceSettingsTab` reads the hue from `@AppStorage` defaulting to `.blue`, so every
    /// other fit test in this file measures the SHORT caption. `.none` needs a sentence of its
    /// own — a swatch labelled "None" over a visibly coloured button has to explain itself — and
    /// at 121 characters that sentence wrapped to a second line, ~13pt the tab did not have. It
    /// put a `.none` user's tab at exactly its clamped opening, zero margin, and no test could
    /// see it: the caption and the sheet-fitting work landed thirty seconds apart, neither aware
    /// of the other.
    ///
    /// Parameterised over `allCases` rather than pinning `.none` as "the worst case", so a
    /// future hue with a long `displayName` is covered by construction. Over the raw VALUES
    /// because `LiquidGlassHue` is not `Sendable` and so cannot cross into a test argument;
    /// resolving it inside keeps a failure naming the hue that broke.
    @MainActor
    @Test(arguments: LiquidGlassHue.allCases.map(\.rawValue))
    func appearanceFitsEveryAccentHue(_ rawValue: String) async throws {
        let hue = try #require(LiquidGlassHue(rawValue: rawValue))

        let margin = appearanceMargin(hue: hue, at: 1)
        #expect(margin >= 15,
                "Appearance has \(margin)pt of slack with the \(rawValue) accent — its caption is costing a line.")

        let clamped = appearanceMargin(hue: hue, at: 1, available: Self.smallDisplayWindow)
        #expect(clamped >= 0,
                "Appearance overflows a 1280×800 display's clamped opening by \(-clamped)pt with the \(rawValue) accent.")
    }

    /// The clamped opening at every TEXT SIZE — the case `appearanceFitsEveryTextSize` cannot
    /// cover, because it passes `available: nil` and so measures Larger against a 910pt sheet
    /// that a 1280×800 display can never produce. That is vacuous for exactly the configuration
    /// the clamped-opening work was about.
    ///
    /// **The honest measured result, and the one place the residual is recorded.** On a 1280×800
    /// display (Dock hidden or side-parked, per `smallDisplayWindow`) Appearance fits at Small
    /// and at the Default text size, and does NOT fit at Large (~10pt over) or Larger (~55pt
    /// over). This is a floor, not a bug to trim away: the sheet is capped at ~692pt by the
    /// display while the tab's type grows 15–30%, so closing a 55pt gap would mean deleting
    /// controls, and both of the alternatives are worse — a sheet sized for this case would
    /// carry dead air on every normal display (which is the defect `baseSize` was just bounded
    /// against), and `floorSize` cannot help because the clamp comes from the window, not the
    /// floor. Large text on a small display genuinely has less room; scrolling is the correct
    /// degradation and `SettingsPage` already does it.
    ///
    /// Written as a boundary rather than a one-sided assertion so it stays honest in both
    /// directions: if a trim ever makes Large fit, this fails and asks for the note above to be
    /// updated, and if Default ever stops fitting it fails loudly.
    @MainActor
    @Test func theClampedOpeningFitsTheSmallerTextSizesOnly() async throws {
        let fitting = FontSize.allCases.filter { size in
            let height = laidOutHeight(AppearanceSettingsTab(),
                                       width: SettingsSheetMetrics.contentWidth(textScale: size.scale,
                                                                                available: Self.smallDisplayWindow),
                                       scale: size.scale)
            return height <= SettingsSheetMetrics.contentOpening(textScale: size.scale,
                                                                 available: Self.smallDisplayWindow)
        }

        #expect(fitting == [.small, .medium],
                "Appearance fits a 1280×800 display at \(fitting.map(\.displayName)) — the residual recorded on this test is out of date.")
    }

    /// The residual degrades by SCROLLING, not by clipping — the thing a fit test cannot say.
    ///
    /// `SettingsPage` is a `ScrollView`, so content taller than its opening scrolls. What could
    /// still go wrong is the sheet itself outgrowing the window, which would put the overflow
    /// behind the screen edge where no scroll gesture reaches it. `resolvedSize` is what
    /// prevents that, at every text size, on the display where the overflow actually happens.
    @Test func residualOverflowIsAbsorbedByScrolling() {
        for size in FontSize.allCases {
            let sheet = SettingsSheetMetrics.resolvedSize(textScale: size.scale,
                                                          available: Self.smallDisplayWindow)

            #expect(sheet.height <= Self.smallDisplayWindow.height,
                    "at \(size.displayName) the sheet is \(sheet.height)pt in a \(Self.smallDisplayWindow.height)pt window — the overflow is off-screen, not scrollable.")
            #expect(sheet.width <= Self.smallDisplayWindow.width)
            #expect(SettingsSheetMetrics.contentOpening(textScale: size.scale,
                                                        available: Self.smallDisplayWindow) > 0,
                    "at \(size.displayName) the title row has eaten the whole sheet.")
        }
    }

    /// The rule the case above rests on, stated directly so a regression names the cause rather
    /// than only the symptom: the sheet grows with the text setting and never shrinks below its
    /// base size.
    @Test func theSheetNeverShrinksBelowItsBaseSize() {
        for size in FontSize.allCases {
            let resolved = SettingsSheetMetrics.resolvedSize(textScale: size.scale, available: nil)

            #expect(resolved.width >= SettingsSheetMetrics.baseSize.width)
            #expect(resolved.height >= SettingsSheetMetrics.baseSize.height,
                    "\(size.displayName) shrank the sheet to \(resolved.height)pt.")
        }
    }

    /// Intelligence is long by nature (four sections, from the on-device toggles to the saved
    /// suggestions) and is expected to scroll, so there is no fit to assert. What this pins is
    /// that it can be laid out AT ALL: it used to read the Anthropic key out of the Keychain in
    /// `onAppear`, which blocked this host — and, in the app, put a password prompt on screen for
    /// anyone who merely opened the tab. If that read comes back, this test stops finishing.
    ///
    /// **It follows `CloudKeyRow`, and `CloudKeyRow` has now moved twice** — onto the Organize tab
    /// when Tidy split, and onto Intelligence when Organize did. This is still the tab with a
    /// Keychain call one `onAppear` away, and the hazard got slightly larger with the move: the
    /// row is drawn unconditionally here (disabled when the cloud toggles are off) rather than
    /// only when cloud filing is switched on, so its `onAppear` now runs for every visitor to the
    /// tab rather than only for users who had already opted in. `AnthropicKeychain.isConfigured`
    /// is an existence check that never reads the secret, which is what makes that safe — and
    /// this test is what would notice if it stopped being.
    @MainActor
    @Test func intelligenceLaysOutWithoutReachingForTheKeychain() async throws {
        let height = laidOutHeight(IntelligenceSettingsTab(syncManager: nil), width: Self.contentWidth)

        #expect(height > 0)
    }

    // MARK: - The other tabs

    /// The tabs that must fit, and the height each lays out at. Appearance is measured by the
    /// tests above; these three were never measured at all.
    ///
    /// Three tabs are absent for reasons that are properties of those tabs rather than oversights:
    /// Providers grows with the Mac's provider list and People with the household roster, so both
    /// heights are properties of the machine's data; and Intelligence is long by nature and is
    /// expected to scroll (see `intelligenceLaysOutWithoutReachingForTheKeychain`).
    ///
    /// Duplicates joined the list when it split off Tidy: three `@AppStorage` rows and a caption,
    /// so its height is a property of the layout like Appearance's, and nothing about it excuses
    /// it from fitting.
    ///
    /// **Organize joined it when the engine and the roster moved out.** It was excluded as "long
    /// by nature and expected to scroll", and that was true of the five-section tab; what is left
    /// is an inbox path, a signpost row and the kept-names list, which with no engine attached is
    /// a fixed note. That is a layout-shaped height, so it is measured like the rest — and the
    /// exclusion had to be revisited rather than inherited, because a tab that gets SHORTER keeps
    /// its exemption silently and no test ever asks again.
    @MainActor
    private func mustFitTabs(_ settings: SettingsManager) -> [(String, AnyView)] {
        [("General", AnyView(GeneralSettingsTab().environmentObject(settings))),
         ("Appearance", AnyView(AppearanceSettingsTab())),
         ("Sync", AnyView(SyncSettingsTab(syncManager: nil).environmentObject(settings))),
         ("Organize", AnyView(FilingSettingsTab(syncManager: nil))),
         ("Duplicates", AnyView(DuplicatesSettingsTab())),
         ("Advanced", AnyView(AdvancedSettingsTab(syncManager: nil, onResetAllSettings: nil)))]
    }

    /// EVERY tab that must fit, against the opening a 1280×800 display actually gives.
    ///
    /// The gap this closes: the suite asserted a fit for Appearance alone, while the 758 → 700
    /// change shrank the opening by 58pt for all six tabs. The chrome trims gave each tab back
    /// only ~18–26pt of that, so every other tab came out a net 32–40pt WORSE off than before —
    /// and if Sync or Advanced had been within that of its old opening it would now scroll with
    /// nothing to say so. (Measured, they are not: Sync and Advanced sit far under. That is the
    /// answer this test exists to keep true, not a reason it was unnecessary.)
    @MainActor
    @Test func everyMustFitTabFitsTheClampedOpening() async throws {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false,
                                       userDefaults: test.defaults,
                                       cloudStorageLister: { [] })
        let opening = SettingsSheetMetrics.contentOpening(textScale: 1, available: Self.smallDisplayWindow)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1, available: Self.smallDisplayWindow)

        for (name, tab) in mustFitTabs(settings) {
            let height = laidOutHeight(tab, width: width)

            #expect(height <= opening,
                    "\(name) lays out at \(height)pt in a 1280×800 display's \(opening)pt opening — it scrolls.")
        }
    }

    /// The claim `SettingsSheetMetrics.baseSize` is derived from — "Appearance is the tallest tab
    /// that can be made to fit" — stated as an assertion rather than a comment.
    ///
    /// It is load-bearing for the whole sizing argument: every bound on `baseSize` is measured
    /// against Appearance, so if some other must-fit tab were taller, the sheet would be sized
    /// against the wrong tab and that tab would scroll while all the fit tests stayed green.
    @MainActor
    @Test func appearanceIsTheTallestTabThatMustFit() async throws {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false,
                                       userDefaults: test.defaults,
                                       cloudStorageLister: { [] })
        let appearance = laidOutHeight(AppearanceSettingsTab(), width: Self.contentWidth)

        for (name, tab) in mustFitTabs(settings) where name != "Appearance" {
            let height = laidOutHeight(tab, width: Self.contentWidth)

            #expect(height <= appearance,
                    "\(name) lays out at \(height)pt, taller than Appearance's \(appearance)pt — baseSize is being sized against the wrong tab.")
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

    @Test func sheetClampsToTheSpaceTheHostHas() {
        // The window's own minimum is 760×560 — narrower than the sheet wants at any text size
        // once `hostMargin` is taken off — so an unclamped sheet would hang off the edge of a
        // small window. The fixture is that floor rather than a smaller invented one: a window
        // this size is reachable, and the clamp still bites there.
        let available = Self.windowFloor
        let cramped = SettingsSheetMetrics.resolvedSize(textScale: 1, available: available)

        #expect(cramped.width == available.width - SettingsSheetMetrics.hostMargin)
        #expect(cramped.height == available.height - SettingsSheetMetrics.hostMargin)
    }

    @Test func sheetStopsShrinkingAtItsFloor() {
        // Below the floor the rail plus a usable content column stops being possible. The sheet
        // stops shrinking and its content scrolls instead — overflowing a tiny window is better
        // than a sheet too small to use.
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

    /// The RAIL has to fit too — the half of the sheet every other test here is blind to.
    ///
    /// Every fit assertion above measures a tab against `contentOpening`, which is the height of
    /// the column beside the rail. The rail sits in the same opening and is sized by a completely
    /// different thing: one row per `SettingsTab` at ~33pt each, plus a hairline between each pair
    /// of `railGroups`. Splitting Tidy into Organize and Duplicates took it from six rows to
    /// seven, and no test could see that — the content column did not change height by one point,
    /// so the whole suite stayed green while the rail grew.
    ///
    /// **What this measures changed when the rail gained a scroller.** The tabs now sit in a
    /// `ScrollView` (`.basedOnSize`, so it sits still whenever it fits), which accepts whatever
    /// height it is offered — so `SettingsRail`'s own `fittingSize` can no longer answer "do the
    /// tabs fit?" and an assertion resting on it would pass by construction forever. What is
    /// measured instead is `SettingsRail.TabList` — the rows outside the scroller — against
    /// `SettingsRail.tabListOpening`, the space between the search field and the version line.
    /// Both of those are laid out for real rather than allowed for; see `tabListMargin`.
    ///
    /// The claim is therefore no longer "the rail is not clipped" (the scroller guarantees that)
    /// but the stronger and more useful one: **on the display the tabs are budgeted against, every
    /// tab is reachable without scrolling at all.** A rail that has to scroll on a 1280×800 screen
    /// is a rail that has outgrown the design, and that is what this fails on.
    ///
    /// Measured against the SMALL display's clamped opening for the same reason
    /// `appearanceFitsA1280x800Display` exists — an unclamped opening grows with `baseSize` and
    /// so can never fail. At every text size, because the rows are text and grow with it.
    ///
    /// **The measured residual.** Nine rows and three group separators come to 312pt at the
    /// default text size against a 559pt tab-list opening — 247pt of slack, room for roughly
    /// seven more tabs. (Small 269pt, Large 223pt, Larger 191pt: the margin narrows with the text
    /// size, as it should, and none of the four is close.) The rail is nowhere near its ceiling on
    /// the display it is budgeted against; where it DOES bind is the sheet's own floor —
    /// `theRailIsWhatTheFloorSizedSheetRunsOutOf`.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theRailFitsItsOpening(_ size: FontSize) async throws {
        let margin = tabListMargin(at: size.scale, available: Self.smallDisplayWindow)

        #expect(margin >= 0,
                """
                The tab list overruns its opening by \(-margin)pt on a 1280×800 display at \
                \(size.displayName) — \(SettingsView.SettingsTab.allCases.count) tabs in \
                \(SettingsView.SettingsTab.railGroups.count) groups no longer fit, and the rail \
                has to scroll on the display it is budgeted against.
                """)
    }

    /// The smallest sheet a user can actually produce, which is no longer `floorSize`.
    ///
    /// `ContentView` gives the window a 760×560 content floor, so `resolvedSize` is clamped by the
    /// window (712×512) and stops well above the floor `theRailIsWhatTheFloorSizedSheetRunsOutOf`
    /// measures. Hard-coding the pair here mirrors what `sheetClampsToTheSpaceTheHostHas` already
    /// does — the Settings module cannot see `MacApp` — and a floor raised without looking here
    /// only ever makes this pass.
    ///
    /// This is the assertion the floor test cannot make: it records where the layout gives up,
    /// which is a case the window no longer reaches, so on its own it would leave the rail's real
    /// worst case unmeasured.
    ///
    /// **Measured slack at the floor: 89.4pt at Small, 67.0 at Default, 26.0 at Large, 9.6 at
    /// Larger.** It fits at every size, and only just at the largest — which is the honest reading
    /// of a 560pt window, not a margin to spend. Ten more points of rail (a tenth tab is ~32) and
    /// Larger goes to a scroll here first. The numbers are real: raising the bound to a value
    /// nothing could satisfy printed all four, so this reports a measurement rather than the
    /// silence of an assertion that cannot fail.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theRailFitsTheSheetTheWindowFloorProduces(_ size: FontSize) async throws {
        let margin = tabListMargin(at: size.scale, available: Self.windowFloor)

        #expect(margin >= 0,
                """
                At the window's own floor (\(Self.windowFloor.width)×\(Self.windowFloor.height)) \
                the tab list overruns its opening by \(-margin)pt at \(size.displayName) — the \
                rail has to scroll at the smallest window a user can make.
                """)
    }

    /// Where the rail genuinely binds, recorded honestly rather than trimmed away — the same shape
    /// as `theClampedOpeningFitsTheSmallerTextSizesOnly`, and for the same reason: a boundary that
    /// stays true in BOTH directions beats a one-sided assertion nobody can tell is vacuous.
    ///
    /// `floorSize` is where `resolvedSize` stops shrinking (a window under ~570×428). **No user
    /// can drag a window there any more** — `ContentView`'s floor is 760×560, which is what
    /// `theRailFitsTheSheetTheWindowFloorProduces` measures instead, and it fits. What is left
    /// here is the layout's own last stand: the size the sheet takes when a host offers it less
    /// than the main window ever will. There the sheet is 380pt and the opening 335pt at the
    /// default text size, and the rail is the part that runs out first.
    ///
    /// **Measured: the tab list overruns the floor-sized opening at every text size — by 42.6pt at
    /// Small, 65.0pt at Default, 88.6pt at Large and 121.2pt at Larger.** At seven rows it fitted
    /// at the first three and overran only at Larger, which is what made a non-scrolling rail
    /// defensible then. Nine rows and three separators is what took Default across, and no amount
    /// of trimming brings it back: a row is ~32pt so the two new ones cost ~63pt, while the
    /// separators are only 27pt of it — deleting the grouping outright would still leave Default
    /// ~38pt short. The overrun is the tab count, not the ornament.
    ///
    /// **So this is now a scroll, not a clip, and that is the whole point of the change.** The
    /// rail's `ScrollView` is `.basedOnSize`: it sits still on any window where the tabs fit, and
    /// in this one it lets the user reach the rows that do not. The failure mode it replaces was
    /// silent — the bottom rows were not clipped mid-glyph, they were simply absent, with nothing
    /// on screen saying a tab existed below the fold.
    ///
    /// This test exists to keep that trade visible: if the overrun ever reaches the point where
    /// the scroller is doing real work on an ORDINARY window rather than a deliberately tiny one,
    /// `theRailFitsItsOpening` is the one that fails. This one only pins where the boundary is.
    @MainActor
    @Test func theRailIsWhatTheFloorSizedSheetRunsOutOf() async throws {
        // Smaller than `floorSize` in both axes, so `resolvedSize` returns the floor itself.
        let tinyWindow = CGSize(width: 300, height: 300)
        #expect(SettingsSheetMetrics.resolvedSize(textScale: 1, available: tinyWindow)
                == SettingsSheetMetrics.floorSize,
                "this window no longer clamps to the floor — the test has lost its subject")

        let fitting = FontSize.allCases.filter { tabListMargin(at: $0.scale, available: tinyWindow) >= 0 }
        let margins = FontSize.allCases.map { size in
            "\(size.displayName) \(tabListMargin(at: size.scale, available: tinyWindow))pt"
        }

        #expect(fitting.isEmpty,
                """
                At the sheet's floor the tab list now fits at \(fitting.map(\.displayName)) with \
                \(SettingsView.SettingsTab.allCases.count) tabs — the residual recorded on this \
                test is out of date. Margins now: \(margins.joined(separator: ", ")).
                """)
    }

    /// The premise both rail tests rest on, stated so a failure names the cause: the tab list's
    /// height is driven by the tab COUNT. Without this, deleting the `ForEach` in
    /// `SettingsRail.TabList` would leave both of them comfortably green.
    @MainActor
    @Test func theRailGrowsWithTheTabCount() async throws {
        let measured = tabListHeight(at: 1)
        let rows = CGFloat(SettingsView.SettingsTab.allCases.count)

        // A row is a `.callout` line (13pt) plus 7pt of inset above and below plus the 2pt gap —
        // ~30pt at the floor. Nine of those is the bulk of the rail; anything much under that
        // means the rows have stopped being laid out as rows.
        #expect(measured >= rows * 30,
                "the tab list lays out at \(measured)pt for \(Int(rows)) tabs — its rows are not being measured.")
    }

    /// Every group in `railGroups` is drawn, and every tab belongs to exactly one.
    ///
    /// A tab added to the enum but not to a group would simply never appear in the rail — the
    /// `ForEach` walks the groups, not `allCases` — and nothing else here would notice: the tab
    /// would still have a display name, a symbol, search entries and a `content` arm. It would
    /// just be unreachable by clicking.
    @Test func railGroupsCoverEveryTab() {
        let grouped = SettingsView.SettingsTab.railGroups.flatMap { $0 }

        #expect(Set(grouped) == Set(SettingsView.SettingsTab.allCases),
                """
                \(Set(SettingsView.SettingsTab.allCases).subtracting(grouped).map(\.rawValue)) are \
                in the enum but in no rail group, so the rail never draws them.
                """)
        #expect(grouped.count == SettingsView.SettingsTab.allCases.count,
                "a tab appears in more than one rail group: \(grouped.map(\.rawValue))")
        // Rail order is the enum's order. The groups are what the rail iterates, so a group list
        // that reordered them would silently move rows without a single other test moving.
        #expect(grouped == SettingsView.SettingsTab.allCases,
                "the rail's group order no longer matches `allCases` — the rail rows are reordered")
    }

    /// The separators really are drawn, and really do cost height.
    ///
    /// `railGroupsCoverEveryTab` passes just as well against a rail that ignores the grouping and
    /// draws one flat run, which is the whole failure mode: the grouping is a visual claim, so
    /// something has to measure the pixels it costs. One divider plus its air is ~7pt, so three
    /// groups' worth is ~21pt the flat list would not pay.
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

    /// The same rows the rail draws, without the group separators — the discriminator
    /// `theGroupSeparatorsAreReallyDrawn` needs. Deliberately duplicates `TabList`'s stack rather
    /// than taking a flag on it: a flag would let the real rail pass the test with its separators
    /// switched off. Measured at 285pt against the grouped list's 312pt at the default text size.
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

    /// The version line has to fit the rail's WIDTH, which nothing measured until the marker got
    /// longer than "1.0".
    ///
    /// Every other rail assertion is about height. This one is about width, and the rail's width
    /// is FIXED (`SettingsSheetMetrics.railWidth`, 176pt) — it does not grow for its contents and
    /// it does not scroll. The version line carries no `lineLimit`, so a string too wide for the
    /// column does not clip or truncate: it WRAPS to a second row, quietly making the rail taller
    /// and putting "SyncCloud" and its number on separate lines at the foot of the sidebar.
    ///
    /// Going from "1.0" to "3.0-dev" more than doubled the number's length, so this is measured
    /// rather than reasoned about. Both halves are checked, because they fail differently: the
    /// intrinsic width says how close to the edge the line is, and the rail height says whether
    /// it actually wrapped.
    ///
    /// **The measured margin.** The line has 142pt to lay out in
    /// (176pt of rail, less 8pt of rail inset and 9pt of row inset on each side). "SyncCloud
    /// 3.0-dev" wants 86 / 95 / 107 / 119pt at Small / Default / Large / Larger — so the worst
    /// case, the largest text size, still keeps 23pt in hand, about three characters. A marker
    /// stays safe out to roughly 21 characters including the "SyncCloud " prefix, which covers
    /// every number the scheme in `CLAUDE.md` can produce for a long time ("10.10-dev" measures
    /// 132pt, still clear). If a version ever does approach that, this test says so.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theVersionLineFitsTheRailOnOneLine(_ size: FontSize) async throws {
        let line = Text("SyncCloud \(Self.versionMarker)").scaledFont(.caption2)
        let intrinsic = laidOutWidth(line, scale: size.scale)

        #expect(intrinsic <= SettingsRail.versionTextWidth,
                """
                "SyncCloud \(Self.versionMarker)" wants \(intrinsic)pt at \(size.displayName) in \
                a \(SettingsRail.versionTextWidth)pt column — the rail is fixed-width and does \
                not scroll, so the line wraps onto a second row.
                """)

        // The width check above is the diagnosis; this is the symptom — measured against what a
        // LINE costs rather than against an exact height. A one-character version cannot wrap, so
        // it gives the unwrapped baseline, and subtracting a rail with no version line at all
        // gives what one `.caption2` line is worth at this text size. A wrap adds a whole one of
        // those; anything below half of it is layout jitter.
        //
        // Jitter is why this is not an equality. It was one, and CI caught it: the runner laid
        // the identical unwrapped line out at 326pt where this machine measured 328pt, and the
        // test failed for a 2pt difference in the direction that means "did not wrap" (the marker
        // was SHORTER than the one-character baseline). Half a line is far above that noise and
        // far below a real wrap, so the threshold separates the two on any machine.
        let unwrapped = railHeight(at: size.scale, version: "1")
        let oneLine = unwrapped - railHeight(at: size.scale, version: nil)
        let extra = railHeight(at: size.scale) - unwrapped

        #expect(extra < oneLine / 2,
                """
                At \(size.displayName) the rail is \(extra)pt taller with "\(Self.versionMarker)" \
                than with a one-character version, and a line of this type is \(oneLine)pt — the \
                version line has wrapped onto a second row.
                """)
    }

    /// Keeps `theVersionLineFitsTheRailOnOneLine` from going vacuous.
    ///
    /// Both of its assertions are "nothing bad happened" shapes, and the height half especially
    /// so — if a wrapped line did not actually make `fittingSize.height` grow, comparing heights
    /// would pass for every string ever written and nobody would know. Measured: a marker wide
    /// enough to need a second row adds exactly one `.caption2` line (13pt at the default text
    /// size), and one needing three rows adds 26pt.
    ///
    /// This checks the same `oneLine / 2` threshold the other test uses, from the other side, so
    /// the two together say the threshold DISCRIMINATES rather than merely that one side of it
    /// holds: an unwrapped marker sits below it and a wrapped one sits above it.
    @MainActor
    @Test func aVersionTooWideForTheRailReallyDoesWrapIt() async throws {
        let overlong = "9.9-dev-and-then-some"
        #expect(laidOutWidth(Text("SyncCloud \(overlong)").scaledFont(.caption2), scale: 1)
                > SettingsRail.versionTextWidth,
                "the probe no longer overflows the column — it has stopped probing anything")

        let unwrapped = railHeight(at: 1, version: "1")
        let oneLine = unwrapped - railHeight(at: 1, version: nil)
        let extra = railHeight(at: 1, version: overlong) - unwrapped

        #expect(extra >= oneLine / 2,
                """
                A version far too wide for the rail adds only \(extra)pt to it against a \
                \(oneLine)pt line — `fittingSize.height` is not seeing the wrap, so the height \
                half of `theVersionLineFitsTheRailOnOneLine` proves nothing.
                """)
    }

    /// The seam itself: the version line renders because `versionText` says so.
    ///
    /// Without this, re-inlining the `Bundle.main` read into `body` would leave both tests above
    /// green — they would be measuring a rail with no version line at all, in a host that has no
    /// version to give it, which is precisely the state this whole area was in before.
    @MainActor
    @Test func theRailDrawsNoVersionLineWithoutOne() async throws {
        #expect(railHeight(at: 1, version: nil) < railHeight(at: 1),
                """
                The rail is the same height with and without a version — `versionText` is not \
                what puts the line on screen, so injecting it measures nothing.
                """)
    }

    /// The rail as the APP lays it out — including the version line, which the host cannot
    /// produce on its own (see `theRailFitsItsOpening`) and which is therefore injected.
    @MainActor
    private func railHeight(at scale: CGFloat, version: String? = Self.versionMarker) -> CGFloat {
        let rail = SettingsRail(selection: .constant(.general), query: .constant(""),
                                hue: .blue, versionText: version)
        return laidOutHeight(rail, width: SettingsRail.width, scale: scale)
    }

    /// The tab rows' own height — the quantity the rail's scroller made `railHeight` unable to
    /// report. Laid out at the rail's real width, since the rows are fixed to it.
    @MainActor
    private func tabListHeight(at scale: CGFloat) -> CGFloat {
        let list = SettingsRail.TabList(selection: .constant(.general), query: .constant(""),
                                        hue: .blue)
        return laidOutHeight(list, width: SettingsRail.width, scale: scale)
    }

    /// How much room the tab list has left in a given window — positive means every tab is
    /// reachable without scrolling.
    ///
    /// The search field and the version line are MEASURED here rather than allowed for. That is
    /// not fastidiousness: the previous residual recorded on `theRailIsWhatTheFloorSizedSheetRuns\
    /// OutOf` was wrong in both directions precisely because it rested on a hand-estimated
    /// version-line allowance that had never been checked against a rendered line.
    @MainActor
    private func tabListMargin(at scale: CGFloat, available: CGSize) -> CGFloat {
        let searchField = laidOutHeight(SettingsSearchField(query: .constant("")),
                                        width: SettingsRail.versionTextWidth, scale: scale)
        let versionLine = laidOutHeight(Text("SyncCloud \(Self.versionMarker)").scaledFont(.caption2)
                                            .padding(.top, 8).padding(.bottom, 2),
                                        width: SettingsRail.versionTextWidth, scale: scale)
        // The premise: both really laid out. A zero here would silently inflate every margin.
        #expect(searchField > 0 && versionLine > 0,
                "the rail's search field or version line measured 0pt — this margin is fiction")

        let opening = SettingsRail.tabListOpening(
            in: SettingsSheetMetrics.contentOpening(textScale: scale, available: available),
            searchFieldHeight: searchField,
            versionLineHeight: versionLine)
        return opening - tabListHeight(at: scale)
    }

    @Test func everyTabHasARailSymbol() {
        // A tab added without a symbol would render an empty slot in the rail rather than fail
        // to build — SF Symbol names are strings.
        for tab in SettingsView.SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil) != nil,
                    "\(tab.rawValue) has no SF Symbol named \(tab.symbolName)")
        }
    }

    // MARK: The widest segmented row

    /// "Text size" is the widest of Appearance's segmented rows — four options where the others
    /// have two or three — and it has to fit the narrowest column the sheet can offer, or its
    /// labels truncate to "Sm…/De…/La…/La…" and the two Large sizes stop being tellable apart.
    ///
    /// The floored column is the worst case at EVERY text size, which is what makes one
    /// measurement enough: the sheet only ever grows with the text scale, and it stops shrinking
    /// at `floorSize` regardless.
    ///
    /// Measured from the LAID-OUT picker (`fittingSize`), unconstrained, so the number is what the
    /// control WANTS rather than what a frame told it to be.
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

        let wanted = laidOutTextSizePickerWidth(at: .medium)
        #expect(wanted > 0, "the picker laid out to nothing — the fixture measured no control")
        #expect(wanted <= available,
                """
                The Text size picker wants \(wanted)pt but the floored content column offers only \
                \(available)pt — its labels will truncate. Margin: \(available - wanted)pt.
                """)
    }

    /// A segmented picker's width does not follow the app's text size — and the fit test above
    /// leans on that, so it is pinned rather than assumed.
    ///
    /// Measured, because the obvious expectation is the opposite one: `NSSegmentedControl` ignores
    /// the SwiftUI font outright. The row is 260pt at Small and at Larger, and stays 260pt under an
    /// explicit `.font(.system(size: 24))`. The only lever that moves it is `controlSize`
    /// (`.large` → 276pt, `.small` → 228pt), which Appearance does not set.
    ///
    /// So this is the test that fires if that ever changes — if a future macOS, or a `controlSize`
    /// added upstream of these rows, starts scaling them, the fit above has to be re-measured at
    /// Larger rather than at one size.
    @MainActor
    @Test func theSegmentedRowsWidthDoesNotFollowTheAppTextSize() {
        let sizes = Set(FontSize.allCases.map { laidOutTextSizePickerWidth(at: $0) })
        #expect(sizes.count == 1,
                """
                The Text size picker now measures \(sizes.sorted()) across the four text sizes. It \
                used to be font-invariant, which is why `theTextSizeRowFitsTheNarrowestColumn…` \
                measures one size — re-measure it at Larger.
                """)
        // The fixture CAN see a font change, so the agreement above is a property of the control
        // rather than of the harness: a plain Text through the same path grows by ~40pt.
        let plain = { (size: FontSize) -> CGFloat in
            let host = NSHostingView(rootView: Text("Small Default Large Larger").appFontSize(size))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        #expect(plain(.extraLarge) > plain(.medium) + 5,
                "the fixture does not scale anything at all — the invariance above proves nothing")
    }

    /// Appearance's Text size row exactly as it ships — four options, labels hidden, the app
    /// accent on the selection — laid out at `size` with no width constraint.
    @MainActor
    private func laidOutTextSizePickerWidth(at size: FontSize) -> CGFloat {
        struct TextSizeRow: View {
            @State private var raw = FontSize.medium.rawValue
            var body: some View {
                Picker("Text size", selection: $raw) {
                    ForEach(FontSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(.blue)
            }
        }
        // `appFontSize(_:)` rather than a bare `\.appFontScale`: see the guard test above.
        let host = NSHostingView(rootView: TextSizeRow().appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
}

// MARK: - The cloud-spend readout

/// `FilingSpendReadout` replaced four `SettingsRow`s with a four-figure strip, and until this
/// existed **only its empty branch had ever been exercised** — every render and every layout test
/// ran against a `FilingSpendTotals()` with no scans, which draws one sentence and none of the
/// figures. The whole point of the view was invisible to the suite.
///
/// That mattered because the strip is the one place in Settings where four values share a row.
/// The figures were rendered and read back at three widths before this was written:
///
/// - the real column (547pt) — all four fit on one line with room to spare;
/// - the worst realistic case (`~$128.40`, `91002.7k tok`, `412`, `Opus · 150 files · ~$2.41`) —
///   also one line;
/// - the narrowest column the sheet can ever offer (307pt, the floor-sized window) — "Cloud
///   refines" and the last-refine value **wrap to two lines**, and nothing truncates. That is the
///   intended degradation: each figure sits in a column the `HStack` proposes a real width to, so
///   a `Text` too long for it wraps of its own accord.
///
/// The strip briefly carried a `.fixedSize(horizontal: false, vertical: true)` on the value,
/// copied from `SettingsSection`'s caption where it is load-bearing. **Mutation says it was
/// not**: `theStripWrapsRatherThanOverflowingTheNarrowestColumn` survived its removal, and
/// rendering both variants at 307pt produced pixel-identical output. It is gone, along with the
/// comment claiming the value would otherwise truncate — the caption needs it because it is a
/// `Text` in a stack with `maxWidth: .infinity`, which is a different situation.
///
/// Geometry cannot tell "wrapped" from "truncated to …" — that distinction came from reading the
/// pixels, and it is recorded here rather than asserted. What IS asserted is the part a test can
/// hold: the populated branch draws something the empty branch does not.
@Suite struct SpendReadoutTests {

    @MainActor
    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The narrowest column the sheet can ever offer — the worst case at every text size, since
    /// the sheet only grows with the scale and stops shrinking at `floorSize`.
    private static var narrowestColumn: CGFloat {
        let tiny = CGSize(width: SettingsSheetMetrics.floorSize.width + SettingsSheetMetrics.hostMargin,
                          height: SettingsSheetMetrics.floorSize.height + SettingsSheetMetrics.hostMargin)
        return SettingsSheetMetrics.contentWidth(textScale: 1, available: tiny)
            - 2 * SettingsSheetMetrics.pagePaddingH
    }

    private static let populated = FilingSpendTotals(costUSD: 4.37, tokens: 3_184_502, scans: 27)
    private static let lastRefine = FilingSpendEntry(
        id: "1", timestamp: Date(timeIntervalSince1970: 1_770_000_000),
        model: "claude-haiku-4-5-20251001", fileCount: 148, placedCount: 148,
        inputTokens: 300_000, outputTokens: 18_000,
        cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 0.0312)

    /// The gap this closes: with `scans == 0` the view draws a sentence and returns, so every
    /// assertion that only ever saw the default `FilingSpendTotals()` was measuring the empty
    /// state and calling it the readout.
    @MainActor
    @Test func theFiguresAppearOnlyOnceThereIsSpend() {
        let column = SettingsSheetMetrics.contentWidth(textScale: 1)
            - 2 * SettingsSheetMetrics.pagePaddingH
        let empty = height(FilingSpendReadout(totals: FilingSpendTotals(), last: nil), width: column)
        let full = height(FilingSpendReadout(totals: Self.populated, last: Self.lastRefine),
                          width: column)

        #expect(empty > 0, "the empty state laid out to nothing — this fixture measured no view")
        #expect(full > empty,
                """
                The populated readout (\(full)pt) is no taller than the "nothing spent yet"                 sentence (\(empty)pt) — the figures are not being drawn.
                """)
    }

    // There is deliberately NO geometric test that the last-refine figure wraps rather than
    // truncates, and the absence is the finding.
    //
    // Three were written and all three measured the neighbour instead of the subject. Comparing
    // the whole strip wide-vs-narrow passes because the LABEL "Cloud refines" wraps too, whatever
    // the value does — `.lineLimit(1)` on the value left it green. Varying the model name to
    // lengthen the string does nothing either: `FilingSpendFormat.model` collapses
    // "claude-haiku-4-5-20251001" to "Haiku", so the input never reaches the rendered text, and
    // the two fixtures measured 44.0pt against 44.0pt.
    //
    // `fittingSize` cannot tell a wrapped line from a truncated one — a `Text` that clips to
    // "Haiku · 148 fi…" and one that wraps to two lines both report a height the assertion is
    // happy with. Only painted pixels distinguish them, which is how the wide/worst/narrow
    // renders recorded on this suite were checked. A test that cannot fail for the reason its
    // name gives is worse than no test: it reads as coverage of exactly the thing nobody checked.
}
