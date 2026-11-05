import Events
import Foundation

/// What the Activity Log's on-demand history is doing right now.
///
/// One value rather than separate flags for the history, its limit, its loading state and its load
/// generation, which every path had to update in lockstep. As one enum, the meaningless
/// combinations ("loading" while loaded, a reveal count with nothing loaded) can't be written, and
/// Clear Log can't reset half of it and leave deleted rows on screen.
///
/// The load guard lives here too, in `beginLoading`: there is no flag for the view to forget to
/// check.
enum LogHistoryState {
    /// Not asked for yet: the footer offers "Show older history".
    case notLoaded

    /// A file read is in flight; the footer's button shows progress.
    ///
    /// `token` identifies this load. A completion whose token no longer matches discards its parse,
    /// so a read that started before Clear Log can't bring back the rows it deleted (and hide the
    /// reload button for the window's lifetime). Identity belongs to the load, so it lives here.
    case loading(token: UUID)

    /// Parsed and being shown. `entries` is newest-first and may be empty: the log holds nothing
    /// older than this session, which differs from `.notLoaded`, and the footer says so ("No
    /// earlier activity in the log").
    ///
    /// `revealed` is how many of the FILTERED matches are on screen, not an index into `entries`:
    /// the filter runs first and this caps the result, so changing the filter re-pages from the top.
    case loaded(entries: [LogEntry], revealed: Int)

    /// The read itself failed — the log file could not be read or decoded.
    ///
    /// Deliberately not `.loaded([])`. A second process writes the log too, so a crash mid-write can
    /// leave invalid UTF-8; treating that as "nothing older" would tell the user their history is
    /// empty, with no error anywhere, since this loader has no way to present one. A separate case
    /// lets the footer say what happened and lets `beginLoading` offer a retry, which `.loaded`
    /// refuses by design.
    case failed

    // MARK: Reading

    /// The parsed history, or nil while it has not been loaded. Callers distinguish "no history
    /// loaded" (nil) from "loaded, and there is none" (empty).
    var entries: [LogEntry]? {
        if case .loaded(let entries, _) = self { return entries }
        return nil
    }

    /// Whether a read is in flight (drives the footer button's spinner).
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Whether history has been parsed — true even when the parse found nothing.
    var isLoaded: Bool { entries != nil }

    /// Whether the last read failed. Distinct from `!isLoaded`: `.notLoaded` has simply not been
    /// asked for yet, and the two say different things in the footer.
    var readFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// How many filtered matches to show. Zero unless loaded, so a `prefix(_:)` against it yields
    /// nothing rather than a page of a list that was never fetched.
    var revealed: Int {
        if case .loaded(_, let revealed) = self { return revealed }
        return 0
    }

    // MARK: Transitions

    /// Claims the right to start a read.
    /// - Returns: The token to hand back to `finishLoading`, or nil when a read is already in
    ///   flight or the history is loaded: the double-fire guard, enforced structurally.
    ///
    /// A failed read may be retried: an unreadable file (a crash mid-write, a stalled volume) often
    /// clears on its own, and refusing would strand the window on an error for its lifetime.
    mutating func beginLoading() -> UUID? {
        switch self {
        case .notLoaded, .failed: break
        case .loading, .loaded: return nil
        }
        let token = UUID()
        self = .loading(token: token)
        return token
    }

    /// Applies a completed read, but only if it is still the one being awaited.
    /// - Returns: Whether the parse was applied. False means it was superseded (by Clear Log, or
    ///   by a newer load) and must be dropped.
    @discardableResult
    mutating func finishLoading(_ entries: [LogEntry], token: UUID, pageSize: Int) -> Bool {
        guard case .loading(let current) = self, current == token else { return false }
        self = .loaded(entries: entries, revealed: pageSize)
        return true
    }

    /// Records that a read failed, under the same token guard as `finishLoading`, so a failure from a
    /// superseded read can't knock the state out of whatever replaced it.
    /// - Returns: Whether the failure was applied.
    @discardableResult
    mutating func failLoading(token: UUID) -> Bool {
        guard case .loading(let current) = self, current == token else { return false }
        self = .failed
        return true
    }

    /// Back to the start: the rows are gone from disk, so the window forgets them and offers the
    /// reload button again. Any in-flight read is invalidated because its token no longer matches.
    mutating func reset() {
        self = .notLoaded
    }

    /// Collapses back to the first page: a new filter or search is a fresh view, so the list must
    /// not stay expanded to hundreds of rows. A no-op unless loaded.
    mutating func resetRevealed(to pageSize: Int) {
        guard case .loaded(let entries, _) = self else { return }
        self = .loaded(entries: entries, revealed: pageSize)
    }

    /// Reveals another page. A no-op unless loaded.
    mutating func revealMore(by pageSize: Int) {
        guard case .loaded(let entries, let revealed) = self else { return }
        self = .loaded(entries: entries, revealed: revealed + pageSize)
    }

    /// How many rows the next "Show N more" tap will actually reveal: a whole page while more than a
    /// page is left, and just the remainder on the last. The button names this number, so the final
    /// tap must not promise a full page. Zero means nothing is hidden, which also swaps the button
    /// for the "you're at the start of the log" note.
    ///
    /// `matchCount` is the count of filtered matches (what `revealed` caps), not `entries.count`.
    static func nextRevealCount(matchCount: Int, revealed: Int, pageSize: Int) -> Int {
        max(0, min(pageSize, matchCount - revealed))
    }
}
