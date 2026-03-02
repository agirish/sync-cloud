import SwiftUI

/// An interactive slide-over or floating inspector pane that filters and displays historical LogEntry traces.
struct LogViewer: View {
    @EnvironmentObject var logger: Logger
    
    @State private var selectedLevel: LogLevel? = nil // nil means show all
    @State private var searchText: String = ""
    
    var filteredEntries: [LogEntry] {
        var result = logger.entries
        
        if let level = selectedLevel {
            result = result.filter { $0.level == level }
        }
        
        if !searchText.isEmpty {
            result = result.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
        
        // Show newest at the bottom naturally or reverse for top-down
        return result.reversed() // Show newest at the top
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(LogLevel?.none)
                    Divider()
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                
                Button(action: { logger.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .help("Clear Logs")
                
                Button(action: { logger.openLogFile() }) {
                    Image(systemName: "doc.text")
                }
                .help("Open in Console/TextEdit")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter logs...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Log List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredEntries.isEmpty {
                        Text("No log activity.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                }
                .padding()
            }
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 350)
    }
}

/// An atomic row view rendering a single LogEntry with color-coded severity icons.
private struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.level.icon)
                .foregroundColor(entry.level.color)
                .frame(width: 16)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.level.rawValue)
                        .font(.caption2.bold())
                        .foregroundColor(entry.level.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(entry.level.color.opacity(0.2))
                        .cornerRadius(4)
                    
                    Text(timeString(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(entry.message)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled) // Allow user to copy traces
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
