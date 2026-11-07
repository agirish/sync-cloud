import SwiftUI
import AppKit
import Sync
import Design

// MARK: - StorageLensView

/// Storage Lens — the read-only "where does my space go?" surface. A treemap of the top areas over
/// three ranked lists (largest files, long-untouched files, and reclaim candidates). The only
/// action it offers is a Finder reveal: it never moves, deletes, or evicts a file. Rendered as the
/// Storage workspace's read-only lens.
struct StorageLensView: View {
    @ObservedObject var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    /// Which of the three lists are expanded (all open by default). Kept view-side; the report is
    /// the source of truth for the rows.
    @State private var collapsed: Set<StorageSection> = []

    private let providerName: String?
    /// The header card's live query. Filters the three ranked lists — NOT the treemap, which is a
    /// part-of-whole picture whose proportions a subset would misstate (see `StorageSearch`).
    private let query: StorageSearch.Query
    private let onBuild: () -> Void
    /// Reveals a path in Finder (NSWorkspace). The honest extent of "offload" in this landing.
    private let onReveal: (String) -> Void
    /// Presents a Quick Look preview for a file path. nil hides the per-row Preview button.
    private let onQuickLook: ((String) -> Void)?
    /// Which ranked list is showing, or nil for all three under the treemap. A `Binding` because
    /// the switcher lives in this card while `LensWorkspaceView` owns the `@AppStorage` behind it.
    @Binding private var section: StorageSection?

    init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        query: StorageSearch.Query = StorageSearch.parse(""),
        onBuild: @escaping () -> Void,
        onReveal: @escaping (String) -> Void,
        onQuickLook: ((String) -> Void)? = nil,
        section: Binding<StorageSection?> = .constant(nil)
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.query = query
        self.onBuild = onBuild
        self.onReveal = onReveal
        self.onQuickLook = onQuickLook
        self._section = section
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    private var report: StorageLensReport? { syncManager.storageLensReport }

    var body: some View {
        // The shared LensHeaderCard carries Storage's Re-analyze control, pills and search, so
        // this view is the content card alone and its header matches the other lenses.
        contentCard
    }

    // MARK: Content card

    @ViewBuilder
    private var contentCard: some View {
        VStack(spacing: 0) {
            if syncManager.isBuildingStorageLens {
                buildingState
            } else if let report {
                // Above the ScrollView, so scrolling a list never takes the switcher off screen.
                // Only with a report: before one there are no sections to switch between.
                sectionBar
                reportBody(report)
            } else {
                introState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The lens column's content section — a card in Cards, flush under the shared header in
        // Unified, where `LensWorkspaceView` frames the column as one region.
        .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// The section switcher, over the content it switches.
    private var sectionBar: some View {
        HStack {
            StorageSectionBar(section: $section,
                              accentFill: glassHue.accentFillColor,
                              onAccent: glassHue.onAccentLabelColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, densityMetrics.cardListPadding)
        .padding(.top, densityMetrics.cardListPadding)
    }

    // MARK: Intro / building states

    private var introState: some View {
        // The setup card: job, safety contract, one trigger, and sample rows in the ranked-list
        // shape, plus the read-only promise.
        LensSetupCard(
            intro: LensIntros.storage(providerName: providerName),
            accent: glassHue.accentColor,
            triggerTitle: "Analyze Storage",
            triggerSymbol: "chart.pie.fill",
            triggerHelp: "Map this folder’s biggest areas and rank its largest and longest-untouched files. Read-only.",
            samplesTitle: "What the ranked lists look like",
            samplesAccessibility: "Example of the ranked-list format: a file-type glyph, the "
                + "name, where it sits, and its size. These are samples, not files on your disk.",
            onStart: onBuild
        ) {
            LensSetupSampleRow {
                FileTypeGlyph.view(name: "sample.mp4", isDirectory: false, pointSize: 13)
                    .frame(width: 16)
                Text("Wedding highlights.mp4").scaledFont(.caption).lineLimit(1)
                Text("Events/2023").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text("1.2 GB").scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LensSetupSampleRow {
                FileTypeGlyph.view(name: "sample.pdf", isDirectory: false, pointSize: 13)
                    .frame(width: 16)
                Text("Scanned archive.pdf").scaledFont(.caption).lineLimit(1)
                Text("Legal/Old").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text("340 MB").scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LensSetupSampleRow {
                FileTypeGlyph.view(name: "sample.zip", isDirectory: false, pointSize: 13)
                    .frame(width: 16)
                Text("backup-2019.zip").scaledFont(.caption).lineLimit(1)
                Text("6 years ago").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text("2.8 GB").scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var buildingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.storageLensLifecycle.status ?? "Analyzing…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelBuildStorageLens() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Report body

    @ViewBuilder
    private func reportBody(_ report: StorageLensReport) -> some View {
        if report.totalBytes == 0 {
            EmptyStateView(
                icon: "externaldrive.badge.checkmark",
                tint: SemanticColor.success,
                title: "Nothing measurable here",
                message: "No files with size were found in \(scannedName). Analyze again after adding files.",
                secondary: .init("Analyze Again", systemImage: "arrow.clockwise", handler: onBuild)
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The treemap takes the report's nodes unfiltered: it answers "where does my
                    // space go?" for the whole tree, so a query's subset would misstate every
                    // proportion. The query narrows only the ranked lists. With a section picked
                    // the page is that list alone and the treemap goes too, so a whole-tree
                    // proportion never sits over a filtered list.
                    if section == nil { treemapSection(report) }
                    ForEach(StorageSection.allCases.filter { section == nil || section == $0 }) { s in
                        listSection(s, entries: s.entries(in: report).filter { query.matches($0) },
                                    report: report)
                    }
                }
                .padding(densityMetrics.cardListPadding)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var scannedName: String {
        guard let root = syncManager.storageLensRoot?.path else { return "this folder" }
        return (root as NSString).lastPathComponent
    }

    // MARK: Treemap section

    @ViewBuilder
    private func treemapSection(_ report: StorageLensReport) -> some View {
        if !report.treemap.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeaderLabel(icon: "square.grid.2x2.fill", tint: glassHue.accentColor,
                                   title: "Where space concentrates",
                                   subtitle: "Top areas by total size")
                TreemapView(nodes: report.treemap, hue: glassHue)
            }
        }
    }

    // MARK: List sections

    /// - Note: Collapsing applies to the All page only. The fold is for triaging three stacked
    ///   lists; on a page narrowed to one section, a fold left over from All would show a lone
    ///   collapsed header for the list just picked. The set is kept, so All restores its folds.
    ///
    ///   On a narrowed page the header is not a control at all, so a click there can't fold the
    ///   section on All unseen. Not a disabled button either: that still announces itself to
    ///   VoiceOver and costs Full Keyboard Access a stop.
    private func listSection(_ section: StorageSection, entries: [StorageEntry],
                             report: StorageLensReport) -> some View {
        let canCollapse = self.section == nil
        // The bar's yardstick is the section's own biggest file, not the query-narrowed
        // `entries`, so the bars don't rescale as someone types. See `StorageMagnitude.fraction`.
        let largestBytes = StorageMagnitude.showsBar(section)
            ? (section.entries(in: report).map(\.bytes).max() ?? 0) : 0
        let isCollapsed = canCollapse && collapsed.contains(section)
        let count = StorageSection.PillCount(shown: entries.count,
                                             listed: section.entries(in: report).count,
                                             total: section.total(in: report))
        return VStack(alignment: .leading, spacing: 8) {
            if canCollapse {
                Button {
                    if isCollapsed { collapsed.remove(section) } else { collapsed.insert(section) }
                } label: {
                    listSectionHeader(section, count: count,
                                      canCollapse: true, isCollapsed: isCollapsed)
                }
                .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor))
                .help(isCollapsed ? "Show this section’s files" : "Hide this section’s files")
            } else {
                // Not a disabled button, which VoiceOver would announce as unavailable: the same
                // row drawn plain, as `treemapSection`'s header is.
                listSectionHeader(section, count: count,
                                  canCollapse: false, isCollapsed: false)
            }

            if !isCollapsed {
                if entries.isEmpty {
                    // Under a live query the section's own empty text would lie — "Nothing here"
                    // claims the scan found none, when the query is what hid them.
                    Text(query.isEmpty ? section.emptyText : "No files here match your search.")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: densityMetrics.cardListSpacing) {
                        ForEach(entries) { entry in
                            StorageEntryRow(
                                entry: entry,
                                relativeFolder: displayFolder(entry.path),
                                showAge: section == .stale,
                                offloadStyle: section == .reclaim,
                                barFraction: StorageMagnitude.fraction(bytes: entry.bytes,
                                                                       largestBytes: largestBytes),
                                shareText: StorageMagnitude.shareText(bytes: entry.bytes,
                                                                      ofTotal: report.totalBytes),
                                scannedName: scannedName,
                                densityMetrics: densityMetrics,
                                onReveal: { onReveal(entry.path) },
                                onPreview: onQuickLook.map { ql in { ql(entry.path) } }
                            )
                        }
                    }
                }
            }
        }
    }

    /// One list-section header row, drawn the same whether or not a button wraps it. The chevron
    /// shows only where the fold applies; the trailing `Spacer` keeps the title from shifting.
    ///
    /// `canCollapse` is passed in rather than re-read from the view's `section`, which the first
    /// parameter shadows: a dropped `self.` would compile and take the chevron off the All page.
    @ViewBuilder
    private func listSectionHeader(_ section: StorageSection, count: StorageSection.PillCount,
                                   canCollapse: Bool, isCollapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.icon)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(section.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(section.subtitle)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The mini pill every section count in the app wears. Neutral tint: a list size,
            // never urgency.
            Pill(.mini, tint: .secondary, text: count.text, isNumeric: true)
                .accessibilityLabel(count.speech)
            Spacer(minLength: 0)
            if canCollapse {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .hoverInk()
            }
        }
    }

    private func sectionHeaderLabel(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(.system(size: 13, weight: .semibold))
                Text(subtitle).scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Path helpers

    /// The file's containing folder, shown relative to the scanned root when possible (so rows read
    /// "Photos/2023" not the whole absolute path), else tilde-abbreviated.
    private func displayFolder(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if let root = syncManager.storageLensRoot?.path, !root.isEmpty {
            let standardizedRoot = (root as NSString).standardizingPath
            let standardizedParent = (parent as NSString).standardizingPath
            if standardizedParent == standardizedRoot { return scannedName }
            if standardizedParent.hasPrefix(standardizedRoot + "/") {
                let rel = String(standardizedParent.dropFirst(standardizedRoot.count + 1))
                return "\(scannedName)/\(rel)"
            }
        }
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Section bar

/// Storage's section switcher, All · Largest · Untouched · Reclaim, as a capsule at the top of the
/// content card. It lives here, not in the header, because the header's rail slot belongs to
/// Organize and two rails in one header would shed by different rules (`OrganizeRailMetrics`).
///
/// Follows ``EditorModeBar``'s three choices:
///
/// - `ViewThatFits` over two rungs, labelled then glyph-only, rather than width arithmetic.
/// - Semibold in both selection states, because weight changes width and a bolded selection
///   would move everything beside it on every click. The fill marks the selection.
/// - Glyphs in a framed box (``CapsuleGlyph``), because the four symbols draw at different widths
///   and an unframed row would resize as the selection moves. Shared with the Editor's capsule.
///
/// `nil` is All, matching ``StorageSection/defaultsKey``: there is no value for "no section
/// picked" to write, so nothing to migrate.
struct StorageSectionBar: View {

    @Binding var section: StorageSection?
    /// The selected segment's fill, and its lens and hover — the deepened accent, so the white
    /// label on it clears AA (`LiquidGlassHue.accentFillColor`), as on ``EditorModeBar``.
    let accentFill: Color
    let onAccent: Color
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: Rung?

    /// The two rungs, named so a test can ask for one rather than trying to provoke it.
    enum Rung { case labelled, glyphOnly }

    /// The segments in order, `nil` first. Built from `StorageSection.allCases`, so a new section
    /// is a segment the day it is added.
    private var segments: [StorageSection?] { [nil] + StorageSection.allCases }

    var body: some View {
        if let forcedRung {
            capsule(labelled: forcedRung == .labelled)
        } else {
            ViewThatFits(in: .horizontal) {
                capsule(labelled: true)
                capsule(labelled: false)
            }
        }
    }

    private func capsule(labelled: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(segments, id: \.self) { candidate in
                segment(candidate, labelled: labelled)
            }
        }
        // Frosted and Clear: one glass lens that glides between sections.
        .selectionLensHost(Self.lensChannel, selected: Self.lensID(section), style: .fill(.capsule, color: accentFill))
        .padding(2)
        // Frosted and Clear: a glass track, like the bar's other controls (`ChromeGlass`).
        .chromeGlassTrack()
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage section")
    }

    /// The bar's selection lens in Frosted and Clear — see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("storage.sections")

    /// A segment's lens identity. All is the absence of a ``StorageSection``, so it needs a name
    /// of its own, or "All selected" would read as nothing selected and draw no lens.
    static func lensID(_ candidate: StorageSection?) -> String {
        candidate?.rawValue ?? "all"
    }

    /// The label for a segment. All is not a ``StorageSection``, so its word lives here, as
    /// `OrganizeRailMetrics.overviewTitle` does for Organize.
    private func title(_ candidate: StorageSection?) -> String {
        candidate?.railTitle ?? "All"
    }

    private func symbol(_ candidate: StorageSection?) -> String {
        candidate?.railSymbol ?? "square.grid.2x2"
    }

    private func segment(_ candidate: StorageSection?, labelled: Bool) -> some View {
        let isSelected = section == candidate
        return Button {
            section = candidate
        } label: {
            HStack(spacing: 4) {
                CapsuleGlyph(symbol: symbol(candidate))
                if labelled {
                    Text(title(candidate))
                        .scaledFont(.system(size: 10, weight: .semibold))
                }
            }
            .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
            .padding(.horizontal, labelled ? 8 : 6)
            .padding(.vertical, 3)
            .background {
                if isSelected { SelectionLensTodayMarker { Capsule().fill(accentFill) } }
            }
            .selectionLensStop(Self.lensChannel, id: Self.lensID(candidate))
            .contentShape(Capsule())
        }
        // `.filled` for the chosen section at Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accentFill)
        // Once the word is shed, the tooltip and the accessibility label still name the section.
        .help(title(candidate))
        .accessibilityLabel(title(candidate))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Sections

/// The three ranked lists under the treemap, each with its own glyph, tint, and copy.
/// `CaseIterable` because the section switcher builds its segments from `allCases`.
enum StorageSection: String, Hashable, CaseIterable, Identifiable {
    case largest, stale, reclaim

    var id: String { rawValue }

    /// The defaults key holding the switcher's selection. Absent means All, as with
    /// ``OrganizeLens/defaultsKey``: inventing a value for "no section picked" would only make
    /// something to migrate.
    static let defaultsKey = "selectedStorageSection"

    /// The switcher's label, shorter than ``title``, which heads a list and can afford the words.
    var railTitle: String {
        switch self {
        case .largest: return "Largest"
        case .stale: return "Untouched"
        case .reclaim: return "Reclaim"
        }
    }

    /// The switcher's glyph. Unfilled, matching Organize's rail; ``icon`` keeps the filled variant
    /// for the section heading.
    var railSymbol: String {
        switch self {
        case .largest: return "arrow.up.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .reclaim: return "internaldrive"
        }
    }

    /// "N of M" for whatever the page is showing: `section` nil means all three lists, one means
    /// that list only. Pure, so `theOfMCountsFollowTheRail` can assert it directly.
    ///
    /// `matching` is the search predicate: the selection picks the lists, the query narrows within
    /// them, and N-of-M needs both.
    static func counts(in report: StorageLensReport, section: StorageSection?,
                       matching: (StorageEntry) -> Bool) -> (filtered: Int, total: Int) {
        let lists = (section.map { [$0] } ?? allCases).map { $0.entries(in: report) }
        return (lists.reduce(0) { $0 + $1.filter(matching).count },
                lists.reduce(0) { $0 + $1.count })
    }

    /// This section's entries in a report: the one place the mapping lives, so a count and its
    /// list can't disagree.
    func entries(in report: StorageLensReport) -> [StorageEntry] {
        switch self {
        case .largest: return report.largest
        case .stale: return report.stale
        case .reclaim: return report.reclaimCandidates
        }
    }

    /// How many files the whole tree has in this section, counted before the list was capped —
    /// nil on a report saved before the totals existed.
    func total(in report: StorageLensReport) -> Int? {
        switch self {
        case .largest: return report.fileCount
        case .stale: return report.staleCount
        case .reclaim: return report.reclaimCount
        }
    }

    /// A section header's count pill: "20 of 318" when the capped list is the top of a longer one,
    /// so it agrees with the Overview's whole-tree count. The total shows only when it says
    /// something: not when it equals the list, not on a report without totals, and not during a
    /// search, which reaches only the listed rows.
    struct PillCount: Equatable {
        let text: String
        let speech: String

        init(shown: Int, listed: Int, total: Int?) {
            if shown == listed, let total, total > listed {
                text = "\(listed.formatted()) of \(total.formatted())"
                speech = "\(listed.formatted()) of \(total.formatted()) files"
            } else {
                text = shown.formatted()
                speech = shown == 1 ? "1 file" : "\(shown.formatted()) files"
            }
        }
    }

    var icon: String {
        switch self {
        case .largest: return "arrow.up.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .reclaim: return "internaldrive"
        }
    }
    var tint: Color {
        switch self {
        case .largest: return SemanticColor.info
        case .stale: return SemanticColor.warning
        case .reclaim: return SemanticColor.success
        }
    }
    var title: String {
        switch self {
        case .largest: return "Largest files"
        case .stale: return "Untouched for a long time"
        case .reclaim: return "Reclaim candidates"
        }
    }
    var subtitle: String {
        switch self {
        case .largest: return "The biggest individual files"
        case .stale: return "Not changed in a long while — oldest first"
        case .reclaim: return "Large and long-idle — worth keeping online-only"
        }
    }
    var emptyText: String {
        switch self {
        case .largest: return "No files with measurable size."
        case .stale: return "Nothing has been sitting untouched."
        case .reclaim: return "No large, long-idle files to offload."
        }
    }
}

// MARK: - Row

/// One file row in a Storage Lens list. Read-only by construction: the trailing controls only
/// reveal the file in Finder (the honest extent of "offload") or open a Quick Look preview.
private struct StorageEntryRow: View {
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// Tint for this row's two hover-affordance glyphs, matching the lens chrome around them.
    private var rowAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }
    let entry: StorageEntry
    let relativeFolder: String
    /// When true, show the file's age (used by the stale list).
    let showAge: Bool
    /// When true, the reveal control renders as a prominent "Offload…" button with the
    /// Finder-handoff explainer; otherwise it's a quiet reveal glyph.
    let offloadStyle: Bool
    /// This file against the biggest one in its section, 0...1. Zero draws no bar — either the
    /// section is not size-ordered (`StorageMagnitude.showsBar`) or the file has no bytes.
    let barFraction: Double
    /// This file as a share of everything the scan measured, already rounded and worded, or nil
    /// when there is nothing truthful to say.
    let shareText: String?
    /// The scanned folder's name — what the share figure is a share *of*, for the tooltip and the
    /// spoken label, where a bare "18%" says nothing.
    let scannedName: String
    /// Row measurements per the appearance density setting.
    let densityMetrics: ListDensityMetrics
    let onReveal: () -> Void
    let onPreview: (() -> Void)?

    /// Pointer over the row. Drives the two quiet glyphs together — a per-glyph hover would
    /// reveal one at a time as the pointer crossed the pair.
    @State private var isHovered = false
    /// Which of the two glyphs has keyboard focus, if either. The second half of
    /// `StorageMagnitude.controlsRevealed`: focus reveals, so Full Keyboard Access never rings a
    /// control that is painting nothing.
    @FocusState private var focusedControl: RowControl?

    private enum RowControl: Hashable { case preview, reveal }

    private var controlsRevealed: Bool {
        StorageMagnitude.controlsRevealed(isHovered: isHovered, isFocused: focusedControl != nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            // FileTypeGlyph: in a ranked list of mixed types, shape and tint find "that big audio
            // file" without reading rows.
            FileTypeGlyph.view(name: entry.name, isDirectory: false, pointSize: 16)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The folder and age line is the secondary detail compact hides; name and size
                // still identify the file.
                if densityMetrics.showsSecondaryDetail {
                    HStack(spacing: 6) {
                        Text(relativeFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if showAge, let age = ageText {
                            Text("· \(age)")
                                .lineLimit(1)
                        }
                    }
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(FileSyncManager.formatBytes(entry.bytes))
                .scaledFont(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            // Beside the size, not under it: a second line would change the row height that
            // `densityMetrics` owns. Fixed width, sized for "<1%" and "100%", keeps a column.
            if let shareText {
                Text(shareText)
                    .scaledFont(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .help("\(shareText) of \(scannedName)")
                    .accessibilityLabel("\(shareText) of \(scannedName)")
            }
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye").padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: rowAccent))
                .padding(-4)
                .controlSize(.small)
                .focused($focusedControl, equals: .preview)
                .opacity(controlsRevealed ? 1 : 0)
                .help("Preview with Quick Look")
                .accessibilityLabel("Preview with Quick Look")
            }
            if offloadStyle {
                Button(action: onReveal) {
                    Label("Offload…", systemImage: "icloud.and.arrow.up")
                }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover(tint: rowAccent)
                .help("Reveals the file in Finder — use Finder to keep it online-only and free local space")
            } else {
                Button(action: onReveal) {
                    Image(systemName: RevealGlyph.inFinder).padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: rowAccent))
                .padding(-4)
                .controlSize(.small)
                .focused($focusedControl, equals: .reveal)
                .opacity(controlsRevealed ? 1 : 0)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
        }
        .padding(.horizontal, 12)
        // Clamped, not substituted: this row's comfortable padding (8) is under the shared
        // metric (11), so comfortable stays 8 and compact takes the metric's 6.
        .padding(.vertical, min(8, densityMetrics.cardRowVerticalPadding))
        .background { rowGround }
        .onHover { isHovered = $0 }
    }

    /// The row's ground and the magnitude bar on it. The `GeometryReader` in `.background` reads
    /// the row's width without proposing a size back to it.
    ///
    /// A nonzero bar keeps a 3pt floor, as `TreemapView.tile` does, so a real file never reads as
    /// absent. Clipped to the ground's corner radius, so a full-width bar has no square corners.
    private var rowGround: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(0.04))
                if barFraction > 0 {
                    Rectangle()
                        .fill(rowAccent.opacity(0.16))
                        .frame(width: max(3, geo.size.width * barFraction))
                }
            }
            .clipShape(shape)
        }
        // Decoration: the size and the share beside it are what carries this to VoiceOver.
        .accessibilityHidden(true)
    }

    /// A coarse "N years/months/days ago" for the stale list, from the file's mtime.
    private var ageText: String? {
        guard let modified = entry.modified else { return nil }
        let seconds = Date().timeIntervalSince(modified)
        guard seconds > 0 else { return nil }
        let days = Int(seconds / 86_400)
        if days >= 730 { return "\(days / 365) years ago" }
        if days >= 365 { return "1 year ago" }
        if days >= 60 { return "\(days / 30) months ago" }
        if days >= 30 { return "1 month ago" }
        return "\(days) days ago"
    }
}
