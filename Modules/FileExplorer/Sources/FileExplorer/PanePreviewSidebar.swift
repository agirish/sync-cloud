import AppKit
import Design
import Sync
import SwiftUI

/// One hairline and the 9pt strip that makes it grabbable — the chrome every pane divider wears.
///
/// A view of its own rather than a method on `PaneColumnsView`, because the preview's seam is now
/// drawn on two surfaces (a column stack and a tree) and a second copy of it is how two dividers
/// come to look and hit-test differently. Only the gesture differs between the three call sites,
/// which is what the generic parameter carries.
struct PaneDividerHandle<G: Gesture>: View {
    let gesture: G

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(gesture)
            }
    }
}

/// The preview pinned to a pane's trailing edge, with the divider on its leading edge that resizes
/// it — the whole trailing half of a pane showing a file, whichever way that pane lists its files.
///
/// **Shared by both presentations, and that is the point.** The Columns stack had this inline; Tree
/// then needed the identical thing — same column, same seam, same stored width — and the choice was
/// between a second copy and this. A copy would have been two answers to questions the two modes do
/// not actually disagree about: how wide a dragged preview is, where its divider lives, which band
/// it holds clear for the action bar. What they DO disagree about is how much room the list beside
/// it must keep, and that stays with the caller: it computes `width` (through
/// `PaneViewMode.previewPaneWidth` or `treePreviewPaneWidth`) and gives the rest to its list.
///
/// **The drag state belongs to the caller, not here.** The caller lays out the list from the pane
/// width minus this one, so it must see the width the drag is at *during* the drag, not after it
/// settles — state owned here would leave the list at its old width until the gesture ended, and the
/// seam would drift away from the cursor. So the two scratch values arrive as bindings and only the
/// gesture that writes them lives here.
struct PanePreviewSidebar: View {
    let item: ColumnPreviewItem
    /// The laid-out width, decided by the caller — see the note above.
    let width: CGFloat
    /// Room held clear at the bottom for a pane's action bar. See `ColumnPreviewColumn`.
    let actionBarClearance: CGFloat
    /// The pane a download started here belongs to.
    let paneToken: PaneToken
    /// Whether this pane is watching a download of the file on screen.
    let isAwaitingDownload: Bool
    var downloadChannel: NotificationCenter = .default

    /// The width the drag is at right now, `nil` when no drag is in flight. The caller reads it to
    /// lay the list out against a live seam.
    @Binding var dragWidth: CGFloat?
    /// The width the drag STARTED at. `DragGesture.translation` is cumulative, so folding it into a
    /// width that already includes it compounds — see `PaneViewMode.draggedPreviewColumnWidth`.
    @Binding var dragAnchor: CGFloat?
    /// The remembered width, written once on release rather than per frame.
    @Binding var storedWidth: Double

    var body: some View {
        ColumnPreviewColumn(
            item: item,
            actionBarClearance: actionBarClearance,
            paneToken: paneToken,
            isAwaitingDownload: isAwaitingDownload,
            downloadChannel: downloadChannel)
            .frame(width: width)
            // On the preview's LEADING edge, and it resizes the preview: pinned to the pane's
            // trailing edge, growing it moves this seam left, under the cursor, exactly as a divider
            // should behave.
            .overlay(alignment: .leading) { divider }
    }

    /// The seam between the pane's list and the pinned preview.
    ///
    /// Anchored on the RENDERED width, never the stored one: the two differ whenever the room cap
    /// binds, and anchoring on the stored width would jump the seam by that difference on the drag's
    /// first pixel.
    private var divider: some View {
        PaneDividerHandle(gesture: DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let anchor = dragAnchor ?? width
                if dragAnchor == nil { dragAnchor = anchor }
                dragWidth = PaneViewMode.draggedPreviewColumnWidth(
                    anchor: anchor, translation: value.translation.width)
            }
            .onEnded { _ in
                if let dragWidth { storedWidth = Double(dragWidth) }
                dragWidth = nil
                dragAnchor = nil
            })
    }
}
