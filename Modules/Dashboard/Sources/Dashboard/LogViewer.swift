import SwiftUI
import AppKit
import Design
import Events

/// Dashboard's rendering tint for a log level, drawn from the shared semantic table (C3) — and the
/// only place severity is turned into colour. It lives here rather than in Events because Events is
/// a leaf module that must not depend on Design.
extension LogLevel {
    var semanticColor: Color {
        switch self {
        case .info: return SemanticColor.info
        case .debug: return SemanticColor.neutral
        case .warning: return SemanticColor.warning
        case .error: return SemanticColor.error
        }
    }
}

/// Pure filtering for the Activity Log, kept out of the `LogViewer` View so the level filter,
/// case-insensitive search, and newest-first ordering are unit-testable without `@State`.
enum LogEntryFilter {
    /// Filters to entries at or above `minimumLevel` (a severity *threshold*, not exact-match), then
    /// by case-insensitive message search — preserving the input order. Shared by both the live
    /// session list and the loaded history so one Level/Search setting governs the whole window.
    ///
    /// Threshold rather than equality is the whole point: someone opening the log after a failure
    /// wants "warnings and errors", which exact-match could never express — picking WARN used to
    /// hide the ERROR they came to see. `nil` shows every level.
    static func matches(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String, now: Date = Date()) -> [LogEntry] {
        // The search string may carry `level:`/`since:` tokens (parsed once here); a token-free
        // string is exactly the legacy case-insensitive message substring. The `minimumLevel`
        // threshold from the severity chips still applies independently, ANDed with the query.
        let query = LogSearch.parse(search)
        return entries.filter { entry in
            if let minimumLevel, entry.level.severity < minimumLevel.severity { return false }
            return query.matches(entry, now: now)
        }
    }

    /// ``matches(_:minimumLevel:search:)`` newest-first — the session list's order (its entries are
    /// stored oldest-first, as logged).
    static func apply(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String) -> [LogEntry] {
        matches(entries, minimumLevel: minimumLevel, search: search).reversed()
    }
}

/// The outcome of one history read, which is NOT just "the entries".
///
/// A read failure and "there is nothing older" are opposite facts and used to be the same empty
/// array. Swallowing a failure left the window saying "No earlier activity in the log", forever and
/// falsely, with nothing recorded anywhere: this loader runs off the main actor with no error
/// channel, so it is the one path in the app that cannot present its failure through
/// `FileSyncManager.present(_:)`.
///
/// **Torn BYTES are no longer one of the ways to fail.** The log file is appended to by a second
/// process as well as this one, so a crash mid-write can leave a sequence that isn't valid UTF-8,
/// and `String(contentsOf:)` threw on it — one bad byte cost the entire history. Those bytes are
/// now repaired by ``LogHistoryLoader/repairingUTF8(_:)`` and everything around them loads, which
/// leaves this case to mean what its name says: the file could not be READ.
enum LogHistoryRead: Sendable {
    /// The file was read and parsed. The array may legitimately be EMPTY — the log genuinely holds
    /// nothing older than this session.
    case loaded([LogEntry])
    /// The file could not be read — no permission, the volume gone, the path not a file. `reason`
    /// is the underlying error's description, for the log line the caller writes. **Not** a
    /// decoding failure: bytes that are not valid UTF-8 are repaired, not refused.
    case unreadable(reason: String)

    /// The parsed entries, or nil when the read FAILED. The optional is the point: nil is not an
    /// empty array, so a caller taking this shortcut still cannot mistake a failure for an empty
    /// history — which is the whole bug this type exists to prevent.
    var loadedEntries: [LogEntry]? {
        if case .loaded(let entries) = self { return entries }
        return nil
    }
}

/// Loads previous-session history from the on-disk log so the Activity Log window can show entries
/// that predate the current launch — pure and nonisolated so the read/parse runs off the main actor
/// (the file is capped at ~5MB, so a full read per invocation is cheap) and stays unit-testable.
enum LogHistoryLoader {
    /// Every entry in `fileURL` strictly older than `sessionStart` — i.e. everything from earlier
    /// sessions, excluding the current session's lines (which the window already shows live from
    /// memory) — newest-first. Lines that don't parse are skipped.
    ///
    /// A read that THROWS comes back as `.unreadable` rather than as an empty history; see
    /// ``LogHistoryRead``. A missing file is the exception: no log file yet is a true "nothing
    /// older", not a failure, so it stays `.loaded([])` — reporting it as an error would put a
    /// scary note under a first launch that has simply never written the file.
    static func loadOlderThan(_ sessionStart: Date, fileURL: URL) -> LogHistoryRead {
        do {
            let data = try Data(contentsOf: fileURL)
            return .loaded(parseOlderThan(sessionStart, text: repairingUTF8(data)))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return .loaded([])
            }
            return .unreadable(reason: nsError.localizedDescription)
        }
    }

    /// The log's bytes as text, with every byte sequence that is not valid UTF-8 replaced by
    /// U+FFFD rather than the file being refused.
    ///
    /// **One torn byte used to cost the whole history.** A crash partway through an append — or
    /// the CLI writing this same file — can leave a multi-byte character cut in half, and the log
    /// carries file PATHS, so non-ASCII bytes are routinely in flight. `String(contentsOf:)` threw
    /// on that and the window showed an error note instead of the thousands of lines either side
    /// of it. Rotation is not a source: `trimTailIfOversized` cuts at a newline, which is always a
    /// character boundary.
    ///
    /// `String(decoding:as:)` is the standard library's REPAIRING initializer, and it is the whole
    /// implementation: one U+FFFD per malformed sequence, everything on both sides kept.
    /// Foundation's `String(data:encoding:)` is not a substitute — measured on this fixture, it
    /// answers `nil` for a UTF-8 character cut short, which is the refusal this function exists to
    /// stop. (On UTF-16 it does something worse and quieter: a partial code unit comes back as a
    /// clean string with the tail silently gone. Neither behaviour is a repair.)
    ///
    /// Internal rather than private so the repair can be asserted on bytes, without a file.
    static func repairingUTF8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// ``loadOlderThan(_:fileURL:)`` ordered behind the log writer's pending disk work.
    ///
    /// The ordering is the whole point of this function, which is why it exists instead of two
    /// statements at the call site. Clear Logs truncates the file on the writer's own
    /// **background-qos** queue, so a history load that starts right after a clear can still read
    /// the pre-clear bytes — and it does so holding a perfectly valid token, because the token
    /// guard only defends loads that were already in flight AT the clear. The just-deleted rows
    /// then come back as loaded history and stay for the window's lifetime. Draining the writer
    /// first puts this read behind any enqueued truncate.
    ///
    /// `drainWriter` is injected rather than reached for so a test can supply the pending write
    /// itself and prove the read happens after it, not before.
    static func loadOlderThanDrainingWriter(
        _ sessionStart: Date,
        fileURL: URL,
        drainWriter: () -> Void
    ) -> LogHistoryRead {
        drainWriter()
        return loadOlderThan(sessionStart, fileURL: fileURL)
    }

    /// The pure core of ``loadOlderThan(_:fileURL:)``, split out so the parse/boundary/order logic is
    /// testable without touching disk.
    static func parseOlderThan(_ sessionStart: Date, text: String) -> [LogEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { LogEntry.parse(String($0)) }
            .filter { $0.timestamp < sessionStart }
            .reversed()
    }
}

/// Which empty state the log list shows — pure so the distinctions stay unit-testable. Each dead end
/// needs different words: "No matching entries" names the filters as the cause and offers to clear
/// them; "No activity yet" explains the surface and points at the loadable history; "No earlier
/// activity" is the honest end state once history is loaded and the log holds nothing older; and
/// the same quiet session over an UNREADABLE log says so instead of offering a load that just
/// failed.
enum LogEmptyState: Equatable {
    /// Rows are visible; no empty state.
    case none
    /// Nothing logged this session and history hasn't been loaded — offer to load it.
    case noActivity
    /// History was loaded and the log holds nothing before this session.
    case noEarlierActivity
    /// Nothing logged this session AND the history read failed, so there is nothing to offer.
    ///
    /// Split out of `.noActivity` because the two say opposite things about the same file. A quiet
    /// session over a failed read classified as `.noActivity`, whose message ends "use 'Show older
    /// history' below to load what earlier sessions recorded" — directly above the footer's
    /// "Couldn't read the log file — earlier activity is unavailable". The window promised the
    /// history and denied it in the same breath, in two adjacent paragraphs.
    case historyUnavailable
    /// Entries exist (this session and/or loaded history), but the level filter and/or search hide
    /// them all.
    case noMatches

    /// - Parameters:
    ///   - hasVisibleRows: any session or history rows are currently shown.
    ///   - hasRawEntries: any session entries, or already-loaded history entries, exist before filtering.
    ///   - historyLoaded: the user has loaded history at least once this session.
    ///   - historyReadFailed: the last history read failed (`LogHistoryState.failed`). Deliberately
    ///     has NO default: it is the difference between "there is history to load" and "the file
    ///     couldn't be read", and a caller that omitted it would silently re-print the contradiction
    ///     `.historyUnavailable` exists to end.
    static func classify(hasVisibleRows: Bool,
                         hasRawEntries: Bool,
                         historyLoaded: Bool,
                         historyReadFailed: Bool) -> LogEmptyState {
        if hasVisibleRows { return .none }
        if hasRawEntries { return .noMatches }
        if historyLoaded { return .noEarlierActivity }
        return historyReadFailed ? .historyUnavailable : .noActivity
    }

    /// Whether the history FOOTER should add its own "No earlier activity in the log" note.
    ///
    /// The footer and the in-flow empty state are independent views that reached the same
    /// conclusion by different routes, so a quiet session over an empty history rendered the fact
    /// twice on one screen — `.noEarlierActivity`'s "the log holds nothing from earlier sessions"
    /// directly above "No earlier activity in the log". The empty state is the fuller of the two
    /// (it also explains what the window records), so it keeps the floor and the footer yields.
    ///
    /// It still speaks in every other loaded-and-empty case — most importantly when the session
    /// DID log something, where the empty state isn't rendered at all and this note is the only
    /// word on the subject.
    static func footerNotesNoEarlierActivity(historyIsEmpty: Bool, emptyState: LogEmptyState) -> Bool {
        historyIsEmpty && emptyState != .noEarlierActivity
    }

    /// Whether the history FOOTER should add its own "Couldn't read the log file" note.
    ///
    /// The same yield rule as ``footerNotesNoEarlierActivity(historyIsEmpty:emptyState:)`` and for
    /// the same reason: once `.historyUnavailable` renders, the failed read is already stated —
    /// more fully, and in the place the eye lands first — so repeating it in the footer is the
    /// double-render again. The retry BUTTON is unaffected; it is an action, not a second telling,
    /// and the empty state's message points at it by name.
    ///
    /// It still speaks whenever the empty state is saying something else — most importantly when
    /// the session DID log something, where no empty state renders at all and this note is the only
    /// word on why the earlier history isn't there.
    static func footerNotesUnreadableHistory(emptyState: LogEmptyState) -> Bool {
        emptyState != .historyUnavailable
    }
}

/// Everything the Activity Log's list and chip row derive from the session entries plus the history
/// STATE — computed in one pure pass so the parts cannot disagree with each other.
///
/// The bug this exists to prevent is a disagreement, not a miscount: the severity chips set a
/// threshold that filters the session rows AND the loaded history, but the counts were tallied from
/// the session alone, so an "Errors 0" chip sat above a screenful of history error rows. Fixing the
/// tally at the call site left the hole open — `history: []` is a one-line edit, and every test
/// passed either way because they all called `thresholdCounts` directly.
///
/// So the history state enters here ONCE and feeds both the counts and the rows. Reverting the
/// counts now means handing this a different history than the rows are drawn from, which no longer
/// fits through the API: there is one `history` parameter, and emptying it empties the visible rows
/// too — a change that is loud on screen instead of silent.
///
/// It really is a pure value — nonisolated, constructible from anywhere. That is not free: every
/// helper it reaches has to be nonisolated too, and `LogViewer.thresholdCounts` is a static on a
/// SwiftUI `View`, which SwiftUI isolates to the main actor along with the rest of the type.
/// Calling one of those from off-actor SIGTRAPs at runtime while compiling with only a warning, so
/// constructing this inside a `Task.detached` crashed. The counting is `nonisolated` for that
/// reason; keep any future helper this init reaches the same way, or move the work behind the
/// actor and mark the whole type `@MainActor` — what must not happen again is a nonisolated init
/// over main-actor-isolated work.
struct LogViewerContents {
    /// Session entries after the level/search filter, newest-first — the main list.
    let sessionRows: [LogEntry]
    /// Per-threshold tallies for the chip row, keyed by `LogLevel?` (nil is the "All" total).
    let levelCounts: [LogLevel?: Int]
    /// The revealed page of filtered history rows (empty unless history is loaded).
    let visibleHistory: [LogEntry]
    /// How many rows the next "Show N more" tap would actually reveal; 0 gates the button off.
    let nextReveal: Int
    /// Which empty state (if any) the list shows.
    let emptyState: LogEmptyState

    /// - Parameters:
    ///   - session: the live in-memory entries, oldest-first as logged.
    ///   - history: the on-demand history's state — the same value that decides what the footer
    ///     renders. Deliberately the STATE and not an array: "not loaded", "loading", "failed" and
    ///     "loaded but empty" contribute nothing to the tally for different reasons, and passing
    ///     entries would let a caller quietly substitute a different set for the counts.
    ///   - now: clock for `since:` search tokens, taken once so the session rows, the history rows
    ///     and the counts are all filtered against the same instant.
    init(session: [LogEntry],
         history: LogHistoryState,
         minimumLevel: LogLevel?,
         search: String,
         pageSize: Int,
         now: Date = Date()) {
        let loadedHistory = history.entries
        sessionRows = LogEntryFilter.matches(session, minimumLevel: minimumLevel, search: search, now: now).reversed()
        // The chips count what the threshold filters: the session AND all LOADED history — not the
        // revealed page. "Show more" reveals further into this same set, so a count that grew as
        // you paged would describe the scroll position rather than what the window holds.
        levelCounts = LogViewer.thresholdCounts(session: session, history: loadedHistory ?? [])
        // History respects the same Level/Search filters as the session; it is already newest-first.
        let historyMatches = loadedHistory.map {
            LogEntryFilter.matches($0, minimumLevel: minimumLevel, search: search, now: now)
        } ?? []
        visibleHistory = Array(historyMatches.prefix(history.revealed))
        nextReveal = LogHistoryState.nextRevealCount(
            matchCount: historyMatches.count, revealed: history.revealed, pageSize: pageSize)
        emptyState = LogEmptyState.classify(
            hasVisibleRows: !(sessionRows.isEmpty && visibleHistory.isEmpty),
            hasRawEntries: !session.isEmpty || !(loadedHistory?.isEmpty ?? true),
            historyLoaded: history.isLoaded,
            historyReadFailed: history.readFailed
        )
    }
}

/// An interactive slide-over or floating inspector pane that filters and displays historical LogEntry traces.
public struct LogViewer: View {
    @ObservedObject public var logger = Logger.shared
    
    public init() {}
    
    // The minimum severity to show (a threshold, not exact-match). Defaults to All Levels (nil)
    // so a user opening the log sees everything recorded; picking "Warnings & above" keeps errors
    // in view, which the old exact-match filter couldn't do.
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchText: String = ""
    /// Whether the search field is revealed. Collapsed by default and toggled by the header's
    /// magnifier — Design's `ExpandingSearch` mechanism, the same one Compare and the Organize lenses
    /// drive, so the log's search expands, focuses, escapes and clears exactly like theirs
    /// instead of being this window's own always-visible field.
    @State private var isSearchExpanded = false
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    /// The glass hue, so the accent-tinted chrome (token chips, the selected severity chip)
    /// matches the hue every other window passes to the same components — the lens workspace hands this exact
    /// tint to `TokenChipsRow`; the Log window used to hardcode `Color.accentColor` instead.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// The Tint slider. Read here for the same reason the level and hue are: this window paints the
    /// main window's background, so it has to scale its accent by the same amount or the Activity
    /// Log comes up at full strength beside a faintly-tinted app.
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// List-density setting (H7): comfortable renders exactly the pre-setting look; compact
    /// tightens the row spacing so more log lines fit on screen.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var hueAccent: Color { glassHue.accentColor }

    /// What the SELECTED level chip fills with: the deepened accent, since it carries a white
    /// label. Everything else here (hover washes, token-chip tints, hairlines) keeps `hueAccent` —
    /// no white label to carry, and deepening a wash only muddies it.
    private var hueAccentFill: Color { glassHue.accentFillColor }

    /// Text/glyph color on a `hueAccentFill` fill — white for every hue, because that fill is
    /// deepened until white clears 4.5:1 on it. See `LiquidGlassHue.onAccentLabelColor` for why the
    /// app moved the fill instead of flipping the label per-hue.
    private var onHueAccent: Color { glassHue.onAccentLabelColor }

    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// Previous-session entries pulled from `~/sync-cloud.log` on demand (newest-first), and the
    /// state of that fetch. The window shows the live in-memory session by default; this backfills
    /// the record that predates the current launch, in-window, without opening the file externally.
    /// Whether that history has been asked for, is being read, or is loaded — and, once loaded, how
    /// much of it is revealed. See ``LogHistoryState``: this replaced four separate `@State` vars
    /// that every path had to move in lockstep, two of whose combinations were meaningless.
    @State private var history: LogHistoryState = .notLoaded

    /// Page size for the on-demand history: the first "Show older history" reveals this many, and each
    /// "Show more" reveals another page.
    private static let historyPageSize = 25

    /// Height of the standard macOS title bar the header must clear. The window hides its title
    /// bar so the glass reaches the top edge (no white slab, matching Settings), which leaves the
    /// traffic lights floating over the content's first rows.
    static let titleBarInset: CGFloat = 28

    /// Menu options for the severity threshold. Debug is omitted as its own row because
    /// "Debug & above" is identical to "All Levels".
    ///
    /// `nonisolated` for the same reason `thresholdCounts` is: the tally walks this list, and a
    /// main-actor-isolated static read from a nonisolated context is exactly the trap that function
    /// exists to stay out of. The value is an immutable `Sendable` table, so nothing is given up.
    private nonisolated static let levelOptions: [(label: String, level: LogLevel?)] = [
        ("All Levels", nil),
        ("Info & above", .info),
        ("Warnings & above", .warning),
        ("Errors", .error),
    ]

    /// Short labels for the severity filter chips — same thresholds as `levelOptions`, trimmed so four
    /// pills fit the narrow log window. Counts are looked up from the shared `thresholdCounts`.
    private static let chipOptions: [(label: String, level: LogLevel?)] = [
        ("All", nil),
        ("Info", .info),
        ("Warnings", .warning),
        ("Errors", .error),
    ]

    /// One O(N) pass tallying how many entries sit at or above each menu threshold (plus the total
    /// under the `nil`/"All Levels" key). Computed once per body render and read by the picker
    /// labels, instead of a full `entries` reduce per option on every render.
    ///
    /// Counts the session AND any revealed history, because the threshold these chips set filters
    /// both. Tallying the session alone put an "Errors 0" chip directly above a screenful of
    /// history error rows — which happens whenever a quiet session sits under a raised threshold,
    /// the exact situation someone opens the history for. The two arrays are walked in place rather
    /// than concatenated: this runs on every body render, and the session list alone reaches
    /// thousands of entries.
    // Internal, not private: `LogLevelChipCountTests` pins the session+history tally directly. It is
    // reached from `body` only through `LogViewerContents`, which is what decides — from the history
    // STATE — which entries are counted; this function just adds up whatever it is handed.
    //
    // `nonisolated` is load-bearing, not tidiness. `LogViewer` is a `View`, so SwiftUI isolates the
    // whole type — including its statics — to the main actor, and a static on a `View` called from
    // off-actor SIGTRAPs at runtime with nothing but a warning at compile time. `LogViewerContents`
    // is documented as (and used as) a pure value with a nonisolated `init`, so it reaches this from
    // exactly such a context: constructing one inside `Task.detached` trapped. Nothing here needs
    // the actor — it is arithmetic over two arrays — so the counting is declared for what it is
    // rather than the value being pinned to the main actor to match the arithmetic's accident.
    nonisolated static func thresholdCounts(session: [LogEntry], history: [LogEntry]) -> [LogLevel?: Int] {
        var perLevel: [LogLevel: Int] = [:]
        for e in session { perLevel[e.level, default: 0] += 1 }
        for e in history { perLevel[e.level, default: 0] += 1 }
        var out: [LogLevel?: Int] = [nil: session.count + history.count]
        for option in levelOptions {
            guard let lvl = option.level else { continue }
            out[lvl] = perLevel.reduce(0) { $0 + ($1.key.severity >= lvl.severity ? $1.value : 0) }
        }
        return out
    }

    /// Copies the on-screen slice (current level + search filter) to the clipboard as canonical log
    /// lines — the fast path for pasting into a bug report. Emitted oldest-first so the paste reads
    /// chronologically and matches the on-disk file's order (the list itself shows newest-first).
    private func copyVisibleEntries(_ entries: [LogEntry]) {
        let text = entries.reversed().map(\.formattedString).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reads previous-session history off the main actor and reveals the first page. The boundary is
    /// the current session's first in-memory entry (the launch breadcrumb), so nothing the window
    /// already shows live is duplicated. Reading a ≤5MB file once per open is cheap; "Show more" then
    /// just reveals further into the already-parsed array without re-reading.
    @MainActor
    private func loadHistory() {
        // Claiming the load IS the guard: `beginLoading` returns nil when a read is already in
        // flight or the history is loaded, so the double-fire check cannot be forgotten.
        guard let token = history.beginLoading() else { return }
        // Everything on disk older than this app session's start is prior-session history. Use the
        // fixed session-start timestamp, NOT `entries.first` — the memory cache is trimmed to the
        // newest N, so after a busy session `entries.first` drifts into the current session and
        // would pull current-session lines (and the ms-truncated launch breadcrumb) into "history".
        // Floored to the on-disk MILLISECOND precision: the writer rounds timestamps to ms,
        // so the session's first line (logged microseconds after sessionStart) can serialize
        // BELOW the raw boundary on ~half of launches — classifying the launch breadcrumb as
        // "history" and showing (and copying) it twice. Flooring keeps every line whose
        // rounded timestamp equals the boundary's ms on the session side; genuine history is
        // seconds older and unaffected.
        let raw = logger.sessionStart.timeIntervalSinceReferenceDate
        let boundary = Date(timeIntervalSinceReferenceDate: (raw * 1000).rounded(.down) / 1000)
        let fileURL = logger.logFileURL
        // Taken here (main actor) but RUN inside the detached read below: the barrier blocks until
        // the writer's queue drains, which is exactly what must not happen on the main actor.
        let drainWriter = logger.diskWriteBarrier()
        // Token guard: Clear Logs mid-flight resets the state, and a completion parsed from the
        // PRE-clear file must not overwrite that reset — it would resurrect deleted rows AND (by
        // making the history non-nil again) hide the reload button for the window's lifetime.
        // `finishLoading` applies the parse only while this token is still the one being awaited.
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                LogHistoryLoader.loadOlderThanDrainingWriter(
                    boundary,
                    fileURL: fileURL,
                    drainWriter: drainWriter
                )
            }.value
            switch outcome {
            case .loaded(let parsed):
                history.finishLoading(parsed, token: token, pageSize: Self.historyPageSize)
            case .unreadable(let reason):
                // The failure is logged HERE, on the main actor, rather than inside the detached
                // read: `Logger.shared` is a MainActor-isolated static, and the read is the one
                // place in the app with no error channel of its own. Logging unconditionally (not
                // only when the token still matches) is deliberate — the read really did fail, and
                // a superseded load's failure is exactly as diagnostic as a current one's.
                logger.error("Could not read \(fileURL.lastPathComponent) for the Activity Log's earlier history: \(reason)")
                history.failLoading(token: token)
            }
        }
    }

    public var body: some View {
        // One pure pass per body evaluation, from the session entries and the history STATE: the
        // filtered rows, the chip tallies, the revealed history page, the "Show N more" remainder
        // and the empty state. They are derived together (see `LogViewerContents`) because they
        // must describe the same set — the chips counting one thing while the list showed another
        // is the bug this window shipped. It is also cheaper: the isEmpty checks and the ForEach
        // below would otherwise each re-run the full filter pass.
        let contents = LogViewerContents(
            session: logger.entries,
            history: history,
            minimumLevel: selectedLevel,
            search: searchText,
            pageSize: Self.historyPageSize
        )
        let filtered = contents.sessionRows
        let levelCounts = contents.levelCounts
        let visibleHistory = contents.visibleHistory
        let nextReveal = contents.nextReveal
        let emptyState = contents.emptyState
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Text("Activity Log")
                    .scaledFont(.headline)
                Spacer()

                // Copy covers EVERYTHING on screen — session rows AND any revealed "Earlier
                // sessions" page. Session entries are all newer than the history boundary, so
                // the concatenation stays globally newest-first and the copier's single
                // reversed() yields one chronological paste. It also enables on history alone:
                // a quiet session with 25 revealed history rows used to show a disabled Copy
                // under a help text promising "the 25 shown entries".
                let shownCount = filtered.count + visibleHistory.count
                Button(action: { copyVisibleEntries(filtered + visibleHistory) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                .disabled(filtered.isEmpty && visibleHistory.isEmpty)
                .help("Copy the \(shownCount) shown \(shownCount == 1 ? "entry" : "entries") to the clipboard")
                .accessibilityLabel("Copy the shown entries")

                // The history reset rides the Logger's own notification, NOT this button:
                // Settings has its own Clear Logs door, and a reset wired to one button left
                // the other door resurrecting deleted history rows. The on-disk file was
                // truncated, so parsed history must drop (and the reload button reappear —
                // it only renders while the history is unloaded); the reset also invalidates any
                // IN-FLIGHT load's token, so its pre-clear parse is discarded instead of applied.
                Button(action: { logger.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .onReceive(NotificationCenter.default.publisher(for: Logger.didClearLogsNotification)) { _ in
                    history.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                // Enabled while there is anything ON SCREEN to clear — session entries OR revealed
                // history rows. Gating on `entries` alone left the button dead above a screenful of
                // history whenever the session list was empty (a quiet session under an
                // "Errors only" threshold is exactly that), with Settings ▸ Advanced the only way out.
                .disabled(logger.entries.isEmpty && !history.isLoaded)
                .help("Clear Logs")
                .accessibilityLabel("Clear the log")

                Button(action: { logger.openLogFile() }) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                .help("Open in Console/TextEdit")
                .accessibilityLabel("Open the log file")

                // Search collapses to this magnifier — last item, far right, exactly where
                // Compare's header puts it. Clicking reveals the field on the row below, which
                // claims focus itself; a second click (or Escape) collapses and clears.
                ExpandingSearchToggle(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    accent: hueAccent,
                    help: "Search the log by message, level, or age"
                )
            }
            // Plain header row directly on the window glass — the Settings pattern (its title row
            // carries no bar background), so no white slab across the top.
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // The window is `.hiddenTitleBar`, so the glass runs all the way up and the content
            // starts under the traffic lights — inset the header past them. Without this the
            // title sits behind the close/minimize/zoom buttons.
            .padding(.top, LogViewer.titleBarInset)

            // Severity filter chips — the level threshold as tappable pills (All / Info & above /
            // Warnings & above / Errors), each carrying its live count. Replaces the old menu so the
            // active scope is always visible, not one click away.
            // Horizontal scroll so four chips with large counts never compress/truncate on the
            // narrow (380 pt) log window.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.chipOptions, id: \.label) { option in
                        levelChip(option.label, level: option.level, count: levelCounts[option.level] ?? 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // Search Bar — revealed by the header's magnifier. The query, plus (below) the parsed
            // filter tokens as removable chips and, while focused, one-tap suggestions. Design's
            // `ExpandingSearchField` carries the field, its clear button, focus-on-appear and
            // Escape, so this window's search behaves exactly like Compare's and the lens workspaces'.
            if isSearchExpanded {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
            // The transition above needs a driving animation or it never runs — an `if` alone
            // inserts and removes the field instantly, which is what shipped.


            // Log List. The empty state renders in-flow (not as an overlay) so the "Show older
            // history" footer below it stays reachable even when this session logged nothing.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: densityMetrics.logListSpacing) {
                    if emptyState == .none {
                        daySections(filtered)
                    } else {
                        emptyStateView(emptyState)
                    }
                    historyFooter(visibleHistory: visibleHistory, nextReveal: nextReveal, emptyState: emptyState)
                }
                .padding(16)
            }
            // No surface of its own: the list sits directly on the window's glass background,
            // exactly like Settings' content area.
        }
        .frame(minWidth: 380)
        // A new filter/search is a fresh view of history — collapse back to the first page so the
        // list doesn't stay expanded to hundreds of now-filtered rows.
        .onChange(of: selectedLevel) { _, _ in history.resetRevealed(to: Self.historyPageSize) }
        .onChange(of: searchText) { _, _ in history.resetRevealed(to: Self.historyPageSize) }
        // Drives the search field's reveal/hide transition (see above).
        .designAnimation(.easeOut(duration: 0.14), value: isSearchExpanded)
        // Match the main window's glass: same level + hue background, so the Activity Log reads as
        // the same frosted (or, at Clear, whiter see-through) surface instead of a plain window.
        .liquidGlassAppBackground(level: glassLevel, hue: glassHue, tint: surfaceTint)
        // Keep the glass from graying out when this window isn't key (see the main window).
        .environment(\.controlActiveState, .active)
    }

    // MARK: Search field

    /// The revealed search field: Design's shared `ExpandingSearchField` (query, clear button,
    /// focus-on-appear, Escape-to-collapse) carrying this window's own accessories — the parsed
    /// `level:`/`since:` chips, and the one-tap suggestions while the field holds the caret.
    private var searchField: some View {
        let chips = LogSearch.chips(searchText)
        return ExpandingSearchField(
            text: $searchText,
            isExpanded: $isSearchExpanded,
            placeholder: "Filter — try level:error, since:1h",
            accessories: { isFocused in
                if !chips.isEmpty {
                    logTokenChips(chips)
                }
                if isFocused {
                    logSuggestionRow(active: chips)
                }
            }
        )
    }

    // MARK: Token chips & suggestions

    /// The parsed `level:`/`since:` tokens as removable chips (Design's shared `TokenChipsRow`):
    /// a plain reading of the query, each with an ✕ that edits that word back out of the raw text.
    private func logTokenChips(_ chips: [LogSearch.Chip]) -> some View {
        HStack(spacing: 6) {
            TokenChipsRow(
                items: chips.map { TokenChipsRow.Item(label: $0.label, word: $0.raw, isActive: $0.isActive) },
                tint: hueAccent,
                onRemove: { word in searchText = LogSearch.removing(searchText, word: word) }
            )
            Spacer(minLength: 0)
        }
    }

    /// One-tap filter suggestions shown while the field is focused, omitting any family already active
    /// (level and since are each single-valued, so a second one just replaces the first).
    @ViewBuilder
    private func logSuggestionRow(active: [LogSearch.Chip]) -> some View {
        let suggestions = logSuggestions(active: active)
        if !suggestions.isEmpty {
            HStack(spacing: 6) {
                Text("Add filter")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                ForEach(suggestions, id: \.raw) { suggestion in
                    Button {
                        // Trim first so appending never leaves a double space when the field already
                        // ends in whitespace.
                        let base = searchText.trimmingCharacters(in: .whitespaces)
                        searchText = base.isEmpty ? suggestion.raw : base + " " + suggestion.raw
                    } label: {
                        Text(suggestion.label)
                            .scaledFont(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.hoverAffordance(.segment, tint: hueAccent))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private static let logSuggestionCandidates: [(label: String, raw: String)] = [
        ("Errors", "level:error"),
        ("Warnings", "level:warning"),
        ("Last hour", "since:1h"),
        ("Last day", "since:1d"),
    ]

    private func logSuggestions(active: [LogSearch.Chip]) -> [(label: String, raw: String)] {
        let hasLevel = active.contains { $0.raw.lowercased().hasPrefix("level:") }
        let hasSince = active.contains { $0.raw.lowercased().hasPrefix("since:") }
        return Self.logSuggestionCandidates.filter { candidate in
            if candidate.raw.hasPrefix("level:") { return !hasLevel }
            if candidate.raw.hasPrefix("since:") { return !hasSince }
            return true
        }
    }

    // MARK: Severity chips

    /// One severity-threshold pill: its label, its live count, and a filled state when it's the active
    /// threshold. Tapping sets the same `selectedLevel` the old menu did, so the filter logic is
    /// unchanged — only its presentation.
    @ViewBuilder
    private func levelChip(_ label: String, level: LogLevel?, count: Int) -> some View {
        let selected = selectedLevel == level
        Button {
            selectedLevel = level
        } label: {
            // White on a deepened fill — which is, in the end, what AppKit's
            // alternateSelectedControlTextColor always claimed: it returns white under every accent
            // because it pairs with the *darkened* selection fill. The old bug was pairing it with
            // the RAW accent (white-on-Yellow, ~1.6:1). Deepening the fill makes the claim true.
            let onAccent = onHueAccent
            HStack(spacing: 5) {
                Text(label)
                Text(count.formatted())
                    .monospacedDigit()
                    // Dimmed via the shared floor constant, not a local literal: 0.85 white on
                    // the Graphite hue composited to ~2.97:1, under the 3:1 large-text minimum.
                    .foregroundStyle(selected
                        ? AnyShapeStyle(onAccent.opacity(AccentLabel.dimmedOnFillOpacity))
                        : AnyShapeStyle(.secondary))
            }
            .scaledFont(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
            .background(
                // Selected fills with the glass hue (the accent every other window's chips use);
                // unselected wears the canonical badge wash (`PillVariant.fillOpacity`).
                Capsule().fill(selected ? AnyShapeStyle(hueAccentFill) : AnyShapeStyle(Color.secondary.opacity(PillVariant.fillOpacity)))
            )
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(selected ? .filled : .segment, tint: hueAccent))
        .fixedSize()
        .help("Show \(label.lowercased())")
        // **Exactly one of these is active, which makes it this window's primary state — and it
        // was carried only by ink, fill and border width.** `.help` describes the ACTION ("Show
        // errors"), never the state, and on macOS it lands on the accessibility help rather than
        // the name. The label and count go into one spoken name so the chip does not announce as
        // two unrelated strings, and the trait says which one is on.
        // `.accessibilityLabel` alone, NOT `.accessibilityElement(children: .ignore)`. This is a
        // `Button`; the container form is for views that are not already one element, and applied
        // to a Button it replaces the element AppKit would have activated. A label on the Button
        // does the one thing needed — replace the two concatenated child texts with one spoken
        // name — and cannot cost the chip its action. Untestable from here either way: assertions
        // against the live accessibility tree pass vacuously with no assistive client attached,
        // which is exactly why the form that cannot break is the one to use.
        .accessibilityLabel("\(label), \(count.formatted())")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Day-grouped list

    /// Renders `entries` (session or history) as day sections, folding per-file operation runs. Shared
    /// by the live list and the loaded-history footer so both read identically.
    @ViewBuilder
    private func daySections(_ entries: [LogEntry]) -> some View {
        ForEach(LogGrouping.byDay(entries)) { section in
            LogDayHeader(text: section.header)
            ForEach(section.items) { item in
                switch item {
                case .entry(let entry):
                    LogEntryRow(entry: entry, density: density)
                case .group(let group):
                    LogOperationGroupRow(group: group, density: density, accent: hueAccent)
                }
            }
        }
    }

    // MARK: History footer

    /// The bottom-of-list history controls: before loading, one "Show older history" button; after,
    /// a divider, the revealed history rows, and either "Show more" or an end-of-log note.
    ///
    /// `nextReveal` is how many rows the "Show more" button would actually reveal (0 when none are
    /// left), and `emptyState` is what the in-flow empty state above is already saying — passed in
    /// rather than recomputed so the footer can hold its tongue when the two would agree.
    @ViewBuilder
    private func historyFooter(visibleHistory: [LogEntry], nextReveal: Int, emptyState: LogEmptyState) -> some View {
        if let loadedEntries = history.entries {
            if !visibleHistory.isEmpty {
                historyDivider
                daySections(visibleHistory)
                if nextReveal > 0 {
                    // The TRUE remainder, not the page size: on the last page this used to promise
                    // 25 and hand over 5.
                    historyActionButton("Show \(nextReveal) more", icon: "chevron.down") {
                        history.revealMore(by: Self.historyPageSize)
                    }
                } else {
                    historyEndNote("No older entries — you're at the start of the log")
                }
            } else if LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: loadedEntries.isEmpty,
                                                                emptyState: emptyState) {
                // Loaded, and the log holds nothing before this session — said here only when the
                // empty state above isn't already saying it.
                historyEndNote("No earlier activity in the log")
            }
            // else: history exists but the current filter hides it — the empty state / session rows
            // already explain the emptiness; no separate note needed.
        } else if history.readFailed {
            // A failed read is NOT "nothing older" (see `LogHistoryState.failed`): say what
            // happened, and keep the same button so the user can simply try again — an unreadable
            // log is usually a torn write that the next read gets past.
            //
            // The note yields to `.historyUnavailable` when the empty state above is already
            // carrying the same fact (a quiet session); the button is not a telling and always
            // stays. See `footerNotesUnreadableHistory`.
            if LogEmptyState.footerNotesUnreadableHistory(emptyState: emptyState) {
                historyEndNote("Couldn't read the log file — earlier activity is unavailable")
            }
            historyActionButton("Show older history", icon: "clock.arrow.circlepath") { loadHistory() }
        } else {
            historyActionButton("Show older history", icon: "clock.arrow.circlepath",
                                 loading: history.isLoading) { loadHistory() }
        }
    }

    private var historyDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider().opacity(0.5) }
            Text("Earlier sessions")
                .scaledFont(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
            VStack { Divider().opacity(0.5) }
        }
        .padding(.vertical, 6)
    }

    private func historyActionButton(_ title: String, icon: String, loading: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon)
                    }
                    Text(loading ? "Loading…" : title)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .chromeHover(tint: hueAccent)
            .disabled(loading)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func historyEndNote(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 10)
    }

    // MARK: Empty state

    /// The in-flow empty state: distinguishes a quiet session (offer history), a log with nothing
    /// older (once loaded), and filters that hide everything. Mirrors the app's EmptyStateView
    /// template used elsewhere.
    ///
    /// The state is classified by `body` and passed in, not derived here: the footer needs the same
    /// answer (so it can stay quiet when this view already speaks), and two independent derivations
    /// are what let the window say "no earlier activity" twice in one render.
    @ViewBuilder
    private func emptyStateView(_ state: LogEmptyState) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .noMatches:
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching entries",
                message: "The current level filter and search hide every entry. Clear them to see the log again.",
                primary: .init("Clear Filters", systemImage: "xmark.circle") {
                    selectedLevel = nil
                    searchText = ""
                }
            )
        case .noEarlierActivity:
            EmptyStateView(
                icon: "clock",
                title: "No activity recorded",
                message: "This session is quiet and the log holds nothing from earlier sessions. Scans, copies, moves and deletes appear here as they happen."
            )
        case .noActivity:
            // Quiet session, history not loaded — point at the history that lives in the file, loadable
            // right here with the footer button below.
            EmptyStateView(
                icon: "list.bullet.rectangle",
                title: "No activity yet",
                message: "Every scan, copy, move and delete is recorded here as it happens. This session is quiet so far — use “Show older history” below to load what earlier sessions recorded."
            )
        case .historyUnavailable:
            // Quiet session AND the read failed. Says the failure once, in the fuller of the two
            // places (the footer's note yields), and names the button as a RETRY rather than as an
            // offer to load history the app has just failed to read.
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "No activity recorded",
                message: "This session is quiet so far, and the log file couldn’t be read — earlier activity is unavailable. Scans, copies, moves and deletes appear here as they happen; “Show older history” below tries the file again."
            )
        }
    }
}

/// An atomic row view rendering a single LogEntry with color-coded severity icons.
/// Internal (not private) so the snapshot tests can pin the severity color/icon pairings.
struct LogEntryRow: View {
    let entry: LogEntry
    /// List-density setting (H7), passed down by the parent (which already reads the defaults
    /// key) instead of a per-row `@AppStorage` — one storage observer per window, not per row.
    /// Comfortable keeps the two-line pill/time-over-message layout exactly; compact collapses
    /// to one baseline row and drops the Location tail. Neither truncates: a message too long
    /// for the window wraps in both densities.
    var density: ListDensity = .comfortable

    private var densityMetrics: ListDensityMetrics { density.metrics }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .scaledFont(.caption)
                .foregroundStyle(entry.level.semanticColor)
                .frame(width: 18)
                .padding(.top, 2)

            if density == .compact {
                // One baseline row: pill, time, then the message — the scanning eye gets a column
                // of aligned messages instead of two-line blocks.
                //
                // The message WRAPS rather than truncating. Compact used to clamp it to
                // `lineLimit(1)`, which held "one row per entry" at the cost of hiding the end of
                // every long line — and a log's long lines are its paths and failure reasons, the
                // things this window exists to show. Narrowing the window silently ellipsised them
                // with no way to read the rest short of widening again. Short entries (nearly all
                // of them) still occupy exactly one line, so the density is unchanged in practice;
                // only a line too long for the window now costs a second row instead of its tail.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    levelPill
                    timeText
                    messageText
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        levelPill
                        timeText
                    }

                    messageText

                    // The `Location: file:line / function` tail that warnings/errors carry is a
                    // developer breadcrumb, not the event — show it dimmed and smaller so the row
                    // reads as its message. Still selectable; the full line remains in the log file
                    // and in Copy.
                    if densityMetrics.showsSecondaryDetail, let location = entry.messageLocation {
                        Text(location)
                            .scaledFont(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
    }

    private var levelPill: some View {
        Pill(.mini, tint: entry.level.semanticColor, text: entry.level.rawValue)
    }

    private var timeText: some View {
        Text(timeString(from: entry.timestamp))
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
    }

    private var messageText: some View {
        Text(entry.messageBody)
            .scaledFont(.system(.subheadline, design: .monospaced))
            .textSelection(.enabled)
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned locale + calendar, the same rule SyncHistoryRow follows and for the same reason:
        // an unpinned fixed-format DateFormatter follows the system region, which can rewrite even
        // an explicit "HH" into a 12-hour clock — so the row would disagree with the line Copy puts
        // on the clipboard and with the on-disk log. Timezone stays local: this column is display.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func timeString(from date: Date) -> String {
        return Self.timeFormatter.string(from: date)
    }
}

/// A day divider ("Today" / "Yesterday" / a date) above that day's rows.
private struct LogDayHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .scaledFont(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// A folded operation run (e.g. "Synced 12 files") as an expandable disclosure row. Collapsed by
/// default — the point is to fold a bulk action's per-file lines out of the way — but the header
/// keeps the run's highest severity color so a failure inside a run is never hidden.
private struct LogOperationGroupRow: View {
    let group: LogGrouping.OperationGroup
    /// Passed down by LogViewer (see `LogEntryRow.density`); also forwarded to the expanded
    /// per-file child rows.
    var density: ListDensity = .comfortable
    /// The glass hue, forwarded rather than re-read from `@AppStorage`: this row renders once
    /// per folded run, and one storage observer per row is a lot of observers for one color.
    var accent: Color = .accentColor
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: group.icon)
                        .scaledFont(.caption)
                        .foregroundStyle(group.level.semanticColor)
                        .frame(width: 18)
                    Text(group.title)
                        .scaledFont(.subheadline.weight(.semibold))
                    // The folded run's entry count — Design's neutral mini pill, not a
                    // hand-rolled capsule, so the badge matches every other count badge.
                    Pill(.mini, tint: .secondary, text: group.count.formatted(), isNumeric: true)
                    Spacer(minLength: 8)
                    Text(Self.timeString(group.timestamp))
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.row, tint: accent))

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.children) { LogEntryRow(entry: $0, density: density) }
                }
                .padding(.leading, 22)
            }
        }
        // The header follows the density setting like its child rows already did (clamped so
        // comfortable keeps the original 4pt; compact drops to the flat-row 2pt).
        .padding(.vertical, min(4, density.metrics.flatRowVerticalPadding))
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(expanded ? "expanded" : "collapsed")")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned locale + calendar, the same rule SyncHistoryRow follows and for the same reason:
        // an unpinned fixed-format DateFormatter follows the system region, which can rewrite even
        // an explicit "HH" into a 12-hour clock — so the row would disagree with the line Copy puts
        // on the clipboard and with the on-disk log. Timezone stays local: this column is display.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
}
