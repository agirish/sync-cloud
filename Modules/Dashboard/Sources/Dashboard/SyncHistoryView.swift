import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Design
import Events

/// The Sync History window (X2): the durable, exportable, reversible counterpart to the Activity
/// Log. Where `LogViewer` shows the in-memory event stream that forgets on quit, this shows the
/// persisted `SyncHistoryStore` — every copy/move/delete with time, action, direction, paths, and
/// size — filterable by action, date range, and path, exportable to CSV/JSON, with a one-click
/// "Undo last sync run" that reverses the most recent run through the app's existing undo stack.
///
/// Built deliberately in the same shape as `LogViewer` (pure `SyncHistoryFilter`, a toolbar of
/// controls, a lazy list, an empty state) so the two read as one system.
public struct SyncHistoryView: View {
    @ObservedObject public var store = SyncHistoryStore.shared

    /// Reverses the most recent sync run. Injected so the (data-touching) NSAlert confirmation
    /// lives at the app boundary, keeping this view free of the manager and of Sync's types.
    private let onUndoLastSyncRun: () -> Void

    public init(store: SyncHistoryStore = .shared, onUndoLastSyncRun: @escaping () -> Void = {}) {
        self.store = store
        self.onUndoLastSyncRun = onUndoLastSyncRun
    }

    /// The action gate — nil is "All actions".
    @State private var selectedAction: SyncAction? = nil
    /// The date-range gate, as a preset the picker offers.
    @State private var dateRange: DateRange = .all
    @State private var searchText: String = ""
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    /// List-density setting (H7): comfortable renders exactly the pre-setting look; compact
    /// tightens the row spacing so more history records fit on screen.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// A coarse relative date window — enough for "what did I do recently" without a full date
    /// picker. Resolves to a lower bound at render time (upper bound is always "now").
    private enum DateRange: String, CaseIterable, Identifiable {
        case all = "All time"
        case lastHour = "Last hour"
        case today = "Today"
        case last7 = "Last 7 days"
        case last30 = "Last 30 days"

        var id: String { rawValue }

        /// The inclusive lower bound this range imposes, or nil for "no lower bound".
        func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
            switch self {
            case .all: return nil
            case .lastHour: return now.addingTimeInterval(-3600)
            case .today: return calendar.startOfDay(for: now)
            case .last7: return now.addingTimeInterval(-7 * 86_400)
            case .last30: return now.addingTimeInterval(-30 * 86_400)
            }
        }
    }

    private static let actionOptions: [(label: String, action: SyncAction?)] = [
        ("All Actions", nil),
        ("Copies", .copy),
        ("Moves", .move),
        ("Deletes", .delete),
    ]

    public var body: some View {
        // One filter pass per body render, shared by the count badges, the list, and Export.
        let filtered = SyncHistoryFilter.apply(
            store.records,
            action: selectedAction,
            search: searchText,
            start: dateRange.start()
        )
        VStack(spacing: 0) {
            toolbar(filtered: filtered)
            Divider().opacity(0.6)
            searchBar
            Divider().opacity(0.6)
            list(filtered: filtered)
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(filtered: [SyncHistoryRecord]) -> some View {
        HStack(spacing: 10) {
            Text("Sync History")
                .font(.headline)
            Spacer()

            Picker("Action", selection: $selectedAction) {
                ForEach(Self.actionOptions, id: \.label) { option in
                    Text(option.label).tag(option.action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            Picker("Range", selection: $dateRange) {
                ForEach(DateRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            Button {
                onUndoLastSyncRun()
            } label: {
                Label("Undo Last Run", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.records.isEmpty)
            .help("Reverse the most recent sync run")

            Menu {
                Button("Export as CSV…") { export(.csv, records: filtered) }
                Button("Export as JSON…") { export(.json, records: filtered) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 34)
            .disabled(filtered.isEmpty)
            .help("Export the \(filtered.count) shown \(filtered.count == 1 ? "record" : "records")")

            Button(action: { store.clear() }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.records.isEmpty)
            .help("Clear all history")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassBarStyle(level: glassLevel)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by path…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .glassBarStyle(level: glassLevel)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: List

    @ViewBuilder
    private func list(filtered: [SyncHistoryRecord]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: densityMetrics.logListSpacing) {
                ForEach(filtered) { record in
                    SyncHistoryRow(record: record, density: density)
                }
            }
            .padding(16)
        }
        .background(.regularMaterial.opacity(0.5))
        .overlay {
            if filtered.isEmpty {
                if store.records.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No sync history yet",
                        message: "Every copy, move, and delete is recorded here as it happens — with a timestamp, direction, and size you can filter, search, and export. History survives quitting the app.",
                        secondary: .init("Reveal History File", systemImage: "doc.text") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                        }
                    )
                } else {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No matching records",
                        message: "The current action, date range, and search hide all \(store.records.count) \(store.records.count == 1 ? "record" : "records").",
                        primary: .init("Clear Filters", systemImage: "xmark.circle") {
                            selectedAction = nil
                            dateRange = .all
                            searchText = ""
                        }
                    )
                }
            }
        }
    }

    // MARK: Export

    private enum ExportFormat { case csv, json }

    /// Writes the given records to a user-chosen file via NSSavePanel. Failures are logged (never
    /// thrown): an export is a read-only convenience, so a bad path can't cost data.
    private func export(_ format: ExportFormat, records: [SyncHistoryRecord]) {
        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.nameFieldStringValue = "sync-history.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .json:
            panel.nameFieldStringValue = "sync-history.json"
            panel.allowedContentTypes = [.json]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .csv ? SyncHistoryExporter.csv(records) : SyncHistoryExporter.json(records)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Logger.shared.info("Exported \(records.count) Sync History record(s) to \(url.lastPathComponent)")
        } catch {
            Logger.shared.error("Sync History export failed: \(error.localizedDescription)")
        }
    }
}

/// One row rendering a single `SyncHistoryRecord`: an action glyph, the action + direction +
/// time, the source→destination paths, and the size — kept honest and readable.
private struct SyncHistoryRow: View {
    let record: SyncHistoryRecord
    /// List-density setting (H7), passed down by SyncHistoryView (which already reads the
    /// defaults key) instead of a per-row `@AppStorage` — one storage observer per window, not
    /// per row. Comfortable keeps the two-line pill/meta-over-path layout exactly; compact
    /// collapses to a single baseline row where the path middle-truncates (it stays visible —
    /// the path IS the record).
    let density: ListDensity

    private var densityMetrics: ListDensityMetrics { density.metrics }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.action.systemImage)
                .font(.caption)
                .foregroundStyle(actionColor)
                .frame(width: 18)
                .padding(.top, 2)

            if density == .compact {
                // One baseline row: pill, path (middle-truncating, never hidden), then the
                // time/size meta pinned readable at the trailing edge.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    actionPill

                    if let direction = record.direction {
                        directionText(direction)
                    }

                    compactPathText
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    timeText
                        .layoutPriority(1)

                    if let size = record.sizeBytes {
                        sizeText(size)
                            .layoutPriority(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        actionPill

                        if let direction = record.direction {
                            directionText(direction)
                        }

                        timeText

                        if let size = record.sizeBytes {
                            sizeText(size)
                        }
                    }

                    // Source → destination. A delete has no destination, so it shows the origin alone.
                    if let dest = record.destPath {
                        HStack(spacing: 6) {
                            Text(Self.displayPath(record.sourcePath))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(Self.displayPath(dest))
                        }
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                    } else {
                        Text(Self.displayPath(record.sourcePath))
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
    }

    private var actionPill: some View {
        Pill(.mini, tint: actionColor, text: record.action.label)
    }

    private func directionText(_ direction: String) -> some View {
        Text(direction)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var timeText: some View {
        Text(Self.timeString(record.timestamp))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func sizeText(_ size: Int) -> some View {
        Text(Self.sizeString(size))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// The whole path as one `Text` (a "→" character instead of the comfortable layout's Image)
    /// so compact's middle truncation applies across source and destination together.
    private var compactPathText: Text {
        if let dest = record.destPath {
            return Text("\(Self.displayPath(record.sourcePath)) → \(Self.displayPath(dest))")
        }
        return Text(Self.displayPath(record.sourcePath))
    }

    private var actionColor: Color {
        // From the shared semantic table (C3): copy = success-green (accent collided with the
        // app accent), move = its own purple (orange collided with warning), delete = error.
        switch record.action {
        case .copy: return SemanticColor.success
        case .move: return SemanticColor.move
        case .delete: return SemanticColor.error
        }
    }

    private static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned locale + calendar (the Logger's own rule): an unpinned fixed-format
        // DateFormatter follows the system region, so a Buddhist-calendar region rendered
        // years like 2569 — disagreeing with the same window's ISO-8601 CSV/JSON export.
        // The timezone deliberately stays local: this column is display, not interchange.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
