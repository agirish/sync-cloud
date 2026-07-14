import SwiftUI
import AppKit
import Design
import Events

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
    static func matches(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String) -> [LogEntry] {
        var result = entries

        if let minimumLevel {
            result = result.filter { $0.level.severity >= minimumLevel.severity }
        }

        if !search.isEmpty {
            result = result.filter { $0.message.localizedCaseInsensitiveContains(search) }
        }

        return result
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
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65

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
        // Older than the session's start; distantFuture (no session entries yet) means the whole file
        // is history.
        let boundary = logger.entries.first?.timestamp ?? .distantFuture
        let fileURL = logger.logFileURL
        Task {
            let history = await Task.detached(priority: .userInitiated) {
                LogHistoryLoader.loadOlderThan(boundary, fileURL: fileURL)
            }.value
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
                    .font(.headline.weight(.semibold))
                Spacer()
                
                Picker("Level", selection: $selectedLevel) {
                    ForEach(Self.levelOptions, id: \.label) { option in
                        Text("\(option.label) (\(levelCounts[option.level] ?? 0))")
                            .tag(option.level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Button(action: { copyVisibleEntries(filtered) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(filtered.isEmpty)
                .help("Copy the \(filtered.count) shown \(filtered.count == 1 ? "entry" : "entries") to the clipboard")

                Button(action: { logger.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(logger.entries.isEmpty)
                .help("Clear Logs")

                Button(action: { logger.openLogFile() }) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .help("Open in Console/TextEdit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassBarStyle(intensity: glassIntensity)
            
            Divider()
                .opacity(0.6)
            
            // Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassBarStyle(intensity: glassIntensity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .opacity(0.6)
            
            // Log List. The empty state renders in-flow (not as an overlay) so the "Show older
            // history" footer below it stays reachable even when this session logged nothing.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filtered.isEmpty && visibleHistory.isEmpty {
                        emptyState
                    } else {
                        ForEach(filtered) { entry in
                            LogEntryRow(entry: entry)
                        }
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

    // MARK: History footer

    /// The bottom-of-list history controls: before loading, one "Show older history" button; after,
    /// a divider, the revealed history rows, and either "Show more" or an end-of-log note.
    @ViewBuilder
    private func historyFooter(visibleHistory: [LogEntry], moreAvailable: Bool) -> some View {
        if let loadedHistory {
            if !visibleHistory.isEmpty {
                historyDivider
                ForEach(visibleHistory) { LogEntryRow(entry: $0) }
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
private struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .font(.caption)
                .foregroundStyle(entry.level.color)
                .frame(width: 18)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.level.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.level.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(entry.level.color.opacity(0.15))
                        .clipShape(Capsule())
                    
                    Text(timeString(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Text(entry.messageBody)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)

                // The `Location: file:line / function` tail that warnings/errors carry is a
                // developer breadcrumb, not the event — show it dimmed and smaller so the row
                // reads as its message. Still selectable; the full line remains in the log file
                // and in Copy.
                if let location = entry.messageLocation {
                    Text(location)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
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
