import Design
import FileExplorer
import SwiftUI

/// A pane's Info as a column: drawn over the room the pane's list keeps for it (`PaneInfoSlot`),
/// with no fill of its own and a column's divider, so it reads as one more column.
///
/// In Columns the room follows the deepest column and scrolls with the stack, so this follows the
/// room as it moves, masked to the stack's visible region as the columns are. Its divider is on its
/// trailing edge there, as every column's is, and on its leading edge at a Tree list's trailing
/// edge. A drag moves only this view, per frame; the width is written once, on release, and the
/// list's room follows it then, as the columns write theirs.
///
/// Draws nothing until the list has reported its room.
public struct PaneInfoColumnOverlay<Content: View>: View {
    let slot: PaneInfoSlot
    @Binding var width: Double
    let content: Content

    /// A divider drag in flight: the width it started at, and where it has reached. `anchor` is
    /// captured on the first frame, since the gesture's translation is cumulative.
    private struct Drag {
        let anchor: CGFloat
        var width: CGFloat
    }

    @GestureState private var drag: Drag?

    public init(slot: PaneInfoSlot, width: Binding<Double>, @ViewBuilder content: () -> Content) {
        self.slot = slot
        self._width = width
        self.content = content()
    }

    public var body: some View {
        if let room = slot.room {
            let committed = PaneInfo.clampWidth(CGFloat(width))
            let live = drag?.width ?? committed
            let x = Self.leadingX(room: room, width: live)
            content
                .frame(width: live, height: room.frame.height)
                .overlay(alignment: room.dividerEdge == .trailing ? .trailing : .leading) {
                    divider(edge: room.dividerEdge, committed: committed)
                }
                .offset(x: x, y: room.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Always masked, to the whole host where nothing scrolls, so a switch between Tree
                // and Columns does not change the panel's identity and rebuild it.
                .mask(alignment: .topLeading) {
                    let visible = room.viewport ?? CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
                    Rectangle()
                        .frame(width: max(0, visible.width), height: max(0, visible.height))
                        .offset(x: visible.minX, y: visible.minY)
                }
        }
    }

    /// Where Info's leading edge goes, `width` wide: at the room's leading edge when the divider is
    /// on the trailing one (a drag grows it rightward, over the space past it, as a column grows),
    /// else ending at the room's trailing edge (it grows leftward, over the list).
    static func leadingX(room: PaneInfoSlot.Room, width: CGFloat) -> CGFloat {
        room.dividerEdge == .trailing ? room.frame.minX : room.frame.maxX - width
    }

    /// The width a drag reaches, from the width it started at and its horizontal travel. A trailing
    /// divider grows Info as it moves right; a leading one as it moves left.
    static func draggedWidth(anchor: CGFloat, translation: CGFloat, edge: PaneInfoSlot.DividerEdge) -> CGFloat {
        PaneInfo.clampWidth(anchor + (edge == .trailing ? translation : -translation))
    }

    private func divider(edge: PaneInfoSlot.DividerEdge, committed: CGFloat) -> some View {
        let resize = DragGesture(coordinateSpace: .global)
            .updating($drag) { value, drag, _ in
                let anchor = drag?.anchor ?? committed
                drag = Drag(anchor: anchor,
                            width: Self.draggedWidth(anchor: anchor, translation: value.translation.width, edge: edge))
            }
            .onEnded { value in
                let next = Self.draggedWidth(anchor: committed, translation: value.translation.width, edge: edge)
                if next != committed { width = Double(next) }
            }
        // A column's double-click fits it to its names; Info has none to fit, so it goes back to
        // the width it starts at.
        let reset = TapGesture(count: 2).onEnded { width = Double(PaneInfo.defaultWidth) }
        return PaneDividerHandle(gesture: resize.simultaneously(with: reset))
    }
}

public extension View {
    /// Info's close button as a column has it: no title bar, a ✕ at the top trailing corner that
    /// shows while the pointer is over Info or the button has the keyboard. VoiceOver reaches it,
    /// and an action on Info itself, at all times.
    func paneInfoHoverClose(_ close: @escaping () -> Void) -> some View {
        modifier(PaneInfoHoverClose(close: close))
    }
}

private struct PaneInfoHoverClose: ViewModifier {
    let close: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                CloseButton(action: close)
                    .help(ShortcutHint.tooltip("Hide Info", AppChord.infoInspector.display))
                    .accessibilityLabel("Hide Info")
                    .focused($focused)
                    .opacity(hovering || focused ? 1 : 0)
                    .designAnimation(.easeOut(duration: 0.12), value: hovering || focused)
                    .padding(8)
            }
            .onHover { hovering = $0 }
            .accessibilityAction(named: "Hide Info", close)
    }
}
