import AppKit
import Design
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// Visual snapshot net over FileExplorer's composite surfaces: StatPill, the Storage treemap's
/// tile-label pairing (the AccentLabel light-hue fix), TidyGroupCard, and ConditionChip
/// wrapping inside FlowLayout. Fixed sizes, frozen dates, light + dark; workflow and caveats
/// in Modules/Design/Tests/DesignTests/SNAPSHOTS.md.
@MainActor
@Suite(.serialized) struct FileExplorerSnapshotTests {

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

    /// The differences count pill on the flat-capsule path, all three flavors stacked so the point
    /// of the change is visible as a comparison: the accent capsule the pill actually ships (solid
    /// accent fill, paired label, ringed terracotta dot), the `.attention` family a stale scan
    /// flips it to, and `.neutral`. Last row is the tint wash they replaced.
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

    /// The three dressings the differences count pill actually ships, in order: fresh (the accent
    /// capsule it always wore, now with an age run), stale (flat terracotta), scanning (flat
    /// slate). Freshness used to be a separate badge in each pane header; this is the reference
    /// for it living on the count instead.
    ///
    /// What the eye must find here is that **the fill changes**, and that the dot does not. On a
    /// saturated accent capsule nothing coloured clears 3:1 (`SemanticCapsuleStyle.dotRing`), so a
    /// fresh→stale flip carried by the dot would be a signal nobody is guaranteed to see — and an
    /// earlier cut that recoloured it green rendered green-on-green under the green accent, a
    /// hollow ring that read as an empty checkbox.
    @Test func countPillFreshnessStates() {
        assertViewSnapshot(
            of: FreshnessCountPillSpecimen().padding(12),
            size: CGSize(width: 260, height: 130),
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
            VStack(alignment: .leading, spacing: 10) {
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: accent,
                         detail: "0s ago")
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: .of(.attention, scheme),
                         detail: "29m ago")
                StatPill(count: 576, label: "Differences", color: hue.accentColor,
                         systemImage: "exclamationmark.triangle",
                         trailingSystemImage: "chevron.right",
                         semantic: .of(.neutral, scheme),
                         detail: "scanning…")
            }
        }
    }

    // MARK: Treemap

    /// Five tiles wide enough (≥ 68 pt) to show name + size labels. The palette assigns
    /// index 3 the AMBER hue — the light tile whose hardcoded-white label was ~2.4:1 and now
    /// must render near-black via `AccentLabel.prefersDarkText`. "Other" stays neutral gray
    /// with a `.primary` label.
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

    // MARK: TidyGroupCard

    /// Collapsed file "Versions" group: type badge, middle-truncating name, subtitle,
    /// green reclaim figure, disclosure chevron. Collapsed deliberately — expansion would
    /// pull async QuickLook thumbnails into the tree.
    @Test func tidyGroupCardCollapsedVersions() {
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
            of: TidyGroupCard(
                group: group, isExpanded: false, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {})
                .padding(12),
            size: CGSize(width: 640, height: 72),
            named: "collapsed-versions")
    }

    /// Expanded identical-folders group (directories skip the thumbnail strip, keeping the
    /// tree synchronous): keeper radio vs selectable radio, breadcrumbs with the provider
    /// crumb, Keep/Move-to-Trash fate chips, the safety note, and the action row including
    /// "Compare copies".
    @Test func tidyGroupCardExpandedIdenticalFolders() {
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
            of: TidyGroupCard(
                group: group, isExpanded: true, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.comfortable.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {})
                .padding(12),
            size: CGSize(width: 640, height: 330),
            named: "expanded-identical-folders")
    }

    /// Compact-density twin of the expanded card above (same fixture, same canvas): pins the
    /// density behavior nothing else snapshots — tighter header/row padding and the hidden
    /// secondary detail lines — so a compact regression can't hide behind a green comfortable run.
    @Test func tidyGroupCardExpandedIdenticalFoldersCompact() {
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
            of: TidyGroupCard(
                group: group, isExpanded: true, providerName: "iCloud Drive", scanRoot: "/d",
                densityMetrics: ListDensity.compact.metrics,
                onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                onChooseKeeper: { _ in }, onMerge: {})
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
