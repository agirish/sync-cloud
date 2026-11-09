import Design
import Foundation

/// What a pane's header needs to draw its Info button: whether this pane's Info is open, and how to
/// flip it. A value, so a header built without one draws no button, as with `PaneTypeFilterControl`.
public struct PaneInfoControl {
    public var isOn: Bool
    public var toggle: () -> Void

    public init(isOn: Bool, toggle: @escaping () -> Void) {
        self.isOn = isOn
        self.toggle = toggle
    }

    /// The button's tooltip, with ⌘I, which flips the focused pane's Info.
    public var help: String {
        ShortcutHint.tooltip(isOn ? "Hide Info for this pane" : "Show Info for this pane",
                             AppChord.infoInspector.display)
    }
}

/// A pane's Info: where it is stored, how wide it is, and whether it is a column or a drawer.
///
/// Every pane that draws a file list has its own switch, on its own key, as `PaneViewMode` does: the
/// two comparison panes, Browse, and the single-source rail (Organize's folder pane, and Edit's
/// file pane when it is open). The window has no Info of its own.
public enum PaneInfo {
    /// The key for one comparison pane's switch.
    public static func defaultsKey(isLeft: Bool) -> String { isLeft ? "paneInfoLeft" : "paneInfoRight" }
    /// The single-source rail's switch: Organize's folder pane, and Edit's file pane.
    public static let railDefaultsKey = "paneInfoRail"
    /// Browse's switch.
    public static let browseDefaultsKey = "paneInfoBrowse"

    /// Info's width as a column, fixed. Narrower than the 360pt the old window-level Info had, so
    /// the folder columns beside it keep more room.
    public static let slotWidth: CGFloat = 300

    /// The pane must be at least this wide for Info to be a column. Columns go to one spanning
    /// column below `PaneViewMode.pushNavigationBelowWidth` (280), so the columns beside the slot
    /// need that, plus the slot, its hairline and the stack's trailing gutter: 593, rounded up.
    public static let minPaneWidthForSlot: CGFloat = 600

    /// How far past the line the pane must be to switch back, so a window sitting on it stays put.
    public static let hysteresis: CGFloat = 40

    /// A drawer leaves this much of the pane's list showing at its leading edge.
    public static let drawerReveal: CGFloat = 48

    public enum Presentation: Equatable, Sendable {
        case off, slot, drawer
    }

    /// Whether Info is a column or a drawer in a pane `paneWidth` wide, given what it was. Pure, so
    /// a test can walk the line. `previous` is what the pane showed last: a drawer becomes a column
    /// only 40pt past the line, and a column stays one until it crosses it.
    public static func presentation(isOn: Bool, paneWidth: CGFloat, previous: Presentation?) -> Presentation {
        guard isOn else { return .off }
        let line = previous == .drawer ? minPaneWidthForSlot + hysteresis : minPaneWidthForSlot
        return paneWidth >= line ? .slot : .drawer
    }

    /// The drawer's width: 300, or less in a pane that cannot spare it.
    public static func drawerWidth(paneWidth: CGFloat) -> CGFloat {
        max(200, min(slotWidth, paneWidth - drawerReveal))
    }
}
