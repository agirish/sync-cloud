import SwiftUI
import Design
import Events

/// Pure filtering for the Activity Log, kept out of the `LogViewer` View so the level filter,
/// case-insensitive search, and newest-first ordering are unit-testable without `@State`.
enum LogEntryFilter {
    /// - Parameter level: `nil` shows all levels.
    static func apply(_ entries: [LogEntry], level: LogLevel?, search: String) -> [LogEntry] {
        var result = entries

        if let level {
            result = result.filter { $0.level == level }
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
    
    // Defaults to All Levels (nil): the filter is equality-based, so any single level would
    // hide WARN/ERROR entries from a user opening the log right after a failure.
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchText: String = ""
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    
    public var body: some View {
        // Computed once per body evaluation; the isEmpty check and the ForEach below would
        // otherwise each run the full filter pass.
        let filtered = LogEntryFilter.apply(logger.entries, level: selectedLevel, search: searchText)
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Text("Activity Log")
                    .font(.headline.weight(.semibold))
                Spacer()
                
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(LogLevel?.none)
                    Divider()
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                
                Button(action: { logger.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
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
            // The Tidy pre-scan template (CenteredStateView), centered over the list area —
            // symbol, what this surface does, then the one action that helps from here.
            .overlay {
                switch LogEmptyState.classify(hasEntries: !logger.entries.isEmpty, hasVisibleRows: !filtered.isEmpty) {
                case .none:
                    EmptyView()
                case .noActivity:
                    CenteredStateView(
                        symbol: "list.bullet.rectangle",
                        tint: .secondary,
                        title: "No activity yet",
                        message: "Every scan, copy, move and delete is recorded here as it happens, with a timestamp you can filter and search. Earlier sessions live in the log file."
                    ) {
                        // The one action that helps from an empty session log: the on-disk
                        // file still holds earlier sessions. Scans start in the main window.
                        Button(action: { logger.openLogFile() }) {
                            Label("Open Log File", systemImage: "doc.text")
                        }
                        .controlSize(.regular)
                    }
                case .noMatches:
                    CenteredStateView(
                        symbol: "line.3.horizontal.decrease.circle",
                        tint: .secondary,
                        title: "No matching entries",
                        message: "The current level filter and search hide all \(logger.entries.count) \(logger.entries.count == 1 ? "entry" : "entries") from this session."
                    ) {
                        Button {
                            selectedLevel = nil
                            searchText = ""
                        } label: {
                            Label("Clear Filters", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
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
                
                Text(entry.message)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
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
