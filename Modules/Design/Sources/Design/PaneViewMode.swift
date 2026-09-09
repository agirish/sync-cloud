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

    /// Marks that `liftColumnWidthOffTheFloor` has run, so it can only ever run once.
    static let columnWidthFloorLiftKey = "paneColumnWidthFloorLifted"

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
    /// A single column is framed to the full pane width rather than `columnWidth`, so it leaves no
    /// slack either — which also covers push mode, where exactly one column is ever visible.
    ///
    /// `paneWidth` here is the width available to the COLUMNS, which is the pane minus the preview
    /// pane when one is showing. The preview is not part of the scrolling stack, so it never competes
    /// with this filler for the same points.
    public static func trailingFillerWidth(
        paneWidth: CGFloat,
        columnWidth: CGFloat,
        columnCount: Int,
        isSingleColumn: Bool
    ) -> CGFloat {
        guard !isSingleColumn else { return 0 }
        return max(0, paneWidth - CGFloat(columnCount) * columnWidth)
    }

    // MARK: - Preview column

    /// Whether a pane shows a Quick Look preview for a selected file, as Finder's column view does.
    /// On by default; toggled from the pane header's pill (or the same item in its ⋯ menu at narrow
    /// widths), and from the empty-area context menu of a column or of a tree — the place Finder
    /// keeps its view options.
    ///
    /// One preference across BOTH presentations, deliberately. It answers "do I want to see file
    /// contents while I work here", which is a question about the surface and not about how the
    /// surface happens to be listing its files right now; splitting it would mean flipping the pill
    /// twice to get one outcome, and a mode switch could then take the preview away.
    ///
    /// Shared by both comparison panes and the single-source rail (Organize, Storage), like
    /// `columnWidthDefaultsKey`: across those three this is one reading preference ("do I want to see
    /// file contents while I compare"), not a per-surface layout choice. Browse is the exception —
    /// see `browsePreviewColumnDefaultsKey`.
    public static let previewColumnDefaultsKey = "paneColumnShowsPreview"

    /// Browse's own preview preference, on its own key for the same reason `browseDefaultsKey` exists:
    /// Browse draws the same pane the rail does, at full window width instead of in a rail beside a
    /// lens, and the two are not one decision. Compare and the rail are panes read *against* something
    /// — the other provider, a lens — where a preview costs the columns doing that work half the room;
    /// Browse is the pane where reading a file IS the task. Turning the preview off to compare must not
    /// take it away from browsing.
    ///
    /// No migration seeds this from `previewColumnDefaultsKey`: Browse starts at the default, on.
    public static let browsePreviewColumnDefaultsKey = "paneColumnShowsPreviewBrowse"

    public static let previewColumnDefault = true

    /// Which of the two preview keys a surface reads.
    ///
    /// One function rather than a condition restated per call site, because there are three writers of
    /// this preference — the header's pill, a column's empty-area context menu, and ⇧⌘P — and they must
    /// agree about which surface they are on. `shortcutPreviewColumn` records what a second opinion
    /// costs: it resolved the *rail's* view mode while the user was looking at Browse, so ⇧⌘P was dead
    /// in Browse-Columns whenever the rail happened to sit in Tree. Here the app resolves once, in
    /// `ContentView.resolvedPreviewBinding`, and hands every writer the same binding.
    public static func previewColumnKey(isBrowse: Bool) -> String {
        isBrowse ? browsePreviewColumnDefaultsKey : previewColumnDefaultsKey
    }

    /// Whether a pane's header offers the preview toggle.
    ///
    /// **Both modes, now that Tree draws a preview too.** This used to be `mode == .columns`, on the
    /// honest ground that a switch wired to nothing is worse than no switch: Tree had no preview for
    /// it to govern. That was a fact about the Tree presentation, not about previewing — a selected
    /// file is a selected file whichever way the pane lists it, and the preview reads the selection,
    /// never the stack. `FileTreeView.treePreviewItem` resolves it from the row projection, so the
    /// switch now governs something on every surface and this returns true for both cases.
    ///
    /// Kept as a function rather than deleted at its three call sites. It is the one place that
    /// answers "may this surface offer the preview at all", and a mode that could not draw one (a
    /// future gallery, say) would say so here rather than in the header, the ⋯ menu and ⇧⌘P
    /// separately.
    ///
    /// It used to also require the single-source rail, matching a gate in `PaneColumnsView.previewItem`
    /// that kept the preview off comparison panes. Both are gone: a comparison pane in Columns mode
    /// shows a preview like any other, so its header must offer the switch for it.
    ///
    /// Pane *width* is deliberately not a condition, and this genuinely diverges from
    /// `PaneColumnsView.previewSupportable`, which hides the column context menu's item once a pane is
    /// too narrow to hold a preview. The two differ because they govern different scopes. That menu
    /// item is a view option on one column, so withholding it where this pane can show nothing is
    /// honest; the header's pill is the surface's setting, and widths change under a splitter drag — a
    /// pill that vanished mid-drag would take the setting off screen exactly when widening the pane
    /// again should bring the preview back.
    ///
    /// That second reason now carries this alone. It used to rest on the pill writing one preference
    /// SHARED by both comparison panes and the rail, so a flip in a pane too narrow for a preview "still
    /// did something everywhere else". Browse has its own key (`browsePreviewColumnDefaultsKey`), and a
    /// Browse window narrow enough for this is a window with nowhere else for the flip to show — the
    /// drag argument is what keeps the pill there, not the sharing.
    ///
    /// Stated because the divergence looks like an oversight: do not "align" the two without
    /// deciding which scope you mean.
    public static func showsPreviewToggle(mode: PaneViewMode) -> Bool {
        switch mode {
        case .tree, .columns: return true
        }
    }

    /// Narrower than this a preview is not worth the room it costs: the thumbnail stops carrying
    /// content and the identity lines below it (`kind · size`, the dates) start truncating.
    public static let minimumPreviewColumnWidth: CGFloat = 220
    /// The width a fresh preview opens at, before anyone drags it.
    public static let defaultPreviewColumnWidth: CGFloat = 420
    /// Past this a preview stops being a pane and starts being the window. The `room` cap in
    /// `previewPaneWidth` binds first in any pane narrow enough for it to matter.
    public static let maximumPreviewColumnWidth: CGFloat = 1200

    /// The preview's own width, dragged from the divider on its leading edge and remembered.
    ///
    /// Separate from `columnWidthDefaultsKey`, because the two answer different questions: how much
    /// room the file names need, versus how much the content does.
    public static let previewColumnWidthDefaultsKey = "paneColumnPreviewWidth"

    /// Clamps a preview width into the legible range.
    public static func clampPreviewColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumPreviewColumnWidth), maximumPreviewColumnWidth)
    }

    /// The width a drag on the preview's divider has reached.
    ///
    /// The divider is on the preview's LEADING edge and the preview is pinned to the pane's trailing
    /// edge, so the translation is *subtracted*: dragging left grows the preview. Same anchor
    /// discipline as `draggedColumnWidth` — `translation` is cumulative from the drag's start.
    public static func draggedPreviewColumnWidth(anchor: CGFloat, translation: CGFloat) -> CGFloat {
        clampPreviewColumnWidth(anchor - translation)
    }

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

    // MARK: - Preview beside a tree

    /// The narrowest the outline may be squeezed to by a preview beside it.
    ///
    /// The same number, for the same reason, as `PaneLogic.minRailWidth`: below 220 a file row cannot
    /// show a name. It is stated here rather than read from there because the two are different
    /// scopes that happen to agree — that one clamps a whole rail inside a window, this one divides
    /// one pane — and a shared constant would make retuning either silently retune the other.
    ///
    /// Not `minimumColumnWidth`. A column's 140 is what an unindented list of one folder's rows needs;
    /// a tree indents, so the same name in a deep folder starts at 140 with a good deal of it already
    /// spent, and the pane it is being squeezed by is the whole outline rather than the last column
    /// of a stack the user can scroll.
    public static let minimumTreeListWidth: CGFloat = 220

    /// Whether a Tree pane this wide will show the preview for a selected file.
    ///
    /// Same shape as `showsPreviewColumn` and the same rule underneath — the preview only ever takes
    /// slack the list is not using — with the column stack's two conditions dropped, because a tree
    /// has neither. There is no push navigation to protect (nothing scrolls sideways, so selecting a
    /// file cannot make the pane jump), and no column width to fit beside the preview: the outline is
    /// one list that reflows into whatever it is left, down to `minimumTreeListWidth`.
    public static func showsTreePreview(
        paneWidth: CGFloat,
        isEnabled: Bool,
        hasPreviewTarget: Bool
    ) -> Bool {
        guard isEnabled, hasPreviewTarget else { return false }
        return paneWidth >= minimumTreeListWidth + minimumPreviewColumnWidth
    }

    /// Width of the preview beside a tree: what it was dragged to, capped so a legible outline
    /// remains.
    ///
    /// Delegates to `previewPaneWidth`, so the preview is one width preference across both modes —
    /// drag it in Columns and Tree opens at the same size. Only the floor the cap leaves behind
    /// differs, which is the one thing the two modes genuinely disagree about.
    public static func treePreviewPaneWidth(paneWidth: CGFloat, preferred: CGFloat) -> CGFloat {
        previewPaneWidth(paneWidth: paneWidth, columnWidth: minimumTreeListWidth,
                         preferred: preferred)
    }

    /// Width of the preview pane: exactly what it was dragged to, capped so one full column still
    /// fits beside it.
    ///
    /// The preview is NOT part of the scrolling column stack — it is pinned to the pane's trailing
    /// edge, and the columns scroll in what is left. That structure is the whole point, and it is
    /// what two earlier attempts got wrong:
    ///
    /// - With the preview as the last item INSIDE the stack (`38aca86`), widening it extended the
    ///   stack's content past the pane's right edge: the divider never moved, the visible width never
    ///   changed, and `QLPreviewView` rescaled into a frame that was mostly off screen — the drag read
    ///   as an inexplicable zoom.
    /// - Deriving the width from the columns' slack instead (`924c513`) meant the only way to enlarge
    ///   the preview was to narrow every column until they all fit the pane — at which point the
    ///   stack stopped scrolling and the columns became unreadable, while the preview still could not
    ///   exceed what was left over.
    ///
    /// Pinned, both problems go away at once: growing the preview takes width from the SCROLL VIEW,
    /// so the divider tracks the cursor, the columns keep their own width, and they keep scrolling.
    ///
    /// The cap is the pane minus one column — the columns must never be squeezed out of existence by
    /// the preview describing the file selected in them.
    public static func previewPaneWidth(
        paneWidth: CGFloat,
        columnWidth: CGFloat,
        preferred: CGFloat
    ) -> CGFloat {
        min(clampPreviewColumnWidth(preferred), paneWidth - columnWidth)
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
