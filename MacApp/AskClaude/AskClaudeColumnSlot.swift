import AppKit
import SwiftUI
import Design

/// The pinned panel's column, after the Info inspector in the window's row. It is on screen while
/// the panel is open and pinned, and it observes `visibility` itself so the window's own body does
/// not run again when the panel opens or closes.
///
/// The panel itself is in one hosting view (`AskClaudeWindowController`) that this slot's view
/// holds while pinned and gives back to a floating window when not.
struct AskClaudeColumnSlot: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let controller: AskClaudeWindowController
    let pinned: Bool
    let width: Double
    let surface: SurfaceStyle
    let level: GlassLevel
    let hue: LiquidGlassHue
    let tint: Double
    /// The inner edge dragged: the cumulative horizontal translation.
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void

    var body: some View {
        if pinned && visibility.isOpen {
            HStack(spacing: 0) {
                resizeHandle
                column
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Unified draws the column as one more flush area; Cards leaves the cards to the panel, which
    /// draws its header and its thread as two.
    @ViewBuilder private var column: some View {
        let host = AskClaudeColumnHost(controller: controller).frame(width: width)
        if surface == .unified {
            host.bottomSectionCard(.unified, level: level, hue: hue, tint: tint)
        } else {
            host
        }
    }

    /// The seam and its drag, as the Info inspector's: in Unified the hairline between the two
    /// areas, in Cards the gap between cards, with only the hit target left.
    private var resizeHandle: some View {
        Color.clear.frame(width: 1)
            .unifiedSeam(surface, edge: .leading)
            .overlay {
                ResizeHandle(axis: .horizontal, thickness: 10, minimumDistance: 1, coordinateSpace: .global,
                             onDrag: { onDrag($0.translation.width) }, onCommit: onCommit)
            }
    }
}

/// The column's AppKit view, which holds the panel's hosting view while it is pinned.
struct AskClaudeColumnHost: NSViewRepresentable {
    let controller: AskClaudeWindowController

    func makeNSView(context: Context) -> AskClaudeColumnView {
        let view = AskClaudeColumnView()
        view.controller = controller
        controller.columnView = view
        return view
    }

    func updateNSView(_ view: AskClaudeColumnView, context: Context) {
        view.controller = controller
        if controller.columnView !== view { controller.columnView = view }
    }

    static func dismantleNSView(_ view: AskClaudeColumnView, coordinator: ()) {
        if view.controller?.columnView === view { view.controller?.columnView = nil }
    }
}
