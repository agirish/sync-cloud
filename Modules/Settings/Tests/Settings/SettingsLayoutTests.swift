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
/// for every tab, so General, Sync, Duplicates and Advanced are checked too
/// (`everyMustFitTabFitsTheClampedOpening`).
///
/// Two tabs are still excluded, for reasons that are properties of those tabs: Providers grows
/// with the Mac's provider list, and Organize is long by nature and expected to scroll — see
/// `organizeLaysOutWithoutReachingForTheKeychain`, which is here for a different reason again.
/// General was previously excluded as well, on the grounds that it "reaches for SMAppService on
/// appear, which a `swift test` host can block on". Measured, that does not bite in this
/// harness: the reads are in `.task`, which an offscreen `NSHostingView` driven only by
/// `layoutSubtreeIfNeeded` never fires. It is measured here like the rest.
///
/// The RAIL is measured as well (`theRailFitsItsOpening`). It shares the tabs' opening but is
/// sized by the tab COUNT rather than by any tab's contents, so every assertion above is blind
/// to it — which is exactly how Tidy could split into two rail rows without a single test moving.
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

    /// The version string this branch's builds actually carry, mirroring `project.yml`'s
    /// `CFBundleShortVersionString`. Kept in step by the release procedure in `CLAUDE.md`, which
    /// makes updating it part of cutting a release.
    ///
    /// It is written down rather than read from `Bundle.main` because under `swift test`
    /// `Bundle.main` is the test host and has no version at all — the very blindness that let
    /// the app ship "1.0" for twenty-odd releases with a green suite. A literal that a human
    /// must change is the point: it is what gives `theVersionLineFitsTheRailOnOneLine` something
    /// real to measure.
    private static let versionMarker = "3.1-dev"

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

    /// Organize is long by nature (Suggestions plus Cloud spend) and is expected to scroll, so
    /// there is no fit to assert. What this pins is that it can be laid out AT ALL: it used to
    /// read the Anthropic key out of the Keychain in `onAppear`, which blocked this host — and,
    /// in the app, put a password prompt on screen for anyone who merely opened the tab. If that
    /// read comes back, this test stops finishing.
    ///
    /// It followed the Anthropic key when Tidy split: `CloudKeyRow` lives on this tab now, so
    /// this is still the tab with a Keychain call one `onAppear` away.
    @MainActor
    @Test func organizeLaysOutWithoutReachingForTheKeychain() async throws {
        let height = laidOutHeight(FilingSettingsTab(syncManager: nil), width: Self.contentWidth)

        #expect(height > 0)
    }

    // MARK: - The other tabs

    /// The tabs that must fit, and the height each lays out at. Appearance is measured by the
    /// tests above; these three were never measured at all.
    ///
    /// Providers and Organize are absent for reasons that are properties of those tabs rather
    /// than oversights: Providers grows with the Mac's provider list, so its height is a property
    /// of the machine's data, and Organize is long by nature and is expected to scroll (see
    /// `organizeLaysOutWithoutReachingForTheKeychain`).
    ///
    /// Duplicates joined the list when it split off Tidy: three `@AppStorage` rows and a caption,
    /// so its height is a property of the layout like Appearance's, and nothing about it excuses
    /// it from fitting.
    @MainActor
    private func mustFitTabs(_ settings: SettingsManager) -> [(String, AnyView)] {
        [("General", AnyView(GeneralSettingsTab().environmentObject(settings))),
         ("Appearance", AnyView(AppearanceSettingsTab())),
         ("Sync", AnyView(SyncSettingsTab(syncManager: nil).environmentObject(settings))),
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

    /// The RAIL has to fit too — the half of the sheet every other test here is blind to.
    ///
    /// Every fit assertion above measures a tab against `contentOpening`, which is the height of
    /// the column beside the rail. The rail sits in the same opening and is sized by a completely
    /// different thing: one row per `SettingsTab`, at ~33pt each. Splitting Tidy into Organize and
    /// Duplicates took it from six rows to seven, and no test could see that — the content column
    /// did not change height by one point, so the whole suite stayed green while the rail grew.
    /// A rail taller than its opening does not scroll (`SettingsRail` is a plain `VStack`, not a
    /// `ScrollView`): the last tabs and the version line are simply not reachable.
    ///
    /// Measured against the SMALL display's clamped opening for the same reason
    /// `appearanceFitsA1280x800Display` exists — an unclamped opening grows with `baseSize` and
    /// so can never fail. At every text size, because the rows are text and grow with it.
    ///
    /// **The version line is now measured, not estimated.** `Bundle.main` under `swift test` is
    /// the test host, which has no `CFBundleShortVersionString`, so the rail's own default for
    /// `versionText` resolves to nil here and the line does not render on its own. This used to
    /// be papered over with an allowance — a `.caption2` line plus 2pt of padding, scaled and
    /// "generously rounded up" to 18 — which was never once checked against a rendered line.
    /// `railHeight` now injects `versionMarker` through `SettingsRail.versionText` instead, so
    /// the line is really laid out and its height is really in the number. (The old estimate was
    /// indeed conservative, but only by 1–3pt: measured, the line is 15/17/18/20pt at Small /
    /// Default / Large / Larger where the allowance claimed 16.2/18/20.7/23.4.)
    ///
    /// **The measured residual, so nobody mistakes this for a tight budget.** Seven rows and the
    /// version line come to 314pt at the default text size against a 647pt opening — 333pt of
    /// slack, room for ten more tabs. The rail is nowhere near its ceiling on the display the
    /// tabs are budgeted against,
    /// and the honest answer to "does the seventh row fit here" is *comfortably*. This is a floor
    /// check on a quantity nothing else measures, not a budget like `baseSize`'s. Where the
    /// seventh row DOES bind is the sheet's own floor — `theRailIsWhatTheFloorSizedSheetRunsOutOf`.
    @MainActor
    @Test(arguments: FontSize.allCases)
    func theRailFitsItsOpening(_ size: FontSize) async throws {
        // The rail is fixed-width, so `laidOutHeight`'s width argument is only a proposal it
        // ignores — passed for symmetry with the tab measurements.
        let measured = railHeight(at: size.scale)
        let opening = SettingsSheetMetrics.contentOpening(textScale: size.scale,
                                                          available: Self.smallDisplayWindow)

        #expect(measured <= opening,
                """
                The rail lays out at \(measured)pt in a 1280×800 display's \(opening)pt opening \
                at \(size.displayName) — \(SettingsView.SettingsTab.allCases.count) tabs no \
                longer fit, and the rail does not scroll.
                """)
    }

    /// The one place the seventh rail row genuinely binds, recorded honestly rather than trimmed
    /// away — the same shape as `theClampedOpeningFitsTheSmallerTextSizesOnly`, and for the same
    /// reason: a boundary that stays true in BOTH directions beats a one-sided assertion nobody
    /// can tell is vacuous.
    ///
    /// `floorSize` is where `resolvedSize` stops shrinking (a window under ~570×428). There the
    /// sheet is 380pt and the opening 335pt at the default text size, and the rail — which cannot
    /// scroll — is the part that runs out first. **Measured, with the version line really laid
    /// out: the rail clears the floor-sized opening by 40.4pt at Small, 21.0pt at Default and
    /// 0.4pt at Large, and overruns it by 27.2pt at Larger.** So the Tidy split did cost
    /// something, and this is the whole of it: a user who has shrunk the window below the sheet's
    /// own floor AND set the largest text size loses the bottom of the rail.
    ///
    /// **Large fits by four tenths of a point, which is not a margin.** Read the set below as
    /// "Larger is the one that overruns", not as "Large is safe" — anything that adds a point to
    /// the rail or takes one off the opening moves Large across, and it is a coin-flip against
    /// a future macOS rounding text differently. It is recorded as fitting because that is what
    /// it measures; it is not something to spend.
    ///
    /// This is also what couples this test to `theVersionLineFitsTheRailOnOneLine`: a version
    /// marker too wide for the fixed rail wraps to a second line and costs ~15pt of height, which
    /// is 37× the margin Large has here. The version line wrapping would take Large down with it.
    ///
    /// The previously recorded residual — "fit at Small and Default, ~14pt over at Large, ~31pt
    /// over at Larger" — was wrong on both counts. It was derived from `railHeight`'s old
    /// hand-estimated version-line allowance rather than from a rendered line; Large was never
    /// 14pt over, it was 2.3pt over under the estimate and is 0.4pt UNDER once measured.
    ///
    /// Not fixed here, deliberately. The fixes on offer are all worse than the defect: a
    /// `ScrollView` around the rail turns a seven-item list into a scrolling surface on every
    /// display to serve a window smaller than the sheet's own floor, and raising `floorSize` moves
    /// the overflow into the content column, which at least scrolls. If the rail ever reaches
    /// eight rows, revisit — at that point Default stops fitting and this stops being an edge.
    @MainActor
    @Test func theRailIsWhatTheFloorSizedSheetRunsOutOf() async throws {
        // Smaller than `floorSize` in both axes, so `resolvedSize` returns the floor itself.
        let tinyWindow = CGSize(width: 300, height: 300)
        #expect(SettingsSheetMetrics.resolvedSize(textScale: 1, available: tinyWindow)
                == SettingsSheetMetrics.floorSize,
                "this window no longer clamps to the floor — the test has lost its subject")

        let fitting = FontSize.allCases.filter { size in
            railHeight(at: size.scale)
                <= SettingsSheetMetrics.contentOpening(textScale: size.scale, available: tinyWindow)
        }

        let margins = FontSize.allCases.map { size in
            let opening = SettingsSheetMetrics.contentOpening(textScale: size.scale,
                                                             available: tinyWindow)
            return "\(size.displayName) \(opening - railHeight(at: size.scale))pt"
        }

        #expect(fitting == [.small, .medium, .large],
                """
                At the sheet's floor the rail fits at \(fitting.map(\.displayName)) with \
                \(SettingsView.SettingsTab.allCases.count) tabs — the residual recorded on this \
                test is out of date. Margins now: \(margins.joined(separator: ", ")).
                """)
    }

    /// The premise both rail tests rest on, stated so a failure names the cause: the rail's height
    /// is driven by the tab COUNT. Without this, deleting the `ForEach` in `SettingsRail` would
    /// leave both of them comfortably green.
    @MainActor
    @Test func theRailGrowsWithTheTabCount() async throws {
        let measured = railHeight(at: 1)
        let rows = CGFloat(SettingsView.SettingsTab.allCases.count)

        // A row is a `.callout` line (13pt) plus 7pt of inset above and below plus the 2pt gap —
        // ~30pt at the floor. Seven of those is the bulk of the rail; anything much under that
        // means the rows have stopped being laid out as rows.
        #expect(measured >= rows * 30,
                "the rail lays out at \(measured)pt for \(Int(rows)) tabs — its rows are not being measured.")
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

    @Test func everyTabHasARailSymbol() {
        // A tab added without a symbol would render an empty slot in the rail rather than fail
        // to build — SF Symbol names are strings.
        for tab in SettingsView.SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil) != nil,
                    "\(tab.rawValue) has no SF Symbol named \(tab.symbolName)")
        }
    }
}
