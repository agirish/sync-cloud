import SwiftUI

/// The invisible drag-to-resize strip on every seam in the window: the pane split, the
/// single-source rail boundary, the panes↔workspace divider and the Info inspector's edge. One
/// component so the idiom (a clear, hit-testable strip with a resize pointer whose gesture reads a
/// fixed coordinate space) can't drift copy by copy.
///
/// ## The fixed-coordinate-space rule
///
/// The `coordinateSpace` must be a fixed frame (`.named(...)` on a stable ancestor, or `.global`),
/// never `.local`. The handle moves with the seam it drags, so in its own space the gesture's
/// values feed back on themselves and collapse toward zero once layout catches up, and the drag
/// stutters. The parameter has no default, so every call site chooses a fixed space.
///
/// The clamp math stays in `PaneLogic` (pure, unit-tested) at each call site, which gets the raw
/// `DragGesture.Value` (location for the named-space handles, translation for the global-space
/// inspector) and commits on release via `onCommit`.
struct ResizeHandle: View {

    /// The seam's orientation: `.horizontal` resizes columns (a vertical strip, column-resize
    /// pointer), `.vertical` resizes rows (a horizontal strip, row-resize pointer).
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis
    /// The strip's hit-target thickness in points (its length expands to fill the seam).
    var thickness: CGFloat = 12
    /// Minimum drag distance before the gesture starts: 0 for the pane seams, 1 for the
    /// global-space handles (the inspector, the sidebar and Edit's column).
    var minimumDistance: CGFloat = 0
    /// The fixed coordinate space the drag reads; see the rule above. Never pass `.local`.
    let coordinateSpace: CoordinateSpace
    /// Called with each raw gesture value; the call site applies its own (PaneLogic) clamp math
    /// to a live drag @State.
    let onDrag: (DragGesture.Value) -> Void
    /// Called on gesture end; the call site persists the live drag value and clears it.
    let onCommit: () -> Void

    var body: some View {
        Color.clear
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .frame(
                maxWidth: axis == .vertical ? .infinity : nil,
                maxHeight: axis == .horizontal ? .infinity : nil
            )
            .contentShape(Rectangle())
            .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: minimumDistance, coordinateSpace: coordinateSpace)
                    .onChanged(onDrag)
                    .onEnded { _ in onCommit() }
            )
    }
}
