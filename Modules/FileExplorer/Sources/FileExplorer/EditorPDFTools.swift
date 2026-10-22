import AppKit
import Combine
import Events
import os
import PDFToolkitCore
import Sync

/// What the app does around a tool's copy — the half of a run that needs the window.
public struct EditorPDFToolHost {
    /// A copy landed at this path: the rail and the panes re-list (Export as PDF's follow-up).
    public var didWrite: (String) -> Void
    /// The banner's Open — the copy in Edit, through the same door a rail click takes.
    public var open: (String) -> Void
    /// The banner's Reveal in Browse.
    public var reveal: (String) -> Void
    /// Download, for a file only in the cloud now (TE185) — Edit's own, which works for every
    /// provider.
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
        /// A copy was written at this path — the banner offers Open and Reveal in Browse.
        case wrote(String)
        /// A batch from a pane's menu wrote these copies — its banner offers Reveal in Browse.
        case wroteSeveral([String])
        /// Nothing went wrong and nothing was written — "already about as small as this gets".
        case note
        case failure
    }
    public let id = UUID()
    public var message: String
    public var kind: Kind
    /// A second line under the sentence — a batch names each file it skipped or failed, and why.
    public var detail: String?
    /// A file only in the cloud now: the banner offers Download for it (TE185).
    public var download: String?
}

/// How a run ended — what a sheet needs to decide whether to close.
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

/// **The Pages tab's selection** — click, ⌘-click and ⇧-click over the pages as they are SHOWN,
/// which during a pending reorder is not page order.
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

/// **A reorder the reader has dragged and not saved** — the pages in their new order.
public enum EditorPDFArrangement {
    /// `moving` dropped onto `target`: they take its place, after it when dragged forward and
    /// before it when dragged back — the way a dragged row lands in a Finder list.
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

    /// `page` one place earlier (`step` −1) or later (+1) — VoiceOver's way to reorder, where a
    /// drag is not. Unchanged at either end.
    public static func stepping(_ page: Int, by step: Int, in order: [Int]) -> [Int] {
        guard let at = order.firstIndex(of: page), order.indices.contains(at + step) else { return order }
        var next = order
        next.swapAt(at, at + step)
        return next
    }
}

/// **Edit's PDF tools: the selection, a pending reorder, a run, and what it said.** A sibling of
/// ``EditorPDFViewState`` on ``EditorPDFDocument`` — observed by the header's Tools menu, the Pages
/// tab and the card's banner, and by nothing that redraws the window.
///
/// **Every tool writes a NEW copy and never touches the open file**, so nothing here registers undo
/// (as Export as PDF and ⌘N do not): a copy destroys nothing, and removing it is an ordinary Trash.
/// The open file stays open — and read-only — and opening the copy is the reader's choice, from
/// the banner.
@MainActor
public final class EditorPDFTools: ObservableObject {

    /// The file the tools act on — the reader's — or `nil` with nothing open.
    public private(set) var path: String?
    /// **The file as the reader last read it** — set by ``EditorPDFDocument`` with each load. A
    /// run reads the file afresh, so after a change on disk the reader has not reloaded yet (the
    /// watch's settle, or a reload waiting behind a duplicate scan) it wrote from pages nobody was
    /// shown: Fill & Sign's items placed by the old pages' boxes, Rotate's pages by the old
    /// numbering. `nil` — a pane's run, with no reader — checks nothing.
    var shownStamp: EditorFileStore.Stamp?
    @Published public private(set) var pageCount = 0
    /// How the file on disk is protected, read in the lane when it opened. `nil` until then.
    @Published public private(set) var encryption: PDFEncryptionState?
    @Published public private(set) var selection = EditorPDFPageSelection()
    /// A dragged order not yet saved, or `nil`. Never the identity: a drag back to where the pages
    /// were is no arrangement at all.
    @Published public private(set) var arrangement: [Int]?
    /// The run in flight, or `nil` — one at a time.
    @Published public private(set) var running: Running?
    @Published public var sheet: EditorPDFToolSheet?
    @Published public var banner: EditorPDFToolBanner?

    /// "page N of M", from Compress — as it reached the main actor. Cleared when a run starts, and
    /// left on the last page when it ends; it is shown only while ``running`` is set.
    @Published public private(set) var progress: Progress?

    public struct Running: Equatable {
        /// The tool's title — "Rotate", for the log.
        public var tool: String
        /// "rotating the pages" — ``EditorPDFTool/doing``, for the sentences that name the run.
        public var doing: String
        /// "The pages are still being rotated." — the leave question's.
        public var stillRunning: String
        /// Whether the lane reports pages as it goes — Compress alone does.
        public var reportsProgress: Bool
        /// Whether its lane turn has begun. Until then it is waiting behind other PDF work — a
        /// duplicate scan can hold the lane for minutes — and says so, rather than that it is busy.
        public var started = false

        init(_ tool: EditorPDFTool) {
            self.tool = tool.title
            doing = tool.doing
            stillRunning = tool.stillRunning
            if case .compress = tool { reportsProgress = true } else { reportsProgress = false }
        }

        /// "Rotating the pages" — ``doing`` at the start of a sentence.
        public var sentence: String { doing.prefix(1).uppercased() + doing.dropFirst() }
    }

    public struct Progress: Equatable, Sendable {
        public var page: Int
        public var total: Int
    }

    /// Set by the app; a no-op otherwise, so a test can run a tool without a window.
    public var host = EditorPDFToolHost()
    /// Fill & Sign's unsaved items are work a leave can lose too — asked about in ``mayLeave(quitting:thenRetry:)``,
    /// which every route out of the PDF already asks.
    weak var fill: EditorPDFFillSign?
    /// Who a run's log lines say ran the tool — "Edit" for the reader's own tools; a run from a
    /// pane's menu names its workspace instead (``PanePDFTools``).
    var writer = "Edit"
    /// Whether the file is only in the cloud now — evicted since it opened. The toolkit opens it
    /// by URL in the lane, and a dataless file downloads synchronously on whatever thread asks,
    /// which is the lane every duplicate scan waits on; so a run refuses it, as the open does.
    /// Asked again in the lane turn, since a run can wait there long enough for an eviction.
    var isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    /// Called IN THE LANE before each of Compress's pages, with the run's cancel flag — the tests'
    /// way to cancel between two pages without racing the main actor. `nil` in the app.
    var laneProgressHook: (@Sendable (Int, Int, CancelFlag) -> Void)?
    /// Called IN THE LANE as a run's turn begins, before anything is read — a test's way to change
    /// the file while the run waits for the lane. `nil` in the app.
    var laneTurnHook: (@Sendable () -> Void)?
    /// Called on the main actor as the copy's write is handed off — a test's way to cancel or
    /// leave while the bytes are being written, rather than racing the write for it.
    var writeStartedHook: (@MainActor () -> Void)?
    /// Called on the main actor with the copy's path once it has landed, before a cancel is
    /// looked at — a test's way to replace the copy before the run would take it back.
    var writeLandedHook: (@MainActor (String) -> Void)?
    /// Where a combined run (a tool in the dragged order) keeps its middle bytes, in a folder of its
    /// own that it removes — the user's temporary folder in the app, a test's own folder in a test.
    var stagingRoot = FileManager.default.temporaryDirectory
    /// Asks whether to go ahead despite `warning` — a native alert in the app, a canned answer in a
    /// test. `toolTitle` is the tool's own title, which `detailLines` names.
    var confirm: @MainActor (OutputFidelityWarning, String) -> Bool = { EditorPDFTools.confirmWithAlert($0, toolTitle: $1) }
    /// Asks whether a pending reorder or a run in flight may be lost — see ``mayLeave(quitting:thenRetry:)``.
    /// Its argument says whether the leave is ⌘Q.
    lazy var confirmDiscardingArrangement: @MainActor (_ quitting: Bool) -> Bool = { [unowned self] in
        self.confirmDiscardWithAlert(quitting: $0)
    }

    private var cancelFlag: CancelFlag?
    private var generation = 0
    /// Every progress report that has reached the main actor — the tests' way to see it did.
    private(set) var progressReports = 0

    public init() {}

    // MARK: The file

    func attach(path: String, pageCount: Int, encryption: PDFEncryptionState) {
        if self.path == path {
            // **A reload: the file changed on disk.** A pending order went with it whatever the
            // page count — the pages it named may now say something else — and says so. The
            // selection survives while the count does, as the reader's place does.
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
    }

    /// The page count, once a locked file has been unlocked in the reader.
    func update(pageCount: Int) {
        guard pageCount != self.pageCount else { return }
        self.pageCount = pageCount
        selection.clear()
        arrangement = nil
    }

    func detach() {
        if let path {
            // Asked about first where it can be (``mayLeave(quitting:thenRetry:)``); said here either way, since a
            // close from elsewhere — the file deleted, an external open — asks nobody.
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
        selection.clear()
        arrangement = nil
        running = nil
        sheet = nil
        banner = nil
    }

    // MARK: What can run

    /// **Why nothing but Remove Password is offered**, for a file locked to open. Every toolkit
    /// call opens the file by URL, and a locked one is refused there — unlocking it in the reader
    /// does not unlock the file.
    public static let lockedReason = "Remove the password first. That writes an unlocked copy."
    /// Why Clean Metadata is not offered on any encrypted file — the toolkit refuses
    /// (`metadataEncrypted`), so it is said up front instead.
    public static let metadataEncryptedReason = "Password-protected — remove the password to clean metadata"

    /// Whether the page tools, Compress and Protect may run. Restricted-only files are let through:
    /// rebuilding tools work on them, and the in-place ones say why not in the toolkit's words.
    public var offersPageTools: Bool { encryption != nil && encryption != .lockedToOpen && pageCount > 0 }
    public var offersMetadata: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersProtect: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersRemovePassword: Bool { encryption == .lockedToOpen || encryption == .restrictedOnly }

    /// Why a tool is greyed out, or `nil` — the first line of the Tools menu.
    public var disabledReason: String? {
        encryption == .lockedToOpen ? Self.lockedReason : nil
    }

    // MARK: Selection and the pending reorder

    /// The pages as the Pages tab shows them.
    public var order: [Int] { arrangement ?? Array(0..<pageCount) }

    /// Names this document in a dragged page — not its path, which a drop into another app's text
    /// field would paste. A new one per file, so a page from another PDF is no reorder of this one.
    public private(set) var dragToken = UUID()

    /// Whether the Pages tab takes a drop: a file the tools can rebuild, and no run in flight — a
    /// drag while the reordered copy is saving would be cleared by that save.
    public var acceptsReorder: Bool { offersPageTools && running == nil }

    public func click(_ page: Int, _ click: EditorPDFPageSelection.Click) {
        selection.click(page, click, order: order)
    }

    public func clearSelection() { selection.clear() }

    public func selectAll() { selection.selectAll(order) }

    /// `page` one place earlier or later in the pending order — the accessibility actions' reorder.
    public func step(_ page: Int, by step: Int) {
        guard acceptsReorder else { return }
        let next = EditorPDFArrangement.stepping(page, by: step, in: order)
        arrangement = next == Array(0..<pageCount) ? nil : next
    }

    /// `pages` dropped onto `target` in the Pages tab — a pending order, written nowhere.
    public func move(_ pages: [Int], onto target: Int) {
        guard acceptsReorder else { return }
        let next = EditorPDFArrangement.moving(pages, onto: target, in: order)
        arrangement = next == Array(0..<pageCount) ? nil : next
    }

    /// Back to the file's own order.
    public func resetArrangement() { arrangement = nil }

    /// **Whether Delete Pages is offered for `pages`** — none, where the sheet asks which, or a
    /// selection. A copy keeps at least one page, so not on a one-page file and not with every page
    /// selected. The one rule the Tools menu, the Pages tab's menu and its Delete key ask.
    public func mayDelete(_ pages: [Int]) -> Bool {
        guard offersPageTools, running == nil else { return false }
        return pages.isEmpty ? pageCount > 1 : Set(pages).count < pageCount
    }

    /// **The Pages tab's Delete key**: the Delete Pages sheet for the selection, under the menus'
    /// rule — where both grey the item out, the key does nothing too. True when a sheet was asked for.
    @discardableResult
    public func deleteSelectedPages() -> Bool {
        let pages = order.filter(selection.pages.contains)
        guard !pages.isEmpty, sheet == nil, mayDelete(pages) else { return false }
        sheet = .pages(.delete, prefill: EditorPDFPageMenu.rangeText(pages))
        return true
    }

    /// Whether leaving the file would lose something: a pending order, a run still in flight, a
    /// tool's sheet still waiting for its options — a password half-typed, as a pane's sheet is
    /// asked about at ⌘Q — or items placed, or fields filled, with Fill & Sign and not saved.
    public var hasWorkToLose: Bool {
        arrangement != nil || running != nil || sheet != nil || fill?.hasUnsavedChanges == true
    }

    /// **Asks before a pending reorder — or a run in flight — is lost** to opening another file,
    /// closing this one or quitting. True when there is nothing to lose or the reader said to go.
    ///
    /// **It only asks; it drops nothing.** The order and the run go when the file really closes
    /// (``detach()``), which every leave that happens calls — so a leave that fails after the
    /// answer (⌘N's file could not be made, a later quit question was answered Wait) keeps both.
    ///
    /// `retry` is the leave asked for, run again once Fill & Sign's Save Filled Copy has written the
    /// copy (``EditorPDFFillSign/mayLeave(thenRetry:)``) — the save's answer is "stay" until then.
    ///
    /// `quitting` is ⌘Q's, whose question says Quit (TE158).
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
        // Only the order that was saved — not one dragged since, or another file's.
        if case .wrote = outcome, self.arrangement == arrangement { self.arrangement = nil }
        return outcome
    }

    /// **Runs `tool` on the open file and writes its copy.** Refusals first (no lane turn), then
    /// the fidelity confirmation when the file has something to lose, then the lane, then the copy.
    /// Every ending is reported on ``banner`` unless `bannerFailures` is false — a sheet shows its
    /// own failure in place, where the field that caused it is.
    ///
    /// **With a dragged order pending, Rotate and Delete Pages write it too** — one copy, in the new
    /// order with the change applied (``EditorPDFTool/composing(_:arrangement:)``), and the order is
    /// done with once it lands. Every surface asks through here — the header's Tools menu,
    /// File ▸ PDF Tools, the Pages tab's menu and the page-range sheet — so all of them do the same.
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
        // **The file itself, through any symlink**: the toolkit reads the source's size with
        // `resourceValues(.fileSizeKey)`, which does not follow one — so Compress on a symlinked
        // PDF measured the LINK and never ran. The copy is still named beside `path`, the folder
        // the reader sees.
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        let name = (path as NSString).lastPathComponent

        // The sizes the success banner quotes, known once the bytes are in hand.
        var sizes: (before: Int?, after: Int)?

        func end(_ outcome: EditorPDFToolOutcome, download: String? = nil) -> EditorPDFToolOutcome {
            // Another file is open now: what this run says is about one that is not on screen —
            // and ``detach()`` has already logged that it went.
            guard generation == self.generation else { return outcome }
            running = nil
            cancelFlag = nil
            switch outcome {
            case .wrote(let copy):
                // The order went into the copy — as Save Reordered Copy's does, only the one that
                // was used, not one dragged since.
                if case .arranged(let order, _) = tool, arrangement == order { arrangement = nil }
                let copyName = (copy as NSString).lastPathComponent
                banner = EditorPDFToolBanner(
                    message: wroteMessage(copyName, tool: tool, before: sizes?.before, after: sizes?.after),
                    kind: .wrote(copy))
            case .nothingWritten(let message):
                banner = EditorPDFToolBanner(message: message, kind: .note)
            case .cancelled:
                Logger.shared.info("\(writer) cancelled \(tool.title.lowercased()) of \(logName) — nothing written")
                banner = EditorPDFToolBanner(message: "\(Running(tool).sentence) was cancelled — nothing was written.",
                                             kind: .note)
            case .failed(let message):
                if bannerFailures { banner = EditorPDFToolBanner(message: message, kind: .failure, download: download) }
            case .declined:
                break
            }
            return outcome
        }

        if isCloudOnly(path) {
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
            return end(.failed(Self.changedReason(name)))
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
            return end(.failed(Self.changedReason(name)))
        }
        let hook = laneProgressHook
        let result = await EditorPDFToolEngine.run(
            tool, input: input, staging: stagingRoot,
            unchanged: shownStamp.map { (path, $0) }, isCloudOnly: isCloudOnly,
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
                    // Counted and kept even when it lands after the run has ended — the lane
                    // can finish before the main actor reads its first report.
                    guard let self, generation == self.generation else { return }
                    self.progressReports &+= 1
                    self.progress = Progress(page: page, total: total)
                }
            },
            isCancelled: { flag.isCancelled })
        // A close or another file while the lane worked: the bytes are for a file no longer open.
        guard generation == self.generation else { return end(.cancelled) }
        // **Cancel holds for every tool, not only Compress's page loop** — pressed while the run
        // waited for the lane, or after Compress's last page, it still means "write nothing".
        if flag.isCancelled, case .success = result { return end(.cancelled) }

        switch result {
        case .failure(let error) where error is CancellationError:
            return end(.cancelled)
        case .failure(let error) where error is EditorPDFToolEngine.ChangedOnDisk:
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it changed on disk while the run waited for its turn")
            return end(.failed(Self.changedReason(name)))
        case .failure(let error) where error is EditorPDFToolEngine.CloudOnly:
            Logger.shared.info("\(writer) refused \(tool.logDetail) of \(logName) — it went cloud-only while the run waited for its turn")
            return end(.failed(Self.cloudOnlyReason(name)), download: path)
        case .failure(let error):
            // `.info`, not `.warning`: these are the toolkit's refusals — a wrong password, a
            // restricted file, an empty page range — answers about the file, not faults in the app.
            let message = EditorPDFToolEngine.reason(error, tool: tool, name: name)
            Logger.shared.info("\(writer) could not \(tool.logDetail) of \(logName) — "
                               + EditorPDFToolEngine.logReason(error, tool: tool, name: name))
            return end(.failed(message))
        case .success(.noGain):
            Logger.shared.info("\(writer) wrote nothing for \(tool.logDetail) of \(logName) — no smaller than the original")
            return end(.nothingWritten(Self.noGainMessage(tool)))
        case .success(.bytes(let data)):
            let suffix = tool.suffix
            writeStartedHook?()
            let written = await Task.detached(priority: .userInitiated) {
                Result { try EditorPDFCopyWriter.writeStamped(data, besides: path, suffix: suffix) }
            }.value
            if case .success(let landed) = written { writeLandedHook?(landed.path) }
            // **Cancel, or a leave, pressed while the copy was being written still means "write
            // nothing"** — as the button's help and the leave question promise. The copy just made
            // is taken back, if it is still the file this run created.
            if case .success(let landed) = written, flag.isCancelled || generation != self.generation {
                let ours = EditorFileStore.stamp(ofPath: landed.path) == landed.stamp
                if ours { try? FileManager.default.removeItem(atPath: landed.path) }
                Logger.shared.info("\(writer) cancelled \(tool.logDetail) of \(logName) while its copy was being written — "
                                   + (ours ? "the copy was removed" : "the copy had already been replaced, so it was left"))
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
                                   + tool.logDetail + (quoted.map { ", \($0)" } ?? ""))
                host.didWrite(copy)
                return end(.wrote(copy))
            }
        }
    }

    /// A second run while one is in flight — Edit's and a pane's alike.
    static let busyMessage = "Another tool is still running — try again when it has finished."

    /// **A file evicted since it opened**, refused before the lane: its pages may still be on
    /// screen, so this says what to do rather than the reader's "nothing here to read yet".
    static func cloudOnlyReason(_ name: String) -> String {
        "“\(name)” is only in the cloud now. Download it, then try again."
    }

    /// The button beside that sentence — on the banner and in a tool's sheet (TE185).
    static let downloadTitle = "Download"
    static let downloadHelp = "Download the file from the cloud, then try again"

    static func changedReason(_ name: String) -> String {
        "“\(name)” changed on disk since it was opened, so nothing was written. It reloads in a moment — then try again."
    }

    /// The banner's sentence for a copy that landed — sizes for Compress, and for a size target the
    /// reader missed, by how much; and for a restricted original, that the copy is not restricted.
    private func wroteMessage(_ copyName: String, tool: EditorPDFTool, before: Int?, after: Int?) -> String {
        var message = "Saved “\(copyName)”"
        if let detail = tool.arrangedDetail { message += " — \(detail)" }
        if case .compress(let compression) = tool {
            message += Self.sizes(before: before, after: after).map { " — \($0)" } ?? ""
            if case .target(let bytes) = compression, let after, after > bytes {
                message += ". No setting reached \(FileSyncManager.formatBytes(bytes)); this is the smallest it got"
            }
        }
        // The rebuilding tools write a fresh document, which carries no encryption dictionary: the
        // original's editing restrictions do not survive into the copy, and that is said.
        if encryption == .restrictedOnly, tool.rebuildsDocument {
            message += ". The copy has no editing restrictions"
        }
        return message
    }

    /// `"Invoice.pdf in /Users/…/Finance"` — the log's name for a file, which two same-named PDFs in
    /// different folders do not share.
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

    /// The leave question, in the words of what would be lost — and of the leave: ⌘Q's says
    /// Quit where every other route says Leave (TE158). Discard is the same word for both.
    static func leaveQuestion(running: Running?, hasArrangement: Bool, sheet: String? = nil,
                              placedItems: Int = 0, filledFields: Int = 0,
                              quitting: Bool = false) -> (title: String, detail: String, go: String) {
        let (leave, leaving) = quitting ? ("Quit", "Quitting") : ("Leave", "Leaving")
        var placed = placedItems == 0 ? ""
            : " The \(placedItems == 1 ? "item" : "\(placedItems) items") placed with Fill & Sign \(placedItems == 1 ? "is" : "are") discarded too."
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
                                          placedItems: fill?.unsaved.count ?? 0, filledFields: fill?.values.count ?? 0,
                                          quitting: quitting)
        return Self.leaveAlert(question).runModal() == .alertFirstButtonReturn
    }

    /// **A leave or quit question's two buttons** (TE184, decision BS): the answer that throws work
    /// away first, marked destructive and off Return, then Cancel, which keeps the Esc AppKit gives
    /// a button of that name. So Esc stays and Return does nothing — no keypress stops a run or
    /// drops an order — as the file panes' permanent Delete question works. Cancel can't hold
    /// Return as well: a button has one key, and Return on it would take Esc away.
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
