import SwiftUI
import AppKit
import Design
import Events

/// Dashboard's rendering tint for a log level, drawn from the shared semantic table (C3).
/// Lives here rather than replacing `LogLevel.color` because Events is a leaf module that
/// must not depend on Design; non-Dashboard callers keep the original mapping.
extension LogLevel {
    var semanticColor: Color {
        switch self {
        case .info: return SemanticColor.info
        case .debug: return .gray
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

/// Loads previous-session history from the on-disk log so the Activity Log window can show entries
/// that predate the current launch — pure and nonisolated so the read/parse runs off the main actor
/// (the file is capped at ~5MB, so a full read per invocation is cheap) and stays unit-testable.
enum LogHistoryLoader {
    /// Every entry in `fileURL` strictly older than `sessionStart` — i.e. everything from earlier
    /// sessions, excluding the current session's lines (which the window already shows live from
    /// memory) — newest-first. Lines that don't parse are skipped.
    static func loadOlderThan(_ sessionStart: Date, fileURL: URL) -> [LogEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parseOlderThan(sessionStart, text: text)
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
/// activity" is the honest end state once history is loaded and the log holds nothing older.
enum LogEmptyState: Equatable {
    /// Rows are visible; no empty state.
    case none
    /// Nothing logged this session and history hasn't been loaded — offer to load it.
    case noActivity
    /// History was loaded and the log holds nothing before this session.
    case noEarlierActivity
    /// Entries exist (this session and/or loaded history), but the level filter and/or search hide
    /// them all.
    case noMatches

    /// - Parameters:
    ///   - hasVisibleRows: any session or history rows are currently shown.
    ///   - hasRawEntries: any session entries, or already-loaded history entries, exist before filtering.
    ///   - historyLoaded: the user has loaded history at least once this session.
    static func classify(hasVisibleRows: Bool, hasRawEntries: Bool, historyLoaded: Bool) -> LogEmptyState {
        if hasVisibleRows { return .none }
        if hasRawEntries { return .noMatches }
        return historyLoaded ? .noEarlierActivity : .noActivity
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
    /// Drives the one-tap suggestion row: shown only while the field has the caret, exactly like
    /// Compare's search.
    @FocusState private var searchFocused: Bool
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    /// The glass hue, so the accent-tinted chrome (token chips, the selected severity chip)
    /// matches the hue every other window passes to the same components — Tidy hands this exact
    /// tint to `TokenChipsRow`; the Log window used to hardcode `Color.accentColor` instead.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// List-density setting (H7): comfortable renders exactly the pre-setting look; compact
    /// tightens the row spacing so more log lines fit on screen.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var hueAccent: Color { glassHue.accentColor }

    /// Text/glyph color that stays legible on a `hueAccent` fill. `Color.onAccentLabel` pairs
    /// with the *system* accent, but the selected chip now fills with the glass hue — so the
    /// pairing comes from the hue's own sRGB luminance. The `.none` hue fills with the system
    /// accent, where `onAccentLabel` is exactly right.
    private var onHueAccent: Color {
        glassHue == .none ? .onAccentLabel : .onFillLabel(hueAccent)
    }

    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// Previous-session entries pulled from `~/sync-cloud.log` on demand (newest-first). nil until the
    /// user asks for history via "Show older history"; an empty array means the log holds nothing
    /// older than this session. The window shows the live in-memory session by default; this backfills
    /// the record that predates the current launch, in-window, without opening the file externally.
    @State private var loadedHistory: [LogEntry]? = nil
    /// How many of the (filtered) history entries are revealed — grows by ``historyPageSize`` per
    /// "Show more" click.
    @State private var historyLimit = LogViewer.historyPageSize
    /// True while the file read/parse is in flight, so the button shows progress and can't double-fire.
    @State private var isLoadingHistory = false
    /// Bumped by Clear Logs so an in-flight history load parsed from the PRE-clear file
    /// discards its result instead of resurrecting deleted rows over the reset state.
    @State private var historyLoadGeneration = 0

    /// Page size for the on-demand history: the first "Show older history" reveals this many, and each
    /// "Show more" reveals another page.
    private static let historyPageSize = 25

    /// Menu options for the severity threshold. Debug is omitted as its own row because
    /// "Debug & above" is identical to "All Levels".
    private static let levelOptions: [(label: String, level: LogLevel?)] = [
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
    private static func thresholdCounts(_ entries: [LogEntry]) -> [LogLevel?: Int] {
        var perLevel: [LogLevel: Int] = [:]
        for e in entries { perLevel[e.level, default: 0] += 1 }
        var out: [LogLevel?: Int] = [nil: entries.count]
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
        guard !isLoadingHistory, loadedHistory == nil else { return }
        isLoadingHistory = true
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
        // Generation guard: Clear Logs mid-flight resets the history state, and a completion
        // parsed from the PRE-clear file must not overwrite that reset — it would resurrect
        // deleted rows AND (loadedHistory being non-nil again) hide the reload button for the
        // window's lifetime.
        let generation = historyLoadGeneration
        Task {
            let history = await Task.detached(priority: .userInitiated) {
                LogHistoryLoader.loadOlderThan(boundary, fileURL: fileURL)
            }.value
            guard generation == historyLoadGeneration else { return }
            historyLimit = Self.historyPageSize
            loadedHistory = history
            isLoadingHistory = false
        }
    }

    public var body: some View {
        // Computed once per body evaluation; the isEmpty check and the ForEach below would
        // otherwise each run the full filter pass.
        let filtered = LogEntryFilter.apply(logger.entries, minimumLevel: selectedLevel, search: searchText)
        let levelCounts = Self.thresholdCounts(logger.entries)
        // History respects the same Level/Search filters as the session; it's already newest-first, so
        // no reordering. `visibleHistory` is the revealed page; `moreHistory` gates the "Show more".
        let historyMatches = loadedHistory.map { LogEntryFilter.matches($0, minimumLevel: selectedLevel, search: searchText) } ?? []
        let visibleHistory = Array(historyMatches.prefix(historyLimit))
        let moreHistory = historyMatches.count > historyLimit
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Text("Activity Log")
                    .font(.headline)
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
                .disabled(filtered.isEmpty && visibleHistory.isEmpty)
                .help("Copy the \(shownCount) shown \(shownCount == 1 ? "entry" : "entries") to the clipboard")

                // The history reset rides the Logger's own notification, NOT this button:
                // Settings has its own Clear Logs door, and a reset wired to one button left
                // the other door resurrecting deleted history rows. The on-disk file was
                // truncated, so parsed history must drop (and the reload button reappear —
                // it only renders while loadedHistory is nil); the generation bump makes any
                // IN-FLIGHT load discard its pre-clear parse instead of overwriting the reset.
                Button(action: { logger.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .onReceive(NotificationCenter.default.publisher(for: Logger.didClearLogsNotification)) { _ in
                    historyLoadGeneration += 1
                    loadedHistory = nil
                    historyLimit = Self.historyPageSize
                    isLoadingHistory = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logger.entries.isEmpty)
                .help("Clear Logs")

                Button(action: { logger.openLogFile() }) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in Console/TextEdit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassBarStyle(level: glassLevel)

            Divider()
                .opacity(0.6)

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

            // Search Bar — the query, plus (below) the parsed filter tokens as removable chips and,
            // while focused, one-tap suggestions. Mirrors Compare's search so one vocabulary reads the
            // same everywhere.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter — try level:error, since:1h", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                let chips = LogSearch.chips(searchText)
                if !chips.isEmpty {
                    logTokenChips(chips)
                }
                if searchFocused {
                    logSuggestionRow(active: chips)
                }
            }
            .padding(12)
            .glassBarStyle(level: glassLevel)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .opacity(0.6)
            
            // Log List. The empty state renders in-flow (not as an overlay) so the "Show older
            // history" footer below it stays reachable even when this session logged nothing.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: densityMetrics.logListSpacing) {
                    if filtered.isEmpty && visibleHistory.isEmpty {
                        emptyState
                    } else {
                        daySections(filtered)
                    }
                    historyFooter(visibleHistory: visibleHistory, moreAvailable: moreHistory)
                }
                .padding(16)
            }
            .background(.regularMaterial.opacity(0.5))
        }
        .frame(minWidth: 380)
        // A new filter/search is a fresh view of history — collapse back to the first page so the
        // list doesn't stay expanded to hundreds of now-filtered rows.
        .onChange(of: selectedLevel) { _, _ in historyLimit = Self.historyPageSize }
        .onChange(of: searchText) { _, _ in historyLimit = Self.historyPageSize }
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
                    .font(.caption2)
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
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
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
            // Text on the accent fill uses a luminance-derived pairing, not hardcoded
            // white and NOT alternateSelectedControlTextColor: AppKit returns white for that
            // under EVERY accent (it pairs with the darkened selection fill, not the raw accent
            // this capsule fills with), so under Yellow it was still white-on-yellow (~1.6:1).
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
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
            .background(
                // Selected fills with the glass hue (the accent every other window's chips use);
                // unselected wears the canonical badge wash (`PillVariant.fillOpacity`).
                Capsule().fill(selected ? AnyShapeStyle(hueAccent) : AnyShapeStyle(Color.secondary.opacity(PillVariant.fillOpacity)))
            )
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show \(label.lowercased())")
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
                    LogOperationGroupRow(group: group, density: density)
                }
            }
        }
    }

    // MARK: History footer

    /// The bottom-of-list history controls: before loading, one "Show older history" button; after,
    /// a divider, the revealed history rows, and either "Show more" or an end-of-log note.
    @ViewBuilder
    private func historyFooter(visibleHistory: [LogEntry], moreAvailable: Bool) -> some View {
        if let loadedHistory {
            if !visibleHistory.isEmpty {
                historyDivider
                daySections(visibleHistory)
                if moreAvailable {
                    historyActionButton("Show \(Self.historyPageSize) more", icon: "chevron.down") {
                        historyLimit += Self.historyPageSize
                    }
                } else {
                    historyEndNote("No older entries — you're at the start of the log")
                }
            } else if loadedHistory.isEmpty {
                // Loaded, and the log holds nothing before this session.
                historyEndNote("No earlier activity in the log")
            }
            // else: history exists but the current filter hides it — the empty state / session rows
            // already explain the emptiness; no separate note needed.
        } else {
            historyActionButton("Show older history", icon: "clock.arrow.circlepath",
                                 loading: isLoadingHistory) { loadHistory() }
        }
    }

    private var historyDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider().opacity(0.5) }
            Text("Earlier sessions")
                .font(.caption2.weight(.semibold))
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
            .disabled(loading)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func historyEndNote(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 10)
    }

    // MARK: Empty state

    /// The in-flow empty state: distinguishes a quiet session (offer history), a log with nothing
    /// older (once loaded), and filters that hide everything. Mirrors the app's EmptyStateView
    /// template used elsewhere.
    @ViewBuilder
    private var emptyState: some View {
        let hasRawEntries = !logger.entries.isEmpty || !(loadedHistory?.isEmpty ?? true)
        // Rendered only from the no-visible-rows branch, so hasVisibleRows is false here.
        switch LogEmptyState.classify(hasVisibleRows: false, hasRawEntries: hasRawEntries, historyLoaded: loadedHistory != nil) {
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
    /// to a single truncating baseline row and drops the Location tail.
    var density: ListDensity = .comfortable

    private var densityMetrics: ListDensityMetrics { density.metrics }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .font(.caption)
                .foregroundStyle(entry.level.semanticColor)
                .frame(width: 18)
                .padding(.top, 2)

            if density == .compact {
                // One baseline row: pill, time, then the message truncating — the scanning eye
                // gets a column of aligned messages instead of two-line blocks.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    levelPill
                    timeText
                    messageText
                        .lineLimit(1)
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
                            .font(.caption2.monospaced())
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
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var messageText: some View {
        Text(entry.messageBody)
            .font(.system(.subheadline, design: .monospaced))
            .textSelection(.enabled)
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
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
            .font(.caption2.weight(.semibold))
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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: group.icon)
                        .font(.caption)
                        .foregroundStyle(group.level.semanticColor)
                        .frame(width: 18)
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                    // The folded run's entry count — Design's neutral mini pill, not a
                    // hand-rolled capsule, so the badge matches every other count badge.
                    Pill(.mini, tint: .secondary, text: group.count.formatted(), isNumeric: true)
                    Spacer(minLength: 8)
                    Text(Self.timeString(group.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(expanded ? "expanded" : "collapsed")")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
}
