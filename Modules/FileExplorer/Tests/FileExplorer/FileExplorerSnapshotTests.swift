import AppKit
import Design
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// Visual snapshot net over FileExplorer's composite surfaces: StatPill, the Storage treemap's
/// tile-label pairing, DuplicateGroupCard, and ConditionChip wrapping inside FlowLayout. Fixed
/// sizes, frozen dates, light + dark; workflow and caveats in
/// Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct FileExplorerSnapshotTests {

    /// A frozen mtime for every fixture copy (2026-06-01 12:00 UTC), never `Date()`: the card's
    /// meta line renders it through a DateFormatter.
    private static let fixedDate = Date(timeIntervalSince1970: 1_780_315_200)

    /// The zone the cards below render their "modified" date in, so these references hold the
    /// card's layout and not the recording machine's location.
    ///
    /// A frozen `Date` is only half of a frozen string: without a pinned zone, a reference baked in
    /// one zone goes red on an unchanged fixture when the Mac moves to another, and reads as a
    /// colour regression. 12:00 UTC happens to land on the same calendar day either side and the
    /// card prints no clock, but the pin keeps that from resting on luck. UTC, matching the fixture
    /// date above.
    private static let pinnedZone = TimeZone(identifier: "UTC")!

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
    /// ships (solid accent fill, paired label, no leading dot), the `.attention` and `.neutral`
    /// families as whole capsules, and the tint wash.
    ///
    /// A stale or in-flight scan doesn't flip the pill to the flat families; that treatment
    /// lives in the age run (`StatPill.detailStyle`, see `countPillFreshnessStates`). They stay
    /// here because they remain supported surfaces and this is the reference for them at full
    /// capsule size.
    @Test func statPillSemanticCapsule() {
        assertViewSnapshot(
            of: SemanticStatPillSpecimen().padding(12),
            size: CGSize(width: 220, height: 150),
            named: "semantic-capsule")
    }

    /// Reads `colorScheme` from the environment rather than taking it as a parameter: a semantic
    /// capsule's family is chosen per appearance, and a specimen pinned to one of them renders the
    /// light values into the dark reference.
    private struct SemanticStatPillSpecimen: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // Green, the hue the pill was designed against, not the environment's accent, which
                // would make this reference depend on the host's System Settings.
                //
                // `accentFillColor`, exactly as `DifferencesView` passes it. The raw `accentColor`
                // renders a brighter capsule that strands its white label at 2.68:1; the reference
                // must show the pairing that ships.
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
    /// slate).
    ///
    /// What the eye must find here is that the capsule never changes (all four are the accent) and
    /// only the age run does. Flipping the capsule would make a stale pill read as disabled next to
    /// a saturated accent, on a control whose job is being clickable.
    ///
    /// The age run's ring is visible in the dark frame, and these references do not protect it:
    /// deleting the ring still passes, because a 1pt stroke around two small capsules is a smaller
    /// share of the frame than the 0.99/0.98 tolerance absorbs. `StatPillDetailRingTests` measures
    /// the boundary in painted pixels because these frames cannot.
    @Test func countPillFreshnessStates() {
        assertViewSnapshot(
            of: FreshnessCountPillSpecimen().padding(12),
            size: CGSize(width: 280, height: 170),
            named: "count-pill-freshness")
    }

    private struct FreshnessCountPillSpecimen: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            // Green, the hue the pill was designed against, not the environment's accent, which
            // would make this reference depend on the host's System Settings.
            let hue = LiquidGlassHue.green
            let accent = SemanticCapsuleStyle.onAccent(fill: hue.accentFillColor,
                                                       label: hue.onAccentLabelColor)
            // Four states, one capsule. The reference must show the accent surviving all of them; a
            // change that puts a semantic family back on the outer capsule shows up in these
            // frames.
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
            // 152 fits all four subjects. Shorter, the fourth (the long name that must
            // middle-truncate) falls partly or wholly off the canvas, and a clipped subject makes
            // the crop boundary itself the assertion.
            size: CGSize(width: 364, height: 152),
            named: "section-headers")
    }

    /// The Name and Path cells side by side, as the table splits them: the name alone in the Name
    /// cell, the location in the Path cell anchored at the compared folder's name.
    ///
    /// `pathColumnText` is covered as a pure function, but nothing else pins that the cell shows
    /// its result: the cell could stop passing `rootName` through and every pure test would still
    /// pass. The last row is the point of the column: a root-level file (empty prefix, no section
    /// header) must print the compared folder's own name ("Home"), not a blank.
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

    /// The load-bearing question for collapsing. Collapsing emits no rows for a section, which only
    /// works if a `Section` with zero rows still renders its header; if SwiftUI dropped empty
    /// sections, a collapsed folder would vanish instead of collapsing.
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

    /// Five tiles wide enough (≥ 68 pt) to show name + size labels, and none narrow enough to fold,
    /// so the ramp runs its full length across them.
    ///
    /// Index 3 is the sequential ramp's pale end, and its label must flip to near-black through
    /// `AccentLabel.prefersDarkText`. The pale end does not only land on small unlabelled tiles:
    /// the fold floors the smallest tile at the width labels begin at. "Other" stays neutral gray
    /// with a `.primary` label.
    @Test func treemapTileLabels() {
        let nodes = [
            TreemapNode(name: "Documents", path: "/d/Documents", bytes: 400),
            TreemapNode(name: "Photos", path: "/d/Photos", bytes: 300),
            TreemapNode(name: "Projects", path: "/d/Projects", bytes: 250),
            TreemapNode(name: "Backups", path: "/d/Backups", bytes: 220),   // the ramp's pale end
            TreemapNode(name: "Other", path: "", bytes: 180),
        ]
        assertViewSnapshot(
            of: TreemapView(nodes: nodes).padding(12),
            size: CGSize(width: 640, height: 112),
            named: "tile-labels")
    }

    // MARK: DuplicateGroupCard

    /// Collapsed file "Versions" group: type badge, middle-truncating name, subtitle, green reclaim
    /// figure, disclosure chevron. Collapsed deliberately: expansion would pull async QuickLook
    /// thumbnails into the tree.
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
                timeZone: Self.pinnedZone,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 72),
            named: "collapsed-versions")
    }

    /// The same-text card, expanded: the unfilled seal that says "less certain than identical", the
    /// "same text, different bytes" subtitle, the note explaining that a signed or redacted copy
    /// would read the same too, and an action row that offers a per-group trash while the group
    /// stays out of "Apply recommended". Rendered because none of that is provable from geometry:
    /// the badge, the note and the button label are the whole claim.
    ///
    /// The row includes "Compare Copies", offered for file groups as well as folders. A source scan
    /// pins that no folder-only gate exists, but only this reference pins what the reader sees: a
    /// button in a row of four.
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
                timeZone: Self.pinnedZone,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 470),
            named: "expanded-same-text")
    }

    /// Expanded identical-folders group (directories skip the thumbnail strip, keeping the
    /// tree synchronous): keeper radio vs selectable radio, breadcrumbs with the provider
    /// crumb, Keep/Move-to-Trash fate chips, the safety note, and the action row including
    /// "Compare Copies".
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
                timeZone: Self.pinnedZone,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 330),
            named: "expanded-identical-folders")
    }

    /// Compact-density twin of the expanded card above (same fixture, same canvas): pins the
    /// density behaviour nothing else snapshots (tighter header and row padding, hidden secondary
    /// detail lines), so a compact regression can't hide behind a green comfortable run.
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
                timeZone: Self.pinnedZone,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
                .padding(12),
            size: CGSize(width: 640, height: 330),
            named: "expanded-identical-folders-compact")
    }

    // MARK: ConditionChip + FlowLayout

    /// A rule's condition chips at card width: chips wrap onto new lines, and one over-wide
    /// `mentions` chip is clamped to the container and elides with a tail; it must never draw past
    /// the trailing edge.
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

    // MARK: Activity

    /// Activity's Now, as the capsule's popover draws it: two runs, each with its Stop, then Recent
    /// (a folded refusal, an Undo greyed behind a newer step, a warning's detail line and a run's
    /// links) and the foot. Fixed clock, no undo manager.
    @Test func activityNowPopover() {
        let center = ActivityCenter()
        let now = Self.fixedDate
        center.record(ActivityMessage(date: now.addingTimeInterval(-540),
                                      message: "Saved 5 of 6 as PDF. “Budget 2026.numbers” couldn’t be saved.",
                                      detail: "Budget 2026.numbers — it isn’t downloaded", severity: .warning),
                      seen: true)
        center.record(ActivityMessage(date: now.addingTimeInterval(-240), message: "Merged “Photos” — folded 7,363 files into Photos.",
                                      severity: .success, runId: UUID()), seen: true)
        for _ in 1...4 {
            center.record(ActivityMessage(date: now.addingTimeInterval(-120), message: "Wait for the merge to finish",
                                          severity: .warning), seen: true)
        }
        let merge = ProgressCapsuleRun(title: "Merging “Photos”", completed: 736, total: 7363, detail: "IMG_2034.jpg")
        let pdf = ProgressCapsuleRun(title: "Compressing — page 14 of 40", completed: 14, total: 40,
                                     detail: "Lease 2026.pdf", cancelTitle: "Stop")
        assertViewSnapshot(
            of: ActivityNowView(runs: [
                ProgressCapsuleListedRun(id: "merge", run: merge, symbol: "doc.on.doc", startedAt: nil, onCancel: {}),
                ProgressCapsuleListedRun(id: "pdf", run: pdf, symbol: "wrench.and.screwdriver", startedAt: nil,
                                         onCancel: {}),
            ], center: center, runWriteLock: nil, now: now, onOpenWindow: {})
            .environment(\.timeZone, Self.pinnedZone)
            .environment(\.controlActiveState, .key),
            size: CGSize(width: ProgressCapsuleRunList.width, height: 520),
            named: "two-runs-and-recent")
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
