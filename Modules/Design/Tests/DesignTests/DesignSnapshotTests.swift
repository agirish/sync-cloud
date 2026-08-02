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
@Suite(.serialized, .machinePinned(.referenceImages)) struct DesignSnapshotTests {

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

    /// The `path:` slot with a path far wider than the canvas: it must stay a SINGLE
    /// monospaced line, middle-truncated (leading root and trailing leaf both visible) —
    /// never wrap or center like the prose slots. This was the one initializer slot with no
    /// pixel pin at all.
    @Test func emptyStateLongPathTruncatesMiddle() {
        assertViewSnapshot(
            of: EmptyStateView(
                icon: "externaldrive.badge.questionmark",
                title: "Folder not found",
                message: "The scanned folder is no longer at its recorded location.",
                path: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Projects/2026/Quarterly Reports/Q2/Drafts",
                primary: .init("Choose Folder…") {}),
            size: CGSize(width: 420, height: 280),
            named: "long-path")
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

    // MARK: Glass surfaces — the dark "bold" re-tune

    // Rendered at `.solid` on purpose: `.glassEffect` (the `.clear`/`.frosted` fill) doesn't render
    // in a headless host, but the border + shadow the re-tune adds are plain SwiftUI and do — so at
    // `.solid` these deterministically pin exactly what changed. Each captures the dark specular
    // hairline / deep shadow AND the light `.quaternary` hairline / soft shadow it must preserve —
    // the regression net the surfaces lacked (the other suites render inner components, never these
    // wrappers).

    /// A stand-in card body shared by the surface-chrome snapshots.
    @ViewBuilder private func sampleCardBody() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Documents", systemImage: "folder").font(.headline)
            Text("128 items · 4.2 GB").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    /// A pane card (`surfaceCard`): dark gets the white specular hairline + deep lift shadow; light
    /// keeps the `.quaternary` hairline + soft shadow.
    @Test func surfaceCardChrome() {
        assertViewSnapshot(
            of: sampleCardBody().surfaceCard(.solid).padding(40),
            size: CGSize(width: 360, height: 200),
            named: "surface-card")
    }

    /// A bottom-workspace section (`bottomSectionCard`, cards shape) with an accent tint wash.
    @Test func bottomSectionCardChrome() {
        assertViewSnapshot(
            of: sampleCardBody().bottomSectionCard(.cards, level: .solid, hue: .blue, tint: 0.3).padding(40),
            size: CGSize(width: 360, height: 200),
            named: "bottom-section-card")
    }

    /// A floating overlay card (`glassCardStyle`): dark gets the specular hairline + the deep r34
    /// lift shadow (the heaviest of the set); light keeps the soft `cardShadow`.
    @Test func overlayCardChrome() {
        assertViewSnapshot(
            of: sampleCardBody().glassCardStyle(level: .solid).padding(60),
            size: CGSize(width: 400, height: 260),
            named: "overlay-card")
    }

    /// A lens content card (`lensCard`): dark now gets the shared white specular hairline instead of
    /// staying a flat `.quaternary` edge inside a bold section; light unchanged.
    @Test func lensCardChrome() {
        assertViewSnapshot(
            of: sampleCardBody().lensCard().padding(24),
            size: CGSize(width: 320, height: 150),
            named: "lens-card")
    }

    // MARK: Action bar

    /// The three action-bar weights side by side with the divider that separates their zones —
    /// the ladder a reader has to be able to see at a glance, since "one filled capsule per bar"
    /// only means anything if filled, tinted and outline are visibly three steps.
    ///
    /// Unlike the glass chrome above, this renders faithfully offscreen: every weight is drawn
    /// from a fill and a hairline we own rather than from a system material, which is the same
    /// property that keeps it from graying out when the app isn't frontmost
    /// (`ActionBarFocusIndependenceTests`).
    ///
    /// The label text is ILLUSTRATIVE, not a copy reference. It is shaped like the differences
    /// bar's buttons because that is this style's main caller, but the exact wording lives in
    /// `BulkActionLabel` (FileExplorer) and has since gained a "Copy" verb these specimens do not
    /// carry — they are sized to a fixed canvas, and this suite asserts weights, not words.
    @Test func actionBarWeights() {
        assertViewSnapshot(
            of: HStack(spacing: 10) {
                Button { } label: { Label("Verify 6", systemImage: "checkmark.shield") }
                    .buttonStyle(.actionBar(.outline, tint: .blue, onTint: .white))
                Button { } label: { Label("4 to iCloud", systemImage: "arrow.left") }
                    .buttonStyle(.actionBar(.quiet, tint: .blue, onTint: .white))
                Button { } label: { Label("17 to Dropbox", systemImage: "arrow.right") }
                    .buttonStyle(.actionBar(.primary, tint: .blue, onTint: .white))
                ActionBarDivider()
                Button { } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.actionBar(.outline, tint: .blue, onTint: .white, iconOnly: true))
            }
            .padding(12),
            size: CGSize(width: 460, height: 52),
            named: "weights")
    }

    /// A disabled row: every weight keeps its shape and loses its conviction, so a blocked bulk
    /// action still reads as a control rather than disappearing (the failure the Clear glass level
    /// used to produce).
    @Test func actionBarDisabled() {
        assertViewSnapshot(
            of: HStack(spacing: 10) {
                Button { } label: { Label("Verify 6", systemImage: "checkmark.shield") }
                    .buttonStyle(.actionBar(.outline, tint: .blue, onTint: .white))
                Button { } label: { Label("4", systemImage: "arrow.left") }
                    .buttonStyle(.actionBar(.quiet, tint: .blue, onTint: .white))
                Button { } label: { Label("17 to Dropbox", systemImage: "arrow.right") }
                    .buttonStyle(.actionBar(.primary, tint: .blue, onTint: .white))
            }
            .disabled(true)
            .padding(12),
            size: CGSize(width: 380, height: 52),
            named: "disabled")
    }
}
