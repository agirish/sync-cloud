import SwiftUI
import Design

/// What a pane draws to say it is reading its folder: one indicator, in the corner, for the whole
/// load. A load paints the top level first and deeper folders after, so separate indicators for
/// each state would stack up on screen during one load.
///
/// Nothing else speaks for the pane's walk: `PaneEmptyState.loading` claims the space without
/// drawing, so "Folder is empty" can't show mid-walk, and a column's own spinner is only for a
/// listing that column alone is waiting on (`PaneColumnsView.emptyCaption`).
///
/// The chip is backed only when rows sit under it: a material over an empty pane has nothing to
/// blur and paints a flat gray box. Spinner, label and corner stay fixed across the load; only the
/// backing comes and goes.
enum PaneBusyIndicator: Equatable, Sendable {
    /// The pane is not reading its folder.
    case none
    /// The pane is reading its folder. `backed` is true when rows are under the chip.
    case chip(backed: Bool)

    /// Shown and spoken, the one sentence a loading pane says.
    static let title = "Scanning Directory…"

    static func resolve(isLoading: Bool, treeIsEmpty: Bool) -> PaneBusyIndicator {
        isLoading ? .chip(backed: !treeIsEmpty) : .none
    }
}

/// The chip itself: a small spinner and `PaneBusyIndicator.title`, pinned to the pane's
/// bottom-trailing corner.
///
/// Display-only, so it never takes a click meant for the rows under it. VoiceOver reads it as
/// one element carrying the title, the same sentence the screen shows.
struct PaneBusyChip: View {
    let backed: Bool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(PaneBusyIndicator.title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if backed {
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PaneBusyIndicator.title)
        .accessibilityAddTraits(.updatesFrequently)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
    }
}
