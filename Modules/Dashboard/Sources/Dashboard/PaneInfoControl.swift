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

    /// Info's width as a column: one value for every pane, as the columns' is, so a comparison stays
    /// symmetric. Dragged at Info's own divider, written on release.
    public static let widthDefaultsKey = "paneInfoWidth"
    /// The width Info starts at, and the one a double-click on its divider goes back to. Wider than
    /// a column's 210, so the picture has room.
    public static let defaultWidth: CGFloat = 300
    /// The details reflow cleanly down to 200 (`DetailsSidebar`'s floor), and 600 is the columns'
    /// own ceiling.
    public static let minimumWidth: CGFloat = 200
    public static let maximumWidth: CGFloat = 600

    /// A stored or dragged width brought into range.
    public static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The pane must be at least this wide for Info to be a column. Columns go to one spanning
    /// column below `PaneViewMode.pushNavigationBelowWidth` (280), so the columns beside Info need
    /// that, plus Info, its hairline and the stack's trailing gutter (13), rounded up to 20: 600 at
    /// the default width.
    public static func minPaneWidthForColumn(infoWidth: CGFloat) -> CGFloat {
        PaneViewMode.pushNavigationBelowWidth + clampWidth(infoWidth) + 20
    }

    /// How far past the line the pane must be to switch back, so a window sitting on it stays put.
    public static let hysteresis: CGFloat = 40

    /// A drawer leaves this much of the pane's list showing at its leading edge.
    public static let drawerReveal: CGFloat = 48

    /// Off, a column in the pane (after the deepest column in Columns, at the trailing edge in
    /// Tree), or a drawer over a pane too narrow for one.
    public enum Presentation: Equatable, Sendable {
        case off, column, drawer
    }

    /// Whether Info is a column or a drawer in a pane `paneWidth` wide, Info being `infoWidth` wide as
    /// a column, given what it was. Pure, so a test can walk the line. `previous` is what the pane
    /// showed last: a drawer becomes a column only 40pt past the line, and a column stays one until
    /// it crosses it.
    public static func presentation(isOn: Bool, paneWidth: CGFloat, previous: Presentation?,
                                    infoWidth: CGFloat = defaultWidth) -> Presentation {
        guard isOn else { return .off }
        let base = minPaneWidthForColumn(infoWidth: infoWidth)
        let line = previous == .drawer ? base + hysteresis : base
        return paneWidth >= line ? .column : .drawer
    }

    /// The drawer's width: Info's own, or less in a pane that cannot spare it, never under the
    /// details' floor.
    public static func drawerWidth(paneWidth: CGFloat, infoWidth: CGFloat = defaultWidth) -> CGFloat {
        max(minimumWidth, min(clampWidth(infoWidth), paneWidth - drawerReveal))
    }
}
