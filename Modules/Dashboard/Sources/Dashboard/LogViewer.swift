import SwiftUI
import AppKit
import Design
import Events
import Settings

/// Dashboard's tint for a log level, from the shared semantic table, and the only place severity
/// becomes colour. It lives here, not in Events, because Events is a leaf module that must not
/// depend on Design.
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

/// Pure filtering for the Activity Log, kept out of the `LogViewer` View so the level filter and
/// case-insensitive search are unit-testable without `@State`.
enum LogEntryFilter {
    /// Filters to entries at or above `minimumLevel`, then by the search query, keeping input order.
    /// Shared by the session list and the loaded history so one Level/Search setting governs the
    /// whole window.
    ///
    /// A threshold, not an exact match: someone opening the log after a failure wants "warnings and
    /// errors", and picking WARN must not hide the ERROR they came to see. `nil` shows every level.
    static func matches(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String, now: Date = Date()) -> [LogEntry] {
        // The search may carry `level:`/`since:` tokens; a token-free string is a plain
        // case-insensitive message substring. The chips' `minimumLevel` threshold applies too, ANDed.
        let query = LogSearch.parse(search)
        return entries.filter { entry in
            if let minimumLevel, entry.level.severity < minimumLevel.severity { return false }
            return query.matches(entry, now: now)
        }
    }
}

/// The outcome of one history read, which is not just "the entries".
///
/// A failed read and "there is nothing older" are opposite facts and must not share an empty
/// array, or the window says "No earlier activity in the log" falsely, with nothing recorded. This
/// loader runs off the main actor with no error channel, so it can't present a failure through
/// `FileSyncManager.present(_:)`.
///
/// Torn bytes are not a failure: the log has a second writer, so a crash mid-write can leave
/// invalid UTF-8, and ``LogHistoryLoader/repairingUTF8(_:)`` repairs it so everything around it
/// loads. This case means only that the file could not be read.
enum LogHistoryRead: Sendable {
    /// The file was read and parsed. The array may be empty: the log holds nothing older than this
    /// session.
    case loaded([LogEntry])
    /// The file could not be read: no permission, the volume gone, the path not a file. `reason` is
    /// the error's description, for the log line the caller writes. Not a decoding failure: invalid
    /// UTF-8 is repaired, not refused.
    case unreadable(reason: String)

    /// The parsed entries, or nil when the read failed. Nil is not an empty array, so a caller
    /// taking this shortcut still can't mistake a failure for an empty history.
    var loadedEntries: [LogEntry]? {
        if case .loaded(let entries) = self { return entries }
        return nil
    }
}

/// Loads previous-session history from the on-disk log, so the Activity Log can show entries from
/// before this launch. Pure and nonisolated, so the read runs off the main actor (the file is capped
/// at ~5MB, so a full read is cheap) and stays unit-testable.
enum LogHistoryLoader {
    /// Every entry in `fileURL` older than `sessionStart`, newest-first: earlier sessions only, since
    /// the window already shows this session live. Lines that don't parse are skipped.
    ///
    /// A read that throws comes back as `.unreadable`, not an empty history (see
    /// ``LogHistoryRead``). A missing file is the exception: no log yet really is "nothing older",
    /// so it stays `.loaded([])` rather than putting an error note under a first launch.
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

    /// The log's bytes as text, with every invalid UTF-8 sequence replaced by U+FFFD rather than the
    /// file refused.
    ///
    /// A crash mid-append, or the CLI writing the same file, can cut a multi-byte character in half,
    /// and the log carries file paths, so non-ASCII bytes are common. One torn byte must not cost the
    /// whole history. Rotation is not a source: `trimTailIfOversized` cuts at a newline.
    ///
    /// `String(decoding:as:)` is the standard library's repairing initializer: one U+FFFD per
    /// malformed sequence, everything around it kept. **Don't** swap in Foundation's
    /// `String(data:encoding:)`: it answers nil for a UTF-8 character cut short (and on UTF-16 it
    /// silently drops the tail).
    ///
    /// Internal rather than private so the repair can be asserted on bytes, without a file.
    static func repairingUTF8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// ``loadOlderThan(_:fileURL:)`` ordered behind the log writer's pending disk work.
    ///
    /// The ordering is why this exists. Clear Log truncates the file on the writer's own
    /// background-QoS queue, so a load that starts right after a clear could read the pre-clear
    /// bytes, and with a valid token, since the token guard only covers loads already in flight at
    /// the clear. The deleted rows would come back for the window's lifetime. Draining the writer
    /// first puts this read behind any enqueued truncate.
    ///
    /// `drainWriter` is injected so a test can supply the pending write and prove the read comes
    /// after it.
    static func loadOlderThanDrainingWriter(
        _ sessionStart: Date,
        fileURL: URL,
        drainWriter: () -> Void
    ) -> LogHistoryRead {
        drainWriter()
        return loadOlderThan(sessionStart, fileURL: fileURL)
    }

    /// The pure core of ``loadOlderThan(_:fileURL:)``, so the parse, boundary and order are testable
    /// without disk.
    static func parseOlderThan(_ sessionStart: Date, text: String) -> [LogEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { LogEntry.parse(String($0)) }
            .filter { $0.timestamp < sessionStart }
            .reversed()
    }
}

/// Which empty state the log list shows, pure so it stays unit-testable. Each dead end needs its
/// own words: "No matching entries" blames the filters and offers to clear them; "No activity yet"
/// points at the loadable history; "No earlier activity" is the end state once history is loaded
/// and empty; and a quiet session over an unreadable log says so instead of offering a load that
/// just failed.
enum LogEmptyState: Equatable {
    /// Rows are visible; no empty state.
    case none
    /// Nothing logged this session and history hasn't been loaded: offer to load it.
    case noActivity
    /// History was loaded and the log holds nothing before this session.
    case noEarlierActivity
    /// Nothing logged this session and the history read failed, so there is nothing to offer.
    ///
    /// Separate from `.noActivity`, whose message offers "Show older history": over a failed read it
    /// would sit right above the footer's "Couldn't read the log file" and contradict it.
    case historyUnavailable
    /// Entries exist (this session and/or loaded history), but the level filter and/or search hide
    /// them all.
    case noMatches
    /// Show in Log's minutes, with the history loaded, and the log holds nothing from them: it is
    /// trimmed by size, and a kept message can be older than its oldest line.
    case spanNotInLog

    /// - Parameters:
    ///   - hasVisibleRows: any session or history rows are currently shown.
    ///   - hasRawEntries: any session entries, or already-loaded history entries, exist before filtering.
    ///   - historyLoaded: the user has loaded history at least once this session.
    ///   - historyReadFailed: the last history read failed (`LogHistoryState.failed`). No default
    ///     on purpose: a caller that omitted it would bring back the contradiction
    ///     `.historyUnavailable` exists to prevent.
    static func classify(hasVisibleRows: Bool,
                         hasRawEntries: Bool,
                         historyLoaded: Bool,
                         historyReadFailed: Bool) -> LogEmptyState {
        if hasVisibleRows { return .none }
        if hasRawEntries { return .noMatches }
        if historyLoaded { return .noEarlierActivity }
        return historyReadFailed ? .historyUnavailable : .noActivity
    }

    /// Whether the history footer should add its own "No earlier activity in the log" note.
    ///
    /// The footer and the in-flow empty state are independent views, so over an empty history in a
    /// quiet session both would say it. The empty state is the fuller of the two, so the footer
    /// yields. It still speaks when the session did log something, where no empty state renders and
    /// this note is the only word on the subject.
    static func footerNotesNoEarlierActivity(historyIsEmpty: Bool, emptyState: LogEmptyState) -> Bool {
        historyIsEmpty && emptyState != .noEarlierActivity
    }

    /// Whether the history footer should add its own "Couldn't read the log file" note.
    ///
    /// The same yield rule as ``footerNotesNoEarlierActivity(historyIsEmpty:emptyState:)``: once
    /// `.historyUnavailable` renders, the failed read is already stated where the eye lands first.
    /// The retry button is unaffected; it is an action, and the empty state's message names it. The
    /// note still speaks whenever the empty state says something else, such as when the session did
    /// log something and no empty state renders.
    static func footerNotesUnreadableHistory(emptyState: LogEmptyState) -> Bool {
        emptyState != .historyUnavailable
    }
}

/// Everything the Activity Log's list and chip row derive from the session entries plus the history
/// state, computed in one pure pass so the parts can't disagree.
///
/// The severity chips set a threshold that filters the session rows and the loaded history, so
/// their counts must cover both, or an "Errors 0" chip sits above a screenful of history error rows.
/// The history state enters here once and feeds both the counts and the rows: there is one
/// `history` parameter, so counting a different history than the rows show doesn't fit the API.
///
/// **Keep it nonisolated all the way down.** It is a pure value, constructible from anywhere, so
/// every helper its init reaches must be nonisolated too. `LogViewer.thresholdCounts` is a static on
/// a SwiftUI `View`, which is main-actor isolated; reaching one of those off the actor (from a
/// `Task.detached`, say) compiles with only a warning and SIGTRAPs at runtime. Mark any new helper
/// `nonisolated`, or move the work behind the actor and make the whole type `@MainActor`.
struct LogViewerContents {
    /// Session entries after the level/search filter, newest-first: the main list.
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
    ///   - history: the on-demand history's state, the same value that decides the footer. The
    ///     state, not an array: "not loaded", "loading", "failed" and "loaded but empty" each add
    ///     nothing for different reasons, and an array would let a caller count a different set.
    ///   - now: clock for `since:` search tokens, taken once so the session rows, the history rows
    ///     and the counts are all filtered against the same instant.
    init(session: [LogEntry],
         history: LogHistoryState,
         minimumLevel: LogLevel?,
         search: String,
         pageSize: Int,
         span: ClosedRange<Date>? = nil,
         now: Date = Date()) {
        // Activity's Show in Log: the minutes around one message, applied before every other
        // filter so the chips count what the narrowed list holds.
        let session = span.map { span in session.filter { span.contains($0.timestamp) } } ?? session
        let loadedHistory = history.entries.map { entries in
            span.map { span in entries.filter { span.contains($0.timestamp) } } ?? entries
        }
        sessionRows = LogEntryFilter.matches(session, minimumLevel: minimumLevel, search: search, now: now).reversed()
        // The chips count what the threshold filters: the session and all loaded history, not the
        // revealed page. "Show more" pages into this same set, so the counts must not grow with it.
        levelCounts = LogViewer.thresholdCounts(session: session, history: loadedHistory ?? [])
        // History respects the same Level/Search filters as the session; it is already newest-first.
        let historyMatches = loadedHistory.map {
            LogEntryFilter.matches($0, minimumLevel: minimumLevel, search: search, now: now)
        } ?? []
        visibleHistory = Array(historyMatches.prefix(history.revealed))
        nextReveal = LogHistoryState.nextRevealCount(
            matchCount: historyMatches.count, revealed: history.revealed, pageSize: pageSize)
        let state = LogEmptyState.classify(
            hasVisibleRows: !(sessionRows.isEmpty && visibleHistory.isEmpty),
            hasRawEntries: !session.isEmpty || !(loadedHistory?.isEmpty ?? true),
            historyLoaded: history.isLoaded,
            historyReadFailed: history.readFailed
        )
        // Nothing in the minutes asked for, with the whole log read: the log no longer reaches
        // them, which "nothing from earlier sessions" would misstate.
        emptyState = span != nil && state == .noEarlierActivity ? .spanNotInLog : state
    }
}

/// The Activity Log: this session's entries and, on demand, earlier history, filtered by level
/// and search.
public struct LogViewer: View {
    @ObservedObject public var logger = Logger.shared
    /// The minutes around one Activity message, set by its Show in Log and cleared by its chip.
    @Binding private var span: ClosedRange<Date>?
    /// The window's own title row; Activity's tab names it instead.
    private let showsTitle: Bool

    public init(span: Binding<ClosedRange<Date>?> = .constant(nil), showsTitle: Bool = true) {
        _span = span
        self.showsTitle = showsTitle
    }

    /// Whether Show in Log's minutes reach back before this launch while the earlier sessions' log
    /// isn't read: a message kept from an earlier session. Its minutes are only in that history,
    /// so the Log reads it as it opens rather than showing an empty list.
    nonisolated static func spanNeedsHistory(_ span: ClosedRange<Date>?, sessionStart: Date,
                                             history: LogHistoryState) -> Bool {
        guard let span, span.lowerBound < sessionStart else { return false }
        if case .notLoaded = history { return true }
        return false
    }

    /// "14:02:11 – 14:06:07", in the reader's own clock.
    static func spanText(_ span: ClosedRange<Date>) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .standard)
        return "\(span.lowerBound.formatted(style)) – \(span.upperBound.formatted(style))"
    }
    
    // The minimum severity to show (a threshold, not an exact match). Defaults to All Levels (nil)
    // so a user opening the log sees everything; "Warnings & above" keeps errors in view.
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchText: String = ""
    /// Whether the search field is revealed. Collapsed by default and toggled by the header's
    /// magnifier, Design's `ExpandingSearch` mechanism, so the log's search expands, focuses,
    /// escapes and clears exactly like Compare's and the Organize lenses'.
    @State private var isSearchExpanded = false
    /// The part of the severity row on screen, for its lens — see `SelectionLensVisibleRegion`.
    @State private var visibleLevels = SelectionLensVisibleRegion()
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    /// The glass hue, so the accent-tinted chrome (token chips, the selected severity chip) matches
    /// the hue every other window hands the same components.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// The Tint slider. This window paints the main window's background, so it must scale its
    /// accent by the same amount or the Activity Log comes up at full strength beside a faintly
    /// tinted app.
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// List density: compact tightens the row spacing so more log lines fit on screen.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var hueAccent: Color { glassHue.accentColor }

    /// What the selected level chip fills with: the deepened accent, since it carries a white label.
    /// Everything else here (hover washes, token chips, hairlines) keeps `hueAccent`; deepening a
    /// wash only muddies it.
    private var hueAccentFill: Color { glassHue.accentFillColor }

    /// Text and glyph colour on a `hueAccentFill` fill: white for every hue, because that fill is
    /// deepened until white clears 4.5:1 on it (`LiquidGlassHue.onAccentLabelColor`).
    private var onHueAccent: Color { glassHue.onAccentLabelColor }

    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// The on-demand history from `~/sync-cloud.log`: entries from before this launch, shown
    /// in-window. Whether it has been asked for, is being read, failed or is loaded, and how much
    /// of it is revealed, in one value (``LogHistoryState``).
    @State private var history: LogHistoryState = .notLoaded

    /// Page size for the on-demand history: the first "Show older history" reveals this many, and
    /// each "Show more" another page.
    private static let historyPageSize = 25

    /// Height of the standard title bar the header must clear. The window hides its title bar so the
    /// glass reaches the top edge (matching Settings), which leaves the traffic lights over the
    /// content's first rows.
    static let titleBarInset: CGFloat = 28

    /// Menu options for the severity threshold. No Debug row: "Debug & above" is "All Levels".
    ///
    /// `nonisolated` for `thresholdCounts`'s reason: the tally walks this list, and a main-actor
    /// static read from a nonisolated context traps. It is an immutable `Sendable` table.
    private nonisolated static let levelOptions: [(label: String, level: LogLevel?)] = [
        ("All Levels", nil),
        ("Info & above", .info),
        ("Warnings & above", .warning),
        ("Errors", .error),
    ]

    /// Short labels for the severity chips: the thresholds of `levelOptions`, trimmed so four pills
    /// fit the narrow log window. Counts come from `thresholdCounts`.
    private static let chipOptions: [(label: String, level: LogLevel?)] = [
        ("All", nil),
        ("Info", .info),
        ("Warnings", .warning),
        ("Errors", .error),
    ]

    /// One O(N) pass tallying the entries at or above each menu threshold, plus the total under
    /// the `nil` ("All Levels") key. Computed once per render and read by every chip.
    ///
    /// Counts the session and the loaded history, because the chips' threshold filters both. The two
    /// arrays are walked in place, not concatenated: this runs on every render, and the session list
    /// alone reaches thousands of entries.
    // Internal, not private: `LogLevelChipCountTests` pins the tally directly. `body` reaches it
    // only through `LogViewerContents`, which decides from the history state what is counted.
    //
    // **`nonisolated` is load-bearing.** SwiftUI isolates a `View`'s statics to the main actor, and
    // `LogViewerContents`'s nonisolated init calls this, from `Task.detached` among other places;
    // an isolated static there compiles with a warning and SIGTRAPs at runtime. It is plain
    // arithmetic over two arrays and needs no actor.
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

    /// Copies the on-screen slice (level and search filter applied) as canonical log lines, for
    /// pasting into a bug report. Oldest-first, so the paste reads chronologically and matches the
    /// file (the list shows newest-first).
    private func copyVisibleEntries(_ entries: [LogEntry]) {
        let text = entries.reversed().map(\.formattedString).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reads previous-session history off the main actor and reveals the first page. Reading a ≤5MB
    /// file once per open is cheap; "Show more" reveals further into the parsed array without
    /// re-reading.
    @MainActor
    private func loadHistory() {
        // Claiming the load IS the guard: `beginLoading` returns nil when a read is already in
        // flight or the history is loaded, so the double-fire check cannot be forgotten.
        guard let token = history.beginLoading() else { return }
        // Prior-session history is everything on disk older than this session's fixed start, not
        // `entries.first`: the memory cache keeps only the newest N, so after a busy session
        // `entries.first` falls inside the current session.
        // Floored to the millisecond, the file's precision: the writer rounds timestamps to ms, so
        // the session's first line, logged microseconds after `sessionStart`, can serialize below a
        // raw boundary and show (and copy) twice. Real history is seconds older and unaffected.
        let raw = logger.sessionStart.timeIntervalSinceReferenceDate
        let boundary = Date(timeIntervalSinceReferenceDate: (raw * 1000).rounded(.down) / 1000)
        let fileURL = logger.logFileURL
        // Taken here on the main actor but run inside the detached read: the barrier blocks until
        // the writer's queue drains, which must not happen on the main actor.
        let drainWriter = logger.diskWriteBarrier()
        // Token guard: Clear Log mid-flight resets the state, and a parse of the pre-clear file
        // must not overwrite that reset, or deleted rows come back and the reload button stays
        // hidden. `finishLoading` applies the parse only while this token is still awaited.
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
                // Logged here on the main actor, not in the detached read: `Logger.shared` is
                // main-actor isolated, and the read has no error channel. Logged even when the
                // token is stale: the read really did fail, and that is just as diagnostic.
                logger.error("Could not read \(fileURL.lastPathComponent) for the Activity Log's earlier history: \(reason)")
                history.failLoading(token: token)
            }
        }
    }

    @MainActor
    private func loadHistoryIfTheSpanNeedsIt() {
        if Self.spanNeedsHistory(span, sessionStart: logger.sessionStart, history: history) { loadHistory() }
    }

    public var body: some View {
        // One pure pass per render from the session entries and the history state: the rows, the
        // chip tallies, the revealed history page, the "Show N more" remainder and the empty state,
        // derived together (`LogViewerContents`) so they describe the same set. It also saves the
        // isEmpty checks and the ForEach below each re-running the filter.
        let contents = LogViewerContents(
            session: logger.entries,
            history: history,
            minimumLevel: selectedLevel,
            search: searchText,
            pageSize: Self.historyPageSize,
            span: span
        )
        let filtered = contents.sessionRows
        let levelCounts = contents.levelCounts
        let visibleHistory = contents.visibleHistory
        let nextReveal = contents.nextReveal
        let emptyState = contents.emptyState
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                if showsTitle {
                    Text("Activity Log")
                        .scaledFont(.headline)
                    Spacer()
                } else {
                    // Activity's Log tab: the tab names it, so the level chips take the title's
                    // place instead of a row of their own.
                    levelChips(levelCounts, inHeader: true)
                }

                // Copy covers everything on screen: session rows and any revealed "Earlier
                // sessions" page. Session entries are all newer than the history boundary, so the
                // concatenation stays newest-first and the copier's one reversed() pastes in
                // order. It enables on history alone, so a quiet session can still copy.
                let shownCount = filtered.count + visibleHistory.count
                Button(action: { copyVisibleEntries(filtered + visibleHistory) }) {
                    Image(systemName: "doc.on.doc")
                }
                // Glass in Frosted and Clear, like every bar button (`ChromeGlass`).
                .chromeGlassBorderedButtonStyle()
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                .disabled(filtered.isEmpty && visibleHistory.isEmpty)
                .help("Copy the \(shownCount) shown \(shownCount == 1 ? "entry" : "entries") to the clipboard")
                .accessibilityLabel("Copy the shown entries")

                // The whole file, masked, for a bug report (`CopyLogForSharing`): not the filtered
                // slice, since a report wants the lines around the problem too.
                Button(action: { Task { await CopyLogForSharing.copy(logger: logger) } }) {
                    Image(systemName: "eye.slash")
                }
                .chromeGlassBorderedButtonStyle()
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                .help(CopyLogForSharing.help)
                .accessibilityLabel(CopyLogForSharing.title)

                // The history reset rides the Logger's own notification, not this button, because
                // Settings has its own Clear Log too, and either must drop the parsed history (and
                // bring back the reload button). The reset also invalidates any in-flight load's
                // token, so its pre-clear parse is discarded.
                // Asks first, as Sync History's Clear does: it truncates the file on disk, every
                // earlier session's record.
                Button(action: { logger.clearIfConfirmed() }) {
                    Image(systemName: "trash")
                }
                .onReceive(NotificationCenter.default.publisher(for: Logger.didClearLogsNotification)) { _ in
                    history.reset()
                }
                // Glass in Frosted and Clear, like every bar button (`ChromeGlass`).
                .chromeGlassBorderedButtonStyle()
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                // Enabled while there is anything to clear: session entries or loaded history. On
                // session entries alone, a quiet session under a raised threshold would leave it
                // dead above a screenful of history.
                .disabled(logger.entries.isEmpty && !history.isLoaded)
                // Ellipsis on the tooltip because it asks, like "Clear all history…".
                .help("\(Logger.clearLogName)…")
                .accessibilityLabel(Logger.clearLogName)

                Button(action: { logger.openLogFile() }) {
                    Image(systemName: "doc.text")
                }
                // Glass in Frosted and Clear, like every bar button (`ChromeGlass`).
                .chromeGlassBorderedButtonStyle()
                .controlSize(.small)
                .chromeHover(tint: hueAccent)
                .help("Open in Console/TextEdit")
                .accessibilityLabel("Open the log file")

                // Search collapses to this magnifier, last on the right, where Compare's header
                // puts it. A click reveals the field on the row below, which takes focus; a second
                // click (or Escape) collapses and clears.
                ExpandingSearchToggle(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    accent: hueAccent,
                    help: "Search the log by message, level, or age"
                )
            }
            // A plain header row on the window glass, like Settings' title row: no bar background,
            // so no white slab across the top.
            .padding(.horizontal, 16)
            .padding(.vertical, showsTitle ? 12 : 10)
            // The window is `.hiddenTitleBar`, so the content starts under the traffic lights;
            // inset the header past them.
            .padding(.top, showsTitle ? LogViewer.titleBarInset : 0)

            if let span {
                ActivityFilterChip(text: "Only \(Self.spanText(span))",
                                   help: "Showing the minutes around the message picked in Activity. Show all to see every entry.") {
                    self.span = nil
                }
            }

            // Severity chips: the level threshold as pills, each with its live count, so the active
            // scope is always visible. They scroll sideways so large counts never truncate in the
            // narrow (380 pt) window.
            if showsTitle {
                levelChips(levelCounts, inHeader: false)
            }

            // The search field, revealed by the header's magnifier, with the parsed tokens as
            // removable chips and, while focused, one-tap suggestions. Design's
            // `ExpandingSearchField` carries the field, clear button, focus and Escape, so it
            // behaves like Compare's and the lens workspaces'.
            if isSearchExpanded {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
            // The transition above needs a driving animation (`designAnimation` below), or an `if`
            // alone inserts and removes the field instantly.


            // The log list. The empty state renders in-flow, not as an overlay, so the "Show older
            // history" footer below stays reachable when this session logged nothing.
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
            // No surface of its own: the list sits on the window's glass, like Settings' content.
        }
        .frame(minWidth: 380)
        // A new filter or search is a fresh view of history: collapse to the first page so the
        // list doesn't stay expanded to hundreds of filtered rows.
        .onChange(of: selectedLevel) { _, _ in history.resetRevealed(to: Self.historyPageSize) }
        .onChange(of: searchText) { _, _ in history.resetRevealed(to: Self.historyPageSize) }
        // Show in Log on a message from an earlier session: read the earlier history now.
        .onAppear { loadHistoryIfTheSpanNeedsIt() }
        .onChange(of: span) { _, _ in loadHistoryIfTheSpanNeedsIt() }
        // Drives the search field's reveal/hide transition (see above).
        .designAnimation(.easeOut(duration: 0.14), value: isSearchExpanded)
        // The main window's glass, level and hue, so the Activity Log reads as the same frosted
        // (or, at Clear, see-through) surface. Not inside Activity, whose window has one ground
        // for all its tabs.
        .modifier(LogViewerGround(applies: showsTitle, level: glassLevel, hue: glassHue, tint: surfaceTint))
    }

    /// The severity threshold as pills (All / Info & above / Warnings & above / Errors), each with
    /// its live count, scrolling sideways so large counts never truncate. A row of its own under
    /// the title, or the header itself inside Activity.
    private func levelChips(_ levelCounts: [LogLevel?: Int], inHeader: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.chipOptions, id: \.label) { option in
                    levelChip(option.label, level: option.level, count: levelCounts[option.level] ?? 0)
                }
            }
            .padding(.horizontal, inHeader ? 0 : 16)
            .padding(.top, inHeader ? 0 : 10)
            // Frosted and Clear: the active threshold's fill is one glass lens that glides between
            // chips, like every pick-one row. Hosted on the padded row, the scroll view's content,
            // so `visibleLevels` is in its coordinates.
            .selectionLensHost(Self.levelLensChannel, selected: Self.levelLensID(selectedLevel),
                               style: .fill(.capsule, color: hueAccentFill), visibleRegion: visibleLevels)
        }
        .selectionLensTracksVisibleRegion(visibleLevels)
    }

    // MARK: Search field

    /// The revealed search field: Design's shared `ExpandingSearchField` with this window's own
    /// accessories, the parsed `level:`/`since:` chips and, while it holds the caret, suggestions.
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

    /// The parsed `level:`/`since:` tokens as removable chips (Design's `TokenChipsRow`), each with
    /// an ✕ that edits that word out of the raw text.
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

    /// One-tap filter suggestions while the field is focused (Design's `TokenSuggestionRow`),
    /// omitting any family already active (level and since are single-valued, so a second would
    /// only replace the first).
    private func logSuggestionRow(active: [LogSearch.Chip]) -> some View {
        TokenSuggestionRow(
            items: logSuggestions(active: active).map {
                TokenSuggestionRow.Item(label: $0.label, raw: $0.raw,
                                        help: "Show only \($0.shows) — adds “\($0.raw)” to the search")
            },
            text: $searchText,
            tint: hueAccent
        )
    }

    /// `shows` completes the tooltip's "Show only …": `level:` matches one level exactly, so
    /// Warnings shows warnings and not errors.
    private static let logSuggestionCandidates: [(label: String, raw: String, shows: String)] = [
        ("Errors", "level:error", "errors"),
        ("Warnings", "level:warning", "warnings"),
        ("Last hour", "since:1h", "the last hour"),
        ("Last day", "since:1d", "the last day"),
    ]

    private func logSuggestions(active: [LogSearch.Chip]) -> [(label: String, raw: String, shows: String)] {
        let hasLevel = active.contains { $0.raw.lowercased().hasPrefix("level:") }
        let hasSince = active.contains { $0.raw.lowercased().hasPrefix("since:") }
        return Self.logSuggestionCandidates.filter { candidate in
            if candidate.raw.hasPrefix("level:") { return !hasLevel }
            if candidate.raw.hasPrefix("since:") { return !hasSince }
            return true
        }
    }

    // MARK: Severity chips

    /// The severity row's selection lens — see `SelectionLens`.
    static let levelLensChannel = SelectionLensChannel("log.levels")

    /// A chip's lens identity: its level, or "all" for the chip that has none.
    static func levelLensID(_ level: LogLevel?) -> String { level?.rawValue ?? "all" }

    /// One severity-threshold pill: its label, its live count, and a fill when it is the active
    /// threshold. Tapping sets `selectedLevel`.
    @ViewBuilder
    private func levelChip(_ label: String, level: LogLevel?, count: Int) -> some View {
        let selected = selectedLevel == level
        Button {
            selectedLevel = level
        } label: {
            // White on a deepened fill: AppKit's alternateSelectedControlTextColor is white under
            // every accent because it pairs with a darkened selection fill, and white on the raw
            // accent fails contrast (~1.6:1 on Yellow).
            let onAccent = onHueAccent
            HStack(spacing: 5) {
                Text(label)
                Text(count.formatted())
                    .monospacedDigit()
                    // Dimmed by the shared floor constant, not a local literal: 0.85 white on
                    // Graphite composites to ~2.97:1, under the 3:1 large-text minimum.
                    .selectionLensLabelInk(isSelected: selected,
                                           onFill: onAccent.opacity(AccentLabel.dimmedOnFillOpacity),
                                           onGlass: .secondary, unselected: .secondary)
            }
            .scaledFont(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .selectionLensLabelInk(isSelected: selected, onFill: onAccent, unselected: .primary)
            .background(
                // Selected fills with the glass hue, the accent other windows' chips use; unselected
                // wears the badge wash (`PillVariant.fillOpacity`). Under the row's lens the
                // selected fill is the lens, one capsule either way, so Solid's change still tweens.
                SelectionLensGround(Capsule(), isSelected: selected, selected: hueAccentFill,
                                    unselected: Color.secondary.opacity(PillVariant.fillOpacity))
            )
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 0.5))
            .selectionLensStop(Self.levelLensChannel, id: Self.levelLensID(level))
            .contentShape(Capsule())
        }
        // `.filled` for the active threshold at Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: selected, tint: hueAccent)
        .fixedSize()
        .help("Show \(label.lowercased())")
        // Exactly one chip is active, the window's primary state, so VoiceOver must hear it, not
        // just see ink and fill. `.help` describes the action and lands on accessibility help, not
        // the name; label and count go into one spoken name, and the trait says which is on.
        // **Use `.accessibilityLabel` alone, never `.accessibilityElement(children: .ignore)`**:
        // on a `Button` the container form replaces the element AppKit activates, and can cost the
        // chip its action. A live-tree test passes vacuously with no assistive client attached,
        // so use the form that can't break.
        .accessibilityLabel("\(label), \(count.formatted())")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Day-grouped list

    /// Renders `entries` (session or history) as day sections, folding per-file runs. Shared by the
    /// live list and the history footer so both read alike.
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
    /// `nextReveal` is how many rows "Show more" would reveal (0 when none are left), and
    /// `emptyState` is what the empty state above already says, passed in so the footer can stay
    /// quiet when the two would repeat each other.
    @ViewBuilder
    private func historyFooter(visibleHistory: [LogEntry], nextReveal: Int, emptyState: LogEmptyState) -> some View {
        if let loadedEntries = history.entries {
            if !visibleHistory.isEmpty {
                historyDivider
                daySections(visibleHistory)
                if nextReveal > 0 {
                    // The true remainder, not the page size.
                    historyActionButton("Show \(nextReveal) More", icon: "chevron.down") {
                        history.revealMore(by: Self.historyPageSize)
                    }
                } else {
                    historyEndNote("No older entries — you’re at the start of the log")
                }
            } else if LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: loadedEntries.isEmpty,
                                                                emptyState: emptyState) {
                // Loaded, and nothing before this session; said here only when the empty state
                // above isn't saying it.
                historyEndNote("No earlier activity in the log")
            }
            // else: history exists but the filter hides it; the empty state or session rows
            // already explain that.
        } else if history.readFailed {
            // A failed read is not "nothing older" (`LogHistoryState.failed`): say so, and keep the
            // button so the user can retry; a torn write usually clears by the next read.
            //
            // The note yields to `.historyUnavailable` when the empty state already says it; the
            // button always stays (`footerNotesUnreadableHistory`).
            if LogEmptyState.footerNotesUnreadableHistory(emptyState: emptyState) {
                historyEndNote("Couldn’t read the log file — earlier activity is unavailable")
            }
            historyActionButton("Show Older History", icon: "clock.arrow.circlepath") { loadHistory() }
        } else {
            historyActionButton("Show Older History", icon: "clock.arrow.circlepath",
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

    /// The in-flow empty state: a quiet session (offer history), a log with nothing older (once
    /// loaded), a failed read, or filters that hide everything, in the app's `EmptyStateView`.
    ///
    /// `body` classifies the state and passes it in: the footer needs the same answer to stay quiet
    /// when this view speaks, and two separate derivations could say the same thing twice.
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
                primary: .init("Clear Filters", systemImage: "xmark.circle",
                               help: "Show every entry — clears the level filter and the search") {
                    selectedLevel = nil
                    searchText = ""
                }
            )
        case .spanNotInLog:
            EmptyStateView(
                icon: "clock.badge.questionmark",
                title: "Nothing logged in these minutes",
                message: "The log keeps only its newest few megabytes, so an older message’s minutes may be gone from it. Show All puts the whole log back."
            )
        case .noEarlierActivity:
            EmptyStateView(
                icon: "clock",
                title: "No activity recorded",
                message: "This session is quiet and the log holds nothing from earlier sessions. Scans, copies, moves and deletes appear here as they happen."
            )
        case .noActivity:
            // Quiet session, history not loaded: point at the history in the file, loadable with the
            // footer button below.
            EmptyStateView(
                icon: "list.bullet.rectangle",
                title: "No activity yet",
                message: "Every scan, copy, move and delete is recorded here as it happens. This session is quiet so far — use “Show Older History” below to load what earlier sessions recorded."
            )
        case .historyUnavailable:
            // Quiet session and the read failed. Says the failure once, here (the footer's note
            // yields), and names the button as a retry, not an offer to load what just failed.
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "No activity recorded",
                message: "This session is quiet so far, and the log file couldn’t be read — earlier activity is unavailable. Scans, copies, moves and deletes appear here as they happen; “Show older history” below tries the file again."
            )
        }
    }
}

/// One log entry as a row, with a colour-coded severity icon. Internal (not private) so the
/// snapshot tests can pin the severity colour and icon pairings.
struct LogEntryRow: View {
    let entry: LogEntry
    /// List density, passed down by the parent instead of a per-row `@AppStorage`: one storage
    /// observer per window, not per row. Comfortable is the two-line pill/time-over-message layout;
    /// compact is one baseline row without the Location tail. Neither truncates: a long message
    /// wraps in both.
    var density: ListDensity = .comfortable
    /// The zone the time column reads in: `.current` everywhere in the app, so the column reads in
    /// the viewer's own clock. Injectable only so the snapshot references don't bake in the
    /// recording machine's zone, which would turn them red when the Mac changes zone.
    var timeZone: TimeZone = .current

    private var densityMetrics: ListDensityMetrics { density.metrics }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .scaledFont(.caption)
                .foregroundStyle(entry.level.semanticColor)
                .frame(width: 18)
                .padding(.top, 2)

            if density == .compact {
                // One baseline row: pill, time, then the message, so the eye gets a column of
                // aligned messages instead of two-line blocks.
                //
                // The message wraps rather than truncating: a log's long lines are its paths and
                // failure reasons, the things this window exists to show. Short entries still take
                // one line; only a line too long for the window costs a second row.
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

                    // The `Location: file:line / function` tail on warnings and errors is a developer
                    // breadcrumb, not the event, so it is dimmed and smaller. Still selectable; the
                    // full line stays in the log file and in Copy.
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
    
    /// The one formatter these rows stamp with, `fixed` so locale and calendar are pinned.
    ///
    /// An unpinned fixed-format `DateFormatter` follows the system region, which can turn even an
    /// explicit "HH" into a 12-hour clock, and the row would disagree with Copy and the on-disk log.
    /// The zone is `ZoneRefreshedFormatter`'s business, re-checked on every use.
    ///
    /// Internal, not private, so `LogRowTimeZoneTests` can drive the refresh directly; moving
    /// `NSTimeZone.default` instead is process-wide and would race every other suite in the run.
    static let timeFormatter = ZoneRefreshedFormatter.fixed("HH:mm:ss.SSS")

    private func timeString(from date: Date) -> String {
        return Self.timeFormatter.string(from: date, in: timeZone)
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

/// A folded operation run ("Synced 12 files") as an expandable row. Collapsed by default, to fold a
/// bulk action's per-file lines out of the way, but the header keeps the run's highest severity
/// colour so a failure inside a run is never hidden.
private struct LogOperationGroupRow: View {
    let group: LogGrouping.OperationGroup
    /// Passed down by `LogViewer` (see `LogEntryRow.density`) and forwarded to the expanded child
    /// rows.
    var density: ListDensity = .comfortable
    /// The glass hue, forwarded rather than read from `@AppStorage`: one storage observer per folded
    /// run is a lot of observers for one colour.
    var accent: Color = LiquidGlassHue.stored().accentColor
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
                    // The run's entry count, as Design's neutral mini pill so it matches every
                    // other count badge.
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
        // The header follows the density setting like its child rows, capped at 4pt; compact
        // drops to the flat-row 2pt.
        .padding(.vertical, min(4, density.metrics.flatRowVerticalPadding))
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(expanded ? "expanded" : "collapsed")")
    }

    /// The run header's stamp, from `LogEntryRow`'s formatter rather than a second one, so a zone
    /// change reaches the entry rows and the run headers above them alike.
    private static func timeString(_ date: Date) -> String {
        LogEntryRow.timeFormatter.string(from: date)
    }
}

/// The log window's own glass ground — off inside Activity, whose window has one for every tab.
private struct LogViewerGround: ViewModifier {
    let applies: Bool
    let level: GlassLevel
    let hue: LiquidGlassHue
    let tint: Double

    func body(content: Content) -> some View {
        if applies {
            content
                .liquidGlassAppBackground(level: level, hue: hue, tint: tint)
                // Keep the glass from graying out when this window isn't key (see the main window).
                .environment(\.controlActiveState, .active)
        } else {
            content
        }
    }
}
