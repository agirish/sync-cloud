import SwiftUI
import Design
import Sync
import Events

/// The Editor workspace's hard widths, in one place because the app target has to clamp against
/// them and the views have to draw at them. Named, as `PaneLogic.minRailWidth` is, because the row
/// is divided by a fraction the user drags, and a clamp that disagrees with what it clamps leaves a
/// column too narrow to use with no way to widen it.
public enum EditorLayoutMetrics {
    /// The file rail's default and narrowest width. The list's three tabs are measured to fit at
    /// exactly this (`theRailTabsFitTheRailAtEveryTextSize`), so nothing narrower is safe.
    public static let railWidth: CGFloat = 232
    /// The widest the side column may be dragged. Edit's list and its file pane share one width the
    /// person drags, floored at ``railWidth``. 480 leaves a paragraph beside it on the smallest
    /// window and two Columns columns inside the pane.
    public static let maxRailWidth: CGFloat = 480

    /// A dragged or stored side-column width, held inside ``railWidth``…``maxRailWidth``.
    public static func clampedRailWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, railWidth), maxRailWidth)
    }
    /// The narrowest the document column may become. Below this a line of prose stops being a line.
    public static let minDocumentWidth: CGFloat = 260
    /// What the editor half of the row needs in total, which the source pane is clamped against when
    /// expanded. Includes 2 × `cardGutter`: the rail and document cards each pad by half a gutter on
    /// every side, chrome neither column can use, and without it the clamp would guarantee a document
    /// width it then shaves short.
    public static var minWorkspaceWidth: CGFloat {
        railWidth + minDocumentWidth + 2 * LiquidGlass.cardGutter
    }

    /// What the editor half needs when the rail is not drawn: the document and its one card, which
    /// is one gutter. The host clamps the source pane's drag range against this when the rail has
    /// stepped aside, rather than reserving room for a column that is not on screen.
    public static var minDocumentOnlyWidth: CGFloat { minDocumentWidth + LiquidGlass.cardGutter }

    /// The narrowest either half of a `.split` may become. Smaller than ``minDocumentWidth``, which
    /// is for a document alone in the column: a preview beside the text is worth more than either
    /// at its comfortable width.
    public static let minSplitColumnWidth: CGFloat = 220

    /// Where Split's divider starts, and where a double-click on it puts it back: the middle.
    public static let splitStart: CGFloat = 0.5

    /// `raw` clamped so neither half of a `.split` falls under ``minSplitColumnWidth``.
    ///
    /// **Every call site must ask this**, the drawing and the drag alike.
    /// `min(max(x, lower), 1 - lower)` is not a clamp when `lower > 1 - lower`: it collapses to
    /// `1 - lower`. At the 760pt window floor the column (~391pt) is under 2 × 220, so an unguarded
    /// copy would freeze the divider, or store a fraction nobody chose for when the window widens.
    public static func splitFraction(_ raw: CGFloat, in width: CGFloat) -> CGFloat {
        // Too narrow to honour two minimums: split the difference rather than pinning one side.
        guard width >= 2 * minSplitColumnWidth else { return 0.5 }
        let lower = minSplitColumnWidth / max(width, 1)
        return min(max(raw, lower), 1 - lower)
    }
}

/// The Editor workspace: the file rail, and the open document beside it.
///
/// Manager-free, like the compare sheet: every act (open a file, create one, save one) leaves
/// through a closure, so the workspace can be laid out and asserted without a `FileSyncManager`.
/// `ContentView+Editor` supplies those closures and owns the consequences.
public struct EditorWorkspaceView: View {

    @ObservedObject var document: EditorDocument
    /// The document's characters, observed separately (see ``EditorBuffer``). Observed here, once,
    /// so a keystroke's redraw stops at this view rather than reaching `ContentView.body` and the
    /// App scene's `.commands` tree, which render only the file's identity.
    @ObservedObject var buffer: EditorBuffer
    /// Which files autosave may write. See ``EditorAutosavePolicy``.
    @ObservedObject var autosavePolicy: EditorAutosavePolicy
    /// The PDF open in Edit, or `nil`. Handed in only while one is open, when the text document is
    /// empty (`path == nil`); the header and document card draw the PDF instead, so nothing a text
    /// file draws is reachable (see ``EditorPDFDocument``).
    let pdf: EditorPDFDocument?

    /// The folder the sidebar has selected. Empty when there is none.
    let folder: String
    let entries: [EditorRailEntry]
    /// What the ＋'s tooltip, the naming row and the rail call `folder`: the pane breadcrumb's word
    /// for it, built by the host ("iCloud" at the top of iCloud Drive, whose last component is
    /// "com~apple~CloudDocs"). `nil` falls back to the last component, right for every folder but a
    /// source's top.
    var folderDisplayName: String?
    /// Where ⌘N will make its file when that is not `folder`: "Notes", for a pane on a folder that
    /// is no place for a new file (the host's `EditorNewFileFolder`). Named by the ＋'s tooltips and
    /// the naming rows; `nil` names `folderName`.
    var newFileFolderName: String?
    /// The rail's folder menu and what a pick in it does; see ``EditorFileRailView/folderTrail``.
    let folderTrail: EditorFolderTrail?
    let onGoToFolder: ((String) -> Void)?
    /// Whether the file rail is drawn beside the document at all.
    ///
    /// Decided by the host (`TopPaneVisibility.editorRailIsDrawn`), from two bits this view never
    /// sees: whether the source pane is open (it is then the file list, and the rail would repeat
    /// it) and whether "Just the text" is on. Without the rail the document takes the whole width,
    /// and ⌘N's naming row is drawn at the top of the document column (see ``EditorNamingRow``).
    let showsRail: Bool
    /// Whether Expand is on (the rail bit set and the source pane folded, worked out by
    /// `ContentView.editorIsExpanded`): the header button's lit state, and whether it reads Expand
    /// or Files. Not `!showsRail`: the rail is also absent while the source pane is open, and the
    /// button is not lit then, because the pane is the file list.
    let railIsHidden: Bool
    /// The Expand button's act. The host owns the bit and what else moves with it.
    let onToggleJustTheText: () -> Void
    /// The rail's fold button: the list folds into the pane's strip. `nil` draws no button.
    let onFoldRail: (() -> Void)?
    /// The empty page's Show Text Files button. The host passes it only while the list is folded or
    /// put away with the pane folded too, when nothing else on the page leads to a file.
    let onShowTextFiles: (() -> Void)?
    /// The status line's Show Outline in File List: the list on its Outline tab from wherever it
    /// was (folded, behind the open file pane, or under Expand), as the strip's Outline button
    /// brings it. `nil`, in the previews and probes, only switches the tab.
    let onShowRailOutline: (() -> Void)?
    /// Opens the file pane on the list's folder: the folder menu's Show All, as the strip's pane
    /// button opens it. `nil` in the previews and probes.
    let onOpenFilePane: (() -> Void)?
    /// The files Edit opened last, for the empty page; `nil` draws the page as one sentence. The app
    /// passes `EditorRecentFiles.shared`.
    let recentFiles: EditorRecentFiles?
    /// A recent row's click, the host's hand-off so the pane follows the file. `nil` with
    /// `recentFiles` draws no list either: a row that opened nothing would be worse than none.
    let onOpenRecent: ((String) -> Void)?
    /// Files dropped from Finder on the empty page. The host opens them as Finder's Open With does:
    /// the first in Edit, the rest waiting in the file pane, a folder named in a banner. `nil` takes
    /// no drop. A drop on an open document is the text's own, unchanged.
    let onDropFiles: (([URL]) -> Void)?
    /// The list's width: the side-column width the host's drag sets, at least
    /// ``EditorLayoutMetrics/railWidth``.
    let railWidth: CGFloat
    /// The header's ＋: **the host's ⌘N closure itself**, not a second copy of what it does.
    ///
    /// ⌘N sets `isNaming` and bumps the focus counter this view only reads (``namingFocus``); a
    /// button that set `isNaming` alone would open the row without taking focus, so a second ⌘N
    /// would do nothing. `nil` greys it. The app always passes ⌘N's closure, since with no folder
    /// in the pane ⌘N makes its file in Notes.
    let onNewTextFile: (() -> Void)?
    /// The header's ×: settle the buffer, then unload the document to the empty state. The host
    /// owns both halves (the unsaved-changes question is asked in `ContentView+Editor` and nowhere
    /// else), so this view only reports the press.
    let onCloseDocument: () -> Void
    /// Passed straight through to the rail's empty caption; see
    /// ``EditorFileRailView/otherFileCount``. Defaulted for the same reason it is defaulted there.
    var otherFileCount: Int?
    /// The raw accent, for washes, hairlines, accent-coloured words and hover tints.
    let accent: Color
    /// The accent deepened until a white label on it clears WCAG AA
    /// (`LiquidGlassHue.accentFillColor`): what every lit control fills with. The raw accent under
    /// a white label is 2.7:1 on Green; `AccentFillScanTests` keeps it out of Edit's fills.
    let accentFill: Color
    /// The label colour on `accentFill`, the same value the workspace bar's selected segment uses.
    let onAccent: Color
    /// Source / Preview / Split. Held by the host so it survives the workspace being torn down.
    @Binding var mode: EditorMode
    /// The width the editor takes in `.split`, as a fraction of the column. Held by the host beside
    /// `mode` for the same reason: as `@State` here a workspace switch would reset the divider while
    /// the mode survived.
    @Binding var splitFraction: CGFloat
    @Binding var isNaming: Bool
    /// The rail's filter, and whether its field is showing. Held by the host beside `isNaming` and
    /// `typedName`, for the same reason; see ``EditorFileRailView/filter``.
    @Binding var railFilter: String
    @Binding var railFilterIsExpanded: Bool
    /// Which half of the rail is showing, its files or the open document's outline. Held by the host
    /// beside the filter, for the same reason; see ``EditorRailTab``.
    @Binding var railTab: EditorRailTab
    /// Where each document's outline was last scrolled to. Held by the host beside the tab, for the
    /// same reason; see ``EditorFileRailView/outlineAnchors``.
    @Binding var railOutlineAnchors: [String: Int]
    /// The name being typed in the naming row. Held by the host beside `isNaming`; see
    /// ``EditorFileRailView/typedName``.
    @Binding var typedName: String
    /// A counter ⌘N bumps, so a row that is already open still takes focus. See
    /// ``EditorFileRailView/namingFocus``.
    let namingFocus: Int
    /// A counter Text ▸ Go to Line… (⌃⌘L) bumps, so the menu opens the field the status line's
    /// "Line, Col" opens. A count rather than a flag, as ``namingFocus`` is: the second press is a
    /// press too. Read only where Go to Line is offered (``offersGoToLine``).
    let goToLineRequest: Int
    /// The window's editor undo stack. See ``PlainTextEditor/undoManager``.
    let undoManager: UndoManager
    /// Why autosave has stopped, in the header's own words, or `nil` while it is working. A string
    /// rather than the host's enum: this view draws it and never branches on it.
    let stopped: String?
    /// The reason behind ``stopped``, for its tooltip where the words are not a door: a failed
    /// write's own sentence, which the banner said only once.
    let stoppedDetail: String?
    /// The second door onto "which version wins", or `nil` when there is nothing to show.
    ///
    /// The alert that asks is modal, and its Cancel leaves autosave stopped, so without this the
    /// only way back to the question is ⌘S. Which stops have a second version is a rule about the
    /// stop (`EditorAutosaveStop.offersDiff`), not the header. `nil` leaves the words as plain
    /// state, with no hover wash and nothing for VoiceOver to activate.
    var onShowWhatChanged: (() -> Void)?
    /// The status word saves ("unsaved — ⌘S", "not saving — couldn't write"), or `nil` where the
    /// host's stop has nothing a save would settle.
    var onSaveNow: (() -> Void)?
    /// "not saving — no longer on disk" is Save Again, or `nil` for any other stop.
    var onSaveAgain: (() -> Void)?
    /// Try Again under a refusal for a file that kept changing: reads it once more.
    var onTryAgain: (() -> Void)?
    /// The question standing over the document after a change from elsewhere, drawn in the
    /// document card above the text. `nil` while there is none.
    var diskBanner: EditorDiskBanner?
    /// A few seconds of words in the status line about what a change from elsewhere did:
    /// "Reloaded — changed elsewhere".
    var diskNotice: String?
    /// A press on the banner, which the host answers.
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
    /// Where the open document lives, for the header's meta row, or with no document open the
    /// folder a new file would be made in, which the empty page's header names instead. `nil` with
    /// no document and no folder. Built by the host from the pane's breadcrumb model; see
    /// ``EditorDocumentLocation``.
    let location: EditorDocumentLocation?
    /// A door in that location, pressed. The host decides what each means for the left pane; the
    /// view only says which word was pressed.
    let onLocationDoor: (EditorDocumentLocation.Door) -> Void
    /// The rail row menu's acts (Reveal in Browse, Get Info, Quick Look, each on that row's file),
    /// built by the host and handed to the rail as they are.
    let railRowActions: EditorRailRowActions
    /// Called when autosave is switched back on for the open document, so the host can write what
    /// is already pending rather than waiting for the next keystroke.
    var onAutosaveResumed: () -> Void = {}
    /// Whether the source pane beside this column draws its tab strip (two tabs, or View ▸ Tab
    /// Bar). The strip pushes the pane's toolbar card down by ``PaneTabStripLadder/slotHeight(_:)``,
    /// so the header card here leaves the same slot empty to stay level: the two cards share their
    /// edges, and the text starts where the list does. `false` while the pane is collapsed, and by
    /// default, since other construction sites are tests with no pane beside them.
    var paneShowsTabStrip: Bool = false
    /// Told about every image dropped on or pasted into the open note: what was written, so the
    /// host can re-read the panes and owe Compare its rescan, or why nothing was, for the banner.
    /// `nil` takes no images, rather than writing files nobody is told about.
    var onImagesImported: ((EditorImageImport.Report) -> Void)?
    /// Told each time the 256 KB decision is taken (see ``PreviewLengthHold``), so the Text and
    /// Markup menus gate on the same answer as the Preview they act on. `nil` tells nobody.
    var onPreviewLengthHold: ((PreviewLengthHold) -> Void)?
    /// The window's search inside files: the Files list filter's Contents side. Held by the host
    /// beside the filter's text; `nil` draws the name filter alone.
    var contentSearch: EditorContentSearchModel?

    @Environment(\.appFontScale) private var fontScale

    // The window's chrome, read straight from the shared defaults rather than threaded through the
    // initializer: the same four keys `StorageLensView` and `LensWorkspaceView` read. Settings, not
    // state anybody owns.
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
    /// Where every line of the buffer begins, built beside the counts for the same reason (see
    /// ``EditorLineIndex``). The split's scroll sync and the outline's caret read it instead of
    /// walking the buffer on the main actor.
    @State private var lineIndex: EditorLineIndex = .empty
    /// The text version ``facts`` and ``lineIndex`` were taken at, `nil` before the first count.
    /// The selection's count pairs itself only with counts of the same text.
    @State private var factsVersion: Int?
    /// The file ``facts`` were counted for; the status line shows them only beside that file.
    @State private var factsPath: String?
    /// The caret's UTF-16 offset, as the text view last reported it. The offset is kept and the
    /// line/column derived on a debounce, because converting walks the buffer and this is written
    /// on every arrow key: the trade ``EditorDocument/textVersion`` makes.
    @State private var caretOffset: Int = 0
    /// The caret in the terms the status line shows, derived from ``caretOffset``.
    @State private var caret: EditorCaret = EditorCaret(line: 1, column: 1)
    /// The file ``caret`` was derived for; the status line draws "Line, Col" only beside that file,
    /// as it does the counts beside ``factsPath``.
    @State private var caretPath: String?
    /// Which count, and which caret, of a file just opened skip the debounce; see
    /// ``EditorFirstCountGate``. Held, not observed.
    @State private var factsGate = EditorFirstCountGate()
    @State private var caretGate = EditorFirstCountGate()
    /// The open document's headings, re-derived beside the blocks they come from.
    @State private var outline: [MarkdownOutlineEntry] = []
    /// Which parse is on screen; see ``EditorParseLanding``. Held, not observed: counting a parse
    /// must not re-render the view.
    @State private var parseTickets = EditorParseTickets()
    /// The same for the counts, and for the caret.
    @State private var countTickets = EditorParseTickets()
    @State private var caretTickets = EditorParseTickets()
    /// Where the text view has been asked to put the caret, and where the preview has been asked to
    /// scroll. Two requests, because an outline click moves both and a scroll in split moves only
    /// the preview.
    @State private var editorScrollRequest: EditorScrollRequest?
    @State private var previewScrollRequest: EditorScrollRequest?
    /// Bumped on every request, so asking for the same line twice is two requests.
    @State private var scrollToken: Int = 0
    /// Bumped by the header's Find button. See ``PlainTextEditor/findRequest``.
    @State private var findRequest: Int = 0
    /// The same, for Split's editable Preview half while the caret was last there.
    @State private var splitPreviewFindRequest: Int = 0
    /// The selection's UTF-16 length, beside ``caretOffset`` (its location), from which the format
    /// bar's lit state and the status line's selection count derive. **Held, not observed**:
    /// `@State` keeps the box and only ``EditorSelectionDerivations`` watches its contents, so a
    /// drag's tick re-renders that, not this whole view (``EditorLiveSelection``).
    @State private var liveSelection = EditorLiveSelection()
    /// The selection's counts for the status line, or `nil` for a bare caret. Derived from
    /// ``caretOffset`` and the live selection on the caret's debounce, off the main actor.
    @State private var selectionFacts: EditorSelectionFacts?
    /// Whether Go to Line's field is up over the status line's "Line, Col".
    @State private var goToLineShown = false
    /// The floating cards' measured height (the read-only note and the disk banner, stacked); see
    /// ``diskBannerInset``.
    @State private var diskBannerHeight: CGFloat = 0
    /// What the format bar shows lit; see ``MarkupFormatState``.
    @State private var formatState: MarkupFormatState = .none
    /// Editable Preview's pending styles, as verbs, lit on the bar while Preview has the caret.
    /// Preview reports them as they change.
    @State private var previewPending: Set<MarkupVerb> = []
    /// The text view, for the format bar's buttons; see ``EditorTextViewHandle``.
    @State private var textViewHandle = EditorTextViewHandle()
    /// View ▸ Format Bar. Read here like the glass settings above: a preference, not state.
    @AppStorage(EditorTextSettings.showsFormatBarKey) private var showsFormatBarPreference: Bool
        = EditorTextSettings.showsFormatBarDefault
    /// Icon and Text or Icon Only: the format bar's right-click choice.
    @AppStorage(EditorTextSettings.formatBarShowsLabelsKey) private var formatBarShowsLabels: Bool
        = EditorTextSettings.formatBarShowsLabelsDefault
    /// Live only while the divider is being dragged; the committed value lives with the host.
    @State private var splitDrag: CGFloat?
    /// Text ▸ Edit in Preview (Experimental) and the pill in the Preview column.
    @AppStorage(EditorTextSettings.editsInPreviewKey) private var editsInPreviewPreference: Bool
        = EditorTextSettings.editsInPreviewDefault
    @AppStorage(EditorTextSettings.editsInPreviewIntroSeenKey) private var editsInPreviewIntroSeen = false
    /// The page under Source's text: Paper, the switch beside Autosave, and Text ▸ Paper Background.
    @AppStorage(EditorTextSettings.drawsPageKey) private var drawsPage: Bool = EditorTextSettings.drawsPageDefault
    /// The pill's one-time "experimental" popover; see ``PreviewEditToggle/showsIntro``.
    @State private var showsPreviewEditIntro = false
    /// Whether this note is too long to edit in Preview, as decided when Preview was opened for it.
    @State private var previewLengthHold: PreviewLengthHold?
    /// "That change needs Source." while Preview has just refused an edit; see ``EditorStatusHint``.
    @State private var statusHint: EditorStatusHint?
    /// Counts every hint raised, so each has its own token for as long as this view lives; a count
    /// that restarted would let an earlier timer clear a later hint early.
    @State private var hintsRaised = 0
    /// Split with Preview editable: which half leads the scroll.
    @State private var splitFollow = SplitScrollFollow()
    /// Split with Preview editable: where Source scrolls to follow Preview (the view, not the caret).
    @State private var editorFollowRequest: EditorScrollRequest?
    /// A Contents result waiting for its file to arrive: the match to select once the document is
    /// the one clicked. From the empty page the text view is built in the arrival's own update, and
    /// a request standing when a text view is built counts as already answered
    /// (`PlainTextEditor.makeCoordinator`, so a mode switch never replays an old jump). Sent from the
    /// arrival's handler, it reaches the new view (`EditorContentOpenMountedTests`).
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
                // No defaults, so every construction site is read: the header's location is a
                // claim about where the file lives, and a silent `nil` would leave it saying nothing.
                location: EditorDocumentLocation?,
                onLocationDoor: @escaping (EditorDocumentLocation.Door) -> Void,
                // No default, like `onToggleJustTheText`, and none inside it for the host's three
                // acts: a row menu whose acts defaulted to nothing would draw and do nothing.
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
        // Taken from the document rather than passed in: there is exactly one buffer per document,
        // held for its life, so a parameter would only be a way to hand this view the wrong one.
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

    /// The Expand button's word: its next act, not its state, as the spine's chevron names its own.
    /// "Expand" while the rail, pane and sidebar can be put away; "Files" once they are. Also the
    /// accessibility label, so VoiceOver and Voice Control users say what a sighted one reads. A
    /// static so a test can pin the strings without a hosted accessibility tree.
    static func expandTitle(railIsHidden: Bool) -> String {
        railIsHidden ? "Files" : "Expand"
    }

    /// What the Expand button says under the pointer, before its chord: the act in full, since the
    /// word alone does not say what "Expand" puts away.
    static func expandHelp(railIsHidden: Bool) -> String {
        railIsHidden ? "Show the files again, as they were"
                     : "Give the document the window — put away the file list and the sidebar"
    }

    /// The glyph: arrows out to expand, arrows in to come back to the files, the platform's own
    /// pair for growing and shrinking a view.
    static func expandSymbol(railIsHidden: Bool) -> String {
        railIsHidden ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    /// What the header's ＋ says in its tooltip: where the file will be made. The rail's ＋ has its
    /// folder named beside it; this one doesn't, so the tooltip carries it. A static for the reason
    /// ``expandTitle(railIsHidden:)`` is one.
    static func newTextFileTitle(folderName: String) -> String {
        folderName.isEmpty ? "Pick a folder in the sidebar first" : "New text file in \(folderName)"
    }

    /// What the empty page says under its header: how to open a file, in one sentence.
    ///
    /// Every variant ends on ⌘O, the door into Edit from everywhere else a text file is listed. It
    /// doesn't mention ⌘N, since the header's ＋ carries it. "From the list" only while the rail is
    /// there; without it the list is the source pane or, under Expand, nothing, and this view can't
    /// tell which. The chord comes from `AppChord`, so a rebinding moves the words. It names the
    /// three workspaces rather than "any tab", since pane tabs and the workspace switcher are both
    /// tabs here. A static so a test can read the sentences without rendering them.
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

    /// The mode actually being drawn: `.edit` on a file with nothing to preview, whatever the
    /// capsule last remembered. The header asks this rather than `mode` for the reason
    /// ``EditorMode/resolved(_:isMarkdown:)`` exists.
    private var resolvedMode: EditorMode {
        EditorMode.resolved(mode, isMarkdown: document.isMarkdown)
    }

    /// The folder as the header and the rail name it; see ``folderDisplayName``.
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

    /// Whether the open text document is a Markdown note that was read, which keeps the rail's
    /// Outline tab. A refused note has no text and so no headings, whatever its name says.
    public static func markdownIsOpen(_ document: EditorDocument) -> Bool {
        document.isMarkdown && document.refusal == nil
    }

    /// Two cards in Cards; in Unified, two areas of the window's one region with a rule down it.
    ///
    /// The rail (what you could open) and the document (what you have open) are separated the way
    /// every pair of neighbours in this window is: a gutter between cards in Cards, a hairline
    /// (`unifiedSeam`) in Unified. `spacing: 0` and no padding, because `bottomSectionCard` insets
    /// itself by half a gutter in Cards, so two cards come to one `cardGutter` and line up with the
    /// pane cards. No `Divider` in Cards: a rule down a gutter would be a third edge.
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
        // Here, on the whole workspace, not beside the text's arrival handler, whose view is
        // taken down the moment a PDF opens and so never hears the PDF arrive.
        .onChange(of: pdf?.path) { _, _ in seedPendingPDFFind() }
    }

    // MARK: - The open document

    /// Two cards, like the file pane's: a header card, and the text under it.
    ///
    /// The header card is pinned to `LiquidGlass.headerHeight`, the constant the pane's `PaneHeader`
    /// reads, so the two share a bottom edge; it keeps that height with the pane collapsed, so the
    /// document doesn't move when the pane opens. In `.unified` the text sits flush under the
    /// header as the pane's list does. The empty page keeps the same header card, so nothing jumps
    /// when a file opens or closes (``emptyHeaderContent``).
    ///
    /// Under the pane's tab strip the strip's slot is left empty (``paneShowsTabStrip``): a gap
    /// above the header card in `.cards`, a band inside the region in `.unified`, so both columns'
    /// tops stay level. Both styles go through the shared column helpers (`columnSectionCard`,
    /// `columnRegionFrame`, `columnHeaderRule`), so this column can't drift from its neighbours.
    private var documentColumn: some View {
        let stripSlot = paneShowsTabStrip ? PaneTabStripLadder.slotHeight(surfaceStyle) : 0
        let cards = surfaceStyle == .cards
        return VStack(spacing: 0) {
            // Unified: the strip's band, inside the region. Cards: the gap above the header card,
            // which is padding outside both cards (below).
            Color.clear.frame(height: cards ? 0 : stripSlot)
            // The rule is drawn over the header's bottom edge, not under it, so it costs no height:
            // the pane's list starts flush at the header's pinned edge, and so must this text.
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

    /// Everything under the header: ⌘N's row when it has no rail to live in, the document, and for
    /// a text file its status line. A PDF has none.
    private var textCard: some View {
        VStack(spacing: 0) {
            // ⌘N's row, when there is no rail to draw it in (the two are exclusive; see
            // ``EditorNamingRow``). It names the folder, since nothing else here says where the file
            // will be made. In the text card, not above the header, so the header stays level with
            // the pane's toolbar card while ⌘N is open.
            if !showsRail && isNaming {
                EditorNamingRow(isNaming: $isNaming, typedName: $typedName, namingFocus: namingFocus,
                                accent: accent, prefilledName: prefilledName, refusal: refusal,
                                onCreate: onCreate, folderName: newFileFolderLabel)
                    .padding(.top, 6)
            }
            if let pdf {
                // No find bar, Fill & Sign toolbar or status line here: the find card, Fill & Sign's
                // palette and its save pill float over the pages (`EditorPDFReader`), and the status
                // line's facts are in the header's second row and the capsule.
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
        // Not under a refusal: a document that could not be read has an empty buffer, and
        // "0 words · 0 characters" would read as a measurement of the file.
        if document.path != nil, document.refusal == nil {
            Divider()
            // Formatted when the stamp moved, not here; see ``EditorDocument/sizeCaption``.
            EditorStatusLine(facts: EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path),
                             caret: caret, fileSize: document.sizeCaption,
                             headings: statusHeadings, hint: statusHint,
                             selection: selectionFacts, goToLine: statusGoToLine, notice: diskNotice,
                             heldFacts: facts, caretIsCurrent: caretPath == document.path)
                // Compared on what it draws, the closures left out; see `EditorStatusLine.==`.
                .equatable()
        }
    }

    /// Go to Line, where there are source lines on screen: Source and Split, never Preview, editable
    /// or not, since a rendered page has no line 48. One rule for the status line's "Line, Col" and
    /// the menu item (`EditorVerbs.goToLine`).
    public static func offersGoToLine(_ resolvedMode: EditorMode) -> Bool { resolvedMode != .preview }

    private var offersGoToLine: Bool { Self.offersGoToLine(resolvedMode) }

    /// The status line's door to Go to Line, or `nil` in Preview.
    private var statusGoToLine: EditorStatusGoToLine? {
        guard offersGoToLine else { return nil }
        // This file's count, or none while the one on hand is the last file's.
        let lines = EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path).map { max($0.lines, 1) }
        return EditorStatusGoToLine(isPresented: $goToLineShown, lineCount: lines,
                                    accent: accent, onGo: goToLine)
    }

    /// Sends Source's caret to a line, and its column when one was typed: the outline's scroll
    /// request with a column on it, which tells the text view to clamp. In Split the preview
    /// follows the text's scroll as usual.
    private func goToLine(_ target: EditorGoToLine.Target) {
        goToLineShown = false
        scrollToken &+= 1
        editorScrollRequest = EditorScrollRequest(line: target.line, token: scrollToken,
                                                  column: target.column ?? 1)
    }

    /// The caret's line when it was derived for the open file, else `nil`: what the rail's outline
    /// and the status line's heading name the caret's section by.
    private var shownCaretLine: Int? {
        EditorStatusLine.shownCaretLine(caret, derivedFor: caretPath, open: document.path)
    }

    /// The status line's heading item: the rail's own outline and scroll request, reachable with the
    /// rail away, and a way to the rail's Outline tab from wherever it is not showing.
    private var statusHeadings: EditorStatusHeadings? {
        EditorStatusHeadings.make(outline: outline, caretLine: shownCaretLine, isMarkdown: document.isMarkdown,
                                  offersRailOutline: EditorStatusHeadings.offersRailOutline(showsRail: showsRail,
                                                                                            railTab: railTab),
                                  accent: accent,
                                  onSelect: goToHeading, onShowRailOutline: onShowRailOutline ?? { railTab = .outline })
    }

    /// The two rows above the document: which file, and where it stands.
    ///
    /// Its own view so a test can measure it: each row's height is its tallest child's (the mode
    /// capsule, the switch), both change with the text size, and a Markdown and a plain-text header
    /// must come out the same.
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

    /// Internal rather than private, so `EditorLayoutTests` can render the header alone and check
    /// the capsule reservation gives a Markdown file and a plain-text one the same height.
    @ViewBuilder
    var headerContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameRow
            metaRow
        }
    }

    /// The name row, and which words it draws: the file's name decides.
    ///
    /// The row holds the name, then New Text File, Find, the capsule, Files (Expand) and Close; the
    /// name is the only thing that gives, and it is what the row is for. So words are drawn only
    /// when the whole name fits beside them; otherwise the capsule is icons alone, each mode's name
    /// kept as its tooltip and accessibility label. `ViewThatFits` asks each row for its ideal
    /// width, the whole name for the worded row, so a name that would truncate picks the next rung.
    /// Both capsule rungs are one height (`bothCapsuleRungsAreTheSameHeight`). A plain-text file
    /// reserves the capsule's height with a hidden one.
    ///
    /// The buttons' words go first, all four together: their glyphs are familiar and have
    /// tooltips, while three bare mode glyphs ask the reader to know which is which. The order is
    /// ``nameRowRungs(isMarkdown:)``, which the tests read.
    @ViewBuilder
    private var nameRow: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(Self.nameRowRungs(isMarkdown: document.isMarkdown).enumerated()),
                    id: \.offset) { _, rung in
                nameRow(rung)
            }
        }
    }

    /// One reading of the name row: the capsule at a rung (or `nil`, only its height reserved, on a
    /// file with nothing to preview), and whether the header's buttons wear their words.
    struct NameRowRung: Equatable {
        var capsule: EditorModeBar.Rung?
        /// New Text File, Find, Files and Close: all four keep their words, or none does, since
        /// three words beside one bare glyph read as two styles.
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

    /// One reading of the name row; see ``NameRowRung``.
    private func nameRow(_ reading: NameRowRung) -> some View {
        HStack(spacing: 6) {
            // Accent while a write is pending, amber when writing has stopped, nothing when the
            // file matches the buffer. The pending dot matters: watching it go out is the only
            // evidence on screen that autosave is working. The coloured states never coincide.
            Circle()
                .fill(dotColour ?? .clear)
                .frame(width: 6, height: 6)
                // A column, not just a dot, and the same width is reserved on the row below, so
                // the header's two rows share one left edge.
                .frame(width: Self.dotColumnWidth, alignment: .leading)
                .opacity(dotColour == nil ? 0 : 1)
                .accessibilityHidden(dotColour == nil)
                .accessibilityLabel(status.dotName)
            Text(document.name)
                .scaledFont(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                // The whole name, and what right-click offers; only where there is a menu.
                .help(document.path == nil ? "" : EditorRailRowMenu.nameTooltip(document.name))
                // The way back: the filename is where a user asks "where is this?", so it offers
                // what the file's row in the list offers, with Reveal in Browse through the
                // header's own door.
                .contextMenu {
                    if let path = document.path {
                        EditorRailRowMenu(path: path, isCloudOnly: Self.isNotDownloaded(document.refusal),
                                          actions: railRowActions.revealing(through: onRevealInBrowse))
                    }
                }
            Spacer(minLength: 0)
            // Each button is its own glass capsule in Frosted and Clear: two worded actions in one
            // capsule read as one control. The row's own 6pt between them, so Solid's layout is
            // the row's.
            //
            // New Text File; see ``newTextFileButton``. The empty page's header draws the same one.
            newTextFileButton(worded: reading.chipsWorded)
            // Find, beside the capsule rather than in it: the capsule picks the representation,
            // this acts on the one you're in. Withheld in read-only `.preview`, which is a rendering
            // with no text view to search.
            if resolvedMode != .preview || editsInPreview {
                Button {
                    // The half the caret was last in, in Split, by the format bar's rule.
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
            // The capsule, only for files with something to preview (`PairContentKind` owns which
            // are Markdown). Its height is reserved either way, since it is the row's tallest
            // child and a `.txt` header would otherwise sit shorter than a `.md` one. Reserved by
            // hiding a real capsule, not by copying its metrics into a number that could go stale;
            // `.frame(width: 0)` so the width isn't reserved and the name isn't cut early.
            if let rung = reading.capsule {
                EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent, forcedRung: rung)
            } else {
                EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent)
                    // A reservation, never seen: Solid, so it runs no lens of its own on a mode
                    // change and draws no glass track; its height is the same in every appearance.
                    .environment(\.selectionLensAppearance, .today)
                    .hidden()
                    .frame(width: 0)
            }
            // Expand, between the capsule and the ×: the window-sized controls at the end of the
            // row, acting on how much of the window the document gets. One view, drawn by the empty
            // page's header too.
            expandButton(worded: reading.chipsWorded)
            // Close, at the far end, since it acts on the whole document. File ▸ Close Document is
            // the other door, with no key, because ⌘W is Close Tab. The host settles the buffer
            // first, so Cancel leaves everything as it was. Drawn in every mode and on read-only or
            // refused files too. The clearance keeps it 4pt from Expand's outset glass.
            EditorCloseChip(name: document.name, worded: reading.chipsWorded, accent: accent,
                            action: onCloseDocument)
                .chromeGlassClearance(.leading, rowSpacing: 6)
        }
    }

    /// The words the header's buttons wear on their worded rung. New Text File is the menu item's
    /// name, File ▸ New Text File…, without its ellipsis: the button asks nothing first.
    static let newTextFileWord = "New Text File"
    static let findWord = "Find"

    /// ＋, ⌘N's button in the header, for when there is no rail and so no other visible ＋ (the
    /// source pane open, or "Just the text"). It calls the host's ⌘N closure rather than setting
    /// `isNaming`, so the naming row opens and takes focus as the chord does. Drawn in Preview too,
    /// since it is about the folder, and with no document open, by both headers from this one view.
    ///
    /// Greyed with no ⌘N, as the menu item is, and visibly: `.disabled` alone leaves a `.glyph`
    /// hover-affordance button looking the same at rest, so the glyph takes the tertiary style. On
    /// the widest rung it reads "＋ New Text File", since the ＋ alone doesn't say new what.
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

    /// The one resolution of "where does this document stand", used by the dot and the words alike:
    /// the whole visible account of autosave.
    ///
    /// No "saving…" state on purpose: the write is a staged file and a rename on a local path,
    /// finished far inside a frame, so a spinner would be an unreadable flicker. A stop replaces the
    /// segment rather than joining it, since it is the one state where typing isn't reaching the
    /// file and "saved · not saving" would contradict itself.
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

    /// What kind of file this is, and nothing else: unobvious on a `.markdown`, a `.text` or a file
    /// with no extension. The size and the other measurements live in the status line, and the
    /// status word appears only in the states that need it (``EditorSaveStatus/word``).
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
            // Paper, then where the file lives, in one slot, so a Paper that steps aside leaves no
            // doubled gap. After Autosave, so Autosave never moves, and before the location, whose
            // width depends on the file. Offered on read-only files too, since a page changes
            // nothing on disk.
            //
            // The slot yields (`-1`), offered what the kind, Autosave and the status word leave.
            // Paper inside it is drawn whole or not at all, or a narrow column at a large size would
            // wrap "Autosave"; Text ▸ Paper Background is the way to it then.
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
                // Where the file lives, after the switch so its file-dependent width never slides
                // the switch. It takes the gap a `Spacer` would hold, since two unbounded views would
                // split the leftover width. It yields first (`layoutPriority(-1)`), or at a large
                // size in the narrowest column "Autosave" would wrap and grow the pinned header; the
                // location folds and truncates instead (``EditorLocationLabel``).
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
            // The status word, at the far end so the left never moves: its width changes with the
            // state, and here it grows into the gap, at the cost of distance from the switch.
            if let word = status.word {
                statusWord(word)
            }
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    /// The status word: a control when there is something behind it, plain text when there is not.
    ///
    /// Nothing painted at rest either way: the clickable case uses the app's hover affordance, a
    /// wash and ring only under the pointer, so the word promises no door that isn't there. Tinted
    /// amber, not accent, on a warning, so the header's one warning line keeps one colour.
    ///
    /// The wash's padding is horizontal only. The word grows into the gap at the row's end, but
    /// vertical padding would make the row taller, and the header must be the same height for
    /// every file (`theHeaderIsTheSameHeightForEveryKindOfTextFile`).
    @ViewBuilder
    private func statusWord(_ word: String) -> some View {
        let text = Text(word)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        let action = Self.statusWordAction(status: status, offersDiff: onShowWhatChanged != nil,
                                           offersSave: onSaveNow != nil, offersSaveAgain: onSaveAgain != nil)
        if let action, let perform = statusWordPerform(action) {
            // VoiceOver reads the visible words: the button's label is the word itself, and the
            // tooltip says what pressing it does.
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

    /// What pressing the status word does.
    enum StatusWordAction: Equatable {
        /// "not saving — changed on disk": the comparison.
        case showWhatChanged
        /// "unsaved — ⌘S", and "not saving — couldn't write": ⌘S.
        case saveNow
        /// "not saving — no longer on disk": Save Again.
        case saveAgain
    }

    /// Which words are a control, and which stay words. The host hands over only the closures its
    /// stop has a use for, so a stop is never asked twice what it is: "couldn't check the save" gets
    /// none and stays plain, as does "read only".
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

    /// The word's tooltip once it is a control: what pressing it does, or for a failed write the
    /// reason, which the word alone doesn't give.
    static func statusWordHelp(_ action: StatusWordAction, status: EditorSaveStatus, detail: String?) -> String? {
        switch action {
        case .showWhatChanged: return "Show what changed on disk while you were typing"
        case .saveAgain: return EditorDiskBannerView.help(.saveAgain)
        case .saveNow:
            if status == .heldUnsaved { return "Save now — autosave is off for this file" }
            return stopTooltip(status: status, detail: detail)
        }
    }

    /// The ⌘S badge under ⌥, for "unsaved — ⌘S" alone; the stop's words don't name the chord.
    static func statusWordKeycap(_ action: StatusWordAction, status: EditorSaveStatus) -> String? {
        action == .saveNow && status == .heldUnsaved ? AppChord.saveDocument.display : nil
    }

    /// The plain status word's tooltip: the stop's reason, and only on a stop. "not saving —
    /// couldn't write" says a write failed, not why, and the banner that said why has faded.
    /// Read-only and "unsaved — ⌘S" carry none.
    static func stopTooltip(status: EditorSaveStatus, detail: String?) -> String? {
        guard case .stopped = status, let detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// The reserved width of the dot's column, shared by both rows of the header. Named once, as
    /// ``EditorFileRailView/dotColumnWidth`` is, so the two rows can't drift apart.
    static let dotColumnWidth: CGFloat = 10

    // MARK: - The empty page's header

    /// The header with no document open: the same card, saying so, and naming where a new file
    /// would go. First entry into Edit, and every close, land here.
    ///
    /// The same two rows at the same heights as a document's, so the text card below starts where
    /// it always does: the title row reserves the capsule's height with a hidden one, and the meta
    /// row the autosave switch's (``emptyMetaRow``). It offers New Text File
    /// (``newTextFileButton(worded:)``) and no Find, capsule or Close, with nothing to act on.
    /// Expand is drawn only while lit, when it reads "Files" and is the way back to a list; unlit it
    /// would offer to hide a list not yet used. Text ▸ Expand follows the same rule.
    ///
    /// Internal so the tests can render it on its own, like ``headerContent``.
    @ViewBuilder
    var emptyHeaderContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Worded, then bare, the document header's rule: "Files" keeps its word only while the
            // whole title fits beside it.
            ViewThatFits(in: .horizontal) {
                emptyNameRow(chipsWorded: true)
                emptyNameRow(chipsWorded: false)
            }
            emptyMetaRow
        }
    }

    /// One reading of the empty page's title row; see ``emptyHeaderContent``.
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
            // At the end of the row, where a document's header draws it, with the clearance that
            // keeps it apart from New Text File's outset glass.
            if railIsHidden {
                expandButton(worded: chipsWorded)
                    .chromeGlassClearance(.leading, rowSpacing: 6)
            }
            // The capsule's height, reserved as a plain-text header reserves it, and like that one
            // drawn at Solid, so it runs no lens of its own.
            EditorModeBar(mode: $mode, accentFill: accentFill, onAccent: onAccent)
                .environment(\.selectionLensAppearance, .today)
                .hidden()
                .frame(width: 0)
        }
    }

    /// The empty page's button while the list is folded.
    static let showTextFilesTitle = "Show File List"
    /// Its tooltip: one sentence for the empty page and the Recent page, which both draw the button.
    static let showTextFilesHelp = "Show the folder’s text files and PDFs in a list"

    /// What the empty page's header says in place of a file name.
    static let emptyTitle = "No document open"

    /// Where a new file would go, and nothing else: no kind, switch or status word, since there is
    /// no file. The location is where ⌘N and the ＋ create, drawn by the same label as a document's
    /// but with no "·" before it. With no folder the row is empty and keeps its height.
    ///
    /// Its height matches the document meta row's by reserving a hidden, zero-width copy of the
    /// autosave switch's label and track, that row's tallest things; without it the row comes out
    /// 1–2pt short and the title moves between the empty page and an open file.
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

    /// Expand ("Just the text"): hides the file rail and, through the host, collapses the source
    /// pane and the sidebar with it, leaving the document alone in the window. Lit while the rail
    /// bit is set; its word names its next act, "Expand" then "Files". Drawn in Preview too, since
    /// it is about the columns. ⌃⌘E (Text ▸ Expand) on its keycap and tooltip, from one `AppChord`.
    /// One view, drawn by both headers.
    ///
    /// Its own glass capsule in Frosted and Clear, like every header button, 18pt tall worded or
    /// not, so the pinned header height never moves; the word only widens it.
    func expandButton(worded: Bool) -> some View {
        Button(action: onToggleJustTheText) {
            Group {
                if worded {
                    HStack(spacing: 4) {
                        Image(systemName: Self.expandSymbol(railIsHidden: railIsHidden))
                            .scaledFont(.system(size: 10, weight: .semibold))
                        // Laid out at the wider word, so lighting it moves nothing: "Files" sits in
                        // the room "Expand" takes, and the buttons to its left stay put.
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
                    // Never squeezed; the name gives way (``EditorHeaderChipLabel``).
                    .fixedSize()
                } else {
                    Image(systemName: Self.expandSymbol(railIsHidden: railIsHidden))
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            // Label colour lit or not: the soft accent wash is the lit state, and accent words on it
            // read at 2.3:1 on Green. The hover style paints its own wash over it, as a pressed
            // preview.
            .foregroundStyle(.primary)
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

    /// Withheld wherever autosave was never going to write anyway (nothing open, a refusal, a
    /// read-only decode): a switch that changes nothing is worse than none.
    ///
    /// A function rather than a computed property, as
    /// ``EditorFileRailView/dotColour(rowPath:selectedPath:status:accent:)`` is, so the rule can be
    /// asserted without building a workspace. Public because Text ▸ Autosave This File is a second
    /// door onto the same setting and must be withheld by the same rule.
    public static func showsAutosaveSwitch(hasPath: Bool, wasRefused: Bool, isReadOnly: Bool) -> Bool {
        hasPath && !wasRefused && !isReadOnly
    }

    /// Wherever there is text to put on a page: a file read in, whether or not it can be written.
    /// Not on a refusal, which shows a caption and no text view.
    public static func showsPageSwitch(hasPath: Bool, wasRefused: Bool) -> Bool {
        hasPath && !wasRefused
    }

    /// Greyed in Preview, where there is no Source for the page to go under, rather than withheld,
    /// so the location beside it doesn't jump with every mode change.
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

    /// The autosave switch, beside the word whose meaning it changes: a track with a sliding knob,
    /// the shape everybody reads as "on, and I can turn it off".
    ///
    /// Hand-drawn rather than SwiftUI's `Toggle`, as ``EditorModeBar`` is: a native control renders
    /// neutral in this window's glass and ignores `.tint`, so "on" could never carry the accent, and
    /// it won't draw at 11pt beside 10pt text. `.plain`, with no hover affordance: the knob already
    /// says "press me", and a wash behind it would read as a rendering fault.
    @ViewBuilder
    private var autosaveSwitch: some View {
        let isOn = autosavePolicy.isOn(document.path)
        Button {
            guard let path = document.path else { return }
            // Switching it back on writes what is already waiting. The debounce is a `.task(id:)`
            // keyed on the buffer's version, which a setting change doesn't re-fire, so without this
            // the file would stay unwritten until the next keystroke.
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
    /// **The `.onChange` and the `.task` must hang here, outside the branch that draws a
    /// document.** Inside it they wouldn't exist while a file is refused or nothing is open, and
    /// `.onChange` without `initial:` doesn't fire when its branch is rebuilt: after a refused file,
    /// the next Markdown file would show the previous one's headings until the parse finished.
    private func body(for document: EditorDocument) -> some View {
        documentBody(for: document)
            // ⌘Z reaches the document whenever nothing else has the keyboard: after a mode
            // switch, in read-only Preview, over a refusal. Only while a document is open.
            .background {
                if document.path != nil {
                    EditorUndoAnchor(undoManager: undoManager, handle: textViewHandle)
                        .frame(width: 0, height: 0)
                }
            }
            // Cleared synchronously when the file changes, before the debounce: the parse is
            // deliberately late, so without this the new file's name would sit over the old
            // file's headings until it finished.
            .onChange(of: document.path, initial: true) { _, _ in
                blocks = []
                // With the blocks, not after them: the rail shows the outline beside the new file's
                // name, so a stale one would list one file's headings under another's name.
                outline = []
                editorScrollRequest = nil
                previewScrollRequest = nil
                // The status line is seeded from the same anchor the text view is. `caretOffset` is
                // `@State`, so a workspace switch resets it to 0 while `makeNSView` puts the caret
                // at the anchor, and nothing reports that placement (the delegate is wired after
                // it, so construction can't write SwiftUI state). Clamped here, on arrival, where
                // reading the buffer's length is affordable, not in the per-keystroke argument.
                caretOffset = EditorCaretAnchors.clamped(
                    document.caretAnchors.offset(for: document.path) ?? 0, in: document.text)
                // The counts and Line/Col go with the file they were taken for. A move keeps them
                // (same text, new path); otherwise the line holds their room undrawn until this
                // file's land, never derived here, where Line/Col alone would walk the new text.
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
                // Last, after every request above was cleared: a Contents result's match, for the
                // file it was clicked in.
                if let match = pendingContentMatch {
                    pendingContentMatch = nil
                    if match.path == document.path { selectContentMatch(match) }
                }
            }
            // The stored length follows the text view it describes. A mode switch builds a new
            // text view with a bare caret (`PlainTextEditor.restoreCaret`); left stale, the next
            // selection of the same length would leave the key unchanged and the bar unlit.
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
            // Text ▸ Go to Line…: the menu's press opens the status line's field. A standing hint
            // goes first, since the field hangs off the caret it covers; a notice gives way by
            // itself while the field is up.
            .onChange(of: goToLineRequest) { _, _ in
                guard offersGoToLine else { return }
                statusHint = nil
                goToLineShown = true
            }
            // A preview a mode switch builds opens where the caret is, not on a stale heading
            // request. On `mode`, the reader's own choice, not `resolvedMode`, which also moves when
            // a Markdown file opens after a plain one while `caret` still holds the old line.
            //
            // Not for the editable Preview, which opens at the caret already
            // (`initialSourceOffset`): the request would arrive after it was built and move the
            // caret to the start of its block.
            .onChange(of: mode) { _, _ in
                guard !(resolvedMode == .preview && editsInPreview) else { return }
                scrollToken &+= 1
                previewScrollRequest = EditorScrollRequest(line: caret.line, token: scrollToken)
            }
            // The 256 KB decision, taken at the moments its key names and held between them (see
            // ``PreviewLengthHold``). Initial, so a note is decided as it arrives.
            .onChange(of: previewLengthKey, initial: true) { _, key in
                let length = buffer.source.textStorage.length
                let hold = PreviewLengthHold(key: key, isTooLong: PreviewEditToggle.isTooLong(length: length))
                previewLengthHold = hold
                onPreviewLengthHold?(hold)
                if hold.isTooLong, offersPreviewEditing, key.editing {
                    Logger.shared.info(PreviewEditToggle.tooLongLog(length: length))
                }
            }
            // The intro, the first time Preview becomes editable: by the pill, by Text ▸ Edit in
            // Preview, or by switching to Preview with the setting on. Seen once shown, however it
            // is closed.
            .onChange(of: editsInPreview) { _, editable in
                // A follow belongs to the Preview that led it. Left standing, it would be handed to
                // a later Source and jump it to a line scrolled to long before.
                if !editable { editorFollowRequest = nil }
                if PreviewEditToggle.showsIntro(turningOn: editable, introSeen: editsInPreviewIntroSeen) {
                    showsPreviewEditIntro = true
                    editsInPreviewIntroSeen = true
                }
            }
            // The re-render is debounced and the parse is off the main actor. Keyed on the version
            // counter, not the text: `.task(id:)` compares its id every render pass, and comparing a
            // 4 MiB buffer per keystroke would cost more than the parse. The sleep is the debounce:
            // a new keystroke cancels this task before it wakes, so a burst parses once.
            .task(id: EditorParseKey(version: document.textVersion, path: document.path)) {
                guard document.isMarkdown else {
                    // Only when there is something to clear: this task restarts on every keystroke,
                    // and writing an empty array into `@State` counts as a change and costs a body
                    // pass each time.
                    if !blocks.isEmpty { blocks = [] }
                    return
                }
                // Cancelled by the next keystroke. Not for a file just opened (its blocks were
                // cleared): nobody is typing, and the status line's heading would arrive late and
                // push the counts sideways.
                if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let source = document.text
                let path = document.path
                parseTickets.started &+= 1
                let ticket = parseTickets.started
                let parsed = await Task.detached(priority: .userInitiated) {
                    MarkdownBlocks.blocks(from: source)
                }.value
                // Landed even when a keystroke cancelled this task mid-parse: a finished parse is
                // newer than what is on screen, unless a later one landed or the file changed.
                // Otherwise steady typing in a long note would keep the outline frozen at the text
                // before the first keystroke.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: parseTickets.shown) else { return }
                parseTickets.shown = ticket
                blocks = parsed
                // Derived here rather than in a body pass: it is a walk of every block, and a body
                // pass happens on every keystroke.
                outline = MarkdownOutline.entries(from: parsed)
            }
            // The status line's own task, on the same debounce for the same reason: counts walk the
            // whole buffer. Keyed on the version counter like the parse, and not on the caret,
            // which would re-count on every arrow key.
            .task(id: EditorParseKey(version: document.textVersion, path: document.path)) {
                // No debounce for a file's first count, which isn't on screen yet and has nobody
                // typing; only the first (``EditorFirstCountGate``).
                guard await factsGate.settle(open: document.path, countedFor: factsPath,
                                             debounce: .milliseconds(150)) else { return }
                let source = document.text
                let path = document.path
                let version = document.textVersion
                let encoding = document.encodingName
                countTickets.started &+= 1
                let ticket = countTickets.started
                // The line table is built in the same detached pass, the same walk of the same
                // buffer, rather than on the main actor per scroll tick. See ``EditorLineIndex`` for
                // what accepts a stale one.
                let derived = await Task.detached(priority: .utility) {
                    (facts: EditorDocumentFacts.of(source, encoding: encoding),
                     lines: EditorLineIndex(text: source))
                }.value
                // Landed even when a keystroke cancelled this task, by the parse's rule: a finished
                // count of this file is a keystroke old at worst, and dropping them would leave the
                // line countless while typing continues.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: countTickets.shown) else { return }
                countTickets.shown = ticket
                facts = derived.facts
                lineIndex = derived.lines
                factsVersion = version
                factsPath = path
            }
            // The caret is its own key, because it moves without the text changing, and the text
            // changing moves it too, hence the version as well as the offset.
            .task(id: EditorCaretKey(version: document.textVersion, path: document.path,
                                     offset: caretOffset)) {
                // A file's first caret starts at once, as its first count does, asked only by a task
                // still running, since the arrival's own caret write restarts this one.
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
                // Landed by the same rule, for the same reason: a keystroke old at worst.
                guard EditorParseLanding.lands(ticket: ticket, takenOn: path, current: document.path,
                                               shown: caretTickets.shown) else { return }
                caretTickets.shown = ticket
                caret = position
                caretPath = path
            }
            // The selection's counts and the format bar's lit state, derived beside this view
            // rather than in it, so a drag's ticks re-render only what derives them.
            .background {
                EditorSelectionDerivations(document: document, live: liveSelection,
                                           version: document.textVersion, path: document.path,
                                           caretOffset: caretOffset, facts: facts, factsVersion: factsVersion,
                                           mode: resolvedMode, showsFormatBar: showsFormatBar,
                                           selectionFacts: $selectionFacts, formatState: $formatState)
            }
    }

    /// This view with every setting it reads and writes taken from `store`, for tests only.
    ///
    /// Not `.defaultAppStorage`: a test reads ``headerContent`` off a view in no hierarchy, where
    /// `@AppStorage` falls back to the standard domain, which under `swift test` is shared by every
    /// test process on the machine. A store given here is read mounted or not.
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

    /// Whether the format bar is drawn over this document; see
    /// ``EditorFormatBar/isShown(preference:hasDocument:isRefused:isMarkdown:isReadOnly:mode:previewEditing:)``.
    /// A file that turns read-only under the bar keeps it, greyed (``formatBar``), so the text
    /// doesn't jump 35pt under the pointer. One opened read-only draws none.
    private var showsFormatBar: Bool {
        EditorFormatBar.isShown(preference: showsFormatBarPreference,
                                hasDocument: document.path != nil,
                                isRefused: document.refusal != nil,
                                isMarkdown: document.isMarkdown,
                                isReadOnly: document.isReadOnly && !document.becameReadOnlyInPlace,
                                mode: mode,
                                previewEditing: editsInPreview)
    }

    /// Whether Preview is the editable one, for this document now; see
    /// ``editsInPreview(preference:hasDocument:isRefused:isMarkdown:isReadOnly:mode:isTooLong:)``.
    private var editsInPreview: Bool {
        Self.editsInPreview(preference: editsInPreviewPreference, hasDocument: document.path != nil,
                            isRefused: document.refusal != nil, isMarkdown: document.isMarkdown,
                            isReadOnly: document.isReadOnly, mode: resolvedMode,
                            isTooLong: previewIsTooLong)
    }

    /// What the 256 KB decision is held for; see ``PreviewLengthHold``.
    private var previewLengthKey: PreviewLengthHold.Key {
        PreviewLengthHold.Key(path: document.path, mode: resolvedMode, editing: editsInPreviewPreference)
    }

    /// Too long to edit in Preview, held since Preview was opened for this note.
    private var previewIsTooLong: Bool {
        PreviewLengthHold.isTooLong(previewLengthHold, key: previewLengthKey) { buffer.source.textStorage.length }
    }

    /// What re-derives the caret: a new position, or the text moving under a position that did not.
    private struct EditorCaretKey: Equatable {
        var version: Int
        var path: String?
        var offset: Int
    }

    /// Whether a refusal is the one for a file still in the cloud, which a Download answers.
    /// `BoundedTextRead`'s own sentence, read from there so a rewording can't split them.
    static func isNotDownloaded(_ refusal: String?) -> Bool {
        refusal != nil && refusal == BoundedTextRead.Outcome.cloudOnly.caption
    }

    @ViewBuilder
    private func documentBody(for document: EditorDocument) -> some View {
        if let refused = document.refusal {
            // The file could not be opened: `BoundedTextRead`'s own prose, written for a reader.
            // Under it, what can still be done: a file still in the cloud gets Download (the host
            // opens it when it arrives), one that kept changing gets Try Again, and every one gets
            // Quick Look and Reveal in Finder.
            if let path = document.path {
                caption(refused, refusalButtons: Self.refusalButtons(for: refused, canTryAgain: onTryAgain != nil),
                        path: path)
            } else {
                caption(refused)
            }
        } else if document.path == nil {
            Group {
                if let recentFiles, let onOpenRecent {
                    // The files Edit opened last, and New Text File, or with none remembered the one
                    // sentence below.
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
            // The whole page takes a drop from Finder, not just the list or the sentence.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                Self.takesDrop(urls, onDropFiles: onDropFiles)
            }
        } else {
            surfaces(for: EditorMode.resolved(mode, isMarkdown: document.isMarkdown))
                // Over the text's foot, not above it (see ``EditorDiskBannerView``), sticky until
                // answered; the text views take ``diskBannerInset`` at their bottom. The read-only
                // note floats there too, above the disk banner, so a file turning read-only
                // mid-session doesn't push the format bar and every line down under the pointer.
                .overlay(alignment: .bottom) {
                    if document.readOnlyReason != nil || diskBanner != nil {
                        VStack(spacing: Self.diskBannerMargin) {
                            if let reason = document.readOnlyReason {
                                EditorReadOnlyNoteView(reason: reason)
                            }
                            if let diskBanner {
                                EditorDiskBannerView(banner: diskBanner, name: document.name,
                                                     canSaveAgain: !document.isReadOnly, onAction: onDiskBanner)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { diskBannerHeight = $0 }
                        .padding(Self.diskBannerMargin)
                    }
                }
        }
    }

    /// The disk banner's margin from the text card's edges and the status line under it.
    static let diskBannerMargin: CGFloat = 8

    /// How far the text views scroll past their last line while the floating cards stand (the
    /// read-only note and the disk banner, stacked): their height and both margins, so the last
    /// line can rise clear of them. None without one.
    static func diskBannerInset(bannerHeight: CGFloat, isShown: Bool) -> CGFloat {
        isShown ? bannerHeight + 2 * diskBannerMargin : 0
    }

    private var diskBannerInset: CGFloat {
        Self.diskBannerInset(bannerHeight: diskBannerHeight,
                             isShown: (diskBanner != nil || document.readOnlyReason != nil) && document.refusal == nil)
    }

    /// Hands a drop on the empty page to the host, files only: a web address dragged from a browser
    /// is a URL too. False, refusing the drop, when nothing in it is a file or nothing takes it.
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

    /// What re-parses the preview, as one value: a new version or a different file. The path is
    /// cheap insurance, keeping the key's meaning "the thing being previewed", not "the buffer".
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

    /// Preview: the editable one when Edit in Preview is on, the read-only one otherwise, with the
    /// pill that switches them in its top-trailing corner wherever it is offered.
    @ViewBuilder
    private func previewColumn(inSplit: Bool) -> some View {
        VStack(spacing: 0) {
            // The pill's row: the bar's, when one is drawn over this Preview, or the pill's own,
            // never over the text. The pill ends the bar's row rather than covering its last
            // buttons, and the bar sheds words to fit. In Split the bar stays over Source's half.
            //
            // One row and one pill in both layouts, the bar coming and going in the `if` beside
            // it, so turning editing on moves only the bar and the pill keeps the intro's state.
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
                                      // In Split too: the status line, the bar's lit state and
                                      // what the bar presses follow the half the caret is in, and
                                      // Preview reopens at the caret typed at in its half. Preview
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
                          accent: accent,
                          isTooLong: previewIsTooLong)
    }

    /// Whether Preview is the editable one: the setting on, and a document the pill is offered for,
    /// a writable Markdown file in Preview and nothing else (a `.txt` has no Preview to type into).
    /// Not over ``PreviewEditToggle/maximumLength``, `isTooLong` as ``PreviewLengthHold`` holds it.
    public static func editsInPreview(preference: Bool, hasDocument: Bool, isRefused: Bool, isMarkdown: Bool,
                                      isReadOnly: Bool, mode: EditorMode, isTooLong: Bool) -> Bool {
        preference && PreviewEditToggle.isOffered(hasDocument: hasDocument, isRefused: isRefused,
                                                  isMarkdown: isMarkdown, isReadOnly: isReadOnly, mode: mode)
            && !isTooLong
    }

    /// Says "That change needs Source." for ``EditorStatusHint/duration``, restarted by each refusal.
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

    /// Who is told where the text has scrolled to: nobody, outside `.split`. The gate is here rather
    /// than inside `followTheText`, because the cost is working out which line is on top, done
    /// before anything could decline the answer.
    private var visibleLineReporter: ((Int) -> Void)? {
        guard Self.followsVisibleLine(mode) else { return nil }
        return { line in followTheText(line) }
    }

    /// Whether anything is following where the text has scrolled to. A named rule because it is
    /// the gate: only the split mounts a preview beside the text, and elsewhere finding the topmost
    /// visible line on every clip-view bounds change would be thrown away.
    ///
    /// The unresolved mode, deliberately, so it agrees with ``followTheText``, which asks the same
    /// unresolved question; asking different ones would let the two halves disagree about whether
    /// they are a split.
    static func followsVisibleLine(_ mode: EditorMode) -> Bool { mode == .split }

    /// The text, under the format bar when it is drawn; in Split, the Source half alone. The bar is
    /// a sibling above the text view, not an overlay, so the text never scrolls under a control, and
    /// an `if` beside an unconditional editor, so toggling it keeps the text view's identity, caret,
    /// scroll and undo.
    private var sourceColumn: some View {
        VStack(spacing: 0) {
            if showsFormatBar { formatBar }
            editorSurface
        }
    }

    /// The format bar, over Source or over an editable Preview: whichever text view the handle holds.
    private var formatBar: some View {
        EditorFormatBar(state: formatState.lighting(barActsOnPreview ? previewPending : []), accent: accent,
                        showsLabels: formatBarShowsLabels,
                        onVerb: { verb in textViewHandle.applyMarkup(verb) })
            .equatable()
            // Greyed over a file that turned read-only under it (``showsFormatBar``).
            .disabled(document.isReadOnly)
            // On the bar itself, so a right-click on the text keeps the text view's menu.
            .contextMenu {
                EditorFormatBarMenu(showsLabels: $formatBarShowsLabels,
                                    showsBar: $showsFormatBarPreference)
            }
            .padding(.horizontal, Self.formatBarInset)
            .padding(.top, Self.formatBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the bar acts on editable Preview now (Preview alone, or Split's Preview half while
    /// the caret was last there), and so lights Preview's pending styles.
    private var barActsOnPreview: Bool {
        editsInPreview && (resolvedMode == .preview || textViewHandle.targetsSplitPreview)
    }

    /// The format bar's inset from the text card's edges: the bar is a strip in the card, and the
    /// text view's own 14pt container inset sits under it.
    static let formatBarInset: CGFloat = 6

    private var editorSurface: some View {
        PlainTextEditor(source: buffer.source,
                        isEditable: !document.isReadOnly,
                        fontScale: fontScale,
                        documentID: document.path,
                        undoManager: undoManager,
                        // Two writes, only one of which announces anything: `caretOffset` drives
                        // the status line's Line/Col, and the anchor is a plain reference on the
                        // document that re-renders nobody (`EditorCaretAnchors` says why it may not
                        // publish). Written here, not in `.onDisappear`, which would depend on
                        // teardown order.
                        onSelectionChange: {
                            // Split: the caret is in Source's half now. An edit in Preview's half
                            // nudges this selection too, but Preview reports after it, so the caret
                            // typed at is the one kept.
                            textViewHandle.caretInSplitPreview = false
                            caretOffset = $0.location
                            // Always, bar or no bar: the status line counts the selection. Into the
                            // box, not this view's state, so a forward drag's ticks redraw nothing
                            // here.
                            liveSelection.set(length: $0.length)
                            document.caretAnchors.remember($0.location, for: document.path)
                        },
                        onSelectionRangeCount: { liveSelection.set(rangeCount: $0) },
                        scrollRequest: editorScrollRequest,
                        // Where the caret goes when this text view is built, as on arrival back from
                        // another workspace; clamped by `restoreCaret`. After `scrollRequest`, the
                        // memberwise init's order, which is also the precedence: a scroll request
                        // lands in `updateNSView`, after `makeNSView`, and overwrites this.
                        initialSelection: document.caretAnchors.offset(for: document.path) ?? 0,
                        onVisibleLineChange: visibleLineReporter,
                        lineIndex: lineIndex,
                        findRequest: findRequest,
                        // Withheld on a file that cannot be written: a Markup menu there would be a
                        // promise the document can't keep.
                        offersMarkup: !document.isReadOnly,
                        editsMarkdown: document.isMarkdown,
                        imageImport: imageImporter,
                        followRequest: editsInPreview ? editorFollowRequest : nil,
                        textViewHandle: textViewHandle,
                        bottomInset: diskBannerInset)
    }

    /// Where a dropped or pasted image goes: only for a Markdown note that can be written, and only
    /// when the host is listening (``onImagesImported``).
    private var imageImporter: EditorImageImporter? {
        guard let onImagesImported, let path = document.path, document.isMarkdown,
              !document.isReadOnly, document.refusal == nil else { return nil }
        return EditorImageImporter(notePath: path, report: onImagesImported)
    }

    /// Sends both surfaces to a heading, whichever mode is showing: a request to an unmounted
    /// surface costs nothing, and choosing would need the mode, the file kind and the focused half.
    ///
    /// To where the heading is now: the outline lags the typing, so an entry can name the line its
    /// heading used to be on, and `MarkdownOutline.line(of:in:)` finds it in the current text.
    private func goToHeading(_ entry: MarkdownOutlineEntry) {
        let line = MarkdownOutline.line(of: entry, in: document.text)
        scrollToken &+= 1
        let request = EditorScrollRequest(line: line, token: scrollToken)
        editorScrollRequest = request
        previewScrollRequest = request
        // In Preview there is no text view to move the caret, so the status line's "in <heading>"
        // and the rail's mark would keep naming the old place. The caret goes there itself, with
        // its anchor, which is also where Source puts it when it comes back.
        if resolvedMode == .preview,
           let offset = PlainTextEditor.utf16Offset(ofLine: line, in: document.text, using: lineIndex) {
            let clamped = EditorCaretAnchors.clamped(offset, in: document.text)
            caretOffset = clamped
            document.caretAnchors.remember(clamped, for: document.path)
        }
    }

    /// Esc in the rail's lists: the keys back to the document. `nil` with nothing open, where Esc
    /// is left to whoever is next.
    private var railReturnKeys: (() -> Void)? {
        guard pdf != nil || document.path != nil else { return nil }
        return { returnKeysToDocument() }
    }

    /// A PDF's pages take the keys through their own request. Text goes to the text view the caret
    /// was last in; where there is none (read-only Preview) the window is left holding them, and
    /// ``EditorUndoAnchor`` takes them from there, as after a mode switch.
    private func returnKeysToDocument() {
        if let pdf {
            pdf.view.requestFocus()
        } else if let text = textViewHandle.target, let window = text.window {
            window.makeFirstResponder(text)
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// Opens a Contents result through the rail's own door, so the unsaved-document question and
    /// the pane's selection are the ones a click on a row gets.
    ///
    /// - A text file opens at the match, selected, with Find holding the word (Source and Split),
    ///   or in Preview scrolled to its line, since a rendered page has no line to select.
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
            // A file that was already open (or refused and read again under the same path) has no
            // arrival to wait for.
            if before == hit.path { selectContentMatch(match) } else { pendingContentMatch = match }
        }
    }

    /// Sends Source to a Contents match, selected and handed to Find, or Preview to its line.
    private func selectContentMatch(_ match: EditorContentMatch) {
        guard document.refusal == nil, let path = document.path else { return }
        let target = EditorContentMatch.located(match, in: document.text, using: lineIndex)
        // The caret's anchor first, as a heading jump in Preview moves it, so a text view built
        // later (Preview to Source) opens at the match.
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

    /// The PDF result's word, into the PDF's find, once the PDF open is the one clicked and only if
    /// it opened: a refused PDF has no pages to search.
    private func seedPendingPDFFind() {
        guard let match = pendingPDFFind, let pdf, pdf.path == match.path else { return }
        pendingPDFFind = nil
        guard pdf.refusal == nil else { return }
        pdf.find.search(match.word)
        pdf.find.show()
    }

    /// Ticking a checkbox from the preview, or `nil` when this document must not be written to:
    /// `nil` rather than a closure that declines, so a read-only file never draws a checkbox that
    /// highlights and then does nothing.
    private var taskToggle: ((Int) -> Void)? {
        guard !document.isReadOnly, document.refusal == nil else { return nil }
        return { line in
            Self.toggleTask(onLine: line, in: buffer.source, undoManager: undoManager)
        }
    }

    /// Ticks or unticks the checkbox on a 1-based source line, as a step ⌘Z can take back.
    ///
    /// **Never** write the whole buffer for this: the undo stack wouldn't hear of it, and every
    /// range it holds would point into moved text. Only the box's character changes, through
    /// `EditorSourceStorage.replace` on the document's own stack, which also converts carriage
    /// returns to LF in the same step. A stale click (no checkbox on the line) changes nothing.
    ///
    /// Measured against the storage's characters, not the published text, which can differ by a
    /// word being composed in Split. Read through `mutableString`, since `textStorage.string`
    /// copies the whole document to look at one line.
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

    /// The Undo item's word for a tick: Edit ▸ Undo Checkbox, whichever way it went.
    static let taskActionName = "Checkbox"

    /// The folder the open document lives in, which a relative image path resolves against. The
    /// document's folder, not the rail's, which can differ, and through a symlink the real file's
    /// folder, where the note is saved and its pasted images go
    /// (``EditorImageImport/linkFolder(ofNote:)``).
    private var documentFolder: String? {
        document.path.map(EditorImageImport.linkFolder(ofNote:))
    }

    /// A `#heading` link inside the document, followed rather than opened. Nothing happens when no
    /// heading matches: the anchor convention is GitHub's, not a standard, and a near-miss should
    /// not scroll somebody somewhere they didn't ask to go.
    private func followAnchor(_ fragment: String) {
        guard let line = MarkdownOutline.line(forAnchor: fragment, in: outline) else { return }
        scrollToken &+= 1
        previewScrollRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// Keeps the preview level with the text, in split only. The text drives and the read-only
    /// preview follows; with Preview editable the two lead in turn, and ``SplitScrollFollow`` drops
    /// each one's echo so the sync doesn't judder.
    private func followTheText(_ line: Int) {
        guard mode == .split else { return }
        // The echo of Preview leading is dropped: with Preview editable, it scrolls too.
        guard splitFollow.shouldFollow(from: .source) else { return }
        scrollToken &+= 1
        previewScrollRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// Split, Preview editable: Source follows Preview the way Preview follows Source, by line, the
    /// view only, and never the echo of its own lead.
    private func followThePreview(_ line: Int) {
        guard mode == .split, splitFollow.shouldFollow(from: .preview) else { return }
        scrollToken &+= 1
        editorFollowRequest = EditorScrollRequest(line: line, token: scrollToken)
    }

    /// The name of the row's own coordinate space, which the drag reads positions in.
    ///
    /// **A fixed space, never `.local`**, the rule `ResizeHandle` states for every seam: the strip
    /// is offset by the divider's position, so it moves as it is dragged, and a local x would be
    /// measured against a frame following the pointer.
    private static let splitSpace = "editorSplit"

    private func splitHandle(width: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: 12)
            // `.pointerStyle`, not an `NSCursor.push()`/`pop()` pair, which leaks a pushed cursor
            // whenever `onHover(false)` isn't delivered (every time the view goes away under the
            // pointer). `.columnResize` matches every other seam in the window.
            .pointerStyle(.columnResize)
            .gesture(
                // `minimumDistance: 1`, matching every other seam: at a narrow window the divider's
                // whole travel is about 20pt, and the default 10pt dead zone would take half.
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
                    // A double-click puts it back in the middle, where Split starts, as a
                    // double-click on a column seam fits it; beside the drag, not instead.
                    .simultaneously(with: TapGesture(count: 2).onEnded {
                        splitDrag = nil
                        splitFraction = EditorLayoutMetrics.splitStart
                    })
            )
            .accessibilityHidden(true)
    }

    /// - Parameter showTextFiles: draws Show Text Files under the words, the empty page's way to the
    ///   list while it is folded into the strip, which a first session opens into.
    /// - Parameter refusalButtons: the buttons drawn under the words for a refused file
    ///   (``refusalButtons(for:canTryAgain:)``), acting on `path`.
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
                .buttonWordsTint(accent)
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
        .buttonWordsTint(tinted ? accent : nil)
        .help(button.help)
    }

    /// What a refusal offers under its caption.
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

    /// The buttons under a refusal, in order: what would let Edit open it first (Download for a file
    /// still in the cloud, Try Again for one that kept changing while read), then Quick Look and
    /// Reveal in Finder, for every file Edit can't open.
    static func refusalButtons(for refusal: String, canTryAgain: Bool) -> [RefusalButton] {
        var buttons: [RefusalButton] = []
        if isNotDownloaded(refusal) { buttons.append(.download) }
        if canTryAgain, refusal == EditorFileStore.keptChangingReason { buttons.append(.tryAgain) }
        return buttons + [.quickLook, .revealInFinder]
    }
}

extension EditorWorkspaceView {
    /// Download, under a refusal for a file still in the cloud: the text card's and the PDF card's,
    /// one view, with Browse's word and glyph.
    static let downloadTitle = "Download"
    static let downloadHelp = "Download this file from the cloud, then open it here"

    static func downloadButton(accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(downloadTitle, systemImage: "icloud.and.arrow.down")
                .scaledFont(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .buttonWordsTint(accent)
        .help(downloadHelp)
    }
}

/// The oval track and its sliding knob: the switch shape, without the button around it. Its own
/// view so a test can measure it: on the one-line meta row of a column as narrow as 260pt, a switch
/// that grew faster than its words would push the status word out.
struct AutosaveSwitchTrack: View {

    let isOn: Bool
    /// The on track's fill: the deepened accent, as every solid accent surface takes.
    let fill: Color

    @Environment(\.appFontScale) private var scale

    /// The track's height at the default text size, and the point size of the text beside it.
    /// Scaled through `FontSize.scaledBox`, not a bare multiply, so the switch follows the words'
    /// ramp, knee included, instead of outgrowing its line. Same rule as ``CapsuleGlyph``.
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
                    // An offset rather than a change of alignment: a layout change doesn't
                    // interpolate, while an offset animates, so the knob slides.
                    .offset(x: isOn ? width - height : 0)
            }
            // Through the house helper, so Reduce Motion turns the slide off; a repo-wide scan in
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

/// The parses a workspace has started, and the one whose blocks are on screen; the same for its
/// counts and its caret.
final class EditorParseTickets {
    var started = 0
    var shown = 0
}

/// Whether a finished parse goes on screen: taken of the file still open, and started after the one
/// on screen. A keystroke during the parse is no reason to drop it, since its text is newer than
/// what is drawn, but an older parse must not put old blocks back, nor another file's land here.
/// The status line's counts and caret land by the same rule.
enum EditorParseLanding {
    static func lands(ticket: Int, takenOn path: String?, current: String?, shown: Int) -> Bool {
        path == current && ticket > shown
    }
}
