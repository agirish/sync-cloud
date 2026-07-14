import SwiftUI
import AppKit
import Design
import Events

/// Pure filtering for the Activity Log, kept out of the `LogViewer` View so the level filter,
/// case-insensitive search, and newest-first ordering are unit-testable without `@State`.
enum LogEntryFilter {
    /// Filters to entries at or above `minimumLevel` (a severity *threshold*, not exact-match), then
    /// by case-insensitive message search, newest first.
    ///
    /// Threshold rather than equality is the whole point: someone opening the log after a failure
    /// wants "warnings and errors", which exact-match could never express — picking WARN used to
    /// hide the ERROR they came to see. `nil` shows every level.
    static func apply(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String) -> [LogEntry] {
        var result = entries

        if let minimumLevel {
            result = result.filter { $0.level.severity >= minimumLevel.severity }
        }

        if !search.isEmpty {
            result = result.filter { $0.message.localizedCaseInsensitiveContains(search) }
        }

        return result.reversed() // Show newest at the top
    }
}

/// Which empty state the log list shows — pure so the never-logged vs filtered-to-empty
/// distinction stays unit-testable. The two dead ends need different words and different
/// actions: "No activity yet" explains the surface's job; "No matching entries" names the
/// filters as the cause and offers to clear them.
enum LogEmptyState: Equatable {
    /// Rows are visible; no empty state.
    case none
    /// Nothing has been logged this session.
    case noActivity
    /// Entries exist, but the level filter and/or search hide them all.
    case noMatches

    static func classify(hasEntries: Bool, hasVisibleRows: Bool) -> LogEmptyState {
        if hasVisibleRows { return .none }
        return hasEntries ? .noMatches : .noActivity
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

    public var body: some View {
        // Computed once per body evaluation; the isEmpty check and the ForEach below would
        // otherwise each run the full filter pass.
        let filtered = LogEntryFilter.apply(logger.entries, minimumLevel: selectedLevel, search: searchText)
        let levelCounts = Self.thresholdCounts(logger.entries)
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
            
            // Log List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { entry in
                        LogEntryRow(entry: entry)
                    }
                }
                .padding(16)
            }
            .background(.regularMaterial.opacity(0.5))
            // The app's unified empty-state template (H3), centered over the list area —
            // symbol, what this surface does, then the one action that helps from here.
            .overlay {
                switch LogEmptyState.classify(hasEntries: !logger.entries.isEmpty, hasVisibleRows: !filtered.isEmpty) {
                case .none:
                    EmptyView()
                case .noActivity:
                    EmptyStateView(
                        icon: "list.bullet.rectangle",
                        title: "No activity yet",
                        message: "Every scan, copy, move and delete is recorded here as it happens, with a timestamp you can filter and search. Earlier sessions live in the log file.",
                        // The one action that helps from an empty session log: the on-disk
                        // file still holds earlier sessions. Scans start in the main window.
                        secondary: .init("Open Log File", systemImage: "doc.text") { logger.openLogFile() }
                    )
                case .noMatches:
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No matching entries",
                        message: "The current level filter and search hide all \(logger.entries.count) \(logger.entries.count == 1 ? "entry" : "entries") from this session.",
                        primary: .init("Clear Filters", systemImage: "xmark.circle") {
                            selectedLevel = nil
                            searchText = ""
                        }
                    )
                }
            }
        }
        .frame(minWidth: 380)
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
