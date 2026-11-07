import Design
import SwiftUI

// MARK: - The settings page layout
//
// Built so each tab fits its opening: a control cut in half by the sheet's edge reads as "you've
// reached the end". `SettingsRail` stands the search field and tabs down the left, the macOS
// Settings convention, so they cost the content column no height. `SettingsSection` keeps a
// grouped Form's structure (a titled group with one explanation underneath) without the box:
// ~77pt per section against grouped Form's ~115. `.formStyle(.columns)` is shorter still, but
// sets section headers at body weight in the value column, so they read as captions.

/// How big the sheet is and how much of it the selected tab gets.
///
/// A free-standing enum, not statics on `SettingsView`: a static on a SwiftUI `View` is
/// `@MainActor`, and calling one from a nonisolated test **traps at runtime** with no compile
/// error. This is plain math.
enum SettingsSheetMetrics {
    /// The sheet at the default text size. The height is sized against a measurement, not a round
    /// number: `theSheetIsSizedAgainstTheTightestPageItMustFit` holds the tightest must-fit page
    /// 15–30pt inside its opening (Appearance ▸ Look, under its strip), so a copy edit can't push it
    /// into scrolling and no dead air builds up. When that page grows, raise this deliberately;
    /// when it is trimmed, lower this. Never widen the bound. Keep it under the ~692pt a 1280×800
    /// display's window clamps the sheet to (`appearanceFitsA1280x800Display`).
    ///
    /// 648pt until TE332 split the tabs into pages and cut the captions to a line: the tallest page
    /// then had 158pt to spare.
    static let baseSize = CGSize(width: 760, height: 512)

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
    /// Measured against System Settings ▸ Appearance side by side: with matching type sizes, its
    /// headers stand ~37pt off their first row against our ~25pt without this, and its groups end
    /// ~38pt before the next header against our ~22pt. This closes about a third of the gap, what
    /// the height budget allows; matching outright would need +12pt a section and a taller sheet.
    static let sectionTitleAir: CGFloat = 4

    /// The title row's height, fixed so the content opening is arithmetic rather than a guess.
    /// 44pt clears `.headline` at the largest text scale (15.85pt: 13pt is above the 11pt knee, so
    /// it grows damped, 11 × 1.35 + 2 × 0.5) with padding.
    static let headerHeight: CGFloat = 44

    /// The sub-tab strip's height on a paged tab, fixed for `headerHeight`'s reason: each page's
    /// opening is `pageOpening`, arithmetic rather than a guess. Clears a small segmented control
    /// at the largest text scale with air above and below.
    static let subTabStripHeight: CGFloat = 40

    /// Air between a section's last control and its caption. Tight, to save height: a caption
    /// belongs to the group it explains, so close to its controls it reads as grouping, and it
    /// spends none of the between-section air. The title keeps its 9pt (`5 + sectionTitleAir`);
    /// `SettingsSection.body` spells both gaps out.
    static let captionGap: CGFloat = 3

    /// The gap between sections on a settings page (`SettingsPage`'s stack spacing). Trimmed for
    /// height against the System Settings comparison on `sectionTitleAir` (Apple ends groups ~38pt
    /// before the next header; this gives ~20), so it is the first to restore if the budget
    /// loosens. A tab that scrolls on a small display loses all its air, not 2pt.
    static let sectionPitch: CGFloat = 14

    /// A settings page's own top and bottom inset. The page sits under the title row's divider
    /// and above the sheet's bottom edge, both already boundaries, so this is the cheapest air to
    /// trim.
    static let pagePaddingV: CGFloat = 12

    /// A settings page's side inset: the difference between the content column and the width a
    /// control gets, which `theTextSizeRowFitsTheNarrowestColumnTheSheetCanOffer` measures against.
    static let pagePaddingH: CGFloat = 18

    /// The sheet's size: the base size scaled by the text setting, then clamped to what the host
    /// actually has room for (never below `floorSize`).
    ///
    /// Larger type needs a larger sheet, or the taller tabs scroll, but a sheet must never exceed
    /// the space it is centered in. Whether the clamp bites at the window's own minimum is
    /// `floor − hostMargin` against what the sheet asks for, and both operands move;
    /// `SettingsLayoutTests.windowFloor` mirrors the floor so its test follows the app.
    ///
    /// Grow only: the scale is floored at 1, as in `ListDensity.tableRowHeight`. Only the type
    /// shrinks at Small; padding, spacing and control heights are fixed points, so a sheet scaled
    /// down by the full 0.9 would lose more opening than its tabs give back and clip the last
    /// control. `appearanceFitsEveryTextSize` checks every size.
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
    /// `headerHeight` is scaled by the raw `textScale`, deliberately not floored like
    /// `resolvedSize`: the sheet never shrinks, but the title row's frame really is
    /// `headerHeight * fontSize.scale` in `SettingsView.body`. Flooring here would understate the
    /// opening at Small and desynchronize this arithmetic from the drawn header.
    static func contentOpening(textScale: CGFloat, available: CGSize? = nil) -> CGFloat {
        resolvedSize(textScale: textScale, available: available).height
            - headerHeight * textScale
            - 1
    }

    /// The height a page of a paged tab gets: the content opening, less the sub-tab strip and the
    /// divider under it, both scaled as `SettingsView` draws them.
    static func pageOpening(textScale: CGFloat, available: CGSize? = nil) -> CGFloat {
        contentOpening(textScale: textScale, available: available) - subTabStripHeight * textScale - 1
    }

    /// The opening a place's page gets: a one-page tab's content opening, or a sub-tab's page
    /// opening under its strip.
    static func opening(for place: SettingsPlace, textScale: CGFloat, available: CGSize? = nil) -> CGFloat {
        place.tab.subTabs.isEmpty
            ? contentOpening(textScale: textScale, available: available)
            : pageOpening(textScale: textScale, available: available)
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

/// A titled group of related controls with one explanation underneath: the grouped-Form
/// `Section { } header: { } footer: { }` shape, minus the box.
///
/// The caption is styled here (subheadline, secondary), but a caption that sets its own
/// `foregroundStyle` still wins, being closer to the text; that keeps the "Notifications are
/// disabled…" hint orange.
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
        // Spacing 0 with each gap spelled out: the title keeps its 9pt (`5 + sectionTitleAir`)
        // while the caption sits at the tighter `captionGap`, which one stack spacing can't do.
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
                // Subheadline (11pt), not caption (10pt): these are the sentences people read in
                // Settings, and at 10pt the sheet reads as too small. Micro labels elsewhere
                // (slider ends, stat labels, the version line) stay caption.
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                // Captions must wrap, not truncate: without this a `Text` in a horizontally
                // flexible stack reports a one-line ideal height and is clipped at the second line.
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

/// The left rail: the search field, the tabs, and the version line. Beside the content rather
/// than above it, so the content keeps its height and the tabs can be a list rather than a
/// segmented picker. `SettingsLayoutTests.theRailFitsItsOpening` checks a new tab still fits.
struct SettingsRail: View {
    @Binding var selection: SettingsView.SettingsTab
    /// The rail's selection lens in Frosted and Clear — see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("settings.rail")
    /// The part of the tab list on screen, from its scroll view.
    @State private var visibleTabs = SelectionLensVisibleRegion()
    @Binding var query: String
    /// The window's accent hue: fills the selected row, tints the hover wash on the others.
    let hue: LiquidGlassHue

    /// The marketing version drawn at the foot of the rail, injectable so tests can measure it.
    /// Under `swift test`, `Bundle.main` is the test host, which has no
    /// `CFBundleShortVersionString`, so the line would never render. The rail is fixed-width, so
    /// a long version wraps to a second row; `theVersionLineFitsTheRailOnOneLine` catches that.
    var versionText: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Rail width. Lives on `SettingsSheetMetrics` because a static on a SwiftUI `View` is
    /// `@MainActor`, and `contentWidth`, plain arithmetic, is not.
    static var width: CGFloat { SettingsSheetMetrics.railWidth }

    /// The width the version line lays out in: the rail, less its side inset and the horizontal
    /// inset it shares with the tab rows. Derived so it can't drift from `Rhythm`.
    static var versionTextWidth: CGFloat {
        width - 2 * Rhythm.sides - 2 * Rhythm.rowInsetH
    }

    /// The rail's vertical rhythm, measured against System Settings beside it: its sidebar rows
    /// run a ~34pt pitch with a clear gap under the search field, so the field and the first tab
    /// don't read as one block.
    private enum Rhythm {
        /// Gap between the search field and the first tab.
        static let searchGap: CGFloat = 16
        /// Between rows. Small, but enough that the selected row's fill reads as one row and
        /// not as a band across two.
        static let rowGap: CGFloat = 2
        /// Air above and below a group separator, beyond the `rowGap` on both sides of it. At 3, a
        /// separator and its air cost 9pt, enough for the divider to read as a break rather than
        /// a squeezed row; `theGroupSeparatorsAreReallyDrawn` measures the difference.
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

            // The tabs scroll, but only when they can't fit. `.basedOnSize`, as the content column
            // uses, keeps a scroller that fits perfectly still, so it costs a normal display
            // nothing. At the window's floor the tabs fit with little to spare
            // (`theRailFitsTheSheetTheWindowFloorProduces`); a host smaller than the main window
            // can shrink the sheet until they overrun (`theRailIsWhatTheFloorSizedSheetRunsOutOf`).
            // A fixed rail would lose its bottom rows silently: absent, not clipped.
            ScrollViewReader { rail in
                ScrollView {
                    TabList(selection: $selection, query: $query, hue: hue, visibleRegion: visibleTabs)
                }
                .scrollBounceBehavior(.basedOnSize)
                // What part of the tab list is on screen, for the selection lens: a move between
                // two rows not both visible switches instantly rather than crossing unseen rows.
                // Into the region rather than `@State`, which would re-render the rail per scroll
                // frame.
                .selectionLensTracksVisibleRegion(visibleTabs)
                // Bring the selected row into view when the rail can't show every row, or a deep
                // link (`cloudRefineSetup` opens Organize, sixth of nine rows) lands on a rail
                // showing no selection. Unanimated: it is a jump, and `withAnimation { scrollTo }`
                // does nothing while the display is asleep. A no-op when the row is visible.
                //
                // **No test covers this**: `onAppear` doesn't fire in an offscreen `NSHostingView`
                // driven by `layoutSubtreeIfNeeded`, so a render can't tell whether it worked. If it
                // silently fails, the rail just opens at the top.
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

    /// The tab rows on their own, outside the scroller, so tests can measure them. A `ScrollView`
    /// accepts any height it is offered, so the rail's own `fittingSize` can't say whether the
    /// tabs fit; tests lay this out and compare it with `SettingsRail.tabListOpening(in:)`.
    struct TabList: View {
        @Binding var selection: SettingsView.SettingsTab
        @Binding var query: String
        let hue: LiquidGlassHue
        /// The part of the list on screen, in its own coordinates — see `SelectionLensVisibleRegion`.
        var visibleRegion: SelectionLensVisibleRegion? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                // Grouped, because at this many rows a flat sidebar becomes a pile to scan. The
                // separator goes between groups only; above the first or below the last it would
                // read as a border on the rail.
                ForEach(Array(SettingsView.SettingsTab.railGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, Rhythm.rowInsetH)
                            .padding(.vertical, Rhythm.groupGap)
                    }
                    ForEach(group, id: \.self) { tab in
                        // `.id` as well as the `ForEach` id: `scrollTo` resolves the explicit id,
                        // which a row in a nested `ForEach` doesn't get from the outer loop.
                        railRow(tab).id(tab)
                    }
                }
            }
            // Frosted and Clear: the selected row's fill as one glass lens that glides between
            // rows. None while searching, when no row is selected.
            .selectionLensHost(SettingsRail.lensChannel, selected: isSearching ? nil : selection,
                               style: .fill(.roundedRect(Radius.chip), color: hue.accentFillColor),
                               visibleRegion: visibleRegion)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var isSearching: Bool {
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        @ViewBuilder
        private func railRow(_ tab: SettingsView.SettingsTab) -> some View {
            SettingsRail.railRow(tab, isSelected: selection == tab && !isSearching, hue: hue) {
                // Picking a tab is also the way out of a search: the results stood in for the
                // content column, and the user just said which content they want.
                selection = tab
                query = ""
            }
        }
    }

    /// The height the tab list has to fit in: the rail's opening, less its insets, the search field
    /// and its gap, and the version line. Derived so it can't drift from `Rhythm`, and taking the
    /// two measured heights as arguments because an estimate would skew the rail tests.
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
            .selectionLensLabelInk(isSelected: isSelected, onFill: hue.onAccentLabelColor, unselected: .primary)
            .padding(.horizontal, Rhythm.rowInsetH)
            .padding(.vertical, Rhythm.rowInsetV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    SelectionLensTodayMarker {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .fill(hue.accentFillColor)
                    }
                }
            }
            .selectionLensStop(SettingsRail.lensChannel, id: tab)
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        // A selected row already carries a solid fill, so at Solid it takes `.filled` (a ring and
        // a lift, no wash, since washing the accent over its own fill paints nothing) with the
        // tint flipped to the on-fill color. Under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: hue.accentColor,
                                        filledTint: hue.onAccentLabelColor, shape: .roundedRect(6))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The rail's search box: a magnifier, a plain text field, and a clear button once there's
/// text. A rounded field rather than `.searchable`, which is meant for navigation stacks, not an
/// overlay card.
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
