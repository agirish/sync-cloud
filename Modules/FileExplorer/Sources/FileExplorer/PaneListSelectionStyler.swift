import AppKit
import SwiftUI

/// Turns off the pane `List`'s built-in selection highlight so each row's accent-tinted
/// `.listRowBackground` is the only one. The backing `NSTableView` paints selection in
/// `selectedContentBackgroundColor`, gray under a Graphite accent and deaf to `.tint`; setting
/// `selectionHighlightStyle = .none` removes it and leaves the SwiftUI selection binding alone.
///
/// A `.background` sibling of the list, it finds that list's table through `PaneListResolver`
/// (frame-anchored, so every Columns column is reached) and re-asserts on every layout pass,
/// because SwiftUI can recreate the table on data changes or tab switches.
struct PaneListSelectionStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table, so re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) { view.rearm() }

    /// Only the assertion; the frame-anchored resolution, budget and re-arm ladder live on
    /// `FrameAnchoredResolveView`.
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
/// Stands in for AppKit's emphasized/unemphasized selection, which the panes lose by disabling the
/// system highlight (`PaneListSelectionStyler`) and pinning `controlActiveState` to `.active`.
/// Without it nothing shows which pane the action bar acts on. Named constants keep the two a pair:
/// the gap between them is the signal, and `PaneSelectionWashTests` pins that it stays legible.
public enum PaneSelectionWash {
    /// The pane holding the action bar: the selection reads at full strength.
    public static let active: Double = 0.22
    /// The other pane: still clearly a selection, visibly subordinate to the active one.
    public static let inactive: Double = 0.10

    public static func opacity(isActivePane: Bool) -> Double {
        isActivePane ? active : inactive
    }
}
