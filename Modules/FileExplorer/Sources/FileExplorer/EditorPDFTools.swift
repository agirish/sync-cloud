import AppKit
import Combine
import Events
import os
import PDFToolkitCore
import Sync

/// What the app does around a tool's copy: the half of a run that needs the window.
public struct EditorPDFToolHost {
    /// A copy landed at this path: the rail and the panes re-list (Export as PDF's follow-up).
    public var didWrite: (String) -> Void
    /// The banner's Open: the copy in Edit, through the same door a rail click takes.
    public var open: (String) -> Void
    /// The banner's Reveal in Browse.
    public var reveal: (String) -> Void
    /// Download, for a file only in the cloud now: Edit's own, which works for every provider.
    public var download: (String) -> Void

    public init(didWrite: @escaping (String) -> Void = { _ in },
                open: @escaping (String) -> Void = { _ in },
                reveal: @escaping (String) -> Void = { _ in },
                download: @escaping (String) -> Void = { _ in }) {
        self.didWrite = didWrite
        self.open = open
        self.reveal = reveal
        self.download = download
    }
}

/// What a run says once it is over, at the top of the PDF card.
public struct EditorPDFToolBanner: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A copy was written at this path; the banner offers Open and Reveal in Browse.
        case wrote(String)
        /// A batch from a pane's menu wrote these copies; its banner offers Reveal in Browse.
        case wroteSeveral([String])
        /// Nothing went wrong and nothing was written: "already about as small as this gets".
        case note
        case failure
    }
    public let id = UUID()
    public var message: String
    public var kind: Kind
    /// A second line under the sentence: a batch names each file it skipped or failed, and why.
    public var detail: String?
    /// A file only in the cloud now: the banner offers Download for it.
    public var download: String?
}

/// How a run ended: what a sheet needs to decide whether to close.
public enum EditorPDFToolOutcome: Equatable, Sendable {
    case wrote(String)
    /// Ran (or decided not to run) and wrote nothing, for a reason that is not a failure.
    case nothingWritten(String)
    case cancelled
    /// The reader turned the fidelity confirmation down.
    case declined
    case failed(String)
}

/// The sheet the header or the Pages tab asked for.
public enum EditorPDFToolSheet: Identifiable, Equatable, Sendable {
    case pages(EditorPDFPageAction, prefill: String)
    case compress
    case metadata
    case protect
    case removePassword

    /// The sheet's own title, as the leave question names it.
    public var title: String {
        switch self {
        case .pages(.extract, _): return "Extract Pages"
        case .pages(.delete, _): return "Delete Pages"
        case .compress: return "Compress"
        case .metadata: return "Clean Metadata"
        case .protect: return "Protect with Password"
        case .removePassword: return "Remove Password"
        }
    }

    public var id: String {
        switch self {
        case .pages(let action, _): return "pages-\(action)"
        case .compress: return "compress"
        case .metadata: return "metadata"
        case .protect: return "protect"
        case .removePassword: return "remove-password"
        }
    }
}

public enum EditorPDFPageAction: String, Sendable {
    case extract
    case delete
}

/// The Pages tab's selection: click, ⌘-click and ⇧-click over the pages as shown, which during a
/// pending reorder is not page order.
public struct EditorPDFPageSelection: Equatable, Sendable {
    public private(set) var pages: Set<Int> = []
    /// Where ⇧-click extends from.
    public private(set) var anchor: Int?

    public enum Click: Sendable { case plain, toggle, extend }

    public static func click(for flags: NSEvent.ModifierFlags) -> Click {
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }

    /// `order` is the pages as shown, zero-based page indices.
    public mutating func click(_ page: Int, _ click: Click, order: [Int]) {
        switch click {
        case .plain:
            pages = [page]
            anchor = page
        case .toggle:
            if pages.contains(page) { pages.remove(page) } else { pages.insert(page) }
            anchor = page
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: page) else {
                pages = [page]
                self.anchor = page
                return
            }
            pages.formUnion(order[min(from, to)...max(from, to)])
        }
    }

    public mutating func clear() {
        pages = []
        anchor = nil
    }

    /// ⌘A in the Pages tab.
    public mutating func selectAll(_ order: [Int]) {
        pages = Set(order)
        anchor = order.first
    }

    /// The pages a menu on `page` acts on: the selection when the page is in it, else that page.
    public func target(for page: Int, order: [Int]) -> [Int] {
        guard pages.contains(page) else { return [page] }
        return order.filter(pages.contains)
    }
}

/// A reorder the reader has dragged and not saved: the pages in their new order.
public enum EditorPDFArrangement {
    /// `moving` dropped onto `target`: they take its place, after it when dragged forward and
    /// before it when dragged back, as a dragged row lands in a Finder list.
    public static func moving(_ moving: [Int], onto target: Int, in order: [Int]) -> [Int] {
        let moved = order.filter(Set(moving).contains)
        guard !moved.isEmpty, !moved.contains(target),
              let first = order.firstIndex(of: moved[0]), let targetAt = order.firstIndex(of: target)
        else { return order }
        var rest = order.filter { !moved.contains($0) }
        guard let inRest = rest.firstIndex(of: target) else { return order }
        rest.insert(contentsOf: moved, at: first < targetAt ? inRest + 1 : inRest)
        return rest
    }

    /// `page` one place earlier (`step` −1) or later (+1): VoiceOver's way to reorder without a
    /// drag. Unchanged at either end.
    public static func stepping(_ page: Int, by step: Int, in order: [Int]) -> [Int] {
        guard let at = order.firstIndex(of: page), order.indices.contains(at + step) else { return order }
        var next = order
        next.swapAt(at, at + step)
        return next
    }
}

/// Edit's PDF tools: the selection, a pending reorder, a run, and what it said. A sibling of
/// ``EditorPDFViewState`` on ``EditorPDFDocument``, observed by the header's Tools menu, the Pages
/// tab and the card's banner, and by nothing that redraws the window.
///
/// Every tool writes a new copy and never touches the open file, so nothing here registers undo
/// (as Export as PDF and ⌘N don't): a copy destroys nothing, and removing it is an ordinary Trash.
/// The open file stays open and read-only; opening the copy is the reader's choice, from the
/// banner.
@MainActor
public final class EditorPDFTools: ObservableObject {

    /// The file the tools act on (the reader's), or `nil` with nothing open.
    public private(set) var path: String?
    /// The file as the reader last read it, set by ``EditorPDFDocument`` with each load. A run reads
    /// the file afresh, so after a change on disk not yet reloaded it would write from pages nobody
    /// was shown: Fill & Sign's items by the old pages' boxes, Rotate's pages by the old numbering.
    /// `nil` (a pane's run, with no reader) checks nothing.
    var shownStamp: EditorFileStore.Stamp?
    @Published public private(set) var pageCount = 0
    /// How the file on disk is protected, read in the lane when it opened. `nil` until then.
    @Published public private(set) var encryption: PDFEncryptionState?
    /// What this file has that a rebuilding tool's copy doesn't keep: tags for screen readers,
    /// layers, colour output intent. Each copy keeps page labels, viewer settings, language and
    /// attached files; these go, and the tool says so (``droppedPartsNote``). Empty while the file
    /// is locked, since its catalog can't be read.
    @Published public private(set) var droppedParts: [PDFToolkit.DroppedCatalogPart] = []
    @Published public private(set) var selection = EditorPDFPageSelection()
    /// A dragged order not yet saved, or `nil`. Never the identity: a drag back to where the pages
    /// were is no arrangement.
    @Published public private(set) var arrangement: [Int]?
    /// The run in flight, or `nil`; one at a time.
    @Published public private(set) var running: Running?
    @Published public var sheet: EditorPDFToolSheet?
    /// Copied to the log as it is shown, as `FileSyncManager.banner` is: what the reader saw is a
    /// record of its own beside the tool's lines. A failure at WARN, anything else at INFO; only
    /// the look of a banner is decided by its kind, so this copy never changes how it is drawn.
    @Published public var banner: EditorPDFToolBanner? {
        didSet {
            guard let banner, banner.id != oldValue?.id else { return }
            if case .failure = banner.kind {
                Logger.shared.warning("[pdf banner] \(banner.message)")
            } else {
                Logger.shared.info("[pdf banner] \(banner.message)")
            }
        }
    }

    /// "page N of M" from Compress, as it reached the main actor. Cleared when a run starts and left
    /// on the last page when it ends; shown only while ``running`` is set.
    @Published public private(set) var progress: Progress?

    public struct Running: Equatable {
        /// The tool's title ("Rotate"), for the log.
        public var tool: String
        /// "rotating the pages": ``EditorPDFTool/doing``, for the sentences that name the run.
        public var doing: String
        /// "The pages are still being rotated.": the leave question's.
        public var stillRunning: String
        /// Whether the lane reports pages as it goes; only Compress does.
        public var reportsProgress: Bool
        /// Whether its lane turn has begun. Until then it is waiting behind other PDF work (a
        /// duplicate scan can hold the lane for minutes), and says so rather than that it is busy.
        public var started = false
        /// When it was asked for, which orders it among the window's other runs, newest first.
        public let requestedAt = Date()

        init(_ tool: EditorPDFTool) {
            self.tool = tool.title
            doing = tool.doing
            stillRunning = tool.stillRunning
            if case .compress = tool { reportsProgress = true } else { reportsProgress = false }
        }

        /// "Rotating the pages": ``doing`` at the start of a sentence.
        public var sentence: String { doing.prefix(1).uppercased() + doing.dropFirst() }
    }

    public struct Progress: Equatable, Sendable {
        public var page: Int
        public var total: Int
    }

    /// Set by the app; a no-op otherwise, so a test can run a tool without a window.
    public var host = EditorPDFToolHost()
    /// Fill & Sign's unsaved items are work a leave can lose too, asked about in
    /// ``mayLeave(quitting:thenRetry:)``, which every route out of the PDF asks.
    weak var fill: EditorPDFFillSign?
    /// Who a run's log lines say ran the tool: "Edit" for the reader's own tools; a run from a
    /// pane's menu names its workspace (``PanePDFTools``).
    var writer = "Edit"
    /// Whether the file is only in the cloud now, evicted since it opened. The toolkit opens it by
    /// URL in the lane, and a dataless file downloads synchronously there, blocking every duplicate
    /// scan, so a run refuses it as the open does. Asked again in the lane turn, since a run can
    /// wait there long enough for an eviction.
    var isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    /// Called in the lane before each of Compress's pages, with the run's cancel flag: a test's way
    /// to cancel between two pages without racing the main actor. `nil` in the app.
    var laneProgressHook: (@Sendable (Int, Int, CancelFlag) -> Void)?
    /// Called in the lane as a run's turn begins, before anything is read: a test's way to change
    /// the file while the run waits for the lane. `nil` in the app.
    var laneTurnHook: (@Sendable () -> Void)?
    /// Called on the main actor as the copy's write is handed off: a test's way to cancel or leave
    /// while the bytes are being written, without racing the write.
    var writeStartedHook: (@MainActor () -> Void)?
    /// Called on the main actor with the copy's path once it has landed, before a cancel is looked
    /// at: a test's way to replace the copy before the run would take it back.
    var writeLandedHook: (@MainActor (String) -> Void)?
    /// Called in the lane in place of the toolkit's `fillAndSignData`: a test's way to have it draw
    /// the comments in after all, as it does when it can't keep them. `nil` in the app.
    var fillAndSignHook: EditorPDFToolEngine.FillSigner?
    /// Where a combined run (a tool in the dragged order) keeps its middle bytes, in a folder of its
    /// own that it removes: the temporary folder in the app, a test's own folder in a test.
    var stagingRoot = FileManager.default.temporaryDirectory
    /// Asks whether to go ahead despite `warning`: a native alert in the app, a canned answer in a
    /// test. `toolTitle` is the tool's own title, which `detailLines` names.
    var confirm: @MainActor (OutputFidelityWarning, String) -> Bool = { EditorPDFTools.confirmWithAlert($0, toolTitle: $1) }
    /// Asks whether a pending reorder or a run in flight may be lost; see
    /// ``mayLeave(quitting:thenRetry:)``. Its argument says whether the leave is ⌘Q.
    lazy var confirmDiscardingArrangement: @MainActor (_ quitting: Bool) -> Bool = { [unowned self] in
        self.confirmDiscardWithAlert(quitting: $0)
    }

    /// Where the copy goes when not beside the original, set by a request that chose a folder
    /// (``PanePDFTools/startFromChat(_:path:folder:expecting:writer:allow:completion:)``). `nil`
    /// writes beside the original, as every menu does.
    var destinationFolder: String?
    /// Whether a run's ending is left off ``banner``: for a run a request made, whose asker reads
    /// ``lastReport`` and ``lastWrite`` instead, so the pane doesn't show it a second time.
    var quiet = false
    /// The last ending a run reported, said or not.
    private(set) var lastReport: EditorPDFToolBanner?
    /// The copy the last run wrote, with the stamp of the file the writer created.
    public private(set) var lastWrite: PDFWrittenFile?
    /// What a run says when the file changed since it was read: Edit's sentence, which promises a
    /// reload; a request that read the file itself says its own.
    var changedMessage: (String) -> String = { EditorPDFTools.changedReason($0) }

    private var cancelFlag: CancelFlag?
    private var generation = 0
    /// Every progress report that has reached the main actor, so a test can see it did.
    private(set) var progressReports = 0

    public init() {}

    // MARK: The file

    func attach(path: String, pageCount: Int, encryption: PDFEncryptionState,
                droppedParts: [PDFToolkit.DroppedCatalogPart] = []) {
        if self.path == path {
            // A reload: the file changed on disk. A pending order is dropped whatever the page
            // count, since its pages may now say something else, and that is said. The selection
            // survives while the count does, as the reader's place does.
            if arrangement != nil {
                arrangement = nil
                Logger.shared.info("Edit dropped the new page order of \(Self.logName(path)) — the file changed on disk")
                banner = EditorPDFToolBanner(message: "The file changed on disk, so the new page order was dropped. Drag the pages again to reorder it.",
                                             kind: .note)
            }
            if self.pageCount != pageCount { selection.clear() }
        } else {
            selection.clear()
            arrangement = nil
            banner = nil
            dragToken = UUID()
        }
        self.path = path
        self.pageCount = pageCount
        self.encryption = encryption
        self.droppedParts = droppedParts
    }

    /// The page count and what the copies drop, once a locked file has been unlocked in the reader.
    func update(pageCount: Int, droppedParts: [PDFToolkit.DroppedCatalogPart] = []) {
        self.droppedParts = droppedParts
        guard pageCount != self.pageCount else { return }
        self.pageCount = pageCount
        selection.clear()
        arrangement = nil
    }

    func detach() {
        if let path {
            // Asked about first where it can be (``mayLeave(quitting:thenRetry:)``); logged here
            // either way, since a close from elsewhere (the file deleted, an external open) asks
            // nobody.
            if let running {
                Logger.shared.info("Edit cancelled \(running.tool.lowercased()) of \(Self.logName(path)) — the file was closed")
            }
            if arrangement != nil {
                Logger.shared.info("Edit discarded the new page order of \(Self.logName(path)) — the file was closed")
            }
        }
        generation &+= 1
        cancelFlag?.cancel()
        path = nil
        shownStamp = nil
        pageCount = 0
        encryption = nil
        droppedParts = []
        selection.clear()
        arrangement = nil
        running = nil
        sheet = nil
        banner = nil
    }

    // MARK: What can run

    /// Why only Remove Password is offered for a file locked to open: every toolkit call opens the
    /// file by URL and is refused there, since unlocking it in the reader doesn't unlock the file.
    public static let lockedReason = "Remove the password first. That writes an unlocked copy."
    /// Why Clean Metadata isn't offered on any encrypted file: the toolkit refuses
    /// (`metadataEncrypted`), so it is said up front.
    public static let metadataEncryptedReason = "Password-protected — remove the password to clean metadata"

    /// Whether the page tools, Compress and Protect may run. Restricted-only files are let through:
    /// rebuilding tools work on them, and the in-place ones say why not in the toolkit's words.
    public var offersPageTools: Bool { encryption != nil && encryption != .lockedToOpen && pageCount > 0 }
    public var offersMetadata: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersProtect: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersRemovePassword: Bool { encryption == .lockedToOpen || encryption == .restrictedOnly }

    /// What a copy won't keep, said where the copy is asked for: each sheet whose tool drops them
    /// (``EditorPDFTool/dropsCatalogParts(fileHasForm:osMajor:)``), the reorder bar, and Fill &
    /// Sign's note card. `nil` when the file has none of them.
    public var droppedPartsNote: String? { Self.droppedPartsNote(droppedParts) }

    /// "The copy won’t keep this PDF’s tags for screen readers, layers or colour output intent.",
    /// naming only what the file has.
    static func droppedPartsNote(_ parts: [PDFToolkit.DroppedCatalogPart]) -> String? {
        let names = parts.map { part -> String in
            switch part {
            case .tags: return "tags for screen readers"
            case .layers: return "layers"
            case .outputIntent: return "color output intent"
            }
        }
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "The copy won’t keep this PDF’s \(list)."
    }

    /// The note for a file whose catalog couldn't be read: one still locked to open.
    static let droppedPartsUnreadNote = "The copy won’t keep any tags for screen readers, layers or color output intent."

    /// Why a tool is greyed out, or `nil`: the first line of the Tools menu.
    public var disabledReason: String? {
        encryption == .lockedToOpen ? Self.lockedReason : nil
    }

    // MARK: Selection and the pending reorder

    /// The pages as the Pages tab shows them.
    public var order: [Int] { arrangement ?? Array(0..<pageCount) }

    /// Names this document in a dragged page instead of its path, which another app's text field
    /// would paste. A new one per file, so a page from another PDF is no reorder of this one.
    public private(set) var dragToken = UUID()

    /// Whether the Pages tab takes a drop: a file the tools can rebuild, and no run in flight, since
    /// a drag while the reordered copy saves would be cleared by that save.
    public var acceptsReorder: Bool { offersPageTools && running == nil }

    public func click(_ page: Int, _ click: EditorPDFPageSelection.Click) {
        selection.click(page, click, order: order)
    }

    public func clearSelection() { selection.clear() }

    public func selectAll() { selection.selectAll(order) }

    /// `page` one place earlier or later in the pending order: the accessibility actions' reorder.
    public func step(_ page: Int, by step: Int) {
        guard acceptsReorder else { return }
        let next = EditorPDFArrangement.stepping(page, by: step, in: order)
        arrangement = next == Array(0..<pageCount) ? nil : next
    }

    /// `pages` dropped onto `target` in the Pages tab: a pending order, written nowhere.
    public func move(_ pages: [Int], onto target: Int) {
        guard acceptsReorder else { return }
        let next = EditorPDFArrangement.moving(pages, onto: target, in: order)
        arrangement = next == Array(0..<pageCount) ? nil : next
    }

    /// Back to the file's own order.
    public func resetArrangement() { arrangement = nil }

    /// Whether Delete Pages is offered for `pages` (none, where the sheet asks which, or a
    /// selection). A copy keeps at least one page, so not on a one-page file or with every page
    /// selected. The one rule the Tools menu, the Pages tab's menu and its Delete key ask.
    public func mayDelete(_ pages: [Int]) -> Bool {
        guard offersPageTools, running == nil else { return false }
        return pages.isEmpty ? pageCount > 1 : Set(pages).count < pageCount
    }

    /// The Pages tab's Delete key: the Delete Pages sheet for the selection, under the menus' rule,
    /// so where they grey the item the key does nothing. True when a sheet was asked for.
    @discardableResult
    public func deleteSelectedPages() -> Bool {
        let pages = order.filter(selection.pages.contains)
        guard !pages.isEmpty, sheet == nil, mayDelete(pages) else { return false }
        sheet = .pages(.delete, prefill: EditorPDFPageMenu.rangeText(pages))
        return true
    }

    /// Whether leaving the file would lose something: a pending order, a run in flight, a tool's
    /// sheet still waiting for its options (a password half-typed), or Fill & Sign's unsaved items
    /// or fields.
    public var hasWorkToLose: Bool {
        arrangement != nil || running != nil || sheet != nil || fill?.hasUnsavedChanges == true
    }

    /// Asks before a pending reorder or a run in flight is lost to opening another file, closing
    /// this one or quitting. True when there is nothing to lose or the reader said to go.
    ///
    /// It only asks; it drops nothing. The order and the run go in ``detach()``, which every
    /// leave that happens calls, so a leave that fails after the answer keeps both.
    ///
    /// `retry` is the leave asked for, run again once Fill & Sign's Save Filled Copy has written the
    /// copy (``EditorPDFFillSign/mayLeave(thenRetry:)``); until then the save's answer is "stay".
    /// `quitting` is ⌘Q's, whose question says Quit.
    public func mayLeave(quitting: Bool = false, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool {
        guard hasWorkToLose, let path else { return true }
        // Placed items alone are Fill & Sign's own question, which can save them as well as drop them.
        if arrangement == nil, running == nil, sheet == nil, let fill { return fill.mayLeave(thenRetry: retry) }
        let go = confirmDiscardingArrangement(quitting)
        Logger.shared.info("Edit asked before \(quitting ? "quitting from" : "leaving") \(Self.logName(path)) with "
                           + (running != nil ? "a tool running"
                              : arrangement != nil ? "a new page order not saved" : "a tool's sheet open")
                           + (go ? " — the reader chose to leave" : " — the reader stayed"))
        return go
    }

    // MARK: Running

    public func cancelRun() { cancelFlag?.cancel() }

    /// Saves the pending reorder as a copy; the arrangement goes once it has landed.
    @discardableResult
    public func saveArrangement() async -> EditorPDFToolOutcome {
        guard let arrangement else { return .nothingWritten("There is no new order to save.") }
        let outcome = await run(.reorder(arrangement))
        // Only the order that was saved, not one dragged since or another file's.
        if case .wrote = outcome, self.arrangement == arrangement { self.arrangement = nil }
        return outcome
    }

    /// Runs `tool` on the open file and writes its copy: refusals first (no lane turn), then the
    /// fidelity confirmation when the file has something to lose, then the lane, then the copy.
    /// Every ending is reported on ``banner`` unless `bannerFailures` is false, when a sheet shows
    /// its own failure in place.
    ///
    /// With a dragged order pending, Rotate and Delete Pages write it too, in one copy
    /// (``EditorPDFTool/composing(_:arrangement:)``), and the order is done with once it lands.
    /// Every surface (Tools menu, File ▸ PDF Tools, the Pages tab's menu, the page-range sheet)
    /// asks through here, so all do the same.
    @discardableResult
    public func run(_ asked: EditorPDFTool, bannerFailures: Bool = true) async -> EditorPDFToolOutcome {
        guard let path else { return .failed("No PDF is open.") }
        let tool = EditorPDFTool.composing(asked, arrangement: arrangement)
        let logName = Self.logName(path)
        // A failure, not "nothing written": a sheet must stay up with this said in it, not close.
        guard running == nil else {
            let busy = Self.busyMessage
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — \(running?.tool ?? "another tool") is running")
            if bannerFailures { banner = EditorPDFToolBanner(message: busy, kind: .failure) }
            return .failed(busy)
        }
        let generation = self.generation
        // The revision this run was asked about, fixed once: `tool` and its page numbers were
        // settled against it. A reload during the form-loss question or the lane wait moves
        // ``shownStamp`` to the new revision, and checking the live value would then pass the new
        // file with old page numbers. Every check below compares with this copy.
        let shownStamp = self.shownStamp
        // The file itself, through any symlink: the toolkit reads the source's size with
        // `resourceValues(.fileSizeKey)`, which doesn't follow one, so Compress would measure the
        // link. The copy is still named beside `path`, in the folder the reader sees.
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        let name = (path as NSString).lastPathComponent
        let folder = destinationFolder
        lastWrite = nil

        // The sizes the success banner quotes, known once the bytes are in hand.
        var sizes: (before: Int?, after: Int)?

        // What the copy could not do as asked, for the saved banner (`Output.bytes`'s note).
        var wroteNote: String?
        // A cancel whose copy couldn't be taken back: its name, so the banner doesn't claim that
        // nothing was written while the copy is still beside the original.
        var cancelLeftCopy: String?
        func end(_ outcome: EditorPDFToolOutcome, download: String? = nil) -> EditorPDFToolOutcome {
            // Another file is open now: this run's ending is about one not on screen, and
            // ``detach()`` has already logged that it went.
            guard generation == self.generation else { return outcome }
            running = nil
            cancelFlag = nil
            switch outcome {
            case .wrote(let copy):
                // The order went into the copy; as with Save Reordered Copy, only the one used, not
                // one dragged since.
                if case .arranged(let order, _) = tool, arrangement == order { arrangement = nil }
                let copyName = (copy as NSString).lastPathComponent
                report(EditorPDFToolBanner(
                    message: wroteMessage(copyName, tool: tool, before: sizes?.before, after: sizes?.after)
                        + (wroteNote.map { ". " + $0 } ?? ""),
                    kind: .wrote(copy)))
            case .nothingWritten(let message):
                report(EditorPDFToolBanner(message: message, kind: .note))
            case .cancelled:
                Logger.shared.info("\(writer) cancelled \(tool.title.lowercased()) of \(logName) — nothing written")
                if let left = cancelLeftCopy {
                    report(EditorPDFToolBanner(
                        message: "\(Running(tool).sentence) was canceled, but its copy “\(left)” couldn’t be removed — it’s still beside the original.",
                        kind: .failure))
                } else {
                    report(EditorPDFToolBanner(message: "\(Running(tool).sentence) was canceled — nothing was written.",
                                               kind: .note))
                }
            case .failed(let message):
                if bannerFailures { report(EditorPDFToolBanner(message: message, kind: .failure, download: download)) }
            case .declined:
                break
            }
            return outcome
        }

        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) {
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — not downloaded")
            return end(.failed(Self.cloudOnlyReason(name)), download: path)
        }
        if let refusal = EditorPDFToolEngine.refusal(tool, pageCount: pageCount) {
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — \(refusal)")
            return end(.failed(refusal))
        }
        if case .compress(.target(let bytes)) = tool, let size = EditorFileStore.stamp(ofPath: path)?.size,
           size <= bytes {
            Logger.shared.info("\(writer) wrote nothing for \(tool.logDetail) of \(logName) — already under the target")
            return end(.nothingWritten("“\(name)” is already \(FileSyncManager.formatBytes(size)), under the "
                                       + "\(FileSyncManager.formatBytes(bytes)) target — nothing was written."))
        }

        // Before any question, too: a confirmed "this will flatten the form" should not then be
        // refused. Asked again after it, since the file can change while the question is up.
        if let shownStamp, EditorFileStore.stamp(ofPath: path) != shownStamp {
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it changed on disk since it was read")
            return end(.failed(changedMessage(name)))
        }
        running = Running(tool)
        progress = nil
        let flag = CancelFlag()
        cancelFlag = flag
        if let warning = await EditorPDFToolEngine.fidelityWarning(for: tool, input: input) {
            guard generation == self.generation, !flag.isCancelled else { return end(.cancelled) }
            guard confirm(warning, tool.title) else {
                Logger.shared.info("\(writer) did not \(tool.logDetail) of \(logName) — declined: \(warning.confirmationTitle)")
                return end(.declined)
            }
        }
        guard generation == self.generation else { return end(.cancelled) }

        let before = EditorFileStore.stamp(ofPath: path)
        if let shownStamp, before != shownStamp {
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it changed on disk since it was read")
            return end(.failed(changedMessage(name)))
        }
        let hook = laneProgressHook
        let result = await EditorPDFToolEngine.run(
            tool, input: input, staging: stagingRoot,
            unchanged: shownStamp.map { (path, $0) }, isCloudOnly: isCloudOnly,
            fillAndSign: fillAndSignHook ?? EditorPDFToolEngine.toolkitFillAndSign,
            turnStarted: { [weak self, turnHook = laneTurnHook] in
                turnHook?()
                Task { @MainActor in
                    guard let self, generation == self.generation else { return }
                    self.running?.started = true
                }
            },
            progress: { [weak self] page, total in
                hook?(page, total, flag)
                Task { @MainActor in
                    // Counted and kept even when it lands after the run has ended: the lane can
                    // finish before the main actor reads its first report.
                    guard let self, generation == self.generation else { return }
                    self.progressReports &+= 1
                    self.progress = Progress(page: page, total: total)
                }
            },
            isCancelled: { flag.isCancelled })
        // A close or another file while the lane worked: the bytes are for a file no longer open.
        guard generation == self.generation else { return end(.cancelled) }
        // Cancel holds for every tool, not only Compress's page loop: pressed during the lane wait
        // or after Compress's last page, it still means "write nothing".
        if flag.isCancelled, case .success = result { return end(.cancelled) }

        switch result {
        case .failure(let error) where error is CancellationError:
            return end(.cancelled)
        case .failure(let error) where error is EditorPDFToolEngine.ChangedOnDisk:
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it changed on disk while the run waited for its turn")
            return end(.failed(changedMessage(name)))
        case .failure(let error) where error is EditorPDFToolEngine.CloudOnly:
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it went cloud-only while the run waited for its turn")
            return end(.failed(Self.cloudOnlyReason(name)), download: path)
        case .failure(let error):
            // `.info`, not `.warning`: the toolkit's refusals (a wrong password, a restricted file,
            // an empty page range) are answers about the file, not faults in the app.
            let message = EditorPDFToolEngine.reason(error, tool: tool, name: name)
            Logger.shared.info("\(writer) could not \(tool.logDetail) of \(logName) — "
                               + EditorPDFToolEngine.logReason(error, tool: tool, name: name))
            return end(.failed(message))
        case .success(.noGain):
            Logger.shared.info("\(writer) wrote nothing for \(tool.logDetail) of \(logName) — no smaller than the original")
            return end(.nothingWritten(Self.noGainMessage(tool)))
        case .success(.bytes(let data, let note, let comments)):
            let suffix = tool.suffix
            writeStartedHook?()
            let written = await Task.detached(priority: .userInitiated) {
                Result { try EditorPDFCopyWriter.writeStamped(data, besides: path, suffix: suffix, into: folder) }
            }.value
            if case .success(let landed) = written { writeLandedHook?(landed.path) }
            // Cancel or a leave during the write still means "write nothing", as the button's help
            // and the leave question promise: the copy is taken back if it is still the file this
            // run created.
            if case .success(let landed) = written, flag.isCancelled || generation != self.generation {
                let ours = EditorFileStore.stamp(ofPath: landed.path) == landed.stamp
                guard ours else {
                    Logger.shared.info("\(writer) cancelled \(tool.logDetail) of \(logName) while its copy was being written — "
                                       + "the copy had already been replaced, so it was left")
                    return end(.cancelled)
                }
                do {
                    try FileManager.default.removeItem(atPath: landed.path)
                    Logger.shared.info("\(writer) cancelled \(tool.logDetail) of \(logName) while its copy was being written — "
                                       + "the copy was removed")
                } catch {
                    // Said, not swallowed: the copy is still on disk, so "nothing was written" would be false.
                    cancelLeftCopy = (landed.path as NSString).lastPathComponent
                    Logger.shared.warning("\(writer) cancelled \(tool.logDetail) of \(logName) while its copy was being written, "
                                          + "but couldn't remove the copy at \(landed.path): \(error.localizedDescription)")
                }
                return end(.cancelled)
            }
            switch written.map({ $0.path }) {
            case .failure(let error):
                let message = "Couldn’t write the copy of “\(name)” — \(error.localizedDescription)"
                Logger.shared.warning("\(writer) could not write \(tool.logDetail) of \(logName): \(error.localizedDescription)")
                return end(.failed(message))
            case .success(let copy):
                sizes = (before?.size, data.count)
                let quoted = Self.sizes(before: before?.size, after: data.count)
                Logger.shared.info("\(writer) wrote \((copy as NSString).lastPathComponent) from \(logName) — "
                                   + tool.logDetail + (quoted.map { ", \($0)" } ?? "")
                                   + Self.commentsLogClause(comments, fellBack: note != nil))
                wroteNote = note
                if case .success(let landed) = written {
                    lastWrite = PDFWrittenFile(source: path, path: copy, stamp: landed.stamp, bytes: data.count,
                                               // A file locked to open has no count until it is unlocked.
                                               pageCount: pageCount > 0 ? tool.pagesInCopy(of: pageCount) : nil)
                }
                host.didWrite(copy)
                return end(.wrote(copy))
            }
        }
    }

    /// What became of the comments a Fill & Sign save was asked to keep, from the run's result
    /// rather than the request: kept, refused beside a picture page or a removed link, or given up
    /// by the toolkit. Empty when keeping them wasn't asked.
    static func commentsLogClause(_ comments: FillSignAnnotations?, fellBack: Bool) -> String {
        switch comments {
        case nil: return ""
        case .keep?: return " — comments kept as comments"
        case .flatten?: return fellBack ? " — the comments could not be kept, so they were drawn in"
            : " — the comments were drawn in, not kept: a page made a picture, or a link taken out, rewrites them"
        }
    }

    /// A second run while one is in flight, Edit's and a pane's alike.
    static let busyMessage = "Another tool is still running — try again when it has finished."

    /// A file evicted since it opened, refused before the lane. Its pages may still be on screen, so
    /// this says what to do rather than the reader's "nothing here to read yet".
    static func cloudOnlyReason(_ name: String) -> String {
        "“\(name)” is only in the cloud now. Download it, then try again."
    }

    /// The button beside that sentence, on the banner and in a tool's sheet.
    static let downloadTitle = "Download"
    static let downloadHelp = "Download the file from the cloud, then try again"

    /// An ending, onto ``banner`` unless the run is ``quiet``.
    private func report(_ ending: EditorPDFToolBanner) {
        lastReport = ending
        if !quiet { banner = ending }
    }

    static func changedReason(_ name: String) -> String {
        "“\(name)” changed on disk since it was opened, so nothing was written. It reloads in a moment — then try again."
    }

    /// The banner's sentence for a copy that landed: sizes for Compress, and by how much a size
    /// target was missed; for a restricted original, that the copy isn't restricted.
    private func wroteMessage(_ copyName: String, tool: EditorPDFTool, before: Int?, after: Int?) -> String {
        var message = "Saved “\(copyName)”"
        if let detail = tool.arrangedDetail { message += " — \(detail)" }
        if case .compress(let compression) = tool {
            message += Self.sizes(before: before, after: after).map { " — \($0)" } ?? ""
            if case .target(let bytes) = compression, let after, after > bytes {
                message += ". No setting reached \(FileSyncManager.formatBytes(bytes)); this is the smallest it got"
            }
        }
        // The rebuilding tools write a fresh document with no encryption dictionary, so the
        // original's editing restrictions don't survive into the copy, and that is said.
        if encryption == .restrictedOnly, tool.rebuildsDocument {
            message += ". The copy has no editing restrictions"
        }
        return message
    }

    /// `"Invoice.pdf in /Users/…/Finance"`: the log's name for a file, which two same-named PDFs in
    /// different folders don't share.
    static func logName(_ path: String) -> String {
        "\((path as NSString).lastPathComponent) in \((path as NSString).deletingLastPathComponent)"
    }

    static func sizes(before: Int?, after: Int?) -> String? {
        guard let before, let after else { return nil }
        return "\(FileSyncManager.formatBytes(before)) → \(FileSyncManager.formatBytes(after))"
    }

    static func noGainMessage(_ tool: EditorPDFTool) -> String {
        if case .compress(.target) = tool {
            return "Compressing couldn’t make this file any smaller — nothing was written."
        }
        return "Already about as small as this compression gets — nothing was written."
    }

    // MARK: The questions

    static func confirmWithAlert(_ warning: OutputFidelityWarning, toolTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.confirmationTitle
        alert.informativeText = (warning.detailLines(toolTitle: toolTitle) + [warning.keptLine])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: warning.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The leave question, in the words of what would be lost and of the leave: ⌘Q's says Quit
    /// where every other route says Leave; Discard is the same for both. `placed` is the save pill's
    /// count ("2 items", "1 correction"), so the two name things alike.
    static func leaveQuestion(running: Running?, hasArrangement: Bool, sheet: String? = nil,
                              placed placedParts: [String] = [], filledFields: Int = 0,
                              quitting: Bool = false) -> (title: String, detail: String, go: String) {
        let (leave, leaving) = quitting ? ("Quit", "Quitting") : ("Leave", "Leaving")
        var placed = ""
        if !placedParts.isEmpty {
            // "The item", not "The 1 item": one of anything is the only singular.
            let one = placedParts.count == 1 && placedParts[0].hasPrefix("1 ")
            let what = one ? String(placedParts[0].dropFirst(2)) : placedParts.joined(separator: " and ")
            placed = " The \(what) placed with Fill & Sign \(one ? "is" : "are") discarded too."
        }
        if filledFields > 0 {
            placed += " The \(filledFields == 1 ? "field" : "\(filledFields) fields") filled with Fill & Sign "
                + "\(filledFields == 1 ? "is" : "are") cleared too."
        }
        if let running {
            return ("Stop \(running.doing)?",
                    "\(running.stillRunning) \(leaving) stops it, and nothing is written."
                        + (hasArrangement ? " The new page order is discarded too." : "") + placed
                        + " The original file is unchanged either way.",
                    "Stop and \(leave)")
        }
        if !hasArrangement, let sheet {
            return ("Close \(sheet)?",
                    "\(sheet) is still waiting for its options. \(leaving) closes it, and nothing is written." + placed
                        + " The original file is unchanged either way.",
                    "Close and \(leave)")
        }
        return ("Discard the new page order?",
                "The pages were reordered but no copy was saved." + placed + " The original file is unchanged either way.",
                "Discard")
    }

    func confirmDiscardWithAlert(quitting: Bool) -> Bool {
        let question = Self.leaveQuestion(running: running, hasArrangement: arrangement != nil, sheet: sheet?.title,
                                          placed: fill?.placedParts ?? [], filledFields: fill?.values.count ?? 0,
                                          quitting: quitting)
        return Self.leaveAlert(question).runModal() == .alertFirstButtonReturn
    }

    /// A leave or quit question's two buttons: the one that throws work away first, destructive and
    /// off Return, then Cancel, which keeps the Esc AppKit gives a button of that name. So Esc stays
    /// and Return does nothing, and no keypress stops a run or drops an order, as with the panes'
    /// permanent Delete. Cancel can't hold Return too: a button has one key, and Esc would go.
    static func leaveAlert(_ question: (title: String, detail: String, go: String),
                           style: NSAlert.Style = .warning) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: question.go)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].hasDestructiveAction = true
        return alert
    }
}

/// Polled from the lane between Compress's pages; set from the main actor by Cancel.
final class CancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}
