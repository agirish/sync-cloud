import AppKit
import Design
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// Visual snapshot net over FileExplorer's composite surfaces: StatPill, the Storage treemap's
/// tile-label pairing (the AccentLabel light-hue fix), DuplicateGroupCard, and ConditionChip
/// wrapping inside FlowLayout. Fixed sizes, frozen dates, light + dark; workflow and caveats
/// in Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct FileExplorerSnapshotTests {

    /// A frozen mtime for every fixture copy (2026-06-01 12:00 UTC) — never `Date()`, the
    /// card's meta line renders it through a DateFormatter.
    private static let fixedDate = Date(timeIntervalSince1970: 1_780_315_200)

    // MARK: StatPill

    /// The differences-header pills: count + label + tint per severity family, plus the
    /// chevron-affordance variant used when a pill doubles as a button.
    @Test func statPillVariants() {
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 8) {
                StatPill(count: 12, label: "Differences", color: .orange,
                         systemImage: "arrow.left.arrow.right")
                StatPill(count: 3, label: "conflicts", color: .red,
                         systemImage: "exclamationmark.triangle")
                StatPill(count: 1284, label: "identical", color: .green,
                         systemImage: "checkmark.circle")
                StatPill(count: 7, label: "risky names", color: .yellow,
                         systemImage: "textformat.abc.dottedunderline",
                         trailingSystemImage: "chevron.right")
            }
            .padding(12),
            size: CGSize(width: 240, height: 150),
            named: "variants")
    }

    /// `StatPill`'s four surfaces stacked for comparison: the accent capsule the differences pill
    /// actually ships (solid accent fill, paired label, and — since the freshness rework — NO
    /// leading dot), the `.attention` and `.neutral` families as whole capsules, and the tint wash.
    ///
    /// The two flat families are no longer what a stale or in-flight scan flips the pill to; that
    /// treatment moved into the age run (`StatPill.detailStyle`, referenced by
    /// `countPillFreshnessStates`). They stay here because they remain supported surfaces and this
    /// is the reference for what they look like at full capsule size.
    @Test func statPillSemanticCapsule() {
        assertViewSnapshot(
            of: SemanticStatPillSpecimen().padding(12),
            size: CGSize(width: 220, height: 150),
            named: "semantic-capsule")
    }

    /// Reads `colorScheme` from the environment rather than taking it as a parameter — the whole
    /// point of a semantic capsule is that its family is chosen per appearance, and a specimen
    /// pinned to one of them renders the light values into the dark reference.
    private struct SemanticStatPillSpecimen: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // Green, the hue the pill was designed against — not the environment's accent,
                // which would make this reference depend on the host's System Settings.
                //
                // `accentFillColor`, exactly as `DifferencesView` passes it. The raw `accentColor`
                // renders a brighter capsule that looks livelier in isolation and strands its white
                // label at 2.68:1 — the reference must show the pairing that ships.
                StatPill(count: 21, label: "Differences", color: .blue,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: .onAccent(fill: LiquidGlassHue.green.accentFillColor,
                                             label: LiquidGlassHue.green.onAccentLabelColor))
                StatPill(count: 21, label: "Differences", color: .blue,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: .of(.attention, scheme))
                StatPill(count: 21, label: "Differences", color: .blue,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: .of(.neutral, scheme))
                StatPill(count: 21, label: "Differences", color: .orange,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right")
            }
        }
    }

    /// The four dressings the differences count pill ships, in order: pre-scan (no age run, no
    /// chevron), fresh (bare age run), stale (the run wears terracotta), scanning (the run wears
    /// slate). Freshness used to be a separate badge in each pane header; this is the reference for
    /// it living on the count instead.
    ///
    /// What the eye must find here is that **the capsule never changes** — all four are the accent
    /// — and that only the age run does. That is the whole freshness rework: flipping the capsule
    /// made a stale pill read as *disabled* next to a saturated accent, on a control whose job is
    /// being clickable, and at the old ten-minute threshold it was in that state nearly always.
    ///
    /// The age run's RING is visible in the dark frame, and these references do NOT protect it —
    /// stated here because the opposite is the natural assumption. Deleting the ring and re-running
    /// this test passes: a 1pt stroke around two small capsules is a smaller share of the frame
    /// than the 0.99/0.98 tolerance absorbs. `StatPillDetailRingTests` measures the boundary in
    /// painted pixels precisely because these frames cannot.
    @Test func countPillFreshnessStates() {
        assertViewSnapshot(
            of: FreshnessCountPillSpecimen().padding(12),
            size: CGSize(width: 280, height: 170),
            named: "count-pill-freshness")
    }

    private struct FreshnessCountPillSpecimen: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            // Green, the hue the pill was designed against — not the environment's accent, which
            // would make this reference depend on the host's System Settings.
            let hue = LiquidGlassHue.green
            let accent = SemanticCapsuleStyle.onAccent(fill: hue.accentFillColor,
                                                       label: hue.onAccentLabelColor)
            // Four states, ONE capsule. The reference must show the accent surviving all of them —
            // if a future change puts a semantic family back on the outer capsule, these frames
            // are where it shows up.
            VStack(alignment: .leading, spacing: 10) {
                // Pre-scan: no age run at all, and no chevron (the toggle is a no-op here).
                StatPill(count: 0, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         semantic: accent)
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: accent,
                         detail: "0s ago")
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: accent,
                         detail: "2h ago",
                         detailStyle: .of(.attention, scheme))
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: accent,
                         detail: "scanning…",
                         detailStyle: .of(.neutral, scheme))
            }
        }
    }

    /// The grouped table's section header in its four states: expanded, collapsed (which earns a
    /// direction summary the expanded form does not need), fully-selected, and a long folder name
    /// that must middle-truncate rather than push its count off the row.
    @Test func differenceSectionHeaders() {
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 8) {
                DifferenceSectionHeader(folder: "Immigration", count: 13,
                                        accent: LiquidGlassHue.green.accentColor)
                DifferenceSectionHeader(folder: "Claude", count: 13,
                                        accent: LiquidGlassHue.green.accentColor,
                                        isCollapsed: true,
                                        directionSummary: "11 → Dropbox · 2 → iCloud")
                DifferenceSectionHeader(folder: "Work", count: 12,
                                        accent: LiquidGlassHue.green.accentColor,
                                        isFullySelected: true)
                DifferenceSectionHeader(folder: "Quarterly Board Reporting And Archive",
                                        count: 1284, accent: LiquidGlassHue.green.accentColor)
                    // Narrower on purpose: the truncation only happens under constraint, and a
                    // reference that lets the long name fit pins nothing about it.
                    .frame(width: 250, alignment: .leading)
            }
            .padding(12)
            .frame(width: 340, alignment: .leading),
            // 152, not the 120 this shipped with. At the old header height the fourth subject —
            // the long name that must middle-truncate — fell entirely off a 120pt canvas, so the
            // reference pinned three states while its own comment described four. Shortening the
            // header brought it half onto the canvas, which is worse than either: a clipped
            // subject makes the crop boundary itself the assertion. 152 fits all four.
            size: CGSize(width: 364, height: 152),
            named: "section-headers")
    }

    /// The Name and Path cells side by side, as the table now splits them: the name alone in the
    /// Name cell, the location in the Path cell anchored at the compared folder's name.
    ///
    /// `pathColumnText` is well covered as a pure function, but nothing else pins that the cell
    /// actually SHOWS its result — the cell could stop passing `rootName` through and every pure
    /// test would still pass. The last row is the entire point of the column: a ROOT-level file,
    /// whose location used to render as nothing at all (empty prefix, no section header), must
    /// print the compared folder's own name ("Home"), not a blank.
    @Test func differenceNameAndPathCells() {
        let paths = ["Claude/Projects/Investing/notes.md",
                     "Immigration/Authorization/H-1B/form.pdf",
                     "Work/report.docx",
                     "loose.pdf"]
        assertViewSnapshot(
            of: VStack(alignment: .leading, spacing: 3) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 12) {
                        DifferenceNameCell(difference: Self.difference(path))
                            .frame(width: 180, alignment: .leading)
                        DifferencePathCell(difference: Self.difference(path), rootName: "Home")
                    }
                }
            }
            .frame(width: 460, alignment: .leading)
            .padding(10),
            size: CGSize(width: 480, height: 120),
            named: "name-and-path-cells")
    }

    private static func difference(_ relativePath: String) -> FileDifference {
        FileDifference(relativePath: relativePath,
                       leftItemPath: "/l/\(relativePath)",
                       rightItemPath: "/r/\(relativePath)",
                       type: .missingOnRight,
                       action: .copyToRight,
                       description: "Missing on right")
    }

    /// **The load-bearing question for collapsing.** Collapsing is implemented by emitting no rows
    /// for a section, which only works if a `Section` with zero rows still renders its header — if
    /// SwiftUI drops empty sections, a collapsed folder VANISHES instead of collapsing.
    ///
    /// Rendered rather than reasoned about: this is a framework behaviour, and the failure mode is
    /// a folder silently disappearing from a table the user is about to act on. The reference must
    /// show three headers with only the middle section's rows present.
    @Test func collapsedSectionKeepsItsHeader() {
        assertViewSnapshot(
            of: CollapsedSectionSpecimen(),
            size: CGSize(width: 460, height: 280),
            named: "collapsed-section")
    }

    private struct CollapsedSectionSpecimen: View {
        private struct Row: Identifiable, Hashable {
            let id = UUID()
            let name: String
        }
        private let groups: [(String, [Row])] = [
            ("Claude", [Row(name: "a.md"), Row(name: "b.md")]),
            ("Immigration", [Row(name: "form.pdf"), Row(name: "receipt.pdf")]),
            ("Work", [Row(name: "report.docx")]),
        ]
        /// Claude and Work are collapsed; only Immigration emits rows.
        private let collapsed: Set<String> = ["Claude", "Work"]

        var body: some View {
            Table(of: Row.self) {
                TableColumn("Name") { Text($0.name) }
            } rows: {
                ForEach(groups, id: \.0) { folder, rows in
                    SwiftUI.Section {
                        ForEach(collapsed.contains(folder) ? [] : rows) { TableRow($0) }
                    } header: {
                        DifferenceSectionHeader(folder: folder, count: rows.count,
                                                accent: LiquidGlassHue.green.accentColor,
                                                isCollapsed: collapsed.contains(folder))
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
        }
    }

    // MARK: Treemap    // MARK: Treemap

    /// Five tiles wide enough (≥ 68 pt) to show name + size labels, and none narrow enough to
    /// fold — so the ramp runs its full length across them.
    ///
    /// **Rewritten for the sequential ramp.** It used to read "the palette assigns index 3 the
    /// AMBER hue", which was true of the rotating ten-hue palette and is meaningless now that
    /// colour is the ranking. What it guards is unchanged and is why the fixture still has five
    /// tiles: index 3 is the ramp's pale end, and its label must flip to near-black through
    /// `AccentLabel.prefersDarkText` exactly as amber's did. The plan for the ramp claimed this
    /// case away — "the pale end lands on the small tiles, which carry no labels" — and it does
    /// not, because the fold floors the smallest tile at the width labels begin at. "Other" stays
    /// neutral gray with a `.primary` label.
    @Test func treemapTileLabels() {
        let nodes = [
            TreemapNode(name: "Documents", path: "/d/Documents", bytes: 400),
            TreemapNode(name: "Photos", path: "/d/Photos", bytes: 300),
            TreemapNode(name: "Projects", path: "/d/Projects", bytes: 250),
            TreemapNode(name: "Backups", path: "/d/Backups", bytes: 220),   // amber tile
            TreemapNode(name: "Other", path: "", bytes: 180),
        ]
        assertViewSnapshot(
            of: TreemapView(nodes: nodes).padding(12),
            size: CGSize(width: 640, height: 112),
            named: "tile-labels")
    }

    // MARK: DuplicateGroupCard

    /// Collapsed file "Versions" group: type badge, middle-truncating name, subtitle,
    /// green reclaim figure, disclosure chevron. Collapsed deliberately — expansion would
    /// pull async QuickLook thumbnails into the tree.
    @Test func duplicateGroupCardCollapsedVersions() {
        let group = DuplicateGroup(
            matchType: .versions,
            name: "Quarterly Report final revised (2).pdf",
            isDirectory: false,
            copies: [
                Self.copy(path: "/d/Reports/Quarterly Report final revised (2).pdf", keeper: true),
                Self.copy(path: "/d/Reports/Old/Quarterly Report final.pdf", keeper: false),
                Self.copy(path: "/d/Desktop/Quarterly Report.pdf", keeper: false),
            ],
            reclaimableBytes: 4_812_000)
        assertViewSnapshot(
            of: DuplicateGroupCard(
                group: group, isExpanded: false, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 72),
            named: "collapsed-versions")
    }

    /// The same-text card, expanded: the unfilled seal that says "less certain than identical",
    /// the "same text, different bytes" subtitle, the note explaining that a signed or redacted
    /// copy would read the same too, and an action row that offers a per-group trash while the
    /// group stays out of "Apply recommended". Rendered because none of that is provable from
    /// geometry — the badge, the note and the button label are the whole claim.
    ///
    /// **The row includes "Compare copies", and that is the point of the reference being re-taken.**
    /// This is a FILE group, and the action was once gated to folders; ungating it is the whole
    /// premise of the compare surface. The reference was recorded before that landed, so it went on
    /// asserting a row that no longer existed — the render was right and the picture was stale.
    /// A source scan pins the gate's absence, but only this reference pins what the reader SEES,
    /// which is a button in a row of four rather than a control reachable in principle.
    @Test func duplicateGroupCardExpandedSameText() {
        let group = DuplicateGroup(
            matchType: .sameText,
            name: "Jul 2023.pdf",
            isDirectory: false,
            copies: [
                Self.copy(path: "/d/Home/Utilities/PG&E/2023/Jul 2023.pdf", keeper: true),
                Self.copy(path: "/d/Downloads/9829custbill07182023.pdf", keeper: false),
            ],
            reclaimableBytes: 402_394)
        assertViewSnapshot(
            of: DuplicateGroupCard(
                group: group, isExpanded: true, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 470),
            named: "expanded-same-text")
    }

    /// Expanded identical-folders group (directories skip the thumbnail strip, keeping the
    /// tree synchronous): keeper radio vs selectable radio, breadcrumbs with the provider
    /// crumb, Keep/Move-to-Trash fate chips, the safety note, and the action row including
    /// "Compare copies".
    @Test func duplicateGroupCardExpandedIdenticalFolders() {
        let group = DuplicateGroup(
            matchType: .identical,
            name: "Tax 2025",
            isDirectory: true,
            copies: [
                Self.copy(path: "/d/Documents/Tax 2025", keeper: true, isDirectory: true),
                Self.copy(path: "/d/Desktop/Backup/Tax 2025", keeper: false, isDirectory: true),
            ],
            reclaimableBytes: 96_400_000)
        assertViewSnapshot(
            of: DuplicateGroupCard(
                group: group, isExpanded: true, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 330),
            named: "expanded-identical-folders")
    }

    /// Compact-density twin of the expanded card above (same fixture, same canvas): pins the
    /// density behavior nothing else snapshots — tighter header/row padding and the hidden
    /// secondary detail lines — so a compact regression can't hide behind a green comfortable run.
    @Test func duplicateGroupCardExpandedIdenticalFoldersCompact() {
        let group = DuplicateGroup(
            matchType: .identical,
            name: "Tax 2025",
            isDirectory: true,
            copies: [
                Self.copy(path: "/d/Documents/Tax 2025", keeper: true, isDirectory: true),
                Self.copy(path: "/d/Desktop/Backup/Tax 2025", keeper: false, isDirectory: true),
            ],
            reclaimableBytes: 96_400_000)
        assertViewSnapshot(
            of: DuplicateGroupCard(
                group: group, isExpanded: true, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.compact.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 330),
            named: "expanded-identical-folders-compact")
    }

    // MARK: ConditionChip + FlowLayout

    /// A rule's condition chips at card width: chips wrap onto new lines, and one over-wide
    /// `mentions` chip is clamped to the container and elides with a tail — it must never
    /// draw past the trailing edge.
    @Test func conditionChipsWrapInFlowLayout() {
        assertViewSnapshot(
            of: FlowLayout(spacing: 5, lineSpacing: 5) {
                ConditionChip(icon: "doc", text: "kind is PDF")
                ConditionChip(icon: "textformat", text: "name contains “invoice”")
                ConditionChip(icon: "calendar", text: "older than 30 days")
                ConditionChip(
                    icon: "text.magnifyingglass",
                    text: "mentions “Statement of quarterly account activity for the household savings portfolio”")
                ConditionChip(icon: "internaldrive", text: "larger than 25 MB")
            }
            .padding(12),
            size: CGSize(width: 340, height: 120),
            named: "wrapping")
    }

    // MARK: Fixtures

    private static func copy(path: String, keeper: Bool, isDirectory: Bool = false) -> DuplicateCopy {
        DuplicateCopy(
            id: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            size: 96_400_000,
            itemCount: isDirectory ? 42 : 1,
            modificationDate: fixedDate,
            uniqueItemCount: 0,
            depth: path.components(separatedBy: "/").count - 2,
            isRecommendedKeeper: keeper)
    }
}
