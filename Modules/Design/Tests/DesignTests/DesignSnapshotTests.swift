import AppKit
import SwiftUI
import Testing
@testable import Design

/// Visual snapshot net over the Design module's shared surfaces — the components that burned
/// us in review rounds and were only caught by code-reading: TokenChipsRow (hit targets,
/// superseded dimming), StatusBadge, EmptyStateView, ProgressDialog. Each scenario renders at
/// a fixed size in light and dark against committed reference images (see SNAPSHOTS.md for
/// the re-record workflow and the single-machine caveat).
@MainActor
@Suite(.serialized) struct DesignSnapshotTests {

    // MARK: TokenChipsRow

    private static let activeItems: [TokenChipsRow.Item] = [
        .init(label: "type:pdf", word: "type:pdf", isActive: true),
        .init(label: "size:>10mb", word: "size:>10mb", isActive: true),
        .init(label: "invoice", word: "invoice", isActive: true),
    ]

    @Test func tokenChipsRowActive() {
        assertViewSnapshot(
            of: TokenChipsRow(items: Self.activeItems, tint: .blue, onRemove: { _ in })
                .padding(12),
            size: CGSize(width: 320, height: 44),
            named: "active")
    }

    /// The last-wins grammar dims and strikes a superseded chip — the exact dimming that
    /// regressed silently before: an inactive chip must read secondary + struck through, not
    /// like a live filter.
    @Test func tokenChipsRowSupersededChipDims() {
        let items: [TokenChipsRow.Item] = [
            .init(label: "type:pdf", word: "type:pdf", isActive: false),
            .init(label: "type:png", word: "type:png", isActive: true),
            .init(label: "report", word: "report", isActive: true),
        ]
        assertViewSnapshot(
            of: TokenChipsRow(items: items, tint: .blue, onRemove: { _ in })
                .padding(12),
            size: CGSize(width: 320, height: 44),
            named: "superseded")
    }

    /// A light tint (the Yellow-accent family) must still produce readable chips — the tint is
    /// caller-supplied, so this pins the low-contrast pairing directly.
    @Test func tokenChipsRowYellowTint() {
        assertViewSnapshot(
            of: TokenChipsRow(items: Self.activeItems, tint: .yellow, onRemove: { _ in })
                .padding(12),
            size: CGSize(width: 320, height: 44),
            named: "yellow-tint")
    }

    // MARK: StatusBadge

    @Test func statusBadgeValidAndInvalid() {
        assertViewSnapshot(
            of: VStack(spacing: 8) {
                StatusBadge(isValid: true)
                StatusBadge(isValid: false)
            }
            .padding(12),
            size: CGSize(width: 180, height: 90),
            named: "both-states")
    }

    // MARK: EmptyStateView

    /// The pre-scan gold standard: icon + title + message + safety-contract caption + a
    /// prominent primary and a quieter secondary action.
    @Test func emptyStatePreScan() {
        assertViewSnapshot(
            of: EmptyStateView(
                icon: "wand.and.stars",
                tint: .accentColor,
                title: "Find duplicate files",
                message: "Scan this folder for byte-for-byte copies, overlapping folders and older versions.",
                caption: "Nothing is removed without your confirmation — redundant copies go to the Trash and can be restored with Undo.",
                primary: .init("Find Duplicates", systemImage: "wand.and.stars") {},
                secondary: .init("Choose Folder…") {}),
            size: CGSize(width: 560, height: 320),
            named: "pre-scan")
    }

    /// The filtered-empty shape (the Activity Log's "filters hide everything" state): no
    /// caption, a single primary — must not look broken, just intentional.
    @Test func emptyStateFilteredNoMatches() {
        assertViewSnapshot(
            of: EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching entries",
                message: "The current level filter and search hide every entry. Clear them to see the log again.",
                primary: .init("Clear Filters", systemImage: "xmark.circle") {}),
            size: CGSize(width: 560, height: 260),
            named: "filtered-no-matches")
    }

    /// The C5 compact layout for narrow hosts (Details sidebar, file-pane placeholder):
    /// smaller icon, tighter spacing, small-size action button.
    @Test func emptyStateCompactSidebar() {
        assertViewSnapshot(
            of: EmptyStateView(
                icon: "sidebar.right",
                title: "Nothing selected",
                message: "Select a file in either pane to see its details here.",
                primary: .init("Choose a File") {},
                layout: .compact),
            size: CGSize(width: 240, height: 240),
            named: "compact-sidebar")
    }

    // MARK: ProgressDialog

    /// Mid-flight with a long current-item path: the count line, the clamped bar and the
    /// middle-truncated file name.
    @Test func progressDialogMidOperation() {
        let progress = Progress(totalUnitCount: 7363)
        progress.completedUnitCount = 3336
        progress.localizedDescription = "Moving files to iCloud Drive"
        progress.localizedAdditionalDescription =
            "~/Documents/Projects/2026/Quarterly Reports/Q2/final-revision-with-appendix.pdf"
        assertViewSnapshot(
            of: ProgressDialog(progress: progress).padding(24),
            size: CGSize(width: 420, height: 220),
            named: "mid-operation")
    }
}
