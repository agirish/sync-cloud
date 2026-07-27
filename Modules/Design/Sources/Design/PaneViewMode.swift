import AppKit
import SwiftUI

/// How a comparison pane presents its tree: today's outline, or Finder-style columns.
///
/// Columns is the default, and that is safe precisely because of how it rests. With nothing
/// selected a Columns pane is a single column spanning the pane, listing the same folder the tree
/// listed — the pane opens exactly as it did before this setting existed. Columns only appear once
/// you click into a folder, so this changes what a click *does*, not what the pane looks like.
///
/// The two modes therefore differ in exactly one place: a folder row. Tree puts a disclosure
/// triangle on the left and expands children inline; Columns puts a chevron on the right and opens
/// the next column.
public enum PaneViewMode: String, CaseIterable, Identifiable, Sendable {
    case tree
    case columns

    /// The app's default. See the note above for why defaulting to Columns does not move anyone's
    /// furniture on first launch.
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

    /// UserDefaults key for one pane's mode.
    ///
    /// Per-pane by decision, so one side can be a deep tree while the other is flat — hence a key
    /// per side rather than one shared setting.
    ///
    /// Deliberately reachable only through this function. The Tidy single-source rail renders
    /// through the same `FileTreeView` as the comparison panes, and it has no "other pane" to
    /// compare against, no seam link, and its own re-rooting behaviour per lens; letting it inherit
    /// a comparison pane's mode would put a column stack on a surface none of the Columns
    /// navigation rules were designed for. The rail passes no side and stays on `.tree`.
    public static func defaultsKey(isLeft: Bool) -> String {
        isLeft ? "paneViewModeLeft" : "paneViewModeRight"
    }

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
    public static let defaultColumnWidth: CGFloat = 210
    public static let minimumColumnWidth: CGFloat = 140
    public static let maximumColumnWidth: CGFloat = 340

    /// One shared width across both panes, so the two sides stay visually symmetric — they are
    /// being read against each other, and mismatched columns make that harder.
    public static let columnWidthDefaultsKey = "paneColumnWidth"

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

    /// How many columns of `width` fit in `paneWidth`, at least one. The stack scrolls when the
    /// open depth exceeds this, keeping the deepest column visible.
    public static func visibleColumnCount(paneWidth: CGFloat, columnWidth: CGFloat) -> Int {
        guard columnWidth > 0 else { return 1 }
        return max(1, Int(paneWidth / columnWidth))
    }

    /// Clamps a dragged width into the legible range.
    public static func clampColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumColumnWidth), maximumColumnWidth)
    }
}
