import AppKit
import Combine
import PDFKit
import PDFToolkitCore
import Sync

/// **A PDF open in Edit — read-only, and deliberately not an ``EditorDocument``.**
///
/// That type is a text buffer: its saved text, encoding, undo store, autosave, disk watch, printing
/// and status line all assume one, and about a thousand tests hold it to that. So a PDF gets a model
/// of its own beside it, and the host shows one or the other. **The point is what a PDF can never
/// reach**: every write the editor makes ends at `EditorFileStore.write`, which needs the text
/// document's path and encoding, and ⌘S, autosave, the settle and the quit flush all ask that
/// document. While a PDF is open the text document is empty — `path == nil` — so each of them is a
/// no-op by the rules it already has, rather than by a new check somebody has to remember.
///
/// **Split in two, for ``EditorDocument``'s reason.** This object is the file's identity — which
/// PDF, whether it opened, what it is — and changes only on open, close, unlock and reload; the
/// window observes it. Where the reader is in it, the zoom and the fit move on every scroll, and
/// live on ``view``, which only the PDF card observes. A page turn must not re-render the window.
///
/// **Every parse goes through `PDFKitSerialAccess`** — the open, the unlock and the facts — with
/// the column preview's rule (Phase 0): the latest request wins, and a load that comes back for any
/// earlier one is dropped. The mounted `PDFView` then draws on the main thread, the lane's one
/// documented exception.
@MainActor
public final class EditorPDFDocument: ObservableObject {

    /// What the card shows.
    public enum Phase: Equatable, Sendable {
        /// The lane has the file; nothing to show yet.
        case loading
        /// Pages on screen.
        case open
        /// It needs a password — `unlock(password:)`.
        case locked
        /// Nothing could be shown. The reason is written for the reader.
        case refused(String)
    }

    /// What a load found, crossing back from the lane.
    enum Read: Sendable {
        case open(SendableDocument, EditorPDFFacts, [EditorPDFOutlineEntry], PDFEncryptionState)
        case locked(SendableDocument)
        case unreadable
        /// Withdrawn before its turn came — another open or a close got there first — so nothing
        /// was parsed. Arrowing through a folder of PDFs in Edit's pane queues no abandoned parses.
        case skipped
    }

    /// The file on screen, or `nil` when no PDF is open.
    @Published public private(set) var path: String?
    @Published public private(set) var phase: Phase = .loading
    /// What the status line says about the file. `nil` until it has opened (and been unlocked).
    @Published public private(set) var facts: EditorPDFFacts?
    /// The document the page view draws — only once it is open, never while it is locked.
    @Published private(set) var document: PDFDocument?
    /// The PDF's bookmarks, flattened for the rail's Outline tab — read in the same lane turn as
    /// ``facts``. Empty until it has opened, and for a file with none.
    @Published public private(set) var outline: [EditorPDFOutlineEntry] = [] {
        didSet { if outline != oldValue { outlineRail = EditorPDFOutline.Rail(outline) } }
    }
    /// ``outline`` as the rail draws it, rebuilt only when the bookmarks change.
    private(set) var outlineRail = EditorPDFOutline.Rail([])

    /// Where the reader is, and how the page is sized — see ``EditorPDFViewState``.
    public let view: EditorPDFViewState
    /// The rail's Pages tab — see ``EditorPDFThumbnails``. Attached when the PDF opens, detached
    /// on every close, so a long scan's thumbnails never outlive it.
    public let thumbnails = EditorPDFThumbnails()
    /// Find inside the PDF — see ``EditorPDFFind``. Attached and detached with the thumbnails, so
    /// its document never outlives the PDF either.
    public let find: EditorPDFFind
    /// The PDF tools — selection, a pending reorder, a run — see ``EditorPDFTools``. Attached with
    /// the file and detached on every close, like ``thumbnails``.
    public let tools = EditorPDFTools()
    /// Fill & Sign — the items placed on the pages and not yet saved — see ``EditorPDFFillSign``.
    /// Attached and detached with ``tools``, which writes its copy.
    public let fill: EditorPDFFillSign

    /// A locked document waiting for its password. Held apart from ``document`` so the page view
    /// never gets a document it cannot draw.
    private var locked: PDFDocument?
    /// Bumped by every open, reload and close. **Latest request wins**: a load that comes back
    /// under an older number is dropped, never assigned.
    private var generation = 0
    /// The open in flight, withdrawable until the lane reaches it — the column preview's ticket.
    private var ticket: PDFOpenTicket?
    /// What the file looked like when it was last read — the watch compares against it.
    private var stamp: EditorFileStore.Stamp?
    private var watcher: EditorFileWatcher?
    private var pending: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private var log: (String) -> Void = { _ in }

    /// How long the watch lets a burst of events settle before it looks — an atomic save empties
    /// the path for a moment.
    let settle: Duration
    private let isCloudOnly: (String) -> Bool

    /// Told the outcome of every load that is applied — the tests' way to see what a load did.
    var onLoaded: ((Phase) -> Void)?
    /// Every lane read that has come back, applied or dropped — so a test can wait for a load it
    /// expects to be DROPPED, which tells `onLoaded` nothing.
    private(set) var loadsReturned = 0
    /// Opens this model withdrew before their turn, which the lane then skipped unparsed.
    private(set) var skippedOpens = 0

    /// `defaults` is where the reader's layout is remembered (``EditorPDFSettings``) — the shared
    /// domain in the app, a scratch one in a test.
    public init(settle: Duration = .milliseconds(250),
                isCloudOnly: @escaping (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
                defaults: UserDefaults = .standard) {
        self.settle = settle
        self.isCloudOnly = isCloudOnly
        let view = EditorPDFViewState(defaults: defaults)
        self.view = view
        find = EditorPDFFind(view: view)
        fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        find.log = { [weak self] in self?.log($0) }
        fill.tools = tools
        tools.fill = fill
    }

    public var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    /// Why nothing is on screen, or `nil`. **A refused PDF is let through a second open** — the
    /// hand-off's rule for a refused text file, so a file downloaded since is one click away.
    public var refusal: String? {
        if case .refused(let reason) = phase { return reason }
        return nil
    }

    /// Whether File ▸ Print… has pages to print.
    public var canPrint: Bool { document != nil }

    // MARK: Opening and closing

    /// Opens `path`, replacing whatever PDF was open, and logs one line when the lane answers.
    ///
    /// **A cloud-only file is refused without being parsed**: `PDFDocument(url:)` on a dataless file
    /// downloads it synchronously on whatever thread asked, which here is the lane every duplicate
    /// scan waits on. The fetch-then-open path a file from Finder takes is the way in for those.
    public func open(path: String, log: @escaping (String) -> Void) {
        close()
        self.log = log
        self.path = path
        view.reset()
        arm(path)
        observeActivation()
        if isCloudOnly(path) {
            finish(.refused(Self.notDownloadedReason), path: path)
            return
        }
        load(path, keepingPage: nil)
    }

    /// Drops the document — and with it the decoded pages a long scan holds. The watch stops and a
    /// load still in the lane will find itself superseded.
    public func close() {
        generation &+= 1
        ticket?.withdraw()
        ticket = nil
        pending?.cancel()
        pending = nil
        watcher?.cancel()
        watcher = nil
        document = nil
        locked = nil
        facts = nil
        outline = []
        thumbnails.detach()
        find.detach()
        tools.detach()
        fill.detach()
        stamp = nil
        path = nil
        phase = .loading
        view.reset()
    }

    /// Tries a password on a locked PDF, in the lane. **The password is used once and kept
    /// nowhere** — not on this object, not in the log, not in the view after the attempt.
    @discardableResult
    public func unlock(password: String) async -> Bool {
        guard phase == .locked, let locked, let path else { return false }
        let generation = self.generation
        let held = SendableDocument(locked)
        let unlocked = await PDFKitSerialAccess.perform { () -> Unlocked? in
            guard held.document.unlock(withPassword: password) else { return nil }
            // The thumbnails' and the find's own copies, unlocked in this same turn — the password
            // is not kept for a later one (``EditorPDFThumbnails``, ``EditorPDFFind``).
            func copy() -> SendableDocument? {
                PDFDocument(url: URL(fileURLWithPath: path))
                    .flatMap { $0.unlock(withPassword: password) ? SendableDocument($0) : nil }
            }
            let facts = EditorPDFFacts.read(held.document, path: path)
            // The file on disk is still locked, so `formFields(at:)` listed nothing — but the
            // reader's unlocked copy has its widgets, and a click must not type into them either.
            if EditorPDFForm.declaresFields(held.document) { EditorPDFForm.lockWidgets(in: held.document) }
            return Unlocked(facts: facts,
                            outline: EditorPDFOutline.flatten(held.document),
                            thumbnailSource: copy(), findSource: copy())
        }
        guard generation == self.generation, self.path == path else { return false }
        guard let unlocked else {
            log("Editor could not unlock \(path) — the password was not accepted")
            return false
        }
        let facts = unlocked.facts
        self.locked = nil
        document = held.document
        self.facts = facts
        view.pageCount = facts.pageCount
        outline = unlocked.outline
        thumbnails.attach(path: path, pageCount: facts.pageCount,
                          unlocked: unlocked.thumbnailSource?.document)
        find.attach(path: path, pageCount: facts.pageCount, hasText: facts.hasText,
                    unlocked: unlocked.findSource?.document)
        // The file on disk is still locked: unlocking it here unlocks the reader's copy, not the
        // file every tool opens by URL — so the tools keep offering only Remove Password.
        tools.update(pageCount: facts.pageCount)
        // Still locked on disk, so Fill & Sign keeps the tools' refusal — but knows the pages.
        fill.attach(path: path, boxes: facts.boxes, encryption: .lockedToOpen, allowsFilling: facts.allowsFilling)
        phase = .open
        log("Editor unlocked \(path) (PDF, \(Self.pages(facts.pageCount)))")
        onLoaded?(.open)
        return true
    }

    /// What a successful unlock read, crossing back from the lane.
    private struct Unlocked: Sendable {
        var facts: EditorPDFFacts
        var outline: [EditorPDFOutlineEntry]
        var thumbnailSource: SendableDocument?
        var findSource: SendableDocument?
    }

    private func load(_ path: String, keepingPage page: Int?) {
        generation &+= 1
        let generation = self.generation
        ticket?.withdraw()
        let ticket = PDFOpenTicket()
        self.ticket = ticket
        let before = EditorFileStore.stamp(ofPath: path)
        Task { @MainActor [weak self] in
            let read = await Self.read(path, ticket: ticket)
            guard let self else { return }
            loadsReturned &+= 1
            if case .skipped = read { skippedOpens &+= 1 }
            guard generation == self.generation, self.path == path else { return }
            self.stamp = before
            switch read {
            case .skipped:
                // Withdrawn, yet still the current generation: unreachable, since every withdraw
                // comes with a new generation. Said rather than left as a silent no-op.
                assertionFailure("a skipped open of \(path) came back as the current one")
            case .unreadable:
                document = nil
                locked = nil
                facts = nil
                outline = []
                thumbnails.detach()
                find.detach()
                tools.detach()
                fill.detach()
                finish(.refused(Self.unreadableReason), path: path)
            case .locked(let held):
                document = nil
                facts = nil
                outline = []
                thumbnails.detach()
                find.detach()
                tools.attach(path: path, pageCount: 0, encryption: .lockedToOpen)
                fill.attach(path: path, boxes: [], encryption: .lockedToOpen, allowsFilling: true)
                locked = held.document
                finish(.locked, path: path)
            case .open(let held, let facts, let outline, let encryption):
                locked = nil
                document = held.document
                self.facts = facts
                view.pageCount = facts.pageCount
                self.outline = outline
                thumbnails.attach(path: path, pageCount: facts.pageCount)
                find.attach(path: path, pageCount: facts.pageCount, hasText: facts.hasText)
                tools.attach(path: path, pageCount: facts.pageCount, encryption: encryption)
                fill.attach(path: path, boxes: facts.boxes, encryption: encryption, allowsFilling: facts.allowsFilling,
                            form: facts.form, allowsFormEntry: facts.allowsFormEntry,
                            allowsCommenting: facts.allowsCommenting)
                if let page { view.requestPage(min(page, max(facts.pageCount - 1, 0))) }
                finish(.open, path: path, reloaded: page != nil)
            }
        }
    }

    private func finish(_ phase: Phase, path: String, reloaded: Bool = false) {
        self.phase = phase
        log(Self.logLine(path: path, phase: phase, pageCount: facts?.pageCount, reloaded: reloaded,
                         page: view.currentPage))
        onLoaded?(phase)
    }

    /// The lane's half of a load: open, and if it opened, read what the status line needs.
    nonisolated static func read(_ path: String, ticket: PDFOpenTicket = PDFOpenTicket()) async -> Read {
        await PDFKitSerialAccess.perform {
            // Counted by the model that withdrew it (``skippedOpens``), not on the column
            // preview's process-wide `PDFOpenTicket.skippedOpens` — see that counter's doc.
            guard ticket.isWanted else { return .skipped }
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return .unreadable }
            if document.isLocked { return .locked(SendableDocument(document)) }
            // How the file is protected, for the tools — read in this same turn. A restricted-only
            // file opens like any other, so it is the toolkit's question, not `isLocked`.
            let url = URL(fileURLWithPath: path)
            let facts = EditorPDFFacts.read(document, path: path)
            if EditorPDFForm.declaresFields(document) { EditorPDFForm.lockWidgets(in: document) }
            return .open(SendableDocument(document), facts,
                         EditorPDFOutline.flatten(document), PDFToolkit.encryptionState(of: url))
        }
    }

    // MARK: Words

    static let notDownloadedReason = "Not downloaded — there is nothing here to read yet."
    static let unreadableReason = "PDFKit couldn't read this file."
    static let goneReason = "It is no longer here — it was moved or deleted."

    static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    /// One line per load, in `EditorDocumentLoad.logLine`'s shape. Separate so the wording can be
    /// asserted without a lane.
    static func logLine(path: String, phase: Phase, pageCount: Int?, reloaded: Bool = false,
                        page: Int = 0) -> String {
        switch phase {
        case .loading: return "Editor is opening \(path) (PDF)"
        case .locked: return "Editor opened \(path) (PDF, locked — waiting for its password)"
        case .refused(let reason): return "Editor could not open \(path) — \(reason)"
        case .open:
            let pages = Self.pages(pageCount ?? 0)
            return reloaded
                ? "Editor reloaded \(path) (PDF, \(pages)) — changed elsewhere; kept page \(page + 1)"
                : "Editor opened \(path) (PDF, \(pages))"
        }
    }

    // MARK: The watch

    /// **The PDF's own small watch** — not `EditorDiskWatch`, which re-reads with the text reader
    /// and asks text questions (unsaved typing, "Use the Disk's"). A read-only PDF has none of
    /// those: a change is reloaded through the lane on the page the reader was on, and a file that
    /// went away says so.
    private func arm(_ path: String) {
        watcher?.cancel()
        watcher = EditorFileWatcher(path: path, isCloudOnly: isCloudOnly) { [weak self] in
            Task { @MainActor in self?.eventArrived() }
        }
    }

    /// The net under the events: a change made while the app was in the background.
    private func observeActivation() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
    }

    func eventArrived() {
        pending?.cancel()
        let settle = self.settle
        pending = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.look()
        }
    }

    /// Looks at the disk now: a new stamp reloads, keeping the page; an empty path says so.
    func look() {
        guard let path else { return }
        // Not while a load is out — it read the stamp it will compare against.
        guard phase != .loading else { return }
        // A refusal for not being downloaded is answered by the fetch-then-open path, not here.
        if refusal == Self.notDownloadedReason { return }
        guard let now = EditorFileStore.stamp(ofPath: path) else {
            guard refusal != Self.goneReason else { return }
            document = nil
            locked = nil
            facts = nil
            outline = []
            thumbnails.detach()
            find.detach()
            tools.detach()
            fill.detach()
            stamp = nil
            finish(.refused(Self.goneReason), path: path)
            return
        }
        guard now != stamp else { return }
        // An atomic save installed a new inode; the descriptor still holds the old one.
        arm(path)
        load(path, keepingPage: view.currentPage)
    }
}

/// **Where the reader is in the PDF, and how the page is sized** — the half of the model that moves
/// on every scroll, observed only by the PDF card. See ``EditorPDFDocument``.
@MainActor
public final class EditorPDFViewState: ObservableObject {
    /// The page under the reader's eye, zero-based — reported by the view. In a two-page layout,
    /// one page of the spread on screen; ``visiblePages`` is the spread.
    @Published public internal(set) var currentPage = 0
    /// How many pages the open document has — set with the document, for ``visiblePages``.
    @Published public internal(set) var pageCount = 0
    /// The scale the view is drawing at — reported by the view.
    @Published public internal(set) var scale: CGFloat = 1
    /// How the page is sized. `nil` once the reader has zoomed by hand, until a fit is picked again.
    @Published public var fit: EditorPDFFit? = .page
    /// How the pages are laid out — remembered across launches under
    /// ``EditorPDFSettings/layoutKey``.
    @Published public var layout: EditorPDFLayout {
        didSet { if layout != oldValue { defaults.set(layout.rawValue, forKey: EditorPDFSettings.layoutKey) } }
    }
    /// Whether a two-page layout shows the first page on its own — remembered under
    /// ``EditorPDFSettings/coverSeparatelyKey``. Kept while a single-page layout is chosen, so
    /// going back to two pages finds it as it was.
    @Published public var coverSeparately: Bool {
        didSet {
            if coverSeparately != oldValue { defaults.set(coverSeparately, forKey: EditorPDFSettings.coverSeparatelyKey) }
        }
    }
    /// **Whether the pages have the keyboard** — the page view first responder (or inside it) in
    /// the key window. Reported by the view; what puts ⌘+ ⌘− ⌘0 on the PDF's zoom rather than the
    /// app's text size.
    @Published public internal(set) var hasFocus = false
    /// A page the view is asked to show — a count, so asking twice for one page is two asks.
    @Published public private(set) var pageRequest: EditorPDFRequest<Int>?
    /// A scale the view is asked to take — the zoom buttons.
    @Published public private(set) var scaleRequest: EditorPDFRequest<CGFloat>?
    /// A place on a page the view is asked to scroll into sight — the find's current match.
    @Published public private(set) var revealRequest: EditorPDFRequest<EditorPDFReveal>?
    /// The page view showing the reader now, set while it is mounted — what ⌘E reads the
    /// selection from. Weak, and cleared only by the view that set it: a page view torn down after
    /// its successor was built must not take the successor's away.
    weak var reader: PDFView?
    /// Asks the page view to take the keyboard — the find bar going away hands it back.
    @Published private(set) var focusRequest = 0
    /// Asks the header's page field to take the caret — Text ▸ Go to Page… ⌃⌘L, the PDF's Go to
    /// Line. A count, like ``focusRequest``, so a second press while the field is up asks again.
    @Published public private(set) var pageFieldRequest = 0
    private var token = 0
    private let defaults: UserDefaults

    /// Reads the remembered layout from `defaults` — the shared domain in the app, a scratch one
    /// in a test.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = EditorPDFSettings.layout(in: defaults)
        coverSeparately = EditorPDFSettings.coverSeparately(in: defaults)
    }

    /// **The pages on screen together, zero-based** — the current page alone in a single-page
    /// layout, its spread in a two-page one: what the page field, the status line and the Pages tab
    /// say the reader is on.
    public var visiblePages: ClosedRange<Int> {
        EditorPDFLayout.spread(containing: currentPage, pageCount: pageCount, twoUp: layout.isTwoUp,
                               coverSeparately: coverSeparately)
    }

    /// **The reader's own selection, as text**, for ⌘E. Selection text the reader already made on
    /// the main thread, read there; no extraction.
    public func selectedText() -> String? { reader?.currentSelection?.string }

    func requestFocus() { focusRequest &+= 1 }

    public func requestPageField() { pageFieldRequest &+= 1 }

    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 8

    public func requestPage(_ index: Int) {
        token &+= 1
        pageRequest = EditorPDFRequest(value: index, token: token)
    }

    /// Scrolls `rect`, in page space, into sight on page `index`. Asked after ``requestPage(_:)``
    /// for the same page, which the view handles first.
    public func reveal(_ rect: CGRect, onPage index: Int) {
        token &+= 1
        revealRequest = EditorPDFRequest(value: EditorPDFReveal(pageIndex: index, rect: rect), token: token)
    }

    /// − and +, and ⌘− ⌘+ while the pages have the keyboard: the next stop on the ladder
    /// (``EditorPDFZoom/step(from:in:)``). Nothing past either end.
    public func zoom(in zoomingIn: Bool) {
        guard let next = EditorPDFZoom.step(from: scale, in: zoomingIn) else { return }
        zoom(to: next)
    }

    /// Whether − or + has a stop to go to.
    public func canZoom(in zoomingIn: Bool) -> Bool { EditorPDFZoom.step(from: scale, in: zoomingIn) != nil }

    /// A preset from the zoom menu: that scale, held until a fit is picked — a resize leaves it.
    public func zoom(to value: CGFloat) {
        token &+= 1
        fit = nil
        scale = min(max(value, Self.minScale), Self.maxScale)
        scaleRequest = EditorPDFRequest(value: scale, token: token)
    }

    func reset() {
        currentPage = 0
        pageCount = 0
        scale = 1
        fit = .page
        pageRequest = nil
        scaleRequest = nil
        revealRequest = nil
    }
}

/// A rect on a page, in page space, to scroll into sight.
public struct EditorPDFReveal: Equatable, Sendable {
    public var pageIndex: Int
    public var rect: CGRect
}

/// One ask of the page view, with a token so the same value asked twice is asked twice.
public struct EditorPDFRequest<Value: Equatable>: Equatable {
    public var value: Value
    public var token: Int
}

/// Fit Page, Fit Width and Actual Size — the zoom menu's fits (mockup 15). Page and Width refit as
/// the window is resized; a preset or a pinch is a scale, held as it is.
public enum EditorPDFFit: String, CaseIterable, Sendable {
    /// The whole spread, both dimensions inside the view — `PDFPageFit`, the preview's own rule.
    case page
    /// The spread's width across the view; the height scrolls.
    case width
    /// 100%: one PDF point to one screen point.
    case actual

    public var title: String {
        switch self {
        case .page: return "Fit Page"
        case .width: return "Fit Width"
        case .actual: return "Actual Size"
        }
    }

    /// The scale this fit asks for, for a spread of `spreadSize` in a view of `viewSize`.
    ///
    /// **A spread is what is on screen side by side** — one page in a single-page layout, so the
    /// numbers there are what they were before there were layouts; two pages and the gap between
    /// them in a two-page one (``spreadSize(_:gap:)``), so Fit Width puts the PAIR across the view.
    ///
    /// `.page` is `PDFPageFit.scale`, capped at 1 as the preview's is, so a small page is not blown
    /// up past its size. `.width` is not capped — fitting the width of a narrow receipt is what the
    /// reader asked for — and keeps the page-break margins PDFKit draws either side.
    static func scale(_ fit: EditorPDFFit, spreadSize: CGSize, viewSize: CGSize, margin: CGFloat) -> CGFloat {
        switch fit {
        case .page: return PDFPageFit.scale(pageSize: spreadSize, viewSize: viewSize)
        case .actual: return 1
        case .width:
            guard spreadSize.width > 0, viewSize.width > 2 * margin else { return 1 }
            return (viewSize.width - 2 * margin) / spreadSize.width
        }
    }

    /// The size of pages drawn side by side with `gap` between each two: their widths and the gaps
    /// added, the tallest one's height.
    static func spreadSize(_ pages: [CGSize], gap: CGFloat) -> CGSize {
        guard !pages.isEmpty else { return .zero }
        return CGSize(width: pages.reduce(0) { $0 + $1.width } + gap * CGFloat(pages.count - 1),
                      height: pages.map(\.height).max() ?? 0)
    }
}

/// What the status line says about the open PDF, read in the lane once per load.
public struct EditorPDFFacts: Equatable, Sendable {
    public var pageCount: Int
    /// Each page's media box, in points — pages of one file can differ.
    public var pageSizes: [CGSize]
    public var majorVersion: Int
    public var minorVersion: Int
    /// The file's size, formatted.
    public var fileSize: String?
    /// Whether any of the first pages has text to select — a scan has none.
    public var hasText: Bool
    /// Each page as the reader SEES it — its crop box, turned by its rotation — which is the shape
    /// the page view draws and a thumbnail is drawn in (``EditorPDFThumbnails/shownSize(of:)``).
    /// ``pageSizes`` stays the media box, the paper the status line names. Empty when not read.
    public var shownSizes: [CGSize] = []
    /// Each page's crop box and rotation — where Fill & Sign's items are placed (``EditorPDFPageBox``).
    public var boxes: [EditorPDFPageBox] = []
    /// Whether the file's owner lets it be written on — comments or form filling allowed. Only an
    /// owner-restricted file says no.
    public var allowsFilling = true
    /// The two halves of ``allowsFilling``, which a form file needs apart (Phase 5c): its fields need
    /// form entry, and text or a signature placed on its pages needs commenting. Many forms allow the
    /// first and forbid the second.
    public var allowsFormEntry = true
    public var allowsCommenting = true
    /// The file's own interactive form, or ``EditorPDFForm/none`` — see ``EditorPDFForm``.
    public var form = EditorPDFForm.none

    /// How many pages are asked for text. A 300-page scan is not walked end to end to say "Image
    /// only": if the first few have no text layer, the rest of a scan will not either.
    static let textProbePages = 5

    /// Called inside the lane only.
    nonisolated static func read(_ document: PDFDocument, path: String) -> EditorPDFFacts {
        let count = document.pageCount
        let pages = (0..<count).map { document.page(at: $0) }
        let sizes = pages.map { $0?.bounds(for: .mediaBox).size ?? .zero }
        let shown = pages.map { $0.map(EditorPDFThumbnails.shownSize(of:)) ?? .zero }
        let boxes = pages.map { page in
            page.map { EditorPDFPageBox(cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) }
                ?? EditorPDFPageBox(cropBox: .zero, rotation: 0)
        }
        let hasText = (0..<min(count, textProbePages)).contains { index in
            guard let text = document.page(at: index)?.string else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let size = EditorFileStore.stamp(ofPath: path).map { FileSyncManager.formatBytes($0.size) }
        return EditorPDFFacts(pageCount: count, pageSizes: sizes, majorVersion: document.majorVersion,
                              minorVersion: document.minorVersion, fileSize: size, hasText: hasText,
                              shownSizes: shown, boxes: boxes,
                              allowsFilling: document.allowsCommenting || document.allowsFormFieldEntry,
                              allowsFormEntry: document.allowsFormFieldEntry,
                              allowsCommenting: document.allowsCommenting,
                              form: EditorPDFForm.read(document, url: URL(fileURLWithPath: path)))
    }

    /// "Letter · 8.5 × 11 in" for the page at `index`, or `nil` past the end.
    public func paperCaption(page index: Int) -> String? {
        guard pageSizes.indices.contains(index) else { return nil }
        return Self.paperCaption(pageSizes[index])
    }

    /// The paper's name when it is a common one, then its size in inches.
    static func paperCaption(_ size: CGSize) -> String {
        let inches = "\(Self.inches(size.width)) × \(Self.inches(size.height)) in"
        guard let name = paperName(size) else { return inches }
        return "\(name) · \(inches)"
    }

    /// Named papers, portrait, in points. Matched either way up, within a point.
    static let papers: [(name: String, size: CGSize)] = [
        ("Letter", CGSize(width: 612, height: 792)),
        ("Legal", CGSize(width: 612, height: 1008)),
        ("Tabloid", CGSize(width: 792, height: 1224)),
        ("A3", CGSize(width: 842, height: 1191)),
        ("A4", CGSize(width: 595, height: 842)),
        ("A5", CGSize(width: 420, height: 595)),
    ]

    static func paperName(_ size: CGSize) -> String? {
        let portrait = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
        return papers.first {
            abs($0.size.width - portrait.width) <= 1.5 && abs($0.size.height - portrait.height) <= 1.5
        }?.name
    }

    /// Points to inches, to two decimals with trailing zeros dropped — 8.5, 11, 8.27.
    static func inches(_ points: CGFloat) -> String {
        let value = (points / 72 * 100).rounded() / 100
        return value == value.rounded() ? String(Int(value)) : String(format: "%g", Double(value))
    }

    public var versionCaption: String { "PDF \(majorVersion).\(minorVersion)" }
    public var textCaption: String { hasText ? "Text selectable" : "Image only" }
}

extension EditorPDFDocument {
    /// File ▸ Print… for the open PDF — `nil` while nothing is open to print (locked, refused,
    /// still loading). Scaled to the paper and rotated to it, as Preview prints.
    public func printOperation(info: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard let document else { return nil }
        let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        operation?.jobTitle = name
        return operation
    }
}
