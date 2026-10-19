import AppKit
import os
import PDFKit
import Sync

// MARK: - Matching a page's text

/// **Where a query falls in one page's text** — pure, so the rules are tested without a PDF.
///
/// Case- and diacritic-insensitive, as the text find bar is. **A run of whitespace or line breaks
/// counts as one space, on both sides**: a PDF's text breaks its lines where the page does, so the
/// phrase a reader sees on two lines is two runs of text with a line break between them, and a
/// query typed with one space has to match it. Compatibility forms are folded too, so the `ﬁ`
/// ligature a typeset PDF stores matches a typed "fi".
enum EditorPDFTextMatch {

    /// The query as it is matched: folded, trimmed, every whitespace run one space. Empty for a
    /// query of nothing but whitespace, which searches nothing.
    static func normalizedQuery(_ query: String) -> String {
        oneLine(query.precomposedStringWithCompatibilityMapping)
    }

    /// `text` trimmed, every run of whitespace or line breaks one space — how a selection made
    /// across lines is put in the one-line field.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Every place `query` appears in `text`, as ranges of `text` itself (UTF-16, `NSString`'s —
    /// what `PDFPage.selection(for:)` takes), in order and not overlapping.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        let source = text as NSString
        // The folded text, one UTF-16 unit at a time, each remembering the span of `text` it came
        // from — so a match in the folded text maps back to the characters on the page.
        var units: [unichar] = []
        var starts: [Int] = []
        var ends: [Int] = []
        var inSpace = false
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: .byComposedCharacterSequences) { piece, range, _, _ in
            guard let piece else { return }
            if piece.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                if inSpace {
                    ends[ends.count - 1] = NSMaxRange(range)
                } else {
                    inSpace = true
                    units.append(0x20)
                    starts.append(range.location)
                    ends.append(NSMaxRange(range))
                }
                return
            }
            inSpace = false
            for unit in piece.precomposedStringWithCompatibilityMapping.utf16 {
                units.append(unit)
                starts.append(range.location)
                ends.append(NSMaxRange(range))
            }
        }
        let folded = NSString(characters: units, length: units.count)
        var found: [NSRange] = []
        var from = 0
        while from < folded.length {
            let hit = folded.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: from, length: folded.length - from))
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            let start = starts[hit.location]
            found.append(NSRange(location: start, length: ends[NSMaxRange(hit) - 1] - start))
            from = NSMaxRange(hit)
        }
        return found
    }
}

// MARK: - What a search found

/// One match: the page it is on, its place among that page's matches, and where it is drawn — one
/// rect per line it spans, in page space. Plain values, never PDFKit objects.
public struct EditorPDFFindMatch: Equatable, Sendable {
    public var pageIndex: Int
    public var ordinal: Int
    public var rects: [CGRect]
}

/// What the page view draws: every match by page, and which one is current.
struct EditorPDFHighlights: Equatable {
    /// A match by where it is: its page, and its place among that page's matches.
    struct Spot: Equatable {
        var page: Int
        var ordinal: Int
    }

    var pages: [Int: [[CGRect]]] = [:]
    var current: Spot?

    static let none = EditorPDFHighlights()

    var isEmpty: Bool { pages.isEmpty }
}

// MARK: - The find

/// **Find inside the open PDF — searched in the PDFKit lane, a page per turn, from a document of
/// its own.**
///
/// The lane's rules decide the shape, as they did the thumbnails' (``EditorPDFThumbnails``):
/// - **Never `PDFDocument.findString` or `beginFindString`.** The first searches the whole document
///   in one turn, which would hold a duplicate scan up for its whole length; the second extracts
///   text on PDFKit's own thread, outside the lane.
/// - **Never the reader's document.** The page view draws that one on the main thread, the lane's
///   documented exception, so reading its text in the lane would be two threads in one
///   `PDFDocument`. The search opens its own, in the lane, and touches it only there — reopened
///   every ``recycleEvery`` pages, the thumbnails' measured bound. A password-unlocked copy, made
///   in the unlock's own turn, is kept instead: the password is kept nowhere to open another.
/// - **One page per turn, one turn in flight**, starting at the page on screen and wrapping. Other
///   lane work queued meanwhile goes between two pages rather than behind all of them.
/// - **Each turn checks a withdrawable ticket at its head.** A changed query, a hidden bar or a
///   closed PDF withdraws the ticket, and the turn already queued skips itself unread.
///
/// Each turn hands back plain values — the page, and each match's rects in page space — and the
/// page view draws them over the pages on the main thread, from geometry alone.
@MainActor
public final class EditorPDFFind: ObservableObject {

    /// What the search is doing.
    public enum Phase: Equatable, Sendable {
        /// Nothing to search for — no query, or the bar is put away.
        case idle
        /// The PDF has no text to search: its facts say image only. Nothing is queued.
        case noText
        case searching
        case done
    }

    @Published public private(set) var isShown = false
    /// What was typed, as typed.
    @Published public private(set) var query = ""
    @Published public private(set) var phase: Phase = .idle
    /// Every match found so far, in document order.
    @Published public private(set) var matches: [EditorPDFFindMatch] = []
    /// ``matches``' rects by page, kept as each page lands — what ``highlights`` hands the view.
    private var highlightedPages: [Int: [[CGRect]]] = [:]
    /// The current match's place in ``matches``.
    @Published public private(set) var currentIndex: Int?
    /// A page turn has waited past ``waitThreshold`` for the lane — other PDF work is ahead of it.
    @Published public private(set) var isWaiting = false
    /// Bumped by every ask to show the bar, so the bar takes focus again when it is already up.
    @Published private(set) var focusRequest = 0
    /// Pages searched for the current query.
    @Published public private(set) var searchedPages = 0
    /// Pages whose text could not be read for the current query — all of them, and the bar says
    /// so rather than "Not found".
    @Published private(set) var failedPages = 0

    /// How long a turn may wait for the lane before the bar says so.
    static let waitThreshold: Duration = .milliseconds(300)
    /// Pages read before the search's document is let go and reopened — the thumbnails' bound.
    nonisolated static let recycleEvery = EditorPDFThumbnails.recycleEvery
    /// How long typing settles before a search starts.
    static let typingSettle: Duration = .milliseconds(150)

    /// Where the reader is — the page a search starts from, and where a match is shown.
    private let view: EditorPDFViewState
    private let lane: EditorPDFLane
    private var source: Source?
    private var pageCount = 0
    private var hasText = false
    private var ticket = Ticket()
    private var pump: Task<Void, Never>?
    private var typing: Task<Void, Never>?
    private var generation = 0
    /// When the current search started, and how many of its turns waited past ``waitThreshold`` —
    /// for its one log line.
    private var startedAt: ContinuousClock.Instant?
    private var waitedTurns = 0

    /// Told one line when a search finishes — never the query, which can be anything the reader
    /// typed. ``EditorPDFDocument`` hands in its log.
    var log: (String) -> Void = { _ in }

    /// Searches started, each a fresh run of turns. Test instrumentation.
    private(set) var searchesStarted = 0
    /// Turns that came up for a withdrawn search and skipped. Test instrumentation.
    private(set) var skippedTurns = 0
    /// Pages searched for the current query, in the order their turns landed. Test instrumentation.
    private(set) var landed: [Int] = []
    /// The page whose turn is out in the lane now, if any — so a test can know a turn is queued
    /// before it changes the query under it.
    private(set) var asking: Int?
    /// The ticket the current search's turns carry — for a test that counts what ran under it.
    var currentTicket: Ticket { ticket }
    /// The source held now — for a test that reads which documents were searched.
    var currentSource: Source? { source }

    init(view: EditorPDFViewState, lane: EditorPDFLane = .pdfKit) {
        self.view = view
        self.lane = lane
    }

    /// **A file evicted while open is not downloaded by a search.** The search reads its own copy,
    /// reopened from the path after Esc and every ``recycleEvery`` pages, and `PDFDocument(url:)` on
    /// a dataless file downloads it there and then — in the lane every duplicate scan waits on. Its
    /// pages fail instead, as an unreadable file's do. Injectable, as the reader's own is.
    var isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }

    /// The document the search reads, created on the main actor and then touched only inside the
    /// lane — see ``EditorPDFThumbnails/Source``, whose rules this one keeps.
    final class Source: @unchecked Sendable {
        let path: String
        var document: PDFDocument?
        var opened = false
        let reopens: Bool
        var readSinceOpen = 0
        /// Every document whose text a turn read. Test instrumentation, readable from any thread —
        /// how a test proves the reader's own document was never one of them.
        let readDocuments = OSAllocatedUnfairLock<Set<ObjectIdentifier>>(initialState: [])
        /// Asked in the lane before every open from ``path`` — see ``EditorPDFFind/isCloudOnly``.
        let isCloudOnly: @Sendable (String) -> Bool
        init(path: String, unlocked: PDFDocument? = nil,
             isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }) {
            self.path = path
            self.isCloudOnly = isCloudOnly
            document = unlocked
            opened = unlocked != nil
            reopens = unlocked == nil
        }
    }

    /// One search's permission to run. Withdrawn, every turn still queued under it skips at its
    /// head; ``bodies`` counts the turns that read a page, so a test can prove a withdrawn one never
    /// did.
    final class Ticket: Sendable {
        private let wanted = OSAllocatedUnfairLock(initialState: true)
        let bodies = OSAllocatedUnfairLock(initialState: 0)
        var isWanted: Bool { wanted.withLock { $0 } }
        func withdraw() { wanted.withLock { $0 = false } }
    }

    /// What one lane turn did.
    enum Turn: Sendable {
        case page(Int, [[CGRect]])
        /// The page could not be read.
        case failed(Int)
        /// Withdrawn before its turn came: nothing was read.
        case skipped
    }

    // MARK: Attaching

    /// Starts over for a newly opened, reloaded or unlocked PDF. A bar left up with a query —
    /// a reload under it — searches the new file from the page on screen.
    func attach(path: String, pageCount: Int, hasText: Bool, unlocked: PDFDocument? = nil) {
        stop()
        source = Source(path: path, unlocked: unlocked, isCloudOnly: isCloudOnly)
        self.pageCount = pageCount
        self.hasText = hasText
        if isShown { restart() }
    }

    /// Drops the search and its document, and puts the bar away — every close, and any load that
    /// left nothing to search. The query is kept for the next ⌘F, as the text find bar keeps its.
    func detach() {
        stop()
        source = nil
        pageCount = 0
        hasText = false
        isShown = false
        phase = .idle
    }

    // MARK: The bar's verbs

    /// ⌘F and the header's Find: shows the bar and gives it the keyboard. A query kept from before
    /// is searched again.
    public func show() {
        let wasShown = isShown
        isShown = true
        focusRequest &+= 1
        if !wasShown { restart() }
    }

    /// Esc and Done: puts the bar away, withdraws the search, clears the highlights and gives the
    /// pages the keyboard back. The search's document is let go too, unless it is a password copy
    /// that cannot be opened again — the next search reopens it in the lane.
    public func hide() {
        let wasShown = isShown
        stop()
        isShown = false
        phase = .idle
        if let source, source.reopens { self.source = Source(path: source.path, isCloudOnly: isCloudOnly) }
        if wasShown { view.requestFocus() }
    }

    /// Searches for `text` now.
    public func search(_ text: String) {
        typing?.cancel()
        typing = nil
        query = text
        restart()
    }

    /// The bar's field: searches once typing settles, so a word typed fast is one search, not one
    /// per letter.
    func type(_ text: String) {
        // Cancelled FIRST: typing back to the query searched must also drop the settle still
        // pending for what was typed in between.
        typing?.cancel()
        typing = nil
        guard text != query else { return }
        let settle = Self.typingSettle
        typing = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.search(text)
        }
    }

    /// Return in the field: a query still settling is searched now; otherwise the next match.
    func submit(_ text: String) {
        if typing != nil || text != query { search(text) } else { step(forward: true) }
    }

    /// ⌘G and ⇧⌘G, and the bar's ‹ ›: the next or previous match, wrapping. With nothing to step
    /// through, the bar is shown — the way to type a query.
    public func step(forward: Bool) {
        guard !matches.isEmpty else {
            show()
            return
        }
        isShown = true
        let next: Int
        if let currentIndex {
            next = (currentIndex + (forward ? 1 : -1) + matches.count) % matches.count
        } else {
            next = Self.firstIndex(atOrAfter: view.currentPage, in: matches, forward: forward)
        }
        select(next)
    }

    /// ⌘E: the reader's selection becomes the query. `nil` or empty — nothing selected — leaves the
    /// query alone, and says so.
    ///
    /// The query is set before the bar is shown, so showing it searches once — for the selection,
    /// not first for the query it replaces. A selection made across lines is put on one.
    @discardableResult
    public func useSelection(_ text: String?) -> Bool {
        let selected = EditorPDFTextMatch.oneLine(text ?? "")
        guard !selected.isEmpty else { return false }
        typing?.cancel()
        typing = nil
        query = selected
        if isShown {
            focusRequest &+= 1
            restart()
        } else {
            show()
        }
        return true
    }

    // MARK: What the bar says

    /// Whether there is any text to search — the facts' "Text selectable".
    public var isSearchable: Bool { hasText }

    /// **What the page view draws** — read on every pass of the reader's body, which a page turn,
    /// a zoom tick and every landed page all make. Built from ``matches`` it was a walk of every
    /// match each time, and its comparison in the page view another: a long search on a common word
    /// grew as pages times matches, on the main thread. The pages are kept as each one lands, so
    /// an unchanged read shares their storage and compares at a glance.
    var highlights: EditorPDFHighlights {
        guard isShown, !matches.isEmpty else { return .none }
        let pages = highlightedPages
        let current = currentIndex.map { EditorPDFHighlights.Spot(page: matches[$0].pageIndex, ordinal: matches[$0].ordinal) }
        return EditorPDFHighlights(pages: pages, current: current)
    }

    /// The counter, and the line under it while a turn waits.
    var caption: String { Self.caption(phase: phase, query: query, count: matches.count,
                                       current: currentIndex, isWaiting: isWaiting,
                                       unreadable: phase == .done && pageCount > 0 && failedPages == pageCount) }

    /// "3 of 9", "3 of 9 so far" while pages are still being searched, and why there is no count.
    nonisolated static func caption(phase: Phase, query: String, count: Int, current: Int?, isWaiting: Bool,
                                    unreadable: Bool = false) -> String {
        if phase == .noText { return noTextCaption }
        guard !EditorPDFTextMatch.normalizedQuery(query).isEmpty, phase != .idle else { return "" }
        let searching = phase == .searching
        let counted: String
        if count == 0 {
            counted = searching ? "Searching…" : (unreadable ? unreadableCaption : "Not found")
        } else {
            let position = current.map { "\($0 + 1) of \(count)" } ?? (count == 1 ? "1 match" : "\(count) matches")
            counted = searching ? "\(position) so far" : position
        }
        return isWaiting && searching ? "\(counted) · \(waitingCaption)" : counted
    }

    nonisolated static let noTextCaption = "This PDF has no text to search"
    nonisolated static let waitingCaption = "Waiting for other PDF work…"
    nonisolated static let unreadableCaption = "Couldn't read this PDF's text"

    // MARK: The search

    /// The pages in the order they are searched: `start` to the end, then the beginning up to it.
    nonisolated static func order(start: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let first = min(max(start, 0), count - 1)
        return Array(first..<count) + Array(0..<first)
    }

    /// The first match on or after `page` (on or before, going back), wrapping.
    nonisolated static func firstIndex(atOrAfter page: Int, in matches: [EditorPDFFindMatch], forward: Bool) -> Int {
        if forward {
            return matches.firstIndex { $0.pageIndex >= page } ?? 0
        }
        return matches.lastIndex { $0.pageIndex <= page } ?? matches.count - 1
    }

    /// Withdraws whatever is searching and clears what it found.
    private func stop() {
        generation &+= 1
        ticket.withdraw()
        ticket = Ticket()
        pump?.cancel()
        pump = nil
        typing?.cancel()
        typing = nil
        if !matches.isEmpty { matches = [] }
        highlightedPages = [:]
        currentIndex = nil
        isWaiting = false
        searchedPages = 0
        failedPages = 0
        landed = []
        asking = nil
        startedAt = nil
        waitedTurns = 0
    }

    private func restart() {
        stop()
        guard let source else { phase = .idle; return }
        guard hasText else { phase = .noText; return }
        let needle = EditorPDFTextMatch.normalizedQuery(query)
        guard isShown, !needle.isEmpty else { phase = .idle; return }
        phase = .searching
        searchesStarted += 1
        startedAt = .now
        let order = Self.order(start: view.currentPage, count: pageCount)
        let generation = self.generation
        let ticket = self.ticket
        let lane = self.lane
        pump = Task { [weak self] in
            // **`self` is held only between turns, never across one** — the thumbnails' rule: a
            // turn can wait behind a duplicate scan for minutes.
            for page in order {
                // Optional chaining, not `guard let`: a binding here would hold `self` across the
                // turn below.
                guard self?.generation == generation else { return }
                self?.asking = page
                let started = OSAllocatedUnfairLock(initialState: false)
                let watch = Task { [weak self] in
                    try? await Task.sleep(for: Self.waitThreshold)
                    guard !Task.isCancelled, !started.withLock({ $0 }),
                          let self, generation == self.generation else { return }
                    self.isWaiting = true
                    self.waitedTurns += 1
                }
                let turn = await Self.searchPage(page, query: needle, source: source, ticket: ticket,
                                                 started: started, lane: lane)
                watch.cancel()
                guard let self, generation == self.generation else { return }
                self.land(turn)
            }
            guard let self, generation == self.generation else { return }
            self.finish()
        }
    }

    private func finish() {
        phase = .done
        isWaiting = false
        pump = nil
        guard let source else { return }
        log(Self.logLine(path: source.path, pageCount: pageCount, matches: matches.count,
                         failed: failedPages, elapsed: startedAt.map { ContinuousClock.now - $0 } ?? .zero,
                         waited: waitedTurns))
    }

    /// The one line a finished search writes. No query: it can be anything the reader typed.
    static func logLine(path: String, pageCount: Int, matches: Int, failed: Int,
                                    elapsed: Duration, waited: Int) -> String {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var line = "Editor searched \(path) (PDF, \(EditorPDFDocument.pages(pageCount))): "
            + (matches == 1 ? "1 match" : "\(matches) matches")
            + " in \(String(format: "%.1f", seconds)) s"
        if waited > 0 { line += " — \(waited) page turn\(waited == 1 ? "" : "s") waited on other PDF work" }
        if failed > 0 { line += " — \(failed) page\(failed == 1 ? "" : "s") unreadable" }
        return line
    }

    private func land(_ turn: Turn) {
        isWaiting = false
        asking = nil
        switch turn {
        case .skipped:
            skippedTurns += 1
        case .failed(let page):
            searchedPages += 1
            failedPages += 1
            landed.append(page)
        case .page(let page, let found):
            searchedPages += 1
            landed.append(page)
            guard !found.isEmpty else { return }
            let new = found.enumerated().map { EditorPDFFindMatch(pageIndex: page, ordinal: $0, rects: $1) }
            highlightedPages[page] = found
            let at = matches.firstIndex { $0.pageIndex > page } ?? matches.count
            let current = currentIndex
            matches.insert(contentsOf: new, at: at)
            if let current {
                currentIndex = current >= at ? current + new.count : current
            } else {
                // The first match found is the first from the page on screen: show it.
                select(at)
            }
        }
    }

    private func select(_ index: Int) {
        currentIndex = index
        let match = matches[index]
        view.requestPage(match.pageIndex)
        if let first = match.rects.first {
            view.reveal(match.rects.dropFirst().reduce(first) { $0.union($1) }, onPage: match.pageIndex)
        }
    }

    /// One lane turn: open the source if this is its first, then match one page.
    nonisolated static func searchPage(_ index: Int, query: String, source: Source, ticket: Ticket,
                                       started: OSAllocatedUnfairLock<Bool> = .init(initialState: false),
                                       lane: EditorPDFLane = .pdfKit) async -> Turn {
        await lane.perform {
            started.withLock { $0 = true }
            guard ticket.isWanted else { return .skipped }
            ticket.bodies.withLock { $0 += 1 }
            if source.reopens, source.readSinceOpen >= recycleEvery {
                source.document = nil
                source.opened = false
            }
            if !source.opened {
                guard !source.isCloudOnly(source.path) else { return .failed(index) }
                source.opened = true
                source.readSinceOpen = 0
                source.document = PDFDocument(url: URL(fileURLWithPath: source.path))
            }
            source.readSinceOpen += 1
            guard let document = source.document, !document.isLocked,
                  let page = document.page(at: index) else { return .failed(index) }
            let read = ObjectIdentifier(document)
            source.readDocuments.withLock { _ = $0.insert(read) }
            return .page(index, matches(of: query, on: page))
        }
    }

    /// Each match on `page`, as one rect per line it spans, in page space. Lane only — the
    /// selections are text work.
    nonisolated static func matches(of query: String, on page: PDFPage) -> [[CGRect]] {
        guard let text = page.string else { return [] }
        return EditorPDFTextMatch.ranges(of: query, in: text).compactMap { range in
            guard let selection = page.selection(for: range) else { return nil }
            let lines = selection.selectionsByLine()
            let rects = (lines.isEmpty ? [selection] : lines)
                .map { $0.bounds(for: page) }
                .filter { !$0.isEmpty }
            return rects.isEmpty ? nil : rects
        }
    }
}
