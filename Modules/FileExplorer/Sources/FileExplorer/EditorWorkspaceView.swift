import SwiftUI
import Design
import Sync
import Events

/// The Editor workspace's hard widths, in one place because the app target has to clamp against
/// them and the views have to draw at them.
///
/// **Named together rather than left as literals**, for the reason `PaneLogic.minRailWidth` is:
/// the row that holds these is divided by a fraction the user drags, and a clamp that disagrees
/// with the thing it clamps is how a column ends up too narrow to use with no way to widen it.
public enum EditorLayoutMetrics {
    /// The file rail's width. Fixed rather than draggable: it holds one column of file names, the
    /// sidebar beside it is already resizable, and a third drag handle in the row would be the
    /// third thing to explain before anyone had opened a file.
    public static let railWidth: CGFloat = 232
    /// **The widest the side column may be dragged** (asked 2026-10-17). Edit's list, and its file
    /// pane, share one width the person drags; ``railWidth`` above is that width's floor and its
    /// default — the floor because the list's three tabs are measured to fit at exactly that
    /// (`theRailTabsFitTheRailAtEveryTextSize`), so nothing narrower is safe. 480 leaves a
    /// paragraph beside it on the smallest window and two Columns columns inside the pane.
    public static let maxRailWidth: CGFloat = 480

    /// A dragged or stored side-column width, held inside ``railWidth``…``maxRailWidth``.
    public static func clampedRailWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, railWidth), maxRailWidth)
    }
    /// The narrowest the document column may become. Below this a line of prose stops being a line.
    public static let minDocumentWidth: CGFloat = 260
    /// What the editor half of the row needs in total, which is what the source pane is clamped
    /// against when it is expanded.
    ///
    /// **Plus the two cards' own insets.** The rail and the document each draw as a
    /// `bottomSectionCard`, and a card pads itself by `cardInset` on every side — half a gutter, so
    /// the pair sums to one `cardGutter` between them and another half at each outer edge. That is
    /// 2 × `cardGutter` of horizontal chrome the two columns do not get to use, and leaving it out
    /// of this number is how a clamp comes to guarantee a document width it then shaves 10pt off.
    public static var minWorkspaceWidth: CGFloat {
        railWidth + minDocumentWidth + 2 * LiquidGlass.cardGutter
    }

    /// What the editor half needs when the rail is not drawn: the document and its one card.
    ///
    /// One card is one gutter — half at each outer edge — by the arithmetic the doc comment above
    /// spells out for two. The host clamps the source pane's drag range against this in its
    /// expanded arm, where the rail has stepped aside for the pane; clamping against
    /// ``minWorkspaceWidth`` there reserved 232pt for a column that was not on screen.
    public static var minDocumentOnlyWidth: CGFloat { minDocumentWidth + LiquidGlass.cardGutter }

    /// The narrowest either half of a `.split` may become.
    ///
    /// **Deliberately not ``minDocumentWidth``, which is a different question.** That one is what a
    /// document needs when it is the only thing in the column, and it is what the workspace floor
    /// is built from. This is what each of two columns needs when the reader has asked for both at
    /// once and has a window wide enough to mean it — a smaller number, because a preview beside
    /// the text is worth more than either at its comfortable width.
    public static let minSplitColumnWidth: CGFloat = 220

    /// Where Split's divider starts, and where a double-click on it puts it back (TE181): the middle.
    public static let splitStart: CGFloat = 0.5

    /// `raw` clamped so neither half of a `.split` falls under ``minSplitColumnWidth``.
    ///
    /// **One function, because this arithmetic has already shipped a bug in each direction.**
    /// `min(max(x, lower), 1 - lower)` is not a clamp when `lower > 1 - lower`: it collapses to the
    /// constant `1 - lower` for every input. At the 760pt window floor the document column is
    /// ~391pt, well under 2 × 220, so split mode first shipped with a divider frozen at the
    /// narrowest window the app allows. The guard below fixed that where the divider is DRAWN — and
    /// the drag handler kept its own copy of the unguarded expression, so every drag at that width
    /// committed 0.4373 (or, narrower still, a negative fraction) into the remembered fraction: the
    /// divider did not move, and then jumped to a position nobody chose the moment the window was
    /// widened. Both call sites now ask this.
    public static func splitFraction(_ raw: CGFloat, in width: CGFloat) -> CGFloat {
        // Too narrow to honour two minimums: split the difference rather than pinning one side.
        guard width >= 2 * minSplitColumnWidth else { return 0.5 }
        let lower = minSplitColumnWidth / max(width, 1)
        return min(max(raw, lower), 1 - lower)
    }
}

/// The Editor workspace: the file rail, and the open document beside it.
///
/// **Manager-free, like the compare sheet and unlike the lens surfaces.** Every act this view can
/// perform — open a file, create one, save one — leaves through a closure, so the workspace can be
/// laid out and asserted without a `FileSyncManager` in the room. `ContentView+Editor` is the
/// wrapper that supplies those closures and owns the consequences.
public struct EditorWorkspaceView: View {

    @ObservedObject var document: EditorDocument
    /// The document's characters, observed separately — see ``EditorBuffer``.
    ///
    /// **This view is where the split's two halves meet.** The window above renders the file's
    /// identity and is not told about a keystroke; everything from here down renders the text and
    /// has to be. So the buffer is observed here, once, and the redraw a keystroke causes stops at
    /// this view rather than reaching `ContentView.body` and the App scene's `.commands` tree.
    @ObservedObject var buffer: EditorBuffer
    /// Which files autosave may write. See ``EditorAutosavePolicy``.
    @ObservedObject var autosavePolicy: EditorAutosavePolicy
    /// **The PDF open in Edit, or `nil`** — handed in only while one is open, when the text
    /// document is empty (`path == nil`). The header and the document card draw the PDF instead;
    /// nothing a text file draws is reachable, which is the point — see ``EditorPDFDocument``.
    let pdf: EditorPDFDocument?

    /// The folder the sidebar has selected. Empty when there is none.
    let folder: String
    let entries: [EditorRailEntry]
    /// **What the ＋'s tooltip, the naming row and the rail call `folder`** — the pane breadcrumb's
    /// word for it, built by the host ("iCloud" at the top of iCloud Drive, where the folder's own
    /// last component is "com~apple~CloudDocs"). `nil` falls back to that last component, which is
    /// right for every folder but a source's top — and is what a test with no pane beside it gets.
    var folderDisplayName: String?
    /// **Where ⌘N will make its file, when that is not `folder`** — "Notes", for a pane on a
    /// folder that is no place for a new file (the host's `EditorNewFileFolder`). Named by the ＋'s
    /// tooltips and the naming rows instead of `folderName`; `nil` names `folderName`, as before.
    var newFileFolderName: String?
    /// The rail's folder menu and what a pick in it does — see ``EditorFileRailView/folderTrail``.
    let folderTrail: EditorFolderTrail?
    let onGoToFolder: ((String) -> Void)?
    /// Whether the file rail is drawn beside the document at all.
    ///
    /// **Decided by the host, not here** — `TopPaneVisibility.editorRailIsDrawn` is the rule, and
    /// it reads two bits this view never sees: whether the source pane is open (the pane is then
    /// the file list, and the rail would list the same folder a second time) and whether "Just the
    /// text" is on. Without the rail the document takes the whole width, and the naming row ⌘N
    /// opens is drawn at the top of the document column instead — see ``EditorNamingRow``.
    let showsRail: Bool
    /// Whether Expand is on — the rail bit set AND the source pane folded, which the host works out
    /// (`ContentView.editorIsExpanded`) — the header button's lit state, and whether it reads Expand
    /// or Files. Distinct from `!showsRail`: the rail is also absent while the source pane is open,
    /// and the button is not lit then, because the file list is on screen — it is the pane.
    let railIsHidden: Bool
    /// The Expand button's act. The host owns the bit and what else moves with it.
    let onToggleJustTheText: () -> Void
    /// The rail's fold button (TE77): the list folds into the pane's strip. `nil` draws no button.
    let onFoldRail: (() -> Void)?
    /// The empty page's Show Text Files button — the host passes it only while the list is folded
    /// or put away with the pane folded too, when nothing else on the page leads to a file.
    let onShowTextFiles: (() -> Void)?
    /// **The status line's Show Outline in File List** (TE180): the list on its Outline tab, from
    /// wherever it was — folded, behind the open file pane, or under Expand — as the strip's
    /// Outline button brings it. `nil`, in the previews and probes, only switches the tab.
    let onShowRailOutline: (() -> Void)?
    /// Opens the file pane on the list's folder — the folder menu's Show All (TE183), as the strip's
    /// pane button opens it. `nil` in the previews and probes.
    let onOpenFilePane: (() -> Void)?
    /// **The files Edit opened last, for the empty page** (TE58) — `nil` draws the page as it was,
    /// one sentence. The app passes `EditorRecentFiles.shared`.
    let recentFiles: EditorRecentFiles?
    /// A recent row's click — the host's hand-off, so the pane follows the file. `nil` with
    /// `recentFiles` draws no list either: a row that opened nothing would be worse than none.
    let onOpenRecent: ((String) -> Void)?
    /// **Files dropped from Finder on the empty page** (TE198) — the host opens them as Finder's
    /// Open With does: the first in Edit, the rest waiting in the file pane, a folder named in a
    /// banner. `nil` takes no drop. A drop on an open document is the text's own, unchanged.
    let onDropFiles: (([URL]) -> Void)?
    /// The list's width — the side-column width the host's drag sets, at least
    /// ``EditorLayoutMetrics/railWidth`` (asked 2026-10-17).
    let railWidth: CGFloat
    /// The header's ＋ — **the host's ⌘N closure itself**, not a second copy of what it does.
    ///
    /// ⌘N sets `isNaming` AND bumps the focus counter this view only reads (``namingFocus``); a
    /// button here that set `isNaming` alone would open the row and leave focus wherever it was,
    /// the exact "second ⌘N did nothing" the counter was added for. `nil` greys it. The app always
    /// passes ⌘N's closure: with no folder in the pane, ⌘N makes its file in Notes, so there is no
    /// longer a folderless state to grey it for.
    let onNewTextFile: (() -> Void)?
    /// The header's × (TE46): settle the buffer, then unload the document to the empty state. The
    /// host owns both halves — the unsaved-changes question is asked in `ContentView+Editor` and
    /// nowhere else — so this view only reports the press.
    let onCloseDocument: () -> Void
    /// Passed straight through to the rail's empty caption — see
    /// ``EditorFileRailView/otherFileCount``. Defaulted for the same reason it is defaulted there.
    var otherFileCount: Int?
    /// The raw accent — for washes, hairlines, accent-coloured words and hover tints.
    let accent: Color
    /// The accent deepened until a white label on it clears WCAG AA
    /// (`LiquidGlassHue.accentFillColor`) — what every lit control fills with. The raw accent under
    /// a white label is 2.7:1 on Green; `AccentFillScanTests` keeps it out of Edit's fills.
    let accentFill: Color
    /// The label colour on `accentFill`, the same value the workspace bar's selected segment uses.
    let onAccent: Color
    /// Source / Preview / Split. Held by the host so it survives the workspace being torn down.
    @Binding var mode: EditorMode
    /// The width the editor takes in `.split`, as a fraction of the column.
    ///
    /// **Held by the host beside `mode`, and for the same reason.** As `@State` here it was reset
    /// to 0.5 by every workspace switch — the mode survived the round trip and the divider silently
    /// did not, which is the pair disagreeing about what the session remembers.
    @Binding var splitFraction: CGFloat
    @Binding var isNaming: Bool
    /// The rail's filter, and whether its field is showing. Held by the host beside `isNaming` and
    /// `typedName`, for the same reason — see ``EditorFileRailView/filter``.
    @Binding var railFilter: String
    @Binding var railFilterIsExpanded: Bool
    /// Which half of the rail is showing — its files, or the open document's outline. Held by the
    /// host beside the filter, for the reason that one is: see ``EditorRailTab``.
    @Binding var railTab: EditorRailTab
    /// Where each document's outline was last scrolled to. Held by the host beside the tab, for the
    /// reason that one is — see ``EditorFileRailView/outlineAnchors``.
    @Binding var railOutlineAnchors: [String: Int]
    /// The name being typed in the naming row. Held by the host beside `isNaming` — see
    /// ``EditorFileRailView/typedName``.
    @Binding var typedName: String
    /// A counter ⌘N bumps, so a row that is already open still takes focus. See
    /// ``EditorFileRailView/namingFocus``.
    let namingFocus: Int
    /// **A counter Text ▸ Go to Line… (⌃⌘L) bumps (TE61)**, so the menu opens the field the status
    /// line's "Line, Col" opens — a count rather than a flag for ``namingFocus``'s reason: the second
    /// press is a press too. Read only where Go to Line is offered (``offersGoToLine``).
    let goToLineRequest: Int
    /// The window's editor undo stack. See ``PlainTextEditor/undoManager``.
    let undoManager: UndoManager
    /// Why autosave has stopped, in the header's own words, or `nil` while it is working. A string
    /// rather than the host's enum: this view draws it and never branches on it.
    let stopped: String?
    /// The reason behind ``stopped``, for its tooltip where the words are not a door (TE114) — a
    /// failed write's own sentence, which the banner said once and then took away.
    let stoppedDetail: String?
    /// **The second door onto "which version wins", or `nil` when there is nothing to show.**
    ///
    /// The stop's words are already on this line saying the file changed underneath the buffer, and
    /// the alert that asks about it is modal — Cancel dismisses it and leaves autosave latched
    /// stopped, so without this the only way back to the question is ⌘S, a chord whose name says
    /// "save" pressed to reach a question about not saving.
    ///
    /// **Optional, and the view does not decide.** Which stops have a second version to show is a
    /// rule about the stop, not about the header — see `EditorAutosaveStop.offersDiff`, which is
    /// where it is stated and tested. `nil` here means the words stay words: a plain read-only piece
    /// of state, with no hover wash and nothing for VoiceOver to activate.
    var onShowWhatChanged: (() -> Void)?
    /// **The status word saves** (TE149) — "unsaved — ⌘S", and "not saving — couldn't write" — or
    /// `nil` where the host's stop has nothing a save would settle.
    var onSaveNow: (() -> Void)?
    /// **"not saving — no longer on disk" is Save Again** (TE149), or `nil` for any other stop.
    var onSaveAgain: (() -> Void)?
    /// **Try Again under a refusal for a file that kept changing** (TE152) — reads it once more.
    var onTryAgain: (() -> Void)?
    /// **The question standing over the document after a change from elsewhere** (TE59) — drawn in
    /// the document card, above the text. `nil` while there is none.
    var diskBanner: EditorDiskBanner?
    /// A few seconds of words in the status line about what a change from elsewhere did —
    /// "Reloaded — changed elsewhere".
    var diskNotice: String?
    /// A press on the banner — the host answers it.
    var onDiskBanner: (EditorDiskBannerAction) -> Void
    let prefilledName: () -> String
    let refusal: (String) -> String?
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a typed name. Answers `false` when the file was not created after all, so the
    /// naming row can stay open with the name still in it.
    let onCreate: (String) -> Bool
    /// The reverse of "Open in Edit": shows a file where it lives. Called with the open document's
    /// path by the header's filename menu; the rail's row menu has its own door in
    /// ``railRowActions``, so the host's log can say which one was pressed. Neither closes the
    /// document.
    let onRevealInBrowse: (String) -> Void
    /// Where the open document lives, for the header's meta row — or, with no document open, the
    /// folder a new file would be made in, which is what the empty page's header names instead.
    /// `nil` when there is nothing to place: no document and no folder. Built by the host from the
    /// pane's own breadcrumb model; see ``EditorDocumentLocation``.
    let location: EditorDocumentLocation?
    /// A door in that location, pressed. The host decides what each means for the left pane —
    /// the view only says which word was pressed.
    let onLocationDoor: (EditorDocumentLocation.Door) -> Void
    /// The rail row menu's acts — Reveal in Browse, Get Info, Quick Look, each on that row's file —
    /// built by the host and handed to the rail as they are.
    let railRowActions: EditorRailRowActions
    /// Called when autosave is switched back on for the open document, so the host can write what
    /// is already pending rather than waiting for the next keystroke.
    var onAutosaveResumed: () -> Void = {}
    /// **Whether the source pane beside this column is drawing its tab strip** — two tabs, or View ▸
    /// Tab Bar. The strip sits above the pane's toolbar card and pushes it down by
    /// ``PaneTabStripLadder/slotHeight(_:)``, so the header card here leaves the same slot empty
    /// above itself to stay level with it (TE43's rule: the two cards share their edges, and the
    /// text starts where the list does). `false` whenever the pane is collapsed — there is no strip
    /// on screen then — which is also why it defaults to `false`: every other construction site is
    /// a test of a workspace with no pane beside it.
    var paneShowsTabStrip: Bool = false
    /// **Told about every image dropped on or pasted into the open note (TE56)** — what was written,
    /// so the host can re-read the panes and owe Compare its rescan, or why nothing was, for the
    /// banner. `nil` takes no images: a drop or paste of one does what it always did, rather than
    /// writing files nobody is told about.
    var onImagesImported: ((EditorImageImport.Report) -> Void)?
    /// **Told each time the 256 KB decision is taken** — see ``PreviewLengthHold`` — so the Text and
    /// Markup menus gate on the same answer as the Preview they act on. `nil` tells nobody.
    var onPreviewLengthHold: ((PreviewLengthHold) -> Void)?
    /// **The window's search inside files (RD38)** — the Files list filter's Contents side. Held by
    /// the host beside the filter's text; `nil` draws the name filter alone.
    var contentSearch: EditorContentSearchModel?

    @Environment(\.appFontScale) private var fontScale

    // The window's chrome, read straight from the shared defaults rather than threaded through the
    // initializer — the same four keys `StorageLensView` and `LensWorkspaceView` read to card
    // themselves. This view stays manager-free; these are settings, not state anybody owns.
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }

    /// The parsed document, re-derived off the main actor after the typing settles.
    @State private var blocks: [MarkdownBlock] = []
    /// What the status line says about the buffer, re-derived on the same debounce as the parse.
    @State private var facts: EditorDocumentFacts = .empty
    /// Where every line of the buffer begins, built beside the counts and for the same reason —
    /// see ``EditorLineIndex``. The split's scroll sync and the outline's caret both read it
    /// instead of walking the buffer on the main actor.
    @State private var lineIndex: EditorLineIndex = .empty
    /// The text version ``facts`` and ``lineIndex`` were taken at — `nil` before the first count. The
    /// selection's count pairs itself only with counts of the same text (TE60 review).
    @State private var factsVersion: Int?
    /// The file ``facts`` were counted for — the status line shows them only beside that file (ED2).
    @State private var factsPath: String?
    /// The caret's UTF-16 offset, as the text view last reported it.
    ///
    /// **The offset is kept and the line/column is derived**, rather than the reverse: converting
    /// walks the buffer, and this is written on every arrow key. Storing the cheap thing and paying
    /// for the expensive one on a debounce is the same trade ``EditorDocument/textVersion`` makes.
    @State private var caretOffset: Int = 0
    /// The caret in the terms the status line shows, derived from ``caretOffset``.
    @State private var caret: EditorCaret = EditorCaret(line: 1, column: 1)
    /// The file ``caret`` was derived for — the status line draws "Line, Col" only beside that file
    /// (EP4), as it does the counts beside ``factsPath``.
    @State private var caretPath: String?
    /// Which count, and which caret, of a file just opened skip the debounce — see
    /// ``EditorFirstCountGate``. Held, not observed.
    @State private var factsGate = EditorFirstCountGate()
    @State private var caretGate = EditorFirstCountGate()
    /// The open document's headings, re-derived beside the blocks they come from.
    @State private var outline: [MarkdownOutlineEntry] = []
    /// Which parse is on screen — see ``EditorParseLanding``. Held, not observed: counting a parse
    /// must not re-render the view.
    @State private var parseTickets = EditorParseTickets()
    /// The same for the counts, and for the caret (F-E6).
    @State private var countTickets = EditorParseTickets()
    @State private var caretTickets = EditorParseTickets()
    /// Where the text view has been asked to put the caret, and where the preview has been asked to
    /// scroll. **Two requests, because they are asked for by different things**: an outline click
    /// moves both, and a scroll in split moves only the preview.
    @State private var editorScrollRequest: EditorScrollRequest?
    @State private var previewScrollRequest: EditorScrollRequest?
    /// Bumped on every request, so asking for the same line twice is two requests.
    @State private var scrollToken: Int = 0
    /// Bumped by the header's Find button. See ``PlainTextEditor/findRequest``.
    @State private var findRequest: Int = 0
    /// The same, for Split's editable Preview half while the caret was last there (V7).
    @State private var splitPreviewFindRequest: Int = 0
    /// The selection's UTF-16 length, beside ``caretOffset`` (its location) — what the format bar's
    /// lit state and the status line's selection count (TE60) are derived from. Stored cheap,
    /// derived on a debounce, as the caret is — and **held, not observed**: `@State` keeps the box,
    /// and only ``EditorSelectionDerivations`` watches what is in it, so a forward drag's tick
    /// re-renders that and not this whole view (``EditorLiveSelection``).
    @State private var liveSelection = EditorLiveSelection()
    /// **The selection's counts for the status line (TE60)**, or `nil` for a bare caret. Derived from
    /// ``caretOffset`` and the live selection on the caret's debounce, off the main actor.
    @State private var selectionFacts: EditorSelectionFacts?
    /// Whether Go to Line's field is up over the status line's "Line, Col" (TE61).
    @State private var goToLineShown = false
    /// The floating disk banner's measured height — see ``diskBannerInset``.
    @State private var diskBannerHeight: CGFloat = 0
    /// What the format bar shows lit — see ``MarkupFormatState``.
    @State private var formatState: MarkupFormatState = .none
    /// Editable Preview's pending styles, as verbs — lit on the bar while Preview has the caret
    /// (FMT-15). Preview reports them as they change.
    @State private var previewPending: Set<MarkupVerb> = []
    /// The text view, for the format bar's buttons — see ``EditorTextViewHandle``.
    @State private var textViewHandle = EditorTextViewHandle()
    /// View ▸ Format Bar. Read here like the glass settings above: a preference, not state.
    @AppStorage(EditorTextSettings.showsFormatBarKey) private var showsFormatBarPreference: Bool
        = EditorTextSettings.showsFormatBarDefault
    /// Icon and Text or Icon Only — the format bar's right-click choice (TE64).
    @AppStorage(EditorTextSettings.formatBarShowsLabelsKey) private var formatBarShowsLabels: Bool
        = EditorTextSettings.formatBarShowsLabelsDefault
    /// Live only while the divider is being dragged; the committed value lives with the host.
    @State private var splitDrag: CGFloat?
    /// Text ▸ Edit in Preview (Experimental) and the pill in the Preview column (TE67).
    @AppStorage(EditorTextSettings.editsInPreviewKey) private var editsInPreviewPreference: Bool
        = EditorTextSettings.editsInPreviewDefault
    @AppStorage(EditorTextSettings.editsInPreviewIntroSeenKey) private var editsInPreviewIntroSeen = false
    /// The page under Source's text — Paper, the switch beside Autosave, and Text ▸ Paper Background.
    @AppStorage(EditorTextSettings.drawsPageKey) private var drawsPage: Bool = EditorTextSettings.drawsPageDefault
    /// The pill's one-time "experimental" popover — see ``PreviewEditToggle/showsIntro``.
    @State private var showsPreviewEditIntro = false
    /// Whether this note is too long to edit in Preview, as decided when Preview was opened for it.
    @State private var previewLengthHold: PreviewLengthHold?
    /// "That change needs Source." while Preview has just refused an edit — see ``EditorStatusHint``.
    @State private var statusHint: EditorStatusHint?
    /// Counts every hint raised, so each has its own token for as long as this view lives — one
    /// restarted at 1 had an earlier timer clear a later hint early (review).
    @State private var hintsRaised = 0
    /// Split with Preview editable: which half leads the scroll (TE67.4).
    @State private var splitFollow = SplitScrollFollow()
    /// Split with Preview editable: where Source scrolls to follow Preview — the view, not the caret.
    @State private var editorFollowRequest: EditorScrollRequest?
    /// **A Contents result waiting for its file to arrive** (RD38): the match to select once the
    /// document is the one clicked. Waits for the arrival because from the empty page the file's
    /// text view is built in the arrival's own update, and a request standing when a text view is
    /// built is taken as already answered (`PlainTextEditor.makeCoordinator`, so a mode switch never
    /// replays an old jump). Sent from the arrival's handler, it reaches the view that update built
    /// (`EditorContentOpenMountedTests`).
    @State private var pendingContentMatch: EditorContentMatch?
    /// The same, for a PDF result: the word its find is to hold once the PDF is the one open.
    @State private var pendingPDFFind: EditorContentMatch?

    public init(document: EditorDocument,
                autosavePolicy: EditorAutosavePolicy,
                pdf: EditorPDFDocument? = nil,
                folder: String,
                entries: [EditorRailEntry],
                otherFileCount: Int? = nil,
                showsRail: Bool,
                railIsHidden: Bool,
                accent: Color,
                accentFill: Color,
                onAccent: Color,
                mode: Binding<EditorMode>,
                splitFraction: Binding<CGFloat>,
                isNaming: Binding<Bool>,
                typedName: Binding<String>,
                railFilter: Binding<String>,
                railFilterIsExpanded: Binding<Bool>,
                railTab: Binding<EditorRailTab>,
                railOutlineAnchors: Binding<[String: Int]>,
                namingFocus: Int = 0,
                goToLineRequest: Int = 0,
                undoManager: UndoManager,
                stopped: String? = nil,
                stoppedDetail: String? = nil,
                onShowWhatChanged: (() -> Void)? = nil,
                onSaveNow: (() -> Void)? = nil,
                onSaveAgain: (() -> Void)? = nil,
                onTryAgain: (() -> Void)? = nil,
                diskBanner: EditorDiskBanner? = nil,
                diskNotice: String? = nil,
                onDiskBanner: @escaping (EditorDiskBannerAction) -> Void = { _ in },
                prefilledName: @escaping () -> String,
                refusal: @escaping (String) -> String?,
                onOpen: @escaping (EditorRailEntry) -> Void,
                onCreate: @escaping (String) -> Bool,
                onRevealInBrowse: @escaping (String) -> Void,
                // No defaults, so every construction site is read — the header's location is a
                // claim about where the file lives, and a site that silently passed `nil` would
                // leave the header saying nothing again.
                location: EditorDocumentLocation?,
                onLocationDoor: @escaping (EditorDocumentLocation.Door) -> Void,
                // No default, like `onToggleJustTheText`, and none inside it for the host's three
                // acts: a rail row menu whose acts defaulted to nothing would draw, and do nothing,
                // at any site that forgot them.
                railRowActions: EditorRailRowActions,
                // No default, so every construction site is read: the two in tests pass `{}`.
                onToggleJustTheText: @escaping () -> Void,
                // No defaults either, for the same reason: a construction site that forgot one
                // would draw a ＋ or a × that does nothing.
                onNewTextFile: (() -> Void)?,
                onCloseDocument: @escaping () -> Void,
                onAutosaveResumed: @escaping () -> Void = {},
                paneShowsTabStrip: Bool = false,
                folderDisplayName: String? = nil,
                newFileFolderName: String? = nil,
                onImagesImported: ((EditorImageImport.Report) -> Void)? = nil,
                onPreviewLengthHold: ((PreviewLengthHold) -> Void)? = nil,
                contentSearch: EditorContentSearchModel? = nil,
                // No defaults: a folder line whose menu silently went nowhere is the failure.
                folderTrail: EditorFolderTrail?,
                onGoToFolder: ((String) -> Void)?,
                onFoldRail: (() -> Void)? = nil,
                onShowTextFiles: (() -> Void)? = nil,
                onShowRailOutline: (() -> Void)? = nil,
                onOpenFilePane: (() -> Void)? = nil,
                recentFiles: EditorRecentFiles? = nil,
                onOpenRecent: ((String) -> Void)? = nil,
                onDropFiles: (([URL]) -> Void)? = nil,
                railWidth: CGFloat = EditorLayoutMetrics.railWidth) {
        self._railFilter = railFilter
        self._railFilterIsExpanded = railFilterIsExpanded
        self._railTab = railTab
        self._railOutlineAnchors = railOutlineAnchors
        self.document = document
        // Taken from the document rather than passed in: there is exactly one buffer per document
        // and it is held for the document's life, so a second parameter would only be a way for a
        // caller to hand this view the wrong one.
        self.buffer = document.buffer
        self.autosavePolicy = autosavePolicy
        self.pdf = pdf
        self.folder = folder
        self.entries = entries
        self.otherFileCount = otherFileCount
        self.showsRail = showsRail
        self.railIsHidden = railIsHidden
        self.onToggleJustTheText = onToggleJustTheText
        self.onFoldRail = onFoldRail
        self.onShowTextFiles = onShowTextFiles
        self.onShowRailOutline = onShowRailOutline
        self.onOpenFilePane = onOpenFilePane
        self.recentFiles = recentFiles
        self.onOpenRecent = onOpenRecent
        self.onDropFiles = onDropFiles
        self.railWidth = railWidth
        self.onNewTextFile = onNewTextFile
        self.onCloseDocument = onCloseDocument
        self.accent = accent
        self.accentFill = accentFill
        self.onAccent = onAccent
        self._mode = mode
        self._splitFraction = splitFraction
        self._isNaming = isNaming
        self._typedName = typedName
        self.namingFocus = namingFocus
        self.goToLineRequest = goToLineRequest
        self.undoManager = undoManager
        self.stopped = stopped
        self.stoppedDetail = stoppedDetail
        self.onShowWhatChanged = onShowWhatChanged
        self.onSaveNow = onSaveNow
        self.onSaveAgain = onSaveAgain
        self.onTryAgain = onTryAgain
        self.diskBanner = diskBanner
        self.diskNotice = diskNotice
        self.onDiskBanner = onDiskBanner
        self.prefilledName = prefilledName
        self.refusal = refusal
        self.onOpen = onOpen
        self.onCreate = onCreate
        self.onRevealInBrowse = onRevealInBrowse
        self.location = location
        self.onLocationDoor = onLocationDoor
        self.railRowActions = railRowActions
        self.onAutosaveResumed = onAutosaveResumed
        self.paneShowsTabStrip = paneShowsTabStrip
        self.folderDisplayName = folderDisplayName
        self.newFileFolderName = newFileFolderName
        self.onImagesImported = onImagesImported
        self.onPreviewLengthHold = onPreviewLengthHold
        self.contentSearch = contentSearch
        self.folderTrail = folderTrail
        self.onGoToFolder = onGoToFolder
    }

    /// **The Expand button's word (TE48): its NEXT act, not its state** — the way the spine's
    /// chevron names its own. "Expand" while the rail, the pane and the sidebar can be put away;
    /// "Files" once they are, which is the way back to them. The word is also the button's
    /// accessibility label, so a VoiceOver or Voice Control user says what a sighted one reads. A
    /// static so the test can pin the two strings without a hosted accessibility tree, which
    /// `swift test` does not build.
    static func expandTitle(railIsHidden: Bool) -> String {
        railIsHidden ? "Files" : "Expand"
    }

    /// What the Expand button says under the pointer, before its chord: the act in full, since the
    /// word alone does not say what "Expand" puts away.
    static func expandHelp(railIsHidden: Bool) -> String {
        railIsHidden ? "Show the files again, as they were"
                     : "Give the document the window — put away the file list and the sidebar"
    }

    /// The glyph: arrows out to expand, arrows in to come back to the files — the platform's own
    /// pair for growing and shrinking a view.
    static func expandSymbol(railIsHidden: Bool) -> String {
        railIsHidden ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    /// What the header's ＋ says in its tooltip: where the file will be made. The rail's ＋ names
    /// its folder on the line beside it; this one has nothing beside it that does, so the tooltip
    /// carries the folder. A static for the reason ``expandTitle(railIsHidden:)`` is one.
    static func newTextFileTitle(folderName: String) -> String {
        folderName.isEmpty ? "Pick a folder in the sidebar first" : "New text file in \(folderName)"
    }

    /// **What the empty page says under its header: how to OPEN a file — one sentence.**
    ///
    /// Every variant ends on ⌘O, the one door into Edit that is reachable from every other place a
    /// text file is listed, and the one nothing on this page would otherwise mention. What it no
    /// longer says is "press ⌘N to make one": the header above now always carries the ＋, with ⌘N as
    /// its keycap and tooltip, so the caption repeating it was a second copy of a control on the
    /// same screen — and a sentence with three ways in stopped being one sentence.
    ///
    /// "From the list" only while the rail is there. Without it the list is the source pane, or — under
    /// Expand — nothing at all until the header's lit Files button or the spine's rung brings it
    /// back, and this view cannot tell those two apart; a sentence that names neither is right in
    /// both. Both chords come from `AppChord`, so a rebinding moves the words with it. A static so
    /// the test can read the three sentences without rendering them. It names the three workspaces
    /// ⌘O works from rather than saying "in any tab": a pane's tabs and the workspace switcher are
    /// both tabs in this app.
    static func emptyCaption(hasFolder: Bool, showsRail: Bool) -> String {
        let open = "press \(AppChord.openInEditor.display) on a text file or PDF in Browse, Compare or Organize"
        guard hasFolder else { return "Pick a folder in the sidebar, then choose a file to edit — or \(open)." }
        return showsRail
            ? "Choose a file from the list — or \(open)."
            : "Choose a file to edit — or \(open)."
    }

    /// What the header's × is called to VoiceOver. Names the file, because the button sits at the
    /// far end of the row from the name it acts on.
    static func closeTitle(name: String) -> String {
        name.isEmpty ? "Close this document" : "Close \(name)"
    }

    /// The mode actually being drawn — `.edit` on a file with nothing to preview, whatever the
    /// capsule last remembered. The header asks this rather than `mode` for the reason
    /// ``EditorMode/resolved(_:isMarkdown:)`` exists.
    private var resolvedMode: EditorMode {
        EditorMode.resolved(mode, isMarkdown: document.isMarkdown)
    }

    /// The folder as the header and the rail name it — see ``folderDisplayName``.
    var folderName: String {
        guard !folder.isEmpty else { return "" }
        if let folderDisplayName, !folderDisplayName.isEmpty { return folderDisplayName }
        return (folder as NSString).lastPathComponent
    }

    /// The folder the ＋ and the naming row name: where the new file will be made.
    var newFileFolderLabel: String {
        if let newFileFolderName, !newFileFolderName.isEmpty { return newFileFolderName }
        return folderName
    }

    /// **Two cards in Cards; in Unified, two areas of the window's one region with a rule down it.**
    ///
    /// Whether the open text document is a Markdown note that was read — what keeps the rail's
    /// Outline tab (TE111). A refused note has no text and so no headings, whatever its name says.
    public static func markdownIsOpen(_ document: EditorDocument) -> Bool {
        document.isMarkdown && document.refusal == nil
    }

    /// The rail and the document are two different things — a list of what you could open, and the
    /// thing you have open — and every pair of neighbours in this window says so the same way: two
    /// cards with a gutter between them in Cards, a hairline between them in Unified
    /// (`unifiedSeam`). Drawn flat in Cards, they were the only surfaces in the app sitting directly
    /// on the window's glass while the sidebar and the source pane beside them floated; drawn as two
    /// boxes in Unified, they read as Cards in the style named for being one surface.
    ///
    /// `spacing: 0` and no padding here: in Cards `bottomSectionCard` insets itself by `cardInset`,
    /// half a gutter, so two adjacent cards come to exactly one `cardGutter` between them and line
    /// up with the pane cards at the window edge; in Unified it insets nothing and the two sit flush.
    /// No `Divider` in Cards — a rule down the middle of a gutter is a third edge between two that
    /// are already there, the same reason the sidebar's seam is a clear strip there.
    public var body: some View {
        HStack(spacing: 0) {
            // Conditional on `showsRail` rather than hidden by opacity or width: an absent rail
            // costs the layout nothing, which is what lets the document take the whole row.
            if showsRail {
            EditorFileRailView(folderName: folderName,
                               entries: entries,
                               otherFileCount: otherFileCount,
                               selectedPath: pdf?.path ?? document.path,
                               accent: accent,
                               accentFill: accentFill,
                               onAccent: onAccent,
                               tab: $railTab,
                               isNaming: $isNaming,
                               typedName: $typedName,
                               documentStatus: status,
                               namingFocus: namingFocus,
                               prefilledName: prefilledName,
                               refusal: refusal,
                               filter: $railFilter,
                               filterIsExpanded: $railFilterIsExpanded,
                               outline: outline,
                               markdownIsOpen: Self.markdownIsOpen(document),
                               currentOutlineIndex: shownCaretLine.flatMap {
                                   MarkdownOutline.currentEntry(forLine: $0, in: outline)
                               },
                               outlineAnchors: $railOutlineAnchors,
                               pdf: pdf,
                               onSelectHeading: goToHeading,
                               onReturnKeys: railReturnKeys,
                               onOpen: onOpen,
                               onCreate: onCreate,
                               onNewTextFile: onNewTextFile,
                               newFileFolderName: newFileFolderName,
                               folderTrail: folderTrail,
                               onGoToFolder: onGoToFolder,
                               onOpenFilePane: onOpenFilePane,
                               rowActions: railRowActions,
                               onFold: onFoldRail,
                               contentSearch: contentSearch.map {
                                   EditorRailContentSearch(model: $0, folder: folder, onOpen: openContentResult)
                               },
                               width: railWidth)
                .frame(maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
                .unifiedSeam(surfaceStyle, edge: .trailing)
            }
            documentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // **Here, on the whole workspace** — not beside the text's arrival handler, whose view is
        // taken down the moment a PDF opens and so never hears the PDF arrive (RD38).
        .onChange(of: pdf?.path) { _, _ in seedPendingPDFFind() }
    }

    // MARK: - The open document

    /// **Two cards, the file pane's two: a header card, and the text under it** (TE43).
    ///
    /// The source pane beside this column is a toolbar card over a list card, and the document was
    /// one card with its header drawn inside it — so the two halves of the window disagreed about
    /// where the chrome ends and the content starts. Now the header is its own card, pinned to
    /// `LiquidGlass.headerHeight`, which is the height the pane's `PaneHeader` is pinned to: the two
    /// cards share a bottom edge because both read the ONE constant, not because a second copy of
    /// the pane's number was typed here (the same rule the capsule reservation below states). With
    /// the pane collapsed there is no toolbar card to line up with, and the header keeps the height
    /// anyway — a document that moved when the pane opened would be worse than one that waited for
    /// a card that is not there.
    ///
    /// **Per surface style, because the pane is.** In `.cards` the pane's header and list are two
    /// cards with a gutter between them (`paneCardIfNeeded`), so this column is two cards. In
    /// `.unified` the pane's list is flush under its header with a hairline between, so this
    /// column's text is flush under its header the same way — two cards here would put a gutter
    /// where the pane has none, and the text would start one gutter below the list.
    ///
    /// **No document, the same two cards.** The empty page keeps its header card, at the same pinned
    /// height, so nothing jumps when a file opens or closes — see ``emptyHeaderContent`` for what it
    /// says with nothing to name. It used to fall back to one card with the caption in it, which
    /// moved the caption's card up by a header and a gutter on every close and left the header's
    /// controls unreachable on the one page that has nothing else to press.
    ///
    /// **Under the pane's tab strip, the strip's slot is left empty** (``paneShowsTabStrip``), the
    /// way each style draws the strip: in `.cards` a gap above the header card where the strip's own
    /// card stands in the pane, so the two header cards share their top edge as well as their bottom;
    /// in `.unified` a band inside the region above the header, so the two regions' tops stay level
    /// as the pane's strip is flush inside its region.
    ///
    /// The two styles go through the helpers every workspace column shares (`columnSectionCard`,
    /// `columnRegionFrame`, `columnHeaderRule`), so this column cannot drift from the pane, the
    /// Organize lenses and the Differences area beside it.
    private var documentColumn: some View {
        let stripSlot = paneShowsTabStrip ? PaneTabStripLadder.slotHeight(surfaceStyle) : 0
        let cards = surfaceStyle == .cards
        return VStack(spacing: 0) {
            // Unified: the strip's band, inside the region. Cards: the gap above the header card,
            // which is padding outside both cards (below).
            Color.clear.frame(height: cards ? 0 : stripSlot)
            // The rule is drawn OVER the header's bottom edge rather than under it, so it costs no
            // height: the pane's list starts flush at the header's pinned edge and so must this
            // column's text.
            headerCard
                .columnHeaderRule(surfaceStyle)
                .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
            textCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
        .padding(.top, cards ? stripSlot : 0)
        .columnRegionFrame(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// The header, at the pane toolbar card's height. Internal so `EditorHeaderLocationTests` and
    /// `EditHeaderMatchesPaneHeaderTests` can measure the card itself rather than its contents.
    var headerCard: some View {
        header
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: LiquidGlass.headerHeight)
    }

    /// Everything under the header: ⌘N's row when it has no rail to live in, the document, and — for
    /// a text file — its status line. A PDF has none (Phase 6a).
    private var textCard: some View {
        VStack(spacing: 0) {
            // ⌘N's row, when there is no rail to draw it in. The rail draws it otherwise, and the
            // two conditions are exclusive — see ``EditorNamingRow``. The folder is named here
            // because nothing else in this column says where the file is about to be created.
            //
            // **In the text card, not above the header.** The header card's height is the pane's
            // toolbar card's, and a row that came and went above it would move it off that line
            // for as long as ⌘N was open.
            if !showsRail && isNaming {
                EditorNamingRow(isNaming: $isNaming, typedName: $typedName, namingFocus: namingFocus,
                                accent: accent, prefilledName: prefilledName, refusal: refusal,
                                onCreate: onCreate, folderName: newFileFolderLabel)
                    .padding(.top, 6)
            }
            if let pdf {
                // **No find bar, no Fill & Sign toolbar and no status line here** (Phases 6a and
                // 6b): the find card, Fill & Sign's palette and its save pill float over the pages
                // (`EditorPDFReader`), and what the status line said is the header's row 2 and the
                // capsule's.
                EditorPDFBody(pdf: pdf, accent: accent, accentFill: accentFill, onAccent: onAccent,
                              quickLook: railRowActions.quickLook,
                              download: railRowActions.download)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                textBody
            }
        }
    }

    /// The text document under the header, and its status line.
    @ViewBuilder
    private var textBody: some View {
        body(for: document)
        // **Not under a refusal.** A document that could not be read has an empty buffer, and
        // "0 words · 0 characters" under a caption explaining why there is nothing here reads
        // as a measurement of the file rather than of the nothing that was loaded.
        if document.path != nil, document.refusal == nil {
            Divider()
            // Formatted when the stamp moved, not here — see ``EditorDocument/sizeCaption``.
            EditorStatusLine(facts: EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path),
                             caret: caret, fileSize: document.sizeCaption,
                             headings: statusHeadings, hint: statusHint,
                             selection: selectionFacts, goToLine: statusGoToLine, notice: diskNotice,
                             heldFacts: facts, caretIsCurrent: caretPath == document.path)
                // Compared on what it draws, the closures left out — see `EditorStatusLine.==`.
                .equatable()
        }
    }

    /// **Go to Line, where there are source lines on screen to go to (TE61)** — Source and Split, and
    /// never Preview, editable or not: a rendered page has no line 48 to put the caret on. One rule
    /// for the status line's "Line, Col" and for the menu item (`EditorVerbs.goToLine`).
    public static func offersGoToLine(_ resolvedMode: EditorMode) -> Bool { resolvedMode != .preview }

    private var offersGoToLine: Bool { Self.offersGoToLine(resolvedMode) }

    /// The status line's door to Go to Line, or `nil` in Preview.
    private var statusGoToLine: EditorStatusGoToLine? {
        guard offersGoToLine else { return nil }
        // This file's count, or none while the one on hand is the last file's (EP7).
        let lines = EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path).map { max($0.lines, 1) }
        return EditorStatusGoToLine(isPresented: $goToLineShown, lineCount: lines,
                                    accent: accent, onGo: goToLine)
    }

    /// **Sends Source's caret to a line, and its column when one was typed** — the outline's scroll
    /// request with a column on it, which is what tells the text view to clamp (TE61). In Split the
    /// preview follows the text's scroll as it always does.
    private func goToLine(_ target: EditorGoToLine.Target) {
        goToLineShown = false
        scrollToken &+= 1
        editorScrollRequest = EditorScrollRequest(line: target.line, token: scrollToken,
                                                  column: target.column ?? 1)
    }

    /// The caret's line when it was derived for the open file, else `nil` — what the rail's outline
    /// and the status line's heading name the caret's section by (F-E1).
    private var shownCaretLine: Int? {
        EditorStatusLine.shownCaretLine(caret, derivedFor: caretPath, open: document.path)
    }

    /// The status line's heading item (TE57): the rail's own outline and scroll request, reachable
    /// with the rail away — and a way to the rail's Outline tab from wherever it is not showing
    /// (TE180).
    private var statusHeadings: EditorStatusHeadings? {
        EditorStatusHeadings.make(outline: outline, caretLine: shownCaretLine, isMarkdown: document.isMarkdown,
                                  offersRailOutline: EditorStatusHeadings.offersRailOutline(showsRail: showsRail,
                                                                                            railTab: railTab),
                                  accent: accent,
                                  onSelect: goToHeading, onShowRailOutline: onShowRailOutline ?? { railTab = .outline })
    }

    /// The two rows above the document: which file, and where it stands.
    ///
    /// **Its own view so a test can measure it.** The heights of the two rows are decided by their
    /// tallest child — the mode capsule on one, the switch on the other — and both of those change
    /// with the text size. Asserting that a Markdown header and a plain-text header come out the
    /// same means measuring them, and measuring them means being able to build one.
    var header: some View {
        EditorDocumentHeader {
            if let pdf {
                EditorPDFHeader(pdf: pdf, accent: accent, accentFill: accentFill, onAccent: onAccent,
                                onRevealInBrowse: onRevealInBrowse, rowActions: railRowActions,
                                onClose: onCloseDocument) { rung in
                    expandButton(worded: rung.isWorded)
                }
            } else if document.path == nil { emptyHeaderContent } else { headerContent }
        }
    }

    /// Internal rather than private, so `EditorLayoutTests` can render the header on its own and
    /// measure it. The header's height is decided by the tallest thing in each of its two rows, and
    /// the whole point of the reservation below is that this comes out the same for a Markdown file
    /// and a plain-text one — which is a claim about a number, so it wants a measurement.
    @ViewBuilder
    var headerContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameRow
            metaRow
        }
    }

    /// **The name row, and which words it draws: the file's name decides.**
    ///
    /// The row holds the name, then New Text File, Find, the capsule, Files (Expand) and Close, and
    /// the name is the only thing in it that gives. Left to its own `ViewThatFits`, the capsule kept its words
    /// whenever IT fitted — so from a ~560pt column up, a long name paid for "Source", "Preview"
    /// and "Split": measured 2026-09-25 on a 55-character `.md` name at 100%, a 580pt column left
    /// 214pt of name beside the words where the icons alone leave it 338. The name is what the row
    /// is for, so
    /// the rule is TE28's, the preview's Edit button beside a long name: **the words are drawn only
    /// when the WHOLE name fits beside them.** Otherwise the capsule is icons alone — pencil, eye,
    /// split — with each mode's name kept as its tooltip and its accessibility label.
    ///
    /// `ViewThatFits` asks each row for its IDEAL width, which for the worded row is the name at
    /// full length, so a name that would truncate beside the words picks the second row; that one
    /// is laid out in the width there actually is, where the name truncates if it still must.
    /// Both rungs are the same height (`bothCapsuleRungsAreTheSameHeight`), so the choice never
    /// moves the row. A plain-text file has no capsule to choose for and reserves its height with
    /// a hidden one, as before.
    ///
    /// **The buttons' words join the same budget, and go FIRST, all four together** (TE48, TE144).
    /// Three rungs on a Markdown file — every word; the capsule's words without the buttons'; no
    /// words — and two on plain text. The buttons' words are the cheaper to lose: each glyph is a
    /// familiar one with a tooltip, where a capsule of three bare glyphs asks the reader to know
    /// which mode is which. ``nameRowRungs(isMarkdown:)`` is the order, and the tests read it there.
    @ViewBuilder
    private var nameRow: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(Self.nameRowRungs(isMarkdown: document.isMarkdown).enumerated()),
                    id: \.offset) { _, rung in
                nameRow(rung)
            }
        }
    }

    /// One reading of the name row: the capsule at a rung — or `nil`, only its height reserved, on a
    /// file with nothing to preview — and whether the header's buttons wear their words.
    struct NameRowRung: Equatable {
        var capsule: EditorModeBar.Rung?
        /// New Text File, Find, Files and Close: **all four keep their words, or none does** (TE144)
        /// — a row of three words beside one bare glyph read as two styles, the PDF header's lesson.
        var chipsWorded: Bool
    }

    /// The name row's rungs, widest first. The buttons' words go before the capsule's.
    static func nameRowRungs(isMarkdown: Bool) -> [NameRowRung] {
        isMarkdown
            ? [NameRowRung(capsule: .labelled, chipsWorded: true),
               NameRowRung(capsule: .labelled, chipsWorded: false),
               NameRowRung(capsule: .glyphOnly, chipsWorded: false)]
            : [NameRowRung(capsule: nil, chipsWorded: true),
               NameRowRung(capsule: nil, chipsWorded: false)]
    }

    /// One reading of the name row — see ``NameRowRung``.
    private func nameRow(_ reading: NameRowRung) -> some View {
        HStack(spacing: 6) {
            // **Three states, because two of them are the point.**
            //
            // This briefly drew only the stopped state, on the reasoning that an unsaved buffer
            // is now ordinary and a dot tracking it would be a light that is always on. That
            // was wrong about what the light is FOR: it is on while you type and for the couple
            // of seconds after, and off the rest of the time — so watching it go out is the
            // only evidence on screen that autosave is working at all. Removing it left a
            // header that said "saved" whether or not anything had been written, which is
            // exactly the reassurance nobody should take on trust.
            //
            // Accent while the write is pending, amber when writing has STOPPED, nothing when
            // the file matches the buffer. The two coloured states are never both true: a stop
            // is only interesting because the document is dirty under it.
            Circle()
                .fill(dotColour ?? .clear)
                .frame(width: 6, height: 6)
                // **A column, not just a dot** — and the same width is reserved on the row
                // below. The title used to start one dot-and-a-gap further right than the line
                // under it, so the header's two rows had two different left edges.
                .frame(width: Self.dotColumnWidth, alignment: .leading)
                .opacity(dotColour == nil ? 0 : 1)
                .accessibilityHidden(dotColour == nil)
                .accessibilityLabel(status.dotName)
            Text(document.name)
                .scaledFont(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                // The whole name, and what right-click offers (TE157) — only where there is a menu.
                .help(document.path == nil ? "" : EditorRailRowMenu.nameTooltip(document.name))
                // The way back. The hand-off into this workspace comes from a file row, so the
                // filename is where a user looks to ask "where is this?" — and it offers what the
                // file's row in the list offers (TE112), with Reveal in Browse through the
                // header's own door.
                .contextMenu {
                    if let path = document.path {
                        EditorRailRowMenu(path: path, isCloudOnly: Self.isNotDownloaded(document.refusal),
                                          actions: railRowActions.revealing(through: onRevealInBrowse))
                    }
                }
            Spacer(minLength: 0)
            // **Each button its own glass capsule** in Frosted and Clear (TE144) — New Text File and
            // Find were one, grouped as Finder groups related buttons, until both wore words: two
            // worded actions in one capsule read as one control. The row's own 6pt between them,
            // so Solid's layout is the row's.
            //
            // New Text File — see ``newTextFileButton``; the empty page's header draws the same one.
            newTextFileButton(worded: reading.chipsWorded)
            // **Beside the capsule, not in it.** The capsule chooses which representation you
            // are looking at; this acts on the one you are in. It is withheld in `.preview`,
            // where there is no text view to search — the preview is a rendering, and a find
            // bar over it would be searching a copy of the document rather than the document.
            if resolvedMode != .preview || editsInPreview {
                Button {
                    // The half the caret was last in, in Split — the bar's rule (V7).
                    if textViewHandle.targetsSplitPreview {
                        splitPreviewFindRequest &+= 1
                    } else {
                        findRequest &+= 1
                    }
                } label: {
                    EditorHeaderChipLabel(symbol: "magnifyingglass", word: reading.chipsWorded ? Self.findWord : nil)
                }
                .chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)
                .chromeGlassClearance(.leading, rowSpacing: 6)
                .accessibilityLabel("Find in this document")
                .accessibilityInputLabels(EditorSpokenNames.names(word: Self.findWord, label: "Find in this document"))
                .shortcutKeycap(AppChord.findInPane.display)
                .help(ShortcutHint.tooltip("Find and replace in this document", AppChord.findInPane.display))
            }
            // **Only for files that have something to preview.** `PairContentKind` already
            // owns which extensions are Markdown; a capsule on a `.txt` would offer two modes
            // that render the same thing.
            //
            // **But its HEIGHT is reserved either way**, which is the same bargain the rail
            // strikes for its unsaved dot. The capsule is the tallest thing in this row, so a
            // header without one was measurably shorter — a `.txt` and a `.md` side by side sat
            // at different heights, and the whole document column below them started at
            // different places. Reserved by hiding a real capsule rather than by naming a
            // number: the number would be the capsule's own metrics copied to a second place,
            // where it could go stale the next time that control's padding moved.
            //
            // `.frame(width: 0)` so only the height is reserved. Reserving the width too would
            // hold a capsule-shaped gap at the end of every plain-text header, and truncate the
            // file name earlier for nothing.
            if let rung = reading.capsule {
                EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent, forcedRung: rung)
            } else {
                EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent)
                    // A reservation, never seen: Solid, so it runs no lens of its own on a mode
                    // change and draws no glass track — its height is the same in every appearance.
                    .environment(\.selectionLensAppearance, .today)
                    .hidden()
                    .frame(width: 0)
            }
            // **Expand, between the capsule and the ×** (TE48) — the window-sized controls at the
            // end of the row. Out of the ＋ / Find capsule, where it was a ≡ that read as "justify";
            // those two act on the folder and the text, this on how much of the window the
            // document gets. One view, drawn by the empty page's header too.
            expandButton(worded: reading.chipsWorded)
            // **Close, at the far end** (TE46). The one way to put the document away — File ▸
            // Close Document is the other door, with no key, because ⌘W is Close Tab. Last,
            // after the capsule, because it acts on the whole document rather than on a view of
            // it. The host settles the buffer first, so Cancel leaves everything as it was. Not
            // withheld in Preview, nor on a read-only or refused file: each of those is still
            // a document somebody may want off the screen.
            // Beside Expand's own outset glass, the room that keeps the two 4pt apart.
            EditorCloseChip(name: document.name, worded: reading.chipsWorded, accent: accent,
                            action: onCloseDocument)
                .chromeGlassClearance(.leading, rowSpacing: 6)
        }
    }

    /// The words the header's buttons wear on their worded rung (TE144). New Text File is the
    /// menu item's name, File ▸ New Text File…, without its ellipsis: the button asks nothing first.
    static let newTextFileWord = "New Text File"
    static let findWord = "Find"

    /// **＋, ⌘N's button in the header** (TE45). With the source pane open, or under "Just the
    /// text", there is no rail and so no other ＋ on screen — ⌘N and File ▸ New Text File… were the
    /// only ways in, and neither is visible. It calls the host's ⌘N closure rather than setting
    /// `isNaming`, so the naming row opens AND takes focus exactly as the chord does. **Not withheld
    /// in Preview**, unlike Find: it is about the folder, not the text view. **Drawn with no
    /// document open too** — the empty page is where making a file is most likely to be the next
    /// thing — and by both headers from this one view.
    ///
    /// **Greyed with no ⌘N, as the menu item is — and greyed where it SHOWS.** `.disabled` stops
    /// the press, but a `.glyph` hover-affordance button draws the same at rest either way
    /// (measured with TE45: pixel-identical with and without the closure), so on its own it left a
    /// ＋ that looked pressable and did nothing. The glyph takes the tertiary style instead.
    ///
    /// **Worded on the widest rung, "＋ New Text File"** (TE144): the ＋ alone said "new" but not new
    /// WHAT, and only its tooltip answered. A glass capsule of its own, like Expand's.
    private func newTextFileButton(worded: Bool) -> some View {
        Button { onNewTextFile?() } label: {
            EditorHeaderChipLabel(symbol: "plus", word: worded ? Self.newTextFileWord : nil)
                .foregroundStyle(onNewTextFile == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)
        .accessibilityLabel("New text file")
        .shortcutKeycap(AppChord.newTextFile.display)
        .lockedDuringRun()
        .help(ShortcutHint.tooltip(Self.newTextFileTitle(folderName: newFileFolderLabel),
                                   AppChord.newTextFile.display))
        .disabled(onNewTextFile == nil)
    }

    /// **What the last segment says, and it is the whole visible account of autosave.**
    ///
    /// There is no "saving…" state on purpose. The write is a staged file and a rename on a local
    /// path — it finishes far inside a frame — so a spinner would be a flicker nobody can read, and
    /// the honest reading of "saved" here is "everything you have typed is on disk", which is true
    /// between keystrokes and false for at most the debounce.
    ///
    /// A stop is what actually needs saying, because it is the one state where typing is not
    /// reaching the file, and it replaces the segment rather than joining it: "saved · not saving"
    /// is a contradiction, and the stop is the half that matters.
    /// The one resolution of "where does this document stand", used by the dot and the words alike.
    private var status: EditorSaveStatus {
        EditorSaveStatus.resolve(isReadOnly: document.isReadOnly,
                                 isDirty: document.isDirty, stopped: stopped,
                                 autosaveOff: !autosavePolicy.isOn(document.path))
    }

    /// Which colour the dot wears, or `nil` for no dot at all.
    private var dotColour: Color? {
        guard status.showsDot else { return nil }
        return status.isWarning ? .orange : accent
    }

    /// What kind of file this is, and nothing else.
    ///
    /// **The size left, and so did the status word.** Size is a measurement, and every other
    /// measurement of this file — its counts, its encoding, its line endings — is in the status
    /// line under the document; keeping one of them up here meant the header grew as the file did.
    /// The word left because it now appears only in the states that need it, see
    /// ``EditorSaveStatus/word``.
    ///
    /// The kind stays because it is the one thing in this row that is not a number, and it is
    /// genuinely unobvious on a `.markdown`, a `.text`, or a file with no extension at all.
    private var kindName: String {
        document.isMarkdown ? "Markdown" : "Plain text"
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            // The reservation that gives this row the title's left edge. An unconditional clear
            // rectangle, because a conditional one takes no part in layout at all.
            Color.clear
                .frame(width: Self.dotColumnWidth, height: 1)
            Text(kindName)
                .layoutPriority(1)
                .lineLimit(1)
            if showsAutosaveSwitch {
                Text("·").foregroundStyle(.tertiary)
                autosaveSwitch
            }
            // **Paper, then where the file lives — one slot of this row, so a Paper that steps aside
            // leaves no gap.** A slot of its own held the row's 6pt on both sides even with
            // nothing in it, doubling the space before the location at exactly the width where
            // the row is short of it (measured with a probe: 112pt against 106).
            //
            // **Page comes after Autosave, so Autosave never moves**, and before the location for
            // the reason Autosave is: the crumb's width depends on the file. Offered on a
            // read-only file too — a page changes nothing on disk.
            //
            // **It yields before everything but the location**: the slot is `-1`, so it is offered
            // what the kind, Autosave and the status word leave; inside it Paper, at a fixed size,
            // is measured first and drawn whole or not at all — measured, at 260pt and 135% the
            // row wrapped "Autosave" onto a second line with it in. Text ▸ Paper Background is the way to it
            // then.
            HStack(spacing: 0) {
                if Self.showsPageSwitch(hasPath: document.path != nil, wasRefused: document.refusal != nil) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text("·").foregroundStyle(.tertiary)
                            pageSwitch
                        }
                        .padding(.trailing, 6)
                        .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                // **Where the file lives — after the switch, so the switch never moves.** The folder's
                // name is the one thing on the left of this row whose width depends on the file, and
                // before the switch it would slide the switch sideways from one folder to the next,
                // the same reason the status word is at the far end.
                //
                // **It takes the gap the `Spacer` held**, rather than sitting beside one: two views
                // flexible without limit split the leftover width between them, and the crumb would
                // have had half the room it could use.
                //
                // **And it yields first — `layoutPriority(-1)`.** At the same priority as its
                // neighbours it was offered a share of the row before they had theirs, and at 135% in
                // the narrowest column "Autosave" was handed less than its own width and wrapped onto
                // a second line, growing a header that is pinned to the pane's toolbar card. Below
                // them it is sized from what the kind, the switch and the status word leave — the
                // location folds and truncates (``EditorLocationLabel``) where those words cannot.
                if let location {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(.tertiary).fixedSize()
                        EditorLocationLabel(location: location, accent: accent, onDoor: onLocationDoor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .layoutPriority(-1)
                } else {
                    Spacer(minLength: 8)
                }
            }
            .layoutPriority(-1)
            // **The far end, so the left never moves.** The word is the only thing in this row
            // whose width changes — `unsaved — ⌘S`, `not saving`, a stop's own sentence — and on
            // the left it would shove the switch sideways every time the state changed. Here it
            // grows into the gap instead. The cost is distance from the switch it qualifies, which
            // is the trade this layout was picked for.
            if let word = status.word {
                statusWord(word)
            }
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    /// The status word — a control when there is something behind it, plain text when there is not.
    ///
    /// **Nothing at rest either way, which is what makes this honest.** A word drawn as a button at
    /// all times would promise a door that is there for one stop out of three; a word that gave no
    /// sign at all would hide the one door there is. The clickable case goes through the app's one
    /// hover-affordance choke point — nothing painted until the pointer is over it, then a wash, a
    /// ring, and the pointing cursor `Button` brings with it — which is exactly the shape this
    /// problem has been solved in twenty-six other places here.
    ///
    /// **`.segment`, tinted amber rather than accent.** The word it washes is amber, and the
    /// affordance previews the fill the control would take; the accent would put a second colour on
    /// the one line of the header that is a warning.
    ///
    /// The padding is the wash's room, and it is **horizontal only**. Bare glyphs inside a capsule
    /// leave the wash tight against the letters — and the word sits at the far end of the row behind
    /// a `Spacer`, so widening it grows into the gap rather than moving anything. Vertical padding
    /// is a different matter: it made this row 2pt taller, and the row is half of a header whose
    /// whole design is that it comes out the same height for every file (see
    /// `theHeaderIsTheSameHeightForEveryKindOfTextFile`). A header that grew when the stop happened
    /// to be the clickable one would start the document column at two different places.
    @ViewBuilder
    private func statusWord(_ word: String) -> some View {
        let text = Text(word)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        let action = Self.statusWordAction(status: status, offersDiff: onShowWhatChanged != nil,
                                           offersSave: onSaveNow != nil, offersSaveAgain: onSaveAgain != nil)
        if let action, let perform = statusWordPerform(action) {
            // **VoiceOver reads the visible words** (TE149): the button's label is the word itself,
            // and the tooltip says what pressing it does.
            Button(action: perform) {
                text.padding(.horizontal, 5)
            }
            .buttonStyle(.hoverAffordance(.segment, tint: status.isWarning ? .orange : accent))
            .help(Self.statusWordHelp(action, status: status, detail: stoppedDetail) ?? "")
            .shortcutKeycap(Self.statusWordKeycap(action, status: status))
        } else if let detail = Self.stopTooltip(status: status, detail: stoppedDetail) {
            text.help(detail)
        } else {
            text
        }
    }

    private func statusWordPerform(_ action: StatusWordAction) -> (() -> Void)? {
        switch action {
        case .showWhatChanged: return onShowWhatChanged
        case .saveNow: return onSaveNow
        case .saveAgain: return onSaveAgain
        }
    }

    /// What pressing the status word does (TE149).
    enum StatusWordAction: Equatable {
        /// "not saving — changed on disk": the comparison.
        case showWhatChanged
        /// "unsaved — ⌘S", and "not saving — couldn't write": ⌘S.
        case saveNow
        /// "not saving — no longer on disk": Save Again.
        case saveAgain
    }

    /// **Which words are a control, and which stay words.** The host hands over only the closures its
    /// stop has a use for, so a stop is never asked twice what it is: "couldn't check the save" gets
    /// none and stays plain — TE147 clears it — and so does "read only".
    static func statusWordAction(status: EditorSaveStatus, offersDiff: Bool, offersSave: Bool,
                                 offersSaveAgain: Bool) -> StatusWordAction? {
        switch status {
        case .heldUnsaved: return offersSave ? .saveNow : nil
        case .stopped:
            if offersDiff { return .showWhatChanged }
            if offersSaveAgain { return .saveAgain }
            return offersSave ? .saveNow : nil
        case .readOnly, .unsaved, .saved: return nil
        }
    }

    /// The word's tooltip once it is a control: what pressing it does — or, for a failed write, the
    /// reason, which the word alone doesn't give (TE114).
    static func statusWordHelp(_ action: StatusWordAction, status: EditorSaveStatus, detail: String?) -> String? {
        switch action {
        case .showWhatChanged: return "Show what changed on disk while you were typing"
        case .saveAgain: return EditorDiskBannerView.help(.saveAgain)
        case .saveNow:
            if status == .heldUnsaved { return "Save now — autosave is off for this file" }
            return stopTooltip(status: status, detail: detail)
        }
    }

    /// The ⌘S badge under ⌥, for "unsaved — ⌘S" alone — the stop's words don't name the chord.
    static func statusWordKeycap(_ action: StatusWordAction, status: EditorSaveStatus) -> String? {
        action == .saveNow && status == .heldUnsaved ? AppChord.saveDocument.display : nil
    }

    /// **The plain status word's tooltip: the stop's reason, and only on a stop** (TE114). "not
    /// saving — couldn't write" says that a write failed and not why; the why was in a banner that
    /// has faded by the time anybody looks. Read-only and "unsaved — ⌘S" carry none.
    static func stopTooltip(status: EditorSaveStatus, detail: String?) -> String? {
        guard case .stopped = status, let detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// The reserved width of the dot's column, shared by both rows of the header.
    ///
    /// Named once for the reason ``EditorFileRailView/dotColumnWidth`` is: two rows agreeing on a
    /// left edge by both writing `10` are two rows that will one day disagree.
    static let dotColumnWidth: CGFloat = 10

    // MARK: - The empty page's header

    /// **The header with no document open: the same card, saying so, and naming where a new file
    /// would go.** First entry into Edit, and every close, land here.
    ///
    /// **The same two rows at the same heights as a document's**, so the card is filled the same
    /// way and the text card below starts where it always does: the title row reserves the mode
    /// capsule's height with a hidden real one, exactly as a plain-text file's does, and the meta
    /// row reserves the autosave switch's (see ``emptyMetaRow``).
    ///
    /// **What it offers is what makes sense with nothing open.** New Text File —
    /// ``newTextFileButton(worded:)``, the same view the document's header draws, greyed with no
    /// folder — and no Find (nothing to search), no capsule (nothing to view three ways) and no
    /// Close (nothing to close).
    ///
    /// Expand is drawn only while it is LIT: with the rail and the pane both put away there is no
    /// list of files anywhere on screen, and the lit button is both the reason why and the way
    /// back — it reads "Files". Unlit it would only offer to hide a list somebody has not yet used,
    /// on a page whose whole job is to get them to one. Text ▸ Expand follows the same rule.
    ///
    /// Internal so the tests can render it on its own, like ``headerContent``.
    @ViewBuilder
    var emptyHeaderContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Worded, then bare — the document header's rule: "Files" keeps its word only while
            // the whole title fits beside it, so at the narrowest column the title is not cut for
            // a word the arrows already carry.
            ViewThatFits(in: .horizontal) {
                emptyNameRow(chipsWorded: true)
                emptyNameRow(chipsWorded: false)
            }
            emptyMetaRow
        }
    }

    /// One reading of the empty page's title row — see ``emptyHeaderContent``.
    private func emptyNameRow(chipsWorded: Bool) -> some View {
        HStack(spacing: 6) {
            // The dot's column, reserved as a shape so the title starts where a file name does.
            Color.clear
                .frame(width: Self.dotColumnWidth, height: 1)
            Text(Self.emptyTitle)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Its own glass capsule in Frosted and Clear, as in the document's header.
            newTextFileButton(worded: chipsWorded)
            // At the end of the row, where a document's header draws it — beside New Text File's
            // outset glass, with the room that keeps the two capsules apart.
            if railIsHidden {
                expandButton(worded: chipsWorded)
                    .chromeGlassClearance(.leading, rowSpacing: 6)
            }
            // The capsule's height, reserved the way a plain-text header reserves it — and,
            // like that one, drawn at Solid, so it runs no lens of its own.
            EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent)
                .environment(\.selectionLensAppearance, .today)
                .hidden()
                .frame(width: 0)
        }
    }

    /// The empty page's button while the list is folded (TE77).
    static let showTextFilesTitle = "Show File List"
    /// Its tooltip — one sentence for the empty page and the Recent page, which both draw the button.
    static let showTextFilesHelp = "Show the folder’s text files and PDFs in a list"

    /// What the empty page's header says in place of a file name.
    static let emptyTitle = "No document open"

    /// **Where a new file would go, and nothing else.** No kind, no switch and no status word — each
    /// of those is about a file, and there is none. The location is the pane's folder, which is
    /// where ⌘N and the ＋ create; it is drawn by the same label as a document's, so it reads and
    /// clicks the same way, but with no "·" before it because nothing precedes it. With no folder
    /// the row is empty, and keeps its height.
    ///
    /// **Its height is the document meta row's, by reservation**: a hidden copy of the autosave
    /// switch's label and track at zero width, the capsule trick again. They are the tallest things
    /// that row holds, and measured without them the row was 1–2pt short at every text size with
    /// no folder to name — enough to move the title between the empty page and an open file.
    private var emptyMetaRow: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: Self.dotColumnWidth, height: 1)
            if let location {
                EditorLocationLabel(location: location, accent: accent, onDoor: onLocationDoor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .layoutPriority(-1)
            } else {
                Spacer(minLength: 8)
            }
            // The switch's label and track, as the document row draws them. Not the switch
            // itself: that is a `Button`, and a hidden one would still be a control.
            HStack(spacing: 5) {
                Text("Autosave")
                    .scaledFont(.system(size: 10, weight: .medium))
                AutosaveSwitchTrack(isOn: false, fill: accentFill)
            }
            .fixedSize()
            .hidden()
            .frame(width: 0)
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    /// **Expand (TE48), once "Just the text".** Hides the file rail — and, through the host,
    /// collapses the source pane if it was open, which takes the sidebar with it — leaving the
    /// document alone in the window. Lit while the rail bit is set, and its word names its NEXT act
    /// rather than its state: "Expand", then "Files". **Not withheld in Preview**, unlike Find: it is
    /// about the columns, not the text view. ⌃⌘E, Text ▸ Expand, shown on its keycap and in its
    /// tooltip from the one `AppChord`. One view, drawn by both headers.
    ///
    /// **A glass capsule of its own in Frosted and Clear, like every header button** — it left the
    /// New Text File / Find capsule because it is not about the folder or the text, and since TE144
    /// those two have a capsule each as well. The same 18pt row height either way,
    /// so the header's two rows, and with them the pinned header height, do not move; the word
    /// only ever widens it.
    func expandButton(worded: Bool) -> some View {
        Button(action: onToggleJustTheText) {
            Group {
                if worded {
                    HStack(spacing: 4) {
                        Image(systemName: Self.expandSymbol(railIsHidden: railIsHidden))
                            .scaledFont(.system(size: 10, weight: .semibold))
                        // **Laid out at the wider word**, so lighting it moves nothing: "Files"
                        // sits in the room "Expand" takes, and the capsule and the buttons to its
                        // left stay where the pointer left them.
                        ZStack(alignment: .leading) {
                            ForEach([false, true], id: \.self) { hidden in
                                Text(Self.expandTitle(railIsHidden: hidden)).hidden()
                            }
                            Text(Self.expandTitle(railIsHidden: railIsHidden))
                        }
                        .scaledFont(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    // Never squeezed — the name gives way (``EditorHeaderChipLabel``).
                    .fixedSize()
                } else {
                    Image(systemName: Self.expandSymbol(railIsHidden: railIsHidden))
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            .foregroundStyle(railIsHidden ? accent : .primary)
            // The soft accent wash is the lit state; the hover style paints its own wash over it,
            // which reads as the pressed preview it is.
            .background(Capsule().fill(railIsHidden ? accent.opacity(0.18) : .clear))
            .contentShape(Capsule())
        }
        .chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)
        .accessibilityLabel(Self.expandTitle(railIsHidden: railIsHidden))
        .shortcutKeycap(AppChord.editorExpand.display)
        .help(ShortcutHint.tooltip(Self.expandHelp(railIsHidden: railIsHidden),
                                   AppChord.editorExpand.display))
    }

    private var showsAutosaveSwitch: Bool {
        Self.showsAutosaveSwitch(hasPath: document.path != nil,
                                 wasRefused: document.refusal != nil,
                                 isReadOnly: document.isReadOnly)
    }

    /// **Withheld wherever autosave was never going to write anyway** — nothing open, a refusal, or
    /// a read-only decode. A switch that changes nothing is worse than no switch.
    ///
    /// A function over three booleans rather than a computed property, for the reason
    /// ``EditorFileRailView/dotColour(rowPath:selectedPath:status:accent:)`` is one: the rule is
    /// worth asserting, and asserting it through the header means building a whole workspace.
    ///
    /// Public since Text ▸ Autosave This File joined the menu bar: the menu item and this switch
    /// are two doors onto one setting, and they have to be withheld by the same rule.
    public static func showsAutosaveSwitch(hasPath: Bool, wasRefused: Bool, isReadOnly: Bool) -> Bool {
        hasPath && !wasRefused && !isReadOnly
    }

    /// **Wherever there is text to put on a page** — a file read in, whether or not it can be
    /// written. Not on a refusal, which shows a caption and no text view.
    public static func showsPageSwitch(hasPath: Bool, wasRefused: Bool) -> Bool {
        hasPath && !wasRefused
    }

    /// **Greyed in Preview**, where there is no Source on screen for the page to go under — rather
    /// than withheld, so the location beside it does not jump with every mode change.
    public static func pageSwitchApplies(_ resolvedMode: EditorMode) -> Bool { resolvedMode != .preview }

    /// The page switch: Autosave's own shape and track, on ``EditorTextSettings/drawsPageKey``.
    @ViewBuilder
    private var pageSwitch: some View {
        let applies = Self.pageSwitchApplies(resolvedMode)
        Button {
            drawsPage.toggle()
            Logger.shared.info("[edit] Paper \(drawsPage ? "on" : "off") from the header")
        } label: {
            HStack(spacing: 5) {
                Text("Paper")
                    .scaledFont(.system(size: 10, weight: .medium))
                    .foregroundStyle(drawsPage ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                AutosaveSwitchTrack(isOn: drawsPage, fill: accentFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!applies)
        .opacity(applies ? 1 : 0.45)
        // Autosave's pattern: the state, then what a click does.
        .help(!applies ? "Paper is for Source — switch to Source or Split to see it"
              : drawsPage ? "Paper is on — click to draw the text straight on the window"
                          : "Paper is off — click to put the text on paper, white in Light Mode and dark in Dark Mode")
        .accessibilityLabel("Paper background")
        .accessibilityValue(drawsPage ? "On" : "Off")
        .accessibilityAddTraits(drawsPage ? [.isButton, .isSelected] : .isButton)
    }

    /// The autosave switch, beside the word whose meaning it changes.
    ///
    /// **A switch, drawn as one** — a track with a knob that slides, the shape everybody already
    /// reads as "this is on, and I can turn it off". It began as a filled-or-hollow dot beside the
    /// word, which is the shape of a radio button: something that reports a state rather than one
    /// that offers to change it.
    ///
    /// **Hand-drawn rather than SwiftUI's `Toggle`**, for the reason ``EditorModeBar`` is: a native
    /// control renders neutral inside this window's glass and ignores `.tint`, so its "on" state
    /// could never carry the app's accent — and on-ness is the one thing this has to say at a
    /// glance. It is also 11pt tall beside 10pt text, far below what AppKit's switch will draw at.
    ///
    /// **`.plain`, and it is the one control in this header without a hover affordance.** A wash
    /// behind a switch fights the switch: the thing saying "you can press me" is the knob, and two
    /// affordances stacked on one control read as a rendering fault rather than as emphasis.
    @ViewBuilder
    private var autosaveSwitch: some View {
        let isOn = autosavePolicy.isOn(document.path)
        Button {
            guard let path = document.path else { return }
            // **Switching it back ON writes what is already waiting.** The debounce is a
            // `.task(id:)` keyed on the buffer's version, so it does not re-fire when a setting
            // changes: without this, turning autosave on left the file unwritten until the next
            // keystroke — the one moment somebody is most entitled to expect it to be saved.
            if autosavePolicy.toggle(path) { onAutosaveResumed() }
        } label: {
            HStack(spacing: 5) {
                // The label leads, which is where macOS puts it.
                Text("Autosave")
                    .scaledFont(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                AutosaveSwitchTrack(isOn: isOn, fill: accentFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Autosave is on for this file — click to stop writing it until you save"
                   : "Autosave is off for this file — click to write it again as you type")
        .accessibilityLabel("Autosave this file")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// The document column, with the parse attached where it cannot be torn down.
    ///
    /// **The `.onChange` and the `.task` hang HERE, outside the branch that draws a document.**
    /// They used to be modifiers on the `VStack` in the `else` arm, which is to say they did not
    /// exist while a file was refused or while nothing was open — and `.onChange` without
    /// `initial:` does not fire when its branch is reconstructed. Opening a cloud-only file
    /// (refused, `else` arm destroyed) and then a second Markdown file rebuilt the arm with the
    /// FIRST document's blocks still in `@State`, so the preview rendered one file's headings under
    /// another file's name until the 150ms debounce and the parse had both finished. That is the
    /// exact failure the synchronous clear was added to prevent, reached through the one path where
    /// the clear was not mounted.
    private func body(for document: EditorDocument) -> some View {
        documentBody(for: document)
            // **⌘Z reaches the document whenever nothing else has the keyboard** (UND-1, UND-2):
            // after a mode switch, in read-only Preview, over a refusal. Only while a document is
            // open — Edit with nothing open, and every other workspace, are left as they were.
            .background {
                if document.path != nil {
                    EditorUndoAnchor(undoManager: undoManager, handle: textViewHandle)
                        .frame(width: 0, height: 0)
                }
            }
            // **Cleared synchronously when the FILE changes, before the debounce.** The parse is
            // deliberately late — 150ms plus however long it takes — and `blocks` is only
            // reassigned at the end of it, so without this a second file's name sits above the
            // first file's headings for at least that long.
            .onChange(of: document.path, initial: true) { _, _ in
                blocks = []
                // **With the blocks, not after them.** The outline is drawn in the RAIL, beside the
                // name of the file being opened, so an outline left standing for the couple of
                // hundred milliseconds before the parse returns lists one file's headings under
                // another file's name — in the one place both are on screen at once.
                outline = []
                editorScrollRequest = nil
                previewScrollRequest = nil
                // **The status line is seeded from the same anchor the text view is.**
                //
                // `caretOffset` is what Ln/Col is derived from, and it is `@State` — so a workspace
                // switch resets it to 0 while `makeNSView` puts the caret wherever the anchor says.
                // Nothing reports that placement any more (the delegate is deliberately wired after
                // it, so construction cannot write SwiftUI state), which left the readout claiming
                // line 1 while the caret sat somewhere else entirely.
                //
                // Clamped HERE and not in the argument above: this runs on arrival and on a file
                // change, where reading the buffer's length is affordable, and that argument is
                // rebuilt on every keystroke, where it is not.
                caretOffset = EditorCaretAnchors.clamped(
                    document.caretAnchors.offset(for: document.path) ?? 0, in: document.text)
                // **The counts and Line/Col go with the file they were taken for** (ED2, EP4). A
                // move keeps them: the same text under a new path (EP5). Otherwise they are the
                // last file's, and the line holds their room undrawn until this file's land —
                // never derived here, where Line/Col alone walks up to the whole new text.
                if EditorStatusLine.keepsCounts(countedAt: factsVersion, textVersion: document.textVersion) {
                    factsPath = document.path
                    if caretPath != nil { caretPath = document.path }
                } else {
                    factsPath = nil
                    caretPath = nil
                }
                // A new file arrives with a caret and no selection, and its own formatting: the
                // last file's lit buttons must not stand over it for the debounce.
                liveSelection.set(length: 0)
                liveSelection.set(rangeCount: 1)
                selectionFacts = nil
                formatState = .none
                previewPending = []
                // …nor the last file's refusal hint, whose link would act on this one.
                statusHint = nil
                goToLineShown = false
                // …and the caret starts in Source's half of a Split, where Source opens it.
                textViewHandle.caretInSplitPreview = false
                // **Last, after every request above was cleared**: a Contents result's match, for
                // the file it was clicked in (RD38).
                if let match = pendingContentMatch {
                    pendingContentMatch = nil
                    if match.path == document.path { selectContentMatch(match) }
                }
            }
            // **The stored length follows the text view it describes.** A mode switch builds a new
            // text view whose selection is a bare caret (`PlainTextEditor.restoreCaret`), and the
            // bar coming on finds a length nobody kept while it was off. Left stale, the next
            // selection of that same length would leave the key unchanged and the bar unlit.
            .onChange(of: resolvedMode) { _, drawn in
                // Out of Split, its Preview half is gone. (Into it, the new half has registered.)
                if drawn != .split { textViewHandle.leaveSplit() }
                // A new Preview starts with nothing pending; Source has no pending styles at all.
                previewPending = []
                liveSelection.set(length: 0)
                liveSelection.set(rangeCount: 1)
                selectionFacts = nil
                // A hint is about the Preview it was raised in.
                statusHint = nil
                goToLineShown = false
            }
            // Text ▸ Go to Line… — the menu's press opens the status line's field (TE61). Any hint
            // standing in the line's place goes first: the field hangs off the caret it covers. A
            // notice from elsewhere gives way by itself while the field is up (TE59).
            .onChange(of: goToLineRequest) { _, _ in
                guard offersGoToLine else { return }
                statusHint = nil
                goToLineShown = true
            }
            // **A preview a mode switch builds opens where the caret is** — not on the last heading
            // chosen, whose request was still standing and was replayed to every preview a switch
            // built, over wherever the reader had gone since (TE57 review). On `mode`, the reader's
            // own choice, and not `resolvedMode`: opening a Markdown file after a plain one moves
            // that too, while `caret` still holds the old file's line.
            //
            // **Not to the editable Preview**, which opens at the caret already (its
            // `initialSourceOffset`): the request would arrive after it was built and send the caret
            // to the START of the caret's block, reporting that as the caret (review V3, 2026-10-09).
            .onChange(of: mode) { _, _ in
                guard !(resolvedMode == .preview && editsInPreview) else { return }
                scrollToken &+= 1
                previewScrollRequest = EditorScrollRequest(line: caret.line, token: scrollToken)
            }
            // **The 256 KB decision, taken at the moments its key names and held between them** —
            // see ``PreviewLengthHold``. Initial, so a note is decided as it arrives.
            .onChange(of: previewLengthKey, initial: true) { _, key in
                let length = buffer.source.textStorage.length
                let hold = PreviewLengthHold(key: key, isTooLong: PreviewEditToggle.isTooLong(length: length))
                previewLengthHold = hold
                onPreviewLengthHold?(hold)
                if hold.isTooLong, offersPreviewEditing, key.editing {
                    Logger.shared.info(PreviewEditToggle.tooLongLog(length: length))
                }
            }
            // **The intro, the first time Preview becomes editable** — by the pill, by Text ▸ Edit in
            // Preview, or by switching to Preview with the setting already on (review V2: from the
            // menu it never showed). Seen once shown, whether or not "Got it" is what closes it.
            .onChange(of: editsInPreview) { _, editable in
                // **A follow is about the Preview that led it.** Left standing, it was handed to a
                // Source built since, the next time Preview was editable, and Source jumped to a
                // line scrolled to long before (review V13, 2026-10-09).
                if !editable { editorFollowRequest = nil }
                if PreviewEditToggle.showsIntro(turningOn: editable, introSeen: editsInPreviewIntroSeen) {
                    showsPreviewEditIntro = true
                    editsInPreviewIntroSeen = true
                }
            }
            // **The re-render is debounced, and the parse is off the main actor.** Keyed on the
            // document's version counter rather than on its text: `.task(id:)` compares its id
            // every render pass, and comparing a 4 MiB buffer per keystroke to decide whether to
            // re-parse would cost more than the parse itself. The sleep is the debounce — a new
            // keystroke cancels this task before it wakes, so a burst of typing parses once at the
            // end of it.
            .task(id: EditorParseKey(version: document.textVersion, path: document.path)) {
                guard document.isMarkdown else {
                    // **Only when there is something to clear.** This task restarts on every
                    // keystroke, and on a plain-text file it reached an unconditional write of an
                    // empty array into `@State` — which SwiftUI treats as a change and answers with
                    // a body pass, per keystroke, for a value that was already empty.
                    if !blocks.isEmpty { blocks = [] }
                    return
                }
                // Cancelled by the next keystroke, which is the whole mechanism. **Not for a file just
                // opened** (its blocks were cleared): nobody is typing, and the status line's
                // heading would arrive 150ms late and push the counts sideways as it did.
                if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let source = document.text
                let path = document.path
                parseTickets.started &+= 1
                let ticket = parseTickets.started
                let parsed = await Task.detached(priority: .userInitiated) {
                    MarkdownBlocks.blocks(from: source)
                }.value
                // **Landed even when a keystroke cancelled this task while it parsed** (CHR-4). It
                // was thrown away, so in a long note — over a second's parse at 256 KB in a debug
                // build — steady typing kept the outline, the rail and the status line's "in …" on
                // the text as it was before the first keystroke. A finished parse is newer than
                // what is on screen, so it lands, unless a later one already has or the file
                // changed under it; the next parse follows with the text as it is now.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: parseTickets.shown) else { return }
                parseTickets.shown = ticket
                blocks = parsed
                // Derived here rather than in a body pass: it is a walk of every block, and a body
                // pass happens on every keystroke.
                outline = MarkdownOutline.entries(from: parsed)
            }
            // **The status line's own task, on the same debounce and for the same reason.** Word
            // and character counts walk the whole buffer, so doing it in a body pass would cost a
            // full scan per keystroke to answer a question nobody reads that fast. Keyed on the
            // version counter rather than the text, exactly as the parse above is — and NOT on the
            // caret, which changes far more often and would re-count the words on every arrow key.
            .task(id: EditorParseKey(version: document.textVersion, path: document.path)) {
                // **Not for a file's first count**, whose counts are not on screen at all (ED2):
                // nobody is typing, and the debounce would only hold them back. Only the first —
                // see ``EditorFirstCountGate`` (EP6).
                guard await factsGate.settle(open: document.path, countedFor: factsPath,
                                             debounce: .milliseconds(150)) else { return }
                let source = document.text
                let path = document.path
                let version = document.textVersion
                let encoding = document.encodingName
                countTickets.started &+= 1
                let ticket = countTickets.started
                // **The line table is built in the same detached pass**, because it is the same
                // walk of the same buffer and the alternative is doing it on the main actor once
                // per scroll tick. See ``EditorLineIndex`` for what accepts a stale one.
                let derived = await Task.detached(priority: .utility) {
                    (facts: EditorDocumentFacts.of(source, encoding: encoding),
                     lines: EditorLineIndex(text: source))
                }.value
                // **Landed even when a keystroke cancelled this task while it counted** (F-E6), by the
                // parse's rule: a large file just opened takes its first count undebounced, and typing
                // on through it threw that count away and every one after, so the line showed no counts
                // until the typing stopped. A finished count of this file is a keystroke old at worst.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: countTickets.shown) else { return }
                countTickets.shown = ticket
                facts = derived.facts
                lineIndex = derived.lines
                factsVersion = version
                factsPath = path
            }
            // The caret is its own key, because it moves without the text changing — and the text
            // changing moves it too, which is why the version is in here as well as the offset.
            .task(id: EditorCaretKey(version: document.textVersion, path: document.path,
                                     offset: caretOffset)) {
                // A file's first caret starts at once, as its first count does (EP4, EP6) — asked
                // only by a task still running, since the arrival's own caret write restarts this one.
                guard await caretGate.settle(open: document.path, countedFor: caretPath,
                                             debounce: .milliseconds(120)) else { return }
                let source = document.text
                let path = document.path
                let offset = caretOffset
                caretTickets.started &+= 1
                let ticket = caretTickets.started
                let position = await Task.detached(priority: .userInitiated) {
                    EditorCaret.at(utf16Offset: offset, in: source)
                }.value
                // Landed by the same rule, for the same reason (F-E6): a keystroke old at worst.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: caretTickets.shown) else { return }
                caretTickets.shown = ticket
                caret = position
                caretPath = path
            }
            // The selection's counts and the format bar's lit state — derived beside this view
            // rather than in it, so a drag's ticks re-render only what derives them.
            .background {
                EditorSelectionDerivations(document: document, live: liveSelection,
                                           version: document.textVersion, path: document.path,
                                           caretOffset: caretOffset, facts: facts, factsVersion: factsVersion,
                                           mode: resolvedMode, showsFormatBar: showsFormatBar,
                                           selectionFacts: $selectionFacts, formatState: $formatState)
            }
    }

    /// This view with every setting it reads and writes taken from `store` — for tests only; the app
    /// never calls it.
    ///
    /// **Not `.defaultAppStorage`, because a test reads ``headerContent`` off a view in no
    /// hierarchy**, where `@AppStorage` has no environment and falls back to the standard domain.
    /// Under `swift test` that domain is `swiftpm-testing-helper`'s, shared by every test process
    /// on the machine. A store given here is read whether the view is mounted or not.
    func readingSettings(from store: UserDefaults) -> Self {
        var view = self
        view._glassLevelRaw = AppStorage(wrappedValue: GlassLevel.frosted.rawValue, LiquidGlass.levelKey, store: store)
        view._glassHueRaw = AppStorage(wrappedValue: LiquidGlassHue.blue.rawValue, LiquidGlass.hueKey, store: store)
        view._surfaceStyleRaw = AppStorage(wrappedValue: SurfaceStyle.unified.rawValue, LiquidGlass.surfaceStyleKey,
                                           store: store)
        view._surfaceTint = AppStorage(wrappedValue: 0, LiquidGlass.tintKey, store: store)
        view._showsFormatBarPreference = AppStorage(wrappedValue: EditorTextSettings.showsFormatBarDefault,
                                                    EditorTextSettings.showsFormatBarKey, store: store)
        view._formatBarShowsLabels = AppStorage(wrappedValue: EditorTextSettings.formatBarShowsLabelsDefault,
                                                EditorTextSettings.formatBarShowsLabelsKey, store: store)
        view._editsInPreviewPreference = AppStorage(wrappedValue: EditorTextSettings.editsInPreviewDefault,
                                                    EditorTextSettings.editsInPreviewKey, store: store)
        view._editsInPreviewIntroSeen = AppStorage(wrappedValue: false, EditorTextSettings.editsInPreviewIntroSeenKey,
                                                   store: store)
        return view
    }

    /// Whether the format bar is drawn over this document — see ``EditorFormatBar/isShown``.
    private var showsFormatBar: Bool {
        EditorFormatBar.isShown(preference: showsFormatBarPreference,
                                hasDocument: document.path != nil,
                                isRefused: document.refusal != nil,
                                isMarkdown: document.isMarkdown,
                                isReadOnly: document.isReadOnly,
                                mode: mode,
                                previewEditing: editsInPreview)
    }

    /// Whether Preview is the editable one, for this document now — see ``editsInPreview(preference:hasDocument:isRefused:isMarkdown:isReadOnly:mode:isTooLong:)``.
    private var editsInPreview: Bool {
        Self.editsInPreview(preference: editsInPreviewPreference, hasDocument: document.path != nil,
                            isRefused: document.refusal != nil, isMarkdown: document.isMarkdown,
                            isReadOnly: document.isReadOnly, mode: resolvedMode,
                            isTooLong: previewIsTooLong)
    }

    /// What the 256 KB decision is held for — see ``PreviewLengthHold``.
    private var previewLengthKey: PreviewLengthHold.Key {
        PreviewLengthHold.Key(path: document.path, mode: resolvedMode, editing: editsInPreviewPreference)
    }

    /// Too long to edit in Preview — held since Preview was opened for this note (V4).
    private var previewIsTooLong: Bool {
        PreviewLengthHold.isTooLong(previewLengthHold, key: previewLengthKey) { buffer.source.textStorage.length }
    }

    /// What re-derives the caret: a new position, OR the text moving under a position that did not.
    private struct EditorCaretKey: Equatable {
        var version: Int
        var path: String?
        var offset: Int
    }

    /// Whether a refusal is the one for a file still in the cloud — the one a Download answers
    /// (TE96). `BoundedTextRead`'s own sentence, read from there so a rewording cannot split them.
    static func isNotDownloaded(_ refusal: String?) -> Bool {
        refusal != nil && refusal == BoundedTextRead.Outcome.cloudOnly.caption
    }

    @ViewBuilder
    private func documentBody(for document: EditorDocument) -> some View {
        if let refused = document.refusal {
            // The file was chosen and could not be opened — `BoundedTextRead`'s own prose, which is
            // already written for a reader. Under it, what can still be done with the file (TE152):
            // a file still in the cloud gets the Download its row in Browse has (TE96), and the host
            // opens it when it arrives; one that kept changing gets Try Again; every one gets Quick
            // Look and Reveal in Finder, which were only on right-click menus.
            if let path = document.path {
                caption(refused, refusalButtons: Self.refusalButtons(for: refused, canTryAgain: onTryAgain != nil),
                        path: path)
            } else {
                caption(refused)
            }
        } else if document.path == nil {
            Group {
                if let recentFiles, let onOpenRecent {
                    // The files Edit opened last, and New Text File (TE58) — or, with none remembered,
                    // the one sentence below.
                    EditorRecentFilesPage(recents: recentFiles, open: onOpenRecent, newNote: onNewTextFile,
                                          newNoteFolder: newFileFolderLabel,
                                          showTextFiles: folder.isEmpty ? nil : onShowTextFiles,
                                          accent: accent) {
                        emptyPageCaption
                    }
                } else {
                    emptyPageCaption
                }
            }
            // **The whole page takes a drop from Finder** (TE198), not just the list or the
            // sentence: it filled the column and did nothing with one.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                Self.takesDrop(urls, onDropFiles: onDropFiles)
            }
        } else {
            VStack(spacing: 0) {
                if let reason = document.readOnlyReason {
                    readOnlyBanner(reason)
                }
                surfaces(for: EditorMode.resolved(mode, isMarkdown: document.isMarkdown))
            }
            // **Over the text's foot, not above it** (TE210): see ``EditorDiskBannerView``. Sticky
            // until answered, as it was; the text views take ``diskBannerInset`` at their bottom.
            .overlay(alignment: .bottom) {
                if let diskBanner {
                    EditorDiskBannerView(banner: diskBanner, name: document.name,
                                         canSaveAgain: !document.isReadOnly, onAction: onDiskBanner)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { diskBannerHeight = $0 }
                        .padding(Self.diskBannerMargin)
                }
            }
        }
    }

    /// The disk banner's margin from the text card's edges and the status line under it.
    static let diskBannerMargin: CGFloat = 8

    /// **How far the text views scroll past their last line while the disk banner stands** — its
    /// height and both margins, so the last line can rise clear of it. None without a banner.
    static func diskBannerInset(bannerHeight: CGFloat, isShown: Bool) -> CGFloat {
        isShown ? bannerHeight + 2 * diskBannerMargin : 0
    }

    private var diskBannerInset: CGFloat {
        Self.diskBannerInset(bannerHeight: diskBannerHeight, isShown: diskBanner != nil && document.refusal == nil)
    }

    /// Hands a drop on the empty page to the host — **files only**: a web address dragged from a
    /// browser is a URL too, and is no file to open. False, so the drop is refused, when nothing in
    /// it is a file or nothing takes it.
    static func takesDrop(_ urls: [URL], onDropFiles: (([URL]) -> Void)?) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard let onDropFiles, !files.isEmpty else { return false }
        onDropFiles(files)
        return true
    }

    /// The empty page's one sentence, and Show File List under it while the list is folded.
    private var emptyPageCaption: some View {
        caption(Self.emptyCaption(hasFolder: !folder.isEmpty, showsRail: showsRail),
                showTextFiles: folder.isEmpty ? nil : onShowTextFiles)
    }

    /// What re-parses the preview, as one value: a new version OR a different file.
    ///
    /// The path is in here because opening a second document can leave the counter unchanged —
    /// `open` writes `text`, which bumps it, but a file whose contents are identical to the last
    /// one's would still be a different document with the same rendered result. Cheap insurance,
    /// and it keeps the key's meaning "the thing being previewed", not "the buffer".
    private struct EditorParseKey: Equatable {
        var version: Int
        var path: String?
    }

    /// The writable surface, the rendered one, or both.
    @ViewBuilder
    private func surfaces(for resolved: EditorMode) -> some View {
        switch resolved {
        case .edit:
            sourceColumn
        case .preview:
            previewColumn(inSplit: false)
        case .split:
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = EditorLayoutMetrics.splitFraction(splitDrag ?? splitFraction,
                                                                 in: width)
                let editorWidth = width * fraction
                HStack(spacing: 0) {
                    sourceColumn.frame(width: editorWidth)
                    Divider()
                    // `max(0, …)` because the first layout pass can report a zero width, and
                    // `0 - 0 - 1` is the negative dimension SwiftUI logs and refuses to lay out.
                    previewColumn(inSplit: true)
                        .frame(width: max(0, width - editorWidth - 1))
                }
                // Compare's divider ergonomics: a 1pt rule with an invisible 12pt grab strip
                // straddling it, so the target is reachable without a visible handle.
                .overlay(alignment: .leading) {
                    splitHandle(width: width)
                        .offset(x: editorWidth - 6)
                }
                .coordinateSpace(.named(Self.splitSpace))
            }
        }
    }

    /// **Preview: the editable one when Edit in Preview is on, the read-only one otherwise** (TE67),
    /// with the pill that switches them in its top-trailing corner wherever it is offered.
    @ViewBuilder
    private func previewColumn(inSplit: Bool) -> some View {
        VStack(spacing: 0) {
            // **The pill's row: the bar's, when one is drawn over this Preview, or the pill's own** —
            // never over the text, whose first line it covered in Split and with the bar off
            // (review). Over Preview the pill ends the bar's row rather than lying over its last
            // buttons (reported 2026-10-05: it covered Link, Table and Divider); the bar sheds words
            // into the width that leaves it, as it does for any narrow column. In Split the bar
            // stays over Source's half, and acts on Source.
            //
            // **One row and one pill in both layouts** (review V2, 2026-10-09): the bar coming and
            // going is the `if` beside the pill, so turning editing on moves nothing but the bar.
            // It was two rows with a pill each, and each pill kept the intro's state — the one
            // clicked raised it as it went away, and the new one never had it.
            if offersPreviewEditing {
                HStack(alignment: .top, spacing: 0) {
                    if editsInPreview && showsFormatBar && !inSplit {
                        formatBar
                    } else {
                        Spacer(minLength: 0)
                    }
                    previewEditToggle
                        .fixedSize()
                        .padding(.top, Self.formatBarInset)
                        .padding(.trailing, 12)
                }
            }
            Group {
                if editsInPreview {
                    PreviewEditorView(source: buffer.source, undoManager: undoManager, fontScale: fontScale,
                                      onRefusal: { reason, offset in raiseHint(reason, at: offset) },
                                      // **In Split too** (review V7, V8, 2026-10-09): the status
                                      // line, the bar's lit state and what the bar presses follow
                                      // the half the caret is in, and the caret typed at in
                                      // Preview's half is the one Preview reopens at. Preview
                                      // reports only while it has the caret.
                                      onSourceSelection: { selection in
                                          if inSplit { textViewHandle.caretInSplitPreview = true }
                                          caretOffset = selection.location
                                          liveSelection.set(length: selection.length)
                                          document.caretAnchors.remember(selection.location, for: document.path)
                                      },
                                      onPendingStyles: { previewPending = $0 },
                                      onFollowAnchor: followAnchor,
                                      textViewHandle: textViewHandle,
                                      isSplitHalf: inSplit,
                                      documentFolder: documentFolder,
                                      followRequest: inSplit ? previewScrollRequest : nil,
                                      onVisibleLineChange: inSplit ? { line in followThePreview(line) } : nil,
                                      scrollRequest: inSplit ? nil : previewScrollRequest,
                                      initialSourceOffset: document.caretAnchors.offset(for: document.path),
                                      findRequest: inSplit ? splitPreviewFindRequest : findRequest,
                                      linkColor: accent,
                                      bottomInset: diskBannerInset)
                        // A new document is a new storage, and a new session to project it.
                        .id(ObjectIdentifier(buffer.source))
                } else {
                    MarkdownPreview(blocks: blocks, accent: accent, scrollRequest: previewScrollRequest,
                                    onToggleTask: taskToggle, documentFolder: documentFolder,
                                    onFollowAnchor: followAnchor)
                        .contentMargins(.bottom, diskBannerInset, for: .scrollContent)
                }
            }
        }
    }

    private var offersPreviewEditing: Bool {
        PreviewEditToggle.isOffered(hasDocument: document.path != nil, isRefused: document.refusal != nil,
                                    isMarkdown: document.isMarkdown, isReadOnly: document.isReadOnly,
                                    mode: resolvedMode)
    }

    private var previewEditToggle: some View {
        PreviewEditToggle(isOn: $editsInPreviewPreference, showsIntro: $showsPreviewEditIntro,
                          accent: accent, scale: fontScale,
                          isTooLong: previewIsTooLong)
    }

    /// **Whether Preview is the editable one** — the setting, and a document the pill is offered
    /// for: a writable Markdown file in Preview, and nothing else. Markdown only (the user's
    /// decision, 2026-10-05): a `.txt` has no Preview to type into, and an `.rtf` is not Markdown.
    /// And not over ``PreviewEditToggle/maximumLength`` — `isTooLong` as ``PreviewLengthHold`` holds it.
    public static func editsInPreview(preference: Bool, hasDocument: Bool, isRefused: Bool, isMarkdown: Bool,
                                      isReadOnly: Bool, mode: EditorMode, isTooLong: Bool) -> Bool {
        preference && PreviewEditToggle.isOffered(hasDocument: hasDocument, isRefused: isRefused,
                                                  isMarkdown: isMarkdown, isReadOnly: isReadOnly, mode: mode)
            && !isTooLong
    }

    /// Says "That change needs Source." for ``EditorStatusHint/duration`` — restarted by each refusal.
    private func raiseHint(_ reason: PreviewRefusal, at sourceOffset: Int) {
        hintsRaised &+= 1
        let token = hintsRaised
        let hint = EditorStatusHint(token: token, onShowInSource: {
            statusHint = nil
            // The caret where the refused edit was: Source opens at the remembered anchor.
            caretOffset = sourceOffset
            document.caretAnchors.remember(sourceOffset, for: document.path)
            mode = .edit
        }, reason: reason)
        statusHint = hint
        // Heard as well as seen: the keystroke went nowhere, and VoiceOver should say why.
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: hint.sentence(.sentence) ?? EditorStatusHint.needsSource,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(EditorStatusHint.duration))
            if statusHint?.token == token { statusHint = nil }
        }
    }

    /// Who is told where the text has scrolled to — nobody, outside `.split`.
    ///
    /// **The gate, and it is here rather than inside `followTheText`.** Nothing follows the text in
    /// the other two modes, and what cost was never the closure: it was working out which line was
    /// on top, which walked the buffer, before anything could decline to use the answer.
    private var visibleLineReporter: ((Int) -> Void)? {
        guard Self.followsVisibleLine(mode) else { return nil }
        return { line in followTheText(line) }
    }

    /// Whether anything is following where the text has scrolled to.
    ///
    /// **A named rule rather than an inline `mode == .split`, because it is the gate.** Only the
    /// split mounts a preview beside the text; in the other two the answer is computed and thrown
    /// away, and computing it means finding the topmost visible line for every clip-view bounds
    /// notification — once per scrolled row, and once per keystroke at the end of a long file.
    ///
    /// The **unresolved** mode, deliberately. `EditorMode.resolved` turns `.split` into `.edit` on a
    /// file with nothing to preview, and this has to agree with ``followTheText``, which asks the
    /// same unresolved question. Asking different ones is how the two halves of a split end up
    /// disagreeing about whether they are a split.
    static func followsVisibleLine(_ mode: EditorMode) -> Bool { mode == .split }

    /// **The text, under the format bar when it is drawn** (TE52) — in Split, the Source half alone.
    ///
    /// The bar is a sibling above the text view rather than an overlay on it, so the text never
    /// scrolls under a control; and it is an `if` beside an unconditional editor, so turning it on or
    /// off leaves the text view's identity — and its caret, scroll and undo — where they were.
    private var sourceColumn: some View {
        VStack(spacing: 0) {
            if showsFormatBar { formatBar }
            editorSurface
        }
    }

    /// The format bar, over Source or over an editable Preview — whichever text view the handle holds.
    private var formatBar: some View {
        EditorFormatBar(state: formatState.lighting(barActsOnPreview ? previewPending : []), accent: accent,
                        showsLabels: formatBarShowsLabels,
                        onVerb: { verb in textViewHandle.applyMarkup(verb) })
            .equatable()
            // On the bar itself, so a right-click on the text keeps the text view's menu.
            .contextMenu {
                EditorFormatBarMenu(showsLabels: $formatBarShowsLabels,
                                    showsBar: $showsFormatBarPreference)
            }
            .padding(.horizontal, Self.formatBarInset)
            .padding(.top, Self.formatBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the bar acts on editable Preview now — Preview alone, or Split's Preview half while
    /// the caret was last there — and so lights Preview's pending styles (FMT-15).
    private var barActsOnPreview: Bool {
        editsInPreview && (resolvedMode == .preview || textViewHandle.targetsSplitPreview)
    }

    /// The format bar's inset from the text card's edges — the bar is a strip IN the card, and the
    /// text view's own 14pt container inset sits under it.
    static let formatBarInset: CGFloat = 6

    private var editorSurface: some View {
        PlainTextEditor(source: buffer.source,
                        isEditable: !document.isReadOnly,
                        fontScale: fontScale,
                        documentID: document.path,
                        undoManager: undoManager,
                        // **Two writes, and only one of them announces anything.** `caretOffset` is
                        // this view's `@State` and drives the status line's Ln/Col. The anchor is a
                        // plain reference type on the document, so recording it costs nothing and
                        // re-renders nobody — see `EditorCaretAnchors` for why it may not publish.
                        // Written here rather than on the way out: `.onDisappear` would make the
                        // whole feature depend on teardown ordering, and this is always current.
                        onSelectionChange: {
                            // Split: the caret is in Source's half now (V7). An edit made in
                            // Preview's half nudges this selection too, but Preview reports after
                            // it, so the caret typed at is the one kept (measured 2026-10-09).
                            textViewHandle.caretInSplitPreview = false
                            caretOffset = $0.location
                            // Always, bar or no bar: the status line counts the selection (TE60).
                            // Into the box, not this view's state — a forward drag keeps the
                            // location still and writes only this, so its ticks redraw nothing here.
                            liveSelection.set(length: $0.length)
                            document.caretAnchors.remember($0.location, for: document.path)
                        },
                        onSelectionRangeCount: { liveSelection.set(rangeCount: $0) },
                        scrollRequest: editorScrollRequest,
                        // Where the caret goes when this text view is BUILT, which is to say on
                        // arrival back from another workspace. Clamped by `restoreCaret` against the
                        // text actually being assigned. After `scrollRequest` in the argument list
                        // because the memberwise init takes them in declaration order, and that
                        // order is also the precedence: a scroll request lands in `updateNSView`,
                        // which runs after `makeNSView` and overwrites this.
                        initialSelection: document.caretAnchors.offset(for: document.path) ?? 0,
                        onVisibleLineChange: visibleLineReporter,
                        lineIndex: lineIndex,
                        findRequest: findRequest,
                        // Withheld on a file that cannot be written — a Markup menu that greys out
                        // is a promise the document cannot keep.
                        offersMarkup: !document.isReadOnly,
                        editsMarkdown: document.isMarkdown,
                        imageImport: imageImporter,
                        followRequest: editsInPreview ? editorFollowRequest : nil,
                        textViewHandle: textViewHandle,
                        bottomInset: diskBannerInset)
    }

    /// Where a dropped or pasted image goes — only for a Markdown note that can be written, and
    /// only when the host is listening (``onImagesImported``).
    private var imageImporter: EditorImageImporter? {
        guard let onImagesImported, let path = document.path, document.isMarkdown,
              !document.isReadOnly, document.refusal == nil else { return nil }
        return EditorImageImporter(notePath: path, report: onImagesImported)
    }

    /// Sends both surfaces to a heading.
    ///
    /// **Both, whichever mode is showing.** Only one of them may be mounted, and the request that
    /// lands on the surface that is not there costs nothing — while resolving which one to send
    /// would have to know the mode, the Markdown-ness of the file and which half of a split has
    /// focus, to save exactly one assignment.
    ///
    /// **To where the heading is NOW** (CHR-4): the outline is re-derived only after the typing
    /// settles and the parse returns, so an entry can name the line its heading used to be on —
    /// `MarkdownOutline.line(of:in:)` finds the heading in the text as it stands.
    private func goToHeading(_ entry: MarkdownOutlineEntry) {
        let line = MarkdownOutline.line(of: entry, in: document.text)
        scrollToken &+= 1
        let request = EditorScrollRequest(line: line, token: scrollToken)
        editorScrollRequest = request
        previewScrollRequest = request
        // **In Preview there is no text view to move the caret**, so nothing reported it — the
        // status line's "in <heading>" (TE57) and the rail's mark both kept naming where the caret
        // had been, however often another heading was chosen. The caret goes there itself, and its
        // anchor with it, which is also where Source puts it when it comes back.
        if resolvedMode == .preview,
           let offset = PlainTextEditor.utf16Offset(ofLine: line, in: document.text, using: lineIndex) {
            let clamped = EditorCaretAnchors.clamped(offset, in: document.text)
            caretOffset = clamped
            document.caretAnchors.remember(clamped, for: document.path)
        }
    }

    /// **Esc in the rail's lists: the keys back to the document** (TE154) — `nil` with nothing
    /// open, where Esc is left to whoever is next.
    private var railReturnKeys: (() -> Void)? {
        guard pdf != nil || document.path != nil else { return nil }
        return { returnKeysToDocument() }
    }

    /// A PDF's pages take the keys through their own request. Text goes to the text view the caret
    /// was last in; where there is none — read-only Preview — the window is left holding them, and
    /// ``EditorUndoAnchor`` takes them from there, as it does after a mode switch.
    private func returnKeysToDocument() {
        if let pdf {
            pdf.view.requestFocus()
        } else if let text = textViewHandle.target, let window = text.window {
            window.makeFirstResponder(text)
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// **Opens a Contents result (RD38)** — through the rail's own door, so the unsaved-document
    /// question and the pane's selection are the ones a click on a row gets.
    ///
    /// - A text file opens at the match, selected, with Find holding the word (Source and Split) —
    ///   or, in Preview, scrolled to its line, since a rendered page has no line to select.
    /// - A PDF opens with its find holding the word and searching, so the first match is lit.
    /// - A Word or PowerPoint file opens in Quick Look: Edit does not open those.
    private func openContentResult(_ hit: EditorContentHit, _ line: EditorContentLine?) {
        guard let word = contentSearch?.key?.query else { return }
        pendingContentMatch = nil
        pendingPDFFind = nil
        switch hit.kind {
        case .document:
            railRowActions.quickLook(hit.path)
        case .pdf:
            onOpen(EditorRailEntry(path: hit.path, name: hit.name, size: 0, isCloudOnly: hit.isCloudOnly,
                                   kind: .pdf))
            pendingPDFFind = EditorContentMatch(path: hit.path, line: 1, column: 1, length: 0, word: word)
            seedPendingPDFFind()
        case .text:
            let before = document.path
            onOpen(EditorRailEntry(path: hit.path, name: hit.name, size: 0, isCloudOnly: false, kind: .text))
            guard document.path == hit.path else { return }
            let first = line ?? hit.lines.first
            let match = EditorContentMatch(path: hit.path, line: first?.line ?? 1, column: first?.column ?? 1,
                                           length: first?.length ?? 0, word: word)
            // A file that was already open — or refused and read again, under the same path — has no
            // arrival to wait for.
            if before == hit.path { selectContentMatch(match) } else { pendingContentMatch = match }
        }
    }

    /// Sends Source to a Contents match, selected and handed to Find — or Preview to its line.
    private func selectContentMatch(_ match: EditorContentMatch) {
        guard document.refusal == nil, let path = document.path else { return }
        let target = EditorContentMatch.located(match, in: document.text, using: lineIndex)
        // The caret's anchor first, as a heading jump in Preview moves it: a text view built later —
        // Preview to Source — opens at the match.
        let offset = EditorGoToLine.utf16Offset(of: .init(line: target.line, column: target.column),
                                                in: document.text, using: lineIndex)
        document.caretAnchors.remember(EditorCaretAnchors.clamped(offset, in: document.text), for: path)
        scrollToken &+= 1
        editorScrollRequest = EditorScrollRequest(line: target.line, token: scrollToken, column: target.column,
                                                  length: target.length, seedsFind: target.length > 0)
        if resolvedMode == .preview {
            previewScrollRequest = EditorScrollRequest(line: target.line, token: scrollToken)
        }
    }

    /// The PDF result's word, into the PDF's find — once the PDF open is the one clicked, and only
    /// if it opened: a refused PDF has no pages to search.
    private func seedPendingPDFFind() {
        guard let match = pendingPDFFind, let pdf, pdf.path == match.path else { return }
        pendingPDFFind = nil
        guard pdf.refusal == nil else { return }
        pdf.find.search(match.word)
        pdf.find.show()
    }

    /// Ticking a checkbox from the preview, or `nil` when this document must not be written to.
    ///
    /// **`nil` rather than a closure that declines**, so the control is never drawn on a read-only
    /// file: a checkbox that highlights under the pointer and then does nothing is worse than one
    /// that is plainly a picture.
    private var taskToggle: ((Int) -> Void)? {
        guard !document.isReadOnly, document.refusal == nil else { return nil }
        return { line in
            Self.toggleTask(onLine: line, in: buffer.source, undoManager: undoManager)
        }
    }

    /// Ticks or unticks the checkbox on a 1-based source line, **as a step ⌘Z can take back.**
    ///
    /// It was `document.text = rewritten`: a whole-buffer write the undo stack never heard of, so a
    /// tick could not be undone and left every range the stack held pointing at a buffer that had
    /// moved under it. It is now the few characters that changed, through the document's storage
    /// (`EditorSourceStorage.replace`), registered on the document's own stack. The edit is
    /// `MarkdownEdits.taskToggle`'s, the box's one character — and `replace` converts any carriage
    /// return in the file to LF in the same step, as it does for every edit from outside the view.
    ///
    /// A stale click — the line no longer holds a checkbox — leaves the text and the stack alone.
    ///
    /// **Measured against the storage's characters, not the published text.** The two differ by a
    /// word an input method is composing in Split, and a range taken from one and applied to the
    /// other would land that many characters early. **Read where they are**, through
    /// `mutableString`: `textStorage.string` copies the whole document to look at one line (P52).
    ///
    /// - Returns: whether anything was ticked.
    @discardableResult
    static func toggleTask(onLine line: Int, in source: EditorSourceStorage,
                           undoManager: UndoManager) -> Bool {
        guard let change = MarkdownEdits.taskToggle(onLine: line, in: source.textStorage.mutableString)
        else { return false }
        source.replace(change.range, with: change.text, undoManager: undoManager,
                       actionName: Self.taskActionName)
        return true
    }

    /// The Undo item's word for a tick — Edit ▸ Undo Checkbox, whichever way it went.
    static let taskActionName = "Checkbox"

    /// The folder the open document lives in — what a relative image path resolves against.
    ///
    /// **The DOCUMENT's folder, not the rail's.** They are usually the same and are not always: a
    /// file opened from a pane row in another folder keeps its own, and an image beside *it* is
    /// what its `![…](shot.png)` means. And the folder of the FILE, through a symlink to it — where
    /// the note is saved, and where its pasted images go (``EditorImageImport/linkFolder(ofNote:)``).
    private var documentFolder: String? {
        document.path.map(EditorImageImport.linkFolder(ofNote:))
    }

    /// A `#heading` link inside the document, followed rather than opened.
    ///
    /// Nothing happens when no heading matches — which is the honest answer, because the anchor
    /// convention is GitHub's rather than a standard and a near-miss should not scroll somebody
    /// somewhere they did not ask to go.
    private func followAnchor(_ fragment: String) {
        guard let line = MarkdownOutline.line(forAnchor: fragment, in: outline) else { return }
        scrollToken &+= 1
        previewScrollRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// Keeps the preview level with the text, in split.
    ///
    /// **One-way, and only in split.** The text drives and the preview follows: the preview cannot
    /// scroll the text back, so there is no loop to break — which is what a two-way sync would need
    /// a suppression flag for, and those are what make scroll syncs judder. In the other two modes
    /// only one surface is on screen and there is nothing to keep level with.
    private func followTheText(_ line: Int) {
        guard mode == .split else { return }
        // The echo of Preview leading is dropped — with Preview editable, it scrolls too.
        guard splitFollow.shouldFollow(from: .source) else { return }
        scrollToken &+= 1
        previewScrollRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// Split, Preview editable: Source follows Preview the way Preview follows Source — by line,
    /// the view only, and never the echo of its own lead.
    private func followThePreview(_ line: Int) {
        guard mode == .split, splitFollow.shouldFollow(from: .preview) else { return }
        scrollToken &+= 1
        editorFollowRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// The name of the row's own coordinate space, which the drag reads positions in.
    ///
    /// **A fixed space, never `.local`** — the rule `ResizeHandle` states for every other seam in
    /// the window. The strip is offset by the divider's position, so it MOVES as it is dragged, and
    /// a local x is measured against a frame that is itself following the pointer: the drag reads
    /// as though the divider were always at the leading edge. Compensating for that by hand
    /// (`editorWidth - 6 + value.location.x`) is what this replaces — the offset is a layout detail
    /// the gesture should not have to know.
    private static let splitSpace = "editorSplit"

    private func splitHandle(width: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: 12)
            // **`.pointerStyle`, not an `NSCursor.push()`/`pop()` pair.** `ContentView+SplitLayout`
            // records removing exactly that bookkeeping from the pane seam — it leaks a pushed
            // cursor whenever `onHover(false)` is not delivered, which is every time the view goes
            // away under the pointer — and `.columnResize` is what every other seam in the window
            // shows. A hand-rolled copy here was both a third copy of the leak and a divider that
            // pointed differently from its neighbours.
            .pointerStyle(.columnResize)
            .gesture(
                // `minimumDistance: 1`, matching every other seam. The default is 10, and at a
                // narrow window the divider's whole legal travel is about 20pt — a 10pt dead zone
                // takes half of it and makes fine adjustment impossible exactly where it is needed.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                    .onChanged { value in
                        guard width > 0 else { return }
                        splitDrag = EditorLayoutMetrics.splitFraction(value.location.x / width,
                                                                      in: width)
                    }
                    .onEnded { _ in
                        if let splitDrag { splitFraction = splitDrag }
                        splitDrag = nil
                    }
                    // **A double-click puts it back in the middle** (TE181), where Split starts —
                    // as a double-click on a column seam fits it, beside the drag, not instead.
                    .simultaneously(with: TapGesture(count: 2).onEnded {
                        splitDrag = nil
                        splitFraction = EditorLayoutMetrics.splitStart
                    })
            )
            .accessibilityHidden(true)
    }

    private func readOnlyBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(.system(size: 11))
            Text(reason)
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    /// - Parameter showTextFiles: draws Show Text Files under the words (TE77) — the empty page's
    ///   way to the list while it is folded into the strip, which a first session opens into.
    /// - Parameter download: draws Download under the words — a refused file still in the cloud.
    private func caption(_ text: String, showTextFiles: (() -> Void)? = nil,
                         refusalButtons: [RefusalButton] = [], path: String = "") -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text(text)
                .scaledFont(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            if let showTextFiles {
                Button(action: showTextFiles) {
                    Label(Self.showTextFilesTitle, systemImage: EditorRailTab.files.symbol)
                        .scaledFont(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(accent)
                .shortcutKeycap(AppChord.editorTextFiles.display)
                .help(ShortcutHint.tooltip(Self.showTextFilesHelp, AppChord.editorTextFiles.display))
            }
            if !refusalButtons.isEmpty {
                // Side by side where they fit, stacked in a narrow column.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { refusalButtonViews(refusalButtons, path: path) }
                    VStack(spacing: 8) { refusalButtonViews(refusalButtons, path: path) }
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func refusalButtonViews(_ buttons: [RefusalButton], path: String) -> some View {
        ForEach(buttons, id: \.self) { button in
            switch button {
            case .download:
                Self.downloadButton(accent: accent, action: { railRowActions.download(path) })
            case .tryAgain:
                refusalButton(button, accent: true) { onTryAgain?() }
            case .quickLook:
                refusalButton(button, accent: false) { railRowActions.quickLook(path) }
            case .revealInFinder:
                refusalButton(button, accent: false) { railRowActions.revealInFinder(path) }
            }
        }
    }

    private func refusalButton(_ button: RefusalButton, accent tinted: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(button.title, systemImage: button.symbol)
                .scaledFont(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(tinted ? accent : nil)
        .help(button.help)
    }

    /// What a refusal offers under its caption (TE152).
    enum RefusalButton: Hashable {
        case download, tryAgain, quickLook, revealInFinder

        var title: String {
            switch self {
            case .download: return EditorWorkspaceView.downloadTitle
            case .tryAgain: return "Try Again"
            case .quickLook: return "Quick Look"
            case .revealInFinder: return "Reveal in Finder"
            }
        }

        var symbol: String {
            switch self {
            case .download: return "icloud.and.arrow.down"
            case .tryAgain: return "arrow.clockwise"
            case .quickLook: return "eye"
            case .revealInFinder: return "folder"
            }
        }

        var help: String {
            switch self {
            case .download: return EditorWorkspaceView.downloadHelp
            case .tryAgain: return "Read the file again, in case it has stopped changing"
            case .quickLook: return "Look at the file without opening it in Edit"
            case .revealInFinder: return "Show the file in Finder"
            }
        }
    }

    /// **The buttons under a refusal, in order**: what would let Edit open it first — Download for a
    /// file still in the cloud, Try Again for one that kept changing while it was read — then Quick
    /// Look and Reveal in Finder, for every file Edit can't open.
    static func refusalButtons(for refusal: String, canTryAgain: Bool) -> [RefusalButton] {
        var buttons: [RefusalButton] = []
        if isNotDownloaded(refusal) { buttons.append(.download) }
        if canTryAgain, refusal == EditorFileStore.keptChangingReason { buttons.append(.tryAgain) }
        return buttons + [.quickLook, .revealInFinder]
    }
}

extension EditorWorkspaceView {
    /// **Download, under a refusal for a file still in the cloud** (TE96) — the text card's and
    /// the PDF card's, one view. Browse's word and glyph.
    static let downloadTitle = "Download"
    static let downloadHelp = "Download this file from the cloud, then open it here"

    static func downloadButton(accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(downloadTitle, systemImage: "icloud.and.arrow.down")
                .scaledFont(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(accent)
        .help(downloadHelp)
    }
}

/// The oval track and its sliding knob — the switch shape, without the button around it.
///
/// **Its own view so a test can measure it.** It sits on the header's meta line, which is
/// `lineLimit(1)` in a column whose guaranteed minimum is 260pt, so a switch that grew faster than
/// the words beside it would be the thing that pushed the status word out of the row.
struct AutosaveSwitchTrack: View {

    let isOn: Bool
    /// The on track's fill — the deepened accent, as every solid accent surface takes.
    let fill: Color

    @Environment(\.appFontScale) private var scale

    /// The track's height at the default text size, and the point size of the text beside it.
    ///
    /// **Scaled through `FontSize.scaledBox`, not a bare multiply**, so the switch follows the same
    /// ramp as the words — including its knee above 11pt, past which a multiply would have the
    /// switch outgrowing the line it is on. Same rule as ``CapsuleGlyph``.
    static let baseHeight: CGFloat = 11
    static let basePoint: CGFloat = 10
    /// A shade under 2:1, the proportion AppKit and iOS both draw.
    static let aspect: CGFloat = 1.85
    /// The gap between knob and track, at the base size.
    static let inset: CGFloat = 1.5

    static func height(at scale: CGFloat) -> CGFloat {
        FontSize.scaledBox(baseHeight, basePoint: basePoint, scale: scale)
    }

    static func width(at scale: CGFloat) -> CGFloat { height(at: scale) * aspect }

    var body: some View {
        let height = Self.height(at: scale)
        let width = Self.width(at: scale)
        let inset = Self.inset * height / Self.baseHeight
        let knob = height - inset * 2

        Capsule()
            .fill(isOn ? AnyShapeStyle(fill) : AnyShapeStyle(.quaternary))
            .overlay {
                // The off track needs an edge, or against a light ground it reads as a gap in the
                // row rather than as a control that is switched off.
                Capsule().strokeBorder(Color.secondary.opacity(isOn ? 0 : 0.35), lineWidth: 0.5)
            }
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 0.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .padding(.leading, inset)
                    // **An offset rather than a change of alignment.** Swapping `.leading` for
                    // `.trailing` moves the knob by re-laying it out, and a layout change does not
                    // interpolate; an offset is a value SwiftUI can animate between, so it slides.
                    .offset(x: isOn ? width - height : 0)
            }
            // Through the house helper, so Reduce Motion turns the slide off — a repo-wide scan in
            // the Design package holds every animated site to it.
            .designAnimation(.easeInOut(duration: 0.16), value: isOn)
            // The button around it carries the label, the value and the traits; a second element
            // here would make VoiceOver stop twice on one control.
            .accessibilityHidden(true)
    }
}

/// The padding around the document header, in one place because a test measures what it produces.
struct EditorDocumentHeader<Content: View>: View {
    @ViewBuilder let content: Content

    static var horizontalPadding: CGFloat { 14 }
    static var verticalPadding: CGFloat { 8 }

    var body: some View {
        content
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
    }
}

/// The parses a workspace has started, and the one whose blocks are on screen (CHR-4) — or its
/// counts, or its caret (F-E6).
final class EditorParseTickets {
    var started = 0
    var shown = 0
}

/// **Whether a finished parse goes on screen** (CHR-4): it was taken of the file still open, and it
/// was started after the one on screen. A keystroke during the parse is no reason to drop it — the
/// text it parsed is newer than what is drawn — but a parse finishing after a later one must not
/// put older blocks back, and one of another file must not land on this one. The status line's counts
/// and its caret land by the same rule (F-E6).
enum EditorParseLanding {
    static func lands(ticket: Int, takenOn path: String?, current: String?, shown: Int) -> Bool {
        path == current && ticket > shown
    }
}
