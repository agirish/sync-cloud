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
        query.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
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
    var pages: [Int: [[CGRect]]] = [:]
    /// The current match: its page, and its place among that page's matches.
    var current: (page: Int, ordinal: Int)?

    static let none = EditorPDFHighlights()

    var isEmpty: Bool { pages.isEmpty }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pages == rhs.pages && lhs.current?.page == rhs.current?.page && lhs.current?.ordinal == rhs.current?.ordinal
    }
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
    /// The current match's place in ``matches``.
    @Published public private(set) var currentIndex: Int?
    /// A page turn has waited past ``waitThreshold`` for the lane — other PDF work is ahead of it.
    @Published public private(set) var isWaiting = false
    /// Bumped by every ask to show the bar, so the bar takes focus again when it is already up.
    @Published private(set) var focusRequest = 0
    /// Pages searched for the current query.
    @Published public private(set) var searchedPages = 0

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
        init(path: String, unlocked: PDFDocument? = nil) {
            self.path = path
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
        source = Source(path: path, unlocked: unlocked)
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

    /// Esc and Done: puts the bar away, withdraws the search and clears the highlights.
    public func hide() {
        stop()
        isShown = false
        phase = .idle
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
        guard text != query else { return }
        typing?.cancel()
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
    @discardableResult
    public func useSelection(_ text: String?) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }
        show()
        search(trimmed)
        return true
    }

    // MARK: What the bar says

    /// Whether there is any text to search — the facts' "Text selectable".
    public var isSearchable: Bool { hasText }

    /// What the page view draws.
    var highlights: EditorPDFHighlights {
        guard isShown, !matches.isEmpty else { return .none }
        var pages: [Int: [[CGRect]]] = [:]
        for match in matches { pages[match.pageIndex, default: []].append(match.rects) }
        let current = currentIndex.map { (matches[$0].pageIndex, matches[$0].ordinal) }
        return EditorPDFHighlights(pages: pages, current: current)
    }

    /// The counter, and the line under it while a turn waits.
    var caption: String { Self.caption(phase: phase, query: query, count: matches.count,
                                       current: currentIndex, isWaiting: isWaiting) }

    /// "3 of 9", "3 of 9 so far" while pages are still being searched, and why there is no count.
    nonisolated static func caption(phase: Phase, query: String, count: Int, current: Int?, isWaiting: Bool) -> String {
        if phase == .noText { return noTextCaption }
        guard !EditorPDFTextMatch.normalizedQuery(query).isEmpty, phase != .idle else { return "" }
        let searching = phase == .searching
        let counted: String
        if count == 0 {
            counted = searching ? "Searching…" : "Not found"
        } else {
            let position = current.map { "\($0 + 1) of \(count)" } ?? (count == 1 ? "1 match" : "\(count) matches")
            counted = searching ? "\(position) so far" : position
        }
        return isWaiting && searching ? "\(counted) · \(waitingCaption)" : counted
    }

    nonisolated static let noTextCaption = "This PDF has no text to search"
    nonisolated static let waitingCaption = "Waiting for other PDF work…"

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
        currentIndex = nil
        isWaiting = false
        searchedPages = 0
        landed = []
        asking = nil
    }

    private func restart() {
        stop()
        guard let source else { phase = .idle; return }
        guard hasText else { phase = .noText; return }
        let needle = EditorPDFTextMatch.normalizedQuery(query)
        guard isShown, !needle.isEmpty else { phase = .idle; return }
        phase = .searching
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
                }
                let turn = await Self.searchPage(page, query: needle, source: source, ticket: ticket,
                                                 started: started, lane: lane)
                watch.cancel()
                guard let self, generation == self.generation else { return }
                self.land(turn)
            }
            guard let self, generation == self.generation else { return }
            self.phase = .done
            self.isWaiting = false
            self.pump = nil
        }
    }

    private func land(_ turn: Turn) {
        isWaiting = false
        asking = nil
        switch turn {
        case .skipped:
            skippedTurns += 1
        case .failed(let page):
            searchedPages += 1
            landed.append(page)
        case .page(let page, let found):
            searchedPages += 1
            landed.append(page)
            guard !found.isEmpty else { return }
            let new = found.enumerated().map { EditorPDFFindMatch(pageIndex: page, ordinal: $0, rects: $1) }
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
        if let rect = match.rects.reduce(nil, { (union: CGRect?, next) in union.map { $0.union(next) } ?? next }) {
            view.reveal(rect, onPage: match.pageIndex)
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
