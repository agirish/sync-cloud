import AppKit
import Design
import SwiftUI
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
/// for all six, so General, Sync and Advanced are checked too
/// (`everyMustFitTabFitsTheClampedOpening`).
///
/// Two tabs are still excluded, for reasons that are properties of those tabs: Providers grows
/// with the Mac's provider list, and Tidy is long by nature and expected to scroll — see
/// `tidyLaysOutWithoutReachingForTheKeychain`, which is here for a different reason again.
/// General was previously excluded as well, on the grounds that it "reaches for SMAppService on
/// appear, which a `swift test` host can block on". Measured, that does not bite in this
/// harness: the reads are in `.task`, which an offscreen `NSHostingView` driven only by
/// `layoutSubtreeIfNeeded` never fires. It is measured here like the rest.
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

    /// Tidy is long by nature (Duplicates, Filing, Cloud spend) and is expected to scroll, so
    /// there is no fit to assert. What this pins is that it can be laid out AT ALL: it used to
    /// read the Anthropic key out of the Keychain in `onAppear`, which blocked this host — and,
    /// in the app, put a password prompt on screen for anyone who merely opened the tab. If that
    /// read comes back, this test stops finishing.
    @MainActor
    @Test func tidyLaysOutWithoutReachingForTheKeychain() async throws {
        let height = laidOutHeight(TidySettingsTab(syncManager: nil), width: Self.contentWidth)

        #expect(height > 0)
    }

    // MARK: - The other tabs

    /// The tabs that must fit, and the height each lays out at. Appearance is measured by the
    /// tests above; these three were never measured at all.
    ///
    /// Providers and Tidy are absent for reasons that are properties of those tabs rather than
    /// oversights: Providers grows with the Mac's provider list, so its height is a property of
    /// the machine's data, and Tidy is long by nature and is expected to scroll (see
    /// `tidyLaysOutWithoutReachingForTheKeychain`).
    @MainActor
    private func mustFitTabs(_ settings: SettingsManager) -> [(String, AnyView)] {
        [("General", AnyView(GeneralSettingsTab().environmentObject(settings))),
         ("Appearance", AnyView(AppearanceSettingsTab())),
         ("Sync", AnyView(SyncSettingsTab(syncManager: nil).environmentObject(settings))),
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
        // The window's own minimum is 600pt wide — narrower than the sheet wants at any text
        // size — so an unclamped sheet would hang off the edge of a small window.
        let available = CGSize(width: 600, height: 500)
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

    @Test func everyTabHasARailSymbol() {
        // A tab added without a symbol would render an empty slot in the rail rather than fail
        // to build — SF Symbol names are strings.
        for tab in SettingsView.SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil) != nil,
                    "\(tab.rawValue) has no SF Symbol named \(tab.symbolName)")
        }
    }
}
