import SwiftUI
import Design

/// An interactive slide-over or floating inspector pane that filters and displays historical LogEntry traces.
public struct LogViewer: View {
    @ObservedObject public var logger = Logger.shared
    
    public init() {}
    
    @State private var selectedLevel: LogLevel? = nil // nil means show all
    @State private var searchText: String = ""
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    
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
    
    public var body: some View {
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
            .modifier(AdaptiveGlass(cornerRadius: 12, intensity: glassIntensity, baseMaterial: .regularMaterial))
            
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
            .modifier(AdaptiveGlass(cornerRadius: 10, intensity: glassIntensity, baseMaterial: .regularMaterial))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .opacity(0.6)
            
            // Log List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filteredEntries.isEmpty {
                        Text("No log activity.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                }
                .padding(16)
            }
            .background(.regularMaterial.opacity(0.5))
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
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
