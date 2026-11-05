import AppKit
import SwiftUI

/// How a comparison pane presents its tree: an outline, or Finder-style columns.
///
/// Columns is the default. With nothing selected a Columns pane is one column at its own width,
/// listing the same folder the tree would; more columns appear as you click into folders. So the
/// modes differ only at a folder row: Tree puts a disclosure triangle on the left and expands
/// children inline; Columns puts a chevron on the right and opens the next column.
public enum PaneViewMode: String, CaseIterable, Identifiable, Sendable {
    case tree
    case columns

    /// The app's default.
    public static let `default` = PaneViewMode.columns

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tree: return "Tree"
        case .columns: return "Columns"
        }
    }

    /// SF Symbol for the view switch. The tree glyph reads as indented rows; the columns glyph as
    /// a divided pane.
    public var symbol: String {
        switch self {
        case .tree: return "list.bullet.indent"
        case .columns: return "rectangle.split.3x1"
        }
    }

    public var help: String {
        switch self {
        case .tree: return "Show this pane as a tree"
        case .columns: return "Show this pane as columns"
        }
    }

    // MARK: - Storage

    /// UserDefaults key for one comparison pane's mode. Per pane, so one side can be a deep tree
    /// while the other is flat.
    public static func defaultsKey(isLeft: Bool) -> String {
        isLeft ? "paneViewModeLeft" : "paneViewModeRight"
    }

    /// UserDefaults key for the single-source rail's mode.
    ///
    /// The rail renders through the same `FileTreeView` as the comparison panes but is a different
    /// surface (narrow, single-source, re-rooted per lens), so it has its own key: choosing Columns
    /// for a comparison must not restack the rail, or the reverse. Columns work there: the mirror
    /// in `applyColumnNavigation` is gated on the compare layout, a lens change re-roots through
    /// `focusOn`, which resets the browse path, and a rail too narrow for two columns falls into
    /// push navigation.
    ///
    /// The rail shares `leftBrowsePath` with the left comparison pane, as it shares that pane's
    /// focus, selection and history, so a column stack left in the rail survives into Compare's
    /// left pane.
    public static let railDefaultsKey = "paneViewModeRail"

    /// UserDefaults key for the Browse workspace's mode.
    ///
    /// Browse draws the same pane as the rail, at full window width, but has its own key for the
    /// rail's reason: a stack chosen for a 220pt rail beside a lens says nothing about a full-width
    /// browser, and flipping Browse to Tree must not restack Organize. Path, selection and history
    /// stay shared; only the presentation is per surface.
    public static let browseDefaultsKey = "paneViewModeBrowse"

    /// Reads a pane's stored mode, falling back to the default for an absent or unrecognised value.
    public static func stored(isLeft: Bool, in defaults: UserDefaults = .standard) -> PaneViewMode {
        guard let raw = defaults.string(forKey: defaultsKey(isLeft: isLeft)),
              let mode = PaneViewMode(rawValue: raw) else { return .default }
        return mode
    }

    // MARK: - Layout

    /// Width one column takes, and the floor and ceiling the resize drag clamps to.
    /// The minimum isn't cosmetic: below it a row can't fit its icon, name, contained-differences
    /// count and difference badge, and the badge is the reason this pane exists. The ceiling of 600
    /// leaves room for a column, sized on its own, that lists files with long names.
    /// leaves room for a column listing files with long names, now that columns size one at a time.
    public static let defaultColumnWidth: CGFloat = 210
    public static let minimumColumnWidth: CGFloat = 140
    public static let maximumColumnWidth: CGFloat = 600

    /// The strip a stack of columns keeps clear after its last column, outside its scroll view.
    ///
    /// It lets the deepest column's divider be grabbed. Every reveal parks an overflowing stack
    /// with the deepest column's trailing edge on the viewport's, where a seam drawn on top of it
    /// (Compare's pane splitter or the rail's, and the inspector's with Info open) would leave the
    /// handle a point or two, or none, just when the stack is deep enough to need it.
    ///
    /// Outside the scroll view, never in its content: padding an overflowing stack's content would
    /// move the very condition its scroll behaviour is tuned against (see `trailingFillerWidth`).
    /// The gutter narrows the viewport instead, which every reveal and clamp already measures
    /// against.
    ///
    /// 12pt: the widest seam that meets a stack's edge reaches 6pt into it (the Compare and rail
    /// splitters, 12pt strips starting 6pt inside the boundary), and a column's own strip reaches
    /// 4.5pt past its edge, so 12 leaves the two 1.5pt apart. Push mode's single column spans its
    /// area, has no divider and keeps no gutter; a stack showing one column keeps it like any
    /// other.
    public static let columnStackTrailingGutter: CGFloat = 12

    /// The width every column takes unless it was sized on its own (see `ColumnWidthOverrides`).
    /// One value across all panes, so the two sides of a comparison stay symmetric.
    public static let columnWidthDefaultsKey = "paneColumnWidth"

    /// What a column's list adds around a row, both sides together: the width a column needs beyond
    /// its widest row's own. A row's content starts 16–16.5pt in from the column's leading edge and
    /// ends 17pt short of its trailing edge, at both densities; 34 rounds that up, so a fitted
    /// column never truncates by a hair.
    public static let columnRowHorizontalInset: CGFloat = 34

    /// The positions sized on their own, over the base width above (see `ColumnWidthOverrides`).
    /// Shared across panes for the base width's reason: a comparison reads column 3 against column
    /// 3.
    public static let columnWidthOverridesDefaultsKey = "paneColumnWidthOverrides"

    /// The widths a divider on the column at `depth` leaves once dragged (or fitted) to `width`.
    ///
    /// `all` is the "All columns together" gesture: every column takes the one width and every
    /// column sized on its own is released. Otherwise only `depth` moves. Pure, and the one place
    /// this is decided. A column sized to exactly the base isn't recorded as an override: it is the
    /// base, and an entry would make a gesture that changed nothing look like a change.
    public static func resizedColumnWidths(
        base: CGFloat, overrides: ColumnWidthOverrides, depth: Int, to width: CGFloat, all: Bool
    ) -> (base: CGFloat, overrides: ColumnWidthOverrides) {
        let clamped = clampColumnWidth(width)
        guard !all else { return (clamped, ColumnWidthOverrides()) }
        var next = overrides
        next.widths[depth] = clamped == base ? nil : clamped
        return (base, next)
    }

    /// Below this pane width there is no room for a second column beside the first, so the pane
    /// shows one column that replaces its contents as you drill, with `‹` walking back out.
    ///
    /// Derived, not picked: a pane narrower than two minimum columns cannot show two, and the
    /// split clamps a pane at 250pt, so this is where "columns" stops meaning more than one.
    public static let pushNavigationBelowWidth: CGFloat = minimumColumnWidth * 2

    /// Whether a pane this wide shows a stack of columns or one pushing column.
    public static func usesPushNavigation(paneWidth: CGFloat) -> Bool {
        paneWidth < pushNavigationBelowWidth
    }

    /// Clamps a dragged width into the legible range.
    public static func clampColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumColumnWidth), maximumColumnWidth)
    }

    /// Marks that `liftColumnWidthOffTheFloor` has run, so it can only ever run once.
    public static let columnWidthFloorLiftKey = "paneColumnWidthFloorLifted"

    /// One-time repair for installs left pinned at `minimumColumnWidth`, a width once forced by a
    /// preview that took its width from the columns' slack and too narrow to read.
    ///
    /// Deliberately narrow: it fires only on a width exactly at the floor (a deliberate 141 is left
    /// alone), and it records that it ran, so someone who drags back to the minimum keeps it. A
    /// stored preference shouldn't be rewritten twice.
    public static func liftColumnWidthOffTheFloor(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: columnWidthFloorLiftKey) else { return }
        defaults.set(true, forKey: columnWidthFloorLiftKey)
        guard defaults.object(forKey: columnWidthDefaultsKey) != nil,
              CGFloat(defaults.double(forKey: columnWidthDefaultsKey)) <= minimumColumnWidth
        else { return }
        defaults.set(Double(defaultColumnWidth), forKey: columnWidthDefaultsKey)
    }

    /// The width a divider drag has reached, from the width it started at and the gesture's
    /// translation.
    ///
    /// `anchor` must be the width captured when the drag began, never the current one:
    /// `DragGesture.translation` is cumulative, so adding it to a width that already includes it
    /// compounds, and the column shoots to its maximum. Taking the anchor explicitly makes that
    /// mistake unrepresentable.
    public static func draggedColumnWidth(anchor: CGFloat, translation: CGFloat) -> CGFloat {
        clampColumnWidth(anchor + translation)
    }

    /// Width of the dead space to the right of the last column, which the pane fills with a
    /// deselect target so clicking there behaves like clicking below a column's last row.
    ///
    /// Zero whenever the stack overflows its pane, which is the load-bearing half: the column
    /// stack's scroll behaviour, and its mounted test, hold only while the stack genuinely
    /// overflows, and padding the content then would move that condition. It only ever fills slack
    /// that exists.
    ///
    /// Push mode needs no case of its own: its single column is framed to the whole viewport, so
    /// there is no slack. A stack showing one column keeps its own width, and the slack after it is
    /// filled like any other.
    ///
    /// `paneWidth` is the stack's viewport: the pane minus `columnStackTrailingGutter`, which isn't
    /// part of the scrolling stack, so the two don't compete for the same points.
    public static func trailingFillerWidth(paneWidth: CGFloat, columnWidths: [CGFloat]) -> CGFloat {
        max(0, paneWidth - columnWidths.reduce(0, +))
    }

    /// Whether a click on a column row (or a pane's empty space) should navigate, or be left
    /// entirely to the list's own mouse handling.
    ///
    /// ⌘ and ⇧ clicks are the list's: they extend and range-select, and navigating on them would
    /// collapse every multi-selection to the row just clicked.
    ///
    /// ⌃ is the secondary click: macOS delivers it as a primary-button event carrying `.control`
    /// (which is how it reaches an `NSClickGestureRecognizer` on button 1) and opens the context
    /// menu from it. Navigating on it would clear both panes' selections and close every column to
    /// the right just as the menu appears, destroying the selection the menu is about to act on
    /// (the "Copy N items from other pane" entry that `applySelectionWrite`'s empty-write rule
    /// protects).
    public static func clickNavigates(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.command) && !modifiers.contains(.shift) && !modifiers.contains(.control)
    }
}


// MARK: - Column resizing

/// Whether dragging a column divider resizes that column alone or every column at once — the
/// Readability setting "Column widths". ⌥ held during a drag always does the other one, as it does
/// in Finder, so either choice keeps the other a keystroke away.
public enum ColumnResizeMode: String, CaseIterable, Identifiable, Sendable {
    case eachColumn = "each"
    case allColumns = "all"

    /// Each column on its own, Finder's way; "All columns together" stays for whoever prefers one
    /// shared width.
    public static let `default` = ColumnResizeMode.eachColumn
    public static let defaultsKey = "paneColumnResizeMode"

    public var id: String { rawValue }

    /// The Settings segment labels — short, because the Readability tab's floor leaves about 340pt
    /// beside the rail; the caption under the control says the rest.
    public var displayName: String {
        switch self {
        case .eachColumn: return "Each column"
        case .allColumns: return "All columns"
        }
    }

    /// Whether a divider gesture made with ⌥ held (or not) resizes every column. One rule, so the drag
    /// and the double-click cannot come to disagree about what ⌥ means.
    public func resizesAll(optionHeld: Bool) -> Bool {
        (self == .allColumns) != optionHeld
    }
}

/// The column positions sized on their own, by depth — the widths that are not the shared base width.
///
/// Per position, not per folder, as in Finder: the third column stays as wide as it was dragged
/// whatever folder it lists, and a new, deeper column opens at the base width. Stored as a string
/// (`"2=480;3=300"`) so `@AppStorage` can hold it; entries outside the legal range are clamped on
/// read by `width(atDepth:base:)`, never trusted.
public struct ColumnWidthOverrides: Equatable, Sendable, RawRepresentable {
    public var widths: [Int: CGFloat]

    public init(widths: [Int: CGFloat] = [:]) {
        self.widths = widths
    }

    /// The width the column at `depth` takes: its own if it was sized on its own, else `base`.
    public func width(atDepth depth: Int, base: CGFloat) -> CGFloat {
        PaneViewMode.clampColumnWidth(widths[depth] ?? base)
    }

    public init?(rawValue: String) {
        var parsed: [Int: CGFloat] = [:]
        for pair in rawValue.split(separator: ";") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let depth = Int(parts[0]), depth >= 0,
                  let width = Double(parts[1]), width.isFinite else { continue }
            parsed[depth] = CGFloat(width)
        }
        self.widths = parsed
    }

    public var rawValue: String {
        widths.keys.sorted().map { "\($0)=\(Double(widths[$0]!))" }.joined(separator: ";")
    }
}
