import AppKit
import SwiftUI

/// How a comparison pane presents its tree: today's outline, or Finder-style columns.
///
/// Columns is the default. With nothing selected a Columns pane is one column at its own width,
/// listing the same folder the tree listed; more columns appear as you click into folders.
///
/// The two modes therefore differ in exactly one place: a folder row. Tree puts a disclosure
/// triangle on the left and expands children inline; Columns puts a chevron on the right and opens
/// the next column.
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

    /// UserDefaults key for one comparison pane's mode.
    ///
    /// Per-pane by decision, so one side can be a deep tree while the other is flat — hence a key
    /// per side rather than one shared setting.
    public static func defaultsKey(isLeft: Bool) -> String {
        isLeft ? "paneViewModeLeft" : "paneViewModeRight"
    }

    /// UserDefaults key for the single-source rail's mode.
    ///
    /// The rail renders through the same `FileTreeView` as the comparison panes but is a different
    /// surface — narrow, single-source, re-rooted per lens — so it gets a key of its own rather
    /// than inheriting the left pane's. Choosing Columns for a comparison must not silently
    /// restack the rail, or the reverse.
    ///
    /// This used to say the rail could never draw columns at all, on the grounds that the Columns
    /// navigation rules assumed a sibling pane. They do not, as it turns out: the mirror in
    /// `applyColumnNavigation` is already gated on the compare layout, a lens change re-roots
    /// through `focusOn` which resets the browse path, and a rail too narrow for two columns falls
    /// into push navigation — the same path a squeezed comparison pane takes. What the rail lacked
    /// was any way to open a folder with one click, which is exactly what Columns is for.
    ///
    /// The rail does share `leftBrowsePath` with the left comparison pane, because it shares that
    /// pane's focus, selection and history too — entering Organize already re-roots the left pane. A
    /// column stack left in the rail therefore survives into Compare's left pane, showing the
    /// folder you were last in. That is the same continuity the shared focus already provides.
    public static let railDefaultsKey = "paneViewModeRail"

    /// UserDefaults key for the Browse workspace's mode.
    ///
    /// Browse draws the same pane as the single-source rail — it IS the left pane, at full window width —
    /// but for the same reason the rail does not inherit the left comparison pane's key, Browse
    /// does not inherit the rail's: a stack chosen for a 220pt rail beside a lens is not a choice
    /// about a full-width file browser, and flipping Browse to Tree must not silently restack
    /// Organize. Path, selection and history stay shared; only the presentation is per-surface.
    public static let browseDefaultsKey = "paneViewModeBrowse"

    /// Reads a pane's stored mode, falling back to the default for an absent or unrecognised value.
    public static func stored(isLeft: Bool, in defaults: UserDefaults = .standard) -> PaneViewMode {
        guard let raw = defaults.string(forKey: defaultsKey(isLeft: isLeft)),
              let mode = PaneViewMode(rawValue: raw) else { return .default }
        return mode
    }

    // MARK: - Layout

    /// Width one column takes, and the floor the resize drag clamps to.
    ///
    /// The minimum is not cosmetic: below it a row cannot fit its icon, name, contained-differences
    /// count and difference badge together, and the badge is the entire reason this pane exists.
    /// Clamping keeps every row complete rather than silently shedding the parts that carry meaning.
    ///
    /// **The ceiling was 340 until columns could be sized one at a time (2026-09-27).** With one
    /// width for every column, a wide column meant a wide stack, and 340 kept a stack of folders
    /// from pushing its deepest column off the pane. A column sized on its own is usually the one
    /// listing files with long names, and 340 was not enough for those — 600 is.
    public static let defaultColumnWidth: CGFloat = 210
    public static let minimumColumnWidth: CGFloat = 140
    public static let maximumColumnWidth: CGFloat = 600

    /// The strip a stack of columns keeps clear after its last column, outside its scroll view.
    ///
    /// **So the deepest column's divider can be grabbed.** Every reveal parks an overflowing stack
    /// with the deepest column's trailing edge on the viewport's, and that edge already carries a
    /// seam drawn later and so on top of it: Compare's pane splitter or the rail's, and the
    /// inspector's with Info open. Each left the column's
    /// handle a point or two, or none — so the one handle the column you most often want wider has
    /// could not be reached exactly when the stack was deep enough to need it.
    ///
    /// **Outside the scroll view, never in its content.** A filler that padded an overflowing
    /// stack's content would move the very condition its scroll behaviour was tuned against (see
    /// `trailingFillerWidth`). The gutter narrows the VIEWPORT instead, which every reveal and clamp
    /// already measures against.
    ///
    /// 12pt: the widest seam that meets a stack's edge reaches 6pt into it (the Compare and rail
    /// splitters, 12pt strips starting 6pt inside the boundary), and a column's own strip reaches
    /// 4.5pt past its edge — 12 leaves the two 1.5pt apart. Push mode's single column spans its area,
    /// has no divider, and keeps no gutter; a stack showing one column keeps all three like any other.
    public static let columnStackTrailingGutter: CGFloat = 12

    /// The width every column takes unless it was sized on its own — see `ColumnWidthOverrides`.
    /// One value across all panes, so the two sides of a comparison stay symmetric; and exactly the
    /// single width this key always held, which is why "All columns together" is today's behaviour
    /// with nothing migrated.
    public static let columnWidthDefaultsKey = "paneColumnWidth"

    /// What a column's list adds around a row, both sides together: the width a column needs beyond
    /// its widest row's own. Measured on a mounted column (2026-09-27): the row's content starts
    /// 16–16.5pt in from the column's leading edge and ends 17pt short of its trailing edge, the same
    /// at both densities; 34 is that sum rounded up, so a fitted column never truncates by a hair.
    public static let columnRowHorizontalInset: CGFloat = 34

    /// The positions sized on their own, over the base width above — see `ColumnWidthOverrides`.
    /// Shared across panes for the base width's reason: a comparison reads column 3 against column 3.
    public static let columnWidthOverridesDefaultsKey = "paneColumnWidthOverrides"

    /// The widths a divider on the column at `depth` leaves once dragged (or fitted) to `width`.
    ///
    /// `all` is the "All columns together" gesture: every column takes the one width and every
    /// column sized on its own is released, which is exactly what one shared width always did — so a
    /// person who prefers that loses nothing. Otherwise only `depth` moves, and every other column
    /// keeps whatever it had. Pure, and the one place this is decided.
    ///
    /// A column sized to exactly the base is not kept as sized on its own: it IS the base, and an
    /// entry saying so would only make a gesture that changed nothing look like a change.
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

    /// One-time repair for installs left pinned at `minimumColumnWidth`.
    ///
    /// For one build (`924c513`) the preview's width came from the columns' slack, so the only way
    /// to enlarge a preview was to drag every column narrower — all the way to this floor. `44ffa41`
    /// gave the preview a width of its own and took that reason away, but the stored 140 stayed
    /// behind: columns too narrow to read, chosen for a rule that no longer exists.
    ///
    /// Deliberately narrow in what it touches. It fires only on a width sitting exactly AT the floor
    /// — a deliberate 141 is left alone — and it records that it ran, so someone who genuinely wants
    /// the minimum and drags back to it keeps it forever after. Rewriting a stored preference is not
    /// something to do twice.
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
    /// `anchor` must be the width captured when the drag *began*, never the current one.
    /// `DragGesture.translation` is cumulative from the drag's start, so folding it into a width
    /// that already includes it compounds: a drag of 10, 20, 30 points produced 220, 240, 270
    /// instead of 220, 230, 240, and the column shot to its maximum almost immediately. Taking the
    /// anchor explicitly makes that mistake unrepresentable rather than merely fixed.
    public static func draggedColumnWidth(anchor: CGFloat, translation: CGFloat) -> CGFloat {
        clampColumnWidth(anchor + translation)
    }

    /// Width of the dead space to the right of the last column, which the pane fills with a
    /// deselect target so clicking there behaves like clicking below a column's last row.
    ///
    /// Zero whenever the stack overflows its pane, which is the load-bearing half. The column
    /// stack's scroll behaviour was fought over four times (`63bb6cf` through `a89aa40`) and its
    /// mounted test holds only while the stack genuinely overflows; a filler that padded the
    /// content in that state would move the very condition those fixes were tuned against. It only
    /// ever occupies slack that already existed.
    ///
    /// Push mode needs no case of its own: its single column is framed to the whole viewport, so
    /// there is no slack to fill. A stack showing one column keeps its own width, and the slack after
    /// it — most of a resting pane — is filled like any other.
    ///
    /// `paneWidth` here is the width of the stack's VIEWPORT: the pane minus
    /// `columnStackTrailingGutter`, which is not part of the scrolling stack, so it does not compete
    /// with this filler for the same points.
    public static func trailingFillerWidth(paneWidth: CGFloat, columnWidths: [CGFloat]) -> CGFloat {
        max(0, paneWidth - columnWidths.reduce(0, +))
    }

    /// Whether a click on a column row (or on a pane's empty space) should navigate, or be left
    /// entirely to the list's own mouse handling.
    ///
    /// ⌘ and ⇧ clicks are the list's: they extend and range-select. A navigation handler that ran
    /// for them too would collapse every multi-selection back to the one row just clicked, which is
    /// exactly what it did — Copy/Move/Delete could never act on more than one item in Columns.
    ///
    /// ⌃ is excluded for a different reason: it is the secondary click. macOS delivers control-click
    /// as a primary-button event carrying `.control` — which is what lets it reach an
    /// `NSClickGestureRecognizer` watching button 1 at all — and then opens the contextual menu from
    /// it. Admitting it here meant a secondary click on a column's empty space cleared BOTH panes'
    /// selections and truncated the column stack, closing every column to the right, at the same
    /// moment its context menu appeared. A secondary click must not navigate: it exists to ask what
    /// the options are, and destroying the selection the menu is about to act on (the same
    /// "Copy N items from other pane" entry the empty-write rule in `applySelectionWrite` was
    /// written to protect) is the opposite of that.
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

    /// Each column on its own: the change people asked for. "All columns together" is exactly the
    /// behaviour before it, kept for whoever prefers it.
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
/// **Per POSITION, not per folder** — Finder's model, and the decision recorded as Q3: the third
/// column stays as wide as it was dragged whatever folder it lists, and a new, deeper column opens at
/// the base width. Stored as a string (`"2=480;3=300"`) so `@AppStorage` can hold it; entries outside
/// the legal range are clamped on read by `width(atDepth:base:)`, never trusted.
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
