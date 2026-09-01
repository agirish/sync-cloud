import Design
import SwiftUI

// MARK: - The settings page layout
//
// Settings used to be a stack: a title row, a search field and a six-up segmented picker over a
// `Form { Section { … } }.formStyle(.grouped)` body. That cost 124pt of chrome before the first
// control, and grouped Form spends ~115pt per section — a header, a boxed control, a footer
// paragraph and a gap — so the Appearance tab laid out at 884pt inside a 436pt opening. The last
// visible control was cut in half by the sheet's bottom edge, which is the one thing a scrolling
// surface must never do: a clipped control reads as "you've reached the end".
//
// The pieces here replace both halves of that. `SettingsRail` takes the search field and the
// tabs out of the content column and stands them down the left, the macOS Settings convention.
// `SettingsSection` keeps a grouped Form's *information* architecture — a titled group of related
// controls with one explanation underneath — while dropping the box it drew around every group:
// ~77pt per section instead of ~115.
//
// `.formStyle(.columns)` was measured as the cheaper alternative (61pt per section) and rejected
// on sight: it renders section headers in the value column at body weight, so "Startup" reads as
// another line of the preceding caption rather than as a heading, and the whole form hangs off a
// wide empty gutter. It is shorter because it deletes the structure, not because it packs it.

/// How big the sheet is and how much of it the selected tab gets.
///
/// A free-standing enum rather than statics on `SettingsView`: a static on a SwiftUI `View` is
/// `@MainActor`, so arithmetic that has nothing to do with the main actor would drag every test
/// asserting it onto that actor — and calling one from a nonisolated context traps at runtime
/// with no compile error. This is plain math; it belongs somewhere plain.
enum SettingsSheetMetrics {
    /// The sheet at the default text size. The height is chosen against a measurement, not a
    /// round number: Appearance is the tallest tab that can be made to fit, and the opening has
    /// to clear it with room to spare so a copy edit doesn't silently push it back into
    /// scrolling. See `SettingsLayoutTests`.
    ///
    /// 660 → 688 when `sectionTitleAir` was added: that air costs 28pt across Appearance's seven
    /// sections, so the sheet grows by exactly 28pt and the safety margin is left where it was.
    /// Paying for the air out of the margin instead would have left the tab one caption line
    /// from scrolling again.
    ///
    /// 688 → 758 when the accent preview strip and its caption landed. Same arithmetic, measured
    /// the same way: Appearance went 604 → 674pt at the default text size (a 44pt strip, the 8pt
    /// stack gap above it, and ~18pt for the caption the section never had), so the sheet takes
    /// the whole 70pt and the margin returns to the 39pt it had before. The tab had only 24pt of
    /// slack over the 15pt floor `appearanceKeepsRoomForACopyEdit` enforces, so the strip could
    /// not have been absorbed — this is the "raise it deliberately" branch that test asks for,
    /// not a silent overflow.
    ///
    /// 758 → 700 when the 758 raise turned out to overflow SMALL displays: `resolvedSize` clamps
    /// the sheet to the host window, and on a 1280×800-class screen the window has ~740pt to give,
    /// so the sheet resolved to ~692pt, the opening to ~647pt — and the 674pt Appearance tab
    /// scrolled again. Every fit test passed because all of them measured against the UNCLAMPED
    /// opening. The strip's 70pt could not stay paid for by height alone, so ~34pt came back out
    /// of the tab's chrome (see `captionGap`, `sectionPitch`, `pagePaddingV`, and the strip's own
    /// vertical padding), Appearance now lays out at ~640pt, and the sheet returns to being sized
    /// against that measurement instead of carrying 79pt of dead air on large displays.
    /// `appearanceFitsA1280x800Display` is the clamped-opening test that was missing.
    ///
    /// This constant is now bounded from BOTH sides, because a lower bound alone could not see
    /// it: on the 1280×800 fixture 758 and 700 clamp to the same 692pt sheet, so the clamped
    /// test is blind to the raise, and every unclamped test grows in lockstep with it.
    /// `appearanceKeepsRoomForACopyEdit` keeps the opening at least 15pt over the measured tab;
    /// `theSheetIsSizedAgainstTheTallestTabItMustFit` keeps it at most 30pt over. Between them
    /// "sized against a measurement" is a property a test can fail rather than a claim in a
    /// comment. If the tab is legitimately trimmed, LOWER this — do not widen the bound.
    ///
    /// 700 → 704 when section captions moved from 10pt to 11pt (the Settings-prose half of the
    /// text-size rework). The tab legitimately grew ~1pt per caption line; the two captions
    /// that grew a whole WRAP line (List density, and the `.none` accent) were copy-edited back
    /// instead, since a wrap line is 14pt and the clamped 1280×800 opening cannot be raised.
    /// This is the "raise it deliberately" branch `appearanceKeepsRoomForACopyEdit` asks for:
    /// Appearance measures ~642pt and the 704pt sheet's 659pt opening keeps the 15pt copy-edit
    /// margin with no dead air (the upper-bound test still holds at ~17pt).
    static let baseSize = CGSize(width: 760, height: 624)

    /// Below this, a rail plus a usable content column stops being possible. The sheet stops
    /// shrinking and its content scrolls instead: overflowing a tiny window is better than a
    /// sheet too small to use.
    static let floorSize = CGSize(width: 520, height: 380)

    /// Breathing room kept between the sheet and the window edge.
    static let hostMargin: CGFloat = 48

    /// The rail's width. Wide enough for the longest tab name ("Appearance") plus its symbol at
    /// the largest text size without the label truncating.
    static let railWidth: CGFloat = 176

    /// Extra air under a section title, beyond the stack's own spacing.
    ///
    /// Measured against System Settings ▸ Appearance sitting beside this pane in one capture:
    /// its group headers stand ~37pt off their first row where ours stood ~25pt, and its groups
    /// end ~38pt before the next header where ours ended ~22pt. Type sizes matched exactly
    /// (11pt headers, 13pt row labels) — the whole difference was air.
    ///
    /// This closes about a third of that gap, which is what the height budget allows: Appearance
    /// is the tab that has to fit, and +4pt across its seven sections spends 28pt of the slack.
    /// Matching Apple outright would want +12pt a section — 84pt — and a taller sheet.
    static let sectionTitleAir: CGFloat = 4

    /// The title row's height, fixed so the content opening is arithmetic rather than a guess.
    /// 44pt clears `.headline` at the largest text scale (15.85pt under the knee curve — 13pt is
    /// above the 11pt knee, so it grows damped: 11 × 1.35 + 2 × 0.5) with padding.
    static let headerHeight: CGFloat = 44

    /// Air between a section's last control and its caption.
    ///
    /// Was the section stack's blanket 5pt spacing. Trimmed to 3 — and made its own constant —
    /// when Appearance had to fit a 1280×800-class display's clamped opening: a caption belongs
    /// to the group it explains, so tightening it against its controls reads as grouping, not
    /// cramping, and it spends none of the *between*-section air `sectionTitleAir` exists to
    /// protect. 2pt × 7 sections is 14 of the ~34pt the tab gave back. The title keeps its full
    /// 9pt (`5 + sectionTitleAir`) — see `SettingsSection.body`, which now spells both gaps out
    /// instead of letting one stack spacing set them together.
    static let captionGap: CGFloat = 3

    /// The gap between sections on a settings page (`SettingsPage`'s stack spacing).
    ///
    /// 16 → 14 for the same 1280×800 budget: 2pt × 6 gaps is 12pt of the ~34. This is the one
    /// trim that works against the System Settings air comparison recorded on `sectionTitleAir`
    /// (Apple ends groups ~38pt before the next header; we were at ~22 and are now at ~20), so it
    /// is the first candidate to restore if the budget ever loosens — but a tab that SCROLLS on a
    /// small display loses all of its air, not 2pt of it.
    static let sectionPitch: CGFloat = 14

    /// A settings page's own top and bottom inset. 16 → 12 for the 1280×800 budget (8 of the
    /// ~34): the page sits under the title row's divider and above the sheet's bottom edge, both
    /// of which already read as boundaries — the inset is the cheapest air on the page.
    static let pagePaddingV: CGFloat = 12

    /// A settings page's side inset. Named rather than inline because it is the difference between
    /// the content COLUMN and the width a control actually gets, which is what
    /// `theTextSizeRowFitsTheNarrowestColumnTheSheetCanOffer` measures against.
    static let pagePaddingH: CGFloat = 18

    /// The sheet's size: the base size scaled by the text setting, then clamped to what the host
    /// actually has room for (never below `floorSize`).
    ///
    /// Scaling up is the point — Larger type needs a larger sheet, or the taller tabs go straight
    /// back to scrolling — but a sheet must never exceed the space it is centered in. The window's
    /// own minimum is 760×560; `hostMargin` takes 48 off that, leaving 712×512, which is SHORTER
    /// than the sheet wants in both axes — so this clamp does the work in width and in height.
    ///
    /// **This conclusion has now flipped twice, and the second flip is why it is written as a
    /// derivation rather than as a fact.** At the original 760 floor the clamp bit in both axes.
    /// The Editor workspace raised the floor to 810 for a fifth bar label, leaving 762 against the
    /// 760 the sheet asks for — two points of slack, and the width clamp stopped biting. Folding
    /// Storage into Organize took the bar back to four labels and the floor back to 760, so the
    /// width clamp bites again. The lesson is that this is `floor − hostMargin` versus what the
    /// sheet asks for, and both operands move; `SettingsLayoutTests.windowFloor` is the one place
    /// the number lives, so the test flips with the app rather than after it.
    ///
    /// **Grow only.** The scale is floored at 1, the same rule and the same reason as
    /// `ListDensity.tableRowHeight`. A tab's height is not proportional to the text scale: its
    /// padding, spacing and control heights are fixed points, so only the type shrinks at Small.
    /// Scaling the sheet down by the full 0.9 took 69pt off the opening while Appearance gave back
    /// 12pt, and the tab measured 592pt into a 578.6pt opening — the last control cut in half by
    /// the sheet's bottom edge, which is the exact defect this whole layout exists to prevent.
    /// `appearanceFitsEveryTextSize` pins it at all four sizes now, not just the default.
    static func resolvedSize(textScale: CGFloat, available: CGSize?) -> CGSize {
        let scale = max(1, textScale)
        let wanted = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        guard let available else { return wanted }
        return CGSize(
            width: min(wanted.width, max(floorSize.width, available.width - hostMargin)),
            height: min(wanted.height, max(floorSize.height, available.height - hostMargin))
        )
    }

    /// The height the selected tab's page actually gets: the sheet, less the title row and the
    /// divider under it. The number the layout tests assert each tab against.
    ///
    /// `headerHeight` is scaled by the RAW `textScale` — deliberately not the grow-only
    /// `max(1, …)` floor `resolvedSize` applies. The two rules cover different things: the SHEET
    /// must never shrink below its base size (its paddings and control heights are fixed points),
    /// but the title row's frame really is `headerHeight * fontSize.scale` in `SettingsView.body`,
    /// because its one line of type does get smaller at Small. At scale 0.9 the sheet stays 704pt
    /// while the header draws at 39.6pt, so the opening is honestly ~4pt taller — flooring the
    /// scale here would understate what the page gets and desynchronize this arithmetic from the
    /// drawn header, which is the one thing the fixed-height frame exists to prevent.
    static func contentOpening(textScale: CGFloat, available: CGSize? = nil) -> CGFloat {
        resolvedSize(textScale: textScale, available: available).height
            - headerHeight * textScale
            - 1
    }

    /// The content column's width: the sheet, less the rail and the divider beside it.
    static func contentWidth(textScale: CGFloat, available: CGSize? = nil) -> CGFloat {
        resolvedSize(textScale: textScale, available: available).width - railWidth - 1
    }
}

/// One tab's worth of settings: a scrolling column of `SettingsSection`s.
///
/// Scrolls only when it has to (`.basedOnSize`), so a tab that fits sits still instead of
/// rubber-banding under the pointer.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsSheetMetrics.sectionPitch) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsSheetMetrics.pagePaddingH)
            .padding(.vertical, SettingsSheetMetrics.pagePaddingV)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A titled group of related controls with one explanation underneath — the grouped-Form
/// `Section { } header: { } footer: { }` shape, minus the box.
///
/// The caption is styled here (caption size, secondary) rather than at each call site, but a
/// caption that sets its own `foregroundStyle` still wins: the inner modifier is applied closer
/// to the text. That is what keeps the "Notifications are disabled…" hint orange.
struct SettingsSection<Content: View, Caption: View>: View {
    private let title: String?
    private let content: Content
    private let caption: Caption

    init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder caption: () -> Caption
    ) {
        self.title = title
        self.content = content()
        self.caption = caption()
    }

    var body: some View {
        // Spacing 0 with each gap spelled out, rather than one stack spacing for both: the title
        // keeps its full 9pt of air (`5 + sectionTitleAir` — the System Settings comparison that
        // constant records) while the caption sits at the tighter `captionGap`. A single spacing
        // value cannot hold the two apart.
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .padding(.bottom, 5 + SettingsSheetMetrics.sectionTitleAir)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            caption
                // Subheadline (11pt), not caption (10pt): these are full sentences of
                // explanation — the text people actually read in Settings — and 10pt was the
                // single biggest reason the sheet read as too small at the default size. Micro
                // labels elsewhere (slider ends, stat labels, the version line) stay caption.
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                // Captions are full sentences that must wrap rather than truncate; without this
                // a `Text` inside a horizontally-flexible stack reports a one-line ideal height
                // and gets clipped at the second line.
                .fixedSize(horizontal: false, vertical: true)
                // On the caption rather than in the stack: an `EmptyView` caption contributes no
                // child, so a captionless section pays neither the gap nor a stray padding.
                .padding(.top, SettingsSheetMetrics.captionGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsSection where Caption == Text {
    /// The common case: a plain sentence of explanation.
    init(_ title: String? = nil, caption: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, caption: { Text(caption) })
    }
}

extension SettingsSection where Caption == EmptyView {
    /// A group that explains itself.
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, caption: { EmptyView() })
    }
}

/// A label-left / control-right row, the alignment grouped Form gave these for free.
///
/// Used for the controls that read as "setting: value" (a popup, a text field, a pair of
/// buttons). Controls that own their own label — `Toggle`, a segmented picker under a section
/// title — are placed directly in a `SettingsSection` instead.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The rail

/// The left rail: the search field, the tabs, and the version line.
///
/// Everything here used to sit above the content column. Moving it aside is what buys the
/// content its height back — and it gives the tabs room to be a list rather than a segmented
/// picker squeezed into 588pt. That headroom is what let the tab count grow from six to seven
/// when Tidy split into Organize and Duplicates; `SettingsLayoutTests.theRailFitsItsOpening`
/// is what keeps the growth honest.
struct SettingsRail: View {
    @Binding var selection: SettingsView.SettingsTab
    @Binding var query: String
    /// The window's accent hue: fills the selected row, tints the hover wash on the others.
    let hue: LiquidGlassHue

    /// The marketing version drawn at the foot of the rail, injectable so it can be MEASURED.
    ///
    /// Defaults to the app's own, which is what ships. It is a property rather than a direct
    /// `Bundle.main` read in `body` because under `swift test` `Bundle.main` is the test host,
    /// which carries no `CFBundleShortVersionString` — the `if let` fails, the line never
    /// renders, and every rail measurement is silently blind to it. That blindness is not
    /// hypothetical: the version line went from "1.0" to a marker like "3.0-dev" without a
    /// single test being able to see the line get wider. The rail is FIXED-WIDTH and does not
    /// scroll, so a line too wide for it wraps to a second row rather than being clipped —
    /// which `SettingsLayoutTests.theVersionLineFitsTheRailOnOneLine` is what now catches.
    var versionText: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Rail width. Lives on `SettingsSheetMetrics` rather than here because a static on a
    /// SwiftUI `View` is `@MainActor`, and `contentWidth` — plain arithmetic — is not.
    static var width: CGFloat { SettingsSheetMetrics.railWidth }

    /// The width the version line actually has to lay out in: the rail, less its own side inset
    /// and the horizontal inset the line shares with the tab rows. Derived rather than written
    /// down so it cannot drift from `Rhythm`.
    static var versionTextWidth: CGFloat {
        width - 2 * Rhythm.sides - 2 * Rhythm.rowInsetH
    }

    /// The rail's vertical rhythm, measured against System Settings sitting next to it rather
    /// than picked: its sidebar rows run a ~34pt pitch and put a clear gap under the search
    /// field. The first pass ran a 28pt pitch with a 9pt gap, and read as cramped at the top —
    /// the search field and the first tab looked like one block.
    private enum Rhythm {
        /// Gap between the search field and the first tab.
        static let searchGap: CGFloat = 16
        /// Between rows. Small, but enough that the selected row's fill reads as one row and
        /// not as a band across two.
        static let rowGap: CGFloat = 2
        /// Air above and below a group separator, *beyond* the `rowGap` the stack already pays on
        /// both sides of it. Measured: at 3 a separator and its air cost 9pt, so the three in
        /// `railGroups` take 27pt of the tab list's 312pt at the default text size — the same nine
        /// rows drawn flat are 285pt (`theGroupSeparatorsAreReallyDrawn` is what measures the
        /// difference). That is the whole price of the grouping, and it buys the divider reading
        /// as a break rather than as a squeezed row.
        static let groupGap: CGFloat = 3
        /// Above and below a row's label; sets the row height with the label's own line.
        static let rowInsetV: CGFloat = 7
        static let rowInsetH: CGFloat = 9
        /// The rail's own inset. Taller at the top so the search field isn't jammed against the
        /// divider under the title row.
        static let top: CGFloat = 14
        static let bottom: CGFloat = 10
        static let sides: CGFloat = 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(query: $query)
                .padding(.bottom, Rhythm.searchGap)

            // The tabs scroll — but only when they genuinely cannot fit.
            //
            // This was rejected once, and the objection is worth restating because it was right
            // at the time: "a `ScrollView` around the rail turns a seven-item list into a
            // scrolling surface on every display to serve a window smaller than the sheet's own
            // floor." What changed is both halves of that. `.basedOnSize` is the modifier the
            // content column has always used, and it is what makes a scroller that FITS sit
            // perfectly still — no rubber-banding, no indicator — so the cost on a normal display
            // is nothing. And the case being served is no longer the corner it was: at seven rows
            // the floor-sized sheet clipped the rail only at the largest text size, while at nine
            // it overruns by 47–125pt at EVERY size (`theRailIsWhatTheFloorSizedSheetRunsOutOf`
            // records the measurements).
            //
            // What has changed since is the window, not the rail: it now carries an 810×560 floor,
            // so the smallest sheet a user can produce is 762×512 and the tabs DO fit there — by
            // 9.6pt at the largest text size (`theRailFitsTheSheetTheWindowFloorProduces`), which
            // is a HEIGHT margin and so unmoved by the floor's width going 760 → 810. The
            // scroller is therefore a guard rather than the working case, which is the right way
            // round and no argument for removing it: 9.6pt is one tab from being gone, and the
            // sheet is also handed to hosts smaller than the main window.
            //
            // Losing the bottom of a fixed rail is silent — the rows are not clipped mid-glyph,
            // they are absent, and nothing says a tab exists below the fold. Scrolling is the
            // only option here that fails visibly.
            ScrollViewReader { rail in
                ScrollView {
                    TabList(selection: $selection, query: $query, hue: hue)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Bring the selected row into view when the rail cannot show every row at once.
                //
                // Without this the scroller fixes the clipping and leaves a subtler version of the
                // same defect: the rail opens at the top, so a selection further down is off-screen
                // with nothing saying which tab is showing. The case that makes it worth handling
                // is not the user scrolling — it is the DEEP LINK. `cloudRefineSetup` opens
                // Intelligence, the eighth of nine rows, for someone who just accepted an offer to
                // set cloud refining up; landing them on a rail that appears to have Advanced
                // selected, or nothing, is worse than the clip was.
                //
                // Unanimated on purpose: this is a jump to a destination, not a movement worth
                // watching, and `withAnimation { scrollTo }` does nothing at all when the display
                // is asleep. Costless when the row is already visible — a `scrollTo` that lands
                // where the stack already sits moves zero points.
                //
                // **Not covered by a test, and it cannot be from here.** `onAppear` does not fire
                // in an offscreen `NSHostingView` driven by `layoutSubtreeIfNeeded` — the same
                // reason `appearanceFitsItsOpeningWithoutScrolling` can measure General's `.task`
                // -free layout at all — so a render would show the unscrolled rail whether this
                // works or not, and a fixture that cannot distinguish the two measures nothing.
                // The failure mode if it silently does nothing is today's behaviour, not a
                // regression, which is what makes shipping it unverified acceptable here.
                .onAppear { rail.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, tab in rail.scrollTo(tab, anchor: .center) }
            }

            if let version = versionText {
                Text("SyncCloud \(version)")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Rhythm.rowInsetH)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .accessibilityLabel("SyncCloud version \(version)")
            }
        }
        .padding(.horizontal, Rhythm.sides)
        .padding(.top, Rhythm.top)
        .padding(.bottom, Rhythm.bottom)
        .frame(width: Self.width, alignment: .leading)
    }

    /// The tab rows on their own, outside the scroller.
    ///
    /// Its own view so the rail's height can still be MEASURED. A `ScrollView` accepts whatever
    /// height it is offered, so `SettingsRail`'s own `fittingSize` stopped being able to answer
    /// "do the tabs fit?" the moment the scroller went in — every rail assertion would have
    /// passed by construction, which is the failure mode where a fixture measures nothing at all.
    /// The tests lay THIS out instead, and compare it against the opening less the search field
    /// and the version line (`SettingsRail.tabListOpening(in:)`).
    struct TabList: View {
        @Binding var selection: SettingsView.SettingsTab
        @Binding var query: String
        let hue: LiquidGlassHue

        var body: some View {
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                // Grouped rather than one flat run: nine rows is where a sidebar stops being a
                // list you read and starts being a pile you scan. The separator is drawn between
                // groups only — never above the first or below the last, where it would read as
                // a border on the rail rather than as a break in it.
                ForEach(Array(SettingsView.SettingsTab.railGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, Rhythm.rowInsetH)
                            .padding(.vertical, Rhythm.groupGap)
                    }
                    ForEach(group, id: \.self) { tab in
                        // `.id` as well as the `ForEach` id: `scrollTo` resolves against the
                        // explicit id, and a row inside a nested `ForEach` does not get one from
                        // the outer loop.
                        railRow(tab).id(tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var isSearching: Bool {
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        @ViewBuilder
        private func railRow(_ tab: SettingsView.SettingsTab) -> some View {
            SettingsRail.railRow(tab, isSelected: selection == tab && !isSearching, hue: hue) {
                // Picking a tab is also the way out of a search: the results were standing in for
                // the content column, and the user has just said which content they want.
                selection = tab
                query = ""
            }
        }
    }

    /// The height the tab list actually has to fit in: the rail's opening, less its own insets,
    /// the search field and the gap under it, and the version line. Derived rather than written
    /// down so it cannot drift from `Rhythm` — and it takes the two MEASURED heights as arguments
    /// rather than estimating them, because a hand-estimated version-line allowance is exactly
    /// what made the previous residual on `theRailIsWhatTheFloorSizedSheetRunsOutOf` wrong.
    static func tabListOpening(in railHeight: CGFloat,
                               searchFieldHeight: CGFloat,
                               versionLineHeight: CGFloat) -> CGFloat {
        railHeight
            - Rhythm.top - Rhythm.bottom
            - searchFieldHeight - Rhythm.searchGap
            - versionLineHeight
    }

    @ViewBuilder
    fileprivate static func railRow(_ tab: SettingsView.SettingsTab,
                                    isSelected: Bool,
                                    hue: LiquidGlassHue,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.symbolName)
                    .frame(width: 16)
                    .scaledFont(.callout)
                Text(tab.displayName)
                    .scaledFont(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(hue.onAccentLabelColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, Rhythm.rowInsetH)
            .padding(.vertical, Rhythm.rowInsetV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(hue.accentFillColor)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        // A selected row already carries a solid fill, so it takes `.filled` (a ring and a lift,
        // no wash — there is nothing to wash over) with the tint flipped to the on-fill color.
        // See the accent-fill model in Design: washing the accent over its own fill paints nothing.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment,
                                      tint: isSelected ? hue.onAccentLabelColor : hue.accentColor,
                                      shape: .roundedRect(6)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The rail's search box: a magnifier, a plain text field, and a clear button that shows once
/// there's text. Styled as a rounded field so it reads as "search" without the native
/// `.searchable` machinery, which is meant for navigation stacks rather than an overlay card.
struct SettingsSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaledFont(.caption)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .scaledFont(.callout)
                .accessibilityLabel("Search settings")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(.caption)
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .searchFieldSurface()
    }
}
