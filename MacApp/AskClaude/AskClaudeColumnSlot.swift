import AppKit
import SwiftUI
import Design

/// Ask Claude's column: the window's last, drawn beside the workspace, or over its right edge in a
/// window too narrow to share the row. It is on screen while the panel is open, and it observes
/// `visibility` itself so the window's own body does not run again when the panel opens or closes.
///
/// One view in one place for both. The row reserves the column's width when it is docked
/// (`AskClaudeReserve`) and this slot is always drawn over the row's trailing edge, so the panel
/// never changes parent when the window crosses the narrow line: only whether the row makes room for
/// it, and whether it casts a shadow.
struct AskClaudeColumnSlot: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let dock: AskClaudeDock
    /// The row has room for it beside the workspace.
    let docked: Bool
    /// The row has been measured and has no room: it is drawn over the workspace's right edge.
    let overlaid: Bool
    let width: Double
    let surface: SurfaceStyle
    let level: GlassLevel
    let hue: LiquidGlassHue
    let tint: Double
    /// The inner edge dragged: the cumulative horizontal translation.
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void

    private var shown: Bool { visibility.isOpen && (docked || (overlaid && !visibility.tucked)) }

    var body: some View {
        if shown {
            HStack(spacing: 0) {
                resizeHandle
                column
            }
            .frame(maxHeight: .infinity)
            .shadow(color: .black.opacity(overlaid ? 0.24 : 0), radius: overlaid ? 14 : 0, x: overlaid ? -4 : 0, y: 0)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Unified draws the column as one more flush area; Cards leaves the cards to the panel, which
    /// draws its header and its thread as two.
    @ViewBuilder private var column: some View {
        let host = AskClaudeColumnHost(dock: dock, tucksOnOutsideClick: overlaid,
                                       onTuck: { visibility.tucked = true }).frame(width: width)
        if surface == .unified {
            host.bottomSectionCard(.unified, level: level, hue: hue, tint: tint)
        } else {
            host
        }
    }

    /// The seam and its drag, as the panes': in Unified the hairline between the two areas, in Cards
    /// the gap between cards, with only the hit target left.
    private var resizeHandle: some View {
        Color.clear.frame(width: 1)
            .unifiedSeam(surface, edge: .leading)
            .overlay {
                ResizeHandle(axis: .horizontal, thickness: 10, minimumDistance: 1, coordinateSpace: .global,
                             onDrag: { onDrag($0.translation.width) }, onCommit: onCommit)
            }
    }
}

/// The room the row keeps for a docked column, so the workspace is narrower by its width. Nothing
/// when it is closed, tucked or drawn over the workspace. Its own view, observing `visibility`.
struct AskClaudeReserve: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let docked: Bool
    /// The column and its seam.
    let width: CGFloat

    var body: some View {
        if visibility.isOpen && docked {
            Color.clear.frame(width: width)
        }
    }
}

/// The column's AppKit view, which holds the panel's hosting view.
struct AskClaudeColumnHost: NSViewRepresentable {
    let dock: AskClaudeDock
    var tucksOnOutsideClick = false
    var onTuck: () -> Void = {}

    func makeNSView(context: Context) -> AskClaudeColumnView {
        let view = AskClaudeColumnView()
        view.controller = dock
        dock.columnView = view
        return view
    }

    func updateNSView(_ view: AskClaudeColumnView, context: Context) {
        view.controller = dock
        view.tucksOnOutsideClick = tucksOnOutsideClick
        view.onTuck = onTuck
        if dock.columnView !== view { dock.columnView = view }
    }

    static func dismantleNSView(_ view: AskClaudeColumnView, coordinator: ()) {
        if view.controller?.columnView === view { view.controller?.columnView = nil }
    }
}
