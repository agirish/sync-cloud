import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Design
import Events
import FileExplorer
import Sync

/// Activity's Events: everything SyncCloud did, newest first and by day, one row for each thing
/// done. A sync run is one row built from its Sync History records, led by the message that
/// reported it when one did, and opens in place to its files. A message no run carries, a one-way
/// sync, and a setting changed from Ask Claude's chat are rows beside it. All of it survives
/// quitting, messages too, except refusals (`ActivityMessageStore`).
///
/// The filters reach into runs: a path or action filter opens every run with a match and lists
/// only the matching files ("3 of 24 records"). Pointing at a row (a notification's click, Show in
/// Events) clears the filters that would hide it.
///
/// The band above it, what runs and needs you, is the window's: it ticks with the clock, and this
/// list never does, so a run's row says its time of day rather than its age.
public struct ActivityEventsView: View {
    @ObservedObject private var store: SyncHistoryStore
    @ObservedObject private var center: ActivityCenter
    @ObservedObject private var oneWay: OneWaySyncController
    /// The settings changes listed among the runs, or nil for none.
    private let settings: HistorySettingsChanges?
    @ObservedObject private var settingsLog: SettingsChangeLog
    /// Why writes wait while a long run goes; a message's Undo waits too.
    private let runWriteLock: String?
    /// The run Undo… can reverse: this session's newest, while it still tops the main window's undo
    /// stack. Injected, with `onUndoRun`, so the asking alert lives at the app boundary and this
    /// view stays free of the manager.
    private let undoableRun: @MainActor () -> UUID?
    /// Asks, then reverses that run. Returns why it refused, shown in this window's alert, or nil
    /// when it asked.
    private let onUndoRun: @MainActor () -> String?
    /// Confirms the history wipe. Injected so both answers can be driven without a modal.
    private let confirmClearHistory: @MainActor () -> Bool

    /// The reason the last Undo… click refused, while its alert is up.
    @State private var undoRefusal: String?
    /// Filters, open runs and paging, kept while the tab is away (Show in Log and back).
    @ObservedObject private var state: ActivityEventsState
    @State private var oneWayEntries: [OneWaySyncHistoryEntry] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    /// List-density setting: compact tightens a run's file rows so more fit on screen.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    /// A run lists its files a page at a time: a run of thousands builds a hundred rows, not all.
    static let recordPage = 100

    public init(store: SyncHistoryStore = .shared, center: ActivityCenter = .shared,
                oneWay: OneWaySyncController = .shared, settings: HistorySettingsChanges? = nil,
                runWriteLock: String? = nil,
                undoableRun: @escaping @MainActor () -> UUID? = { nil },
                onUndoRun: @escaping @MainActor () -> String? = { nil },
                confirmClearHistory: @escaping @MainActor () -> Bool = ActivityEventsView.defaultClearConfirmation,
                state: ActivityEventsState = .shared) {
        self.store = store
        self.state = state
        self.center = center
        self.oneWay = oneWay
        self.settings = settings
        settingsLog = settings?.log ?? Self.noSettingsChanges
        self.runWriteLock = runWriteLock
        self.undoableRun = undoableRun
        self.onUndoRun = onUndoRun
        self.confirmClearHistory = confirmClearHistory
    }

    /// The clear gesture as one step: ask, and only then wipe. Static and confirmer-taking so the
    /// decision is reachable without mounting the view, and no call site can wipe without asking.
    /// - Returns: Whether the history was cleared.
    @discardableResult
    public static func clearIfConfirmed(store: SyncHistoryStore, confirm: @MainActor () -> Bool) -> Bool {
        guard confirm() else { return false }
        // Logged so a suddenly empty history is attributable to this confirmed clear, not read as
        // the store failing to load. Here rather than in `store.clear()` so test fixtures' cleanup
        // stays out of the shared log, which Logger's exact-count suite in this package reads.
        Logger.shared.info("Sync history cleared — \(store.records.count) record(s) removed")
        store.clear()
        return true
    }

    /// Cancel is the default button and the destructive one takes no Return key, matching
    /// Settings' "Reset All Settings…": this empties the durable record on disk, and unlike the
    /// Activity Log nothing else keeps a copy.
    @MainActor public static func defaultClearConfirmation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all sync history?"
        alert.informativeText = "Permanently removes every recorded copy, move, delete, and date match from Events and from the history file on disk. Your files aren’t affected, and this can’t be undone. Export first if you want to keep a copy."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if let clearButton = alert.buttons.first {
            clearButton.hasDestructiveAction = true
            clearButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        return NativeAlerts.runModalCancellingOnEscape(alert) == .alertFirstButtonReturn
    }

    /// Observed when no settings changes are listed: a log that is never written.
    private static let noSettingsChanges = SettingsChangeLog(
        fileURL: URL(fileURLWithPath: "/var/empty/sync-cloud-no-settings-changes.json"))

    /// A coarse relative date window, enough for "what did I do recently" without a date picker.
    /// Resolves to a lower bound at render time; the upper bound is always now.
    enum DateRange: String, CaseIterable, Identifiable {
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

    /// The Action menu's run choices. `.delete` is "Moves to Trash & Deletes": its rows say Move to
    /// Trash, except a rare permanent delete, whose row says Delete and is listed too. Messages and
    /// One-Way Sync follow under a line, then Settings Changes when settings changes are listed.
    static let actionOptions: [(label: String, action: ActivityEventsChoice)] = [
        ("All Events", .all),
        ("Copies", .action(.copy)),
        ("Moves", .action(.move)),
        ("Moves to Trash & Deletes", .action(.delete)),
        ("Date Matches", .action(.matchDates)),
        ("New Folders", .action(.newFolder)),
    ]
    static let otherOptions: [(label: String, action: ActivityEventsChoice)] = [
        ("Messages", .messages),
        ("One-Way Sync", .oneWaySync),
    ]
    static let settingsOption = (label: "Settings Changes", action: ActivityEventsChoice.settings)

    /// The refusal alert's title. The message is the manager's reason, which names the cause.
    static let undoRefusalTitle = "Can’t undo this run"

    /// Whether a filter is narrowing runs to their matching files, which opens every match.
    private var narrowsRuns: Bool {
        state.choice.action != nil || !state.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The timeline as the filters leave it, built again only when what it is built from changed.
    /// The window redraws for many reasons (the manager publishes often); most change nothing here.
    private func events(changes allChanges: [SettingsChange]) -> [ActivityEvent] {
        let start = state.dateRange.start()
        let key = ActivityEventsState.BuildKey(
            records: store.records.count, firstRecord: store.records.first?.id, lastRecord: store.records.last?.id,
            trimmed: store.trimmedRunIds.count, recent: center.recentVersion, oneWay: oneWayEntries.map(\.id),
            changes: allChanges.count, lastChange: allChanges.last?.id, choice: state.choice, search: state.search,
            start: start.map { ($0.timeIntervalSinceReferenceDate / 60).rounded(.down) })
        if let cache = state.cache, cache.key == key { return cache.events }
        let events = ActivityEvents.build(records: store.records, messages: center.recent, oneWay: oneWayEntries,
                                          changes: allChanges, choice: state.choice, search: state.search,
                                          start: start, trimmedRuns: store.trimmedRunIds)
        state.cache = (key, events)
        return events
    }

    public var body: some View {
        let allChanges = settings.map { settingsLog.visible(hiding: $0.hiddenNames()) } ?? []
        // One pass per body render, shared by the list, the empty state, and Export.
        let events = events(changes: allChanges)
        let total = store.records.count + center.recent.count + oneWayEntries.count + allChanges.count
        // Asked once a render, not once a row.
        let undoable = undoableRun()
        VStack(spacing: 0) {
            toolbar(exportable: Self.records(in: events), hasChanges: !allChanges.isEmpty)
            Divider().opacity(0.6)
            list(events: events, total: total, undoable: undoable)
        }
        .frame(minWidth: 460, minHeight: 160)
        .alert(Self.undoRefusalTitle,
               isPresented: Binding(get: { undoRefusal != nil },
                                    set: { if !$0 { undoRefusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoRefusal ?? "")
        }
        // One-way sync's entries, read again after each sync, off the main thread: one file each.
        .task(id: oneWay.state?.lastSyncAt) {
            let history = oneWay.store?.history
            oneWayEntries = await Task.detached { history?.entries() ?? [] }.value
        }
        // One-way sync's History…: its entries alone, asked for perhaps before this tab was shown.
        .onChange(of: center.wantsOneWaySyncHistory, initial: true) { _, wants in
            guard wants else { return }
            center.wantsOneWaySyncHistory = false
            clearFilters()
            state.choice = .oneWaySync
        }
        // A notification's click, Show in Events, a waiting problem: its row, once.
        .onChange(of: center.pointRequest, initial: true) { _, id in
            guard let id else { return }
            center.pointRequest = nil
            point(at: id, in: events)
        }
        .onChange(of: state.search) { _, _ in state.closedWhileFiltered = [] }
        .onChange(of: state.choice) { _, _ in state.closedWhileFiltered = [] }
    }

    /// The runs' records the list shows, for Export: settings changes and messages aren't exported.
    static func records(in events: [ActivityEvent]) -> [SyncHistoryRecord] {
        events.flatMap { event -> [SyncHistoryRecord] in
            if case .run(let run) = event { return run.records }
            return []
        }
    }

    private func clearFilters() {
        state.choice = .all
        state.dateRange = .all
        state.search = ""
    }

    // MARK: Toolbar

    private func toolbar(exportable: [SyncHistoryRecord], hasChanges: Bool) -> some View {
        HStack(spacing: 10) {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassBarStyle(level: glassLevel)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                // What the pickers and buttons leave: they keep their own widths first.
                .layoutPriority(-1)

            Picker("Action", selection: $state.choice) {
                ForEach(Self.actionOptions, id: \.label) { option in
                    Text(option.label).tag(option.action)
                }
                Divider()
                ForEach(Self.otherOptions, id: \.label) { option in
                    Text(option.label).tag(option.action)
                }
                if settings != nil {
                    Text(Self.settingsOption.label).tag(Self.settingsOption.action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            Picker("Range", selection: $state.dateRange) {
                ForEach(DateRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            Menu {
                Button("Export as CSV…") { export(.csv, records: exportable) }
                Button("Export as JSON…") { export(.json, records: exportable) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.button)
            // Glass in Frosted and Clear, like every bar button (`ChromeGlass`).
            .chromeGlassBorderedButtonStyle()
            .controlSize(.small)
            .fixedSize()
            .frame(width: 34)
            .chromeHover()
            .disabled(exportable.isEmpty)
            // The runs' records shown: messages and settings changes aren't exported.
            .help("Export the \(exportable.count) shown sync \(exportable.count == 1 ? "record" : "records")")
            .accessibilityLabel("Export the shown records")

            clearControl(hasChanges: hasChanges)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The trash: three records, each cleared on its own, each asking first. Messages are kept across
    /// quits, so a clear takes earlier sessions' too.
    private func clearControl(hasChanges: Bool) -> some View {
        Menu {
            Button("Clear Messages…") { if ActivityCenter.confirmClearMessages() { center.clear() } }
                .disabled(center.recent.isEmpty)
            Button("Clear Sync History…") {
                // The messages that reported its runs go too: each would be a row with nothing behind it.
                if Self.clearIfConfirmed(store: store, confirm: confirmClearHistory) { center.forgetRunMessages() }
            }
                .disabled(store.records.isEmpty)
            if let settings {
                Button("Clear Settings Changes…") { if settings.confirmClear() { settings.log.clear() } }
                    .disabled(!hasChanges)
            }
        } label: {
            Image(systemName: "trash")
        }
        .menuStyle(.button)
        // No menu arrow, so it doesn't crowd Export's beside it.
        .menuIndicator(.hidden)
        .chromeGlassBorderedButtonStyle()
        .controlSize(.small)
        .fixedSize()
        .frame(width: 34)
        .chromeHover()
        .disabled(center.recent.isEmpty && store.records.isEmpty && !hasChanges)
        .accessibilityLabel("Clear events")
        .help("Clear messages, sync history or settings changes…")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(settings == nil ? "Filter by path or words…" : "Filter by path, setting or words…", text: $state.search)
                .textFieldStyle(.plain)
            if !state.search.isEmpty {
                Button(action: { state.search = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(.body)
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
    }

    // MARK: List

    private func list(events: [ActivityEvent], total: Int, undoable: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(ActivityEvents.days(events), id: \.title) { day in
                        Section {
                            ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                                if index > 0 { Divider().padding(.leading, 12) }
                                row(event, undoable: undoable)
                                    .id(event.id)
                            }
                        } header: {
                            dayHeader(day.title)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .background(.regularMaterial.opacity(0.5))
            // After the update that put the pointed-at row back in the list, not before it.
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                state.scrollTarget = nil
                withDesignAnimation(.default, reduceMotion: reduceMotion) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .overlay {
            if events.isEmpty { emptyState(total: total) }
        }
    }

    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func row(_ event: ActivityEvent, undoable: UUID?) -> some View {
        switch event {
        case .run(let run):
            runRow(run, undoable: undoable)
        case .message(let message):
            ActivityMessageRow(message: message, center: center, runWriteLock: runWriteLock, time: .clock)
                .background { highlight(message.id) }
                .modifier(ArrivalFlash(id: message.id, center: center))
        case .oneWay(let entry):
            OneWaySyncHistoryEntryRow(entry: entry, controller: oneWay)
        case .setting(let change):
            if let settings {
                SettingsChangeHistoryRow(change: change, settings: settings, density: density)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: A run

    private func runRow(_ run: ActivityEventRun, undoable: UUID?) -> some View {
        let open = isOpen(run)
        return VStack(alignment: .leading, spacing: 0) {
            if let message = run.message {
                // Its message leads. Where the run's Undo… stands, the message's own Undo goes; where
                // it doesn't (a mixed delete keeps its step but drops the run's pairing), it stays.
                ActivityMessageRow(message: message, center: center, runWriteLock: runWriteLock, time: .clock,
                                   showsUndo: undoable != run.id) {
                    runControls(run, isOpen: open, undoable: undoable)
                }
            } else {
                builtHeader(run, isOpen: open, undoable: undoable)
            }
            if open { runRecords(run) }
        }
        .background { highlight(run.message?.id) }
        .modifier(ArrivalFlash(id: run.message?.id, center: center))
    }

    /// A run no message reported: its sentence built from its records.
    private func builtHeader(_ run: ActivityEventRun, isOpen: Bool, undoable: UUID?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: run.records.first?.action.systemImage ?? "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.headline)
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(run.date.formatted(date: .omitted, time: .shortened))
                        .scaledFont(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let detail = run.detail {
                    Text(detail)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    runControls(run, isOpen: isOpen, undoable: undoable)
                    Button("Show in Log") { center.doors.showInLog(run.span) }
                        .buttonStyle(.link)
                        .help("The log, narrowed to the minutes around this run")
                }
                .controlSize(.small)
                .scaledFont(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// The run's files toggle, and Undo… on the one run it can reverse.
    @ViewBuilder
    private func runControls(_ run: ActivityEventRun, isOpen: Bool, undoable: UUID?) -> some View {
        Button {
            toggle(run, isOpen: isOpen)
        } label: {
            Label(Self.recordsLabel(run), systemImage: isOpen ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.link)
        .accessibilityValue(isOpen ? "Open" : "Closed")
        .help(isOpen ? "Hide this run’s files" : "Show this run’s files")
        if undoable == run.id {
            Button {
                undoRefusal = onUndoRun()
            } label: {
                // "…": it asks first, showing what it would reverse.
                Label("Undo…", systemImage: "arrow.uturn.backward")
            }
            // Waits while a long run is going, as the main window's undo does.
            .lockedDuringRun()
            .help("Reverse this run — asks first, listing what it puts back")
        }
    }

    /// "24 records", or "3 of 24 records" while a filter narrows it; "5,000 kept" when Sync History's
    /// cap cut the run, whose whole count is no longer known.
    static func recordsLabel(_ run: ActivityEventRun) -> String {
        let total = run.total.formatted()
        let label: String
        if run.isNarrowed {
            label = "\(run.records.count.formatted()) of \(total) records"
        } else {
            label = run.total == 1 ? "1 record" : "\(total) records"
        }
        return run.isCut ? label + " kept" : label
    }

    private func isOpen(_ run: ActivityEventRun) -> Bool {
        narrowsRuns ? !state.closedWhileFiltered.contains(run.id) : state.opened.contains(run.id)
    }

    private func toggle(_ run: ActivityEventRun, isOpen: Bool) {
        if narrowsRuns {
            if isOpen { state.closedWhileFiltered.insert(run.id) } else { state.closedWhileFiltered.remove(run.id) }
        } else {
            if isOpen { state.opened.remove(run.id) } else { state.opened.insert(run.id) }
        }
    }

    private func runRecords(_ run: ActivityEventRun) -> some View {
        let shown = state.shownRecords[run.id] ?? Self.recordPage
        return VStack(alignment: .leading, spacing: density.metrics.logListSpacing) {
            ForEach(run.records.prefix(shown)) { record in
                SyncHistoryRow(record: record, density: density)
            }
            if run.records.count > shown {
                Button("Show \(min(Self.recordPage, run.records.count - shown).formatted()) More") {
                    state.shownRecords[run.id] = shown + Self.recordPage
                }
                .buttonStyle(.link)
                .scaledFont(.system(size: 11))
            }
        }
        .padding(.leading, 39)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func highlight(_ id: UUID?) -> some View {
        if let id, id == center.highlighted {
            RoundedRectangle(cornerRadius: Radius.chip).fill(LiquidGlassHue.stored().accentColor.opacity(0.14))
        }
    }

    /// Brings a message's row into view: its own, or that of the run it leads, opened. Clears the
    /// filters only when they hide it, then scrolls once the list has it again.
    private func point(at id: UUID, in shown: [ActivityEvent]) {
        var target = "message-\(id)"
        if let runId = center.recent.first(where: { $0.id == id })?.runId,
           store.records.contains(where: { $0.runId == runId }) {
            target = "run-\(runId)"
            state.opened.insert(runId)
            state.closedWhileFiltered.remove(runId)
        }
        if !shown.contains(where: { $0.id == target }) { clearFilters() }
        state.scrollTarget = target
    }

    @ViewBuilder
    private func emptyState(total: Int) -> some View {
        if total == 0 {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "Nothing yet",
                message: "Every copy, move, delete, and date match is listed here as it happens, with what SyncCloud said about it. It stays after you quit.",
                secondary: .init("Reveal History File", systemImage: "doc.text",
                                 help: "Show the file the sync history is saved in, \(store.fileURL.lastPathComponent), in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
            )
        } else {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching events",
                message: "The current action, date range, and search hide everything here.",
                primary: .init("Clear Filters", systemImage: "xmark.circle",
                               help: "Show every event — clears the action, date range, and search filters") {
                    clearFilters()
                }
            )
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

/// One row for a single `SyncHistoryRecord`: an action glyph, the action, direction and time, the
/// source→destination paths, and the size. Internal, like `LogEntryRow`, so a test can reach
/// `timeFormatter`.
struct SyncHistoryRow: View {
    let record: SyncHistoryRecord
    /// List-density setting, passed down by `ActivityEventsView`, which already reads the key, so
    /// there is one storage observer per window rather than per row. Comfortable is the two-line
    /// pill/meta-over-path layout; compact is one baseline row where the path middle-truncates but
    /// stays visible, since the path is the record.
    let density: ListDensity

    private var densityMetrics: ListDensityMetrics { density.metrics }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.action.systemImage)
                .scaledFont(.caption)
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
                        .scaledFont(.system(.subheadline, design: .monospaced))
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

                        if let previous = Self.previousDateText(record) {
                            Text(previous)
                                .scaledFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Source → destination. A delete has no destination, so it shows the origin alone.
                    if let dest = record.destPath {
                        HStack(spacing: 6) {
                            Text(Self.displayPath(record.sourcePath))
                            Image(systemName: "arrow.right")
                                .scaledFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(Self.displayPath(dest))
                        }
                        .scaledFont(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                    } else {
                        Text(Self.displayPath(record.sourcePath))
                            .scaledFont(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
        // One element per file, so VoiceOver reads a run's files one at a time.
        .accessibilityElement(children: .combine)
    }

    private var actionPill: some View {
        // The record's own label, so a permanent delete still says "Delete".
        Pill(.mini, tint: actionColor, text: record.actionLabel)
    }

    private func directionText(_ direction: String) -> some View {
        Text(direction)
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var timeText: some View {
        Text(Self.timeString(record.timestamp))
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
    }

    private func sizeText(_ size: Int) -> some View {
        Text(Self.sizeString(size))
            .scaledFont(.caption2)
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
        // From the shared semantic table: copy is success green and move its own purple, so
        // neither clashes with the app accent or the warning colour; delete is error.
        switch record.action {
        case .copy: return SemanticColor.success
        case .move: return SemanticColor.move
        case .delete: return SemanticColor.error
        // Nothing was copied, moved or removed — only a date set — so informational blue.
        case .matchDates: return SemanticColor.info
        // Nothing moved or removed: a folder made.
        case .newFolder: return SemanticColor.info
        }
    }

    private static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The one formatter this column stamps with: `fixed`, so locale and calendar are pinned.
    /// Unpinned, a fixed-format `DateFormatter` follows the system region, and a Buddhist-calendar
    /// region would show years like 2569, disagreeing with the ISO-8601 export. The zone stays
    /// local, since this is display, not interchange, and is re-checked on every use (see
    /// `ZoneRefreshedFormatter`). Internal so `SyncHistoryRowTimeZoneTests` can drive the refresh.
    static let timeFormatter = ZoneRefreshedFormatter.fixed("yyyy-MM-dd HH:mm:ss")

    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// What a date match replaced, in the row's own time format ("was 2025-01-01 09:00:00"), or
    /// nil. Comfortable rows only: compact keeps its one line for the path.
    static func previousDateText(_ record: SyncHistoryRecord) -> String? {
        record.previousModificationDate.map { "was \(timeString($0))" }
    }
}


/// Events' filters, open runs and paging, kept while the window is open: switching to Log and back
/// (Show in Log on a run) finds Events as it was left. One for the app's one Activity window; a
/// test passes its own.
@MainActor
public final class ActivityEventsState: ObservableObject {
    public static let shared = ActivityEventsState()

    @Published var choice: ActivityEventsChoice = .all
    @Published var dateRange: ActivityEventsView.DateRange = .all
    @Published var search = ""
    /// Runs opened by hand while no filter narrows them.
    @Published var opened: Set<UUID> = []
    /// Runs closed by hand while a filter opens every match.
    @Published var closedWhileFiltered: Set<UUID> = []
    /// How many of a run's records it lists, past the first page.
    @Published var shownRecords: [UUID: Int] = [:]
    /// The row to scroll to on the next update, set by pointing at one.
    @Published var scrollTarget: String?

    /// What the timeline was last built from; equal means the build would come out the same.
    struct BuildKey: Equatable {
        let records: Int
        let firstRecord: UUID?
        let lastRecord: UUID?
        let trimmed: Int
        let recent: Int
        let oneWay: [UUID]
        let changes: Int
        let lastChange: UUID?
        let choice: ActivityEventsChoice
        let search: String
        /// The range's start to the minute: "Last hour" moves with the clock.
        let start: Double?
    }
    /// The last build: not published, a cache.
    var cache: (key: BuildKey, events: [ActivityEvent])?

    public init() {}
}

/// A message arriving while Events is open flashes its row once, as the popover's rows do. A fade,
/// so Reduce Motion keeps it.
private struct ArrivalFlash: ViewModifier {
    let id: UUID?
    @ObservedObject var center: ActivityCenter

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: center.flashes) { row, glow in
            row.background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(LiquidGlassHue.stored().accentColor.opacity(id != nil && id == center.flashedRow ? glow : 0)))
        } keyframes: { _ in
            LinearKeyframe(0.22, duration: 0.15)
            LinearKeyframe(0, duration: 1.45)
        }
    }
}
