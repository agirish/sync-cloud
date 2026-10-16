import SwiftUI
import Design

/// **What a pane draws to say it is reading its folder — one thing, in one place.**
///
/// A loading pane used to show up to three indicators, each correct about its own state. There was
/// the centred "Scanning Directory…" while it had no rows, a bare spinner chip in the bottom-right
/// corner once it had some, and a spinner in every open Columns column that was still empty. A load
/// paints the top level first and the deeper folders afterwards (`loadTree`'s shallow first paint),
/// so in the gap between the two the chip and every open column's spinner were all on screen at
/// once, after the centred one had already come and gone. The user saw all of them during one
/// load (raised 2026-10-03) and chose one indicator per pane, in the corner, for the whole load
/// (2026-10-15).
///
/// So the pane's walk has this one indicator and nothing else speaks for it: the centred
/// placeholder no longer draws (`PaneEmptyState.loading` still claims the space, so "Folder is
/// empty" cannot show mid-walk), and a column's own spinner is only for a listing that column alone
/// is waiting on (`PaneColumnsView.emptyCaption`).
///
/// **The chip is backed only when rows sit under it.** A material blurs what is behind it, and on
/// an empty pane there is nothing, so it paints a flat gray box. That was reported as a regression
/// against this same label on 2026-08-11 and is why the centred placeholder lost its card. The
/// spinner, the label and the corner do not change across the load; only the backing comes and
/// goes, and it does so exactly when there is something it has to stay legible against.
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
