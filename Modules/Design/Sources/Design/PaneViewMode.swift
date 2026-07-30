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

    /// UserDefaults key for one comparison pane's mode.
    ///
    /// Per-pane by decision, so one side can be a deep tree while the other is flat — hence a key
    /// per side rather than one shared setting.
    public static func defaultsKey(isLeft: Bool) -> String {
        isLeft ? "paneViewModeLeft" : "paneViewModeRight"
    }

    /// UserDefaults key for the Tidy rail's mode.
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
    /// pane's focus, selection and history too — entering Tidy already re-roots the left pane. A
    /// column stack left in the rail therefore survives into Compare's left pane, showing the
    /// folder you were last in. That is the same continuity the shared focus already provides.
    public static let railDefaultsKey = "paneViewModeRail"

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

    /// Clamps a dragged width into the legible range.
    public static func clampColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumColumnWidth), maximumColumnWidth)
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
    /// A single column is framed to the full pane width rather than `columnWidth`, so it leaves no
    /// slack either — which also covers push mode, where exactly one column is ever visible.
    ///
    /// A preview column takes the same slack (`previewColumnWidth`), so the two must never both
    /// claim it: `hasPreviewColumn` zeroes this outright rather than sharing what is left.
    public static func trailingFillerWidth(
        paneWidth: CGFloat,
        columnWidth: CGFloat,
        columnCount: Int,
        isSingleColumn: Bool,
        hasPreviewColumn: Bool = false
    ) -> CGFloat {
        guard !isSingleColumn, !hasPreviewColumn else { return 0 }
        return max(0, paneWidth - CGFloat(columnCount) * columnWidth)
    }

    // MARK: - Preview column

    /// Whether a Columns pane appends a Quick Look preview column for a selected file, as Finder's
    /// column view does. On by default; toggled from a column's empty-area context menu.
    ///
    /// Shared by both panes and the Tidy rail, like `columnWidthDefaultsKey`: this is a reading
    /// preference ("do I want to see file contents while I browse"), not a per-surface layout choice.
    public static let previewColumnDefaultsKey = "paneColumnShowsPreview"
    public static let previewColumnDefault = true

    /// Narrower than this a preview is not worth the room it costs: the thumbnail stops carrying
    /// content and the identity lines below it (`kind · size`, the dates) start truncating.
    public static let minimumPreviewColumnWidth: CGFloat = 220
    /// The width a preview asks for when the list columns don't leave it that much on their own.
    ///
    /// Not a minimum and not a maximum: with slack to spare the preview takes the slack (see
    /// `previewColumnWidth`), and this is what it claims once the columns have filled the pane. A
    /// deep stack squeezing the preview down to `minimumPreviewColumnWidth` was the first thing the
    /// feature got wrong in use — four open columns left a strip too narrow to read a page in, in a
    /// pane with room for far more.
    public static let defaultPreviewColumnWidth: CGFloat = 380
    /// Past this a preview stops being a column and starts being the pane.
    public static let maximumPreviewColumnWidth: CGFloat = 900

    /// Clamps a preview width into the legible range.
    public static func clampPreviewColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumPreviewColumnWidth), maximumPreviewColumnWidth)
    }

    // The preview deliberately has NO width of its own to drag. It briefly did (`38aca86`,
    // `paneColumnPreviewWidth`) and the geometry does not permit it: the preview is the LAST item in
    // a horizontally scrolling stack, so widening it extends the stack's content to the right, past
    // the pane's edge. The divider — pinned to the trailing edge of a column that has not moved —
    // stays exactly where it is, the visible width never changes, and `QLPreviewView` rescales its
    // content to a frame that is now mostly off screen: the drag reads as an inexplicable zoom, and
    // the metadata values, being trailing-aligned, disappear off the edge with it.
    //
    // Widening the preview is therefore the columns' job: narrow them and the preview takes the slack
    // live, with the divider moving under the cursor as it should. Which also returns that divider to
    // resizing the columns, the thing it was expected to do.

    /// Whether a pane this wide will show the preview column for a selected file.
    ///
    /// The width test is the whole rule: a preview may only ever take slack the list columns are not
    /// using, so the pane must fit one full column *beside* a minimum preview. Without it, selecting
    /// a file in a pane 300pt wide would start the stack scrolling horizontally — a resting pane that
    /// jumps sideways because you clicked a file, which is exactly what Columns' resting-state
    /// contract is about not doing.
    ///
    /// The push-mode test is redundant against today's constants (`minimumColumnWidth` + a minimum
    /// preview is well past `pushNavigationBelowWidth`) and is stated anyway, so that retuning any
    /// one of the three can't quietly put a preview into a pane that shows one pushing column.
    public static func showsPreviewColumn(
        paneWidth: CGFloat,
        columnWidth: CGFloat,
        isEnabled: Bool,
        hasPreviewTarget: Bool
    ) -> Bool {
        guard isEnabled, hasPreviewTarget, !usesPushNavigation(paneWidth: paneWidth) else { return false }
        return paneWidth >= columnWidth + minimumPreviewColumnWidth
    }

    /// Width of the preview column: the slack the list columns leave, or `preferred` when that slack
    /// is less — whichever is larger, and never more than the pane has beside one column.
    ///
    /// Three rules, in that order, each answering a case the others got wrong:
    ///
    /// 1. **Take the slack.** With one column open in a wide pane the preview fills the rest, so the
    ///    common case has nothing to scroll — the same reason `trailingFillerWidth` exists. `floor`
    ///    matters here: at the exact fit the content width must not round *past* the pane and put a
    ///    scrollbar under a stack that fits.
    ///
    ///    This is also the only way the preview is *made* wider: narrow the columns and their slack
    ///    becomes the preview's, live, with the divider tracking the cursor. See the note above for
    ///    why the preview cannot own a dragged width of its own.
    /// 2. **Never below `preferred`.** Once the columns have taken the pane, the slack is whatever
    ///    happens to be left over — four columns left a 270pt strip in a 910pt pane, too narrow to
    ///    read a page in. The preview claims its own width there and the stack scrolls, exactly as it
    ///    already does when the columns alone overflow.
    /// 3. **Never past `room`** — the pane minus one column. A preview wider than that would push the
    ///    column it belongs to off the left edge, so you could no longer see what is selected.
    public static func previewColumnWidth(
        paneWidth: CGFloat,
        columnWidth: CGFloat,
        columnCount: Int,
        /// What the preview asks for when the slack is short. A parameter rather than a direct read of
        /// `defaultPreviewColumnWidth` so the three rules can be tested against each other at widths
        /// the shipped constant doesn't happen to sit at.
        preferred: CGFloat
    ) -> CGFloat {
        let room = paneWidth - columnWidth
        let slack = (paneWidth - CGFloat(columnCount) * columnWidth).rounded(.down)
        return max(min(clampPreviewColumnWidth(preferred), room), slack)
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
