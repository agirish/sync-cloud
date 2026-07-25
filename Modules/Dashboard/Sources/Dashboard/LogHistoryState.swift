import Events
import Foundation

/// What the Activity Log's on-demand history is doing right now.
///
/// One value in place of the four `@State` variables this replaced — `loadedHistory`,
/// `historyLimit`, `isLoadingHistory` and `historyLoadGeneration` — which had to be moved in
/// lockstep by every path that touched any of them, with nothing but ordering to enforce it. Two
/// combinations were representable and meaningless ("loading" while already loaded; a reveal count
/// for history that was never loaded), and the one bug this area has shipped was a partial update:
/// Clear Logs reset some of them and left `loadedHistory` populated, so deleted rows stayed on
/// screen and the reload button never came back.
///
/// The load guard lives here too, in `beginLoading` — the view can no longer start a second read by
/// forgetting to check a flag, because there is no flag to forget.
enum LogHistoryState {
    /// Not asked for yet: the footer offers "Show older history".
    case notLoaded

    /// A file read is in flight; the footer's button shows progress.
    ///
    /// `token` identifies THIS load. A completion whose token no longer matches the current state
    /// discards its parse rather than applying it — which is what keeps a read that started before
    /// Clear Logs from resurrecting the rows it deleted (and, by making `entries` non-nil again,
    /// hiding the reload button for the window's lifetime). It replaces a separate monotonic
    /// generation counter: identity belongs to the load, so it lives in the load's own case.
    case loading(token: UUID)

    /// Parsed and being shown. `entries` is newest-first and may legitimately be EMPTY — the log
    /// holds nothing older than this session, which is a different outcome from `.notLoaded` and
    /// the footer says so ("No earlier activity in the log").
    ///
    /// `revealed` is how many of the FILTERED matches are on screen, not an index into `entries`:
    /// the filter runs first and this caps the result, so changing the filter re-pages from the top.
    case loaded(entries: [LogEntry], revealed: Int)

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

    /// How many filtered matches to show. Zero unless loaded, so a `prefix(_:)` against it yields
    /// nothing rather than a page of a list that was never fetched.
    var revealed: Int {
        if case .loaded(_, let revealed) = self { return revealed }
        return 0
    }

    // MARK: Transitions

    /// Claims the right to start a read.
    /// - Returns: The token to hand back to `finishLoading`, or nil when a read is already in
    ///   flight or the history is already loaded — the double-fire guard, enforced structurally.
    mutating func beginLoading() -> UUID? {
        guard case .notLoaded = self else { return nil }
        let token = UUID()
        self = .loading(token: token)
        return token
    }

    /// Applies a completed read, but only if it is still the one being awaited.
    /// - Returns: Whether the parse was applied. False means it was superseded (by Clear Logs, or
    ///   by a newer load) and must be dropped.
    @discardableResult
    mutating func finishLoading(_ entries: [LogEntry], token: UUID, pageSize: Int) -> Bool {
        guard case .loading(let current) = self, current == token else { return false }
        self = .loaded(entries: entries, revealed: pageSize)
        return true
    }

    /// Back to square one: the rows are gone from disk, so the window must forget them AND offer
    /// the reload button again. Any in-flight read is invalidated by the token no longer matching.
    mutating func reset() {
        self = .notLoaded
    }

    /// Collapses back to the first page — a new filter or search is a fresh view of the history, so
    /// the list must not stay expanded to hundreds of now-filtered rows. A no-op unless loaded.
    mutating func resetRevealed(to pageSize: Int) {
        guard case .loaded(let entries, _) = self else { return }
        self = .loaded(entries: entries, revealed: pageSize)
    }

    /// Reveals another page. A no-op unless loaded.
    mutating func revealMore(by pageSize: Int) {
        guard case .loaded(let entries, let revealed) = self else { return }
        self = .loaded(entries: entries, revealed: revealed + pageSize)
    }
}
