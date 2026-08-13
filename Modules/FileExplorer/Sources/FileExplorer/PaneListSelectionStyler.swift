import AppKit
import SwiftUI

/// Disables the pane `List`'s built-in row-selection highlight so the accent-tinted selection drawn
/// by each row's `.listRowBackground` is the ONLY highlight. SwiftUI backs the sidebar list with an
/// `NSTableView` whose selection is painted from `NSColor.selectedContentBackgroundColor` — a flat
/// gray under a Graphite macOS accent, and unmoved by SwiftUI's `.tint`. Reaching the table and
/// setting `selectionHighlightStyle = .none` removes that gray; the SwiftUI selection binding (and
/// therefore the row background keyed on it) is unaffected, so selection behaviour is unchanged.
///
/// Placed as a `.background` sibling of the list, it finds that list's table through
/// `PaneListResolver` and re-asserts on every layout pass, since SwiftUI re-tiles and can recreate
/// the table on data changes or tab switches.
///
/// It reached only the first column of a Columns pane until the resolver was frame-anchored: every
/// column drilled into kept the OS highlight. See `PaneListResolver` for the mechanism and the
/// measurement.
struct PaneListSelectionStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table, so re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) { view.rearm() }

    /// Everything but the assertion itself — the frame-anchored resolution, the budget, and the
    /// re-arm ladder that is the whole correctness story — lives on `FrameAnchoredResolveView`.
    final class StylerView: FrameAnchoredResolveView {
        override func resolvePass() {
            guard let table = resolveTableView() else { return }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }
    }
}

/// How strongly a pane paints its selected rows, by whether that pane is the active one.
///
/// This is the replacement for the emphasized/unemphasized selection AppKit used to draw: the panes
/// disable the system highlight (`PaneListSelectionStyler`) to get the app accent instead of OS
/// gray, and the window pins `controlActiveState` to `.active` to stop the glass graying out when it
/// isn't key. Both are deliberate, but together they removed every cue for which pane the action bar
/// acts on. Named constants rather than literals at the call site so the two stay a *pair* — the gap
/// between them is the whole signal, and `PaneSelectionWashTests` pins that it stays legible.
public enum PaneSelectionWash {
    /// The pane holding the action bar: the selection reads at full strength.
    public static let active: Double = 0.22
    /// The other pane: still clearly a selection, visibly subordinate to the active one.
    public static let inactive: Double = 0.10

    public static func opacity(isActivePane: Bool) -> Double {
        isActivePane ? active : inactive
    }
}
